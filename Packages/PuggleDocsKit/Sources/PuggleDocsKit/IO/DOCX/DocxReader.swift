import AppKit

/// Reads Office Open XML (.docx) documents.
public enum DocxReader {
    public static func read(_ data: Data) throws -> DocumentContent {
        let zip: ZipReader
        do {
            zip = try ZipReader(data: data)
        } catch {
            throw DocumentIOError.unreadable("It is not a valid Word document.")
        }
        var reader = try Reader(zip: zip)
        return try reader.run()
    }
}

private struct Relationship {
    let type: String
    let target: String
    let external: Bool
}

private struct Reader {
    let zip: ZipReader
    let documentPath: String
    var relationships: [String: Relationship] = [:]
    var styles = DocxStyleSheet()
    var numbering = DocxNumbering()
    var majorFont = "Calibri Light"
    var minorFont = "Calibri"

    var output = NSMutableAttributedString()
    var warnings: Set<ImportWarning> = []
    var pageSetup = PageSetup.localeDefault

    /// Field nesting: `inResult` becomes true after `separate`; `link` comes from HYPERLINK fields.
    struct Field {
        var instruction = ""
        var inResult = false
        var link: String?
        var page: PageFieldAttachment.Kind?
    }
    var headerID: String?
    var footerID: String?
    /// Word comment id → thread id (replies map to their thread).
    var commentThreadIDs: [String: String] = [:]
    var replyCommentIDs = Set<String>()
    var threads: [CommentThread] = []
    var openComments: [String] = []
    var anchoredThreads = Set<String>()
    /// The w:ins or w:del being read, and the last one read (adjacent revisions by the same person
    /// at the same moment are one suggestion: a replacement is a deletion then an insertion).
    var revision: SuggestionMark?
    var lastRevision: (mark: SuggestionMark, end: Int)?
    /// Point comments (a reference with no range) waiting for the next character.
    var pendingAnchors: [String] = []
    var fields: [Field] = []

    init(zip: ZipReader) throws {
        self.zip = zip
        var path = "word/document.xml"
        if let data = try zip.read("_rels/.rels"), let root = try? XMLTree.parse(data) {
            for node in root.children("Relationship") where node.attr("Type")?.hasSuffix("/officeDocument") == true {
                if let target = node.attr("Target") { path = Reader.resolve(target, base: "") }
            }
        }
        guard zip.contains(path) || zip.entries.keys.contains(where: { $0.caseInsensitiveCompare(path) == .orderedSame }) else {
            throw DocumentIOError.unreadable("It does not contain a Word document body.")
        }
        documentPath = path
    }

    static func resolve(_ target: String, base: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var parts = base.split(separator: "/").map(String.init)
        for component in target.split(separator: "/") {
            if component == ".." { if !parts.isEmpty { parts.removeLast() } } else if component != "." { parts.append(String(component)) }
        }
        return parts.joined(separator: "/")
    }

    var documentFolder: String {
        guard let slash = documentPath.lastIndex(of: "/") else { return "" }
        return String(documentPath[..<slash])
    }

    func part(_ path: String) throws -> XNode? {
        guard let data = try zip.read(path) else { return nil }
        return try XMLTree.parse(data)
    }

    mutating func run() throws -> DocumentContent {
        let fileName = (documentPath as NSString).lastPathComponent
        if let rels = try part("\(documentFolder)/_rels/\(fileName).rels") {
            for node in rels.children("Relationship") {
                guard let id = node.attr("Id"), let type = node.attr("Type"), let target = node.attr("Target") else { continue }
                relationships[id] = Relationship(type: type, target: target, external: node.attr("TargetMode") == "External")
            }
        }
        for relationship in relationships.values where !relationship.external {
            let path = Reader.resolve(relationship.target, base: documentFolder)
            if relationship.type.hasSuffix("/styles"), let root = try part(path) {
                styles = DocxStyleSheet(root)
            } else if relationship.type.hasSuffix("/numbering"), let root = try part(path) {
                numbering = DocxNumbering(root)
            } else if relationship.type.hasSuffix("/theme"), let root = try part(path) {
                readTheme(root)
            }
        }
        readComments()
        guard let document = try part(documentPath), let body = document.child("body") else {
            throw DocumentIOError.unreadable("The document body could not be read.")
        }
        for node in body.children { block(node) }
        let header = try headerFooter(headerID)
        let footer = try headerFooter(footerID)
        if let color = document.child("background")?.attr("color"), color.count == 6, color.uppercased() != "FFFFFF",
           NSColor(hex: color) != nil {
            pageSetup.pageColorHex = color.uppercased()
        }
        // Every paragraph was terminated with a newline; the last one is implicit in the editor.
        DocumentIO.trimFinalNewline(output)
        DocumentIO.normalizeImported(output)
        CommentAnchors.normalize(output, threads: threads)
        return DocumentContent(text: output, pageSetup: pageSetup, warnings: warnings, header: header, footer: footer, comments: threads)
    }

