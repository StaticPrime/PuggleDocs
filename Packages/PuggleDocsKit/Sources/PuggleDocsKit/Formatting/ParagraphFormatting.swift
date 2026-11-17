import AppKit

/// The paragraph-level attributes edited together.
public struct ParagraphAttributes {
    public var style: NSMutableParagraphStyle
    public var namedStyle: NamedStyle
    public var listItem: ListItem?

    public init(attributes: [NSAttributedString.Key: Any]) {
        style = (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
            ?? DocumentDefaults.paragraphStyle()
        namedStyle = (attributes[.pdNamedStyle] as? String).flatMap(NamedStyle.init(rawValue:)) ?? .normal
        listItem = attributes[.pdListItem] as? ListItem
    }

    public func write(to attributes: inout [NSAttributedString.Key: Any]) {
        attributes[.paragraphStyle] = style.copy() as! NSParagraphStyle
        attributes[.pdNamedStyle] = namedStyle.rawValue
        attributes[.pdListItem] = listItem
    }
}

public typealias ParagraphTransform = (inout ParagraphAttributes) -> Void

public enum ParagraphFormatting {
    // MARK: Ranges

    /// Sorted, de-duplicated paragraph ranges touched by `ranges`. A zero-length result at the end of
    /// the string stands for the empty final paragraph, which only exists in the typing attributes.
    public static func paragraphRanges(in string: NSString, covering ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            let clamped = NSRange(location: min(range.location, string.length),
                                  length: min(range.length, string.length - min(range.location, string.length)))
            var location = clamped.location
            let end = NSMaxRange(clamped)
            repeat {
                let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
                if result.last.map({ NSEqualRanges($0, paragraph) || NSMaxRange($0) > paragraph.location }) != true {
                    result.append(paragraph)
                }
                location = NSMaxRange(paragraph)
            } while location < end
        }
        return result
    }

    public static func union(of ranges: [NSRange]) -> NSRange {
        guard let first = ranges.first else { return NSRange(location: 0, length: 0) }
        return ranges.dropFirst().reduce(first) { NSUnionRange($0, $1) }
    }

    // MARK: Applying

    public static func apply(_ transform: ParagraphTransform, to storage: NSMutableAttributedString, paragraphRanges: [NSRange]) {
        for range in paragraphRanges where range.length > 0 {
            var paragraph = ParagraphAttributes(attributes: storage.attributes(at: range.location, effectiveRange: nil))
            transform(&paragraph)
            storage.addAttribute(.paragraphStyle, value: paragraph.style.copy() as! NSParagraphStyle, range: range)
            storage.addAttribute(.pdNamedStyle, value: paragraph.namedStyle.rawValue, range: range)
            if let item = paragraph.listItem {
                storage.addAttribute(.pdListItem, value: item, range: range)
            } else {
                storage.removeAttribute(.pdListItem, range: range)
            }
        }
    }

    public static func apply(_ transform: ParagraphTransform, to typing: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var paragraph = ParagraphAttributes(attributes: typing)
        transform(&paragraph)
        var result = typing
        paragraph.write(to: &result)
        return result
    }

    /// Makes paragraph-level attributes uniform across each paragraph touching `range`,
    /// using the paragraph's first character as the source of truth.
    public static func normalize(_ storage: NSMutableAttributedString, in range: NSRange) {
        let string = storage.string as NSString
        guard string.length > 0 else { return }
        let ranges = paragraphRanges(in: string, covering: [range])
        for paragraph in ranges where paragraph.length > 1 {
            for key in ParagraphAttributeKeys.all {
                var effective = NSRange()
                let value = storage.attribute(key, at: paragraph.location, longestEffectiveRange: &effective, in: paragraph)
                if NSMaxRange(effective) < NSMaxRange(paragraph) {
                    if let value {
                        storage.addAttribute(key, value: value, range: paragraph)
                    } else {
                        storage.removeAttribute(key, range: paragraph)
                    }
                }
            }
        }
    }

    // MARK: Transforms

    public static func setAlignment(_ alignment: NSTextAlignment) -> ParagraphTransform {
        { $0.style.alignment = alignment }
    }

    public static func setLineSpacing(_ multiple: CGFloat) -> ParagraphTransform {
        { paragraph in
            paragraph.style.lineHeightMultiple = multiple
            paragraph.style.minimumLineHeight = 0
            paragraph.style.maximumLineHeight = 0
        }
    }

    public static func setSpaceBefore(_ points: CGFloat) -> ParagraphTransform {
        { $0.style.paragraphSpacingBefore = max(0, points) }
    }

    public static func setSpaceAfter(_ points: CGFloat) -> ParagraphTransform {
        { $0.style.paragraphSpacing = max(0, points) }
    }

    /// Sets indents measured from the left margin; `right` is measured from the right margin.
    public static func setIndents(left: CGFloat, firstLine: CGFloat, right: CGFloat) -> ParagraphTransform {
        { paragraph in
            paragraph.style.headIndent = max(0, left)
            paragraph.style.firstLineHeadIndent = max(0, firstLine)
            paragraph.style.tailIndent = right > 0 ? -right : 0
        }
    }

    /// Increase/decrease indent. List items change nesting level; other paragraphs move by 0.5".
    public static func indent(increase: Bool, maximum: CGFloat) -> ParagraphTransform {
        { paragraph in
            if let item = paragraph.listItem {
                let level = min(max(item.level + (increase ? 1 : -1), 0), ListItem.maxLevel)
                let updated = item.with(level: level)
                paragraph.listItem = updated
                paragraph.style.headIndent = updated.textIndent
                paragraph.style.firstLineHeadIndent = updated.textIndent
                return
            }
            let step = ListItem.levelIndent
            let offset = paragraph.style.firstLineHeadIndent - paragraph.style.headIndent
            var head = paragraph.style.headIndent
            if increase {
                head = min((floor(head / step) + 1) * step, maximum)
            } else {
                head = max((ceil(head / step) - 1) * step, 0)
            }
            paragraph.style.headIndent = head
            paragraph.style.firstLineHeadIndent = max(0, head + offset)
        }
    }

    /// Puts the paragraph in a list (or takes it out when `item` is nil).
    public static func setList(_ item: ListItem?, keepIndent: Bool = false) -> ParagraphTransform {
        { paragraph in
            paragraph.listItem = item
            if let item {
                paragraph.style.headIndent = item.textIndent
                paragraph.style.firstLineHeadIndent = item.textIndent
            } else if !keepIndent {
                paragraph.style.headIndent = 0
                paragraph.style.firstLineHeadIndent = 0
            }
        }
    }

    /// Paragraph half of "Clear formatting".
    public static func clearFormatting() -> ParagraphTransform {
        { paragraph in
            let definition = paragraph.namedStyle.definition
            let fresh = DocumentDefaults.paragraphStyle()
            // Keep table cell membership: clearing formatting must not pull text out of a table.
            fresh.textBlocks = paragraph.style.textBlocks
            fresh.paragraphSpacingBefore = definition.spaceBefore
            fresh.paragraphSpacing = definition.spaceAfter
            fresh.lineHeightMultiple = definition.lineSpacing
            if let item = paragraph.listItem {
                fresh.headIndent = item.textIndent
                fresh.firstLineHeadIndent = item.textIndent
            }
            paragraph.style = fresh
        }
    }
}
