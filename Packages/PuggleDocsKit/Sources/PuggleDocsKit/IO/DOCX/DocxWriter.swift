import AppKit
import UniformTypeIdentifiers

/// Writes Office Open XML (.docx) documents.
public enum DocxWriter {
    static let wNamespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    static let rNamespace = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let relationshipsNamespace = "http://schemas.openxmlformats.org/package/2006/relationships"
    static let wpNamespace = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
    static let drawingNamespace = "http://schemas.openxmlformats.org/drawingml/2006/main"
    static let pictureNamespace = "http://schemas.openxmlformats.org/drawingml/2006/picture"
    static let emuPerPoint: CGFloat = 12_700
    static let officeRelationshipBase = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"

    public static func write(_ content: DocumentContent, date: Date = Date()) throws -> Data {
        var context = Context(text: content.text)
        context.contentWidth = content.pageSetup.contentSize.width
        context.threads = Dictionary(content.comments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        context.comments = CommentRangeTracker(threads: content.comments)
        let body = documentXML(content: content, context: &context)
        // Header and footer parts share numbering, links and images with the body.
        var parts: [(path: String, id: String, kind: String, xml: String)] = []
        for (kind, text) in [("header", content.header), ("footer", content.footer)] {
            guard let text, text.length > 0 else { continue }
            var partContext = context.switching(to: text)
            partContext.comments = CommentRangeTracker(threads: []) // Comments are only anchored in the body.
            let xml = headerFooterXML(text, kind: kind, context: &partContext)
            context.absorb(partContext)
            parts.append(("\(kind)1.xml", "rId\(kind.capitalized)1", kind, xml))
            if content.pageSetup.differentFirstPage {
                parts.append(("\(kind)2.xml", "rId\(kind.capitalized)First", kind,
                              "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<w:\(kind == "header" ? "hdr" : "ftr") xmlns:w=\"\(wNamespace)\"><w:p/></w:\(kind == "header" ? "hdr" : "ftr")>"))
            }
        }
        context.headerFooterParts = parts.map { ($0.path, $0.id, $0.kind) }

        var zip = ZipWriter(date: date)
        zip.add(path: "[Content_Types].xml", data: Data(contentTypesXML(hasNumbering: context.hasLists, imageTypes: Set(context.images.map(\.type)),
                                                                         parts: parts.map { ($0.path, $0.kind) },
                                                                         hasComments: !context.writtenComments.isEmpty).utf8))
        zip.add(path: "_rels/.rels", data: Data(packageRelationshipsXML.utf8))
        zip.add(path: "docProps/core.xml", data: Data(corePropertiesXML(date: date).utf8))
        zip.add(path: "docProps/app.xml", data: Data(appPropertiesXML.utf8))
        zip.add(path: "word/document.xml", data: Data(body.utf8))
        for part in parts { zip.add(path: "word/" + part.path, data: Data(part.xml.utf8)) }
        if !context.writtenComments.isEmpty {
            zip.add(path: "word/comments.xml", data: Data(commentsXML(context).utf8))
            zip.add(path: "word/commentsExtended.xml", data: Data(commentsExtendedXML(context).utf8))
        }
        zip.add(path: "word/styles.xml", data: Data(DocxStyles.stylesXML.utf8))
        zip.add(path: "word/settings.xml", data: Data(settingsXML.utf8))
        if context.hasLists {
            zip.add(path: "word/numbering.xml", data: Data(numberingXML(context: context).utf8))
        }
        for image in context.images {
            zip.add(path: "word/" + image.path, data: image.data, compress: false)
        }
        zip.add(path: "word/_rels/document.xml.rels", data: Data(documentRelationshipsXML(context: context).utf8))
        return zip.finish()
    }

    // MARK: - Context

    struct NumberingInstance {
        let numID: Int
        let preset: ListPreset
        let checked: Bool
    }

    struct Context {
        var text: NSAttributedString
        var contentWidth: CGFloat = 468
        var headerFooterParts: [(path: String, id: String, kind: String)] = []
        var numbering: [String: NumberingInstance] = [:]
        var numberingOrder: [String] = []
        var hyperlinks: [(id: String, target: String)] = []
        var hyperlinkIDs: [String: String] = [:]
        var images: [(id: String, path: String, data: Data, type: UTType)] = []
        var threads: [String: CommentThread] = [:]
        var comments = CommentRangeTracker(threads: [])
        /// Thread id → Word comment ids (the thread's own first, then one per reply).
        var commentNumbers: [String: [Int]] = [:]
        var nextCommentNumber = 0
        var writtenComments: [String] { comments.order }
        /// Revision ids (w:ins, w:del) live apart from comment ids.
        var nextRevisionNumber = 10_000

        mutating func commentNumbers(for threadID: String) -> [Int] {
            if let existing = commentNumbers[threadID] { return existing }
            guard let thread = threads[threadID] else { return [] }
            let numbers = (0...thread.replies.count).map { offset in nextCommentNumber + offset }
            nextCommentNumber += numbers.count
            commentNumbers[threadID] = numbers
            return numbers
        }

        init(text: NSAttributedString) { self.text = text }

        /// A copy that writes `text` while keeping shared numbering, links and images.
        func switching(to text: NSAttributedString) -> Context {
            var copy = self
            copy.text = text
            return copy
        }

        mutating func absorb(_ other: Context) {
            numbering = other.numbering
            numberingOrder = other.numberingOrder
            hyperlinks = other.hyperlinks
            hyperlinkIDs = other.hyperlinkIDs
            images = other.images
        }

        var hasLists: Bool { !numbering.isEmpty }

        mutating func numID(for item: ListItem) -> Int {
            // Checked checklist items use a separate definition so the box renders ticked.
            let key = item.kind == .checklist ? "\(item.listID)|\(item.isChecked)" : item.listID
            if let existing = numbering[key] { return existing.numID }
            let instance = NumberingInstance(numID: numbering.count + 1, preset: item.preset, checked: item.isChecked)
            numbering[key] = instance
            numberingOrder.append(key)
            return instance.numID
        }

        mutating func addImage(data: Data, type: UTType) -> (relationshipID: String, number: Int) {
            let number = images.count + 1
            let id = "rIdImage\(number)"
            images.append((id, "media/image\(number).\(ImageAttachments.fileExtension(type))", data, type))
            return (id, number)
        }

        mutating func relationshipID(forLink target: String) -> String {
            if let existing = hyperlinkIDs[target] { return existing }
            let id = "rIdLink\(hyperlinks.count + 1)"
            hyperlinks.append((id, target))
            hyperlinkIDs[target] = id
            return id
        }
    }

    // MARK: - document.xml

    static func documentXML(content: DocumentContent, context: inout Context) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        xml += "<w:document xmlns:w=\"\(wNamespace)\" xmlns:r=\"\(rNamespace)\" xmlns:wp=\"\(wpNamespace)\" xmlns:a=\"\(drawingNamespace)\" xmlns:pic=\"\(pictureNamespace)\">"
        if let color = content.pageSetup.pageColorHex {
            xml += "<w:background w:color=\"\(color)\"/>"
        }
        xml += "<w:body>"
        let text = content.text
        let string = text.string as NSString
        if string.length == 0 {
            xml += paragraphXML(range: NSRange(location: 0, length: 0), attributes: DocumentDefaults.typingAttributes, context: &context)
        }
        xml += blocksXML(text, context: &context)
        // A trailing newline means the text ends with an empty paragraph; keep it.
        if string.length > 0, isParagraphSeparator(string.character(at: string.length - 1)), TableModel.block(at: string.length - 1, in: text) == nil {
            let attributes = text.attributes(at: string.length - 1, effectiveRange: nil)
            xml += paragraphXML(range: NSRange(location: string.length, length: 0), attributes: attributes, context: &context)
        }
        let unfinished = context.comments.finish()
        if !unfinished.isEmpty {
            xml += "<w:p>" + commentMarkers((unfinished, []), context: &context) + "</w:p>"
        }
        xml += sectionPropertiesXML(content.pageSetup, hasHeader: content.hasHeader, hasFooter: content.hasFooter)
        xml += "</w:body></w:document>"
        return xml
    }

