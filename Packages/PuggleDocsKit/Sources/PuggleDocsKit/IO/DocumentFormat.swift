import AppKit
import UniformTypeIdentifiers

/// File formats PuggleDocs reads and writes.
public enum DocumentFormat: String, CaseIterable, Sendable {
    case docx, odt, rtf, plainText, html, markdown

    public var typeIdentifier: String {
        switch self {
        case .docx: "org.openxmlformats.wordprocessingml.document"
        case .odt: "org.oasis-open.opendocument.text"
        case .rtf: "public.rtf"
        case .plainText: "public.plain-text"
        case .html: "public.html"
        case .markdown: "net.daringfireball.markdown"
        }
    }

    public var utType: UTType { UTType(typeIdentifier) ?? .data }

    /// Whether comments and suggestions can be stored. Other formats keep suggestions as accepted text.
    public var keepsReviewMarkup: Bool { self == .docx || self == .odt || self == .html }

    public var fileExtension: String {
        switch self {
        case .docx: "docx"
        case .odt: "odt"
        case .rtf: "rtf"
        case .plainText: "txt"
        case .html: "html"
        case .markdown: "md"
        }
    }

    /// Name used in "Download" menus.
    public var displayName: String {
        switch self {
        case .docx: "Microsoft Word (.docx)"
        case .odt: "OpenDocument Format (.odt)"
        case .rtf: "Rich Text Format (.rtf)"
        case .plainText: "Plain Text (.txt)"
        case .html: "Web Page (.html)"
        case .markdown: "Markdown (.md)"
        }
    }

    /// Short badge shown next to the document title.
    public var badge: String { "." + fileExtension.uppercased() }

    /// Resolves an NSDocument type name (a UTI) or a file extension.
    public init?(typeName: String) {
        if let match = DocumentFormat.allCases.first(where: { $0.typeIdentifier == typeName || $0.fileExtension == typeName.lowercased() }) {
            self = match
            return
        }
        if ["markdown", "mdown", "mkd", "text/markdown"].contains(typeName.lowercased()) {
            self = .markdown
            return
        }
        guard let type = UTType(typeName) ?? UTType(filenameExtension: typeName) else { return nil }
        if type.conforms(to: DocumentFormat.docx.utType) {
            self = .docx
        } else if type.conforms(to: DocumentFormat.odt.utType) {
            self = .odt
        } else if type.conforms(to: .html) {
            self = .html
        } else if type.identifier == DocumentFormat.markdown.typeIdentifier || type.conforms(to: DocumentFormat.markdown.utType),
                  DocumentFormat.markdown.utType != .data {
            self = .markdown
        } else if type.conforms(to: .rtf) {
            self = .rtf
        } else if type.conforms(to: .plainText) {
            self = .plainText
        } else {
            return nil
        }
    }
}

public enum DocumentIOError: LocalizedError {
    case unreadable(String)
    case unwritable(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let reason): "The document could not be opened. \(reason)"
        case .unwritable(let reason): "The document could not be saved. \(reason)"
        }
    }
}

/// Entry point for converting files to and from the editor's representation.
public enum DocumentIO {
    public static func read(_ data: Data, format: DocumentFormat) throws -> DocumentContent {
        switch format {
        case .docx: return try DocxReader.read(data)
        case .odt: return try OdtReader.read(data)
        case .rtf: return try RichTextCodec.read(data)
        case .plainText: return PlainTextCodec.read(data)
        case .html: return try HtmlReader.read(data)
        case .markdown: return try MarkdownReader.read(data)
        }
    }

    public static func write(_ content: DocumentContent, format: DocumentFormat) throws -> Data {
        var content = content
        if !format.keepsReviewMarkup { content.text = Suggestions.accepted(content.text) }
        switch format {
        case .docx: return try DocxWriter.write(content)
        case .odt: return try OdtWriter.write(content)
        case .rtf: return try RichTextCodec.write(content)
        case .plainText: return PlainTextCodec.write(content.text)
        case .html: return HtmlWriter.write(content, title: content.title ?? "Document")
        case .markdown: return MarkdownWriter.write(content)
        }
    }

    /// Adds a page break after everything in `text`: at the end of the last paragraph, or as its own
    /// paragraph when the text ends with a table (a break cannot go inside a cell).
    public static func appendPageBreak(to text: NSMutableAttributedString) {
        guard text.length > 0 else { return }
        if TableModel.block(at: text.length - 1, in: text) != nil {
            text.append(NSAttributedString(string: "\u{0C}\n", attributes: NamedStyle.normal.attributes()))
        } else if (text.string as NSString).character(at: text.length - 1) == 0x0A {
            text.insert(NSAttributedString(string: "\u{0C}"), at: text.length - 1)
        }
    }

    /// Removes the final paragraph separator unless it ends a table cell.
    public static func trimFinalNewline(_ text: NSMutableAttributedString) {
        guard text.length > 0, (text.string as NSString).character(at: text.length - 1) == 0x0A,
              TableModel.block(at: text.length - 1, in: text) == nil else { return }
        text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1))
    }

    /// Gives every paragraph a named style and fills in missing fonts, as the editor expects.
    public static func normalizeImported(_ storage: NSMutableAttributedString) {
        let all = NSRange(location: 0, length: storage.length)
        guard all.length > 0 else { return }
        storage.enumerateAttribute(.font, in: all, options: []) { value, range, _ in
            if value == nil { storage.addAttribute(.font, value: NamedStyle.normal.definition.font, range: range) }
        }
        storage.enumerateAttribute(.pdNamedStyle, in: all, options: []) { value, range, _ in
            if value == nil { storage.addAttribute(.pdNamedStyle, value: NamedStyle.normal.rawValue, range: range) }
        }
        storage.enumerateAttribute(.paragraphStyle, in: all, options: []) { value, range, _ in
            if value == nil { storage.addAttribute(.paragraphStyle, value: DocumentDefaults.paragraphStyle().copy() as! NSParagraphStyle, range: range) }
        }
        ParagraphFormatting.normalize(storage, in: all)
    }
}
