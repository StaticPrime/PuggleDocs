#if DEBUG
import AppKit
import PuggleDocsKit

/// Stands in for iCloud in debug runs (`-PDStandInCloud YES`) and the self-test: shared documents kept in memory and
/// passed between the people in this process, this Mac's person and simulated ones (`StandInPerson`), each a moment
/// after it's sent, as iCloud would.
final class StandInCloud {
    static let shared = StandInCloud()
    static let me = Collaborator(id: "alex@example.com", name: "Alex Morgan", address: "alex@example.com", isOwner: true)

    static var isRequested: Bool {
        UserDefaults.standard.bool(forKey: "PDStandInCloud")
            || (UserDefaults.standard.bool(forKey: "PDSelfTest") && UserDefaults.standard.string(forKey: "PDSelfTestSuite") == "collaboration")
    }

    final class Document {
        let id: UUID
        var title: String
        var owner: Collaborator
        /// The owner first.
        var people: [Collaborator]
        var access: LinkAccess
        var linkPermission: CollaboratorPermission
        var snapshot: SyncSnapshot
        var changes: [Int: LoggedChange] = [:]
        var comments: [String: (comment: SharedComment, version: Int)] = [:]
        var deletedComments: [(id: String, version: Int)] = []
        var presence: [String: (presence: Presence, version: Int)] = [:]
        var version = 0
        var sharingVersion = 0

        init(id: UUID, title: String, owner: Collaborator, access: LinkAccess, linkPermission: CollaboratorPermission, snapshot: SyncSnapshot) {
            self.id = id
            self.title = title
            self.owner = owner
            people = [owner]
            self.access = access
            self.linkPermission = linkPermission
            self.snapshot = snapshot
        }

        func bump() -> Int {
            version += 1
            return version
        }
    }

    private(set) var documents: [UUID: Document] = [:]
    /// The names of the simulated people, by address, as iCloud would know them.
    var directory: [String: String] = [:]
    /// Notices left for people: who for, and what they said.
    private(set) var notices: [(to: String, title: String, body: String, document: UUID)] = []
    private var channels: [WeakChannel] = []
    private var services: [WeakService] = []
    var latency: TimeInterval = 0.05

    private struct WeakChannel { weak var channel: StandInChannel? }
    private struct WeakService { weak var service: StandInCollaboration? }

    func add(_ document: Document) {
        documents[document.id] = document
        announce()
    }

    func remove(_ id: UUID) {
        documents[id] = nil
        announce()
        changed(id)
    }

    func addNotice(to person: String, title: String, body: String, document: UUID) {
        notices.append((person, title, body, document))
    }

    func register(_ channel: StandInChannel) {
        channels.removeAll { $0.channel == nil }
        channels.append(WeakChannel(channel: channel))
    }

    func register(_ service: StandInCollaboration) {
        services.append(WeakService(service: service))
    }

    /// Something in a document changed: everyone in it hears, a moment later.
    func changed(_ id: UUID) {
        for item in channels {
            guard let channel = item.channel, channel.id == id else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + latency) { [weak channel] in channel?.fetchSoon() }
        }
    }

    /// Which documents are shared with whom changed.
    func announce() {
        for item in services { item.service?.onSharedWithMeChange?() }
    }

    func sharing(of document: Document, for person: String) -> DocumentSharing {
        let me = document.people.first { $0.id == person }
        return DocumentSharing(id: document.id, title: document.title, owner: document.owner, collaborators: document.people,
                               access: document.access, linkPermission: document.linkPermission,
                               url: URL(string: "https://share.pugglesoft.invalid/\(document.id.uuidString.lowercased())"),
                               myPermission: document.owner.id == person ? .edit : (me?.permission ?? .comment),
                               isMine: document.owner.id == person)
    }
}

/// One person's view of the stand-in "iCloud".
final class StandInCollaboration: CollaborationService {
    let me: Collaborator
    let cloud: StandInCloud
    var onStatus: (() -> Void)?
    var onSharedWithMeChange: (() -> Void)?
    var onChangesAvailable: (() -> Void)?

    init(me: Collaborator, cloud: StandInCloud) {
        self.me = me
        self.cloud = cloud
        cloud.register(self)
    }

    var status: CollaborationStatus { .ready(me: me) }
    var invitesThroughSystem: Bool { false }

    var sharedWithMe: [SharedDocumentEntry] {
        cloud.documents.values.filter { document in
            document.owner.id != me.id && document.people.contains { $0.id == me.id && $0.status == .joined }
        }.map { SharedDocumentEntry(id: $0.id, title: $0.title, ownerName: $0.owner.name, ownerID: $0.owner.id) }
            .sorted { $0.title < $1.title }
    }

