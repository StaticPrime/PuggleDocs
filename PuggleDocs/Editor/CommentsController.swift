import AppKit
import Observation
import PuggleDocsKit
import SwiftUI

/// The name shown on comments written in this app.
enum CommentAuthor {
    static let key = "PDCommentAuthor"

    static var name: String {
        get {
            if let saved = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
                return saved
            }
            let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
            return full.isEmpty ? "Me" : full
        }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: key) }
    }
}

/// What the comment cards and the comment history show.
@Observable
final class CommentsModel {
    struct Draft: Equatable {
        var range: NSRange
        var text = ""
    }

    enum Editing: Equatable {
        case thread(String)
        case reply(thread: String, reply: String)
    }

    var threads: [CommentThread] = []
    /// Ids of the threads anchored in the text, in document order.
    var order: [String] = []
    /// A short quote of each anchored thread's text.
    var excerpts: [String: String] = [:]
    var activeID: String?
    /// Suggestions in the text, in document order, and the one whose card is open.
    var suggestions: [SuggestionSummary] = []
    var activeSuggestion: String?
    var draft: Draft?
    var replyText = ""
    var editing: Editing?
    var editText = ""
    var showsHistory = false
    var authorName = CommentAuthor.name
    /// False in Viewing mode.
    var canComment = true

    func thread(_ id: String) -> CommentThread? { threads.first { $0.id == id } }

    /// Anchored threads in document order, then any whose text was deleted.
    var historyThreads: [CommentThread] {
        let anchored = order.compactMap(thread)
        return anchored + threads.filter { !order.contains($0.id) }
    }
}

/// Comment cards beside the pages, comment highlights in the text, and the commands that change comments.
///
/// Cards live inside the zoomed canvas so they scroll with the pages, but each card's bounds cancel
/// the zoom: they stay the same size and draw sharply at every zoom level.
final class CommentsController {
    /// Card width and the spacing of the column, in screen points.
    static let cardWidth: CGFloat = 256
    static let shadowPadding: CGFloat = 6
    static let columnInset: CGFloat = 28
    static let activeInset: CGFloat = 10
    static let columnTrailing: CGFloat = 24
    static let spacing: CGFloat = 10
    static let draftKey = "draft"
    static let suggestionPrefix = "s:"

    let model = CommentsModel()
    private unowned let editor: EditorController
    private var hosts: [String: NSView] = [:]
    private var addButton: NSView?
    private var anchors: [String: NSRange] = [:]
    private var layoutScheduled = false
    private var animateNextLayout = false
    private var reloadScheduled = false
    private var warnedAboutFormat = false

    init(editor: EditorController) {
        self.editor = editor
        reload()
    }

    private var undoManager: UndoManager? { editor.undoManager }
    private var storage: NSTextStorage { editor.textStorage }

    // MARK: Model

