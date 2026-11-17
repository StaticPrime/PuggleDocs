import AppKit

/// Run properties with "unset" represented as nil so style layers can be merged.
struct DocxRunProperties {
    var fontFamily: String?
    var themeFont: String?
    var size: CGFloat?
    var bold: Bool?
    var italic: Bool?
    var underline: Int?
    var strike: Bool?
    var color: String?
    var highlight: String?
    var baseline: Int?
    var hidden: Bool?

    mutating func merge(_ other: DocxRunProperties) {
        if let value = other.fontFamily { fontFamily = value; themeFont = nil }
        if let value = other.themeFont { themeFont = value; fontFamily = nil }
        if let value = other.size { size = value }
        if let value = other.bold { bold = value }
        if let value = other.italic { italic = value }
        if let value = other.underline { underline = value }
        if let value = other.strike { strike = value }
        if let value = other.color { color = value }
        if let value = other.highlight { highlight = value }
        if let value = other.baseline { baseline = value }
        if let value = other.hidden { hidden = value }
    }

    func merged(_ other: DocxRunProperties) -> DocxRunProperties {
        var copy = self
        copy.merge(other)
        return copy
    }

    static let highlightColors: [String: String] = [
        "yellow": "FFFF00", "green": "00FF00", "cyan": "00FFFF", "magenta": "FF00FF", "blue": "0000FF", "red": "FF0000",
        "darkBlue": "000080", "darkCyan": "008080", "darkGreen": "008000", "darkMagenta": "800080", "darkRed": "800000",
        "darkYellow": "808000", "darkGray": "808080", "lightGray": "C0C0C0", "black": "000000", "white": "FFFFFF",
    ]

    init() {}

    init(_ node: XNode?) {
        guard let node else { return }
        for child in node.children {
            switch child.name {
            case "rFonts":
                if let family = child.attr("ascii") ?? child.attr("hAnsi") ?? child.attr("cs") ?? child.attr("eastAsia") {
                    fontFamily = family
                } else if let theme = child.attr("asciiTheme") ?? child.attr("hAnsiTheme") {
                    themeFont = theme
                }
            case "b": bold = child.isOn
            case "i": italic = child.isOn
            case "strike", "dstrike": strike = child.isOn
            case "u":
                let value = child.attr("val") ?? "single"
                underline = value == "none" ? 0 : (value == "double" ? NSUnderlineStyle.double.rawValue : NSUnderlineStyle.single.rawValue)
            case "color":
                if let value = child.attr("val") { color = value }
            case "sz":
                if let value = child.attr("val").flatMap(Double.init) { size = CGFloat(value) / 2 }
            case "highlight":
                if let value = child.attr("val") { highlight = value == "none" ? "" : DocxRunProperties.highlightColors[value] ?? "" }
            case "shd":
                if let fill = child.attr("fill"), fill.lowercased() != "auto", fill.count == 6 { highlight = fill.uppercased() }
            case "vertAlign":
                switch child.attr("val") {
                case "superscript": baseline = 1
                case "subscript": baseline = -1
                default: baseline = 0
                }
            case "vanish": hidden = child.isOn
            default: break
            }
        }
    }
}

enum DocxLineSpacing {
    case multiple(CGFloat)
    case exact(CGFloat)
    case atLeast(CGFloat)
}

struct DocxParagraphProperties {
    var styleID: String?
    var alignment: NSTextAlignment?
    var spaceBefore: CGFloat?
    var spaceAfter: CGFloat?
    var lineSpacing: DocxLineSpacing?
    var indentLeft: CGFloat?
    var indentRight: CGFloat?
    /// Positive for a first-line indent, negative for a hanging indent.
    var indentFirstLine: CGFloat?
    var numID: Int?
    var level: Int?
    var pageBreakBefore: Bool?
    var tabs: [NSTextTab]?

    init() {}