    /// Paragraphs and tables of `text`, in order.
    static func blocksXML(_ text: NSAttributedString, context: inout Context) -> String {
        let savedText = context.text
        context.text = text
        defer { context.text = savedText }
        let string = text.string as NSString
        var xml = ""
        var location = 0
        while location < string.length {
            if TableModel.block(at: location, in: text) != nil, let table = TableModel.table(at: location, in: text), table.range.length > 0 {
                xml += tableXML(table, context: &context)
                location = NSMaxRange(table.range)
                continue
            }
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)
            var contentRange = paragraph
            while contentRange.length > 0, isParagraphSeparator(string.character(at: NSMaxRange(contentRange) - 1)) { contentRange.length -= 1 }
            xml += paragraphXML(range: contentRange, attributes: text.attributes(at: paragraph.location, effectiveRange: nil), context: &context)
        }
        return xml
    }

    /// A table: grid, borders, padding, cell widths, shading and merged cells.
    static func tableXML(_ table: TableModel, context: inout Context) -> String {
        let totalTwips = twips(context.contentWidth)
        let border = table.borderWidth > 0
            ? "w:val=\"single\" w:sz=\"\(max(2, Int((table.borderWidth * 8).rounded())))\" w:space=\"0\" w:color=\"\(table.borderColor.hexString ?? "000000")\""
            : "w:val=\"nil\""
        var xml = "<w:tbl><w:tblPr><w:tblW w:w=\"5000\" w:type=\"pct\"/><w:tblBorders>"
        for edge in ["top", "left", "bottom", "right", "insideH", "insideV"] { xml += "<w:\(edge) \(border)/>" }
        xml += "</w:tblBorders><w:tblLayout w:type=\"fixed\"/><w:tblCellMar>"
        for edge in ["top", "left", "bottom", "right"] { xml += "<w:\(edge) w:w=\"\(twips(table.padding))\" w:type=\"dxa\"/>" }
        xml += "</w:tblCellMar></w:tblPr><w:tblGrid>"
        let widths = table.columnWidths.map { Int((CGFloat(totalTwips) * $0).rounded()) }
        for width in widths { xml += "<w:gridCol w:w=\"\(width)\"/>" }
        xml += "</w:tblGrid>"
        for row in 0..<table.rows {
            xml += "<w:tr>"
            var column = 0
            while column < table.columns {
                guard let cell = table.cell(row: row, column: column) else {
                    xml += "<w:tc><w:tcPr><w:tcW w:w=\"\(widths[column])\" w:type=\"dxa\"/></w:tcPr><w:p/></w:tc>"
                    column += 1
                    continue
                }
                let span = min(cell.columnSpan, table.columns - cell.column)
                let width = (cell.column..<(cell.column + span)).reduce(0) { $0 + widths[$1] }
                var properties = "<w:tcW w:w=\"\(width)\" w:type=\"dxa\"/>"
                if span > 1 { properties += "<w:gridSpan w:val=\"\(span)\"/>" }
                if cell.rowSpan > 1 { properties += cell.row == row ? "<w:vMerge w:val=\"restart\"/>" : "<w:vMerge/>" }
                if let background = cell.background?.hexString { properties += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(background)\"/>" }
                var content = cell.row == row ? blocksXML(cell.content, context: &context) : ""
                if !content.hasSuffix("</w:p>") { content += "<w:p/>" }
                xml += "<w:tc><w:tcPr>\(properties)</w:tcPr>\(content)</w:tc>"
                column += span
            }
            xml += "</w:tr>"
        }
        xml += "</w:tbl>"
        return xml
    }

    /// `header1.xml` / `footer1.xml` content.
    static func headerFooterXML(_ text: NSAttributedString, kind: String, context: inout Context) -> String {
        let root = kind == "header" ? "hdr" : "ftr"
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        xml += "<w:\(root) xmlns:w=\"\(wNamespace)\" xmlns:r=\"\(rNamespace)\" xmlns:wp=\"\(wpNamespace)\" xmlns:a=\"\(drawingNamespace)\" xmlns:pic=\"\(pictureNamespace)\">"
        xml += blocksXML(text, context: &context)
        xml += "</w:\(root)>"
        return xml
    }

    static func isParagraphSeparator(_ character: unichar) -> Bool {
        character == 0x0A || character == 0x0D || character == 0x2029 || character == 0x85
    }

    static func paragraphXML(range: NSRange, attributes: [NSAttributedString.Key: Any], context: inout Context) -> String {
        var xml = "<w:p>"
        var properties = paragraphPropertiesXML(attributes, context: &context)
        // A suggested paragraph break is a revision on the paragraph mark.
        let separator = NSMaxRange(range)
        if separator < context.text.length, isParagraphSeparator((context.text.string as NSString).character(at: separator)),
           let mark = context.text.attribute(.pdSuggestion, at: separator, effectiveRange: nil) as? SuggestionMark {
            let element = revisionXML(mark, context: &context, empty: true)
            if let rPr = properties.range(of: "<w:rPr>") {
                properties.insert(contentsOf: element, at: rPr.upperBound)
            } else if let rPr = properties.range(of: "<w:rPr/>") {
                properties.replaceSubrange(rPr, with: "<w:rPr>\(element)</w:rPr>")
            } else {
                properties = properties.replacingOccurrences(of: "</w:pPr>", with: "<w:rPr>\(element)</w:rPr></w:pPr>")
            }
        }
        xml += properties
        if range.length > 0 {
            var currentLink: String?
            var currentRevision: SuggestionMark?
            func closeRevision() {
                guard let revision = currentRevision else { return }
                xml += revision.kind == .insertion ? "</w:ins>" : "</w:del>"
                currentRevision = nil
            }
            context.text.enumerateAttributes(in: range, options: []) { runAttributes, runRange, _ in
                let link = linkTarget(runAttributes[.link])
                let revision = runAttributes[.pdSuggestion] as? SuggestionMark
                let change = context.comments.move(to: runAttributes[.pdComments])
                if !(change.ending.isEmpty && change.starting.isEmpty) {
                    closeRevision()
                    if currentLink != nil {
                        xml += "</w:hyperlink>"
                        currentLink = nil
                    }
                }
                xml += commentMarkers(change, context: &context)
                if link != currentLink {
                    closeRevision()
                    if currentLink != nil { xml += "</w:hyperlink>" }
                    if let link { xml += "<w:hyperlink r:id=\"\(context.relationshipID(forLink: link))\" w:history=\"1\">" }
                    currentLink = link
                }
                if revision != currentRevision {
                    closeRevision()
                    if let revision {
                        xml += revisionXML(revision, context: &context, empty: false)
                        currentRevision = revision
                    }
                }
                let text = (context.text.string as NSString).substring(with: runRange)
                xml += runsXML(text: text, attributes: runAttributes, isLink: link != nil, deleted: revision?.kind == .deletion, context: &context)
            }
            closeRevision()
            if currentLink != nil { xml += "</w:hyperlink>" }
        }
        let ending = context.comments.endParagraph(markValue: CommentAnchors.markValue(in: context.text, after: range))
        xml += commentMarkers((ending, []), context: &context)
        xml += "</w:p>"
        return xml
    }

    static func linkTarget(_ value: Any?) -> String? {
        if let url = value as? URL { return url.absoluteString }
        if let string = value as? String, !string.isEmpty { return string }
        return nil
    }

    static func paragraphPropertiesXML(_ attributes: [NSAttributedString.Key: Any], context: inout Context) -> String {
        let paragraph = ParagraphAttributes(attributes: attributes)
        let style = paragraph.style
        var xml = "<w:pPr>"
        if paragraph.namedStyle != .normal {
            xml += "<w:pStyle w:val=\"\(paragraph.namedStyle.docxStyleID)\"/>"
        }
        if let item = paragraph.listItem {
            xml += "<w:numPr><w:ilvl w:val=\"\(item.level)\"/><w:numId w:val=\"\(context.numID(for: item))\"/></w:numPr>"
        }
        let customTabs = style.tabStops.filter { $0.location > 0 }
        if !customTabs.isEmpty && !isDefaultTabArray(customTabs) {
            xml += "<w:tabs>"
            for tab in customTabs.prefix(64) {
                let kind: String
                switch tab.alignment {
                case .center: kind = "center"
                case .right: kind = "right"
                default: kind = tab.options[.columnTerminators] != nil ? "decimal" : "left"
                }
                xml += "<w:tab w:val=\"\(kind)\" w:pos=\"\(twips(tab.location))\"/>"
            }
            xml += "</w:tabs>"
        }
        xml += "<w:spacing w:before=\"\(twips(style.paragraphSpacingBefore))\" w:after=\"\(twips(style.paragraphSpacing))\" \(lineSpacingAttributes(style))/>"
        if let item = paragraph.listItem {
            xml += "<w:ind w:left=\"\(twips(item.textIndent))\" w:hanging=\"\(twips(ListItem.markerOffset))\"\(rightIndentAttribute(style))/>"
        } else {
            let left = style.headIndent
            let first = style.firstLineHeadIndent - style.headIndent
            var ind = "<w:ind w:left=\"\(twips(left))\""
            if first > 0 { ind += " w:firstLine=\"\(twips(first))\"" }
            if first < 0 { ind += " w:hanging=\"\(twips(-first))\"" }
            ind += rightIndentAttribute(style) + "/>"
            xml += ind
        }
        switch style.alignment {
        case .center: xml += "<w:jc w:val=\"center\"/>"
        case .right: xml += "<w:jc w:val=\"right\"/>"
        case .justified: xml += "<w:jc w:val=\"both\"/>"
        default: xml += "<w:jc w:val=\"left\"/>"
        }
        xml += runPropertiesXML(attributes, isLink: false)
        xml += "</w:pPr>"
        return xml
    }

    static func rightIndentAttribute(_ style: NSParagraphStyle) -> String {
        style.tailIndent < 0 ? " w:right=\"\(twips(-style.tailIndent))\"" : " w:right=\"0\""
    }

    /// AppKit's default paragraph style carries twelve stops every 28 points; those are not real tabs.
    static func isDefaultTabArray(_ tabs: [NSTextTab]) -> Bool {
        let defaults = NSParagraphStyle.default.tabStops
        return tabs.count == defaults.count && zip(tabs, defaults).allSatisfy { $0.location == $1.location && $0.alignment == $1.alignment }
    }

    static func lineSpacingAttributes(_ style: NSParagraphStyle) -> String {
        if style.maximumLineHeight > 0, style.minimumLineHeight == style.maximumLineHeight {
            return "w:line=\"\(twips(style.maximumLineHeight))\" w:lineRule=\"exact\""
        }
        if style.minimumLineHeight > 0 {
            return "w:line=\"\(twips(style.minimumLineHeight))\" w:lineRule=\"atLeast\""
        }
        let multiple = style.lineHeightMultiple > 0 ? style.lineHeightMultiple : 1
        return "w:line=\"\(Int((multiple * 240).rounded()))\" w:lineRule=\"auto\""
    }

    static func runsXML(text: String, attributes: [NSAttributedString.Key: Any], isLink: Bool, deleted: Bool = false,
                        context: inout Context) -> String {
        let properties = runPropertiesXML(attributes, isLink: isLink)
        let textElement = deleted ? "w:delText" : "w:t"
        var xml = ""
        var buffer = ""
        func flush() {
            guard !buffer.isEmpty else { return }
            xml += "<w:r>\(properties)<\(textElement) xml:space=\"preserve\">\(escape(buffer))</\(textElement)></w:r>"
            buffer = ""
        }
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\t":
                flush(); xml += "<w:r>\(properties)<w:tab/></w:r>"
            case "\u{2028}", "\u{0B}":
                flush(); xml += "<w:r>\(properties)<w:br/></w:r>"
            case "\u{0C}":
                flush(); xml += "<w:r>\(properties)<w:br w:type=\"page\"/></w:r>"
            case "\u{FFFC}":
                flush()
                if let field = attributes[.attachment] as? PageFieldAttachment {
                    let instruction = field.kind == .pageNumber ? "PAGE" : "NUMPAGES"
                    xml += "<w:fldSimple w:instr=\" \(instruction) \"><w:r>\(properties)<w:t>1</w:t></w:r></w:fldSimple>"
                } else if let attachment = attributes[.attachment] as? NSTextAttachment {
                    xml += drawingXML(attachment, context: &context)
                }
            default:
                buffer.unicodeScalars.append(scalar)
            }
        }
        flush()
        return xml
    }

    /// Opens a `w:ins` or `w:del` (or writes an empty one for a paragraph mark).
    static func revisionXML(_ mark: SuggestionMark, context: inout Context, empty: Bool) -> String {
        context.nextRevisionNumber += 1
        let tag = mark.kind == .insertion ? "w:ins" : "w:del"
        let date = Suggestions.timestamp(mark.date)
        return "<\(tag) w:id=\"\(context.nextRevisionNumber)\" w:author=\"\(escape(mark.author))\" w:date=\"\(date)\"\(empty ? "/" : "")>"
    }

    /// Range markers for comments that end and start here. Replies share their thread's range.
    static func commentMarkers(_ change: (ending: [String], starting: [String]), context: inout Context) -> String {
        var xml = ""
        for id in change.ending {
            for number in context.commentNumbers(for: id) {
                xml += "<w:commentRangeEnd w:id=\"\(number)\"/><w:r><w:commentReference w:id=\"\(number)\"/></w:r>"
            }
        }
        for id in change.starting {
            for number in context.commentNumbers(for: id) { xml += "<w:commentRangeStart w:id=\"\(number)\"/>" }
        }
        return xml
    }

    static func paraID(_ number: Int) -> String { String(format: "%08X", 0x1000_0000 + number) }

    static func commentXML(number: Int, author: String, date: Date, text: String) -> String {
        let formatter = ISO8601DateFormatter()
        var xml = "<w:comment w:id=\"\(number)\" w:author=\"\(escape(author))\" w:date=\"\(formatter.string(from: date))\" w:initials=\"\(escape(CommentThread.initials(author)))\">"
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let paraAttribute = index == lines.count - 1 ? " w14:paraId=\"\(paraID(number))\" w14:textId=\"77777777\"" : ""
            xml += "<w:p\(paraAttribute)>"
            if index == 0 { xml += "<w:r><w:annotationRef/></w:r>" }
            xml += "<w:r><w:t xml:space=\"preserve\">\(escape(line))</w:t></w:r></w:p>"
        }
        xml += "</w:comment>"
        return xml
    }

    static func commentsXML(_ context: Context) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        xml += "<w:comments xmlns:w=\"\(wNamespace)\" xmlns:w14=\"http://schemas.microsoft.com/office/word/2010/wordml\">"
        for id in context.writtenComments {
            guard let thread = context.threads[id], let numbers = context.commentNumbers[id] else { continue }
            xml += commentXML(number: numbers[0], author: thread.author, date: thread.date, text: thread.text)
            for (reply, number) in zip(thread.replies, numbers.dropFirst()) {
                xml += commentXML(number: number, author: reply.author, date: reply.date, text: reply.text)
            }
        }
        xml += "</w:comments>"
        return xml
    }

    /// Reply threading and the resolved state (Word 2013+ "commentsExtended").
    static func commentsExtendedXML(_ context: Context) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        xml += "<w15:commentsEx xmlns:w15=\"http://schemas.microsoft.com/office/word/2012/wordml\">"
        for id in context.writtenComments {
            guard let thread = context.threads[id], let numbers = context.commentNumbers[id] else { continue }
            let root = paraID(numbers[0])
            xml += "<w15:commentEx w15:paraId=\"\(root)\" w15:done=\"\(thread.resolved ? 1 : 0)\"/>"
            for number in numbers.dropFirst() {
                xml += "<w15:commentEx w15:paraId=\"\(paraID(number))\" w15:paraIdParent=\"\(root)\" w15:done=\"0\"/>"
            }
        }
        xml += "</w15:commentsEx>"
        return xml
    }

    /// An inline picture (DrawingML) for an image attachment.
    static func drawingXML(_ attachment: NSTextAttachment, context: inout Context) -> String {
        guard let info = ImageAttachments.info(attachment), let portable = ImageAttachments.portableData(info) else { return "" }
        let (id, number) = context.addImage(data: portable.data, type: portable.type)
        let cx = Int((info.size.width * emuPerPoint).rounded())
        let cy = Int((info.size.height * emuPerPoint).rounded())
        return "<w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\"><wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/>"
            + "<wp:docPr id=\"\(number)\" name=\"Picture \(number)\"/><wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect=\"1\"/></wp:cNvGraphicFramePr>"
            + "<a:graphic><a:graphicData uri=\"\(pictureNamespace)\"><pic:pic><pic:nvPicPr><pic:cNvPr id=\"\(number)\" name=\"image\(number)\"/><pic:cNvPicPr/></pic:nvPicPr>"
            + "<pic:blipFill><a:blip r:embed=\"\(id)\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
            + "<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr>"
            + "</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>"
    }

    static func runPropertiesXML(_ attributes: [NSAttributedString.Key: Any], isLink: Bool) -> String {
        let spec = FontResolver.spec(from: attributes)
        let family = escape(spec.family)
        var xml = "<w:rPr>"
        xml += "<w:rFonts w:ascii=\"\(family)\" w:hAnsi=\"\(family)\" w:eastAsia=\"\(family)\" w:cs=\"\(family)\"/>"
        if spec.bold { xml += "<w:b/><w:bCs/>" }
        if spec.italic { xml += "<w:i/><w:iCs/>" }
        if CharacterFormatting.isStruckThrough(attributes) { xml += "<w:strike/>" }
        var color = (attributes[.foregroundColor] as? NSColor)?.hexString ?? "000000"
        if isLink && color == "000000" { color = ColorPalette.linkHex }
        xml += "<w:color w:val=\"\(color)\"/>"
        let halfPoints = max(2, Int((spec.size * 2).rounded()))
        xml += "<w:sz w:val=\"\(halfPoints)\"/><w:szCs w:val=\"\(halfPoints)\"/>"
        let underline = (attributes[.underlineStyle] as? Int) ?? 0
        if underline != 0 || isLink {
            let double = underline & NSUnderlineStyle.double.rawValue == NSUnderlineStyle.double.rawValue
            xml += "<w:u w:val=\"\(double ? "double" : "single")\"/>"
        }
        if let highlight = (attributes[.backgroundColor] as? NSColor)?.hexString {
            xml += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(highlight)\"/>"
        }
        switch CharacterFormatting.baseline(attributes) {
        case 1: xml += "<w:vertAlign w:val=\"superscript\"/>"
        case -1: xml += "<w:vertAlign w:val=\"subscript\"/>"
        default: break
        }
        xml += "</w:rPr>"
        return xml
    }

    static func sectionPropertiesXML(_ setup: PageSetup, hasHeader: Bool = false, hasFooter: Bool = false) -> String {
        let size = setup.pageSize
        let orient = setup.orientation == .landscape ? " w:orient=\"landscape\"" : ""
        let m = setup.margins
        var references = ""
        if hasHeader {
            references += "<w:headerReference w:type=\"default\" r:id=\"rIdHeader1\"/>"
            if setup.differentFirstPage { references += "<w:headerReference w:type=\"first\" r:id=\"rIdHeaderFirst\"/>" }
        }
        if hasFooter {
            references += "<w:footerReference w:type=\"default\" r:id=\"rIdFooter1\"/>"
            if setup.differentFirstPage { references += "<w:footerReference w:type=\"first\" r:id=\"rIdFooterFirst\"/>" }
        }
        let titlePage = setup.differentFirstPage && (hasHeader || hasFooter) ? "<w:titlePg/>" : ""
        return "<w:sectPr>\(references)<w:pgSz w:w=\"\(twips(size.width))\" w:h=\"\(twips(size.height))\"\(orient)/>"
            + "<w:pgMar w:top=\"\(twips(m.top))\" w:right=\"\(twips(m.right))\" w:bottom=\"\(twips(m.bottom))\" w:left=\"\(twips(m.left))\" "
            + "w:header=\"\(twips(setup.headerDistance))\" w:footer=\"\(twips(setup.footerDistance))\" w:gutter=\"0\"/>"
            + "<w:pgNumType w:start=\"1\"/>\(titlePage)</w:sectPr>"
    }

    // MARK: - numbering.xml

    static func numberingXML(context: Context) -> String {
        var abstracts = ""
        var nums = ""
        for (index, key) in context.numberingOrder.enumerated() {
            guard let instance = context.numbering[key] else { continue }
            abstracts += "<w:abstractNum w:abstractNumId=\"\(index)\"><w:multiLevelType w:val=\"hybridMultilevel\"/>"
            for level in 0...ListItem.maxLevel {
                abstracts += levelXML(preset: instance.preset, level: level, checked: instance.checked)
            }
            abstracts += "</w:abstractNum>"
            nums += "<w:num w:numId=\"\(instance.numID)\"><w:abstractNumId w:val=\"\(index)\"/></w:num>"
        }
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<w:numbering xmlns:w=\"\(wNamespace)\">\(abstracts)\(nums)</w:numbering>"
    }

    static func levelXML(preset: ListPreset, level: Int, checked: Bool) -> String {
        let format = preset.levelFormat(level)
        let numFmt: String
        let levelText: String
        var isBullet = false
        switch format.format {
        case .bullet(let glyph): numFmt = "bullet"; levelText = glyph; isBullet = true
        case .checkbox: numFmt = "bullet"; levelText = checked ? "☑" : "☐"; isBullet = true
        case .decimal: numFmt = "decimal"; levelText = ""
        case .decimalZero: numFmt = "decimalZero"; levelText = ""
        case .lowerAlpha: numFmt = "lowerLetter"; levelText = ""
        case .upperAlpha: numFmt = "upperLetter"; levelText = ""
        case .lowerRoman: numFmt = "lowerRoman"; levelText = ""
        case .upperRoman: numFmt = "upperRoman"; levelText = ""
        }
        let text: String
        if isBullet {
            text = levelText
        } else if format.outline {
            text = (1...(level + 1)).map { "%\($0)" }.joined(separator: ".") + format.suffix
        } else {
            text = "%\(level + 1)" + format.suffix
        }
        var xml = "<w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(numFmt)\"/>"
        xml += "<w:lvlText w:val=\"\(escape(text))\"/><w:lvlJc w:val=\"left\"/>"
        xml += "<w:pPr><w:ind w:left=\"\(twips(ListItem.textIndent(forLevel: level)))\" w:hanging=\"\(twips(ListItem.markerOffset))\"/></w:pPr>"
        xml += "<w:rPr><w:rFonts w:ascii=\"Arial\" w:hAnsi=\"Arial\" w:eastAsia=\"Arial\" w:cs=\"Arial\"/><w:u w:val=\"none\"/></w:rPr>"
        xml += "</w:lvl>"
        return xml
    }

    // MARK: - Package parts

    static func contentTypesXML(hasNumbering: Bool, imageTypes: Set<UTType> = [], parts: [(path: String, kind: String)] = [],
                                hasComments: Bool = false) -> String {
        let main = "application/vnd.openxmlformats-officedocument.wordprocessingml"
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        xml += "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        xml += "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        xml += "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        for type in imageTypes.sorted(by: { $0.identifier < $1.identifier }) {
            xml += "<Default Extension=\"\(ImageAttachments.fileExtension(type))\" ContentType=\"\(ImageAttachments.mimeType(type))\"/>"
        }
        xml += "<Override PartName=\"/word/document.xml\" ContentType=\"\(main).document.main+xml\"/>"
        xml += "<Override PartName=\"/word/styles.xml\" ContentType=\"\(main).styles+xml\"/>"
        xml += "<Override PartName=\"/word/settings.xml\" ContentType=\"\(main).settings+xml\"/>"
        if hasNumbering { xml += "<Override PartName=\"/word/numbering.xml\" ContentType=\"\(main).numbering+xml\"/>" }
        for part in parts { xml += "<Override PartName=\"/word/\(part.path)\" ContentType=\"\(main).\(part.kind)+xml\"/>" }
        if hasComments {
            xml += "<Override PartName=\"/word/comments.xml\" ContentType=\"\(main).comments+xml\"/>"
            xml += "<Override PartName=\"/word/commentsExtended.xml\" ContentType=\"\(main).commentsExtended+xml\"/>"
        }
        xml += "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>"
        xml += "<Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>"
        xml += "</Types>"
        return xml
    }

    static let packageRelationshipsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="\(relationshipsNamespace)">\
    <Relationship Id="rId1" Type="\(officeRelationshipBase)officeDocument" Target="word/document.xml"/>\
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
    <Relationship Id="rId3" Type="\(officeRelationshipBase)extended-properties" Target="docProps/app.xml"/>\
    </Relationships>
    """

    static func documentRelationshipsXML(context: Context) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"\(relationshipsNamespace)\">"
        xml += "<Relationship Id=\"rId1\" Type=\"\(officeRelationshipBase)styles\" Target=\"styles.xml\"/>"
        xml += "<Relationship Id=\"rId2\" Type=\"\(officeRelationshipBase)settings\" Target=\"settings.xml\"/>"
        if context.hasLists {
            xml += "<Relationship Id=\"rId3\" Type=\"\(officeRelationshipBase)numbering\" Target=\"numbering.xml\"/>"
        }
        for image in context.images {
            xml += "<Relationship Id=\"\(image.id)\" Type=\"\(officeRelationshipBase)image\" Target=\"\(image.path)\"/>"
        }
        for part in context.headerFooterParts {
            xml += "<Relationship Id=\"\(part.id)\" Type=\"\(officeRelationshipBase)\(part.kind)\" Target=\"\(part.path)\"/>"
        }
        if !context.writtenComments.isEmpty {
            xml += "<Relationship Id=\"rIdComments\" Type=\"\(officeRelationshipBase)comments\" Target=\"comments.xml\"/>"
            xml += "<Relationship Id=\"rIdCommentsEx\" Type=\"http://schemas.microsoft.com/office/2011/relationships/commentsExtended\" Target=\"commentsExtended.xml\"/>"
        }
        for link in context.hyperlinks {
            xml += "<Relationship Id=\"\(link.id)\" Type=\"\(officeRelationshipBase)hyperlink\" Target=\"\(escape(link.target))\" TargetMode=\"External\"/>"
        }
        xml += "</Relationships>"
        return xml
    }

    static let settingsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:settings xmlns:w="\(wNamespace)"><w:displayBackgroundShape/><w:defaultTabStop w:val="720"/><w:characterSpacingControl w:val="doNotCompress"/>\
    <w:compat><w:compatSetting w:name="compatibilityMode" w:uri="http://schemas.microsoft.com/office/word" w:val="15"/></w:compat></w:settings>
    """

    static func corePropertiesXML(date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: date)
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
        xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\
        <dcterms:created xsi:type="dcterms:W3CDTF">\(stamp)</dcterms:created>\
        <dcterms:modified xsi:type="dcterms:W3CDTF">\(stamp)</dcterms:modified></cp:coreProperties>
        """
    }

    static let appPropertiesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>PuggleDocs</Application></Properties>
    """

    // MARK: - Helpers

    static func twips(_ points: CGFloat) -> Int { Int((points * 20).rounded()) }

    /// Escapes XML special characters and drops characters XML 1.0 cannot represent.
    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default:
                let value = scalar.value
                let valid = value == 0x9 || value == 0xA || value == 0xD || (0x20...0xD7FF).contains(value)
                    || (0xE000...0xFFFD).contains(value) || (0x10000...0x10FFFF).contains(value)
                if valid { result.unicodeScalars.append(scalar) }
            }
        }
        return result
    }
}