    func start() {}

    private func later(_ work: @escaping () -> Void) {
        nonisolated(unsafe) let work = work
        DispatchQueue.main.asyncAfter(deadline: .now() + cloud.latency) { work() }
    }

    private func change(_ id: UUID, _ completion: @escaping (Result<DocumentSharing, Error>) -> Void,
                        _ change: @escaping (StandInCloud.Document) -> Void) {
        later { [self] in
            guard let document = cloud.documents[id] else { return completion(.failure(CollaborationError.notShared)) }
            change(document)
            document.sharingVersion += 1
            cloud.changed(id)
            cloud.announce()
            completion(.success(cloud.sharing(of: document, for: me.id)))
        }
    }

    func share(_ id: UUID, title: String, snapshot: SyncSnapshot, comments: [SharedComment], access: LinkAccess,
               permission: CollaboratorPermission, completion: @escaping (Result<DocumentSharing, Error>) -> Void) {
        let document = StandInCloud.Document(id: id, title: title, owner: Collaborator(id: me.id, name: me.name, address: me.address, isOwner: true),
                                             access: access, linkPermission: permission, snapshot: snapshot)
        for comment in comments { document.comments[comment.thread.id] = (comment, document.bump()) }
        later { [self] in
            cloud.add(document)
            completion(.success(cloud.sharing(of: document, for: me.id)))
        }
    }

    func setAccess(_ access: LinkAccess, permission: CollaboratorPermission, of id: UUID,
                   completion: @escaping (Result<DocumentSharing, Error>) -> Void) {
        change(id, completion) { document in
            document.access = access
            document.linkPermission = permission
        }
    }

    func setPermission(_ permission: CollaboratorPermission, for person: Collaborator, in id: UUID,
                       completion: @escaping (Result<DocumentSharing, Error>) -> Void) {
        change(id, completion) { document in
            if let index = document.people.firstIndex(where: { $0.id == person.id && !$0.isOwner }) { document.people[index].permission = permission }
        }
    }

    func remove(_ person: Collaborator, from id: UUID, completion: @escaping (Result<DocumentSharing, Error>) -> Void) {
        change(id, completion) { document in document.people.removeAll { $0.id == person.id && !$0.isOwner } }
    }

    /// Someone invited joins a moment later.
    func invite(_ address: String, permission: CollaboratorPermission, to id: UUID,
                completion: @escaping (Result<DocumentSharing, Error>) -> Void) {
        let local = address.split(separator: "@").first.map(String.init) ?? address
        let name = cloud.directory[address.lowercased()] ?? local.prefix(1).uppercased() + local.dropFirst()
        let person = Collaborator(id: address.lowercased(), name: name, address: address, permission: permission, status: .invited)
        change(id, completion) { document in
            if !document.people.contains(where: { $0.id == person.id }) { document.people.append(person) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            guard let document = cloud.documents[id], let index = document.people.firstIndex(where: { $0.id == person.id }) else { return }
            document.people[index].status = .joined
            document.sharingVersion += 1
            cloud.changed(id)
            cloud.announce()
        }
    }

    func showInvitation(for id: UUID, relativeTo view: NSView) {}

    func stopSharing(_ id: UUID, completion: @escaping (Error?) -> Void) {
        later { [self] in
            cloud.remove(id)
            completion(nil)
        }
    }

    func leave(_ id: UUID, completion: @escaping (Error?) -> Void) {
        later { [self] in
            guard let document = cloud.documents[id] else { return completion(nil) }
            document.people.removeAll { $0.id == me.id }
            document.sharingVersion += 1
            cloud.changed(id)
            cloud.announce()
            completion(nil)
        }
    }

    func connect(_ id: UUID, owner: String?, delegate: CollaborationChannelDelegate) -> CollaborationChannel {
        StandInChannel(cloud: cloud, me: me, id: id, delegate: delegate)
    }
}

/// One person's line to one document in the stand-in "iCloud".
final class StandInChannel: CollaborationChannel {
    let id: UUID
    private let cloud: StandInCloud
    private let me: Collaborator
    private weak var delegate: CollaborationChannelDelegate?
    private var isRunning = false
    private var delivered: Set<Int> = []
    private var seenVersion = 0
    private var seenSharing = -1
    private var gone = false
    var pollInterval: TimeInterval = 15

    init(cloud: StandInCloud, me: Collaborator, id: UUID, delegate: CollaborationChannelDelegate) {
        self.cloud = cloud
        self.me = me
        self.id = id
        self.delegate = delegate
    }

    private var document: StandInCloud.Document? { cloud.documents[id] }

