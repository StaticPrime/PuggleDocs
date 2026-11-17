import AppKit

/// Reads OpenDocument Text (.odt).
public enum OdtReader {
    public static func read(_ data: Data) throws -> DocumentContent {
        let zip: ZipReader
        do {
            zip = try ZipReader(data: data)
        } catch {
            throw DocumentIOError.unreadable("It is not a valid OpenDocument file.")
        }
        guard let contentData = try zip.read("content.xml") else {
            throw DocumentIOError.unreadable("It does not contain any document content.")
        }
        let content: XMLDocument
        do {
            content = try XMLDocument(data: contentData, options: [])
        } catch {
            throw DocumentIOError.unreadable("Its content is not valid XML.")
        }
        let styles = try (zip.read("styles.xml")).flatMap { try? XMLDocument(data: $0, options: []) }
        var reader = OdtDocumentReader(content: content, styles: styles, zip: zip)
        return reader.run()
    }
}

struct OdfTextProperties {
    var family: String?
    var size: CGFloat?
    var sizeFactor: CGFloat?
    var bold: Bool?
    var italic: Bool?
    var underline: Int?
    var strike: Bool?
    var color: String?
    var background: String?
    var clearsBackground = false
    var baseline: Int?

    init() {}

    init(_ element: XMLElement?, fonts: [String: String]) {
        guard let element else { return }
        if let name = element.value("font-name") { family = fonts[name] ?? name }
        if let fontFamily = element.value("font-family") { family = OdfTextProperties.cleanFamily(fontFamily) }
        if let size = element.value("font-size") {
            if let factor = Lengths.percentage(size) { sizeFactor = factor } else { self.size = Lengths.points(size) }
        }
        if let weight = element.value("font-weight") { bold = weight == "bold" || (Int(weight) ?? 400) >= 600 }
        if let style = element.value("font-style") { italic = style == "italic" || style == "oblique" }
        if let style = element.value("text-underline-style") {
            underline = style == "none" ? 0 : (element.value("text-underline-type") == "double" ? NSUnderlineStyle.double.rawValue : NSUnderlineStyle.single.rawValue)
        }
        if let style = element.value("text-line-through-style") { strike = style != "none" }
        if let color = element.value("color") { self.color = Lengths.hexColor(color) }
        if let background = element.value("background-color") {
            self.background = Lengths.hexColor(background)
            clearsBackground = self.background == nil
        }
        if let position = element.value("text-position")?.lowercased() {
            let first = position.split(separator: " ").first.map(String.init) ?? ""
            if first == "super" { baseline = 1 } else if first == "sub" { baseline = -1 } else if let value = Lengths.percentage(first) {
                baseline = value > 0 ? 1 : (value < 0 ? -1 : 0)
            }
        }
    }

    static func cleanFamily(_ value: String) -> String {
        let first = value.split(separator: ",").first.map(String.init) ?? value
        return first.trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
    }

    mutating func merge(_ other: OdfTextProperties) {
        if let value = other.family { family = value }
        if let value = other.size { size = value }
        if let factor = other.sizeFactor { size = (size ?? 12) * factor }
        if let value = other.bold { bold = value }
        if let value = other.italic { italic = value }
        if let value = other.underline { underline = value }
        if let value = other.strike { strike = value }
        if let value = other.color { color = value }
        if let value = other.background { background = value }
        if other.clearsBackground { background = nil }
        if let value = other.baseline { baseline = value }
    }

    func merged(_ other: OdfTextProperties) -> OdfTextProperties {
        var copy = self
        copy.merge(other)
        return copy
    }

    var cacheKey: String {
        "\(family ?? "")|\(size ?? 0)|\(bold ?? false)|\(italic ?? false)|\(underline ?? 0)|\(strike ?? false)|\(color ?? "")|\(background ?? "")|\(baseline ?? 0)"
    }
}

struct OdfParagraphProperties {
    var alignment: NSTextAlignment?
    var marginLeft: CGFloat?
    var marginRight: CGFloat?
    var textIndent: CGFloat?
    var marginTop: CGFloat?
    var marginBottom: CGFloat?
    var lineSpacing: DocxLineSpacing?
    var breakBefore = false
    var breakAfter = false

    init() {}

