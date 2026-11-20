import AppKit

public struct CommentReply: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var author: String
    /// In a shared document, the iCloud identity of whoever wrote it.
    public var authorID: String?
    public var date: Date
    public var text: String

    public init(id: String = UUID().uuidString, author: String, authorID: String? = nil, date: Date = Date(), text: String) {
        self.id = id
        self.author = author
        self.authorID = authorID
        self.date = date
        self.text = text
    }
}

/// A comment and its replies, anchored to text marked with `.pdComments`.
public struct CommentThread: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var author: String
    /// In a shared document, the iCloud identity of whoever wrote it.
    public var authorID: String?
    public var date: Date
    public var text: String
    public var replies: [CommentReply]
    public var resolved: Bool

    public init(id: String = UUID().uuidString, author: String, authorID: String? = nil, date: Date = Date(), text: String,
                replies: [CommentReply] = [], resolved: Bool = false) {
        self.id = id
        self.author = author
        self.authorID = authorID
        self.date = date
        self.text = text
        self.replies = replies
        self.resolved = resolved
    }

    /// Initials for the avatar ("Ana Lopez" → "AL").
    public static func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map { String($0).uppercased() }.joined()
        return letters.isEmpty ? "?" : letters
    }
}

public extension NSAttributedString.Key {
    /// Character-level. Comma-separated ids of the comment threads anchored to this text.
    static let pdComments = NSAttributedString.Key("PuggleDocs.comments")
}

/// Reading and changing comment anchors in text.
public enum CommentAnchors {
    public static func ids(_ value: Any?) -> [String] {
        guard let string = value as? String, !string.isEmpty else { return [] }
        return string.split(separator: ",").map(String.init)
    }

    public static func value(_ ids: [String]) -> String? {
        let unique = Array(Set(ids)).sorted()
        return unique.isEmpty ? nil : unique.joined(separator: ",")
    }

    public static func add(_ id: String, to text: NSMutableAttributedString, range: NSRange) {
        guard range.length > 0, NSMaxRange(range) <= text.length else { return }
        text.enumerateAttribute(.pdComments, in: range, options: []) { value, subrange, _ in
            text.addAttribute(.pdComments, value: CommentAnchors.value(ids(value) + [id])!, range: subrange)
        }
    }

    public static func remove(_ id: String, from text: NSMutableAttributedString) {
        guard text.length > 0 else { return }
        text.enumerateAttribute(.pdComments, in: NSRange(location: 0, length: text.length), options: []) { value, range, _ in
            let current = ids(value)
            guard current.contains(id) else { return }
            if let remaining = CommentAnchors.value(current.filter { $0 != id }) {
                text.addAttribute(.pdComments, value: remaining, range: range)
            } else {
                text.removeAttribute(.pdComments, range: range)
            }
        }
    }

    /// The range covered by each comment id, from its first to its last character.
    public static func ranges(in text: NSAttributedString) -> [String: NSRange] {
        var result: [String: NSRange] = [:]
        guard text.length > 0 else { return result }
        text.enumerateAttribute(.pdComments, in: NSRange(location: 0, length: text.length), options: []) { value, range, _ in
            for id in ids(value) {
                result[id] = result[id].map { NSUnionRange($0, range) } ?? range
            }
        }
        return result
    }
}

public extension CommentAnchors {
    /// Drops anchors of unknown threads and makes each thread's anchor one unbroken range.
    static func normalize(_ text: NSMutableAttributedString, threads: [CommentThread]) {
        let known = Set(threads.map(\.id))
        for (id, range) in ranges(in: text) {
            if known.contains(id) { add(id, to: text, range: range) } else { remove(id, from: text) }
        }
    }

    /// `range` after an edit that put `editedRange` (in the new text) where `editedRange.length - delta`
    /// characters were. Edits inside or touching the range's end grow or shrink it.
    static func adjust(_ range: NSRange, editedRange: NSRange, delta: Int) -> NSRange {
        let oldEnd = editedRange.location + editedRange.length - delta
        // Entirely before the range: it moves. Entirely after: nothing changes. Otherwise keep what's left.
        if oldEnd <= range.location { return NSRange(location: max(0, range.location + delta), length: range.length) }
        if editedRange.location >= NSMaxRange(range) { return range }
        let start = min(range.location, editedRange.location)
        let end = max(NSMaxRange(editedRange), NSMaxRange(range) + delta)
        return NSRange(location: start, length: max(0, end - start))
    }

    /// The `.pdComments` value on the paragraph mark that follows `range`, if there is one.
    static func markValue(in text: NSAttributedString, after range: NSRange) -> Any? {
        let string = text.string as NSString
        let separator = NSMaxRange(range)
        guard separator < string.length, [0x0A, 0x0D, 0x2029, 0x85].contains(string.character(at: separator)) else { return nil }
        return text.attribute(.pdComments, at: separator, effectiveRange: nil)
    }
}

/// Follows comment anchors while a writer walks the text's runs in order. Each comment opens once
/// and closes where its anchor ends, or at the end of a paragraph whose mark it doesn't cover.
struct CommentRangeTracker {
    let known: Set<String>
    private(set) var open = Set<String>()
    private(set) var closed = Set<String>()
    /// Threads in the order they were first opened.
    private(set) var order: [String] = []

    init(threads: [CommentThread]) { known = Set(threads.map(\.id)) }

    /// Moves to a run whose `.pdComments` value is `value`.
    mutating func move(to value: Any?) -> (ending: [String], starting: [String]) {
        transition(to: Set(CommentAnchors.ids(value)).intersection(known).subtracting(closed))
    }

    /// At the end of a paragraph's text: comments carry on only when the paragraph mark carries them.
    mutating func endParagraph(markValue: Any?) -> [String] {
        transition(to: open.intersection(CommentAnchors.ids(markValue))).ending
    }

    mutating func finish() -> [String] { transition(to: []).ending }

    private mutating func transition(to ids: Set<String>) -> (ending: [String], starting: [String]) {
        let ending = open.subtracting(ids).sorted()
        let starting = ids.subtracting(open).sorted()
        closed.formUnion(ending)
        order.append(contentsOf: starting)
        open = ids
        return (ending, starting)
    }
}
