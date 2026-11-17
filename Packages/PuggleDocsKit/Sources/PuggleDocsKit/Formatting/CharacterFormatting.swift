import AppKit

/// A change applied to the attributes of one run (or to typing attributes).
public typealias AttributeTransform = (inout [NSAttributedString.Key: Any]) -> Void

/// Character-level formatting operations. They mutate attributed strings directly; callers that edit
/// a live text view wrap them in `shouldChangeText`/`didChangeText` so they are undoable.
public enum CharacterFormatting {
    public static let fontSizePresets: [CGFloat] = [8, 9, 10, 11, 12, 14, 18, 24, 30, 36, 48, 60, 72, 96]

    // MARK: Applying

    public static func apply(_ transform: AttributeTransform, to storage: NSMutableAttributedString, range: NSRange) {
        guard range.length > 0 else { return }
        storage.enumerateAttributes(in: range, options: []) { attributes, subrange, _ in
            var updated = attributes
            transform(&updated)
            storage.setAttributes(updated, range: subrange)
        }
    }

    public static func apply(_ transform: AttributeTransform, to attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var updated = attributes
        transform(&updated)
        return updated
    }

    // MARK: Transforms

    public static func modifyFont(_ change: @escaping (inout FontSpec) -> Void) -> AttributeTransform {
        { attributes in
            var spec = FontResolver.spec(from: attributes)
            change(&spec)
            FontResolver.apply(spec, to: &attributes)
        }
    }

    public static func setBold(_ on: Bool) -> AttributeTransform { modifyFont { $0.bold = on } }
    public static func setItalic(_ on: Bool) -> AttributeTransform { modifyFont { $0.italic = on } }
    public static func setFontFamily(_ family: String) -> AttributeTransform { modifyFont { $0.family = family } }

    public static func setFontSize(_ size: CGFloat) -> AttributeTransform {
        modifyFont { $0.size = min(max(size, FontResolver.minimumSize), FontResolver.maximumSize) }
    }

    /// Adds `delta` points to every run, keeping relative differences (the +/- buttons).
    public static func adjustFontSize(by delta: CGFloat) -> AttributeTransform {
        modifyFont { $0.size = min(max(($0.size + delta).rounded(), FontResolver.minimumSize), FontResolver.maximumSize) }
    }

    /// Moves every run to the next/previous preset size (⇧⌘. and ⇧⌘,).
    public static func stepFontSize(up: Bool) -> AttributeTransform {
        modifyFont { $0.size = nextPresetSize(after: $0.size, up: up) }
    }

    public static func nextPresetSize(after size: CGFloat, up: Bool) -> CGFloat {
        if up {
            return fontSizePresets.first { $0 > size } ?? min(size + 12, FontResolver.maximumSize)
        }
        return fontSizePresets.last { $0 < size } ?? max(size - 1, FontResolver.minimumSize)
    }

    public static func setUnderline(_ on: Bool) -> AttributeTransform {
        { $0[.underlineStyle] = on ? NSUnderlineStyle.single.rawValue : nil }
    }

    public static func setStrikethrough(_ on: Bool) -> AttributeTransform {
        { $0[.strikethroughStyle] = on ? NSUnderlineStyle.single.rawValue : nil }
    }

    public static func setTextColor(_ color: NSColor?) -> AttributeTransform {
        { $0[.foregroundColor] = color }
    }

    public static func setHighlight(_ color: NSColor?) -> AttributeTransform {
        { $0[.backgroundColor] = color }
    }

    /// 1 = superscript, -1 = subscript, 0 = normal baseline.
    public static func setBaseline(_ value: Int) -> AttributeTransform {
        { attributes in
            let spec = FontResolver.spec(from: attributes)
            attributes[.superscript] = value == 0 ? nil : value
            attributes[.baselineOffset] = nil
            FontResolver.apply(spec, to: &attributes)
        }
    }

    public static func setLink(_ url: URL?) -> AttributeTransform {
        { $0[.link] = url }
    }

    /// Resets character formatting to the paragraph style's defaults, keeping links.
    public static func clearFormatting(for style: NamedStyle) -> AttributeTransform {
        { attributes in
            let link = attributes[.link]
            let definition = style.definition
            let preserved = attributes.filter { ParagraphAttributeKeys.all.contains($0.key) }
            attributes = preserved
            attributes[.font] = definition.font
            attributes[.foregroundColor] = definition.color
            attributes[.link] = link
        }
    }

    // MARK: Queries

    /// True when `predicate` holds for every run in every range (or for `typing` when all ranges are empty).
    public static func allRuns(in storage: NSAttributedString, ranges: [NSRange], typing: [NSAttributedString.Key: Any],
                               satisfy predicate: ([NSAttributedString.Key: Any]) -> Bool) -> Bool {
        let nonEmpty = ranges.filter { $0.length > 0 }
        if nonEmpty.isEmpty { return predicate(typing) }
        for range in nonEmpty {
            var result = true
            storage.enumerateAttributes(in: range, options: []) { attributes, _, stop in
                if !predicate(attributes) {
                    result = false
                    stop.pointee = true
                }
            }
            if !result { return false }
        }
        return true
    }

    public static func isBold(_ attributes: [NSAttributedString.Key: Any]) -> Bool {
        FontResolver.spec(from: attributes).bold
    }

    public static func isItalic(_ attributes: [NSAttributedString.Key: Any]) -> Bool {
        FontResolver.spec(from: attributes).italic
    }

    public static func isUnderlined(_ attributes: [NSAttributedString.Key: Any]) -> Bool {
        ((attributes[.underlineStyle] as? Int) ?? 0) != 0
    }

    public static func isStruckThrough(_ attributes: [NSAttributedString.Key: Any]) -> Bool {
        ((attributes[.strikethroughStyle] as? Int) ?? 0) != 0
    }

    public static func baseline(_ attributes: [NSAttributedString.Key: Any]) -> Int {
        let value = (attributes[.superscript] as? Int) ?? 0
        return value > 0 ? 1 : (value < 0 ? -1 : 0)
    }
}