    init(_ element: XMLElement?) {
        guard let element else { return }
        switch element.value("text-align") {
        case "center": alignment = .center
        case "end", "right": alignment = .right
        case "justify": alignment = .justified
        case "start", "left": alignment = .left
        default: break
        }
        marginLeft = Lengths.points(element.value("margin-left"))
        marginRight = Lengths.points(element.value("margin-right"))
        textIndent = Lengths.points(element.value("text-indent"))
        marginTop = Lengths.points(element.value("margin-top"))
        marginBottom = Lengths.points(element.value("margin-bottom"))
        if let height = element.value("line-height") {
            if height == "normal" {
                lineSpacing = .multiple(1)
            } else if let factor = Lengths.percentage(height) {
                lineSpacing = .multiple(factor)
            } else if let points = Lengths.points(height) {
                lineSpacing = .exact(points)
            }
        }
        if let atLeast = Lengths.points(element.value("line-height-at-least")) { lineSpacing = .atLeast(atLeast) }
        breakBefore = element.value("break-before") == "page"
        breakAfter = element.value("break-after") == "page"
    }

    mutating func merge(_ other: OdfParagraphProperties) {
        if let value = other.alignment { alignment = value }
        if let value = other.marginLeft { marginLeft = value }
        if let value = other.marginRight { marginRight = value }
        if let value = other.textIndent { textIndent = value }
        if let value = other.marginTop { marginTop = value }
        if let value = other.marginBottom { marginBottom = value }
        if let value = other.lineSpacing { lineSpacing = value }
        breakBefore = other.breakBefore
        breakAfter = other.breakAfter
    }

    func paragraphStyle() -> NSParagraphStyle {
        let style = DocumentDefaults.paragraphStyle()
        style.alignment = alignment ?? .natural
        style.paragraphSpacingBefore = max(0, marginTop ?? 0)
        style.paragraphSpacing = max(0, marginBottom ?? 0)
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
        let left = max(0, marginLeft ?? 0)
        style.headIndent = left
        style.firstLineHeadIndent = max(0, left + (textIndent ?? 0))
        if let right = marginRight, right > 0 { style.tailIndent = -right }
        return style.copy() as! NSParagraphStyle
    }
}

struct OdfStyle {
    let name: String
    let family: String
    let parent: String?
    let displayName: String?
    let paragraph: OdfParagraphProperties
    let text: OdfTextProperties
    var columnWidth: CGFloat?
    var cellBackground: String?
    var cellBorder: (width: CGFloat, color: String?)?
    var cellPadding: CGFloat?
}

struct OdfListLevel {
    var isBullet = true
    var bulletChar = "●"
    var numFormat = "1"
    var suffix = "."
    var displayLevels = 1
}

private struct OdtDocumentReader {
    let content: XMLDocument
    let styles: XMLDocument?
    let zip: ZipReader?
    var fonts: [String: String] = [:]
    var styleTable: [String: OdfStyle] = [:]
    var defaultParagraph = OdfParagraphProperties()
    var defaultText = OdfTextProperties()
    var listStyles: [String: [Int: OdfListLevel]] = [:]
    var output = NSMutableAttributedString()
    var warnings: Set<ImportWarning> = []
    var pageSetup = PageSetup.localeDefault
    var listCounter = 0
    var listIDsByXMLID: [String: String] = [:]
    var lastTopLevelListID: String?
    var attributeCache: [String: [NSAttributedString.Key: Any]] = [:]
    var threads: [CommentThread] = []
    /// `office:name` → thread id, for range ends and replies.
    var annotationThreads: [String: String] = [:]
    var openComments: [String] = []
    var anchoredThreads = Set<String>()
    var pendingAnchors: [String] = []
    /// Tracked changes by region id, the suggestion marks made for them, insertions still open,
    /// and the deletion whose text is being read back into place.
    var regions: [String: (kind: SuggestionMark.Kind, author: String, date: Date, element: XMLElement)] = [:]
    var regionMarks: [String: SuggestionMark] = [:]
    var openInsertions: [String] = []
    var deletionMark: SuggestionMark?
    var lastRevision: (mark: SuggestionMark, end: Int)?

    struct ListContext {
        let listID: String
        let styleName: String?
        let level: Int
    }

    struct InlineState {
        var pendingSpace = false
        var hasContent = false
    }

    init(content: XMLDocument, styles: XMLDocument?, zip: ZipReader? = nil) {
        self.content = content
        self.styles = styles
        self.zip = zip
    }

