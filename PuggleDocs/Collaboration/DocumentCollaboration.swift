import AppKit
import Observation
import PuggleDocsKit

/// What the header shows about a document's sharing: who's in it, who has it open, and how it's keeping up.
@Observable
final class CollaborationState {
    var isShared = false
    var isOwner = true
    var ownerName = ""
    /// What this Mac's person can do.
    var permission: CollaboratorPermission = .edit
    /// Everyone it's shared with, the owner first.
    var collaborators: [Collaborator] = []
    /// Who has it open, as last heard, by iCloud identity.
    var presence: [String: Presence] = [:]
    var meID: String?
    /// Words for how the shared copy is keeping up, in place of the file's save status.
    var statusText = ""
    var statusSymbol = "icloud"
    /// Bumped as time passes, so "last seen" words keep up.
    var clock = Date()

    /// The people other than this Mac's who are in it, the owner first: the round badges in the header. Everyone who
    /// has opened it, named as they name themselves, so they show even when iCloud doesn't say who they are; then
    /// those iCloud lists as joined who haven't, by names not shown already, so nobody shows twice.
    var others: [Collaborator] {
        var people: [Collaborator] = []
        for item in presence.values where item.person != meID {
            var person = collaborators.first { $0.id == item.person }
                ?? Collaborator(id: item.person, name: item.info.name, isOwner: item.info.isOwner ?? false,
                                permission: item.info.permission ?? .comment, status: .joined)
            if person.name.isEmpty { person.name = item.info.name }
            people.append(person)
        }
        for person in collaborators where person.id != meID && person.status == .joined && !people.contains(where: { $0.id == person.id }) {
            guard people.isEmpty || (!person.name.isEmpty && !people.contains { $0.name == person.name }) else { continue }
            people.append(person)
        }
        return people.sorted { ($0.isOwner ? 0 : 1, $0.displayName.lowercased()) < ($1.isOwner ? 0 : 1, $1.displayName.lowercased()) }
    }

    func isViewing(_ person: Collaborator) -> Bool { presence[person.id]?.isActive(now: clock) ?? false }

    func lastSeen(_ person: Collaborator) -> Date? { presence[person.id]?.date }

    func reset() {
        isShared = false
        isOwner = true
        ownerName = ""
        permission = .edit
        collaborators = []
        presence = [:]
        statusText = ""
    }
}

/// An undo step of this Mac's in a shared document: what undoes it, kept up to date as other people's changes come
/// in, so undo only ever takes back this person's own changes, wherever they've moved to.
private final class UndoEntry {
    let stream: DocumentCollaboration.Stream
    var delta: TextDelta

    init(stream: DocumentCollaboration.Stream, delta: TextDelta) {
        self.stream = stream
        self.delta = delta
    }
}

/// One open document's part in sharing: its text, header and footer kept the same as everyone else's through the
/// document's log, its comments through the talk zone, who's in it, and the short summaries that tell the others
/// what changed.
///
/// While a document is shared, changes made here are recorded as they're made (see `RecordingTextStorage`) and sent
/// one after another; other people's changes are applied as they come, with this Mac's changes still on their way
/// rewritten around them. Undo works on this Mac's own changes, through steps kept here rather than the text views'.
final class DocumentCollaboration: NSObject {
    enum Stream: CaseIterable {
        case body, header, footer
    }

    enum Phase: Equatable {
        /// Waiting for the shared copy to load.
        case connecting
        case live
        case ended
    }

    /// How long a run of changes waits for the next before the others are told about it.
    static var noticeDelay: TimeInterval = 120

    let id: UUID
    let isOwner: Bool
    /// For documents shared with this person, whose iCloud they're in.
    let ownerID: String?
    private unowned let controller: CollaborationController
    private(set) weak var document: PuggleDocument?
    private weak var windowController: DocumentWindowController?
    let coder = SyncAttributeCoder()
    private(set) var client: SyncClient?
    private var channel: CollaborationChannel?
    private(set) var sharing: DocumentSharing?
    private(set) var phase: Phase = .connecting
    private var info: SharedDocumentInfo?
    /// Changes that came before the snapshot they follow.
    private var earlyChanges: [LoggedChange] = []
    private var isApplyingRemote = false
    private var undoEntries: [UndoEntry] = []
    private var redoEntries: [UndoEntry] = []
    private weak var typingEntry: UndoEntry?
    private var typingEnd: Int?
    private var typingDeletes = false
    private var isTypingBroken = true
    /// Comment threads as iCloud last had them, by id.
    private var serverComments: [String: SharedComment] = [:]
    /// Threads from others whose anchoring waits for their revision of the log to come.
    private var waitingAnchors: [String: SharedComment] = [:]
    private var tally = ChangeTally()
    private var noticeWork: DispatchWorkItem?
    private var snapshotWork: DispatchWorkItem?
    private var lastSnapshotRevision = 0
    private var retryDelay: TimeInterval = 1
    private var retryScheduled = false
    /// Why changes can't be saved to iCloud just now, when they can't. Meanwhile the window takes none: nothing made
    /// in a shared document is kept to send later.
    private enum Blocked: Equatable {
        /// iCloud can't be reached: the Mac is offline, say.
        case offline
        /// iCloud turned a change down, saying why.
        case refused(String)
    }
    private var blocked: Blocked?
    /// The window's banner as this session last set it, so coming back online takes away only its own.
    private var blockedBanner: String?
    private var heartbeat: Timer?
    /// Looking again for a change of the log that others came ahead of, longer apart each time.
    private var gapCheck: DispatchWorkItem?
    private var gapDelay: TimeInterval = 1

