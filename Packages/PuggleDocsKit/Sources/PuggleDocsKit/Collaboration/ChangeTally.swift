import AppKit

/// What someone has changed in a shared document since the people they share it with were last told, and the short
/// summary that tells them: what was added, taken out, restyled or commented on, not every change.
public struct ChangeTally: Equatable, Sendable {
    /// Text added, and taken out, run by run. Typing and then deleting what was just typed leaves nothing.
    private var added = ""
    private var removed = ""
    /// Where the latest run of added text ends, so typing on carries it on and Backspace takes from it.
    private var runEnd: Int?
    private var lastRunLength = 0
    public private(set) var paragraphsAdded = 0
    public private(set) var restyled = false
    public private(set) var imagesAdded = 0
    public private(set) var tablesAdded = 0
    public private(set) var headerOrFooterChanged = false
    public private(set) var pageSetupChanged = false
    public private(set) var commentsAdded = 0
    public private(set) var repliesAdded = 0
    public private(set) var commentsResolved = 0
    /// The words of the latest comment or reply.
    public private(set) var commentExcerpt: String?

    public init() {}

    public var isEmpty: Bool { self == ChangeTally() }

    public var wordsAdded: Int { Self.words(in: added) }
    public var wordsRemoved: Int { Self.words(in: removed) }

    // MARK: Counting

    /// A round of editing in the document's text.
    public mutating func recordText(inserted: [(location: Int, text: NSAttributedString)], deleted: [(location: Int, text: NSAttributedString)],
                                    restyled restyledCount: Int) {
        for (location, text) in deleted {
            let string = text.string
            let length = (string as NSString).length
            if let end = runEnd, location + length == end, lastRunLength >= length {
                // Backspace over what was just typed.
                added = String(added.utf16.dropLast(length)) ?? added
                lastRunLength -= length
                runEnd = location
            } else {
                removed += (removed.isEmpty ? "" : "\n") + string
                runEnd = runEnd.map { $0 > location ? max(location, $0 - length) : $0 }
            }
        }
        for (location, text) in inserted {
            let string = text.string
            let length = (string as NSString).length
            if runEnd == location {
                added += string
                lastRunLength += length
            } else {
                added += (added.isEmpty ? "" : "\n") + string
                lastRunLength = length
            }
            runEnd = location + length
            paragraphsAdded += string.filter { $0 == "\n" || $0 == "\u{2029}" }.count
            imagesAdded += Self.images(in: text)
            tablesAdded += Self.tables(in: text)
        }
        if restyledCount > 0 { restyled = true }
    }

    public mutating func recordHeaderOrFooter() { headerOrFooterChanged = true }
    public mutating func recordPageSetup() { pageSetupChanged = true }

    public mutating func recordComment(_ text: String) {
        commentsAdded += 1
        commentExcerpt = Self.excerpt(text)
    }

    public mutating func recordReply(_ text: String) {
        repliesAdded += 1
        commentExcerpt = Self.excerpt(text)
    }

    public mutating func recordResolved() { commentsResolved += 1 }

    private static func words(in text: String) -> Int {
        var count = 0
        let string = text as NSString
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        return count
    }

    private static func images(in text: NSAttributedString) -> Int {
        var count = 0
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length), options: []) { value, range, _ in
            if let attachment = value as? NSTextAttachment, !(attachment is PageFieldAttachment) { count += range.length }
        }
        return count
    }

    /// Tables the text brings whole: at least two of a table's cells. Typing in a cell brings part of one only.
    private static func tables(in text: NSAttributedString) -> Int {
        var cells: [ObjectIdentifier: Set<ObjectIdentifier>] = [:]
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length), options: []) { value, _, _ in
            for case let block as NSTextTableBlock in (value as? NSParagraphStyle)?.textBlocks ?? [] {
                cells[ObjectIdentifier(block.table), default: []].insert(ObjectIdentifier(block))
            }
        }
        return cells.values.filter { $0.count > 1 }.count
    }

    private static func excerpt(_ text: String) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return words.count > 70 ? String(words.prefix(70)) + "…" : words
    }

    // MARK: Words

    /// The notification: a title naming who changed which document, and a line saying roughly what they did. Nil
    /// when there's nothing to tell.
    public func notice(author: String, documentTitle: String) -> (title: String, body: String)? {
        guard !isEmpty else { return nil }
        let name = author.isEmpty ? "Someone" : author
        let title = documentTitle.count > 48 ? String(documentTitle.prefix(47)) + "…" : documentTitle
        let editedText = wordsAdded > 0 || wordsRemoved > 0 || restyled || imagesAdded > 0 || tablesAdded > 0
            || headerOrFooterChanged || pageSetupChanged || paragraphsAdded > 0
        let commented = commentsAdded + repliesAdded + commentsResolved > 0
        if !editedText, !commented { return nil }
        if !editedText {
            let heading = commentsAdded == 0 && repliesAdded > 0 ? "\(name) replied in “\(title)”"
                : (commentsAdded == 0 && repliesAdded == 0 ? "\(name) resolved comments in “\(title)”" : "\(name) commented on “\(title)”")
            if commentsAdded + repliesAdded == 1, commentsResolved == 0, let commentExcerpt {
                return (heading, "“\(commentExcerpt)”")
            }
            return (heading, Self.sentence(commentParts))
        }
        var parts: [String] = []
        if wordsAdded > 0 { parts.append("added " + Self.count(wordsAdded, "word")) }
        if wordsRemoved > 0 { parts.append("removed " + Self.count(wordsRemoved, "word")) }
        if wordsAdded == 0, wordsRemoved == 0, paragraphsAdded > 0 { parts.append("added " + Self.count(paragraphsAdded, "paragraph", exact: true)) }
        if imagesAdded > 0 { parts.append("added " + Self.count(imagesAdded, "image", exact: true)) }
        if tablesAdded > 0 { parts.append("added " + Self.count(tablesAdded, "table", exact: true)) }
        if restyled { parts.append("changed the formatting") }
        if headerOrFooterChanged { parts.append("changed the header or footer") }
        if pageSetupChanged { parts.append("changed the page setup") }
        parts += commentParts
        return ("\(name) edited “\(title)”", Self.sentence(parts))
    }

    private var commentParts: [String] {
        var parts: [String] = []
        if commentsAdded > 0 { parts.append("added " + Self.count(commentsAdded, "comment", exact: true)) }
        if repliesAdded > 0 { parts.append(repliesAdded == 1 ? "replied to a comment" : "added \(repliesAdded) replies") }
        if commentsResolved > 0 { parts.append("resolved " + Self.count(commentsResolved, "comment", exact: true)) }
        return parts
    }

    /// "a word", "3 words", "about 120 words".
    private static func count(_ value: Int, _ noun: String, exact: Bool = false) -> String {
        if value == 1 { return (noun.first.map { "aeiou".contains($0) } ?? false ? "an " : "a ") + noun }
        if !exact, value >= 20 {
            let rounded = value >= 100 ? (value + 5) / 10 * 10 : value
            return "about \(rounded) \(noun)s"
        }
        return "\(value) \(noun)s"
    }

    /// "Added 3 words, changed the formatting and added a comment."
    private static func sentence(_ parts: [String]) -> String {
        guard var first = parts.first else { return "" }
        first = first.prefix(1).uppercased() + first.dropFirst()
        let all = [first] + parts.dropFirst()
        let joined = all.count <= 1 ? all.joined() : all.dropLast().joined(separator: ", ") + " and " + all.last!
        return joined + "."
    }
}