    mutating func run() -> DocumentContent {
        for document in [styles, content].compactMap({ $0 }) {
            guard let root = document.rootElement() else { continue }
            if let declarations = root.firstChild("font-face-decls") {
                for face in declarations.childElements("font-face") {
                    guard let name = face.value("name") else { continue }
                    fonts[name] = OdfTextProperties.cleanFamily(face.value("font-family") ?? name)
                }
            }
        }
        for document in [styles, content].compactMap({ $0 }) {
            guard let root = document.rootElement() else { continue }
            for container in ["styles", "automatic-styles"] {
                guard let section = root.firstChild(container) else { continue }
                readStyles(section)
            }
        }
        readPageSetup()
        let masterPage = styles?.rootElement()?.firstChild("master-styles")?.childElements("master-page").first
        let header = masterPage?.firstChild("header").map { headerFooter($0) } ?? nil
        let footer = masterPage?.firstChild("footer").map { headerFooter($0) } ?? nil
        if masterPage?.firstChild("header-first") != nil || masterPage?.firstChild("footer-first") != nil {
            pageSetup.differentFirstPage = true
        }
        if let text = content.rootElement()?.firstChild("body")?.firstChild("text") {
            if let changes = text.firstChild("tracked-changes") { readTrackedChanges(changes) }
            for child in text.elementChildren { block(child, list: nil, continuation: false) }
        }
        DocumentIO.trimFinalNewline(output)
        DocumentIO.normalizeImported(output)
        CommentAnchors.normalize(output, threads: threads)
        return DocumentContent(text: output, pageSetup: pageSetup, warnings: warnings, header: header, footer: footer, comments: threads)
    }

    /// A comment, a reply (LibreOffice's `loext:parent-name`) or a point comment.
    mutating func annotation(_ element: XMLElement) {
        let author = element.firstChild("creator")?.stringValue ?? "Unknown"
        let rawDate = element.firstChild("date")?.stringValue ?? ""
        let formatter = ISO8601DateFormatter()
        let date = formatter.date(from: rawDate) ?? formatter.date(from: String(rawDate.prefix(19)) + "Z") ?? Date()
        let text = element.childElements("p").map { $0.stringValue ?? "" }.joined(separator: "\n")
        if let parent = element.value("parent-name"), let threadID = annotationThreads[parent],
           let index = threads.firstIndex(where: { $0.id == threadID }) {
            threads[index].replies.append(CommentReply(author: author, date: date, text: text))
            return
        }
        let thread = CommentThread(author: author, date: date, text: text, resolved: element.value("resolved") == "true")
        threads.append(thread)
        if let name = element.value("name") {
            annotationThreads[name] = thread.id
            openComments.append(thread.id)
            return
        }
        // No range: attach to the character before, or the next one at the start of a paragraph.
        let string = output.string as NSString
        if string.length > 0, !DocxWriter.isParagraphSeparator(string.character(at: string.length - 1)) {
            CommentAnchors.add(thread.id, to: output, range: NSRange(location: string.length - 1, length: 1))
            anchoredThreads.insert(thread.id)
        } else {
            pendingAnchors.append(thread.id)
        }
    }

    mutating func readTrackedChanges(_ element: XMLElement) {
        for region in element.childElements("changed-region") {
            guard let id = region.value("id"),
                  let change = region.elementChildren.first(where: { $0.localName == "insertion" || $0.localName == "deletion" }) else { continue }
            let info = change.firstChild("change-info")
            let date = Suggestions.date(info?.firstChild("date")?.stringValue) ?? Date(timeIntervalSince1970: 0)
            regions[id] = (change.localName == "insertion" ? .insertion : .deletion, info?.firstChild("creator")?.stringValue ?? "Unknown", date, change)
        }
    }

    /// The suggestion for a tracked change. Touching changes by the same person at the same moment
    /// are one suggestion (a replacement is a deletion and an insertion).
    mutating func suggestionMark(forRegion id: String) -> SuggestionMark? {
        if let mark = regionMarks[id] { return mark }
        guard let region = regions[id] else { return nil }
        var mark = SuggestionMark(kind: region.kind, author: region.author, date: region.date)
        if let previous = Suggestions.continues(lastRevision, at: output.length, author: region.author, date: region.date) {
            mark = SuggestionMark(id: previous.id, kind: region.kind, author: region.author, date: previous.date)
        }
        regionMarks[id] = mark
        return mark
    }

    var currentSuggestion: SuggestionMark? { deletionMark ?? openInsertions.last.flatMap { regionMarks[$0] } }

