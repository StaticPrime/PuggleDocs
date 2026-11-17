import AppKit

/// Reads web pages (.html) into editor text.
public enum HtmlReader {
    public static func read(_ data: Data) throws -> DocumentContent {
        let source = decode(data)
        let document: XMLDocument
        // Well-formed pages (XHTML, including PuggleDocs' own) are read as they are; tidying would move
        // spaces at the ends of inline elements. Everything else goes through HTML Tidy.
        if let strict = ExactXMLTree.parse(source), strict.rootElement()?.localName?.lowercased() == "html" {
            document = strict
        } else {
            do {
                document = try XMLDocument(xmlString: source, options: [.documentTidyHTML])
            } catch {
                throw DocumentIOError.unreadable("The web page could not be read.")
            }
        }
        var reader = HtmlDocumentReader(document: document)
        return reader.run()
    }

    /// Decodes using a byte-order mark or `<meta charset>`, falling back to UTF-8 then Windows-1252.
    static func decode(_ data: Data) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]), let text = String(data: data.dropFirst(3), encoding: .utf8) { return text }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let text = String(data: data, encoding: .utf16) { return text }
        let head = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
        if let range = head.range(of: "charset=") {
            let name = head[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding(String(name) as CFString))
            if encoding != UInt(kCFStringEncodingInvalidId), let text = String(data: data, encoding: String.Encoding(rawValue: encoding)) { return text }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }
}

/// A small subset of CSS: rules for `tag`, `.class` and `tag.class` selectors, plus `@page`.
struct CSSRules {
    var tags: [String: [String: String]] = [:]
    var classes: [String: [String: String]] = [:]
    var tagClasses: [String: [String: String]] = [:]
    var page: [String: String] = [:]

    init() {}