    init(id: UUID, isOwner: Bool, ownerID: String?, controller: CollaborationController, document: PuggleDocument,
         windowController: DocumentWindowController) {
        self.id = id
        self.isOwner = isOwner
        self.ownerID = ownerID
        self.controller = controller
        self.document = document
        self.windowController = windowController
        super.init()
    }

    private var editor: EditorController? { windowController?.editor }
    private var state: CollaborationState? { windowController?.state.collaboration }
    var title: String { document?.title ?? info?.title ?? "Untitled document" }
    var me: Collaborator? { controller.status.me }

    /// Whether this person may change the text.
    var canEdit: Bool { isOwner || (sharing?.myPermission ?? .comment) == .edit }

    /// Whether changes made here haven't all reached iCloud.
    var hasUnsentChanges: Bool { phase == .live && (client?.hasPending ?? false) }

    private func storage(_ stream: Stream) -> RecordingTextStorage? {
        switch stream {
        case .body: document?.textStorage
        case .header: document?.headerStorage
        case .footer: document?.footerStorage
        }
    }

    // MARK: Starting and ending

    /// Shares the document for the first time, as it is now, then carries on live.
    func startSharing(access: LinkAccess, permission: CollaboratorPermission, completion: @escaping (Error?) -> Void) {
        guard let document else { return }
        let snapshot = makeSnapshot(revision: 0)
        let comments = document.comments.map { thread in
            SharedComment(thread: thread, anchor: anchor(of: thread.id, revision: 0, logPosition: { $0 }))
        }
        controller.service.share(id, title: title, snapshot: snapshot, comments: comments, access: access, permission: permission) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(sharing):
                self.sharing = sharing
                for comment in comments { serverComments[comment.thread.id] = comment }
                client = SyncClient(revision: 0, author: me?.id ?? "me", authorName: me?.name ?? NSFullUserName())
                lastSnapshotRevision = 0
                info = SharedDocumentInfo(title: title, ownerName: me?.name ?? "")
                updateState()
                goLive()
                connectChannel()
                completion(nil)
            case let .failure(error):
                completion(error)
            }
        }
    }

    /// Opens the shared copy: until it's here, the window shows what it has, and nothing can be changed.
    func connect() {
        phase = .connecting
        editor?.setAccess(.locked)
        updateState()
        connectChannel()
    }

    private func connectChannel() {
        let channel = controller.service.connect(id, owner: isOwner ? nil : ownerID, delegate: self)
        self.channel = channel
        channel.start()
    }

    private func goLive() {
        guard phase != .ended, let editor else { return }
        phase = .live
        for stream in Stream.allCases {
            guard let storage = storage(stream) else { continue }
            storage.coder = coder
            storage.onEdit = { [weak self] edit in self?.recorded(edit, in: stream) }
            storage.isRecording = true
        }
        document?.onCommentsChange = { [weak self] old in self?.commentsChanged(from: old) }
        document?.onPageSetupEdited = { [weak self] in self?.pageSetupEdited() }
        editor.usesSharedUndo = true
        document?.undoManager?.removeAllActions()
        applyPermission()
        announcePresence(viewing: true)
        // A file of this person's renamed while it was closed: everyone gets its new name.
        titleChanged()
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.announcePresence(viewing: true)
                self.state?.clock = Date()
            }
        }
        updateState()
        flush()
    }

    /// Stops taking part: the channel closes, the text stops recording and undo goes back to the text views.
    func end(saying presenceEnds: Bool = true) {
        guard phase != .ended else { return }
        sendNotice()
        if presenceEnds { announcePresence(viewing: false) }
        phase = .ended
        channel?.stop()
        channel = nil
        heartbeat?.invalidate()
        heartbeat = nil
        snapshotWork?.cancel()
        noticeWork?.cancel()
        gapCheck?.cancel()
        gapCheck = nil
        for stream in Stream.allCases {
            storage(stream)?.isRecording = false
            storage(stream)?.onEdit = nil
        }
        document?.onCommentsChange = nil
        document?.onPageSetupEdited = nil
        editor?.usesSharedUndo = false
        undoEntries = []
        redoEntries = []
        document?.undoManager?.removeAllActions()
    }

    /// The owner renamed the document: its name in iCloud follows, and with it the name everyone else sees.
    func titleChanged() {
        guard isOwner, phase == .live else { return }
        channel?.setTitle(title)
    }

    /// Tells the others whether this person has the document open, and who they are in it.
    private func announcePresence(viewing: Bool) {
        channel?.setPresence(viewing: viewing, isOwner: isOwner, permission: isOwner ? .edit : (sharing?.myPermission ?? .comment))
    }

    /// The window is closing: everyone's told this person has gone.
    func close() {
        end()
        controller.unregister(self)
    }

    private func applyPermission() {
        guard let editor else { return }
        switch phase {
        case .connecting: editor.setAccess(.locked)
        case .ended: break
        case .live: editor.setAccess(blocked != nil ? .offline : (canEdit ? .full : .commentOnly))
        }
    }

    // MARK: Changes made here

    private func recorded(_ edit: RecordedEdit, in stream: Stream) {
        guard phase == .live, !isApplyingRemote, let client else { return }
        // Someone who may only comment never changes the text; anything AppKit does to it here stays here.
        guard canEdit else { return }
        var change = DocumentChange()
        switch stream {
        case .body:
            change.body = edit.change
            tally.recordText(inserted: edit.inserted, deleted: edit.deleted, restyled: edit.restyled)
        case .header:
            change.header = edit.change
            tally.recordHeaderOrFooter()
        case .footer:
            change.footer = edit.change
            tally.recordHeaderOrFooter()
        }
        client.local(change)
        registerUndo(edit, in: stream)
        noteLocalAction()
        flush()
    }

    private func pageSetupEdited() {
        guard phase == .live, !isApplyingRemote, canEdit, let client, let setup = document?.pageSetup else { return }
        client.local(DocumentChange(pageSetup: setup))
        tally.recordPageSetup()
        noteLocalAction()
        flush()
    }

    /// Sends the next change, if one's waiting and none is on its way; not while text is being composed (an accent,
    /// an input method), which ends in a change of its own.
    func flush() {
        guard phase == .live, let client, let channel else { return }
        if editor?.activeTextView.hasMarkedText() == true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.flush() }
            return
        }
        guard let next = client.nextToSend() else {
            updateState()
            return
        }
        updateState()
        channel.claim(next) { [weak self] result in
            guard let self, let client = self.client else { return }
            switch result {
            case .claimed:
                client.sent(next.id)
                markOnline()
                afterConfirm()
            case let .taken(existing):
                apply(client.sendTaken(next.id, by: existing))
                lookForGap()
                markOnline()
            case .notAllowed:
                client.sendFailed(next.id)
                lostEditing()
                return
            case let .failed(error):
                client.sendFailed(next.id)
                markOffline(because: error)
                return
            }
            flush()
        }
    }

    /// A change went in: whatever kept the window from being changed is over.
    private func markOnline() {
        retryDelay = 1
        guard blocked != nil else { return }
        blocked = nil
        cameBack()
    }

    /// Sending failed: the window stops taking changes, saying why, and the change is tried again in a while, longer
    /// each time. (It was made while iCloud could still be reached; it goes in, merged, once it can be again.)
    private func markOffline(because error: Error) {
        block(isConnectionProblem(error) ? .offline : .refused(error.localizedDescription))
        guard !retryScheduled else { return }
        retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
            guard let self else { return }
            retryScheduled = false
            flush()
        }
        retryDelay = min(retryDelay * 2, 30)
    }

    /// Changes can't be saved to iCloud: the window stops taking any, and says why, until they can again. It's still
    /// looked at for others' changes, more often, so it knows as soon as iCloud's back.
    private func block(_ reason: Blocked) {
        guard blocked != reason else { return }
        blocked = reason
        channel?.pollInterval = 5
        applyPermission()
        updateState()
        explainOffline()
    }

    /// Says in the window why it can't be changed just now (again, when someone tries).
    func explainOffline() {
        guard let blocked else { return }
        let banner = switch (blocked, phase) {
        case (.offline, .connecting):
            "You’re offline, so “\(title)” can’t be opened from iCloud yet. It opens as soon as iCloud can be reached."
        case (.offline, _):
            "You’re offline, so changes to “\(title)” can’t be saved. You can still read it, print it or save a copy, and editing comes back as soon as iCloud can be reached."
        case let (.refused(reason), _):
            "Changes to “\(title)” can’t be saved to iCloud right now (\(reason)). You can still read it, print it or save a copy."
        }
        blockedBanner = banner
        windowController?.state.banner = banner
    }

    /// Changes can be saved again: the window takes them, catches up with what others did meanwhile, and its own
    /// message about it goes.
    private func cameBack() {
        if let banner = windowController?.state.banner, banner == blockedBanner { windowController?.state.banner = nil }
        blockedBanner = nil
        applyPermission()
        updateState()
        titleChanged()
        channel?.fetchSoon()
        flush()
    }

    /// iCloud turned a change down: this person may no longer edit. Their changes not yet in go; the text is put back
    /// as the log has it.
    private func lostEditing() {
        windowController?.state.banner = "You can no longer edit “\(title)”, only comment on it. Your latest changes weren’t kept."
        channel?.fetchSoon()
    }

    // MARK: Changes from others

    private func apply(_ changes: [DocumentChange]) {
        guard !changes.isEmpty else { return }
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        for change in changes {
            moveUndo(around: change)
            for stream in Stream.allCases {
                let delta: TextDelta = switch stream {
                case .body: change.body
                case .header: change.header
                case .footer: change.footer
                }
                if !delta.ops.isEmpty { applyRemote(delta, to: stream) }
            }
            if let setup = change.pageSetup { document?.pageSetup = setup }
        }
        editor?.comments.scheduleReload()
        anchorWaitingComments()
    }

    private func applyRemote(_ delta: TextDelta, to stream: Stream) {
        guard let storage = storage(stream), let editor else { return }
        // The caret and selection stay on the same text; text inserted right at the caret goes after it.
        let view: NSTextView? = stream == .body ? editor.activeTextView : editor.editingHeaderFooterView.flatMap { $0.textStorage === storage ? $0 : nil }
        let selections = view?.selectedRanges.map(\.rangeValue)
        storage.isRecording = false
        let applied = coder.apply(delta, to: storage)
        storage.isRecording = true
        if !applied {
            // The change doesn't fit the text here: start over from iCloud's copy.
            channel?.fetchSoon()
            return
        }
        if let view, let selections {
            let moved = selections.map { range -> NSValue in
                let start = delta.transformPosition(range.location, priority: true)
                let end = range.length == 0 ? start : max(start, delta.transformPosition(NSMaxRange(range), priority: true))
                return NSValue(range: NSRange(location: min(start, storage.length), length: min(end, storage.length) - min(start, storage.length)))
            }
            view.setSelectedRanges(moved, affinity: .downstream, stillSelecting: false)
        }
        if stream == .body { keepCommentsWhole(around: delta, in: storage) }
    }

    /// Text inserted inside a comment's text joins the comment, as it does when typed here.
    private func keepCommentsWhole(around delta: TextDelta, in storage: RecordingTextStorage) {
        var index = 0
        for op in delta.ops {
            switch op {
            case let .insert(text, _):
                if index > 0, index + text.count < storage.length {
                    let before = CommentAnchors.ids(storage.attribute(.pdComments, at: index - 1, effectiveRange: nil))
                    let after = CommentAnchors.ids(storage.attribute(.pdComments, at: index + text.count, effectiveRange: nil))
                    let shared = before.filter(after.contains)
                    if !shared.isEmpty {
                        storage.isRecording = false
                        storage.addAttribute(.pdComments, value: CommentAnchors.value(shared)!, range: NSRange(location: index, length: text.count))
                        storage.isRecording = true
                    }
                }
                index += text.count
            case let .retain(count, _):
                index += count
            case .delete:
                break
            }
        }
    }

    // MARK: Undo

    /// Whether a recorded round was a keystroke: a short insert, or a deletion of a character or two, in one place.
    private func typing(_ edit: RecordedEdit) -> (location: Int, length: Int, deletes: Bool)? {
        guard edit.restyled == 0 else { return nil }
        if edit.deleted.isEmpty, edit.inserted.count == 1, let insert = edit.inserted.first, insert.text.length <= 4,
           !insert.text.string.contains(where: \.isNewline) {
            return (insert.location, insert.text.length, false)
        }
        if edit.inserted.isEmpty, edit.deleted.count == 1, let delete = edit.deleted.first, delete.text.length <= 2 {
            return (delete.location, delete.text.length, true)
        }
        return nil
    }

    private func registerUndo(_ edit: RecordedEdit, in stream: Stream) {
        guard let undoManager = document?.undoManager, undoManager.isUndoRegistrationEnabled else { return }
        let undoing = undoManager.isUndoing
        let redoing = undoManager.isRedoing
        let keystroke = undoing || redoing ? nil : typing(edit)
        if let keystroke, let entry = typingEntry, entry === undoEntries.last, entry.stream == stream, !isTypingBroken,
           keystroke.deletes == typingDeletes,
           keystroke.deletes ? (keystroke.location + keystroke.length == typingEnd || keystroke.location == typingEnd) : keystroke.location == typingEnd {
            // Carries on the typing: one undo step for the run, as the text views make it.
            entry.delta = edit.inverse.compose(entry.delta)
            typingEnd = keystroke.deletes ? keystroke.location : keystroke.location + keystroke.length
            return
        }
        let entry = UndoEntry(stream: stream, delta: edit.inverse)
        undoManager.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated { session.perform(entry) }
        }
        if undoing {
            redoEntries.append(entry)
        } else if redoing {
            undoEntries.append(entry)
        } else {
            undoEntries.append(entry)
            redoEntries.removeAll()
        }
        if let keystroke {
            typingEntry = entry
            typingDeletes = keystroke.deletes
            typingEnd = keystroke.deletes ? keystroke.location : keystroke.location + keystroke.length
            isTypingBroken = false
            undoManager.setActionName("Typing")
        } else {
            typingEntry = nil
        }
        if undoEntries.count > 500 { undoEntries.removeFirst(undoEntries.count - 500) }
    }

    /// The next keystroke starts a new undo step.
    func breakTyping() { isTypingBroken = true }

    #if DEBUG
    /// What undo holds, for the self-test.
    var undoDescription: String {
        "undo \(undoEntries.count) [\(undoEntries.last.map { "\($0.delta.ops)" } ?? "-")] redo \(redoEntries.count) "
            + "manager canUndo \(document?.undoManager?.canUndo ?? false) name \(document?.undoManager?.undoActionName ?? "")"
    }
    #endif

    private func perform(_ entry: UndoEntry) {
        undoEntries.removeAll { $0 === entry }
        redoEntries.removeAll { $0 === entry }
        typingEntry = nil
        isTypingBroken = true
        guard phase == .live, canEdit, let storage = storage(entry.stream) else { return }
        // Made through the storage while it records: it goes to the others like any change of this Mac's, and what
        // takes it back again is registered for Redo.
        let location = entry.delta.ops.first.map { op -> Int in if case let .retain(count, attributes) = op, attributes.isEmpty { count } else { 0 } } ?? 0
        guard coder.apply(entry.delta, to: storage) else { return }
        if entry.stream == .body, let view = editor?.activeTextView {
            view.setSelectedRange(NSRange(location: min(location + max(0, entry.delta.lengthChange), storage.length), length: 0))
            view.scrollRangeToVisible(view.selectedRange())
        }
    }

    /// Other people's change came in: each undo step of this Mac's is rewritten to follow it, the newest first.
    private func moveUndo(around change: DocumentChange) {
        isTypingBroken = true
        for stream in Stream.allCases {
            let remote: TextDelta = switch stream {
            case .body: change.body
            case .header: change.header
            case .footer: change.footer
            }
            guard !remote.ops.isEmpty else { continue }
            for list in [undoEntries, redoEntries] {
                var moving = remote
                for entry in list.reversed() where entry.stream == stream {
                    let moved = moving.transform(entry.delta, priority: true)
                    moving = entry.delta.transform(moving, priority: false)
                    entry.delta = moved
                }
            }
        }
    }

    // MARK: Snapshots

    private func makeSnapshot(revision: Int) -> SyncSnapshot {
        let body = document?.textStorage ?? NSTextStorage()
        let known = Set((document?.comments ?? []).map(\.id))
        return SyncSnapshot(revision: revision, body: coder.insertion(of: body),
                            header: coder.insertion(of: document?.headerStorage ?? NSTextStorage()),
                            footer: coder.insertion(of: document?.footerStorage ?? NSTextStorage()),
                            pageSetup: document?.pageSetup ?? .localeDefault,
                            anchors: CommentAnchors.ranges(in: body).filter { known.contains($0.key) })
    }

    /// After changes go in: now and then, when everything here is in, a snapshot for people joining to start from.
    private func afterConfirm() {
        updateState()
        guard canEdit, let client, !client.hasPending, client.revision > lastSnapshotRevision else { return }
        snapshotWork?.cancel()
        if client.revision - lastSnapshotRevision >= 100 {
            saveSnapshot()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.saveSnapshot() }
        snapshotWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    private func saveSnapshot() {
        guard phase == .live, canEdit, let client, !client.hasPending, client.revision > lastSnapshotRevision else { return }
        lastSnapshotRevision = client.revision
        channel?.saveSnapshot(makeSnapshot(revision: client.revision), title: title)
    }

    /// Starts from a snapshot: the text, header, footer and page setup become iCloud's, and changes go on from its
    /// revision.
    private func load(_ snapshot: SyncSnapshot) {
        guard let document else { return }
        isApplyingRemote = true
        // Comments come from iCloud too: the ones a file of this person's kept may be out of date.
        document.comments = []
        for (stream, delta) in [(Stream.body, snapshot.body), (.header, snapshot.header), (.footer, snapshot.footer)] {
            guard let storage = storage(stream) else { continue }
            storage.isRecording = false
            if let text = coder.text(from: delta) {
                storage.beginEditing()
                storage.setAttributedString(text)
                storage.endEditing()
            }
        }
        document.pageSetup = snapshot.pageSetup
        for (thread, range) in snapshot.anchors where NSMaxRange(range) <= document.textStorage.length {
            CommentAnchors.add(thread, to: document.textStorage, range: range)
        }
        isApplyingRemote = false
        lastSnapshotRevision = snapshot.revision
        if let client {
            client.reset(to: snapshot.revision)
        } else {
            client = SyncClient(revision: snapshot.revision, author: me?.id ?? "me", authorName: me?.name ?? NSFullUserName())
        }
        undoEntries = []
        redoEntries = []
        document.undoManager?.removeAllActions()
        editor?.refreshAfterLoading()
    }

    // MARK: Comments

    /// Where a thread's text is in the log, at its latest revision.
    private func anchor(of threadID: String, revision: Int, logPosition: (Int) -> Int) -> CommentAnchor? {
        guard let storage = document?.textStorage, let range = CommentAnchors.ranges(in: storage)[threadID] else { return nil }
        let start = logPosition(range.location)
        let end = logPosition(NSMaxRange(range))
        let quote = (storage.string as NSString).substring(with: range)
        return CommentAnchor(revision: revision, location: start, length: max(0, end - start), quote: String(quote.prefix(200)))
    }

    private func currentAnchor(of threadID: String) -> CommentAnchor? {
        guard let client else { return nil }
        return anchor(of: threadID, revision: client.revision, logPosition: client.logPosition)
    }

    private func commentsChanged(from old: [CommentThread]) {
        guard phase == .live, !isApplyingRemote, let document, let channel else { return }
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let now = Dictionary(document.comments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for thread in document.comments where before[thread.id] != thread {
            let previous = before[thread.id]
            if previous == nil {
                tally.recordComment(thread.text)
            } else if let previous {
                let known = Set(previous.replies.map(\.id))
                for reply in thread.replies where !known.contains(reply.id) { tally.recordReply(reply.text) }
                if thread.resolved, !previous.resolved { tally.recordResolved() }
            }
            let anchor = serverComments[thread.id]?.anchor ?? currentAnchor(of: thread.id)
            let comment = SharedComment(thread: thread, anchor: anchor)
            serverComments[thread.id] = comment
            save(comment, base: previous, using: channel)
        }
        for id in before.keys where now[id] == nil {
            serverComments[id] = nil
            channel.deleteComment(id)
        }
        noteLocalAction()
    }

    /// Saves a thread to iCloud, trying again a few times, further apart, while it can't be reached.
    private func save(_ comment: SharedComment, base: CommentThread?, using channel: CollaborationChannel, attempt: Int = 0) {
        channel.save(comment, base: base) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(saved):
                // Someone else changed the thread meanwhile: theirs and ours, merged.
                if saved.thread != comment.thread { received([saved], deleted: []) }
            case .failure where attempt < 6:
                DispatchQueue.main.asyncAfter(deadline: .now() + pow(2, Double(attempt))) { [weak self] in
                    guard let self, phase == .live, let channel = self.channel,
                          document?.comments.first(where: { $0.id == comment.thread.id }) == comment.thread else { return }
                    save(comment, base: base, using: channel, attempt: attempt + 1)
                }
            case let .failure(error):
                windowController?.state.banner = "A comment couldn’t be saved to iCloud: \(error.localizedDescription)"
            }
        }
    }

    private func received(_ comments: [SharedComment], deleted: [String]) {
        guard let document else { return }
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        var threads = document.comments
        for comment in comments {
            serverComments[comment.thread.id] = comment
            if let index = threads.firstIndex(where: { $0.id == comment.thread.id }) {
                threads[index] = comment.thread
            } else {
                threads.append(comment.thread)
            }
            anchorIfNeeded(comment)
        }
        threads.removeAll { deleted.contains($0.id) }
        for id in deleted { serverComments[id] = nil }
        if threads != document.comments { document.comments = threads }
        editor?.comments.reload()
    }

    /// Marks a thread's text here, from where it was at its revision of the log.
    private func anchorIfNeeded(_ comment: SharedComment) {
        guard let storage = document?.textStorage, CommentAnchors.ranges(in: storage)[comment.thread.id] == nil,
              let anchor = comment.anchor, let client else { return }
        if anchor.revision > client.revision {
            waitingAnchors[comment.thread.id] = comment
            let id = comment.thread.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.anchorByQuote(id) }
            return
        }
        waitingAnchors[comment.thread.id] = nil
        var range: NSRange?
        if let start = client.position(anchor.location, at: anchor.revision, priority: false),
           let end = client.position(anchor.location + anchor.length, at: anchor.revision, priority: true), end > start {
            range = NSRange(location: start, length: end - start)
        } else if !anchor.quote.isEmpty {
            // The changes since can't be followed here: find the text it was on.
            let found = (storage.string as NSString).range(of: anchor.quote)
            if found.location != NSNotFound { range = found }
        }
        guard let range, NSMaxRange(range) <= storage.length else { return }
        storage.isRecording = false
        storage.beginEditing()
        CommentAnchors.add(comment.thread.id, to: storage, range: range)
        storage.endEditing()
        storage.isRecording = true
    }

    private func anchorWaitingComments() {
        for comment in waitingAnchors.values { anchorIfNeeded(comment) }
    }

    /// A thread whose revision of the log is slow to come: shown meanwhile on the text it quotes, when that's here.
    private func anchorByQuote(_ id: String) {
        guard let comment = waitingAnchors[id], let storage = document?.textStorage, CommentAnchors.ranges(in: storage)[id] == nil,
              let quote = comment.anchor?.quote, !quote.isEmpty else { return }
        let found = (storage.string as NSString).range(of: quote)
        guard found.location != NSNotFound else { return }
        waitingAnchors[id] = nil
        storage.isRecording = false
        storage.beginEditing()
        CommentAnchors.add(id, to: storage, range: found)
        storage.endEditing()
        storage.isRecording = true
        editor?.comments.reload()
    }

    // MARK: Telling the others

    private func noteLocalAction() {
        noticeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sendNotice() }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noticeDelay, execute: work)
    }

    /// Sends what's changed since the others were last told, to everyone else who's joined.
    func sendNotice() {
        noticeWork?.cancel()
        noticeWork = nil
        defer { tally = ChangeTally() }
        guard let me, let notice = tally.notice(author: me.name, documentTitle: title) else { return }
        let others = (sharing?.collaborators ?? []).filter { $0.id != me.id && $0.status == .joined }.map(\.id)
        guard !others.isEmpty else { return }
        channel?.sendNotice(title: notice.title, body: notice.body, to: others)
        controller.noticeSent(title: notice.title, body: notice.body, document: id, to: others)
    }

    // MARK: The header

    private func updateState() {
        guard let state else { return }
        state.isShared = phase != .ended
        state.isOwner = isOwner
        state.meID = me?.id
        if let sharing {
            let people = named(sharing.collaborators)
            state.collaborators = people
            state.permission = sharing.myPermission
            state.ownerName = people.first(where: \.isOwner)?.displayName ?? sharing.owner.displayName
        } else if let info {
            state.ownerName = info.ownerName
        }
        switch phase {
        case .connecting:
            if blocked == .offline {
                state.statusText = "Offline · It opens when iCloud can be reached"
                state.statusSymbol = "icloud.slash"
            } else {
                state.statusText = "Opening the shared copy from iCloud…"
                state.statusSymbol = "icloud.and.arrow.down"
            }
        case .ended:
            state.statusText = "No longer shared"
            state.statusSymbol = "icloud.slash"
        case .live:
            if let blocked {
                state.statusText = blocked == .offline ? "Offline · Changes can’t be saved until iCloud can be reached"
                    : "Changes can’t be saved to iCloud right now"
                state.statusSymbol = blocked == .offline ? "icloud.slash" : "exclamationmark.icloud"
            } else if client?.hasPending == true {
                state.statusText = "Saving to iCloud…"
                state.statusSymbol = "arrow.triangle.2.circlepath.icloud"
            } else if !canEdit {
                state.statusText = isOwner ? "Saved in iCloud" : "Shared by \(state.ownerName) · You can comment"
                state.statusSymbol = "icloud"
            } else {
                state.statusText = isOwner ? "Saved in iCloud" : "Shared by \(state.ownerName) · Saved in iCloud"
                state.statusSymbol = "checkmark.icloud"
            }
        }
    }

    /// The people in the share, named where iCloud doesn't say who they are: the owner as the document names them,
    /// anyone else as they name themselves when they open it.
    private func named(_ people: [Collaborator]) -> [Collaborator] {
        let presence = state?.presence ?? [:]
        var people = people
        for index in people.indices where people[index].name.isEmpty {
            if let seen = presence[people[index].id] {
                people[index].name = seen.info.name
            } else if people[index].isOwner, let owner = info?.ownerName, !owner.isEmpty {
                people[index].name = owner
            }
        }
        // One person iCloud says nothing about, and one person who opened it whom iCloud lists under no identity of
        // theirs: the same person.
        let listed = Set(people.map(\.id))
        let unlisted = presence.values.filter { $0.person != me?.id && !listed.contains($0.person) }
        let nameless = people.indices.filter {
            people[$0].name.isEmpty && people[$0].address == nil && people[$0].id != me?.id && people[$0].status == .joined
        }
        if nameless.count == 1, unlisted.count == 1, let only = unlisted.first { people[nameless[0]].name = only.info.name }
        return people
    }

    /// The owner changed how it's shared, from the sharing sheet.
    func sharingUpdated(_ sharing: DocumentSharing) {
        self.sharing = sharing
        applyPermission()
        updateState()
    }
}