    /// Comments with their replies (commentsExtended) and resolved state.
    mutating func readComments() {
        let commentsPath = relationships.values.first { $0.type.hasSuffix("/comments") }.map { Reader.resolve($0.target, base: documentFolder) }
        guard let commentsPath, let root = try? part(commentsPath) else { return }
        var parents: [String: String] = [:]
        var done = Set<String>()
        if let extended = relationships.values.first(where: { $0.type.hasSuffix("/commentsExtended") }),
           let node = try? part(Reader.resolve(extended.target, base: documentFolder)) {
            for entry in node.children("commentEx") {
                guard let paraID = entry.attr("paraId") else { continue }
                if let parent = entry.attr("paraIdParent") { parents[paraID] = parent }
                if entry.attr("done") == "1" { done.insert(paraID) }
            }
        }
        let formatter = ISO8601DateFormatter()
        var byParaID: [String: Int] = [:]
        var entries: [(id: String, author: String, date: Date, text: String, paraID: String?)] = []
        for comment in root.children("comment") {
            guard let id = comment.attr("id") else { continue }
            let paragraphs = comment.children("p")
            let text = paragraphs.map { paragraph in Reader.plainText(paragraph) }.joined(separator: "\n")
            let rawDate = comment.attr("date") ?? ""
            let date = formatter.date(from: rawDate) ?? formatter.date(from: rawDate + "Z") ?? Date()
            let paraID = paragraphs.last?.attr("paraId")
            if let paraID { byParaID[paraID] = entries.count }
            entries.append((id, comment.attr("author") ?? "Unknown", date, text, paraID))
        }
        for entry in entries {
            if let paraID = entry.paraID, let parentParaID = parents[paraID], let parentIndex = byParaID[parentParaID],
               let threadID = commentThreadIDs[entries[parentIndex].id], let index = threads.firstIndex(where: { $0.id == threadID }) {
                threads[index].replies.append(CommentReply(author: entry.author, date: entry.date, text: entry.text))
                commentThreadIDs[entry.id] = threadID
                replyCommentIDs.insert(entry.id)
                continue
            }
            let thread = CommentThread(author: entry.author, date: entry.date, text: entry.text,
                                       resolved: entry.paraID.map { done.contains($0) } ?? false)
            threads.append(thread)
            commentThreadIDs[entry.id] = thread.id
        }
    }

    static func plainText(_ node: XNode) -> String {
        var text = ""
        for child in node.children {
            switch child.name {
            case "t": text += child.text
            case "tab": text += "\t"
            case "br", "cr": text += "\n"
            case "annotationRef", "delText", "instrText": continue
            default: text += plainText(child)
            }
        }
        return text
    }

    /// Reads the contents of a w:ins/w:del (or w:moveTo/w:moveFrom) as a suggestion.
    mutating func withRevision(_ node: XNode, _ body: (inout Reader) -> Void) {
        let saved = revision
        let mark = revisionMark(node)
        revision = mark
        body(&self)
        lastRevision = (mark, output.length)
        revision = saved
    }

