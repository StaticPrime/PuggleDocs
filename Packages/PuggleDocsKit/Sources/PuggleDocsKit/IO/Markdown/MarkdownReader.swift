import AppKit

/// Reads Markdown (CommonMark with GitHub tables, strikethrough and task lists) into editor text.
public enum MarkdownReader {
    public static func read(_ data: Data) throws -> DocumentContent {
        var source = String(decoding: data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data, as: UTF8.self)
        source = source.replacingOccurrences(of: "\r\n", with: "\n")
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false, interpretedSyntax: .full,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        let parsed: AttributedString
        do {
            parsed = try AttributedString(markdown: source, options: options)
        } catch {
            throw DocumentIOError.unreadable("The Markdown could not be read.")
        }
        var builder = MarkdownBuilder()
        return builder.build(parsed)
    }
}

private struct MarkdownBuilder {
    var output = NSMutableAttributedString()
    var warnings: Set<ImportWarning> = []
    /// The table being collected: its intent identity, column count and cells by (row, column).
    var table: (identity: Int, columns: Int, cells: [Int: [Int: NSMutableAttributedString]])?

    /// What a block of Markdown is: heading, list item, quote, code or table cell.
    struct Block {
        var heading: Int?
        var isCode = false
        var quoteDepth = 0
        /// Lists from the outermost in: (list identity, ordered).
        var lists: [(identity: Int, ordered: Bool)] = []
        var isThematicBreak = false
        var cell: (table: Int, columns: Int, row: Int, column: Int)?

        init(_ intent: PresentationIntent?) {
            var row = 0
            var column = 0
            for component in intent?.components ?? [] {
                switch component.kind {
                case .header(let level): heading = level
                case .codeBlock: isCode = true
                case .blockQuote: quoteDepth += 1
                case .orderedList: lists.insert((component.identity, true), at: 0)
                case .unorderedList: lists.insert((component.identity, false), at: 0)
                case .thematicBreak: isThematicBreak = true
                case .tableCell(let index): column = index
                case .tableRow(let index): row = index
                case .tableHeaderRow: row = 0
                case .table(let columns): cell = (component.identity, columns.count, row, column)
                default: break
                }
            }
        }
    }

    mutating func build(_ parsed: AttributedString) -> DocumentContent {
        var currentIntent: PresentationIntent?
        var started = false
        var text = NSMutableAttributedString()
        for run in parsed.runs {
            if !started || run.presentationIntent != currentIntent {
                if started { finishBlock(text, intent: currentIntent) }
                started = true
                currentIntent = run.presentationIntent
                text = NSMutableAttributedString()
            }
            text.append(inlineText(parsed, run: run, block: Block(run.presentationIntent)))
        }
        if started { finishBlock(text, intent: currentIntent) }
        flushTable()
        DocumentIO.trimFinalNewline(output)
        DocumentIO.normalizeImported(output)
        return DocumentContent(text: output, warnings: warnings)
    }

    func baseAttributes(for block: Block) -> [NSAttributedString.Key: Any] {
        if let level = block.heading, let style = NamedStyle(rawValue: "heading\(min(max(level, 1), 6))") {
            return style.attributes()
        }
        var attributes = NamedStyle.normal.attributes()
        if block.isCode {
            attributes = CharacterFormatting.apply(CharacterFormatting.setFontFamily("Courier New"), to: attributes)
        }
        return attributes
    }

    mutating func inlineText(_ parsed: AttributedString, run: AttributedString.Runs.Run, block: Block) -> NSAttributedString {
        var string = String(parsed[run.range].characters)
        var attributes = baseAttributes(for: block)
        if let inline = run.inlinePresentationIntent {
            if inline.contains(.stronglyEmphasized) { attributes = CharacterFormatting.apply(CharacterFormatting.setBold(true), to: attributes) }
            if inline.contains(.emphasized) { attributes = CharacterFormatting.apply(CharacterFormatting.setItalic(true), to: attributes) }
            if inline.contains(.strikethrough) { attributes = CharacterFormatting.apply(CharacterFormatting.setStrikethrough(true), to: attributes) }
            if inline.contains(.code) { attributes = CharacterFormatting.apply(CharacterFormatting.setFontFamily("Courier New"), to: attributes) }
            if inline.contains(.softBreak) { string = " " }
            if inline.contains(.lineBreak) { string = "\u{2028}" }
        }
        if let link = run.link { attributes[.link] = link }
        if let url = run.imageURL {
            // Embedded pictures (as PuggleDocs writes them) come back as pictures. Pictures referenced by
            // path or web address can't be fetched here, so their description stands in and the file opens as a copy.
            if let data = Self.dataURLContents(url), let attachment = ImageAttachments.make(data: data, size: nil) {
                attributes[.attachment] = attachment
                attributes[.link] = nil
                return NSAttributedString(string: "\u{FFFC}", attributes: attributes)
            }
            warnings.insert(.images)
            return NSAttributedString(string: string, attributes: attributes)
        }
        return NSAttributedString(string: string, attributes: attributes)
    }