    init(_ css: String) {
        var text = css
        while let start = text.range(of: "/*"), let end = text.range(of: "*/", range: start.upperBound..<text.endIndex) {
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        var index = text.startIndex
        while let open = text[index...].firstIndex(of: "{") {
            let selector = text[index..<open].trimmingCharacters(in: .whitespacesAndNewlines)
            // Find the matching close brace (at-rules such as @media nest).
            var depth = 0
            var close = open
            var cursor = open
            while cursor < text.endIndex {
                if text[cursor] == "{" { depth += 1 }
                if text[cursor] == "}" { depth -= 1; if depth == 0 { close = cursor; break } }
                cursor = text.index(after: cursor)
            }
            guard close > open else { break }
            let body = String(text[text.index(after: open)..<close])
            if selector.lowercased().hasPrefix("@page") {
                page.merge(CSSRules.declarations(body)) { _, new in new }
            } else if !selector.hasPrefix("@") {
                let declarations = CSSRules.declarations(body)
                for part in selector.split(separator: ",") {
                    add(selector: String(part), declarations: declarations)
                }
            }
            index = text.index(after: close)
        }
    }

    private mutating func add(selector: String, declarations: [String: String]) {
        let last = selector.split(whereSeparator: { " >+~".contains($0) }).last.map(String.init) ?? ""
        guard !last.isEmpty, !last.contains(":"), !last.contains("["), !last.hasPrefix("#"), last != "*" else { return }
        let pieces = last.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let tag = pieces[0].lowercased()
        let classNames = pieces.dropFirst()
        if classNames.isEmpty {
            tags[tag, default: [:]].merge(declarations) { _, new in new }
        } else if tag.isEmpty {
            for name in classNames { classes[name, default: [:]].merge(declarations) { _, new in new } }
        } else {
            for name in classNames { tagClasses["\(tag).\(name)", default: [:]].merge(declarations) { _, new in new } }
        }
    }

    static func declarations(_ body: String) -> [String: String] {
        var result: [String: String] = [:]
        for declaration in body.split(separator: ";") {
            guard let colon = declaration.firstIndex(of: ":") else { continue }
            let name = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = declaration[declaration.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if let important = value.range(of: "!important") { value.removeSubrange(important) }
            result[name] = value.trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    func declarations(for element: XMLElement) -> [String: String] {
        let tag = (element.localName ?? "").lowercased()
        var result = tags[tag] ?? [:]
        let classNames = (element.value("class") ?? "").split(separator: " ").map(String.init)
        for name in classNames { result.merge(classes[name] ?? [:]) { _, new in new } }
        for name in classNames { result.merge(tagClasses["\(tag).\(name)"] ?? [:]) { _, new in new } }
        if let inline = element.value("style") { result.merge(CSSRules.declarations(inline)) { _, new in new } }
        return result
    }
}

private struct HtmlDocumentReader {
    struct TextStyle {
        var family = FontResolver.defaultFamily
        var size: CGFloat = 11
        var bold = false
        var italic = false
        var underline = false
        var strike = false
        var color = "000000"
        var background: String?
        var baseline = 0
        var preserveWhitespace = false
        /// `.pdComments` for the text (from `data-pd-comments`); not part of the cache key.
        var comments: String?
        /// A suggestion written by PuggleDocs as `<ins>`/`<del>` with `data-pd-suggestion`.
        var suggestion: SuggestionMark?

        var key: String { "\(family)|\(size)|\(bold)|\(italic)|\(underline)|\(strike)|\(color)|\(background ?? "")|\(baseline)" }
    }

    struct BlockStyle {
        var alignment: NSTextAlignment?
        var marginLeft: CGFloat = 0
        var marginRight: CGFloat = 0
        var textIndent: CGFloat = 0
        var marginTop: CGFloat = 0
        var marginBottom: CGFloat = 0
        var lineSpacing: DocxLineSpacing?
        var breakBefore = false
        var breakAfter = false
    }

    struct Paragraph {
        var named: NamedStyle
        var block: BlockStyle
        var listItem: ListItem?
        var explicit: Bool
        var buffer = NSMutableAttributedString()
        var pendingSpace = false
        /// Where the collapsed space came from: it keeps that text's formatting, as in a browser.
        var pendingSpaceStyle: (text: TextStyle, link: String?)?
        var hasContent = false
        var lastText: TextStyle
    }

    struct ListFrame {
        let listID: String
        let preset: ListPreset
        let level: Int
        var itemCount = 0
        let start: Int
    }

    let document: XMLDocument
    var css = CSSRules()
    var output = NSMutableAttributedString()
    var warnings: Set<ImportWarning> = []
    var pageSetup = PageSetup.localeDefault
    var paragraph: Paragraph?
    var blockContext: [(named: NamedStyle, block: BlockStyle, text: TextStyle)] = []
    var lists: [ListFrame] = []
    var listCounter = 0
    var lastTopList: (listID: String, preset: ListPreset, next: Int)?
    var attributeCache: [String: [NSAttributedString.Key: Any]] = [:]

    init(document: XMLDocument) { self.document = document }

    mutating func run() -> DocumentContent {
        guard let root = document.rootElement() else { return DocumentContent(text: output) }
        let styleText = collectStyles(root)
        css = CSSRules(styleText)
        let body = root.firstDescendant("body") ?? root
        readPageSetup(body: body)
        var base = TextStyle()
        apply(css.declarations(for: body), to: &base)
        base.background = nil // The page color, not a highlight.
        blockContext = [(.normal, BlockStyle(), base)]
        walk(children: body, text: base, link: nil)
        flush()
        trimTrailingNewline(output)
        DocumentIO.normalizeImported(output)
        CommentAnchors.normalize(output, threads: threads)
        return DocumentContent(text: output, pageSetup: pageSetup, warnings: warnings, header: header, footer: footer, comments: threads)
    }

    var threads: [CommentThread] = []

    /// The comment list written by PuggleDocs after the document.
    mutating func readComments(_ list: XMLElement) {
        let iso = ISO8601DateFormatter()
        func entry(_ element: XMLElement) -> (author: String, date: Date, text: String) {
            let head = element.elementChildren.first { $0.value("data-pd-comment-head") != nil }
            let author = head?.elementChildren.first { $0.value("data-pd-author") != nil }?.stringValue ?? "Unknown"
            let date = head?.elementChildren.first { $0.value("data-pd-date") != nil }?.value("data-pd-date").flatMap(iso.date(from:)) ?? Date()
            let body = element.elementChildren.first { $0.value("data-pd-comment-text") != nil }
            return (author, date, body.map(Self.plainText) ?? "")
        }
        for node in list.elementChildren {
            guard let id = node.value("data-pd-thread") else { continue }
            let main = entry(node)
            let replies = node.elementChildren.filter { $0.value("data-pd-reply") != nil }.map { reply in
                let value = entry(reply)
                return CommentReply(author: value.author, date: value.date, text: value.text)
            }
            threads.append(CommentThread(id: id, author: main.author, date: main.date, text: main.text, replies: replies,
                                         resolved: node.value("data-pd-resolved") == "true"))
        }
    }

    /// Text with HTML whitespace collapsing and `<br>` as line breaks.
    static func plainText(_ element: XMLElement) -> String {
        func collect(_ element: XMLElement) -> String {
            var text = ""
            for child in element.children ?? [] {
                if child.kind == .text {
                    text += (child.stringValue ?? "").replacingOccurrences(of: "\n", with: " ")
                } else if let element = child as? XMLElement {
                    text += (element.localName ?? "").lowercased() == "br" ? "\n" : collect(element)
                }
            }
            return text
        }
        return collect(element).components(separatedBy: "\n").map { line in
            line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).joined(separator: " ")
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var header: NSAttributedString?
    var footer: NSAttributedString?

    func trimTrailingNewline(_ text: NSMutableAttributedString) {
        DocumentIO.trimFinalNewline(text)
    }

    /// Reads a PuggleDocs header or footer block into its own text.
    mutating func readHeaderFooter(_ element: XMLElement, text: TextStyle) -> NSAttributedString? {
        flush()
        let body = output
        let savedLists = lists
        output = NSMutableAttributedString()
        lists = []
        walk(children: element, text: text, link: nil)
        flush()
        trimTrailingNewline(output)
        let result = output.length > 0 ? NSAttributedString(attributedString: output) : nil
        output = body
        lists = savedLists
        if let result {
            let normalized = NSMutableAttributedString(attributedString: result)
            DocumentIO.normalizeImported(normalized)
            return normalized
        }
        return nil
    }

    func collectStyles(_ element: XMLElement) -> String {
        var text = ""
        for child in element.elementChildren {
            if child.localName?.lowercased() == "style" { text += (child.stringValue ?? "") + "\n" } else { text += collectStyles(child) }
        }
        return text
    }

    mutating func readPageSetup(body: XMLElement) {
        var setup = pageSetup
        if let size = css.page["size"]?.lowercased() {
            let parts = size.split(separator: " ").map(String.init)
            let lengths = parts.compactMap { Lengths.points($0) }
            if lengths.count == 2 {
                setup = .from(pageSize: CGSize(width: lengths[0], height: lengths[1]), margins: setup.margins)
            } else if parts.contains("a4") {
                setup = .a4
            } else if parts.contains("letter") {
                setup = .letter
            }
            if parts.contains("landscape") { setup.orientation = .landscape }
        }
        if let margins = css.page["margin"].map(boxValues) { setup.margins = margins }
        let bodyStyle = css.declarations(for: body)
        if css.page["margin"] == nil, let padding = bodyStyle["padding"].map(boxValues), let width = Lengths.points(bodyStyle["max-width"]) {
            // Some web editors export page margins as body padding around a fixed-width body.
            setup.margins = padding
            setup = .from(pageSize: CGSize(width: width + padding.left + padding.right, height: setup.pageSize.height), margins: padding)
        }
        if let color = Lengths.hexColor(bodyStyle["background-color"] ?? bodyStyle["background"]), color != "FFFFFF" {
            setup.pageColorHex = color
        }
        if setup.hasValidMargins { pageSetup = setup }
    }

    func boxValues(_ value: String) -> PageMargins {
        let values = value.split(separator: " ").compactMap { Lengths.points(String($0)) }
        switch values.count {
        case 1: return .uniform(values[0])
        case 2: return PageMargins(top: values[0], left: values[1], bottom: values[0], right: values[1])
        case 3: return PageMargins(top: values[0], left: values[1], bottom: values[2], right: values[1])
        case 4: return PageMargins(top: values[0], left: values[3], bottom: values[2], right: values[1])
        default: return .uniform(72)
        }
    }

    // MARK: Styles

    func apply(_ declarations: [String: String], to text: inout TextStyle) {
        if let family = declarations["font-family"] {
            let first = (family.split(separator: ",").first.map(String.init) ?? family).trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
            switch first.lowercased() {
            case "serif": text.family = "Times New Roman"
            case "sans-serif", "system-ui", "-apple-system": text.family = FontResolver.defaultFamily
            case "monospace": text.family = "Courier New"
            case "": break
            default: text.family = first
            }
        }
        if let size = declarations["font-size"] { text.size = fontSize(size, parent: text.size) }
        if let font = declarations["font"] {
            for token in font.split(separator: " ") {
                if let size = Lengths.points(String(token.split(separator: "/").first ?? token)) { text.size = size }
            }
        }
        if let weight = declarations["font-weight"]?.lowercased() {
            text.bold = weight == "bold" || weight == "bolder" || (Int(weight) ?? 400) >= 600
        }
        if let style = declarations["font-style"]?.lowercased() { text.italic = style == "italic" || style == "oblique" }
        if let decoration = (declarations["text-decoration"] ?? declarations["text-decoration-line"])?.lowercased() {
            if decoration.contains("none") { text.underline = false; text.strike = false }
            if decoration.contains("underline") { text.underline = true }
            if decoration.contains("line-through") { text.strike = true }
        }
        if let color = Lengths.hexColor(declarations["color"]) { text.color = color }
        if let background = declarations["background-color"] ?? declarations["background"] {
            text.background = Lengths.hexColor(background.split(separator: " ").first.map(String.init))
        }
        if let align = declarations["vertical-align"]?.lowercased() {
            text.baseline = align == "super" ? 1 : (align == "sub" ? -1 : (align == "baseline" ? 0 : text.baseline))
        }
        if let whiteSpace = declarations["white-space"]?.lowercased() {
            text.preserveWhitespace = whiteSpace.hasPrefix("pre") || whiteSpace == "break-spaces"
        }
    }

    func fontSize(_ value: String, parent: CGFloat) -> CGFloat {
        let keywords: [String: CGFloat] = ["xx-small": 7, "x-small": 7.5, "small": 10, "medium": 12, "large": 13.5, "x-large": 18, "xx-large": 24]
        let lower = value.lowercased().trimmingCharacters(in: .whitespaces)
        if let keyword = keywords[lower] { return keyword }
        if lower == "smaller" { return parent * 0.83 }
        if lower == "larger" { return parent * 1.2 }
        if let factor = Lengths.percentage(lower) { return parent * factor }
        if lower.hasSuffix("em"), let number = Double(lower.replacingOccurrences(of: "rem", with: "").replacingOccurrences(of: "em", with: "")) {
            return parent * CGFloat(number)
        }
        return Lengths.points(lower) ?? parent
    }

    func blockStyle(_ declarations: [String: String]) -> BlockStyle {
        var block = BlockStyle()
        switch declarations["text-align"]?.lowercased() {
        case "center": block.alignment = .center
        case "right", "end": block.alignment = .right
        case "justify": block.alignment = .justified
        case "left", "start": block.alignment = .left
        default: break
        }
        block.marginLeft = (Lengths.points(declarations["margin-left"]) ?? 0) + (Lengths.points(declarations["padding-left"]) ?? 0)
        block.marginRight = Lengths.points(declarations["margin-right"]) ?? 0
        block.textIndent = Lengths.points(declarations["text-indent"]) ?? 0
        block.marginTop = max(0, Lengths.points(declarations["margin-top"]) ?? Lengths.points(declarations["padding-top"]) ?? 0)
        block.marginBottom = max(0, Lengths.points(declarations["margin-bottom"]) ?? Lengths.points(declarations["padding-bottom"]) ?? 0)
        if let margin = declarations["margin"] {
            let box = boxValues(margin)
            if declarations["margin-top"] == nil { block.marginTop = max(0, box.top) }
            if declarations["margin-bottom"] == nil { block.marginBottom = max(0, box.bottom) }
            if declarations["margin-left"] == nil { block.marginLeft = max(0, box.left) }
        }
        if let height = declarations["line-height"]?.lowercased() {
            if height == "normal" {
                block.lineSpacing = .multiple(1)
            } else if let factor = Lengths.percentage(height) {
                block.lineSpacing = .multiple(factor)
            } else if let number = Double(height) {
                block.lineSpacing = .multiple(CGFloat(number))
            } else if let points = Lengths.points(height) {
                block.lineSpacing = .exact(points)
            }
        }
        let before = (declarations["page-break-before"] ?? declarations["break-before"])?.lowercased()
        let after = (declarations["page-break-after"] ?? declarations["break-after"])?.lowercased()
        block.breakBefore = before == "always" || before == "page"
        block.breakAfter = after == "always" || after == "page"
        return block
    }

    // MARK: Walking

    static let skipped: Set<String> = ["head", "script", "style", "title", "noscript", "template", "meta", "link", "object", "iframe", "svg", "canvas", "video", "audio"]
    static let blocks: Set<String> = ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "section", "article", "header",
                                      "footer", "main", "nav", "aside", "address", "center", "figure", "figcaption", "dd", "dt", "dl",
                                      "form", "fieldset", "legend", "caption", "details", "summary", "td", "th"]
    static let boxes: Set<String> = ["body", "html", "table", "thead", "tbody", "tfoot", "tr", "ul", "ol", "li", "hr"]
    static let explicitBlocks: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "li", "dt", "dd"]

    mutating func walk(children element: XMLElement, text: TextStyle, link: String?) {
        for child in element.children ?? [] {
            if child.kind == .text {
                appendText(child.stringValue ?? "", text: text, link: link)
            } else if let element = child as? XMLElement {
                walk(element, text: text, link: link)
            }
        }
    }

    mutating func walk(_ element: XMLElement, text inherited: TextStyle, link: String?) {
        let tag = (element.localName ?? "").lowercased()
        if Self.skipped.contains(tag) { return }
        let declarations = css.declarations(for: element)
        if declarations["display"]?.lowercased() == "none", tag != "hr" { return }
        var text = inherited
        switch tag {
        case "b", "strong": text.bold = true
        case "i", "em", "cite", "dfn", "var": text.italic = true
        case "u", "ins": text.underline = true
        case "s", "strike", "del": text.strike = true
        case "sup": text.baseline = 1
        case "sub": text.baseline = -1
        case "code", "kbd", "tt", "samp": text.family = "Courier New"
        case "pre": text.family = "Courier New"; text.preserveWhitespace = true
        case "mark": text.background = "FFFF00"
        case "small": text.size *= 0.83
        case "big": text.size *= 1.17
        case "font":
            if let face = element.value("face") { text.family = face.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? face }
            if let color = Lengths.hexColor(element.value("color")) { text.color = color }
            if let size = element.value("size").flatMap(Int.init) { text.size = [7, 7.5, 10, 12, 13.5, 18, 24][min(max(size, 1), 7) - 1] }
        default: break
        }
        if tag == "ins" || tag == "del", let id = element.value("data-pd-suggestion") {
            text.underline = inherited.underline
            text.strike = inherited.strike
            let date = Suggestions.date(element.value("data-pd-date")) ?? Date(timeIntervalSince1970: 0)
            text.suggestion = SuggestionMark(id: id, kind: tag == "ins" ? .insertion : .deletion,
                                             author: element.value("data-pd-author") ?? "Unknown", date: date)
        }
        let named = namedStyle(tag: tag, element: element)
        if let named, let level = named.headingLevel ?? (named == .title || named == .subtitle ? 0 : nil), level >= 0 {
            // Headings and titles start from the familiar style definitions; explicit CSS still wins below.
            let definition = named.definition
            text.size = definition.fontSize
            text.color = definition.colorHex
            text.italic = definition.italic
            text.bold = definition.bold
        }
        apply(declarations, to: &text)
        // A block's background is a box, not a text highlight (and CSS backgrounds don't inherit).
        if Self.blocks.contains(tag) || Self.boxes.contains(tag) { text.background = inherited.background }

        let classNames = (element.value("class") ?? "").split(separator: " ")
        if tag == "div", classNames.contains("pd-header") {
            header = readHeaderFooter(element, text: text)
            if element.value("data-pd-different-first-page") == "true" { pageSetup.differentFirstPage = true }
            return
        }
        if tag == "div", classNames.contains("pd-footer") {
            footer = readHeaderFooter(element, text: text)
            return
        }
        if tag == "div", element.value("data-pd-comments-list") != nil {
            readComments(element)
            return
        }
        if let comments = element.value("data-pd-comments") { text.comments = comments }
        if tag == "span", classNames.contains("pd-page-number") || classNames.contains("pd-page-count") {
            ensureParagraph(text)
            emitPendingSpace()
            paragraph!.hasContent = true
            var attributes = self.attributes(for: text)
            attributes[.attachment] = PageFieldAttachment(kind: classNames.contains("pd-page-number") ? .pageNumber : .pageCount)
            paragraph!.buffer.append(NSAttributedString(string: "\u{FFFC}", attributes: attributes))
            return
        }

        switch tag {
        case "br":
            appendLiteral("\u{2028}", text: text, link: link)
        case "img":
            if let attachment = image(element, declarations: declarations) {
                ensureParagraph(text)
                emitPendingSpace()
                paragraph!.hasContent = true
                var attributes = self.attributes(for: text)
                attributes[.attachment] = attachment
                paragraph!.buffer.append(NSAttributedString(string: "\u{FFFC}", attributes: attributes))
            } else {
                warnings.insert(.images)
            }
        case "hr":
            let block = blockStyle(declarations)
            if block.breakBefore || block.breakAfter { pageBreak() }
        case "table":
            readTable(element, text: text)
        case "ul", "ol":
            flush()
            openList(element, ordered: tag == "ol", declarations: declarations)
            walk(children: element, text: text, link: link)
            closeList()
        case "li":
            let block = blockStyle(declarations)
            var item: ListItem?
            if !lists.isEmpty {
                lists[lists.count - 1].itemCount += 1
                let frame = lists[lists.count - 1]
                var preset = frame.preset
                var checked = false
                if let value = element.value("data-pd-checked") {
                    preset = .checkbox
                    checked = value == "true"
                }
                item = ListItem(listID: frame.listID, preset: preset, level: min(frame.level, ListItem.maxLevel), isChecked: checked)
            }
            beginBlock(named: .normal, block: block, text: text, listItem: item, explicit: true)
            walk(children: element, text: text, link: link)
            endBlock()
        case "a":
            walk(children: element, text: text, link: element.value("href") ?? link)
        default:
            if Self.blocks.contains(tag) {
                beginBlock(named: named ?? (blockContext.last?.named ?? .normal), block: blockStyle(declarations), text: text,
                           listItem: nil, explicit: Self.explicitBlocks.contains(tag))
                walk(children: element, text: text, link: link)
                endBlock()
            } else {
                walk(children: element, text: text, link: link)
            }
        }
    }

    /// An image embedded as a data URL. Other sources cannot be read without network or file access.
    func image(_ element: XMLElement, declarations: [String: String]) -> NSTextAttachment? {
        guard let source = element.value("src"), source.hasPrefix("data:"), let comma = source.firstIndex(of: ",") else { return nil }
        let header = source[..<comma]
        let payload = String(source[source.index(after: comma)...])
        let data = header.contains(";base64") ? Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
            : payload.removingPercentEncoding.map { Data($0.utf8) }
        guard let data else { return nil }
        var size: CGSize?
        if let width = Lengths.points(declarations["width"]), let height = Lengths.points(declarations["height"]) {
            size = CGSize(width: width, height: height)
        } else if let width = element.value("width").flatMap(Double.init), let height = element.value("height").flatMap(Double.init) {
            size = CGSize(width: width * 0.75, height: height * 0.75)
        }
        return ImageAttachments.make(data: data, size: size)
    }

    /// Rows of a table, including those inside thead/tbody/tfoot.
    func tableRows(_ element: XMLElement) -> [XMLElement] {
        element.elementChildren.flatMap { child -> [XMLElement] in
            switch child.localName?.lowercased() {
            case "tr": return [child]
            case "thead", "tbody", "tfoot": return tableRows(child)
            default: return []
            }
        }
    }

    /// Reads a table into a text table.
    mutating func readTable(_ element: XMLElement, text: TextStyle) {
        flush()
        var widths: [CGFloat] = element.firstChild("colgroup")?.childElements("col").compactMap { column in
            Lengths.percentage(CSSRules.declarations(column.value("style") ?? "")["width"] ?? column.value("width") ?? "")
        } ?? []
        var cells: [TableModel.Cell] = []
        var occupied = Set<[Int]>()
        var border: (width: CGFloat, color: String?)?
        var padding: CGFloat?
        let rows = tableRows(element)
        for (rowIndex, row) in rows.enumerated() {
            var column = 0
            for cellElement in row.elementChildren where ["td", "th"].contains(cellElement.localName?.lowercased() ?? "") {
                while occupied.contains([rowIndex, column]) { column += 1 }
                let columnSpan = max(1, min(cellElement.value("colspan").flatMap(Int.init) ?? 1, 64))
                let rowSpan = max(1, min(cellElement.value("rowspan").flatMap(Int.init) ?? 1, 64))
                let declarations = css.declarations(for: cellElement)
                var cellText = text
                if cellElement.localName?.lowercased() == "th" { cellText.bold = true }
                apply(declarations, to: &cellText)
                // Read the cell's content on its own, then take it out of the main text.
                let start = output.length
                let savedLists = lists
                let savedContext = blockContext
                lists = []
                blockContext.append((.normal, BlockStyle(), cellText))
                walk(children: cellElement, text: cellText, link: nil)
                flush()
                blockContext = savedContext
                lists = savedLists
                var range = NSRange(location: start, length: output.length - start)
                let content = NSMutableAttributedString()
                if range.length > 0 {
                    if (output.string as NSString).character(at: NSMaxRange(range) - 1) == 0x0A { range.length -= 1 }
                    content.append(output.attributedSubstring(from: range))
                    output.deleteCharacters(in: NSRange(location: start, length: output.length - start))
                }
                var cell = TableModel.Cell(row: rowIndex, column: column, rowSpan: rowSpan, columnSpan: columnSpan, content: content)
                if let background = Lengths.hexColor(declarations["background-color"] ?? declarations["background"]), background != "FFFFFF" {
                    cell.background = NSColor(hex: background)
                }
                if border == nil, let value = declarations["border"] ?? declarations["border-top"] {
                    let parts = value.split(separator: " ").map(String.init)
                    let width = parts.compactMap { Lengths.points($0) }.first ?? 1
                    border = (parts.contains("none") ? 0 : width, parts.compactMap { Lengths.hexColor($0) }.first)
                }
                if padding == nil { padding = Lengths.points(declarations["padding"]?.split(separator: " ").first.map(String.init)) }
                if rowIndex == 0, columnSpan == 1, widths.count < column + 1, let width = Lengths.percentage(declarations["width"] ?? cellElement.value("width") ?? "") {
                    while widths.count < column { widths.append(0) }
                    widths.append(width)
                }
                cells.append(cell)
                for r in rowIndex..<(rowIndex + rowSpan) { for c in column..<(column + columnSpan) { occupied.insert([r, c]) } }
                column += columnSpan
            }
        }
        guard !cells.isEmpty else { return }
        let columns = cells.map { $0.column + $0.columnSpan }.max() ?? 1
        let rowCount = max(rows.count, cells.map { $0.row + $0.rowSpan }.max() ?? 1)
        var model = TableModel(rows: rowCount, columns: columns, cells: cells,
                               columnWidths: widths.count == columns && widths.allSatisfy({ $0 > 0 }) ? widths : nil)
        model.borderWidth = border?.width ?? 1
        model.borderColor = border?.color.flatMap(NSColor.init(hex:)) ?? .black
        if let padding { model.padding = padding }
        output.append(model.attributedString(attributes: NamedStyle.normal.attributes()))
    }

    func namedStyle(tag: String, element: XMLElement) -> NamedStyle? {
        if tag.count == 2, tag.hasPrefix("h"), let level = Int(tag.dropFirst()), (1...6).contains(level) {
            return NamedStyle.allCases.first { $0.headingLevel == level }
        }
        let classNames = (element.value("class") ?? "").lowercased().split(separator: " ")
        if classNames.contains("title") { return .title }
        if classNames.contains("subtitle") { return .subtitle }
        return nil
    }

    // MARK: Lists

    mutating func openList(_ element: XMLElement, ordered: Bool, declarations: [String: String]) {
        let classes = (element.value("class") ?? "").split(separator: " ").map(String.init)
        // Some web editors flatten nested lists into "lst-kix_<id>-<level>" classes.
        var flatList: (id: String, level: Int)?
        for name in classes where name.hasPrefix("lst-kix_") {
            let rest = name.dropFirst("lst-kix_".count)
            if let dash = rest.lastIndex(of: "-"), let level = Int(rest[rest.index(after: dash)...]) {
                flatList = (String(rest[..<dash]), level)
            }
        }
        let level = flatList?.level ?? ((lists.last?.level ?? -1) + 1)
        let start = element.value("start").flatMap(Int.init) ?? 1
        let preset = element.value("data-pd-preset").flatMap(ListPreset.init(rawValue:))
            ?? lists.last?.preset
            ?? listPreset(ordered: ordered, type: element.value("type"), style: declarations["list-style-type"] ?? declarations["list-style"])
        let listID: String
        if let id = element.value("data-pd-list") {
            listID = id
        } else if let flatList {
            listID = "flat-\(flatList.id)"
        } else if let parent = lists.last {
            listID = parent.listID
        } else if ordered, start > 1, let last = lastTopList, last.preset == preset, last.next == start {
            listID = last.listID
        } else {
            listCounter += 1
            listID = "html-list-\(listCounter)"
        }
        lists.append(ListFrame(listID: listID, preset: preset, level: min(level, ListItem.maxLevel), start: start))
    }

    mutating func closeList() {
        flush()
        guard let frame = lists.popLast() else { return }
        if lists.isEmpty {
            lastTopList = (frame.listID, frame.preset, frame.start + frame.itemCount)
        }
    }

    func listPreset(ordered: Bool, type: String?, style: String?) -> ListPreset {
        let style = (style ?? "").lowercased()
        if ordered {
            switch type {
            case "A": return .upperAlphaLowerAlpha
            case "I": return .upperRomanUpperAlpha
            default: break
            }
            if style.contains("upper-alpha") || style.contains("upper-latin") { return .upperAlphaLowerAlpha }
            if style.contains("upper-roman") { return .upperRomanUpperAlpha }
            return .decimalAlphaRoman
        }
        if style.contains("☐") || style.contains("☑") { return .checkbox }
        if style.contains("❖") { return .diamondArrowSquare }
        if style.contains("➔") || style.contains("→") { return .arrowDiamondDisc }
        if style.contains("★") { return .starCircleSquare }
        if style.contains("❏") { return .boxArrowSquare }
        if style.contains("–") || style.contains("\"-") { return .dashCircleSquare }
        return .discCircleSquare
    }

    // MARK: Paragraph building

    mutating func beginBlock(named: NamedStyle, block: BlockStyle, text: TextStyle, listItem: ListItem?, explicit: Bool) {
        // A <p> or heading as the first thing inside a list item is that item's paragraph.
        if var current = paragraph, current.listItem != nil, !current.hasContent, listItem == nil {
            current.named = named
            current.block.alignment = block.alignment ?? current.block.alignment
            current.block.marginTop = max(current.block.marginTop, block.marginTop)
            current.block.marginBottom = max(current.block.marginBottom, block.marginBottom)
            current.block.lineSpacing = block.lineSpacing ?? current.block.lineSpacing
            current.block.breakBefore = current.block.breakBefore || block.breakBefore
            paragraph = current
            blockContext.append((named, block, text))
            return
        }
        flush()
        blockContext.append((named, block, text))
        paragraph = Paragraph(named: named, block: block, listItem: listItem, explicit: explicit, lastText: text)
    }

    mutating func endBlock() {
        if blockContext.count > 1 { blockContext.removeLast() }
        flush()
    }

    mutating func ensureParagraph(_ text: TextStyle) {
        guard paragraph == nil else { return }
        let context = blockContext.last ?? (.normal, BlockStyle(), text)
        var block = context.block
        block.breakBefore = false
        paragraph = Paragraph(named: context.named, block: block, listItem: nil, explicit: false, lastText: text)
    }

    mutating func appendText(_ raw: String, text: TextStyle, link: String?) {
        if text.preserveWhitespace {
            let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
            let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() {
                if index > 0 { appendLiteral("\u{2028}", text: text, link: link) }
                if !line.isEmpty { appendLiteral(String(line), text: text, link: link) }
            }
            return
        }
        var buffer = ""
        for character in raw {
            if character == " " || character == "\t" || character == "\n" || character == "\r" || character == "\u{0C}" {
                if paragraph != nil, !paragraph!.pendingSpace {
                    paragraph!.pendingSpace = true
                    paragraph!.pendingSpaceStyle = (text, link)
                }
            } else {
                ensureParagraph(text)
                if paragraph!.pendingSpace && !buffer.isEmpty { buffer.append(" ") }
                else if buffer.isEmpty { emitPendingSpace() }
                paragraph!.pendingSpace = false
                paragraph!.hasContent = true
                buffer.append(character)
            }
        }
        emit(buffer, text: text, link: link)
    }

    mutating func appendLiteral(_ literal: String, text: TextStyle, link: String?) {
        ensureParagraph(text)
        emitPendingSpace()
        paragraph!.hasContent = true
        emit(literal, text: text, link: link)
    }

    /// Writes a collapsed space between words with the formatting of the text it came from.
    mutating func emitPendingSpace() {
        guard paragraph != nil else { return }
        defer {
            paragraph!.pendingSpace = false
            paragraph!.pendingSpaceStyle = nil
        }
        guard paragraph!.pendingSpace, paragraph!.hasContent else { return }
        let style = paragraph!.pendingSpaceStyle ?? (paragraph!.lastText, nil)
        emit(" ", text: style.text, link: style.link)
    }

    mutating func emit(_ string: String, text: TextStyle, link: String?) {
        guard !string.isEmpty, paragraph != nil else { return }
        var attributes = attributes(for: text)
        if let link { attributes[.link] = URL(string: link) ?? link }
        paragraph!.buffer.append(NSAttributedString(string: string, attributes: attributes))
        paragraph!.lastText = text
    }

    mutating func attributes(for text: TextStyle) -> [NSAttributedString.Key: Any] {
        var attributes = baseAttributes(for: text)
        if let comments = text.comments { attributes[.pdComments] = comments }
        if let suggestion = text.suggestion { attributes[.pdSuggestion] = suggestion }
        return attributes
    }

    mutating func baseAttributes(for text: TextStyle) -> [NSAttributedString.Key: Any] {
        if let cached = attributeCache[text.key] { return cached }
        var attributes: [NSAttributedString.Key: Any] = [:]
        if text.baseline != 0 { attributes[.superscript] = text.baseline }
        FontResolver.apply(FontSpec(family: text.family, size: text.size, bold: text.bold, italic: text.italic), to: &attributes)
        attributes[.foregroundColor] = NSColor(hex: text.color) ?? .black
        if text.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if text.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let background = text.background.flatMap(NSColor.init(hex:)) { attributes[.backgroundColor] = background }
        attributeCache[text.key] = attributes
        return attributes
    }

    mutating func pageBreak() {
        flush()
        DocumentIO.appendPageBreak(to: output)
    }

    mutating func flush() {
        guard let current = paragraph else { return }
        paragraph = nil
        guard current.hasContent || current.explicit else { return }
        let buffer = current.buffer
        if buffer.string == "\u{2028}" { buffer.deleteCharacters(in: NSRange(location: 0, length: buffer.length)) }

        let style = DocumentDefaults.paragraphStyle()
        style.alignment = current.block.alignment ?? .natural
        style.paragraphSpacingBefore = current.block.marginTop
        style.paragraphSpacing = current.block.marginBottom
        switch current.block.lineSpacing ?? .multiple(current.named.definition.lineSpacing) {
        case .multiple(let value): style.lineHeightMultiple = max(0.5, value)
        case .exact(let value):
            style.lineHeightMultiple = 0
            style.minimumLineHeight = value
            style.maximumLineHeight = value
        case .atLeast(let value):
            style.lineHeightMultiple = 0
            style.minimumLineHeight = value
        }
        if let item = current.listItem {
            style.headIndent = item.textIndent
            style.firstLineHeadIndent = item.textIndent
        } else {
            style.headIndent = max(0, current.block.marginLeft)
            style.firstLineHeadIndent = max(0, current.block.marginLeft + current.block.textIndent)
        }
        if current.block.marginRight > 0 { style.tailIndent = -current.block.marginRight }

        var paragraphAttributes: [NSAttributedString.Key: Any] = [
            .paragraphStyle: style.copy() as! NSParagraphStyle,
            .pdNamedStyle: current.named.rawValue,
        ]
        paragraphAttributes[.pdListItem] = current.listItem
        if buffer.length > 0 { buffer.addAttributes(paragraphAttributes, range: NSRange(location: 0, length: buffer.length)) }
        if current.block.breakBefore { DocumentIO.appendPageBreak(to: output) }
        output.append(buffer)
        var mark = attributes(for: current.lastText)
        mark.merge(paragraphAttributes) { _, new in new }
        output.append(NSAttributedString(string: current.block.breakAfter ? "\u{0C}\n" : "\n", attributes: mark))
    }
}

/// Builds an `XMLDocument` with every character of text kept. `XMLDocument`'s own parser drops
/// text nodes that are only spaces, which in HTML are real spaces between words.
final class ExactXMLTree: NSObject, XMLParserDelegate {
    /// Pages nesting deeper than this go through HTML Tidy instead: a tree tens of thousands of levels deep
    /// overflows the stack when it's freed.
    static let maximumDepth = 256

    private var stack: [XMLElement] = []
    private var root: XMLElement?
    private var text = ""
    private var isTooDeep = false

    static func parse(_ source: String) -> XMLDocument? {
        let parser = XMLParser(data: Data(source.utf8))
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        let builder = ExactXMLTree()
        parser.delegate = builder
        guard parser.parse(), !builder.isTooDeep, let root = builder.root else { return nil }
        return XMLDocument(rootElement: root)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        guard stack.count < Self.maximumDepth else {
            isTooDeep = true
            parser.abortParsing()
            return
        }
        flushText()
        let element = XMLElement(name: elementName)
        for (name, value) in attributeDict where !name.hasPrefix("xmlns") {
            if let attribute = XMLNode.attribute(withName: name, stringValue: value) as? XMLNode { element.addAttribute(attribute) }
        }
        if let parent = stack.last { parent.addChild(element) } else { root = element }
        stack.append(element)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        flushText()
        _ = stack.popLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(decoding: CDATABlock, as: UTF8.self) }

    private func flushText() {
        defer { text = "" }
        guard !text.isEmpty, let parent = stack.last, let node = XMLNode.text(withStringValue: text) as? XMLNode else { return }
        parent.addChild(node)
    }
}