    /// Appends text, tagging it with the comments open at this point.
    mutating func appendTagged(_ string: NSAttributedString) {
        guard string.length > 0 else { return }
        let start = output.length
        output.append(string)
        if let suggestion = currentSuggestion {
            output.addAttribute(.pdSuggestion, value: suggestion, range: NSRange(location: start, length: string.length))
        }
        if let value = CommentAnchors.value(openComments) {
            output.addAttribute(.pdComments, value: value, range: NSRange(location: start, length: string.length))
            anchoredThreads.formUnion(openComments)
        }
        for id in pendingAnchors { CommentAnchors.add(id, to: output, range: NSRange(location: start, length: 1)) }
        anchoredThreads.formUnion(pendingAnchors)
        pendingAnchors = []
    }

    mutating func headerFooter(_ element: XMLElement) -> NSAttributedString? {
        let body = output
        output = NSMutableAttributedString()
        defer { output = body }
        for child in element.elementChildren { block(child, list: nil, continuation: false) }
        DocumentIO.trimFinalNewline(output)
        guard output.length > 0 else { return nil }
        DocumentIO.normalizeImported(output)
        return NSAttributedString(attributedString: output)
    }

    // MARK: Styles

    mutating func readStyles(_ section: XMLElement) {
        for element in section.elementChildren {
            switch element.localName {
            case "default-style" where element.value("family") == "paragraph":
                defaultParagraph = OdfParagraphProperties(element.firstChild("paragraph-properties"))
                defaultText = OdfTextProperties(element.firstChild("text-properties"), fonts: fonts)
            case "style":
                guard let name = element.value("name") else { continue }
                var style = OdfStyle(name: name, family: element.value("family") ?? "paragraph", parent: element.value("parent-style-name"),
                                     displayName: element.value("display-name"),
                                     paragraph: OdfParagraphProperties(element.firstChild("paragraph-properties")),
                                     text: OdfTextProperties(element.firstChild("text-properties"), fonts: fonts))
                if let column = element.firstChild("table-column-properties") {
                    style.columnWidth = Lengths.points(column.value("column-width"))
                }
                if let cell = element.firstChild("table-cell-properties") {
                    style.cellBackground = Lengths.hexColor(cell.value("background-color"))
                    if let border = cell.value("border") ?? cell.value("border-top") {
                        let parts = border.split(separator: " ").map(String.init)
                        let width = parts.compactMap { Lengths.points($0) }.first ?? 0
                        style.cellBorder = (parts.contains("none") ? 0 : width, parts.first { $0.hasPrefix("#") }.flatMap { Lengths.hexColor($0) })
                    }
                    style.cellPadding = Lengths.points(cell.value("padding") ?? cell.value("padding-left"))
                }
                styleTable[name] = style
            case "list-style":
                guard let name = element.value("name") else { continue }
                var levels: [Int: OdfListLevel] = [:]
                for levelElement in element.elementChildren {
                    guard let level = levelElement.value("level").flatMap(Int.init) else { continue }
                    var info = OdfListLevel()
                    if levelElement.localName == "list-level-style-number" {
                        info.isBullet = false
                        info.numFormat = levelElement.value("num-format") ?? "1"
                        info.suffix = levelElement.value("num-suffix") ?? ""
                        info.displayLevels = levelElement.value("display-levels").flatMap(Int.init) ?? 1
                    } else {
                        info.bulletChar = levelElement.value("bullet-char") ?? "●"
                    }
                    levels[level - 1] = info
                }
                listStyles[name] = levels
            default:
                break
            }
        }
    }

    func chain(_ name: String?) -> [OdfStyle] {
        var result: [OdfStyle] = []
        var current = name
        var seen = Set<String>()
        while let key = current, let style = styleTable[key], !seen.contains(key) {
            seen.insert(key)
            result.insert(style, at: 0)
            current = style.parent
        }
        return result
    }

    func namedStyle(for styleName: String?, outlineLevel: Int?) -> NamedStyle {
        for style in chain(styleName).reversed() {
            for candidate in [style.displayName, style.name].compactMap({ $0 }) {
                let readable = candidate.replacingOccurrences(of: "_20_", with: " ")
                if let match = NamedStyle.matching(styleName: readable) { return match }
            }
        }
        if let level = outlineLevel, (1...6).contains(level) {
            return NamedStyle.allCases.first { $0.headingLevel == level } ?? .normal
        }
        return .normal
    }