    static func dataURLContents(_ url: URL) -> Data? {
        let string = url.absoluteString
        guard string.hasPrefix("data:"), let comma = string.firstIndex(of: ","), string[..<comma].hasSuffix(";base64") else { return nil }
        return Data(base64Encoded: String(string[string.index(after: comma)...]).removingPercentEncoding ?? "")
    }

    mutating func finishBlock(_ text: NSMutableAttributedString, intent: PresentationIntent?) {
        let block = Block(intent)
        if let cell = block.cell {
            if table?.identity != cell.table {
                flushTable()
                table = (cell.table, cell.columns, [:])
            }
            table?.cells[cell.row, default: [:]][cell.column] = text
            return
        }
        flushTable()
        if block.isThematicBreak { return }
        if block.isCode {
            // One paragraph per line of code.
            var lines = text.string.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            var location = 0
            for line in lines {
                let length = (line as NSString).length
                let piece = NSMutableAttributedString(attributedString: text.attributedSubstring(from: NSRange(location: location, length: length)))
                location += length + 1
                if piece.length == 0 { piece.append(NSAttributedString(string: "", attributes: baseAttributes(for: block))) }
                appendParagraph(piece, block: block, spacing: false)
            }
            return
        }
        appendParagraph(text, block: block, spacing: true)
    }

    mutating func appendParagraph(_ text: NSMutableAttributedString, block: Block, spacing: Bool) {
        var paragraph = baseAttributes(for: block)
        if let innermost = block.lists.last, let outermost = block.lists.first {
            var preset: ListPreset = innermost.ordered ? .decimalAlphaRoman : .discCircleSquare
            var checked = false
            // GitHub task lists: "[ ] " and "[x] " at the start of an item.
            let string = text.string
            if !innermost.ordered, string.hasPrefix("[ ] ") || string.lowercased().hasPrefix("[x] ") {
                preset = .checkbox
                checked = !string.hasPrefix("[ ] ")
                text.deleteCharacters(in: NSRange(location: 0, length: 4))
            }
            let item = ListItem(listID: "md-\(outermost.identity)", preset: preset, level: min(block.lists.count - 1, ListItem.maxLevel), isChecked: checked)
            paragraph = ParagraphFormatting.apply(ParagraphFormatting.setList(item), to: paragraph)
            if checked {
                text.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: text.length))
            }
        } else if block.quoteDepth > 0 {
            let indent = CGFloat(block.quoteDepth) * ListItem.levelIndent
            paragraph = ParagraphFormatting.apply(ParagraphFormatting.setIndents(left: indent, firstLine: indent, right: 0), to: paragraph)
        }
        if !spacing, let style = (paragraph[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
            style.paragraphSpacing = 0
            style.paragraphSpacingBefore = 0
            paragraph[.paragraphStyle] = style.copy()
        }
        let keys = [NSAttributedString.Key.paragraphStyle, .pdNamedStyle, .pdListItem]
        if text.length > 0 {
            for key in keys {
                if let value = paragraph[key] {
                    text.addAttribute(key, value: value, range: NSRange(location: 0, length: text.length))
                } else {
                    text.removeAttribute(key, range: NSRange(location: 0, length: text.length))
                }
            }
        }
        output.append(text)
        var mark = text.length > 0 ? text.attributes(at: text.length - 1, effectiveRange: nil) : paragraph
        mark[.link] = nil
        for key in keys { mark[key] = paragraph[key] }
        output.append(NSAttributedString(string: "\n", attributes: mark))
    }

    mutating func flushTable() {
        guard let table, !table.cells.isEmpty else {
            self.table = nil
            return
        }
        self.table = nil
        let rows = (table.cells.keys.max() ?? 0) + 1
        let columns = max(table.columns, table.cells.values.map { ($0.keys.max() ?? 0) + 1 }.max() ?? 1)
        let attributes = NamedStyle.normal.attributes()
        var model = TableModel.empty(rows: rows, columns: columns, attributes: attributes)
        for (row, cells) in table.cells {
            for (column, content) in cells {
                guard let index = model.cells.firstIndex(where: { $0.row == row && $0.column == column }) else { continue }
                model.cells[index].content = content
            }
        }
        // Proportional widths: the editor fits them to the page.
        output.append(model.attributedString(attributes: attributes))
    }
}