    func start() {
        isRunning = true
        cloud.register(self)
        DispatchQueue.main.asyncAfter(deadline: .now() + cloud.latency) { [weak self] in
            guard let self, let document else {
                self?.fetchSoon()
                return
            }
            seenSharing = document.sharingVersion
            delegate?.channel(self, sharingChanged: cloud.sharing(of: document, for: me.id))
            delegate?.channel(self, loaded: document.snapshot, info: SharedDocumentInfo(title: document.title, ownerName: document.owner.name,
                                                                                          snapshotRevision: document.snapshot.revision))
            fetchSoon()
        }
    }

    func stop() { isRunning = false }

    func fetchSoon() {
        guard isRunning, !gone else { return }
        guard let document, document.people.contains(where: { $0.id == me.id }) else {
            gone = true
            isRunning = false
            delegate?.channel(self, becameUnavailable: .stopped)
            return
        }
        if document.sharingVersion != seenSharing {
            seenSharing = document.sharingVersion
            delegate?.channel(self, sharingChanged: cloud.sharing(of: document, for: me.id))
        }
        let fresh = document.changes.values.filter { !delivered.contains($0.revision) }
        if !fresh.isEmpty {
            fresh.forEach { delivered.insert($0.revision) }
            delegate?.channel(self, received: fresh)
        }
        let comments = document.comments.values.filter { $0.version > seenVersion }.map(\.comment)
        let deleted = document.deletedComments.filter { $0.version > seenVersion }.map(\.id)
        if !comments.isEmpty || !deleted.isEmpty { delegate?.channel(self, receivedComments: comments, deleted: deleted) }
        let presence = document.presence.values.filter { $0.version > seenVersion }.map(\.presence)
        if !presence.isEmpty { delegate?.channel(self, receivedPresence: presence) }
        seenVersion = document.version
    }

    private func later(_ work: @escaping () -> Void) {
        nonisolated(unsafe) let work = work
        DispatchQueue.main.asyncAfter(deadline: .now() + cloud.latency) { work() }
    }

    func claim(_ change: LoggedChange, completion: @escaping (ClaimResult) -> Void) {
        later { [self] in
            guard let document else { return completion(.failed(CollaborationError.notShared)) }
            let permission = document.owner.id == me.id ? .edit : document.people.first { $0.id == me.id }?.permission
            guard permission == .edit else { return completion(.notAllowed) }
            if let existing = document.changes[change.revision] { return completion(.taken(existing)) }
            document.changes[change.revision] = change
            delivered.insert(change.revision)
            cloud.changed(id)
            completion(.claimed)
        }
    }

    func saveSnapshot(_ snapshot: SyncSnapshot, title: String) {
        guard let document, snapshot.revision > document.snapshot.revision else { return }
        document.snapshot = snapshot
    }

    func save(_ comment: SharedComment, base: CommentThread?, completion: @escaping (Result<SharedComment, Error>) -> Void) {
        later { [self] in
            guard let document else { return completion(.failure(CollaborationError.notShared)) }
            var saved = comment
            if let server = document.comments[comment.thread.id]?.comment, server.thread != base, base != nil {
                saved = SharedComment(thread: SharedComment.merge(local: comment.thread, base: base, server: server.thread),
                                      anchor: server.anchor ?? comment.anchor)
            }
            document.comments[comment.thread.id] = (saved, document.bump())
            seenVersion = max(seenVersion, document.version)
            cloud.changed(id)
            completion(.success(saved))
        }
    }

    func deleteComment(_ id: String) {
        guard let document else { return }
        document.comments[id] = nil
        document.deletedComments.append((id, document.bump()))
        cloud.changed(self.id)
    }

    func setPresence(viewing: Bool) {
        guard let document else { return }
        document.presence[me.id] = (Presence(person: me.id, info: PresenceInfo(name: me.name, isViewing: viewing, inboxURL: nil), date: Date()), document.bump())
        cloud.changed(id)
    }

    func sendNotice(title: String, body: String, to people: [String]) {
        for person in people { cloud.addNotice(to: person, title: title, body: body, document: id) }
    }
}

/// A simulated person working on a shared document in the stand-in "iCloud" from another Mac: the text as their Mac
/// has it, kept up through the log like any Mac's, for the self-test to type and comment as them.
final class StandInPerson: CollaborationChannelDelegate {
    let person: Collaborator
    let service: StandInCollaboration
    let storage = RecordingTextStorage()
    let coder = SyncAttributeCoder()
    private(set) var client: SyncClient?
    private var channel: CollaborationChannel?
    private(set) var comments: [String: SharedComment] = [:]
    private(set) var sharing: DocumentSharing?
    private(set) var isGone = false
    private(set) var refusals = 0
    private(set) var documentID: UUID?