    mutating func revisionMark(_ node: XNode) -> SuggestionMark {
        let kind: SuggestionMark.Kind = node.name == "ins" || node.name == "moveTo" ? .insertion : .deletion
        let author = node.attr("author") ?? "Unknown"
        let date = Suggestions.date(node.attr("date")) ?? Date(timeIntervalSince1970: 0)
        if let previous = Suggestions.continues(lastRevision, at: output.length, author: author, date: date) {
            return SuggestionMark(id: previous.id, kind: kind, author: author, date: previous.date)
        }
        return SuggestionMark(kind: kind, author: author, date: date)
    }

    mutating func commentMarker(_ node: XNode) {
        guard let id = node.attr("id"), let threadID = commentThreadIDs[id], !replyCommentIDs.contains(id) else { return }
        if node.name == "commentRangeStart" {
            if !openComments.contains(threadID) { openComments.append(threadID) }
        } else {
            openComments.removeAll { $0 == threadID }
        }
    }

    /// Reads a header or footer part into its own text.
    mutating func headerFooter(_ id: String?) throws -> NSAttributedString? {
        guard let id, let relationship = relationships[id], let root = try part(Reader.resolve(relationship.target, base: documentFolder)) else { return nil }
        let body = output
        output = NSMutableAttributedString()
        defer { output = body }
        for node in root.children { block(node) }
        DocumentIO.trimFinalNewline(output)
        guard output.string.trimmingCharacters(in: .whitespacesAndNewlines).count > 0 || output.string.contains("\u{FFFC}") else { return nil }
        DocumentIO.normalizeImported(output)
        return NSAttributedString(attributedString: output)
    }

    mutating func readTheme(_ root: XNode) {
        if let latin = root.firstDescendant("majorFont")?.child("latin")?.attr("typeface"), !latin.isEmpty { majorFont = latin }
        if let latin = root.firstDescendant("minorFont")?.child("latin")?.attr("typeface"), !latin.isEmpty { minorFont = latin }
    }

    // MARK: Blocks

    mutating func block(_ node: XNode) {
        switch node.name {
        case "p": paragraph(node)
        case "tbl":
            table(node)
        case "sdt":
            node.child("sdtContent")?.children.forEach { block($0) }
        case "customXml", "smartTag":
            node.children.forEach { block($0) }
        case "ins", "moveTo", "del", "moveFrom":
            withRevision(node) { reader in node.children.forEach { reader.block($0) } }
        case "sectPr":
            readSection(node)
        case "commentRangeStart", "commentRangeEnd":
            commentMarker(node)
        case "AlternateContent":
            (node.child("Fallback") ?? node.child("Choice"))?.children.forEach { block($0) }
        default:
            break
        }
    }

