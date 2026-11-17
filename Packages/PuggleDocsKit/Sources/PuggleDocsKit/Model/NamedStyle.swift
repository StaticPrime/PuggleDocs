import AppKit

/// The paragraph styles offered in the style dropdown, with the familiar default look.
public enum NamedStyle: String, CaseIterable, Sendable {
    case normal, title, subtitle, heading1, heading2, heading3, heading4, heading5, heading6

    public var displayName: String {
        switch self {
        case .normal: "Normal text"
        case .title: "Title"
        case .subtitle: "Subtitle"
        case .heading1: "Heading 1"
        case .heading2: "Heading 2"
        case .heading3: "Heading 3"
        case .heading4: "Heading 4"
        case .heading5: "Heading 5"
        case .heading6: "Heading 6"
        }
    }

    /// Style id written to `styles.xml`.
    public var docxStyleID: String {
        switch self {
        case .normal: "Normal"
        case .title: "Title"
        case .subtitle: "Subtitle"
        case .heading1: "Heading1"
        case .heading2: "Heading2"
        case .heading3: "Heading3"
        case .heading4: "Heading4"
        case .heading5: "Heading5"
        case .heading6: "Heading6"
        }
    }

    /// Built-in style name that Word and other editors recognise.
    public var docxStyleName: String {
        switch self {
        case .normal: "Normal"
        case .title: "Title"
        case .subtitle: "Subtitle"
        default: "heading \(headingLevel ?? 1)"
        }
    }

    /// 1...6 for headings, nil otherwise.
    public var headingLevel: Int? {
        switch self {
        case .heading1: 1
        case .heading2: 2
        case .heading3: 3
        case .heading4: 4
        case .heading5: 5
        case .heading6: 6
        default: nil
        }
    }

    public var isHeadingLike: Bool { self != .normal }

    /// Keyboard shortcut digit used with ⌥⌘ (0 = Normal text).
    public var shortcutDigit: String? {
        switch self {
        case .normal: "0"
        case .title, .subtitle: nil
        default: headingLevel.map(String.init)
        }
    }

    /// Matches a style name or id from a DOCX/ODT file ("heading 1", "Heading1", "Title"...).
    public static func matching(styleName: String) -> NamedStyle? {
        let key = styleName.lowercased().replacingOccurrences(of: " ", with: "")
        switch key {
        case "normal": return .normal
        case "title": return .title
        case "subtitle": return .subtitle
        default:
            if key.hasPrefix("heading"), let level = Int(key.dropFirst("heading".count)), (1...6).contains(level) {
                return NamedStyle.allCases.first { $0.headingLevel == level }
            }
            return nil
        }
    }

    public var definition: StyleDefinition {
        switch self {
        case .normal: StyleDefinition(fontSize: 11)
        case .title: StyleDefinition(fontSize: 26, spaceAfter: 3)
        case .subtitle: StyleDefinition(fontSize: 15, colorHex: "666666", spaceAfter: 16)
        case .heading1: StyleDefinition(fontSize: 20, spaceBefore: 20, spaceAfter: 6)
        case .heading2: StyleDefinition(fontSize: 16, spaceBefore: 18, spaceAfter: 6)
        case .heading3: StyleDefinition(fontSize: 14, colorHex: "434343", spaceBefore: 16, spaceAfter: 4)
        case .heading4: StyleDefinition(fontSize: 12, colorHex: "666666", spaceBefore: 14, spaceAfter: 4)
        case .heading5: StyleDefinition(fontSize: 11, colorHex: "666666", spaceBefore: 12, spaceAfter: 4)
        case .heading6: StyleDefinition(fontSize: 11, italic: true, colorHex: "666666", spaceBefore: 12, spaceAfter: 4)
        }
    }
}

public struct StyleDefinition: Sendable, Equatable {
    public var fontFamily: String = "Arial"
    public var fontSize: CGFloat
    public var bold: Bool = false
    public var italic: Bool = false
    public var colorHex: String = "000000"
    public var spaceBefore: CGFloat = 0
    public var spaceAfter: CGFloat = 0
    public var lineSpacing: CGFloat = 1.15

    public var color: NSColor { NSColor(hex: colorHex) ?? .black }

    public var font: NSFont {
        FontResolver.font(family: fontFamily, size: fontSize, bold: bold, italic: italic)
    }

    public var characterAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color]
    }

    /// Paragraph style for this definition. Alignment and indents are taken from `base`.
    public func paragraphStyle(basedOn base: NSParagraphStyle? = nil) -> NSParagraphStyle {
        let style = (base?.mutableCopy() as? NSMutableParagraphStyle) ?? DocumentDefaults.paragraphStyle()
        style.paragraphSpacingBefore = spaceBefore
        style.paragraphSpacing = spaceAfter
        style.lineHeightMultiple = lineSpacing
        return style.copy() as! NSParagraphStyle
    }
}

public extension NamedStyle {
    /// Complete attributes for an empty paragraph of this style (used as typing attributes).
    func attributes(basedOn base: NSParagraphStyle? = nil) -> [NSAttributedString.Key: Any] {
        var attributes = definition.characterAttributes
        attributes[.paragraphStyle] = definition.paragraphStyle(basedOn: base)
        attributes[.pdNamedStyle] = rawValue
        return attributes
    }
}

public enum DocumentDefaults {
    public static let defaultTabInterval: CGFloat = 36

    public static func paragraphStyle() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = NamedStyle.normal.definition.lineSpacing
        style.defaultTabInterval = defaultTabInterval
        style.tabStops = []
        return style
    }

    public static var typingAttributes: [NSAttributedString.Key: Any] {
        NamedStyle.normal.attributes()
    }
}
