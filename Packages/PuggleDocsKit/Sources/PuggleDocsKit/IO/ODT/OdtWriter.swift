import AppKit
import UniformTypeIdentifiers

/// Writes OpenDocument Text (.odt).
public enum OdtWriter {
    static let mimeType = "application/vnd.oasis.opendocument.text"
    static let namespaces = """
    xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
    xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" \
    xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" \
    xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" \
    xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0" \
    xmlns:xlink="http://www.w3.org/1999/xlink" \
    xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0" \
    xmlns:dc="http://purl.org/dc/elements/1.1/" \
    xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" \
    xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" \
    xmlns:loext="urn:org:documentfoundation:names:experimental:office:xmlns:loext:1.0"
    """

    public static func write(_ content: DocumentContent, date: Date = Date()) throws -> Data {
        var context = Context()
        context.contentWidth = content.pageSetup.contentSize.width
        context.threads = Dictionary(content.comments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        context.comments = CommentRangeTracker(threads: content.comments)
        var body = bodyXML(content.text, context: &context)
        let unfinished = context.comments.finish()
        if !unfinished.isEmpty { body += "<text:p>" + annotationMarkers((unfinished, []), context: &context) + "</text:p>" }
        body = trackedChangesXML(context) + body
        // Header and footer live in styles.xml with their own automatic styles ("M" prefix).
        var masterContext = Context(prefix: "M")
        masterContext.contentWidth = context.contentWidth
        masterContext.images = context.images
        let header = content.header.map { bodyXML($0, context: &masterContext) }
        let footer = content.footer.map { bodyXML($0, context: &masterContext) }
        context.images = masterContext.images
        context.fonts.formUnion(masterContext.fonts)
        var zip = ZipWriter(date: date)
        // The mimetype entry must come first and be stored uncompressed.
        zip.add(path: "mimetype", data: Data(mimeType.utf8), compress: false)
        zip.add(path: "META-INF/manifest.xml", data: Data(manifestXML(images: context.images).utf8))
        for image in context.images {
            zip.add(path: image.path, data: image.data, compress: false)
        }
        zip.add(path: "meta.xml", data: Data(metaXML(date: date).utf8))
        zip.add(path: "styles.xml", data: Data(stylesXML(content.pageSetup, fonts: context.fonts, header: header, footer: footer,
                                                         masterStyles: masterContext.automaticStyles).utf8))
        zip.add(path: "content.xml", data: Data(contentXML(body: body, context: context).utf8))
        return zip.finish()
    }

    // MARK: - Context

    struct Context {
        var prefix = ""
        var contentWidth: CGFloat = 468
        var tableCount = 0
        var tableStyleXML = ""
        var paragraphStyles: [String: String] = [:]
        var paragraphStyleXML = ""
        var textStyles: [String: String] = [:]
        var textStyleXML = ""
        var listStyles: [String: String] = [:]
        var listStyleXML = ""
        var fonts: Set<String> = [NamedStyle.normal.definition.fontFamily]
        var listCount = 0
        var lastListXMLID: [String: String] = [:]
        var images: [(path: String, data: Data, type: UTType)] = []
        var threads: [String: CommentThread] = [:]
        var comments = CommentRangeTracker(threads: [])
        /// Suggestions as ODF tracked changes; a deletion keeps its text here, out of the body.
        var changes: [(id: String, mark: SuggestionMark, style: String, deleted: String)] = []

        mutating func newChange(_ mark: SuggestionMark, style: String) -> String {
            let id = "ct\(changes.count + 1)"
            changes.append((id, mark, style, ""))
            return id
        }

        func annotationName(_ threadID: String) -> String {
            "__Annotation__\((comments.order.firstIndex(of: threadID) ?? 0) + 1)"
        }

        mutating func addImage(data: Data, type: UTType) -> (path: String, number: Int) {
            let number = images.count + 1
            let path = "Pictures/image\(number).\(ImageAttachments.fileExtension(type))"
            images.append((path, data, type))
            return (path, number)
        }

        init(prefix: String = "") { self.prefix = prefix }

        var automaticStyles: String { paragraphStyleXML + textStyleXML + listStyleXML + tableStyleXML }

        mutating func paragraphStyle(_ properties: String, parent: String) -> String {
            let key = parent + "|" + properties
            if let existing = paragraphStyles[key] { return existing }
            let name = "\(prefix)P\(paragraphStyles.count + 1)"
            paragraphStyles[key] = name
            paragraphStyleXML += "<style:style style:name=\"\(name)\" style:family=\"paragraph\" style:parent-style-name=\"\(parent)\">"
                + "<style:paragraph-properties \(properties)/></style:style>"
            return name
        }

        mutating func textStyle(_ properties: String) -> String {
            if let existing = textStyles[properties] { return existing }
            let name = "\(prefix)T\(textStyles.count + 1)"
            textStyles[properties] = name
            textStyleXML += "<style:style style:name=\"\(name)\" style:family=\"text\"><style:text-properties \(properties)/></style:style>"
            return name
        }

        mutating func listStyle(for item: ListItem) -> String {
            let key = "\(item.preset.rawValue)|\(item.kind == .checklist ? String(item.isChecked) : "")"
            if let existing = listStyles[key] { return existing }
            let name = "\(prefix)L\(listStyles.count + 1)"
            listStyles[key] = name
            listStyleXML += OdtWriter.listStyleXML(name: name, preset: item.preset, checked: item.isChecked)
            return name
        }
    }

    static func odfStyleName(_ style: NamedStyle) -> String {
        switch style {
        case .normal: "Standard"
        case .title: "Title"
        case .subtitle: "Subtitle"
        default: "Heading_20_\(style.headingLevel ?? 1)"
        }
    }

    // MARK: - Body

    /// Tracks open `text:list` elements while writing consecutive list paragraphs.
    struct ListWriter {
        var listKey: String?
        var openItems: [Bool] = []

        mutating func closeLevel(_ xml: inout String) {
            if openItems.removeLast() { xml += "</text:list-item>" }
            xml += "</text:list>"
        }

        mutating func closeAll(_ xml: inout String) {
            while !openItems.isEmpty { closeLevel(&xml) }
            listKey = nil
        }
    }

    static func bodyXML(_ text: NSAttributedString, context: inout Context) -> String {
        let string = text.string as NSString
        var xml = ""
        var lists = ListWriter()
        var breakBefore = false
        var location = 0
        var paragraphs: [(range: NSRange, content: NSRange)] = []
        while location < string.length {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            var content = paragraph
            while content.length > 0, DocxWriter.isParagraphSeparator(string.character(at: NSMaxRange(content) - 1)) { content.length -= 1 }
            paragraphs.append((paragraph, content))
            location = NSMaxRange(paragraph)
        }
        if string.length == 0 || DocxWriter.isParagraphSeparator(string.character(at: string.length - 1)) {
            paragraphs.append((NSRange(location: string.length, length: 0), NSRange(location: string.length, length: 0)))
        }

        var tableEnd = 0
        for (paragraph, var content) in paragraphs {
            if paragraph.location < tableEnd { continue }
            if paragraph.length > 0, TableModel.block(at: paragraph.location, in: text) != nil,
               let table = TableModel.table(at: paragraph.location, in: text), table.range.length > 0 {
                lists.closeAll(&xml)
                xml += tableXML(table, context: &context)
                tableEnd = NSMaxRange(table.range)
                continue
            }
            let attributes = paragraph.length > 0 || string.length == 0
                ? (string.length == 0 ? DocumentDefaults.typingAttributes : text.attributes(at: paragraph.location, effectiveRange: nil))
                : text.attributes(at: string.length - 1, effectiveRange: nil)
            // A page break at the end of a paragraph becomes "break before" on the next one.
            var endsWithBreak = false
            if content.length > 0, string.character(at: NSMaxRange(content) - 1) == 0x0C {
                content.length -= 1
                endsWithBreak = true
            }
            let item = paragraph.length > 0 ? attributes[.pdListItem] as? ListItem : nil
            let paragraphXML = self.paragraphXML(text, content: content, attributes: attributes, isListItem: item != nil,
                                                 breakBefore: breakBefore, context: &context)
            breakBefore = endsWithBreak

            guard let item else {
                lists.closeAll(&xml)
                xml += paragraphXML
                continue
            }
            let key = item.kind == .checklist ? "\(item.listID)|\(item.isChecked)" : item.listID
            if lists.listKey != key { lists.closeAll(&xml) }
            if lists.openItems.isEmpty {
                context.listCount += 1
                let id = "list\(context.listCount)"
                var open = "<text:list xml:id=\"\(id)\" text:style-name=\"\(context.listStyle(for: item))\""
                if let previous = context.lastListXMLID[key] { open += " text:continue-list=\"\(previous)\"" }
                xml += open + ">"
                context.lastListXMLID[key] = id
                lists.openItems = [false]
                lists.listKey = key
            }
            while lists.openItems.count - 1 < item.level {
                if !lists.openItems[lists.openItems.count - 1] {
                    xml += "<text:list-item>"
                    lists.openItems[lists.openItems.count - 1] = true
                }
                xml += "<text:list>"
                lists.openItems.append(false)
            }
            while lists.openItems.count - 1 > item.level { lists.closeLevel(&xml) }
            if lists.openItems[item.level] { xml += "</text:list-item>" }
            xml += "<text:list-item>" + paragraphXML
            lists.openItems[item.level] = true
        }
        lists.closeAll(&xml)
        return xml
    }

    static func paragraphXML(_ text: NSAttributedString, content: NSRange, attributes: [NSAttributedString.Key: Any],
                             isListItem: Bool, breakBefore: Bool, context: inout Context) -> String {
        let paragraph = ParagraphAttributes(attributes: attributes)
        let style = paragraph.style
        var properties: [String] = []
        switch style.alignment {
        case .center: properties.append("fo:text-align=\"center\"")
        case .right: properties.append("fo:text-align=\"end\"")
        case .justified: properties.append("fo:text-align=\"justify\"")
        default: properties.append("fo:text-align=\"start\"")
        }
        properties.append("fo:margin-top=\"\(points(style.paragraphSpacingBefore))\"")
        properties.append("fo:margin-bottom=\"\(points(style.paragraphSpacing))\"")
        if !isListItem {
            properties.append("fo:margin-left=\"\(points(style.headIndent))\"")
            properties.append("fo:text-indent=\"\(points(style.firstLineHeadIndent - style.headIndent))\"")
        }
        properties.append("fo:margin-right=\"\(points(max(0, -style.tailIndent)))\"")
        if style.maximumLineHeight > 0, style.minimumLineHeight == style.maximumLineHeight {
            properties.append("fo:line-height=\"\(points(style.maximumLineHeight))\"")
        } else if style.minimumLineHeight > 0 {
            properties.append("style:line-height-at-least=\"\(points(style.minimumLineHeight))\"")
        } else {
            let multiple = style.lineHeightMultiple > 0 ? style.lineHeightMultiple : 1
            properties.append("fo:line-height=\"\(Int((multiple * 100).rounded()))%\"")
        }
        if breakBefore { properties.append("fo:break-before=\"page\"") }
        let styleName = context.paragraphStyle(properties.joined(separator: " "), parent: odfStyleName(paragraph.namedStyle))

        let isHeading = paragraph.namedStyle.headingLevel != nil
        let element = isHeading ? "text:h" : "text:p"
        var xml = "<\(element) text:style-name=\"\(styleName)\""
        if let level = paragraph.namedStyle.headingLevel { xml += " text:outline-level=\"\(level)\"" }
        xml += ">"
        var leading = true
        var deletedLeading = true
        if content.length > 0 {
            var currentLink: String?
            var currentRevision: (mark: SuggestionMark, id: String)?
            func closeRevision() {
                if let revision = currentRevision, revision.mark.kind == .insertion {
                    xml += "<text:change-end text:change-id=\"\(revision.id)\"/>"
                }
                currentRevision = nil
            }
            text.enumerateAttributes(in: content, options: []) { runAttributes, runRange, _ in
                let link = DocxWriter.linkTarget(runAttributes[.link])
                let revision = runAttributes[.pdSuggestion] as? SuggestionMark
                if revision != currentRevision?.mark {
                    closeRevision()
                    if let revision {
                        let id = context.newChange(revision, style: styleName)
                        xml += revision.kind == .insertion ? "<text:change-start text:change-id=\"\(id)\"/>" : "<text:change text:change-id=\"\(id)\"/>"
                        currentRevision = (revision, id)
                        deletedLeading = true
                    }
                }
                let change = context.comments.move(to: runAttributes[.pdComments])
                if !(change.ending.isEmpty && change.starting.isEmpty), currentLink != nil {
                    xml += "</text:a>"
                    currentLink = nil
                }
                xml += annotationMarkers(change, context: &context)
                if link != currentLink {
                    if currentLink != nil { xml += "</text:a>" }
                    if let link { xml += "<text:a xlink:type=\"simple\" xlink:href=\"\(DocxWriter.escape(link))\">" }
                    currentLink = link
                }
                let run = (text.string as NSString).substring(with: runRange)
                let spanStyle = context.textStyle(textProperties(runAttributes, context: &context))
                var body = ""
                if let attachment = runAttributes[.attachment] as? NSTextAttachment, run.contains("\u{FFFC}") {
                    for (index, piece) in run.components(separatedBy: "\u{FFFC}").enumerated() {
                        if index > 0 {
                            if let field = attachment as? PageFieldAttachment {
                                body += field.kind == .pageNumber ? "<text:page-number text:select-page=\"current\">1</text:page-number>" : "<text:page-count>1</text:page-count>"
                            } else {
                                body += frameXML(attachment, context: &context)
                            }
                            leading = false
                        }
                        body += encode(piece, leading: &leading)
                    }
                } else if revision?.kind == .deletion {
                    body = encode(run, leading: &deletedLeading)
                } else {
                    body = encode(run, leading: &leading)
                }
                let span = "<text:span text:style-name=\"\(spanStyle)\">\(body)</text:span>"
                if revision?.kind == .deletion, let index = context.changes.indices.last {
                    context.changes[index].deleted += span
                } else {
                    xml += span
                }
            }
            closeRevision()
            if currentLink != nil { xml += "</text:a>" }
        }
        let ending = context.comments.endParagraph(markValue: CommentAnchors.markValue(in: text, after: content))
        xml += annotationMarkers((ending, []), context: &context)
        xml += "</\(element)>"
        return xml
    }

    static func trackedChangesXML(_ context: Context) -> String {
        guard !context.changes.isEmpty else { return "" }
        var xml = "<text:tracked-changes text:track-changes=\"false\">"
        for change in context.changes {
            let info = "<office:change-info><dc:creator>\(DocxWriter.escape(change.mark.author))</dc:creator>"
                + "<dc:date>\(Suggestions.timestamp(change.mark.date))</dc:date></office:change-info>"
            xml += "<text:changed-region xml:id=\"\(change.id)\" text:id=\"\(change.id)\">"
            if change.mark.kind == .insertion {
                xml += "<text:insertion>\(info)</text:insertion>"
            } else {
                xml += "<text:deletion>\(info)<text:p text:style-name=\"\(change.style)\">\(change.deleted)</text:p></text:deletion>"
            }
            xml += "</text:changed-region>"
        }
        return xml + "</text:tracked-changes>"
    }

    /// `office:annotation` starts (with replies as point annotations naming their parent) and ends.
    static func annotationMarkers(_ change: (ending: [String], starting: [String]), context: inout Context) -> String {
        var xml = ""
        for id in change.ending { xml += "<office:annotation-end office:name=\"\(context.annotationName(id))\"/>" }
        for id in change.starting {
            guard let thread = context.threads[id] else { continue }
            let name = context.annotationName(id)
            xml += annotationXML(author: thread.author, date: thread.date, text: thread.text,
                                 extra: " office:name=\"\(name)\"" + (thread.resolved ? " loext:resolved=\"true\"" : ""))
            for reply in thread.replies {
                xml += annotationXML(author: reply.author, date: reply.date, text: reply.text, extra: " loext:parent-name=\"\(name)\"")
            }
        }
        return xml
    }

    static func annotationXML(author: String, date: Date, text: String, extra: String) -> String {
        var xml = "<office:annotation\(extra)><dc:creator>\(DocxWriter.escape(author))</dc:creator>"
        xml += "<dc:date>\(ISO8601DateFormatter().string(from: date))</dc:date>"
        xml += "<meta:creator-initials>\(DocxWriter.escape(CommentThread.initials(author)))</meta:creator-initials>"
        for line in text.components(separatedBy: "\n") {
            var leading = true
            xml += "<text:p>\(encode(line, leading: &leading))</text:p>"
        }
        return xml + "</office:annotation>"
    }

    /// A table with column widths, borders, padding, cell colors and merged cells.
    static func tableXML(_ table: TableModel, context: inout Context) -> String {
        context.tableCount += 1
        let name = "\(context.prefix)Table\(context.tableCount)"
        context.tableStyleXML += "<style:style style:name=\"\(name)\" style:family=\"table\"><style:table-properties style:width=\"\(points(context.contentWidth))\" table:align=\"margins\"/></style:style>"
        for (index, width) in table.columnWidths.enumerated() {
            context.tableStyleXML += "<style:style style:name=\"\(name).C\(index + 1)\" style:family=\"table-column\"><style:table-column-properties style:column-width=\"\(points(width * context.contentWidth))\"/></style:style>"
        }
        let border = table.borderWidth > 0 ? "\(points(table.borderWidth)) solid #\(table.borderColor.hexString ?? "000000")" : "none"
        var cellStyles: [String: String] = [:]
        func cellStyle(_ background: NSColor?) -> String {
            let key = background?.hexString ?? ""
            if let existing = cellStyles[key] { return existing }
            let styleName = "\(name).A\(cellStyles.count + 1)"
            cellStyles[key] = styleName
            var properties = "fo:padding=\"\(points(table.padding))\" fo:border=\"\(border)\""
            if let hex = background?.hexString { properties += " fo:background-color=\"#\(hex)\"" }
            context.tableStyleXML += "<style:style style:name=\"\(styleName)\" style:family=\"table-cell\"><style:table-cell-properties \(properties)/></style:style>"
            return styleName
        }
        var xml = "<table:table table:name=\"\(name)\" table:style-name=\"\(name)\">"
        for index in table.columnWidths.indices { xml += "<table:table-column table:style-name=\"\(name).C\(index + 1)\"/>" }
        for row in 0..<table.rows {
            xml += "<table:table-row>"
            for column in 0..<table.columns {
                guard let cell = table.cell(row: row, column: column), cell.row == row, cell.column == column else {
                    xml += "<table:covered-table-cell/>"
                    continue
                }
                var open = "<table:table-cell table:style-name=\"\(cellStyle(cell.background))\" office:value-type=\"string\""
                if cell.columnSpan > 1 { open += " table:number-columns-spanned=\"\(cell.columnSpan)\"" }
                if cell.rowSpan > 1 { open += " table:number-rows-spanned=\"\(cell.rowSpan)\"" }
                xml += open + ">" + bodyXML(cell.content, context: &context) + "</table:table-cell>"
            }
            xml += "</table:table-row>"
        }
        xml += "</table:table>"
        return xml
    }

    /// An inline (as-character) picture frame.
    static func frameXML(_ attachment: NSTextAttachment, context: inout Context) -> String {
        guard let info = ImageAttachments.info(attachment), let portable = ImageAttachments.portableData(info) else { return "" }
        let (path, number) = context.addImage(data: portable.data, type: portable.type)
        return "<draw:frame draw:name=\"Image\(number)\" text:anchor-type=\"as-char\" svg:width=\"\(points(info.size.width))\" "
            + "svg:height=\"\(points(info.size.height))\" draw:z-index=\"0\"><draw:image xlink:href=\"\(path)\" xlink:type=\"simple\" "
            + "xlink:show=\"embed\" xlink:actuate=\"onLoad\"/></draw:frame>"
    }

    static func textProperties(_ attributes: [NSAttributedString.Key: Any], context: inout Context) -> String {
        let spec = FontResolver.spec(from: attributes)
        context.fonts.insert(spec.family)
        var properties = ["style:font-name=\"\(DocxWriter.escape(spec.family))\"", "fo:font-size=\"\(points(spec.size))\""]
        properties.append("fo:font-weight=\"\(spec.bold ? "bold" : "normal")\"")
        properties.append("fo:font-style=\"\(spec.italic ? "italic" : "normal")\"")
        let isPlainLink = attributes[.link] != nil && ((attributes[.foregroundColor] as? NSColor)?.hexString ?? "000000") == "000000"
        let underline = isPlainLink ? NSUnderlineStyle.single.rawValue : ((attributes[.underlineStyle] as? Int) ?? 0)
        if underline != 0 {
            properties.append("style:text-underline-style=\"solid\" style:text-underline-width=\"auto\" style:text-underline-color=\"font-color\"")
            if underline & NSUnderlineStyle.double.rawValue == NSUnderlineStyle.double.rawValue {
                properties.append("style:text-underline-type=\"double\"")
            }
        }
        if CharacterFormatting.isStruckThrough(attributes) { properties.append("style:text-line-through-style=\"solid\"") }
        properties.append("fo:color=\"#\(isPlainLink ? ColorPalette.linkHex : ((attributes[.foregroundColor] as? NSColor)?.hexString ?? "000000"))\"")
        if let highlight = (attributes[.backgroundColor] as? NSColor)?.hexString {
            properties.append("fo:background-color=\"#\(highlight)\"")
        }
        switch CharacterFormatting.baseline(attributes) {
        case 1: properties.append("style:text-position=\"super 58%\"")
        case -1: properties.append("style:text-position=\"sub 58%\"")
        default: break
        }
        return properties.joined(separator: " ")
    }

    /// Escapes text and encodes the whitespace ODF would otherwise collapse.
    static func encode(_ text: String, leading: inout Bool) -> String {
        var xml = ""
        var pendingSpaces = 0
        func flushSpaces() {
            guard pendingSpaces > 0 else { return }
            if leading {
                xml += "<text:s text:c=\"\(pendingSpaces)\"/>"
            } else {
                xml += " "
                if pendingSpaces > 1 { xml += "<text:s text:c=\"\(pendingSpaces - 1)\"/>" }
            }
            pendingSpaces = 0
        }
        for scalar in text.unicodeScalars {
            switch scalar {
            case " ":
                pendingSpaces += 1
            case "\t":
                flushSpaces(); xml += "<text:tab/>"; leading = false
            case "\u{2028}", "\u{0B}", "\u{0C}":
                flushSpaces(); xml += "<text:line-break/>"; leading = true
            case "\u{FFFC}":
                continue
            default:
                flushSpaces()
                xml += DocxWriter.escape(String(scalar))
                leading = false
            }
        }
        if pendingSpaces > 0 {
            // Trailing spaces: keep them all explicit.
            xml += "<text:s text:c=\"\(pendingSpaces)\"/>"
        }
        return xml
    }

    static func listStyleXML(name: String, preset: ListPreset, checked: Bool) -> String {
        var xml = "<text:list-style style:name=\"\(name)\">"
        for level in 0...ListItem.maxLevel {
            let format = preset.levelFormat(level)
            let indent = ListItem.textIndent(forLevel: level)
            let alignment = "<style:list-level-properties text:list-level-position-and-space-mode=\"label-alignment\">"
                + "<style:list-level-label-alignment text:label-followed-by=\"listtab\" text:list-tab-stop-position=\"\(points(indent))\" "
                + "fo:text-indent=\"-\(points(ListItem.markerOffset))\" fo:margin-left=\"\(points(indent))\"/></style:list-level-properties>"
            switch format.format {
            case .bullet(let glyph):
                xml += "<text:list-level-style-bullet text:level=\"\(level + 1)\" text:bullet-char=\"\(DocxWriter.escape(glyph))\">\(alignment)</text:list-level-style-bullet>"
            case .checkbox:
                xml += "<text:list-level-style-bullet text:level=\"\(level + 1)\" text:bullet-char=\"\(checked ? "☑" : "☐")\">\(alignment)</text:list-level-style-bullet>"
            default:
                let numFormat: String
                switch format.format {
                case .lowerAlpha: numFormat = "a"
                case .upperAlpha: numFormat = "A"
                case .lowerRoman: numFormat = "i"
                case .upperRoman: numFormat = "I"
                default: numFormat = "1"
                }
                let display = format.outline ? " text:display-levels=\"\(level + 1)\"" : ""
                xml += "<text:list-level-style-number text:level=\"\(level + 1)\" style:num-suffix=\"\(DocxWriter.escape(format.suffix))\" "
                    + "style:num-format=\"\(numFormat)\"\(display)>\(alignment)</text:list-level-style-number>"
            }
        }
        xml += "</text:list-style>"
        return xml
    }

    // MARK: - Parts

    static func points(_ value: CGFloat) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded() ? "\(Int(rounded))pt" : "\(rounded)pt"
    }