    mutating func readPageSetup() {
        guard let root = styles?.rootElement() else { return }
        let masterPage = root.firstChild("master-styles")?.childElements("master-page").first
        let layoutName = masterPage?.value("page-layout-name")
        var layouts: [XMLElement] = []
        for section in ["automatic-styles", "styles"] {
            layouts += root.firstChild(section)?.childElements("page-layout") ?? []
        }
        guard let layout = layouts.first(where: { $0.value("name") == layoutName }) ?? layouts.first,
              let properties = layout.firstChild("page-layout-properties") else { return }
        var setup = pageSetup
        if let width = Lengths.points(properties.value("page-width")), let height = Lengths.points(properties.value("page-height")),
           width > 72, height > 72 {
            setup = .from(pageSize: CGSize(width: width, height: height), margins: setup.margins)
        }
        func margin(_ key: String) -> CGFloat { max(0, Lengths.points(properties.value(key)) ?? 72) }
        setup.margins = PageMargins(top: margin("margin-top"), left: margin("margin-left"), bottom: margin("margin-bottom"), right: margin("margin-right"))
        if let color = Lengths.hexColor(properties.value("background-color")), color != "FFFFFF" { setup.pageColorHex = color }
        pageSetup = setup
    }

    // MARK: Blocks

    mutating func block(_ element: XMLElement, list: ListContext?, continuation: Bool) {
        switch element.localName {
        case "p", "h":
            paragraph(element, list: list, continuation: continuation)
        case "list":
            readList(element, parent: list)
        case "section", "index-body", "deletion":
            if element.localName == "deletion" { return }
            element.elementChildren.forEach { block($0, list: list, continuation: continuation) }
        case "table-of-content", "alphabetical-index", "illustration-index", "table-index", "object-index", "user-index", "bibliography":
            element.firstChild("index-body")?.elementChildren.forEach { block($0, list: list, continuation: continuation) }
        case "table":
            readTable(element)
        case "tracked-changes":
            break // Read up front.
        case "frame", "custom-shape", "rect", "line", "ellipse", "g":
            warnings.insert(element.firstDescendant("text-box") != nil ? .textBoxes : .images)
        default:
            break
        }
    }

    func tableColumns(_ element: XMLElement) -> [XMLElement] {
        var columns: [XMLElement] = []
        for child in element.elementChildren {
            switch child.localName {
            case "table-column":
                let repeated = max(1, min(child.value("number-columns-repeated").flatMap(Int.init) ?? 1, 64))
                columns += Array(repeating: child, count: repeated)
            case "table-columns", "table-column-group", "table-header-columns": columns += tableColumns(child)
            default: break
            }
        }
        return columns
    }

    /// Reads a table into a text table.
    mutating func readTable(_ element: XMLElement) {
        let columnElements = tableColumns(element)
        let widths = columnElements.map { column in column.value("style-name").flatMap { styleTable[$0]?.columnWidth } ?? 0 }
        var cells: [TableModel.Cell] = []
        var occupied = Set<[Int]>()
        var border: (width: CGFloat, color: String?)?
        var padding: CGFloat?
        let rows = tableRows(element)
        for (rowIndex, row) in rows.enumerated() {
            var column = 0
            for cellElement in row.elementChildren where cellElement.localName == "table-cell" || cellElement.localName == "covered-table-cell" {
                while occupied.contains([rowIndex, column]) { column += 1 }
                if cellElement.localName == "covered-table-cell" {
                    column += 1
                    continue
                }
                let columnSpan = max(1, cellElement.value("number-columns-spanned").flatMap(Int.init) ?? 1)
                let rowSpan = max(1, cellElement.value("number-rows-spanned").flatMap(Int.init) ?? 1)
                let start = output.length
                for child in cellElement.elementChildren { block(child, list: nil, continuation: false) }
                var range = NSRange(location: start, length: output.length - start)
                let content = NSMutableAttributedString()
                if range.length > 0 {
                    if (output.string as NSString).character(at: NSMaxRange(range) - 1) == 0x0A { range.length -= 1 }
                    content.append(output.attributedSubstring(from: range))
                    output.deleteCharacters(in: NSRange(location: start, length: output.length - start))
                }
                let style = cellElement.value("style-name").flatMap { styleTable[$0] }
                var cell = TableModel.Cell(row: rowIndex, column: column, rowSpan: rowSpan, columnSpan: columnSpan, content: content)
                if let background = style?.cellBackground, background != "FFFFFF" { cell.background = NSColor(hex: background) }
                if border == nil { border = style?.cellBorder }
                if padding == nil { padding = style?.cellPadding }
                cells.append(cell)
                for r in rowIndex..<(rowIndex + rowSpan) { for c in column..<(column + columnSpan) { occupied.insert([r, c]) } }
                column += columnSpan
            }
        }
        guard !cells.isEmpty else { return }
        let columns = max(widths.count, cells.map { $0.column + $0.columnSpan }.max() ?? 1)
        var model = TableModel(rows: rows.count, columns: columns, cells: cells,
                               columnWidths: widths.count == columns && widths.allSatisfy({ $0 > 0 }) ? widths : nil)
        model.borderWidth = border?.width ?? 0.5
        model.borderColor = border?.color.flatMap(NSColor.init(hex:)) ?? .black
        if let padding { model.padding = padding }
        output.append(model.attributedString(attributes: NamedStyle.normal.attributes()))
    }

