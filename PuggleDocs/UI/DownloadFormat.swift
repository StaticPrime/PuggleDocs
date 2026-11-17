import PuggleDocsKit
import UniformTypeIdentifiers

/// Entries of File ▸ Download, in the familiar order. PDF and EPUB are export-only.
enum DownloadFormat: CaseIterable {
    case docx, odt, rtf, pdf, plainText, html, epub, markdown

    var documentFormat: DocumentFormat? {
        switch self {
        case .docx: .docx
        case .odt: .odt
        case .rtf: .rtf
        case .plainText: .plainText
        case .html: .html
        case .markdown: .markdown
        case .pdf, .epub: nil
        }
    }

    var displayName: String {
        switch self {
        case .pdf: "PDF Document (.pdf)"
        case .epub: "EPUB Publication (.epub)"
        default: documentFormat?.displayName ?? ""
        }
    }

    var fileExtension: String {
        switch self {
        case .pdf: "pdf"
        case .epub: "epub"
        default: documentFormat?.fileExtension ?? ""
        }
    }

    var utType: UTType {
        switch self {
        case .pdf: .pdf
        case .epub: UTType("org.idpf.epub-container") ?? UTType(filenameExtension: "epub") ?? .data
        default: documentFormat?.utType ?? .data
        }
    }
}
