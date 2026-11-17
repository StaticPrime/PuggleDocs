import AppKit
import Testing
@testable import PuggleDocsKit

/// Writes sample files for manual or scripted checks when PUGGLE_SAMPLE_OUT is set.
@MainActor
struct SampleExportTests {
    @Test func exportSamplesWhenRequested() throws {
        guard let folder = ProcessInfo.processInfo.environment["PUGGLE_SAMPLE_OUT"] else { return }
        let base = URL(fileURLWithPath: folder)
        let content = DocumentContent(text: sampleDocument(), pageSetup: .letter)
        try DocxWriter.write(content).write(to: base.appendingPathComponent("Sample.docx"))
        try RichTextCodec.write(content).write(to: base.appendingPathComponent("Sample.rtf"))
        try PlainTextCodec.write(content.text).write(to: base.appendingPathComponent("Sample.txt"))
        try OdtWriter.write(content).write(to: base.appendingPathComponent("Sample.odt"))
        try HtmlWriter.write(content, title: "Sample").write(to: base.appendingPathComponent("Sample.html"))
        let table = "<w:p><w:pPr><w:pStyle w:val=\"Heading1\"/></w:pPr><w:r><w:t>Budget</w:t></w:r></w:p>"
            + "<w:tbl><w:tr><w:tc><w:p><w:r><w:t>Item</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Cost</w:t></w:r></w:p></w:tc></w:tr></w:tbl>"
        try DocxTests().minimalDocx(body: table).write(to: base.appendingPathComponent("WithTable.docx"))
    }
}
