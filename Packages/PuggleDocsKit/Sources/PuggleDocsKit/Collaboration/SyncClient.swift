import AppKit

/// A change to a shared document: to its text, header and footer, and perhaps its page setup.
public struct DocumentChange: Equatable, Sendable {
    public var body: TextDelta
    public var header: TextDelta
    public var footer: TextDelta
    /// The whole page setup, when the change sets it; the latest change that sets it wins.
    public var pageSetup: PageSetup?

    public init(body: TextDelta = TextDelta(), header: TextDelta = TextDelta(), footer: TextDelta = TextDelta(), pageSetup: PageSetup? = nil) {
        self.body = body
        self.header = header
        self.footer = footer
        self.pageSetup = pageSetup
    }

    public var isEmpty: Bool { body.isEmpty && header.isEmpty && footer.isEmpty && pageSetup == nil }

    /// This change followed by `later`, as one.
    public func compose(_ later: DocumentChange) -> DocumentChange {
        DocumentChange(body: body.compose(later.body), header: header.compose(later.header), footer: footer.compose(later.footer),
                       pageSetup: later.pageSetup ?? pageSetup)
    }

    /// `other`, made at the same time as this change, rewritten to follow it. With `priority`, this change came first
    /// in the log: its insertions go first where both insert at one place, and `other`'s page setup, coming later,
    /// stands. Without, `other` came first, and this change's page setup stands over it.
    public func transform(_ other: DocumentChange, priority: Bool) -> DocumentChange {
        DocumentChange(body: body.transform(other.body, priority: priority), header: header.transform(other.header, priority: priority),
                       footer: footer.transform(other.footer, priority: priority),
                       pageSetup: priority || pageSetup == nil ? other.pageSetup : nil)
    }
}

extension DocumentChange: Codable {
    private enum CodingKeys: String, CodingKey { case body, header, footer, pageSetup }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        body = try container.decodeIfPresent(TextDelta.self, forKey: .body) ?? TextDelta()
        header = try container.decodeIfPresent(TextDelta.self, forKey: .header) ?? TextDelta()
        footer = try container.decodeIfPresent(TextDelta.self, forKey: .footer) ?? TextDelta()
        pageSetup = try container.decodeIfPresent(PageSetupCoding.self, forKey: .pageSetup)?.pageSetup
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !body.ops.isEmpty { try container.encode(body, forKey: .body) }
        if !header.ops.isEmpty { try container.encode(header, forKey: .header) }
        if !footer.ops.isEmpty { try container.encode(footer, forKey: .footer) }
        try container.encodeIfPresent(pageSetup.map(PageSetupCoding.init), forKey: .pageSetup)
    }

    /// The change as bytes, to keep or send.
    public var encoded: Data { Self.encode(self) }

    public init(encoded data: Data) throws {
        self = try PropertyListDecoder().decode(DocumentChange.self, from: data)
    }

    static func encode(_ value: some Encodable) -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return (try? encoder.encode(value)) ?? Data()
    }
}

/// Every part of a page setup, for keeping and sending.
struct PageSetupCoding: Codable, Equatable {
    var paperWidth: Double
    var paperHeight: Double
    var orientation: String
    var top: Double
    var left: Double
    var bottom: Double
    var right: Double
    var headerDistance: Double
    var footerDistance: Double
    var pageColor: String?
    var differentFirstPage: Bool

    init(_ setup: PageSetup) {
        paperWidth = Double(setup.paperSize.width)
        paperHeight = Double(setup.paperSize.height)
        orientation = setup.orientation.rawValue
        top = Double(setup.margins.top)
        left = Double(setup.margins.left)
        bottom = Double(setup.margins.bottom)
        right = Double(setup.margins.right)
        headerDistance = Double(setup.headerDistance)
        footerDistance = Double(setup.footerDistance)
        pageColor = setup.pageColorHex
        differentFirstPage = setup.differentFirstPage
    }