    /// Reads a table into a text table: grid widths, borders, padding, shading and merged cells.
    mutating func table(_ node: XNode) {
        let properties = node.child("tblPr")
        let gridWidths = node.child("tblGrid")?.children("gridCol").compactMap { DocxParagraphProperties.points($0.attr("w")) } ?? []
        var cells: [TableModel.Cell] = []
        var openMerges: [Int: Int] = [:] // column → index of the cell a vertical merge continues
        var rowIndex = 0
        let rows = node.children("tr")
        for row in rows {
            var column = 0
            for cellNode in row.children.flatMap({ $0.name == "sdt" ? ($0.child("sdtContent")?.children ?? []) : [$0] }) where cellNode.name == "tc" {
                let cellProperties = cellNode.child("tcPr")
                let span = max(1, cellProperties?.child("gridSpan")?.attr("val").flatMap(Int.init) ?? 1)
                if let merge = cellProperties?.child("vMerge"), (merge.attr("val") ?? "continue") != "restart", let index = openMerges[column] {
                    cells[index].rowSpan += 1
                    column += span
                    continue
                }
                let start = output.length
                for child in cellNode.children where child.name != "tcPr" { block(child) }
                var range = NSRange(location: start, length: output.length - start)
                let content = NSMutableAttributedString()
                if range.length > 0 {
                    if (output.string as NSString).character(at: NSMaxRange(range) - 1) == 0x0A { range.length -= 1 }
                    content.append(output.attributedSubstring(from: range))
                    output.deleteCharacters(in: NSRange(location: start, length: output.length - start))
                }
                var cell = TableModel.Cell(row: rowIndex, column: column, columnSpan: span, content: content)
                if let fill = cellProperties?.child("shd")?.attr("fill"), fill.count == 6, fill.lowercased() != "auto", fill.uppercased() != "FFFFFF" {
                    cell.background = NSColor(hex: fill)
                }
                cells.append(cell)
                if cellProperties?.child("vMerge")?.attr("val") == "restart" { openMerges[column] = cells.count - 1 } else { openMerges[column] = nil }
                column += span
            }
            rowIndex += 1
        }
        guard !cells.isEmpty else { return }
        let columns = max(gridWidths.count, cells.map { $0.column + $0.columnSpan }.max() ?? 1)
        var model = TableModel(rows: rowIndex, columns: columns, cells: cells,
                               columnWidths: gridWidths.count == columns && gridWidths.allSatisfy({ $0 > 0 }) ? gridWidths : nil)
        let borders = properties?.child("tblBorders")
        let firstCellBorders = rows.first?.child("tc")?.child("tcPr")?.child("tcBorders")
        if let edge = borders?.child("insideH") ?? borders?.child("top") ?? firstCellBorders?.child("top") {
            let value = edge.attr("val") ?? "single"
            model.borderWidth = ["nil", "none"].contains(value) ? 0 : max(0.25, (edge.attr("sz").flatMap(Double.init) ?? 4) / 8)
            model.borderColor = edge.attr("color").flatMap { $0.lowercased() == "auto" ? nil : NSColor(hex: $0) } ?? .black
        } else {
            let style = properties?.child("tblStyle")?.attr("val") ?? ""
            model.borderWidth = style.lowercased().contains("grid") ? 0.5 : 0
        }
        if let left = properties?.child("tblCellMar")?.child("left") ?? properties?.child("tblCellMar")?.child("start"),
           let value = DocxParagraphProperties.points(left.attr("w")) {
            model.padding = value
        }
        let tableAttributes = NamedStyle.normal.attributes()
        output.append(model.attributedString(attributes: tableAttributes))
    }

    mutating func readSection(_ node: XNode) {
        headerID = node.children("headerReference").first { ($0.attr("type") ?? "default") == "default" }?.attr("id")
        footerID = node.children("footerReference").first { ($0.attr("type") ?? "default") == "default" }?.attr("id")
        var setup = pageSetup
        if let size = node.child("pgSz"),
           let width = DocxParagraphProperties.points(size.attr("w")), let height = DocxParagraphProperties.points(size.attr("h")),
           width > 72, height > 72 {
            setup = .from(pageSize: CGSize(width: width, height: height), margins: setup.margins)
        }
        if let margins = node.child("pgMar") {
            func value(_ key: String, _ fallback: CGFloat) -> CGFloat {
                max(0, DocxParagraphProperties.points(margins.attr(key)).map(abs) ?? fallback)
            }
            setup.margins = PageMargins(top: value("top", 72), left: value("left", 72), bottom: value("bottom", 72), right: value("right", 72))
            setup.headerDistance = value("header", 36)
            setup.footerDistance = value("footer", 36)
        }
        setup.differentFirstPage = node.child("titlePg")?.isOn ?? false
        pageSetup = setup
    }

    // MARK: Paragraphs