    init(_ person: Collaborator, cloud: StandInCloud = .shared) {
        self.person = person
        service = StandInCollaboration(me: person, cloud: cloud)
        if let address = person.address { cloud.directory[address.lowercased()] = person.name }
        storage.coder = coder
        storage.onEdit = { [weak self] edit in
            guard let self, let client else { return }
            client.local(DocumentChange(body: edit.change))
            flush()
        }
    }

    var text: String { storage.string }

    /// Opens a document shared with them.
    func join(_ id: UUID) {
        documentID = id
        let channel = service.connect(id, owner: nil, delegate: self)
        self.channel = channel
        channel.start()
        channel.setPresence(viewing: true)
    }

    /// Shares a document of theirs with `people`, each as they're allowed, and keeps it open.
    func share(title: String, text: String, with people: [(Collaborator, CollaboratorPermission)]) -> UUID {
        let id = UUID()
        let body = NSAttributedString(string: text, attributes: DocumentDefaults.typingAttributes)
        let snapshot = SyncSnapshot(revision: 0, body: coder.insertion(of: body), header: TextDelta(), footer: TextDelta(), pageSetup: .letter, anchors: [:])
        let document = StandInCloud.Document(id: id, title: title, owner: Collaborator(id: person.id, name: person.name, address: person.address, isOwner: true),
                                             access: .invited, linkPermission: .comment, snapshot: snapshot)
        for (someone, permission) in people {
            document.people.append(Collaborator(id: someone.id, name: someone.name, address: someone.address, permission: permission, status: .joined))
        }
        service.cloud.add(document)
        join(id)
        return id
    }

    func stopSharing() {
        guard let documentID else { return }
        channel?.stop()
        service.stopSharing(documentID) { _ in }
    }

    func type(_ text: String, at location: Int) {
        storage.replaceCharacters(in: NSRange(location: min(location, storage.length), length: 0), with: text)
    }

    func delete(_ range: NSRange) {
        storage.deleteCharacters(in: range)
    }

    /// Comments on the first place `phrase` appears.
    func comment(_ text: String, on phrase: String) {
        guard let client, let channel else { return }
        let range = (storage.string as NSString).range(of: phrase)
        guard range.location != NSNotFound else { return }
        let thread = CommentThread(author: person.name, authorID: person.id, text: text)
        let comment = SharedComment(thread: thread, anchor: CommentAnchor(revision: client.revision, location: client.logPosition(range.location),
                                                                         length: range.length, quote: phrase))
        comments[thread.id] = comment
        channel.save(comment, base: nil) { _ in }
    }

    func reply(_ text: String, to threadID: String) {
        guard let channel, var comment = comments[threadID] else { return }
        let base = comment.thread
        comment.thread.replies.append(CommentReply(author: person.name, authorID: person.id, text: text))
        comments[threadID] = comment
        channel.save(comment, base: base) { _ in }
    }

    private func flush() {
        guard let client, let channel, let next = client.nextToSend() else { return }
        channel.claim(next) { [weak self] result in
            guard let self else { return }
            switch result {
            case .claimed:
                client.sent(next.id)
            case let .taken(existing):
                apply(client.sendTaken(next.id, by: existing))
            case .notAllowed:
                client.sendFailed(next.id)
                refusals += 1
                return
            case .failed:
                client.sendFailed(next.id)
                return
            }
            flush()
        }
    }

    private func apply(_ changes: [DocumentChange]) {
        storage.isRecording = false
        for change in changes { coder.apply(change.body, to: storage) }
        storage.isRecording = true
    }

    func channel(_ channel: CollaborationChannel, loaded snapshot: SyncSnapshot, info: SharedDocumentInfo) {
        guard client == nil else { return }
        storage.isRecording = false
        if let text = coder.text(from: snapshot.body) { storage.setAttributedString(text) }
        storage.isRecording = true
        client = SyncClient(revision: snapshot.revision, author: person.id, authorName: person.name)
    }

    func channel(_ channel: CollaborationChannel, received changes: [LoggedChange]) {
        guard let client else { return }
        apply(client.receive(changes))
        flush()
    }

    func channel(_ channel: CollaborationChannel, receivedComments comments: [SharedComment], deleted: [String]) {
        for comment in comments { self.comments[comment.thread.id] = comment }
        for id in deleted { self.comments[id] = nil }
    }

    func channel(_ channel: CollaborationChannel, receivedPresence presence: [Presence]) {}

    func channel(_ channel: CollaborationChannel, sharingChanged sharing: DocumentSharing) { self.sharing = sharing }

    func channel(_ channel: CollaborationChannel, becameUnavailable reason: UnavailableReason) { isGone = true }
}
#endif
