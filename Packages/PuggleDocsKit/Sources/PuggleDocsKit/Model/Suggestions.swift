import AppKit

/// Marks text suggested for insertion or deletion ("Suggesting" mode, tracked changes in Word).
/// One suggestion can cover several runs; a replacement is a deletion and an insertion sharing an id.
public final class SuggestionMark: NSObject, NSSecureCoding {
    public enum Kind: String, Sendable {
        case insertion, deletion
    }

    public let id: String
    public let kind: Kind
    public let author: String
    public let date: Date

    public init(id: String = UUID().uuidString, kind: Kind, author: String, date: Date = Date()) {
        self.id = id
        self.kind = kind
        self.author = author
        self.date = date
    }

    public func with(kind: Kind) -> SuggestionMark { SuggestionMark(id: id, kind: kind, author: author, date: date) }

    // Equal marks let adjacent runs merge.
    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? SuggestionMark else { return false }
        return id == other.id && kind == other.kind && author == other.author && date == other.date
    }

    public override var hash: Int {
        var hasher = Hasher()
        hasher.combine(id)
        hasher.combine(kind.rawValue)
        return hasher.finalize()
    }

    public static var supportsSecureCoding: Bool { true }

    public func encode(with coder: NSCoder) {
        coder.encode(id as NSString, forKey: "id")
        coder.encode(kind.rawValue as NSString, forKey: "kind")
        coder.encode(author as NSString, forKey: "author")
        coder.encode(date as NSDate, forKey: "date")
    }

    public required init?(coder: NSCoder) {
        guard let id = coder.decodeObject(of: NSString.self, forKey: "id") as String?,
              let kind = (coder.decodeObject(of: NSString.self, forKey: "kind") as String?).flatMap(Kind.init(rawValue:)) else { return nil }
        self.id = id
        self.kind = kind
        author = coder.decodeObject(of: NSString.self, forKey: "author") as String? ?? ""
        date = coder.decodeObject(of: NSDate.self, forKey: "date") as Date? ?? Date()
    }
}

public extension NSAttributedString.Key {
    /// Character-level `SuggestionMark`.
    static let pdSuggestion = NSAttributedString.Key("PuggleDocs.suggestion")
}

/// One suggestion as a reviewer sees it: what it adds and removes, by whom and when.
public struct SuggestionSummary: Equatable, Identifiable, Sendable {
    public let id: String
    public let author: String
    public let date: Date
    /// From its first to its last character.
    public let range: NSRange
    public let inserted: String
    public let deleted: String

    public var isReplacement: Bool { !inserted.isEmpty && !deleted.isEmpty }
}

public enum Suggestions {
    /// Suggestion times are written to the millisecond, so touching revisions are known to be one
    /// suggestion only when their times match exactly. Word's own files use whole seconds.
    public static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        return precise.date(from: text) ?? plain.date(from: text) ?? precise.date(from: String(text.prefix(23)) + "Z")
            ?? plain.date(from: String(text.prefix(19)) + "Z")
    }

    /// Whether a revision continues the one just read: same person, same moment, touching.
    static func continues(_ last: (mark: SuggestionMark, end: Int)?, at location: Int, author: String, date: Date) -> SuggestionMark? {
        guard let last, last.end == location, last.mark.author == author, abs(last.mark.date.timeIntervalSince(date)) < 0.000_5 else { return nil }
        return last.mark
    }

    public static func mark(at index: Int, in text: NSAttributedString) -> SuggestionMark? {
        index >= 0 && index < text.length ? text.attribute(.pdSuggestion, at: index, effectiveRange: nil) as? SuggestionMark : nil
    }

    public static func hasSuggestions(_ text: NSAttributedString) -> Bool {
        var found = false
        text.enumerateAttribute(.pdSuggestion, in: NSRange(location: 0, length: text.length), options: []) { value, _, stop in
            if value is SuggestionMark { found = true; stop.pointee = true }
        }
        return found
    }

    /// Every suggestion in document order.
    public static func summaries(in text: NSAttributedString) -> [SuggestionSummary] {
        struct Builder {
            var author: String
            var date: Date
            var range: NSRange
            var inserted = ""
            var deleted = ""
        }
        var builders: [String: Builder] = [:]
        var order: [String] = []
        let string = text.string as NSString
        text.enumerateAttribute(.pdSuggestion, in: NSRange(location: 0, length: text.length), options: []) { value, range, _ in
            guard let mark = value as? SuggestionMark else { return }
            if builders[mark.id] == nil {
                builders[mark.id] = Builder(author: mark.author, date: mark.date, range: range)
                order.append(mark.id)
            }
            let piece = string.substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "")
            builders[mark.id]!.range = NSUnionRange(builders[mark.id]!.range, range)
            if mark.kind == .insertion { builders[mark.id]!.inserted += piece } else { builders[mark.id]!.deleted += piece }
        }
        return order.compactMap { id in
            guard let builder = builders[id] else { return nil }
            return SuggestionSummary(id: id, author: builder.author, date: builder.date, range: builder.range,
                                     inserted: builder.inserted, deleted: builder.deleted)
        }
    }

    /// The text of `range` with suggestions settled: accepting keeps insertions and drops deletions,
    /// rejecting does the opposite. `ids` limits which suggestions are settled (nil means all).
    public static func resolved(_ text: NSAttributedString, in range: NSRange, ids: Set<String>? = nil, accept: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()
        text.enumerateAttribute(.pdSuggestion, in: range, options: []) { value, subrange, _ in
            let piece = NSMutableAttributedString(attributedString: text.attributedSubstring(from: subrange))
            if let mark = value as? SuggestionMark, ids?.contains(mark.id) ?? true {
                let keep = (mark.kind == .insertion) == accept
                guard keep else { return }
                piece.removeAttribute(.pdSuggestion, range: NSRange(location: 0, length: piece.length))
            }
            result.append(piece)
        }
        return result
    }

    /// The whole text with every suggestion accepted, for formats that can't store suggestions.
    public static func accepted(_ text: NSAttributedString) -> NSAttributedString {
        guard hasSuggestions(text) else { return text }
        return resolved(text, in: NSRange(location: 0, length: text.length), accept: true)
    }
}