    func tableRows(_ table: XMLElement) -> [XMLElement] {
        var rows: [XMLElement] = []
        for child in table.elementChildren {
            switch child.localName {
            case "table-row": rows.append(child)
            case "table-header-rows", "table-rows", "table-row-group": rows += tableRows(child)
            default: break
            }
        }
        return rows
    }

    mutating func readList(_ element: XMLElement, parent: ListContext?) {
        let styleName = element.value("style-name") ?? parent?.styleName
        let listID: String
        if let parent {
            listID = parent.listID
        } else {
            if let continued = element.value("continue-list"), let existing = listIDsByXMLID[continued] {
                listID = existing
            } else if element.value("continue-numbering") == "true", let last = lastTopLevelListID {
                listID = last
            } else {
                listCounter += 1
                listID = "odt-list-\(listCounter)"
            }
            if let xmlID = element.value("id") { listIDsByXMLID[xmlID] = listID }
            lastTopLevelListID = listID
        }
        let context = ListContext(listID: listID, styleName: styleName, level: (parent?.level ?? -1) + 1)
        for item in element.elementChildren where item.localName == "list-item" || item.localName == "list-header" {
            var first = item.localName == "list-item"
            for child in item.elementChildren {
                block(child, list: context, continuation: !first)
                if child.localName == "p" || child.localName == "h" { first = false }
            }
        }
    }

    func listItem(for context: ListContext) -> ListItem {
        let levels = context.styleName.flatMap { listStyles[$0] } ?? [:]
        let level = min(context.level, ListItem.maxLevel)
        let first = levels[0] ?? OdfListLevel()
        let preset: ListPreset
        if first.isBullet {
            let glyph = first.bulletChar
            if ["☐", "☑", "☒", "❑"].contains(glyph) { preset = .checkbox }
            else if glyph.contains("❖") { preset = .diamondArrowSquare }
            else if glyph.contains("➔") || glyph.contains("→") { preset = .arrowDiamondDisc }
            else if glyph.contains("★") { preset = .starCircleSquare }
            else if glyph.contains("❏") { preset = .boxArrowSquare }
            else if glyph == "–" || glyph == "-" { preset = .dashCircleSquare }
            else { preset = .discCircleSquare }
        } else {
            switch first.numFormat {
            case "A": preset = levels[1].map { !$0.isBullet && $0.numFormat == "1" } == true ? .upperAlphaDecimal : .upperAlphaLowerAlpha
            case "I": preset = .upperRomanUpperAlpha
            default:
                if first.suffix.contains(")") { preset = .decimalParen }
                else if (levels[1]?.displayLevels ?? 1) > 1 { preset = .decimalOutline }
                else { preset = .decimalAlphaRoman }
            }
        }
        let glyph = levels[level]?.bulletChar ?? ""
        let checked = preset == .checkbox && ["☑", "☒", "✓", "✔"].contains(glyph)
        return ListItem(listID: context.listID, preset: preset, level: level, isChecked: checked)
    }

    // MARK: Paragraphs