    var pageSetup: PageSetup {
        var setup = PageSetup(paperSize: CGSize(width: paperWidth, height: paperHeight),
                              orientation: PageSetup.Orientation(rawValue: orientation) ?? .portrait,
                              margins: PageMargins(top: CGFloat(top), left: CGFloat(left), bottom: CGFloat(bottom), right: CGFloat(right)))
        setup.headerDistance = CGFloat(headerDistance)
        setup.footerDistance = CGFloat(footerDistance)
        setup.pageColorHex = pageColor
        setup.differentFirstPage = differentFirstPage
        return setup
    }
}

/// One change in a shared document's log, at its revision: the log is the document's history, one revision after
/// another, the same on every Mac.
public struct LoggedChange: Equatable, Sendable {
    public var revision: Int
    /// Tells this change from every other, so a Mac knows its own change when it comes back.
    public var id: String
    /// Who made it: their iCloud identity.
    public var author: String
    public var authorName: String
    public var change: DocumentChange

    public init(revision: Int, id: String = UUID().uuidString, author: String, authorName: String, change: DocumentChange) {
        self.revision = revision
        self.id = id
        self.author = author
        self.authorName = authorName
        self.change = change
    }
}

/// One Mac's side of editing a shared document along with others, through its log.
///
/// Changes made here go into the log one at a time, each claiming the revision after the last one known here. Changes
/// that others got into the log first come in and are applied here; changes of this Mac's still on their way are
/// rewritten to follow them, as are the incoming changes to fit around them. So every Mac ends up with the same text.
public final class SyncClient {
    public let author: String
    public var authorName: String
    /// The last revision of the log that's been applied here.
    public private(set) var revision: Int
    /// The change of this Mac's that's claiming the next revision (or about to).
    public private(set) var outstanding: LoggedChange?
    /// Changes made here since `outstanding`, to go once it's in.
    public private(set) var buffer: DocumentChange?
    /// `outstanding`'s id while it's being sent.
    public private(set) var sending: String?
    /// Changes that came ahead of the ones before them.
    private var early: [Int: LoggedChange] = [:]
    /// The log's changes, by revision, as far back as they're kept: for moving places in the text forward.
    private var history: [Int: DocumentChange] = [:]
    public var historyLimit = 5_000

    public init(revision: Int, author: String, authorName: String) {
        self.revision = revision
        self.author = author
        self.authorName = authorName
    }

    /// Whether changes made here aren't all in the log yet.
    public var hasPending: Bool { outstanding != nil || buffer != nil }

    /// The oldest revision whose change is kept here.
    public var earliestKnownRevision: Int { history.keys.min() ?? revision + 1 }

    /// A change made here.
    public func local(_ change: DocumentChange) {
        guard !change.isEmpty else { return }
        if outstanding == nil {
            outstanding = LoggedChange(revision: revision + 1, author: author, authorName: authorName, change: change)
        } else {
            buffer = buffer.map { $0.compose(change) } ?? change
        }
    }

    /// The change to send next, if one is waiting and none is already on its way.
    public func nextToSend() -> LoggedChange? {
        guard sending == nil, let outstanding else { return nil }
        sending = outstanding.id
        return outstanding
    }

    /// The change went into the log at the revision it claimed.
    public func sent(_ id: String) {
        if sending == id { sending = nil }
        guard let outstanding, outstanding.id == id else { return }
        confirm(outstanding)
    }

    /// The change couldn't be sent (no connection, say); it's sent again next time.
    public func sendFailed(_ id: String) {
        if sending == id { sending = nil }
    }

    /// Another change took the revision the change claimed. Answers what to apply here; the change follows it.
    public func sendTaken(_ id: String, by existing: LoggedChange) -> [DocumentChange] {
        if sending == id { sending = nil }
        return receive([existing])
    }