// MARK: - The channel

extension DocumentCollaboration: CollaborationChannelDelegate {
    func channel(_ channel: CollaborationChannel, loaded snapshot: SyncSnapshot, info: SharedDocumentInfo) {
        self.info = info
        if !isOwner, let document, document.sharedCopy?.title != info.title {
            document.sharedCopy?.title = info.title
            windowController?.updateStatus()
        }
        // A Mac that's following the log needs no snapshot; one starting, or one so far behind that the changes it's
        // missing are gone, starts from it.
        if let client, phase == .live, client.revision >= snapshot.revision || !client.isMissingChanges { return }
        let catchingUp = phase == .live
        if catchingUp, let client, client.hasPending {
            // What's waiting to go was made on text the snapshot moves past, so it can't follow.
            client.discardPending()
            windowController?.state.banner = "Your latest changes to “\(title)” couldn’t be kept while it caught up with iCloud."
        }
        load(snapshot)
        if catchingUp { restoreComments() }
        let early = earlyChanges
        earlyChanges = []
        // With the changes that came ahead of the ones the snapshot now covers.
        if let client { apply(client.receive(early)) }
        if phase == .connecting { goLive() }
        lookForGap()
    }

    func channel(_ channel: CollaborationChannel, received changes: [LoggedChange]) {
        guard let client, phase == .live else {
            earlyChanges += changes
            return
        }
        apply(client.receive(changes))
        lookForGap()
        afterConfirm()
        flush()
    }