    mutating func paragraph(_ node: XNode) {
        let direct = DocxParagraphProperties(node.child("pPr"))
        var properties = styles.paragraphProperties(styleID: direct.styleID)
        properties.merge(direct)
        let styleID = direct.styleID
        let namedStyle = styles.namedStyle(for: styleID)

        var listItem: ListItem?
        if let numID = properties.numID {
            listItem = numbering.listItem(numID: numID, level: properties.level ?? 0)
        }

        if properties.pageBreakBefore == true { DocumentIO.appendPageBreak(to: output) }

        let paragraphStyle = properties.paragraphStyle().mutableCopy() as! NSMutableParagraphStyle
        if let listItem {
            paragraphStyle.headIndent = listItem.textIndent
            paragraphStyle.firstLineHeadIndent = listItem.textIndent
        }
        var paragraphAttributes: [NSAttributedString.Key: Any] = [
            .paragraphStyle: paragraphStyle.copy() as! NSParagraphStyle,
            .pdNamedStyle: namedStyle.rawValue,
        ]
        paragraphAttributes[.pdListItem] = listItem

        let start = output.length
        inline(node, paragraphStyleID: styleID, paragraphAttributes: paragraphAttributes, link: nil)

        // Paragraph mark carries the formatting used for an empty paragraph.
        let markRun = DocxRunProperties(node.child("pPr")?.child("rPr"))
        let markProperties = styles.runProperties(paragraphStyleID: styleID, characterStyleID: nil).merged(markRun)
        var markAttributes = characterAttributes(markProperties)
        if output.length > start {
            // Prefer the last run's look so the newline matches the text before it.
            let last = output.attributes(at: output.length - 1, effectiveRange: nil)
            markAttributes[.font] = last[.font] ?? markAttributes[.font]
            markAttributes[.pdRequestedFont] = last[.pdRequestedFont]
        }
        markAttributes.merge(paragraphAttributes) { _, new in new }
        markAttributes[.link] = nil
        // Comments still open run on into the next paragraph, so the mark belongs to them too.
        markAttributes[.pdComments] = CommentAnchors.value(openComments)
        // A paragraph break that was inserted or deleted as a suggestion.
        if let markRevision = node.child("pPr")?.child("rPr")?.children.first(where: { ["ins", "del", "moveTo", "moveFrom"].contains($0.name) }) {
            let mark = revisionMark(markRevision)
            markAttributes[.pdSuggestion] = mark
            output.append(NSAttributedString(string: "\n", attributes: markAttributes))
            lastRevision = (mark, output.length)
            return
        }
        output.append(NSAttributedString(string: "\n", attributes: markAttributes))
    }

    mutating func inline(_ node: XNode, paragraphStyleID: String?, paragraphAttributes: [NSAttributedString.Key: Any], link: String?) {
        for child in node.children {
            switch child.name {
            case "r":
                run(child, paragraphStyleID: paragraphStyleID, paragraphAttributes: paragraphAttributes, link: link)
            case "hyperlink":
                var target = link
                if let id = child.attr("id"), let relationship = relationships[id] {
                    target = relationship.target
                } else if let anchor = child.attr("anchor") {
                    target = "#" + anchor
                }
                inline(child, paragraphStyleID: paragraphStyleID, paragraphAttributes: paragraphAttributes, link: target)
            case "fldSimple":
                let instruction = child.attr("instr") ?? ""
                if let kind = Reader.pageField(instruction) {
                    let properties = styles.runProperties(paragraphStyleID: paragraphStyleID, characterStyleID: nil)
                        .merged(DocxRunProperties(child.firstDescendant("rPr")))
                    var attributes = characterAttributes(properties)
                    attributes.merge(paragraphAttributes) { _, new in new }
                    attributes[.attachment] = PageFieldAttachment(kind: kind)
                    output.append(NSAttributedString(string: "\u{FFFC}", attributes: attributes))
                    continue
                }
                let fieldLink = Reader.hyperlinkTarget(instruction)
                if fieldLink == nil { warnings.insert(.fields) }
                inline(child, paragraphStyleID: paragraphStyleID, paragraphAttributes: paragraphAttributes, link: fieldLink ?? link)
            case "smartTag", "customXml", "dir", "bdo":
                inline(child, paragraphStyleID: paragraphStyleID, paragraphAttributes: paragraphAttributes, link: link)
            case "ins", "moveTo", "del", "moveFrom":
                withRevision(child) { reader in
                    reader.inline(child, paragraphStyleID: paragraphStyleID, paragraphAttributes: paragraphAttributes, link: link)
                }
            case "sdt":
                if let content = child.child("sdtContent") {
                    inline(content, paragraphStyleID: paragraphStyleID, paragraphAttributes: paragraphAttributes, link: link)
                }
            case "AlternateContent":
                if let fallback = child.child("Fallback") ?? child.child("Choice") {
                    inline(fallback, paragraphStyleID: paragraphStyleID, paragraphAttributes: paragraphAttributes, link: link)
                }
            case "commentRangeStart", "commentRangeEnd":
                commentMarker(child)
            case "oMath", "oMathPara":
                warnings.insert(.equations)
            default:
                break
            }
        }
    }

