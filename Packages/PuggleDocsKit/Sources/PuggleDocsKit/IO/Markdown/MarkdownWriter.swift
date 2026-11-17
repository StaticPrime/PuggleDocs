import AppKit

/// Writes GitHub-flavored Markdown: headings, emphasis, strikethrough, code, links, lists, task
/// lists, tables and pictures (embedded as data addresses). Other formatting has no Markdown form.
public enum MarkdownWriter {
    public static func write(_ content: DocumentContent) -> Data {
        Data(markdown(content.text).utf8)
    }

    static let monospaceFamilies: Set<String> = ["Courier New", "Courier", "Menlo", "Monaco", "SF Mono", "Source Code Pro", "Roboto Mono", "Consolas"]

    public static func markdown(_ text: NSAttributedString) -> String {
        var writer = Writer(text: text)
        writer.writeBlocks()
        return writer.output
    }

    struct Writer {
        let text: NSAttributedString
        var output = ""
        var images: [String] = []
        /// What the last block was, to decide on blank lines between blocks.
        var previous: Kind = .none
        var codeLines: [String] = []

        enum Kind: Equatable { case none, paragraph, list(String), code }

        init(text: NSAttributedString) { self.text = text }

        mutating func writeBlocks() {
            let string = text.string as NSString
            var location = 0
            while location < string.length {
                if TableModel.block(at: location, in: text) != nil, let table = TableModel.table(at: location, in: text), table.range.length > 0 {
                    flushCode()
                    separate(from: .paragraph)
                    output += tableMarkdown(table)
                    previous = .paragraph
                    location = NSMaxRange(table.range)
                    continue
                }
                let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
                location = NSMaxRange(paragraph)
                var content = paragraph
                while content.length > 0, DocxWriter.isParagraphSeparator(string.character(at: NSMaxRange(content) - 1)) { content.length -= 1 }
                writeParagraph(content)
            }
            flushCode()
            if !images.isEmpty {
                output += "\n"
                for (index, image) in images.enumerated() { output += "[image\(index + 1)]: <\(image)>\n" }
            }
            if !output.hasSuffix("\n") { output += "\n" }
        }

        /// A blank line between blocks, except between items of the same list.
        mutating func separate(from kind: Kind) {
            guard previous != .none else { return }
            if case .list(let id) = kind, previous == .list(id) { return }
            output += "\n"
        }

        mutating func writeParagraph(_ range: NSRange) {
            let string = (text.string as NSString).substring(with: range).replacingOccurrences(of: "\u{0C}", with: "")
            let attributes = range.length > 0 ? text.attributes(at: range.location, effectiveRange: nil)
                : (range.location < text.length ? text.attributes(at: range.location, effectiveRange: nil) : [:])
            let paragraph = ParagraphAttributes(attributes: attributes)
            // Lines set entirely in a code font become a fenced code block.
            if !string.trimmingCharacters(in: .whitespaces).isEmpty, paragraph.listItem == nil, isMonospace(range) {
                if previous != .code { flushCode(); separate(from: .code) }
                codeLines.append(string)
                previous = .code
                return
            }
            flushCode()
            guard !string.trimmingCharacters(in: .whitespaces).isEmpty || paragraph.listItem != nil else { return }
            if let item = paragraph.listItem {
                separate(from: .list(item.listID))
                let indent = String(repeating: " ", count: item.level * 4)
                let marker: String
                switch item.kind {
                case .bulleted: marker = "- "
                case .numbered: marker = "1. "
                case .checklist: marker = item.isChecked ? "- [x] " : "- [ ] "
                }
                output += indent + marker + inline(range, continuation: indent + "    ", style: paragraph.namedStyle,
                                                   skipStrikethrough: item.kind == .checklist && item.isChecked) + "\n"
                previous = .list(item.listID)
                return
            }
            separate(from: .paragraph)
            let body = inline(range, continuation: "", style: paragraph.namedStyle)
            switch paragraph.namedStyle {
            case .title: output += "# " + body
            case .subtitle: output += body.isEmpty ? "" : "*" + body + "*"
            case .normal: output += body
            default: output += String(repeating: "#", count: paragraph.namedStyle.headingLevel ?? 1) + " " + body
            }
            output += "\n"
            previous = .paragraph
        }

        mutating func flushCode() {
            guard !codeLines.isEmpty else { return }
            let fence = codeLines.contains { $0.contains("```") } ? "~~~" : "```"
            output += fence + "\n" + codeLines.joined(separator: "\n") + "\n" + fence + "\n"
            codeLines = []
        }

        func isMonospace(_ range: NSRange) -> Bool {
            guard range.length > 0 else { return false }
            var all = true
            text.enumerateAttribute(.font, in: range, options: []) { value, _, stop in
                let family = (value as? NSFont)?.familyName ?? ""
                if !MarkdownWriter.monospaceFamilies.contains(family) { all = false; stop.pointee = true }
            }
            return all
        }

        // MARK: Inline

        struct Segment: Equatable {
            var text: String
            var bold = false
            var italic = false
            var strike = false
            var code = false
            var link: String?
        }

