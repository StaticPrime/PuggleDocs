import AppKit

/// Writes a standalone web page (.html) with semantic markup and inline styles. The markup is also
/// well-formed XML (XHTML), so PuggleDocs reads its own pages back exactly and EPUB can reuse it.
public enum HtmlWriter {
    public static func write(_ content: DocumentContent, title: String = "Document") -> Data {
        Data(html(content, title: title).utf8)
    }

    public static func html(_ content: DocumentContent, title: String = "Document") -> String {
        let setup = content.pageSetup
        let size = setup.pageSize
        let m = setup.margins
        let normal = NamedStyle.normal.definition
        var html = "<!DOCTYPE html>\n<html xmlns=\"http://www.w3.org/1999/xhtml\" lang=\"en\">\n<head>\n<meta charset=\"utf-8\"/>\n"
        html += "<meta name=\"generator\" content=\"PuggleDocs\"/>\n<title>\(escape(title))</title>\n<style>\n"
        html += "@page { size: \(css(size.width)) \(css(size.height)); margin: \(css(m.top)) \(css(m.right)) \(css(m.bottom)) \(css(m.left)); }\n"
        html += "body { background-color: #\(setup.pageColorHex ?? "FFFFFF"); margin: 0; }\n"
        html += ".pd-doc { max-width: \(css(setup.contentSize.width)); margin: \(css(m.top)) auto; padding: 0 \(css(m.right)) 0 \(css(m.left)); "
            + "font-family: \(cssFamily(normal.fontFamily)); font-size: \(css(normal.fontSize)); line-height: \(normal.lineSpacing); color: #000000; }\n"
        html += ".pd-doc p, .pd-doc h1, .pd-doc h2, .pd-doc h3, .pd-doc h4, .pd-doc h5, .pd-doc h6, .pd-doc li { margin: 0; font-weight: normal; }\n"
        html += ".pd-doc ul, .pd-doc ol { margin: 0; padding-left: 0; }\n"
        html += ".pd-header { margin-bottom: 24pt; } .pd-footer { margin-top: 24pt; }\n"
        let options = Options(content: content)
        if !options.anchoredComments.isEmpty { html += commentCSS }
        if Suggestions.hasSuggestions(content.text) { html += suggestionCSS }
        html += "</style>\n</head>\n<body>\n<div class=\"pd-doc\">\n"
        if let header = content.header, header.length > 0 {
            html += "<div class=\"pd-header\"\(setup.differentFirstPage ? " data-pd-different-first-page=\"true\"" : "")>\n\(body(header))</div>\n"
        }
        html += body(content.text, options: options)
        if let footer = content.footer, footer.length > 0 {
            html += "<div class=\"pd-footer\">\n\(body(footer))</div>\n"
        }
        html += "</div>\n"
        html += commentsHTML(content, options: options)
        html += "</body>\n</html>\n"
        return html
    }

    /// Pictures and headings collected while writing an EPUB's text.
    final class BookParts {
        var images: [(path: String, data: Data, type: String)] = []
        var headings: [(id: String, level: Int, title: String)] = []
    }

    /// What the body writer needs to know about the document as a whole.
    struct Options {
        /// Comment threads that appear in the text, and those of them still open (highlighted).
        var anchoredComments: [String] = []
        var openComments = Set<String>()
        /// For EPUB: pictures become separate files and headings get ids for the table of contents.
        var book: BookParts?

        init() {}

        init(content: DocumentContent) {
            let anchored = CommentAnchors.ranges(in: content.text)
            anchoredComments = content.comments.map(\.id).filter { anchored[$0] != nil }
            openComments = Set(content.comments.filter { !$0.resolved }.map(\.id))
        }
    }

    static let suggestionCSS = """
    ins[data-pd-suggestion] { color: #188038; text-decoration: underline; }
    del[data-pd-suggestion] { color: #C5221F; text-decoration: line-through; }

    """

    // Attribute selectors, so the highlight is never read back in as a text background.
    static let commentCSS = """
    span[data-pd-open] { background-color: #FEF0C0; border-bottom: 2px solid #F4B400; }
    div[data-pd-comments-list] { max-width: 6.5in; margin: 24pt auto; padding: 12pt 16pt; border-top: 1px solid #DADCE0; font-family: Arial, sans-serif; font-size: 10pt; color: #3C4043; }
    div[data-pd-thread] { margin: 0 0 12pt; } div[data-pd-thread] p { margin: 0 0 2pt; }
    div[data-pd-resolved] { display: none; } div[data-pd-reply] { margin-left: 18pt; margin-top: 6pt; }
    span[data-pd-date] { color: #5F6368; margin-left: 6pt; }

    """

    /// A readable list of the comment threads after the document, which the HTML reader also turns back into comments.
    static func commentsHTML(_ content: DocumentContent, options: Options) -> String {
        guard !options.anchoredComments.isEmpty else { return "" }
        let threads = Dictionary(content.comments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let iso = ISO8601DateFormatter()
        let display = DateFormatter()
        display.dateStyle = .medium
        display.timeStyle = .short
        func entry(author: String, date: Date, text: String) -> String {
            let lines = text.components(separatedBy: "\n").map { escape($0) }.joined(separator: "<br/>")
            return "<p data-pd-comment-head=\"\"><b data-pd-author=\"\">\(escape(author))</b>"
                + "<span data-pd-date=\"\(iso.string(from: date))\">\(escape(display.string(from: date)))</span></p>"
                + "<p data-pd-comment-text=\"\">\(lines)</p>"
        }
        var html = "<div class=\"pd-comments\" data-pd-comments-list=\"\">\n<p><b>Comments</b></p>\n"
        for id in options.anchoredComments {
            guard let thread = threads[id] else { continue }
            html += "<div data-pd-thread=\"\(escape(id))\"\(thread.resolved ? " data-pd-resolved=\"true\"" : "")>"
            html += entry(author: thread.author, date: thread.date, text: thread.text)
            for reply in thread.replies {
                html += "<div data-pd-reply=\"\">" + entry(author: reply.author, date: reply.date, text: reply.text) + "</div>"
            }
            html += "</div>\n"
        }
        return html + "</div>\n"
    }

    // MARK: Body

    struct OpenList {
        let tag: String
        var itemOpen: Bool
    }

    static func body(_ text: NSAttributedString, options: Options = Options()) -> String {
        let string = text.string as NSString
        var html = ""
        var lists: [OpenList] = []
        var currentListKey: String?
        var counters: [String: [Int]] = [:]

        func closeLevel() {
            let list = lists.removeLast()
            if list.itemOpen { html += "</li>" }
            html += "</\(list.tag)>\n"
        }
        func closeAll() {
            while !lists.isEmpty { closeLevel() }
            currentListKey = nil
        }

        var location = 0
        var breakBefore = false
        while location < string.length {
            if TableModel.block(at: location, in: text) != nil, let table = TableModel.table(at: location, in: text), table.range.length > 0 {
                closeAll()
                html += tableHTML(table, options: options)
                location = NSMaxRange(table.range)
                continue
            }
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)
            var content = paragraph
            while content.length > 0, DocxWriter.isParagraphSeparator(string.character(at: NSMaxRange(content) - 1)) { content.length -= 1 }
            var endsWithBreak = false
            if content.length > 0, string.character(at: NSMaxRange(content) - 1) == 0x0C {
                content.length -= 1
                endsWithBreak = true
            }
            let attributes = text.attributes(at: paragraph.location, effectiveRange: nil)
            let item = attributes[.pdListItem] as? ListItem
            if breakBefore {
                closeAll()
                html += "<hr style=\"page-break-before:always;display:none;\"/>\n"
            }
            breakBefore = endsWithBreak

            guard let item else {
                closeAll()
                html += paragraphHTML(text, content: content, attributes: attributes, inList: false, options: options) + "\n"
                continue
            }
            var levels = counters[item.listID] ?? Array(repeating: 0, count: ListItem.maxLevel + 1)
            levels[item.level] += 1
            for deeper in (item.level + 1)..<levels.count { levels[deeper] = 0 }
            counters[item.listID] = levels

            let key = item.kind == .checklist ? "\(item.listID)|\(item.isChecked)" : item.listID
            if currentListKey != key { closeAll() }
            currentListKey = key
            while lists.count - 1 < item.level {
                if let last = lists.indices.last, !lists[last].itemOpen {
                    html += "<li style=\"list-style-type:none\">"
                    lists[last].itemOpen = true
                }
                let level = lists.count
                let tag = item.kind == .numbered ? "ol" : "ul"
                var open = "<\(tag) data-pd-list=\"\(escape(item.listID))\" data-pd-preset=\"\(item.preset.rawValue)\""
                open += " style=\"\(listStyle(item, level: level))\""
                if item.kind == .numbered {
                    let number = level == item.level ? levels[level] : 1
                    if number > 1 { open += " start=\"\(number)\"" }
                }
                html += open + ">"
                lists.append(OpenList(tag: tag, itemOpen: false))
            }
            while lists.count - 1 > item.level { closeLevel() }
            if lists[item.level].itemOpen { html += "</li>" }
            var li = "<li"
            if item.kind == .checklist { li += " data-pd-checked=\"\(item.isChecked)\"" }
            li += ">"
            html += li + paragraphHTML(text, content: content, attributes: attributes, inList: true, options: options)
            lists[item.level].itemOpen = true
        }
        closeAll()
        if string.length > 0, DocxWriter.isParagraphSeparator(string.character(at: string.length - 1)), TableModel.block(at: string.length - 1, in: text) == nil {
            html += "<p><br/></p>\n"
        }
        return html
    }

    static func tableHTML(_ table: TableModel, options: Options = Options()) -> String {
        let border = table.borderWidth > 0 ? "\(css(table.borderWidth)) solid #\(table.borderColor.hexString ?? "000000")" : "none"
        var html = "<table style=\"border-collapse:collapse;width:100%;table-layout:fixed\"><colgroup>"
        for width in table.columnWidths { html += "<col style=\"width:\((width * 1000).rounded() / 10)%\"/>" }
        html += "</colgroup>\n"
        for row in 0..<table.rows {
            html += "<tr>"
            for column in 0..<table.columns {
                guard let cell = table.cell(row: row, column: column), cell.row == row, cell.column == column else { continue }
                var style = "border:\(border);padding:\(css(table.padding));vertical-align:top"
                if let background = cell.background?.hexString { style += ";background-color:#\(background)" }
                var open = "<td style=\"\(style)\""
                if cell.columnSpan > 1 { open += " colspan=\"\(cell.columnSpan)\"" }
                if cell.rowSpan > 1 { open += " rowspan=\"\(cell.rowSpan)\"" }
                html += open + ">" + body(cell.content, options: options) + "</td>"
            }
            html += "</tr>\n"
        }
        html += "</table>\n"
        return html
    }

    static func listStyle(_ item: ListItem, level: Int) -> String {
        let indent = "margin-left:\(css(level == 0 ? ListItem.textIndent(forLevel: 0) : ListItem.levelIndent))"
        let format = item.preset.levelFormat(level)
        let type: String
        switch format.format {
        case .bullet(let glyph):
            switch glyph {
            case "●": type = "disc"
            case "○": type = "circle"
            case "■": type = "square"
            default: type = "'\(glyph)  '"
            }
        case .checkbox: type = item.isChecked ? "'☑  '" : "'☐  '"
        case .decimal: type = "decimal"
        case .decimalZero: type = "decimal-leading-zero"
        case .lowerAlpha: type = "lower-alpha"
        case .upperAlpha: type = "upper-alpha"
        case .lowerRoman: type = "lower-roman"
        case .upperRoman: type = "upper-roman"
        }
        return "\(indent);list-style-type:\(type)"
    }

    static func paragraphHTML(_ text: NSAttributedString, content: NSRange, attributes: [NSAttributedString.Key: Any], inList: Bool,
                              options: Options = Options()) -> String {
        let paragraph = ParagraphAttributes(attributes: attributes)
        let style = paragraph.style
        var css: [String] = []
        switch style.alignment {
        case .center: css.append("text-align:center")
        case .right: css.append("text-align:right")
        case .justified: css.append("text-align:justify")
        default: break
        }
        if !inList {
            if style.headIndent > 0 { css.append("margin-left:\(self.css(style.headIndent))") }
            let firstLine = style.firstLineHeadIndent - style.headIndent
            if firstLine != 0 { css.append("text-indent:\(self.css(firstLine))") }
        }
        if style.tailIndent < 0 { css.append("margin-right:\(self.css(-style.tailIndent))") }
        if style.paragraphSpacingBefore > 0 { css.append("margin-top:\(self.css(style.paragraphSpacingBefore))") }
        if style.paragraphSpacing > 0 { css.append("margin-bottom:\(self.css(style.paragraphSpacing))") }
        if style.maximumLineHeight > 0, style.minimumLineHeight == style.maximumLineHeight {
            css.append("line-height:\(self.css(style.maximumLineHeight))")
        } else if style.lineHeightMultiple > 0 {
            css.append("line-height:\((style.lineHeightMultiple * 100).rounded() / 100)")
        }

        let runs = content.length > 0 ? runsHTML(text, content: content, options: options) : "<br/>"
        if content.length > 0, needsPreservedWhitespace((text.string as NSString).substring(with: content)) {
            css.append("white-space:pre-wrap")
        }
        let styleAttribute = css.isEmpty ? "" : " style=\"\(css.joined(separator: ";"))\""
        let tag: String
        var classAttribute = ""
        switch paragraph.namedStyle {
        case .title: tag = "p"; classAttribute = " class=\"title\""
        case .subtitle: tag = "p"; classAttribute = " class=\"subtitle\""
        case .normal: tag = "p"
        default: tag = "h\(paragraph.namedStyle.headingLevel ?? 1)"
        }
        if let book = options.book, tag.hasPrefix("h"), let level = paragraph.namedStyle.headingLevel {
            let title = (text.string as NSString).substring(with: content).replacingOccurrences(of: "\u{FFFC}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                let id = "heading-\(book.headings.count + 1)"
                book.headings.append((id, level, title))
                classAttribute += " id=\"\(id)\""
            }
        }
        return "<\(tag)\(classAttribute)\(styleAttribute)>\(runs)</\(tag)>"
    }

    static func needsPreservedWhitespace(_ text: String) -> Bool {
        text.hasPrefix(" ") || text.hasSuffix(" ") || text.contains("  ") || text.contains("\t")
    }

    static func runsHTML(_ text: NSAttributedString, content: NSRange, options: Options = Options()) -> String {
        var html = ""
        var currentLink: String?
        text.enumerateAttributes(in: content, options: []) { attributes, range, _ in
            let link = DocxWriter.linkTarget(attributes[.link])
            if link != currentLink {
                if currentLink != nil { html += "</a>" }
                if let link { html += "<a href=\"\(escape(link))\">" }
                currentLink = link
            }
            let raw = (text.string as NSString).substring(with: range)
            if let field = attributes[.attachment] as? PageFieldAttachment, raw.contains("\u{FFFC}") {
                let marker = field.kind == .pageNumber ? "pd-page-number" : "pd-page-count"
                html += raw.components(separatedBy: "\u{FFFC}").map { escape($0) }
                    .joined(separator: "<span class=\"\(marker)\" style=\"\(textCSS(attributes))\">1</span>")
                return
            }
            if let attachment = attributes[.attachment] as? NSTextAttachment, raw.contains("\u{FFFC}") {
                html += raw.components(separatedBy: "\u{FFFC}").map { escape($0) }.joined(separator: imageHTML(attachment, book: options.book))
                return
            }
            var body = escape(raw).replacingOccurrences(of: "\u{2028}", with: "<br/>").replacingOccurrences(of: "\u{FFFC}", with: "")
            switch CharacterFormatting.baseline(attributes) {
            case 1: body = "<sup>\(body)</sup>"
            case -1: body = "<sub>\(body)</sub>"
            default: break
            }
            let span = "<span\(commentAttributes(attributes, options: options)) style=\"\(textCSS(attributes))\">\(body)</span>"
            if let mark = attributes[.pdSuggestion] as? SuggestionMark {
                // A suggestion reads as <ins>/<del> anywhere, and comes back as a suggestion in PuggleDocs.
                let tag = mark.kind == .insertion ? "ins" : "del"
                html += "<\(tag) data-pd-suggestion=\"\(escape(mark.id))\" data-pd-author=\"\(escape(mark.author))\" "
                    + "data-pd-date=\"\(Suggestions.timestamp(mark.date))\">\(span)</\(tag)>"
            } else {
                html += span
            }
        }
        if currentLink != nil { html += "</a>" }
        return html
    }

    static func commentAttributes(_ attributes: [NSAttributedString.Key: Any], options: Options) -> String {
        let ids = CommentAnchors.ids(attributes[.pdComments]).filter { options.anchoredComments.contains($0) }
        guard !ids.isEmpty else { return "" }
        let open = ids.contains { options.openComments.contains($0) }
        return " data-pd-comments=\"\(escape(ids.joined(separator: ",")))\"" + (open ? " data-pd-open=\"\"" : "")
    }

    /// An inline image embedded as a data URL, so the page is a single file.
    static func imageHTML(_ attachment: NSTextAttachment, book: BookParts? = nil) -> String {
        guard let info = ImageAttachments.info(attachment), let portable = ImageAttachments.portableData(info) else { return "" }
        var source = "data:\(ImageAttachments.mimeType(portable.type));base64,\(portable.data.base64EncodedString())"
        if let book {
            let path = "images/image\(book.images.count + 1).\(ImageAttachments.fileExtension(portable.type))"
            book.images.append((path, portable.data, ImageAttachments.mimeType(portable.type)))
            source = path
        }
        return "<img src=\"\(source)\" alt=\"\" style=\"width:\(css(info.size.width));height:\(css(info.size.height))\"/>"
    }

    static func textCSS(_ attributes: [NSAttributedString.Key: Any]) -> String {
        let spec = FontResolver.spec(from: attributes)
        var css = ["font-family:\(cssFamily(spec.family))", "font-size:\(self.css(spec.size))"]
        css.append("font-weight:\(spec.bold ? 700 : 400)")
        css.append("font-style:\(spec.italic ? "italic" : "normal")")
        let isPlainLink = attributes[.link] != nil && ((attributes[.foregroundColor] as? NSColor)?.hexString ?? "000000") == "000000"
        var decorations: [String] = []
        if CharacterFormatting.isUnderlined(attributes) || isPlainLink { decorations.append("underline") }
        if CharacterFormatting.isStruckThrough(attributes) { decorations.append("line-through") }
        css.append("text-decoration:\(decorations.isEmpty ? "none" : decorations.joined(separator: " "))")
        css.append("color:#\(isPlainLink ? ColorPalette.linkHex : ((attributes[.foregroundColor] as? NSColor)?.hexString ?? "000000"))")
        if let highlight = (attributes[.backgroundColor] as? NSColor)?.hexString { css.append("background-color:#\(highlight)") }
        return css.joined(separator: ";")
    }

    static func cssFamily(_ family: String) -> String {
        let generic = family.lowercased().contains("courier") || family.lowercased().contains("mono") ? "monospace" : "sans-serif"
        return "'\(escape(family).replacingOccurrences(of: "'", with: ""))', \(generic)"
    }

    static func css(_ points: CGFloat) -> String {
        let rounded = (points * 100).rounded() / 100
        return rounded == rounded.rounded() ? "\(Int(rounded))pt" : "\(rounded)pt"
    }

    static func escape(_ text: String) -> String { DocxWriter.escape(text) }
}