    static func pageField(_ instruction: String) -> PageFieldAttachment.Kind? {
        let word = instruction.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map { $0.uppercased() }
        switch word {
        case "PAGE": return .pageNumber
        case "NUMPAGES", "SECTIONPAGES": return .pageCount
        default: return nil
        }
    }

    static func hyperlinkTarget(_ instruction: String) -> String? {
        let trimmed = instruction.trimmingCharacters(in: .whitespaces)
        guard trimmed.uppercased().hasPrefix("HYPERLINK") else { return nil }
        if let open = trimmed.firstIndex(of: "\""), let close = trimmed[trimmed.index(after: open)...].firstIndex(of: "\"") {
            return String(trimmed[trimmed.index(after: open)..<close])
        }
        let parts = trimmed.split(separator: " ")
        return parts.count > 1 ? String(parts[1]) : nil
    }

    mutating func run(_ node: XNode, paragraphStyleID: String?, paragraphAttributes: [NSAttributedString.Key: Any], link: String?) {
        let directNode = node.child("rPr")
        let characterStyle = directNode?.child("rStyle")?.attr("val")
        let properties = styles.runProperties(paragraphStyleID: paragraphStyleID, characterStyleID: characterStyle)
            .merged(DocxRunProperties(directNode))
        if properties.hidden == true { return }

        var text = ""
        var pieces: [NSAttributedString] = []
        var attributes = characterAttributes(properties)
        attributes.merge(paragraphAttributes) { _, new in new }
        if let target = fields.last(where: { $0.link != nil })?.link ?? link {
            attributes[.link] = URL(string: target) ?? target
        }
        if let comments = CommentAnchors.value(openComments) { attributes[.pdComments] = comments }
        attributes[.pdSuggestion] = revision
        func flushText() {
            guard !text.isEmpty else { return }
            pieces.append(NSAttributedString(string: text, attributes: attributes))
            text = ""
        }
        for child in node.children {
            switch child.name {
            case "t":
                if fields.last.map({ $0.inResult && $0.page == nil }) ?? true { text += child.text }
            case "delText":
                if revision?.kind == .deletion, fields.last.map({ $0.inResult && $0.page == nil }) ?? true { text += child.text }
            case "tab": text += "\t"
            case "br":
                switch child.attr("type") {
                case "page": text += "\u{0C}"
                case "column": text += "\u{2028}"
                default: text += "\u{2028}"
                }
            case "cr": text += "\u{2028}"
            case "noBreakHyphen": text += "\u{2011}"
            case "softHyphen": text += "\u{00AD}"
            case "sym":
                if let code = child.attr("char").flatMap({ UInt32($0, radix: 16) }) {
                    // Symbol-font codes live in the private use area; show a bullet for the common one.
                    let value = code >= 0xF000 ? code - 0xF000 : code
                    text += value == 0xB7 ? "•" : (UnicodeScalar(value).map { String(Character($0)) } ?? "")
                }
            case "drawing", "pict", "object":
                if let attachment = image(in: child) {
                    flushText()
                    var imageAttributes = attributes
                    imageAttributes[.attachment] = attachment
                    pieces.append(NSAttributedString(string: "\u{FFFC}", attributes: imageAttributes))
                } else {
                    warnings.insert(child.firstDescendant("txbxContent") != nil ? .textBoxes : .images)
                }
            case "fldChar":
                switch child.attr("fldCharType") {
                case "begin": fields.append(Field())
                case "separate":
                    if !fields.isEmpty {
                        fields[fields.count - 1].inResult = true
                        let instruction = fields[fields.count - 1].instruction
                        if let kind = Reader.pageField(instruction) {
                            fields[fields.count - 1].page = kind
                        } else {
                            let target = Reader.hyperlinkTarget(instruction)
                            fields[fields.count - 1].link = target
                            if target == nil { warnings.insert(.fields) }
                        }
                    }
                case "end":
                    if let field = fields.popLast(), let kind = field.page {
                        flushText()
                        var fieldAttributes = attributes
                        fieldAttributes[.attachment] = PageFieldAttachment(kind: kind)
                        fieldAttributes[.link] = nil
                        pieces.append(NSAttributedString(string: "\u{FFFC}", attributes: fieldAttributes))
                    }
                default: break
                }
            case "instrText":
                if !fields.isEmpty, !fields[fields.count - 1].inResult { fields[fields.count - 1].instruction += child.text }
            case "footnoteReference", "endnoteReference":
                warnings.insert(.footnotes)
            case "commentReference":
                anchorPointComment(child)
            default:
                break
            }
        }
        flushText()
        guard !pieces.isEmpty else { return }
        if !fields.isEmpty, !fields.allSatisfy({ $0.inResult }) { return }
        let start = output.length
        for piece in pieces { output.append(piece) }
        guard output.length > start else { return }
        anchoredThreads.formUnion(openComments)
        for id in pendingAnchors {
            CommentAnchors.add(id, to: output, range: NSRange(location: start, length: 1))
            anchoredThreads.insert(id)
        }
        pendingAnchors = []
    }