        mutating func inline(_ range: NSRange, continuation: String, style: NamedStyle = .normal, inTable: Bool = false,
                             skipStrikethrough: Bool = false) -> String {
            // A style's own weight and slant (bold headings, say) aren't extra emphasis.
            let definition = style.definition
            var segments: [Segment] = []
            text.enumerateAttributes(in: range, options: []) { attributes, run, _ in
                let raw = (text.string as NSString).substring(with: run)
                if let attachment = attributes[.attachment] as? NSTextAttachment, raw.contains("\u{FFFC}") {
                    if !(attachment is PageFieldAttachment), let info = ImageAttachments.info(attachment), let portable = ImageAttachments.portableData(info) {
                        images.append("data:\(ImageAttachments.mimeType(portable.type));base64,\(portable.data.base64EncodedString())")
                        segments.append(Segment(text: "\u{1}image\(images.count)\u{1}"))
                    }
                    return
                }
                let family = (attributes[.font] as? NSFont)?.familyName ?? ""
                var segment = Segment(text: raw)
                segment.bold = CharacterFormatting.isBold(attributes) && !definition.bold
                segment.italic = CharacterFormatting.isItalic(attributes) && !definition.italic
                segment.strike = CharacterFormatting.isStruckThrough(attributes) && !skipStrikethrough
                segment.code = MarkdownWriter.monospaceFamilies.contains(family)
                segment.link = DocxWriter.linkTarget(attributes[.link])
                if var last = segments.last, last.bold == segment.bold, last.italic == segment.italic, last.strike == segment.strike,
                   last.code == segment.code, last.link == segment.link, !last.text.hasPrefix("\u{1}") {
                    last.text += segment.text
                    segments[segments.count - 1] = last
                } else {
                    segments.append(segment)
                }
            }
            let lineBreak = inTable ? "<br>" : "\\\n" + continuation
            var result = ""
            var index = 0
            while index < segments.count {
                // Group runs that share a link so the link wraps them once.
                let link = segments[index].link
                var group: [Segment] = []
                while index < segments.count, segments[index].link == link {
                    group.append(segments[index])
                    index += 1
                }
                let body = group.map { formatted($0, inTable: inTable) }.joined()
                result += link.map { "[\(body)](\(escapeURL($0)))" } ?? body
            }
            return result.replacingOccurrences(of: "\u{2028}", with: lineBreak)
        }

        func formatted(_ segment: Segment, inTable: Bool) -> String {
            if segment.text.hasPrefix("\u{1}image") {
                return "![][\(segment.text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{1}")))]"
            }
            if segment.code {
                let ticks = segment.text.contains("`") ? "``" : "`"
                return segment.text.isEmpty ? "" : ticks + segment.text.replacingOccurrences(of: "\u{2028}", with: " ") + ticks
            }
            var body = MarkdownWriter.escape(segment.text, inTable: inTable)
            // Emphasis markers must touch the words, so spaces stay outside them.
            let leading = String(body.prefix { $0 == " " })
            let trailing = String(body.reversed().prefix { $0 == " " })
            body = String(body.dropFirst(leading.count).dropLast(trailing.count))
            guard !body.isEmpty else { return leading + trailing }
            var markers = ""
            if segment.bold { markers += "**" }
            if segment.italic { markers += "*" }
            if segment.strike { markers += "~~" }
            return leading + markers + body + String(markers.reversed()) + trailing
        }

        func escapeURL(_ url: String) -> String {
            url.replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
        }

        // MARK: Tables

        mutating func tableMarkdown(_ table: TableModel) -> String {
            var rows: [[String]] = Array(repeating: Array(repeating: "", count: table.columns), count: max(table.rows, 1))
            for cell in table.cells where cell.row < rows.count && cell.column < table.columns {
                let content = cell.content
                var writer = Writer(text: content)
                writer.images = images
                let string = content.string as NSString
                var parts: [String] = []
                var location = 0
                while location < string.length {
                    let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
                    location = NSMaxRange(paragraph)
                    var range = paragraph
                    while range.length > 0, DocxWriter.isParagraphSeparator(string.character(at: NSMaxRange(range) - 1)) { range.length -= 1 }
                    parts.append(writer.inline(range, continuation: "", inTable: true))
                }
                images = writer.images
                rows[cell.row][cell.column] = parts.joined(separator: "<br>")
            }
            var markdown = "| " + rows[0].joined(separator: " | ") + " |\n"
            markdown += "|" + String(repeating: " --- |", count: table.columns) + "\n"
            for row in rows.dropFirst() { markdown += "| " + row.joined(separator: " | ") + " |\n" }
            return markdown
        }
    }

    /// Backslash-escapes characters Markdown would otherwise read as formatting.
    static func escape(_ text: String, inTable: Bool) -> String {
        var result = ""
        for character in text {
            switch character {
            case "\\", "*", "_", "`", "[", "]", "<", ">", "~": result += "\\" + String(character)
            case "|" where inTable: result += "\\|"
            default: result.append(character)
            }
        }
        // Line starts that would begin a heading, list or quote.
        if let first = result.first, "#+-".contains(first) { result = "\\" + result }
        if let match = result.range(of: "^[0-9]+[.)]", options: .regularExpression) {
            result.insert("\\", at: result.index(before: match.upperBound))
        }
        return result
    }
}
