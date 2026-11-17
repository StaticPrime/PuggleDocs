import AppKit
import PDFKit
import PuggleDocsKit

/// Read-only PDF document shown in a viewer window.
@objc(PDFViewerDocument)
final class PDFViewerDocument: NSDocument {
    nonisolated(unsafe) private(set) var pdf: PDFDocument?

    nonisolated override class var autosavesInPlace: Bool { false }

    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { false }

    nonisolated override func read(from data: Data, ofType typeName: String) throws {
        guard let document = PDFDocument(data: data) else {
            throw DocumentIOError.unreadable("The PDF is damaged or protected.")
        }
        pdf = document
    }

    override func makeWindowControllers() {
        addWindowController(PDFWindowController(document: self))
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        guard let pdf, let operation = pdf.printOperation(for: printInfo, scalingMode: .pageScaleToFit, autoRotate: true) else {
            throw DocumentIOError.unwritable("The PDF can't be printed.")
        }
        return operation
    }

    /// Plain text of the PDF as editor text: one paragraph per paragraph of the source, pages separated by page breaks.
    func editableText() -> NSAttributedString {
        let result = NSMutableAttributedString()
        guard let pdf else { return result }
        let attributes = DocumentDefaults.typingAttributes
        var bullets: ListItem?
        var numbers: ListItem?
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { continue }
            let paragraphs = PDFTextJoiner.paragraphs(from: page.string ?? "")
            for paragraph in paragraphs {
                // Lines that start with a bullet or number become list items.
                let (kind, level, text) = PDFTextJoiner.listMarker(in: paragraph, numberedListActive: numbers != nil)
                var paragraphAttributes = attributes
                switch kind {
                case .bulleted?:
                    let item = bullets ?? ListItem(preset: .discCircleSquare)
                    bullets = item
                    paragraphAttributes = ParagraphFormatting.apply(ParagraphFormatting.setList(item.with(level: level)), to: attributes)
                case .numbered?:
                    let item = numbers ?? ListItem(preset: .decimalAlphaRoman)
                    numbers = item
                    paragraphAttributes = ParagraphFormatting.apply(ParagraphFormatting.setList(item.with(level: level)), to: attributes)
                default:
                    bullets = nil
                    numbers = nil
                }
                result.append(NSAttributedString(string: text + "\n", attributes: paragraphAttributes))
            }
            if index < pdf.pageCount - 1, result.length > 0 {
                result.insert(NSAttributedString(string: "\u{0C}", attributes: attributes), at: result.length - 1)
            }
        }
        if result.length > 0, (result.string as NSString).character(at: result.length - 1) == 0x0A {
            result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
        }
        return result
    }
}

/// Rebuilds paragraphs from PDF text, which arrives one line at a time: a line much shorter than
/// the page's longest line ends a paragraph, as do blank lines; list bullets start a new one.
enum PDFTextJoiner {
    static func paragraphs(from text: String) -> [String] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let longest = lines.map(\.count).max() ?? 0
        let shortLine = Int(Double(longest) * 0.7)
        var paragraphs: [String] = []
        var current = ""
        func finish() {
            if !current.isEmpty { paragraphs.append(current) }
            current = ""
        }
        for line in lines {
            guard !line.isEmpty else { finish(); continue }
            if let first = line.first, "•●○■▪–-*".contains(first) { finish() }
            if current.isEmpty {
                current = line
            } else if current.hasSuffix("-"), line.first?.isLowercase == true {
                current.removeLast()
                current += line
            } else {
                current += " " + line
            }
            if line.count < shortLine { finish() }
        }
        finish()
        return paragraphs.filter { !isMarkerOnly($0) }
    }

    static let bulletCharacters: Set<Character> = ["•", "●", "○", "■", "▪", "◦", "–", "-", "*", "➢", "❖", "★"]

    /// "●" or "12." alone on a line (markers that lost their text during extraction).
    static func isMarkerOnly(_ text: String) -> Bool {
        if text.count == 1, let first = text.first, bulletCharacters.contains(first) { return true }
        return text.range(of: #"^(\(?\d{1,3}|[A-Za-z]|[ivxlcdmIVXLCDM]{1,6})[.)]$"#, options: .regularExpression) != nil
    }

    /// Detects a leading list marker; returns the list kind, nesting level and the text after it.
    /// Letters ("a.") and roman numerals ("ii.") nest under an active numbered list.
    static func listMarker(in paragraph: String, numberedListActive: Bool) -> (ListKind?, Int, String) {
        if let first = paragraph.first, bulletCharacters.contains(first), paragraph.dropFirst().first == " " {
            let level = "○◦".contains(first) ? 1 : ("▪■".contains(first) ? 2 : 0)
            return (.bulleted, level, String(paragraph.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        }
        if let match = paragraph.range(of: #"^\d{1,3}[.)]\s+"#, options: .regularExpression) {
            return (.numbered, 0, String(paragraph[match.upperBound...]))
        }
        if numberedListActive {
            if let match = paragraph.range(of: #"^(ii|iii|iv|v|vi|vii|viii|ix|x)[.)]\s+"#, options: .regularExpression) {
                return (.numbered, 2, String(paragraph[match.upperBound...]))
            }
            if let match = paragraph.range(of: #"^[a-z][.)]\s+"#, options: .regularExpression) {
                return (.numbered, 1, String(paragraph[match.upperBound...]))
            }
        }
        return (nil, 0, paragraph)
    }
}
