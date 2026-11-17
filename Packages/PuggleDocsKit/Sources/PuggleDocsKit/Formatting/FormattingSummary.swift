import AppKit

/// What the toolbar shows for the current selection. Optional values are nil when mixed.
public struct FormattingSummary: Equatable {
    public var fontFamily: String?
    public var fontSize: CGFloat?
    public var isBold = false
    public var isItalic = false
    public var isUnderlined = false
    public var isStruckThrough = false
    public var baseline = 0
    public var textColorHex: String? = "000000"
    public var highlightHex: String?
    public var link: URL?
    public var alignment: NSTextAlignment? = .left
    public var lineSpacing: CGFloat? = 1.15
    public var spaceBefore: CGFloat = 0
    public var spaceAfter: CGFloat = 0
    public var namedStyle: NamedStyle? = .normal
    public var listKind: ListKind?
    public var listPreset: ListPreset?
    public var headIndent: CGFloat = 0
    public var firstLineHeadIndent: CGFloat = 0
    public var tailIndent: CGFloat = 0

    public init() {}

    /// Selections longer than this are summarised from their first part only, to stay responsive.
    static let scanLimit = 50_000

    public static func make(storage: NSAttributedString, selectedRanges: [NSRange],
                            typingAttributes: [NSAttributedString.Key: Any]) -> FormattingSummary {
        var summary = FormattingSummary()
        let ranges = selectedRanges.filter { $0.length > 0 }

        // Character attributes.
        var runs: [[NSAttributedString.Key: Any]] = []
        if ranges.isEmpty {
            runs = [typingAttributes]
        } else {
            var budget = scanLimit
            for range in ranges where budget > 0 {
                let limited = NSRange(location: range.location, length: min(range.length, budget))
                budget -= limited.length
                storage.enumerateAttributes(in: limited, options: []) { attributes, _, _ in runs.append(attributes) }
            }
        }
        let specs = runs.map(FontResolver.spec(from:))
        summary.fontFamily = uniform(specs.map(\.family))
        summary.fontSize = uniform(specs.map(\.size))
        summary.isBold = !specs.isEmpty && specs.allSatisfy(\.bold)
        summary.isItalic = !specs.isEmpty && specs.allSatisfy(\.italic)
        summary.isUnderlined = !runs.isEmpty && runs.allSatisfy(CharacterFormatting.isUnderlined)
        summary.isStruckThrough = !runs.isEmpty && runs.allSatisfy(CharacterFormatting.isStruckThrough)
        summary.baseline = uniform(runs.map(CharacterFormatting.baseline)) ?? 0
        summary.textColorHex = uniform(runs.map { ($0[.foregroundColor] as? NSColor)?.hexString ?? "000000" })
        summary.highlightHex = uniform(runs.map { ($0[.backgroundColor] as? NSColor)?.hexString ?? "" }).flatMap { $0.isEmpty ? nil : $0 }
        summary.link = runs.first?[.link].flatMap { ($0 as? URL) ?? ($0 as? String).flatMap(URL.init(string:)) }

        // Paragraph attributes.
        let string = storage.string as NSString
        let paragraphs = ParagraphFormatting.paragraphRanges(in: string, covering: selectedRanges.isEmpty ? [NSRange(location: 0, length: 0)] : selectedRanges)
        let paragraphAttributes = paragraphs.prefix(2_000).map { range -> ParagraphAttributes in
            if range.length == 0 || range.location >= storage.length {
                return ParagraphAttributes(attributes: typingAttributes)
            }
            return ParagraphAttributes(attributes: storage.attributes(at: range.location, effectiveRange: nil))
        }
        if let first = paragraphAttributes.first {
            summary.alignment = uniform(paragraphAttributes.map { normalized($0.style.alignment) })
            summary.lineSpacing = uniform(paragraphAttributes.map { $0.style.lineHeightMultiple == 0 ? 1 : $0.style.lineHeightMultiple })
            summary.spaceBefore = first.style.paragraphSpacingBefore
            summary.spaceAfter = first.style.paragraphSpacing
            summary.namedStyle = uniform(paragraphAttributes.map(\.namedStyle))
            let kinds = paragraphAttributes.map { $0.listItem?.kind }
            summary.listKind = kinds.allSatisfy({ $0 == kinds.first }) ? kinds.first ?? nil : nil
            summary.listPreset = summary.listKind == nil ? nil : first.listItem?.preset
            summary.headIndent = first.style.headIndent
            summary.firstLineHeadIndent = first.style.firstLineHeadIndent
            summary.tailIndent = first.style.tailIndent
        }
        return summary
    }

    static func normalized(_ alignment: NSTextAlignment) -> NSTextAlignment {
        alignment == .natural ? .left : alignment
    }

    static func uniform<T: Equatable>(_ values: [T]) -> T? {
        guard let first = values.first else { return nil }
        return values.allSatisfy { $0 == first } ? first : nil
    }
}