    mutating func paragraph(_ element: XMLElement, list: ListContext?, continuation: Bool) {
        let styleName = element.value("style-name")
        let styles = chain(styleName)
        var properties = defaultParagraph
        var text = defaultText
        for style in styles {
            properties.merge(style.paragraph)
            text.merge(style.text)
        }
        let outlineLevel = element.localName == "h" ? (element.value("outline-level").flatMap(Int.init) ?? 1) : nil
        let named = namedStyle(for: styleName, outlineLevel: outlineLevel)

        if properties.breakBefore { DocumentIO.appendPageBreak(to: output) }

        let paragraphStyle = properties.paragraphStyle().mutableCopy() as! NSMutableParagraphStyle
        var item: ListItem?
        if let list {
            let indent = ListItem.textIndent(forLevel: min(list.level, ListItem.maxLevel))
            paragraphStyle.headIndent = indent
            paragraphStyle.firstLineHeadIndent = indent
            if !continuation { item = listItem(for: list) }
        }
        var paragraphAttributes: [NSAttributedString.Key: Any] = [
            .paragraphStyle: paragraphStyle.copy() as! NSParagraphStyle,
            .pdNamedStyle: named.rawValue,
        ]
        paragraphAttributes[.pdListItem] = item

        let start = output.length
        var state = InlineState()
        inline(element, text: text, link: nil, state: &state, paragraphAttributes: paragraphAttributes)

        var mark = attributes(for: text)
        if output.length > start {
            let last = output.attributes(at: output.length - 1, effectiveRange: nil)
            mark[.font] = last[.font] ?? mark[.font]
        }
        mark.merge(paragraphAttributes) { _, new in new }
        // Comments and insertions still open run on into the next paragraph, so the mark belongs to them too.
        mark[.pdComments] = CommentAnchors.value(openComments)
        mark[.pdSuggestion] = currentSuggestion
        output.append(NSAttributedString(string: properties.breakAfter ? "\u{0C}\n" : "\n", attributes: mark))
    }

    mutating func inline(_ node: XMLNode, text: OdfTextProperties, link: String?, state: inout InlineState,
                         paragraphAttributes: [NSAttributedString.Key: Any]) {
        for child in node.children ?? [] {
            if child.kind == .text {
                append(collapsing: child.stringValue ?? "", text: text, link: link, state: &state, paragraphAttributes: paragraphAttributes)
                continue
            }
            guard let element = child as? XMLElement else { continue }
            switch element.localName {
            case "span":
                var spanText = text
                for style in chain(element.value("style-name")) { spanText.merge(style.text) }
                inline(element, text: spanText, link: link, state: &state, paragraphAttributes: paragraphAttributes)
            case "a":
                inline(element, text: text, link: element.value("href") ?? link, state: &state, paragraphAttributes: paragraphAttributes)
            case "s":
                let count = max(1, element.value("c").flatMap(Int.init) ?? 1)
                appendLiteral(String(repeating: " ", count: count), text: text, link: link, state: &state, paragraphAttributes: paragraphAttributes)
            case "tab":
                appendLiteral("\t", text: text, link: link, state: &state, paragraphAttributes: paragraphAttributes)
            case "line-break":
                appendLiteral("\u{2028}", text: text, link: link, state: &state, paragraphAttributes: paragraphAttributes)
                state.pendingSpace = false
            case "page-number", "page-count":
                let prefix = state.pendingSpace && state.hasContent ? " " : ""
                state.pendingSpace = false
                state.hasContent = true
                emit(prefix, text: text, link: link, paragraphAttributes: paragraphAttributes)
                var attributes = self.attributes(for: text)
                attributes.merge(paragraphAttributes) { _, new in new }
                attributes[.attachment] = PageFieldAttachment(kind: element.localName == "page-number" ? .pageNumber : .pageCount)
                appendTagged(NSAttributedString(string: "\u{FFFC}", attributes: attributes))
            case "note":
                warnings.insert(.footnotes)
            case "change-start":
                if let id = element.value("change-id"), regions[id]?.kind == .insertion, suggestionMark(forRegion: id) != nil {
                    openInsertions.append(id)
                }
            case "change-end":
                if let id = element.value("change-id"), let mark = regionMarks[id] {
                    openInsertions.removeAll { $0 == id }
                    lastRevision = (mark, output.length)
                }
            case "change":
                // A deletion: its text sits in the tracked changes, so read it back in here, marked.
                guard let id = element.value("change-id"), let region = regions[id], region.kind == .deletion,
                      let mark = suggestionMark(forRegion: id) else { continue }
                let saved = deletionMark
                deletionMark = mark
                let paragraphs = region.element.elementChildren.filter { $0.localName == "p" || $0.localName == "h" }
                for (index, deleted) in paragraphs.enumerated() {
                    if index > 0 {
                        var attributes = self.attributes(for: text)
                        attributes.merge(paragraphAttributes) { _, new in new }
                        appendTagged(NSAttributedString(string: "\n", attributes: attributes))
                    }
                    var deletedText = text
                    for style in chain(deleted.value("style-name")) { deletedText.merge(style.text) }
                    var deletedState = InlineState(pendingSpace: false, hasContent: state.hasContent)
                    inline(deleted, text: deletedText, link: link, state: &deletedState, paragraphAttributes: paragraphAttributes)
                }
                deletionMark = saved
                lastRevision = (mark, output.length)
            case "annotation":
                annotation(element)
            case "annotation-end":
                if let name = element.value("name"), let threadID = annotationThreads[name] { openComments.removeAll { $0 == threadID } }
            case "frame":
                if let attachment = image(in: element) {
                    let prefix = state.pendingSpace && state.hasContent ? " " : ""
                    state.pendingSpace = false
                    state.hasContent = true
                    emit(prefix, text: text, link: link, paragraphAttributes: paragraphAttributes)
                    var attributes = self.attributes(for: text)
                    attributes.merge(paragraphAttributes) { _, new in new }
                    attributes[.attachment] = attachment
                    appendTagged(NSAttributedString(string: "\u{FFFC}", attributes: attributes))
                } else {
                    warnings.insert(element.firstDescendant("text-box") != nil ? .textBoxes : .images)
                }
            case "custom-shape", "rect", "image", "g":
                warnings.insert(element.firstDescendant("text-box") != nil ? .textBoxes : .images)
            case "ruby-text", "soft-page-break", "bookmark", "bookmark-start", "bookmark-end", "reference-mark", "reference-mark-start",
                 "reference-mark-end", "toc-mark", "toc-mark-start", "toc-mark-end",
                 "alphabetical-index-mark", "alphabetical-index-mark-start", "alphabetical-index-mark-end":
                continue
            default:
                // Fields and other inline wrappers: keep their visible text.
                inline(element, text: text, link: link, state: &state, paragraphAttributes: paragraphAttributes)
            }
        }
    }