    static func fontDeclarations(_ fonts: Set<String>) -> String {
        "<office:font-face-decls>" + fonts.sorted().map { family in
            let escaped = DocxWriter.escape(family)
            return "<style:font-face style:name=\"\(escaped)\" svg:font-family=\"&apos;\(escaped)&apos;\"/>"
        }.joined() + "</office:font-face-decls>"
    }

    static func contentXML(body: String, context: Context) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<office:document-content \(namespaces) office:version=\"1.3\">"
            + fontDeclarations(context.fonts)
            + "<office:automatic-styles>\(context.automaticStyles)</office:automatic-styles>"
            + "<office:body><office:text>\(body)</office:text></office:body></office:document-content>"
    }

    static func stylesXML(_ setup: PageSetup, fonts: Set<String>, header: String? = nil, footer: String? = nil, masterStyles: String = "") -> String {
        let normal = NamedStyle.normal.definition
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<office:document-styles \(namespaces) office:version=\"1.3\">"
        xml += fontDeclarations(fonts)
        xml += "<office:styles>"
        xml += "<style:default-style style:family=\"paragraph\"><style:paragraph-properties fo:line-height=\"\(Int(normal.lineSpacing * 100))%\" "
            + "style:tab-stop-distance=\"\(points(DocumentDefaults.defaultTabInterval))\"/>"
            + "<style:text-properties style:font-name=\"\(normal.fontFamily)\" fo:font-size=\"\(points(normal.fontSize))\" fo:language=\"en\"/></style:default-style>"
        for style in NamedStyle.allCases {
            let definition = style.definition
            let name = odfStyleName(style)
            xml += "<style:style style:name=\"\(name)\" style:display-name=\"\(style == .normal ? "Default Paragraph Style" : style.displayName)\" style:family=\"paragraph\""
            if style != .normal { xml += " style:parent-style-name=\"Standard\" style:next-style-name=\"Standard\"" }
            if let level = style.headingLevel { xml += " style:default-outline-level=\"\(level)\"" }
            xml += " style:class=\"\(style.headingLevel != nil ? "text" : (style == .normal ? "text" : "chapter"))\">"
            if style != .normal {
                xml += "<style:paragraph-properties fo:margin-top=\"\(points(definition.spaceBefore))\" fo:margin-bottom=\"\(points(definition.spaceAfter))\" fo:keep-with-next=\"always\"/>"
                var text = "fo:font-size=\"\(points(definition.fontSize))\""
                if definition.colorHex != "000000" { text += " fo:color=\"#\(definition.colorHex)\"" }
                if definition.italic { text += " fo:font-style=\"italic\"" }
                if definition.bold { text += " fo:font-weight=\"bold\"" }
                xml += "<style:text-properties \(text)/>"
            }
            xml += "</style:style>"
        }
        xml += "</office:styles>"
        let size = setup.pageSize
        let m = setup.margins
        var layout = "fo:page-width=\"\(points(size.width))\" fo:page-height=\"\(points(size.height))\" style:print-orientation=\"\(setup.orientation.rawValue)\" "
            + "fo:margin-top=\"\(points(m.top))\" fo:margin-bottom=\"\(points(m.bottom))\" fo:margin-left=\"\(points(m.left))\" fo:margin-right=\"\(points(m.right))\""
        if let color = setup.pageColorHex { layout += " fo:background-color=\"#\(color)\"" }
        xml += "<office:automatic-styles><style:page-layout style:name=\"pm1\"><style:page-layout-properties \(layout)/></style:page-layout>\(masterStyles)</office:automatic-styles>"
        xml += "<office:master-styles><style:master-page style:name=\"Standard\" style:page-layout-name=\"pm1\">"
        if let header { xml += "<style:header>\(header)</style:header>" }
        if header != nil, setup.differentFirstPage { xml += "<style:header-first><text:p/></style:header-first>" }
        if let footer { xml += "<style:footer>\(footer)</style:footer>" }
        if footer != nil, setup.differentFirstPage { xml += "<style:footer-first><text:p/></style:footer-first>" }
        xml += "</style:master-page></office:master-styles>"
        xml += "</office:document-styles>"
        return xml
    }

    static func manifestXML(images: [(path: String, data: Data, type: UTType)]) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"1.3\">"
        xml += "<manifest:file-entry manifest:full-path=\"/\" manifest:version=\"1.3\" manifest:media-type=\"\(mimeType)\"/>"
        for part in ["content.xml", "styles.xml", "meta.xml"] {
            xml += "<manifest:file-entry manifest:full-path=\"\(part)\" manifest:media-type=\"text/xml\"/>"
        }
        for image in images {
            xml += "<manifest:file-entry manifest:full-path=\"\(image.path)\" manifest:media-type=\"\(ImageAttachments.mimeType(image.type))\"/>"
        }
        xml += "</manifest:manifest>"
        return xml
    }

    static func metaXML(date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: date)
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<office:document-meta \(namespaces) office:version=\"1.3\"><office:meta>"
            + "<meta:generator>PuggleDocs</meta:generator><meta:creation-date>\(stamp)</meta:creation-date><dc:date>\(stamp)</dc:date>"
            + "</office:meta></office:document-meta>"
    }
}