    /// Changes came ahead of one that hasn't (iCloud passed over it while reading, say). If it still hasn't a moment
    /// later, it's asked for by name, and failing that the document starts again from its latest snapshot; until then
    /// nothing after it can be shown.
    private func lookForGap() {
        guard phase == .live, client?.missingRevisions != nil else {
            gapCheck?.cancel()
            gapCheck = nil
            gapDelay = 1
            return
        }
        guard gapCheck == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            gapCheck = nil
            guard phase == .live, let missing = self.client?.missingRevisions else { return lookForGap() }
            collaborationLog.notice("Asking again for changes \(missing.lowerBound)–\(missing.upperBound)")
            channel?.fetchChanges(missing)
            gapDelay = min(gapDelay * 2, 60)
            lookForGap()
        }
        gapCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + gapDelay, execute: work)
    }

    /// After starting over from a snapshot: the comment threads as iCloud last had them, back on their text.
    private func restoreComments() {
        guard let document else { return }
        isApplyingRemote = true
        let threads = serverComments.values.map(\.thread).sorted { $0.date < $1.date }
        if document.comments != threads { document.comments = threads }
        isApplyingRemote = false
        for comment in serverComments.values { anchorIfNeeded(comment) }
        editor?.comments.reload()
    }

    func channel(_ channel: CollaborationChannel, retitled title: String) {
        info?.title = title
        guard !isOwner, let document, document.sharedCopy?.title != title else { return }
        document.sharedCopy?.title = title
        windowController?.synchronizeWindowTitleWithDocumentName()
    }

    func channel(_ channel: CollaborationChannel, receivedComments comments: [SharedComment], deleted: [String]) {
        received(comments, deleted: deleted)
    }

    func channel(_ channel: CollaborationChannel, receivedPresence presence: [Presence]) {
        guard let state else { return }
        for item in presence { state.presence[item.person] = item }
        state.clock = Date()
        updateState()
        let othersActive = state.presence.values.contains { $0.person != me?.id && $0.isActive() }
        channel.pollInterval = othersActive ? 2 : 15
    }

    func channel(_ channel: CollaborationChannel, sharingChanged sharing: DocumentSharing) {
        let couldEdit = canEdit
        self.sharing = sharing
        if phase == .live {
            applyPermission()
            if couldEdit != canEdit { announcePresence(viewing: true) }
            if couldEdit != canEdit, !isOwner {
                windowController?.state.banner = canEdit
                    ? "\(sharing.owner.displayName) changed your access: you can now edit “\(title)”."
                    : "\(sharing.owner.displayName) changed your access: you can now comment on “\(title)”, but not change it."
            }
        }
        updateState()
    }

    func channel(_ channel: CollaborationChannel, reachable: Bool) {
        if reachable {
            // iCloud answers again. (A change it turned down is over only when one goes in.)
            if blocked == .offline { markOnline() }
        } else {
            block(.offline)
        }
    }

    func channel(_ channel: CollaborationChannel, becameUnavailable reason: UnavailableReason) {
        guard phase != .ended else { return }
        let ownerName = sharing?.owner.displayName ?? info?.ownerName ?? "The owner"
        end(saying: false)
        updateState()
        if isOwner {
            controller.sharingEnded(self)
        } else {
            controller.documentWentAway(self, ownerName: ownerName, reason: reason)
        }
    }
}