    /// A comment with no text range is attached to the character before its reference (or the next one).
    mutating func anchorPointComment(_ node: XNode) {
        guard let id = node.attr("id"), let threadID = commentThreadIDs[id], !replyCommentIDs.contains(id),
              !anchoredThreads.contains(threadID), !openComments.contains(threadID) else { return }
        let string = output.string as NSString
        if string.length > 0, !DocxWriter.isParagraphSeparator(string.character(at: string.length - 1)) {
            CommentAnchors.add(threadID, to: output, range: NSRange(location: string.length - 1, length: 1))
            anchoredThreads.insert(threadID)
        } else if !pendingAnchors.contains(threadID) {
            pendingAnchors.append(threadID)
        }
    }

    /// An inline or floating picture (DrawingML or VML) as an image attachment; floating pictures become inline.
    func image(in node: XNode) -> NSTextAttachment? {
        var relationshipID = node.firstDescendant("blip")?.attr("embed")
        var size: CGSize?
        if let extent = node.firstDescendant("extent"), let cx = extent.attr("cx").flatMap(Double.init), let cy = extent.attr("cy").flatMap(Double.init) {
            size = CGSize(width: CGFloat(cx) / DocxWriter.emuPerPoint, height: CGFloat(cy) / DocxWriter.emuPerPoint)
        }
        if relationshipID == nil, let imageData = node.firstDescendant("imagedata") {
            relationshipID = imageData.attr("id")
            if let style = node.firstDescendant("shape")?.attr("style") {
                let declarations = CSSRules.declarations(style)
                if let width = Lengths.points(declarations["width"]), let height = Lengths.points(declarations["height"]) {
                    size = CGSize(width: width, height: height)
                }
            }
        }
        guard let relationshipID, let relationship = relationships[relationshipID], !relationship.external else { return nil }
        let path = Reader.resolve(relationship.target, base: documentFolder)
        guard let data = try? zip.read(path) else { return nil }
        return ImageAttachments.make(data: data, size: size)
    }

    func characterAttributes(_ properties: DocxRunProperties) -> [NSAttributedString.Key: Any] {
        var family = properties.fontFamily
        if family == nil, let theme = properties.themeFont {
            family = theme.lowercased().hasPrefix("major") ? majorFont : minorFont
        }
        let spec = FontSpec(family: family ?? minorFont, size: properties.size ?? 11,
                            bold: properties.bold ?? false, italic: properties.italic ?? false)
        var attributes: [NSAttributedString.Key: Any] = [:]
        if let baseline = properties.baseline, baseline != 0 { attributes[.superscript] = baseline }
        FontResolver.apply(spec, to: &attributes)
        if let color = properties.color, color.lowercased() != "auto", let value = NSColor(hex: color) {
            attributes[.foregroundColor] = value
        } else {
            attributes[.foregroundColor] = NSColor.black
        }
        if let underline = properties.underline, underline != 0 { attributes[.underlineStyle] = underline }
        if properties.strike == true { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let highlight = properties.highlight, !highlight.isEmpty, let color = NSColor(hex: highlight) {
            attributes[.backgroundColor] = color
        }
        return attributes
    }
}