    func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.reloadScheduled = false
            self?.reload()
        }
    }

    /// Re-reads the threads and their anchors after the document or its text changed.
    func reload() {
        let threads = editor.document?.comments ?? []
        anchors = CommentAnchors.ranges(in: storage)
        let string = storage.string as NSString
        let order = threads.map(\.id).filter { anchors[$0] != nil }.sorted { anchors[$0]!.location < anchors[$1]!.location }
        var excerpts: [String: String] = [:]
        for id in order { excerpts[id] = Self.excerpt(string.substring(with: anchors[id]!)) }
        if model.threads != threads { model.threads = threads }
        if model.order != order { model.order = order }
        if model.excerpts != excerpts { model.excerpts = excerpts }
        let suggestions = Suggestions.summaries(in: storage)
        if model.suggestions != suggestions { model.suggestions = suggestions }
        if let active = model.activeSuggestion, !suggestions.contains(where: { $0.id == active }) { model.activeSuggestion = nil }
        let canComment = editor.state.canComment
        if model.canComment != canComment { model.canComment = canComment }
        if let active = model.activeID, !isShown(active) { model.activeID = nil }
        if let draft = model.draft, NSMaxRange(draft.range) > storage.length { model.draft = nil }
        updateHighlights()
        scheduleLayout()
    }

    static func excerpt(_ text: String) -> String {
        let words = text.replacingOccurrences(of: "\u{FFFC}", with: "").split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let joined = words.joined(separator: " ")
        return joined.count > 140 ? String(joined.prefix(140)) + "…" : joined
    }

    /// Open, anchored threads get a card and a highlight (none in Viewing mode).
    func isShown(_ id: String) -> Bool {
        guard model.canComment, let thread = model.thread(id) else { return false }
        return !thread.resolved && anchors[id] != nil
    }

    private func updateHighlights() {
        let layoutManager = editor.layoutManager
        let highlighted = Set(model.order.filter(isShown))
        let active = model.activeID.flatMap { isShown($0) ? $0 : nil }
        let draft = model.canComment ? model.draft?.range : nil
        let suggestion = model.canComment ? model.suggestions.first { $0.id == model.activeSuggestion } : nil
        guard layoutManager.highlightedComments != highlighted || layoutManager.activeComment != active
                || layoutManager.draftCommentRange != draft || layoutManager.activeSuggestionRange != suggestion?.range else { return }
        layoutManager.highlightedComments = highlighted
        layoutManager.activeComment = active
        layoutManager.draftCommentRange = draft
        layoutManager.activeSuggestionRange = suggestion?.range
        layoutManager.activeSuggestionColor = suggestion.map { AuthorColors.color(for: $0.author) }
        editor.textViews.forEach { $0.needsDisplay = true }
    }

    /// Replaces the document's threads, with undo. Undo takes back only what this change did to each thread it
    /// touched, so that in a shared document what other people did meanwhile (a reply, a thread of their own) stays.
    func setThreads(_ threads: [CommentThread], actionName: String?) {
        guard let document = editor.document else { return }
        let before = Dictionary(document.comments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(threads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let steps = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.map { (id: $0, before: before[$0], after: after[$0]) }
        document.comments = threads
        registerUndo(steps)
        if let actionName { undoManager?.setActionName(actionName) }
        reload()
    }

    private func registerUndo(_ steps: [(id: String, before: CommentThread?, after: CommentThread?)]) {
        guard !steps.isEmpty else { return }
        undoManager?.registerUndo(withTarget: self) { controller in
            controller.revert(steps)
        }
    }

    /// Takes back each step's change to its thread, as the thread is now.
    private func revert(_ steps: [(id: String, before: CommentThread?, after: CommentThread?)]) {
        guard let document = editor.document else { return }
        var threads = document.comments
        var redo: [(id: String, before: CommentThread?, after: CommentThread?)] = []
        for step in steps {
            let index = threads.firstIndex { $0.id == step.id }
            let current = index.map { threads[$0] }
            let reverted = Self.revert(current, from: step.after, to: step.before)
            redo.append((step.id, current, reverted))
            switch (index, reverted) {
            case let (index?, thread?): threads[index] = thread
            case let (index?, nil): threads.remove(at: index)
            case let (nil, thread?): threads.append(thread)
            case (nil, nil): break
            }
        }
        if threads != document.comments { document.comments = threads }
        registerUndo(redo)
        reload()
    }

    /// `current` with the change from `before` to `after` taken back, leaving the rest of it as it is now.
    static func revert(_ current: CommentThread?, from after: CommentThread?, to before: CommentThread?) -> CommentThread? {
        // A thread the change made goes; one it deleted comes back.
        guard let before else { return nil }
        guard let after, var thread = current else { return before }
        if after.text != before.text { thread.text = before.text }
        if after.resolved != before.resolved { thread.resolved = before.resolved }
        let beforeIDs = Set(before.replies.map(\.id))
        let afterIDs = Set(after.replies.map(\.id))
        thread.replies.removeAll { afterIDs.contains($0.id) && !beforeIDs.contains($0.id) }
        for reply in before.replies {
            if !afterIDs.contains(reply.id) {
                if !thread.replies.contains(where: { $0.id == reply.id }) { thread.replies.append(reply) }
            } else if let edited = after.replies.first(where: { $0.id == reply.id }), edited.text != reply.text,
                      let index = thread.replies.firstIndex(where: { $0.id == reply.id }) {
                thread.replies[index].text = reply.text
            }
        }
        thread.replies.sort { $0.date < $1.date }
        return thread
    }

    private func update(_ id: String, actionName: String, _ change: (inout CommentThread) -> Void) {
        guard var threads = editor.document?.comments, let index = threads.firstIndex(where: { $0.id == id }) else { return }
        change(&threads[index])
        setThreads(threads, actionName: actionName)
    }

    // MARK: Commands

    /// Starts a new comment on the selection (or the word at the caret).
    func startDraft() {
        guard model.canComment, !editor.isEditingHeaderFooter else { return }
        let textView = editor.activeTextView
        var range = textView.selectedRange()
        if range.length == 0 { range = textView.selectionRange(forProposedRange: range, granularity: .selectByWord) }
        let string = storage.string as NSString
        while range.length > 0, NSMaxRange(range) <= string.length,
              CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(string.character(at: NSMaxRange(range) - 1)) ?? " ") {
            range.length -= 1
        }
        guard range.length > 0, NSMaxRange(range) <= storage.length else {
            NSSound.beep()
            return
        }
        model.editing = nil
        model.activeID = nil
        model.activeSuggestion = nil
        model.authorName = CommentAuthor.name
        // The selection gives way to the draft's highlight.
        textView.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
        model.draft = CommentsModel.Draft(range: range)
        textView.scrollRangeToVisible(range)
        updateHighlights()
        updateAddButton()
        scheduleLayout(animated: true)
    }

    func commitDraft() {
        guard let draft = model.draft else { return }
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let range = NSIntersectionRange(draft.range, NSRange(location: 0, length: storage.length))
        let textView = editor.textView(forCharacterAt: range.location) ?? editor.activeTextView
        guard range.length > 0 else {
            cancelDraft()
            return
        }
        let thread = CommentThread(author: CommentAuthor.name, authorID: editor.collaboration?.me?.id, text: text)
        undoManager?.beginUndoGrouping()
        textView.breakUndoCoalescing()
        if !editor.state.isEditable {
            // Someone who may only comment marks the text without changing it; the mark stays on this Mac.
            storage.beginEditing()
            CommentAnchors.add(thread.id, to: storage, range: range)
            storage.endEditing()
        } else if textView.shouldChangeText(in: range, replacementString: nil) {
            storage.beginEditing()
            CommentAnchors.add(thread.id, to: storage, range: range)
            storage.endEditing()
            textView.didChangeText()
        }
        setThreads((editor.document?.comments ?? []) + [thread], actionName: "Comment")
        undoManager?.endUndoGrouping()
        model.draft = nil
        model.activeID = thread.id
        reload()
        scheduleLayout(animated: true)
        warnIfFormatDropsReviewMarkup()
        editor.focus()
    }

    func cancelDraft() {
        guard model.draft != nil else { return }
        model.draft = nil
        updateHighlights()
        scheduleLayout(animated: true)
        editor.focus()
    }

    func activate(_ id: String?, reveal: Bool = false) {
        if model.activeID != id {
            model.activeID = id
            model.replyText = ""
            model.editing = nil
        }
        if id != nil { model.activeSuggestion = nil }
        if id != nil, model.draft?.text.isEmpty == true { model.draft = nil }
        updateHighlights()
        scheduleLayout(animated: true)
        if reveal, let id, let range = anchors[id], let textView = editor.textView(forCharacterAt: range.location) {
            textView.scrollRangeToVisible(range)
        }
    }

    func activateSuggestion(_ id: String?) {
        if model.activeSuggestion != id { model.activeSuggestion = id }
        if id != nil {
            model.activeID = nil
            model.replyText = ""
            model.editing = nil
            if model.draft?.text.isEmpty == true { model.draft = nil }
        }
        updateHighlights()
        scheduleLayout(animated: true)
    }

    func resolveSuggestion(_ id: String, accept: Bool) {
        if model.activeSuggestion == id { model.activeSuggestion = nil }
        editor.resolveSuggestions([id], accept: accept)
        editor.focus()
    }

    /// Shows a thread from the comment history: scrolls to its text and opens its card.
    func reveal(_ id: String) {
        model.showsHistory = false
        guard let range = anchors[id] else { return }
        if let textView = editor.textView(forCharacterAt: range.location) {
            editor.scrollView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: range.location, length: 0))
            textView.scrollRangeToVisible(range)
        }
        activate(isShown(id) ? id : nil)
    }

    func reply(to id: String) {
        let text = model.replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.replyText = ""
        let author = CommentAuthor.name
        let authorID = editor.collaboration?.me?.id
        update(id, actionName: "Reply") { $0.replies.append(CommentReply(author: author, authorID: authorID, text: text)) }
    }

    func setResolved(_ id: String, _ resolved: Bool) {
        if resolved, model.activeID == id { model.activeID = nil }
        update(id, actionName: resolved ? "Resolve Comment" : "Re-open Comment") { $0.resolved = resolved }
    }

    /// Asks first; undo brings the thread back.
    func delete(_ id: String) {
        guard let window = editor.scrollView.window else {
            remove(id)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete this comment thread?"
        alert.informativeText = "The comment and its replies will be deleted."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.remove(id) }
        }
    }

    /// Deletes a thread. Its anchor stays in the text (unused ids are ignored and never saved),
    /// so undo restores the thread exactly where it was.
    func remove(_ id: String) {
        guard let threads = editor.document?.comments else { return }
        if model.activeID == id { model.activeID = nil }
        setThreads(threads.filter { $0.id != id }, actionName: "Delete Comment")
    }

    func deleteReply(_ replyID: String, in id: String) {
        update(id, actionName: "Delete Reply") { thread in thread.replies.removeAll { $0.id == replyID } }
    }

    func beginEditing(_ editing: CommentsModel.Editing) {
        switch editing {
        case .thread(let id):
            model.editText = model.thread(id)?.text ?? ""
        case .reply(let id, let replyID):
            model.editText = model.thread(id)?.replies.first { $0.id == replyID }?.text ?? ""
        }
        model.editing = editing
    }

    func saveEdit() {
        guard let editing = model.editing else { return }
        let text = model.editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.editing = nil
        switch editing {
        case .thread(let id):
            update(id, actionName: "Edit Comment") { $0.text = text }
        case .reply(let id, let replyID):
            update(id, actionName: "Edit Reply") { thread in
                if let index = thread.replies.firstIndex(where: { $0.id == replyID }) { thread.replies[index].text = text }
            }
        }
    }

    func cancelEdit() { model.editing = nil }

    /// In a shared document, people edit only what they wrote (the owner, what was written before it was shared).
    func mayEdit(authorID: String?) -> Bool {
        guard let collaboration = editor.collaboration, let me = collaboration.me?.id else { return true }
        return authorID == me || (authorID == nil && collaboration.isOwner)
    }

    /// And delete what they wrote, or anything if they can edit the document.
    func mayDelete(authorID: String?) -> Bool { mayEdit(authorID: authorID) || editor.state.access == .full }

    func setAuthorName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        CommentAuthor.name = trimmed
        model.authorName = trimmed
    }

    /// Rich Text and plain text files have nowhere to keep comments or suggestions.
    func warnIfFormatDropsReviewMarkup() {
        guard !warnedAboutFormat, let document = editor.document, document.fileURL != nil,
              let format = document.format, !format.keepsReviewMarkup else { return }
        warnedAboutFormat = true
        editor.state.banner = "\(format == .rtf ? "Rich Text" : "Plain text") files can’t store comments or suggestions: comments won’t be kept and suggestions will be saved as accepted text. To keep them, use File ▸ Download ▸ Microsoft Word (.docx)."
    }

    // MARK: Editor events

    /// Keeps a comment being written on its text while the document changes underneath it.
    func textDidChange(editedRange: NSRange, delta: Int, charactersChanged: Bool) {
        if charactersChanged, let draft = model.draft {
            model.draft?.range = CommentAnchors.adjust(draft.range, editedRange: editedRange, delta: delta)
        }
        scheduleReload()
    }

    func modeDidChange() {
        if !editor.state.canComment {
            model.draft = nil
            model.activeID = nil
            model.activeSuggestion = nil
        }
        reload()
        updateAddButton()
    }

    /// Clicking into commented text opens its card; typing at a comment's edge doesn't extend it.
    func selectionDidChange() {
        let textView = editor.activeTextView
        let selection = textView.selectedRange()
        if textView.typingAttributes[.pdSuggestion] != nil {
            // New text gets its own suggestion mark (or none when editing).
            var typing = textView.typingAttributes
            typing[.pdSuggestion] = nil
            textView.typingAttributes = typing
        }
        if selection.length == 0 { trimTypingComments(textView, at: selection.location) }
        if model.canComment, editor.scrollView.window?.firstResponder is DocumentTextView {
            // Clicking back into the document drops an empty draft.
            if model.draft?.text.isEmpty == true {
                model.draft = nil
                scheduleLayout(animated: true)
            }
            // The caret opens the card of the comment it's in, or else of the suggestion it's in.
            let caret = selection.length == 0 ? selection.location : nil
            let comment = caret.flatMap(shownComment)
            let suggestion = comment == nil ? caret.flatMap(suggestion(at:)) : nil
            if comment != model.activeID || suggestion != model.activeSuggestion {
                if let suggestion {
                    activateSuggestion(suggestion)
                } else {
                    model.activeSuggestion = nil
                    activate(comment)
                }
            } else {
                updateHighlights()
            }
        }
        updateAddButton()
    }

    private func trimTypingComments(_ textView: NSTextView, at location: Int) {
        guard textView.typingAttributes[.pdComments] != nil else { return }
        let before = location > 0 ? CommentAnchors.ids(storage.attribute(.pdComments, at: location - 1, effectiveRange: nil)) : []
        let after = location < storage.length ? CommentAnchors.ids(storage.attribute(.pdComments, at: location, effectiveRange: nil)) : []
        var typing = textView.typingAttributes
        typing[.pdComments] = CommentAnchors.value(before.filter(after.contains))
        textView.typingAttributes = typing
    }

    private func suggestion(at location: Int) -> String? {
        (Suggestions.mark(at: location, in: storage) ?? Suggestions.mark(at: location - 1, in: storage))?.id
    }

    private func shownComment(at location: Int) -> String? {
        var ids: [String] = []
        if location < storage.length { ids = CommentAnchors.ids(storage.attribute(.pdComments, at: location, effectiveRange: nil)) }
        if ids.isEmpty, location > 0 { ids = CommentAnchors.ids(storage.attribute(.pdComments, at: location - 1, effectiveRange: nil)) }
        // The innermost comment wins.
        return ids.filter(isShown).min { (anchors[$0]?.length ?? .max) < (anchors[$1]?.length ?? .max) }
    }

    // MARK: Cards

    func scheduleLayout(animated: Bool = false) {
        animateNextLayout = animateNextLayout || animated
        guard !layoutScheduled else { return }
        layoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutScheduled = false
            let animated = self.animateNextLayout
            self.animateNextLayout = false
            self.layoutCards(animated: animated)
        }
    }

    private var magnification: CGFloat { max(editor.scrollView.magnification, 0.01) }

    /// The top of the line holding `location`, in canvas coordinates.
    private func lineTop(at location: Int) -> CGFloat? {
        let length = storage.length
        guard length > 0, location < length,
              let (textView, rect) = editor.rect(for: NSRange(location: location, length: 1)) else { return nil }
        return editor.canvas.convert(rect.origin, from: textView).y
    }

    private func layoutCards(animated: Bool) {
        let canvas = editor.canvas
        let scale = magnification
        var items: [(key: String, top: CGFloat, location: Int)] = []
        if model.canComment {
            for id in model.order where isShown(id) {
                guard let range = anchors[id], let top = lineTop(at: range.location) else { continue }
                items.append((id, top, range.location))
            }
            if let draft = model.draft, let top = lineTop(at: draft.range.location) {
                items.append((Self.draftKey, top, draft.range.location))
            }
            for suggestion in model.suggestions {
                guard let top = lineTop(at: min(suggestion.range.location, max(0, storage.length - 1))) else { continue }
                items.append((Self.suggestionPrefix + suggestion.id, top, suggestion.range.location))
            }
        }
        items.sort { $0.top != $1.top ? $0.top < $1.top : $0.location < $1.location }

        let gutter = items.isEmpty ? 0 : (Self.cardWidth + Self.columnInset + Self.columnTrailing) / scale
        if abs(canvas.rightGutter - gutter) > 0.5 { canvas.rightGutter = gutter }

        let keys = Set(items.map(\.key))
        for (key, host) in hosts where !keys.contains(key) {
            host.removeFromSuperview()
            hosts[key] = nil
        }
        for item in items where hosts[item.key] == nil {
            let host = makeHost(for: item.key)
            canvas.addSubview(host)
            hosts[item.key] = host
        }

        // Stack the cards in screen points: each wants to sit beside its text; the active card gets
        // its place and the others make room above and below it.
        let pad = Self.shadowPadding / scale
        let gap = Self.spacing / scale
        let sizes = items.map { Self.contentSize(of: hosts[$0.key]!) }
        let heights = sizes.map { max(0, $0.height / scale - 2 * pad) }
        var tops = items.map(\.top)
        let activeKey = model.draft != nil ? Self.draftKey : (model.activeID ?? model.activeSuggestion.map { Self.suggestionPrefix + $0 })
        let activeIndex = items.firstIndex { $0.key == activeKey }
        func pushDown(from start: Int) {
            guard start < tops.count, start > 0 else { return }
            for index in start..<tops.count { tops[index] = max(tops[index], tops[index - 1] + heights[index - 1] + gap) }
        }
        if let activeIndex {
            pushDown(from: activeIndex + 1)
            for index in stride(from: activeIndex - 1, through: 0, by: -1) {
                tops[index] = min(tops[index], tops[index + 1] - heights[index] - gap)
            }
        }
        if let first = tops.first, first < PageCanvasView.verticalPadding {
            tops[0] = PageCanvasView.verticalPadding
        }
        pushDown(from: 1)

        guard let pageRight = canvas.pages.first?.frame.maxX else { return }
        for (index, item) in items.enumerated() {
            guard let host = hosts[item.key] else { continue }
            let inset = index == activeIndex ? Self.activeInset : Self.columnInset
            let frame = NSRect(x: pageRight + inset / scale - pad, y: tops[index] - pad,
                               width: sizes[index].width / scale, height: sizes[index].height / scale)
            Self.place(host, frame: frame, size: sizes[index], animated: animated)
        }
        updateAddButton()
    }

    /// The SwiftUI content's size in screen points (cached by the hosting view until its content changes).
    static func contentSize(of host: NSView) -> NSSize {
        let size = host.intrinsicContentSize
        return size.width > 0 && size.height > 0 ? size : host.fittingSize
    }

    /// Sizes a card in canvas units while its contents keep their size in screen points.
    static func place(_ host: NSView, frame: NSRect, size: NSSize, animated: Bool) {
        let sameSize = abs(host.frame.width - frame.width) < 0.5 && abs(host.frame.height - frame.height) < 0.5
            && abs(host.bounds.width - size.width) < 0.5 && abs(host.bounds.height - size.height) < 0.5
        if animated, sameSize, host.frame.origin != frame.origin {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.allowsImplicitAnimation = true
                host.animator().setFrameOrigin(frame.origin)
            }
            return
        }
        host.frame = frame
        host.bounds = NSRect(origin: .zero, size: size)
    }

    private func makeHost(for key: String) -> NSView {
        let host: NSView
        if key == Self.draftKey {
            host = CanvasHostingView(rootView: CommentDraftCard(model: model, controller: self))
        } else if key.hasPrefix(Self.suggestionPrefix) {
            host = CanvasHostingView(rootView: SuggestionCard(suggestionID: String(key.dropFirst(Self.suggestionPrefix.count)),
                                                              model: model, controller: self))
        } else {
            host = CanvasHostingView(rootView: CommentCard(threadID: key, model: model, controller: self))
        }
        (host as? CanvasSizeReporting)?.onSizeChange = { [weak self] in self?.scheduleLayout() }
        return host
    }

    /// The round "Add comment" button beside a selection.
    func updateAddButton() {
        let textView = editor.activeTextView
        let selection = textView.selectedRange()
        let show = model.canComment && model.draft == nil && selection.length > 0 && !editor.isEditingHeaderFooter
            && editor.scrollView.window?.firstResponder is DocumentTextView
        guard show, let top = lineTop(at: selection.location), let pageRight = editor.canvas.pages.first?.frame.maxX else {
            addButton?.isHidden = true
            return
        }
        let button: NSView
        if let addButton {
            button = addButton
        } else {
            button = CanvasHostingView(rootView: AddCommentButton { [weak self] in self?.startDraft() })
            editor.canvas.addSubview(button)
            addButton = button
        }
        button.isHidden = false
        let scale = magnification
        let size = Self.contentSize(of: button)
        let frame = NSRect(x: pageRight + 8 / scale, y: top - 6 / scale, width: size.width / scale, height: size.height / scale)
        Self.place(button, frame: frame, size: size, animated: false)
        // Keep the button above the cards.
        if editor.canvas.subviews.last !== button {
            button.removeFromSuperview()
            editor.canvas.addSubview(button)
        }
    }
}

/// Reports SwiftUI size changes so the comment column can restack.
protocol CanvasSizeReporting: AnyObject {
    var onSizeChange: (() -> Void)? { get set }
}

/// A SwiftUI view placed in the document canvas.
final class CanvasHostingView<Content: View>: NSHostingView<Content>, CanvasSizeReporting {
    var onSizeChange: (() -> Void)?

    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = [.intrinsicContentSize]
        safeAreaRegions = []
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onSizeChange?()
    }

    override var mouseDownCanMoveWindow: Bool { false }
}