    /// The picture inside a draw:frame, sized by the frame.
    func image(in frame: XMLElement) -> NSTextAttachment? {
        guard let href = frame.firstChild("image")?.value("href"), !href.hasPrefix("http"), let zip else { return nil }
        let path = href.hasPrefix("./") ? String(href.dropFirst(2)) : href
        guard let data = try? zip.read(path) else { return nil }
        var size: CGSize?
        if let width = Lengths.points(frame.value("width")), let height = Lengths.points(frame.value("height")) {
            size = CGSize(width: width, height: height)
        }
        return ImageAttachments.make(data: data, size: size)
    }

    /// Appends character data, collapsing whitespace as ODF requires.
    mutating func append(collapsing raw: String, text: OdfTextProperties, link: String?, state: inout InlineState,
                         paragraphAttributes: [NSAttributedString.Key: Any]) {
        var buffer = ""
        for character in raw {
            if character == " " || character == "\t" || character == "\n" || character == "\r" {
                state.pendingSpace = true
            } else {
                if state.pendingSpace && state.hasContent { buffer.append(" ") }
                state.pendingSpace = false
                buffer.append(character)
                state.hasContent = true
            }
        }
        emit(buffer, text: text, link: link, paragraphAttributes: paragraphAttributes)
    }

    mutating func appendLiteral(_ literal: String, text: OdfTextProperties, link: String?, state: inout InlineState,
                                paragraphAttributes: [NSAttributedString.Key: Any]) {
        let prefix = state.pendingSpace && state.hasContent ? " " : ""
        state.pendingSpace = false
        state.hasContent = true
        emit(prefix + literal, text: text, link: link, paragraphAttributes: paragraphAttributes)
    }

    mutating func emit(_ string: String, text: OdfTextProperties, link: String?, paragraphAttributes: [NSAttributedString.Key: Any]) {
        guard !string.isEmpty else { return }
        var attributes = self.attributes(for: text)
        attributes.merge(paragraphAttributes) { _, new in new }
        if let link { attributes[.link] = URL(string: link) ?? link }
        appendTagged(NSAttributedString(string: string, attributes: attributes))
    }

    mutating func attributes(for text: OdfTextProperties) -> [NSAttributedString.Key: Any] {
        if let cached = attributeCache[text.cacheKey] { return cached }
        var attributes: [NSAttributedString.Key: Any] = [:]
        if let baseline = text.baseline, baseline != 0 { attributes[.superscript] = baseline }
        let spec = FontSpec(family: text.family ?? FontResolver.defaultFamily, size: text.size ?? 12,
                            bold: text.bold ?? false, italic: text.italic ?? false)
        FontResolver.apply(spec, to: &attributes)
        attributes[.foregroundColor] = text.color.flatMap(NSColor.init(hex:)) ?? NSColor.black
        if let underline = text.underline, underline != 0 { attributes[.underlineStyle] = underline }
        if text.strike == true { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let background = text.background.flatMap(NSColor.init(hex:)) { attributes[.backgroundColor] = background }
        attributeCache[text.cacheKey] = attributes
        return attributes
    }
}