    init(_ node: XNode?) {
        guard let node else { return }
        for child in node.children {
            switch child.name {
            case "pStyle": styleID = child.attr("val")
            case "jc":
                switch child.attr("val") {
                case "center": alignment = .center
                case "right", "end": alignment = .right
                case "both", "distribute", "justify", "lowKashida", "mediumKashida", "highKashida", "thaiDistribute": alignment = .justified
                default: alignment = .left
                }
            case "spacing":
                if let value = DocxParagraphProperties.points(child.attr("before")) { spaceBefore = value }
                if let value = DocxParagraphProperties.points(child.attr("after")) { spaceAfter = value }
                if let line = child.attr("line").flatMap(Double.init) {
                    switch child.attr("lineRule") ?? "auto" {
                    case "exact": lineSpacing = .exact(CGFloat(line) / 20)
                    case "atLeast": lineSpacing = .atLeast(CGFloat(line) / 20)
                    default: lineSpacing = .multiple(CGFloat(line) / 240)
                    }
                }
            case "ind":
                if let value = DocxParagraphProperties.points(child.attr("left") ?? child.attr("start")) { indentLeft = value }
                if let value = DocxParagraphProperties.points(child.attr("right") ?? child.attr("end")) { indentRight = value }
                if let value = DocxParagraphProperties.points(child.attr("hanging")) {
                    indentFirstLine = -value
                } else if let value = DocxParagraphProperties.points(child.attr("firstLine")) {
                    indentFirstLine = value
                }
            case "numPr":
                if let value = child.child("numId")?.attr("val").flatMap(Int.init) { numID = value }
                if let value = child.child("ilvl")?.attr("val").flatMap(Int.init) { level = value }
            case "pageBreakBefore": pageBreakBefore = child.isOn
            case "tabs":
                tabs = child.children("tab").compactMap { tab in
                    guard let position = DocxParagraphProperties.points(tab.attr("pos")), position > 0 else { return nil }
                    switch tab.attr("val") {
                    case "clear", "bar": return nil
                    case "center": return NSTextTab(textAlignment: .center, location: position)
                    case "right", "end": return NSTextTab(textAlignment: .right, location: position)
                    case "decimal":
                        return NSTextTab(textAlignment: .right, location: position, options: [.columnTerminators: NSTextTab.columnTerminators(for: .current)])
                    default: return NSTextTab(textAlignment: .left, location: position)
                    }
                }
            default: break
            }
        }
    }

    mutating func merge(_ other: DocxParagraphProperties) {
        if let value = other.styleID { styleID = value }
        if let value = other.alignment { alignment = value }
        if let value = other.spaceBefore { spaceBefore = value }
        if let value = other.spaceAfter { spaceAfter = value }
        if let value = other.lineSpacing { lineSpacing = value }
        if let value = other.indentLeft { indentLeft = value }
        if let value = other.indentRight { indentRight = value }
        if let value = other.indentFirstLine { indentFirstLine = value }
        if let value = other.numID { numID = value }
        if let value = other.level { level = value }
        if let value = other.pageBreakBefore { pageBreakBefore = value }
        if let value = other.tabs { tabs = value }
    }

    static func points(_ twips: String?) -> CGFloat? {
        guard let twips, let value = Double(twips) else { return nil }
        return CGFloat(value) / 20
    }

    func paragraphStyle() -> NSParagraphStyle {
        let style = DocumentDefaults.paragraphStyle()
        style.alignment = alignment ?? .natural
        style.paragraphSpacingBefore = max(0, spaceBefore ?? 0)
        style.paragraphSpacing = max(0, spaceAfter ?? 0)
        switch lineSpacing ?? .multiple(1) {
        case .multiple(let value): style.lineHeightMultiple = max(0.5, value)
        case .exact(let value):
            style.lineHeightMultiple = 0
            style.minimumLineHeight = value
            style.maximumLineHeight = value
        case .atLeast(let value):
            style.lineHeightMultiple = 0
            style.minimumLineHeight = value
        }
        let left = max(0, indentLeft ?? 0)
        style.headIndent = left
        style.firstLineHeadIndent = max(0, left + (indentFirstLine ?? 0))
        if let right = indentRight, right > 0 { style.tailIndent = -right }
        if let tabs { style.tabStops = tabs }
        return style.copy() as! NSParagraphStyle
    }
}

struct DocxStyle {
    let id: String
    let type: String
    let name: String?
    let basedOn: String?
    let paragraph: DocxParagraphProperties
    let run: DocxRunProperties
    let isDefault: Bool
}

/// `styles.xml` with inheritance resolution.
struct DocxStyleSheet {
    var styles: [String: DocxStyle] = [:]
    var defaultRun = DocxRunProperties()
    var defaultParagraph = DocxParagraphProperties()
    var defaultParagraphStyleID: String?

    init() {}

    init(_ root: XNode) {
        if let defaults = root.child("docDefaults") {
            defaultRun = DocxRunProperties(defaults.child("rPrDefault")?.child("rPr"))
            defaultParagraph = DocxParagraphProperties(defaults.child("pPrDefault")?.child("pPr"))
        }
        for node in root.children("style") {
            guard let id = node.attr("styleId") else { continue }
            let style = DocxStyle(id: id, type: node.attr("type") ?? "paragraph", name: node.child("name")?.attr("val"),
                                  basedOn: node.child("basedOn")?.attr("val"),
                                  paragraph: DocxParagraphProperties(node.child("pPr")),
                                  run: DocxRunProperties(node.child("rPr")),
                                  isDefault: node.attr("default").map { $0 == "1" || $0 == "true" } ?? false)
            styles[id] = style
            if style.type == "paragraph" && style.isDefault { defaultParagraphStyleID = id }
        }
    }

