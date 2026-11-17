import AppKit
import Testing
@testable import PuggleDocsKit

/// "Acme · Page # of #" with page number and page count fields.
func sampleHeader() -> NSAttributedString {
    let text = NSMutableAttributedString(string: "Acme · Page ", attributes: DocumentDefaults.typingAttributes)
    var field = DocumentDefaults.typingAttributes
    field[.attachment] = PageFieldAttachment(kind: .pageNumber)
    text.append(NSAttributedString(string: "\u{FFFC}", attributes: field))
    text.append(NSAttributedString(string: " of ", attributes: DocumentDefaults.typingAttributes))
    field[.attachment] = PageFieldAttachment(kind: .pageCount)
    text.append(NSAttributedString(string: "\u{FFFC}", attributes: field))
    return text
}

func fieldKinds(in text: NSAttributedString?) -> [PageFieldAttachment.Kind] {
    guard let text else { return [] }
    var kinds: [PageFieldAttachment.Kind] = []
    text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length), options: []) { value, _, _ in
        if let field = value as? PageFieldAttachment { kinds.append(field.kind) }
    }
    return kinds
}

@MainActor
struct HeaderFooterTests {
    func content() -> DocumentContent {
        var setup = PageSetup.letter
        setup.differentFirstPage = true
        let footer = NSAttributedString(string: "Confidential", attributes: DocumentDefaults.typingAttributes)
        return DocumentContent(text: sampleDocument(), pageSetup: setup, header: sampleHeader(), footer: footer)
    }

    @Test func docxKeepsHeaderFooterAndFields() throws {
        let data = try DocxWriter.write(content())
        let zip = try ZipReader(data: data)
        #expect(zip.contains("word/header1.xml") && zip.contains("word/footer1.xml"))
        for path in zip.entries.keys { #expect(XMLParser(data: try #require(try zip.read(path))).parse(), "\(path)") }
        let result = try DocxReader.read(data)
        #expect(result.warnings.isEmpty)
        #expect(result.header?.string == "Acme · Page \u{FFFC} of \u{FFFC}")
        #expect(fieldKinds(in: result.header) == [.pageNumber, .pageCount])
        #expect(result.footer?.string == "Confidential")
        #expect(result.pageSetup.differentFirstPage)
        #expect(result.text.string == sampleDocument().string)
    }

    @Test func odtKeepsHeaderFooterAndFields() throws {
        let data = try OdtWriter.write(content())
        let zip = try ZipReader(data: data)
        for path in ["content.xml", "styles.xml"] { #expect(XMLParser(data: try #require(try zip.read(path))).parse(), "\(path)") }
        let result = try OdtReader.read(data)
        #expect(result.header?.string == "Acme · Page \u{FFFC} of \u{FFFC}")
        #expect(fieldKinds(in: result.header) == [.pageNumber, .pageCount])
        #expect(result.footer?.string == "Confidential")
        #expect(result.pageSetup.differentFirstPage)
        #expect(result.text.string == sampleDocument().string)
    }

    @Test func htmlKeepsHeaderFooterAndFields() throws {
        let html = HtmlWriter.html(content())
        let result = try HtmlReader.read(Data(html.utf8))
        #expect(result.header?.string == "Acme · Page \u{FFFC} of \u{FFFC}")
        #expect(fieldKinds(in: result.header) == [.pageNumber, .pageCount])
        #expect(result.footer?.string == "Confidential")
        #expect(result.pageSetup.differentFirstPage)
        #expect(result.text.string == sampleDocument().string)
    }

    @Test func docxReadsComplexPageField() throws {
        let body = "<w:p><w:r><w:t>Body</w:t></w:r></w:p><w:sectPr><w:headerReference w:type=\"default\" r:id=\"rIdH\"/></w:sectPr>"
        let header = """
        <w:hdr xmlns:w="\(DocxWriter.wNamespace)"><w:p><w:r><w:t xml:space="preserve">Page </w:t></w:r>\
        <w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText> PAGE \\* MERGEFORMAT </w:instrText></w:r>\
        <w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>7</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p></w:hdr>
        """
        var zip = ZipWriter()
        zip.add(path: "[Content_Types].xml", data: Data(DocxWriter.contentTypesXML(hasNumbering: false).utf8))
        zip.add(path: "_rels/.rels", data: Data(DocxWriter.packageRelationshipsXML.utf8))
        zip.add(path: "word/document.xml", data: Data("<w:document xmlns:w=\"\(DocxWriter.wNamespace)\" xmlns:r=\"\(DocxWriter.rNamespace)\"><w:body>\(body)</w:body></w:document>".utf8))
        zip.add(path: "word/_rels/document.xml.rels", data: Data("<Relationships xmlns=\"\(DocxWriter.relationshipsNamespace)\"><Relationship Id=\"rIdH\" Type=\"\(DocxWriter.officeRelationshipBase)header\" Target=\"header1.xml\"/></Relationships>".utf8))
        zip.add(path: "word/header1.xml", data: Data(header.utf8))
        let result = try DocxReader.read(zip.finish())
        #expect(result.header?.string == "Page \u{FFFC}")
        #expect(fieldKinds(in: result.header) == [.pageNumber])
        #expect(!result.warnings.contains(.fields))
    }
}
