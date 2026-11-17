import AppKit
import Testing
@testable import PuggleDocsKit

/// Paragraph, a 2x3 table with a merged cell and colored cell, then a closing paragraph.
func documentWithTable() -> NSAttributedString {
    let attributes = NamedStyle.normal.attributes()
    let text = NSMutableAttributedString(string: "Intro\n", attributes: attributes)
    var cells: [TableModel.Cell] = []
    for (index, word) in ["Name", "Role", "Team", "Ana", "Lead"].enumerated() {
        let row = index < 3 ? 0 : 1
        let column = index < 3 ? index : index - 3
        cells.append(TableModel.Cell(row: row, column: column, columnSpan: index == 4 ? 2 : 1,
                                     content: NSAttributedString(string: word, attributes: attributes),
                                     background: index == 0 ? NSColor(hex: "D9EAD3") : nil))
    }
    var model = TableModel(rows: 2, columns: 3, cells: cells, columnWidths: [2, 1, 1])
    model.borderWidth = 1.5
    model.borderColor = NSColor(hex: "1155CC")!
    text.append(model.attributedString(attributes: attributes))
    text.append(NSAttributedString(string: "Outro", attributes: attributes))
    return text
}

@MainActor
struct TableTests {
    func check(_ result: DocumentContent, _ format: String) throws {
        #expect(result.text.string == documentWithTable().string, "\(format) text")
        let start = (result.text.string as NSString).range(of: "Name").location
        let table = try #require(TableModel.table(at: start, in: result.text), "\(format) table")
        #expect(table.rows == 2 && table.columns == 3, "\(format) size")
        #expect(table.orderedCells.map(\.content.string) == ["Name", "Role", "Team", "Ana", "Lead"], "\(format) cells")
        #expect(table.orderedCells.last?.columnSpan == 2, "\(format) merged cell")
        #expect(table.orderedCells.first?.background?.hexString == "D9EAD3", "\(format) background")
        #expect(abs(table.columnWidths[0] - 0.5) < 0.02, "\(format) widths \(table.columnWidths)")
        #expect(abs(table.borderWidth - 1.5) < 0.2, "\(format) border \(table.borderWidth)")
        #expect(result.warnings.isEmpty, "\(format) warnings")
    }

    @Test func modelReadsAndRebuildsTables() throws {
        let text = documentWithTable()
        let table = try #require(TableModel.table(at: 8, in: text))
        #expect(table.rows == 2 && table.columns == 3 && table.cells.count == 5)
        #expect(table.range == NSRange(location: 6, length: (text.string as NSString).range(of: "Outro").location - 6))
        var edited = table
        edited.insertRow(at: 1)
        edited.insertColumn(at: 0)
        #expect(edited.rows == 3 && edited.columns == 4)
        let rebuilt = edited.attributedString(attributes: NamedStyle.normal.attributes())
        #expect(TableModel.table(at: 0, in: rebuilt)?.cells.count == edited.cells.count)
    }

    @Test func docxKeepsTables() throws {
        let data = try DocxWriter.write(DocumentContent(text: documentWithTable(), pageSetup: .letter))
        let zip = try ZipReader(data: data)
        #expect(XMLParser(data: try #require(try zip.read("word/document.xml"))).parse())
        try check(try DocxReader.read(data), "docx")
    }

    @Test func odtKeepsTables() throws {
        let data = try OdtWriter.write(DocumentContent(text: documentWithTable(), pageSetup: .letter))
        let zip = try ZipReader(data: data)
        #expect(XMLParser(data: try #require(try zip.read("content.xml"))).parse())
        try check(try OdtReader.read(data), "odt")
    }

    @Test func htmlKeepsTables() throws {
        let html = HtmlWriter.html(DocumentContent(text: documentWithTable()))
        try check(try HtmlReader.read(Data(html.utf8)), "html")
    }

    @Test func rtfKeepsTables() throws {
        let data = try RichTextCodec.write(DocumentContent(text: documentWithTable(), pageSetup: .letter))
        let result = try RichTextCodec.read(data)
        let start = (result.text.string as NSString).range(of: "Name").location
        let table = try #require(TableModel.table(at: start, in: result.text))
        #expect(table.rows == 2 && table.columns == 3)
    }
}