    /// The chain from the root ancestor down to `id`.
    func chain(_ id: String?) -> [DocxStyle] {
        var result: [DocxStyle] = []
        var current = id
        var seen = Set<String>()
        while let key = current, let style = styles[key], !seen.contains(key) {
            seen.insert(key)
            result.insert(style, at: 0)
            current = style.basedOn
        }
        return result
    }

    func paragraphProperties(styleID: String?) -> DocxParagraphProperties {
        var result = defaultParagraph
        for style in chain(styleID ?? defaultParagraphStyleID) { result.merge(style.paragraph) }
        return result
    }

    func runProperties(paragraphStyleID: String?, characterStyleID: String?) -> DocxRunProperties {
        var result = defaultRun
        for style in chain(paragraphStyleID ?? defaultParagraphStyleID) { result.merge(style.run) }
        for style in chain(characterStyleID) { result.merge(style.run) }
        return result
    }

    /// The named style a paragraph style corresponds to, following `basedOn` links.
    func namedStyle(for id: String?) -> NamedStyle {
        let styles = chain(id ?? defaultParagraphStyleID)
        if styles.isEmpty, let id { return NamedStyle.matching(styleName: id) ?? .normal }
        for style in styles.reversed() {
            if let match = NamedStyle.matching(styleName: style.name ?? style.id) ?? NamedStyle.matching(styleName: style.id) {
                return match
            }
        }
        return .normal
    }
}

/// `numbering.xml`.
struct DocxNumbering {
    struct Level {
        var format = "decimal"
        var text = "%1."
        var start = 1
    }

    var abstractLevels: [Int: [Int: Level]] = [:]
    var numToAbstract: [Int: Int] = [:]
    var restartedNums: Set<Int> = []

    init() {}

    init(_ root: XNode) {
        for abstract in root.children("abstractNum") {
            guard let id = abstract.attr("abstractNumId").flatMap(Int.init) else { continue }
            var levels: [Int: Level] = [:]
            for node in abstract.children("lvl") {
                guard let index = node.attr("ilvl").flatMap(Int.init) else { continue }
                var level = Level()
                level.format = node.child("numFmt")?.attr("val") ?? "decimal"
                level.text = node.child("lvlText")?.attr("val") ?? ""
                level.start = node.child("start")?.attr("val").flatMap(Int.init) ?? 1
                levels[index] = level
            }
            abstractLevels[id] = levels
        }
        for num in root.children("num") {
            guard let numID = num.attr("numId").flatMap(Int.init),
                  let abstractID = num.child("abstractNumId")?.attr("val").flatMap(Int.init) else { continue }
            numToAbstract[numID] = abstractID
            if num.children("lvlOverride").contains(where: { $0.child("startOverride") != nil }) {
                restartedNums.insert(numID)
            }
        }
    }

    func listItem(numID: Int, level: Int) -> ListItem? {
        guard numID != 0, let abstractID = numToAbstract[numID], let levels = abstractLevels[abstractID] else { return nil }
        let level = min(max(level, 0), ListItem.maxLevel)
        // Word continues numbering across instances of the same definition unless one restarts it.
        let listID = restartedNums.contains(numID) ? "docx-num-\(numID)" : "docx-abstract-\(abstractID)"
        let preset = DocxNumbering.preset(levels)
        let glyph = levels[level]?.text ?? ""
        let checked = preset == .checkbox && ["☑", "☒", "✓", "✔", "\u{F0FE}"].contains(glyph)
        return ListItem(listID: listID, preset: preset, level: level, isChecked: checked)
    }

    static func preset(_ levels: [Int: Level]) -> ListPreset {
        let first = levels[0] ?? Level()
        let second = levels[1]
        switch first.format {
        case "bullet":
            let glyph = first.text
            if ["☐", "☑", "☒", "❑", "\u{F0A8}", "\u{F06F}"].contains(glyph) { return .checkbox }
            if glyph.contains("❖") || glyph == "\u{F076}" { return .diamondArrowSquare }
            if glyph.contains("➔") || glyph.contains("→") || glyph == "\u{F0E0}" { return .arrowDiamondDisc }
            if glyph.contains("★") { return .starCircleSquare }
            if glyph.contains("❏") { return .boxArrowSquare }
            if glyph.contains("–") || glyph == "-" { return .dashCircleSquare }
            return .discCircleSquare
        case "upperLetter":
            return second?.format == "decimal" ? .upperAlphaDecimal : .upperAlphaLowerAlpha
        case "upperRoman":
            return .upperRomanUpperAlpha
        default:
            if first.text.contains(")") { return .decimalParen }
            if let second, second.text.contains("%1") { return .decimalOutline }
            return .decimalAlphaRoman
        }
    }
}