    /// Changes from the log, in any order. Answers the changes to make to the text here, in the order to make them.
    public func receive(_ changes: [LoggedChange]) -> [DocumentChange] {
        for change in changes where change.revision > revision { early[change.revision] = change }
        var applied: [DocumentChange] = []
        while let next = early.removeValue(forKey: revision + 1) {
            if let mine = outstanding, mine.id == next.id {
                if sending == mine.id { sending = nil }
                confirm(mine)
                continue
            }
            var remote = next.change
            if var mine = outstanding {
                let moved = remote.transform(mine.change, priority: true)
                remote = mine.change.transform(remote, priority: false)
                mine.change = moved
                mine.revision = next.revision + 1
                outstanding = mine
            }
            if let pending = buffer {
                let moved = remote.transform(pending, priority: true)
                remote = pending.transform(remote, priority: false)
                buffer = moved
            }
            revision = next.revision
            remember(next.revision, next.change)
            applied.append(remote)
        }
        return applied
    }

    /// Whether changes from the log are waiting for one that hasn't come.
    public var isMissingChanges: Bool { !early.isEmpty }

    private func confirm(_ change: LoggedChange) {
        revision = change.revision
        remember(change.revision, change.change)
        outstanding = buffer.map { LoggedChange(revision: revision + 1, author: author, authorName: authorName, change: $0) }
        buffer = nil
    }

    private func remember(_ revision: Int, _ change: DocumentChange) {
        history[revision] = change
        if history.count > historyLimit, let oldest = history.keys.min() { history[oldest] = nil }
    }

    /// Starts over from a snapshot of the log at `revision`, dropping whatever was known before it.
    public func reset(to revision: Int) {
        self.revision = revision
        history = [:]
        early = early.filter { $0.key > revision }
        if var mine = outstanding {
            mine.revision = revision + 1
            outstanding = mine
        }
    }

    // MARK: Places in the text

    /// Where a place in the body at `revision` of the log is in the text here now; nil when the changes since then
    /// aren't known here (or `revision` hasn't come yet). With `priority`, text inserted exactly there goes after it.
    public func position(_ index: Int, at revision: Int, priority: Bool) -> Int? {
        guard revision <= self.revision else { return nil }
        var index = index
        if revision < self.revision {
            for step in (revision + 1)...self.revision {
                guard let change = history[step] else { return nil }
                index = change.body.transformPosition(index, priority: priority)
            }
        }
        if let outstanding { index = outstanding.change.body.transformPosition(index, priority: priority) }
        if let buffer { index = buffer.body.transformPosition(index, priority: priority) }
        return index
    }

    /// Where a place in the body here is in the text at `revision`, the last revision applied: before the changes made
    /// here that aren't in the log yet.
    public func logPosition(_ index: Int) -> Int {
        var index = index
        if let buffer { index = buffer.body.positionBefore(index) }
        if let outstanding { index = outstanding.change.body.positionBefore(index) }
        return index
    }
}

/// A shared document as a whole at one revision of its log, for a Mac joining it to start from.
public struct SyncSnapshot: Sendable {
    public var revision: Int
    /// The texts, as changes inserting them into empty text.
    public var body: TextDelta
    public var header: TextDelta
    public var footer: TextDelta
    public var pageSetup: PageSetup
    /// Where each comment's text is at `revision`, by thread.
    public var anchors: [String: NSRange]

    public init(revision: Int, body: TextDelta, header: TextDelta, footer: TextDelta, pageSetup: PageSetup, anchors: [String: NSRange]) {
        self.revision = revision
        self.body = body
        self.header = header
        self.footer = footer
        self.pageSetup = pageSetup
        self.anchors = anchors
    }

    private struct Coded: Codable {
        var revision: Int
        var body: TextDelta
        var header: TextDelta
        var footer: TextDelta
        var pageSetup: PageSetupCoding
        var anchors: [String: [Int]]
    }

    public var encoded: Data {
        DocumentChange.encode(Coded(revision: revision, body: body, header: header, footer: footer, pageSetup: PageSetupCoding(pageSetup),
                                    anchors: anchors.mapValues { [$0.location, $0.length] }))
    }

    public init(encoded data: Data) throws {
        let coded = try PropertyListDecoder().decode(Coded.self, from: data)
        revision = coded.revision
        body = coded.body
        header = coded.header
        footer = coded.footer
        pageSetup = coded.pageSetup.pageSetup
        anchors = coded.anchors.compactMapValues { $0.count == 2 ? NSRange(location: $0[0], length: $0[1]) : nil }
    }
}
