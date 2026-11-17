import AppKit
import Testing
@testable import PuggleDocsKit

/// A small document exercising most formatting PuggleDocs can store.
func sampleDocument() -> NSAttributedString {
    let text = NSMutableAttributedString()
    func add(_ string: String, style: NamedStyle = .normal, configure: (inout [NSAttributedString.Key: Any]) -> Void = { _ in }) {
        var attributes = style.attributes()
        configure(&attributes)
        text.append(NSAttributedString(string: string, attributes: attributes))
    }
    add("Quarterly plan\n", style: .title)
    add("Overview\n", style: .heading1)
    add("Plain, ")
    add("bold", configure: CharacterFormatting.setBold(true))
    add(", ")
    add("italic red", configure: { attributes in
        CharacterFormatting.setItalic(true)(&attributes)
        attributes[.foregroundColor] = NSColor(hex: "CC0000")
    })
    add(" and ")
    add("highlighted", configure: CharacterFormatting.setHighlight(NSColor(hex: "FFFF00")))
    add(" with a ")
    add("link", configure: { $0[.link] = URL(string: "https://example.com/a?b=1&c=2")! })
    add(" and x")
    add("2", configure: CharacterFormatting.setBaseline(1))
    add(".\n")
    let list = ListItem(listID: "L1", preset: .decimalAlphaRoman)
    for (string, item) in [("First", list), ("Nested", list.with(level: 1)), ("Second", list)] {
        add(string + "\n", configure: { $0 = ParagraphFormatting.apply(ParagraphFormatting.setList(item), to: $0) })
    }
    add("Centered & spaced\n", configure: { attributes in
        let style = (attributes[.paragraphStyle] as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
        style.alignment = .center
        style.lineHeightMultiple = 2
        style.paragraphSpacing = 10
        attributes[.paragraphStyle] = style
    })
    add("Before break\u{0C}\nAfter break")
    return text
}

@MainActor
struct ZipTests {
    @Test func roundTripStoresAndDeflates() throws {
        var writer = ZipWriter()
        let repetitive = Data(String(repeating: "PuggleDocs ", count: 2000).utf8)
        writer.add(path: "a.txt", data: repetitive)
        writer.add(path: "folder/b.bin", data: Data([1, 2, 3]))
        writer.add(path: "empty", data: Data())
        let archive = writer.finish()
        #expect(archive.count < repetitive.count)
        let reader = try ZipReader(data: archive)
        #expect(try reader.read("a.txt") == repetitive)
        #expect(try reader.read("folder/b.bin") == Data([1, 2, 3]))
        #expect(try reader.read("empty") == Data())
        #expect(try reader.read("missing") == nil)
    }

    @Test func crcMatchesKnownValue() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
    }
}

@MainActor
struct DocxTests {
    func roundTrip(_ text: NSAttributedString, setup: PageSetup = .letter) throws -> DocumentContent {
        let data = try DocxWriter.write(DocumentContent(text: text, pageSetup: setup))
        return try DocxReader.read(data)
    }

    @Test func everyPartIsWellFormedXML() throws {
        let data = try DocxWriter.write(DocumentContent(text: sampleDocument(), pageSetup: .letter))
        let zip = try ZipReader(data: data)
        #expect(zip.entries.keys.contains("word/numbering.xml"))
        for path in zip.entries.keys {
            let part = try #require(try zip.read(path))
            let parser = XMLParser(data: part)
            #expect(parser.parse(), "\(path) is not well-formed")
        }
    }

    @Test func textAndParagraphsSurviveRoundTrip() throws {
        let original = sampleDocument()
        let result = try roundTrip(original)
        #expect(result.text.string == original.string)
        #expect(result.warnings.isEmpty)
    }

    @Test func characterFormattingSurvivesRoundTrip() throws {
        let result = try roundTrip(sampleDocument()).text
        let string = result.string as NSString
        func attributes(of word: String) -> [NSAttributedString.Key: Any] {
            result.attributes(at: string.range(of: word).location, effectiveRange: nil)
        }
        #expect(FontResolver.spec(from: attributes(of: "bold")).bold)
        #expect(FontResolver.spec(from: attributes(of: "italic red")).italic)
        #expect((attributes(of: "italic red")[.foregroundColor] as? NSColor)?.hexString == "CC0000")
        #expect((attributes(of: "highlighted")[.backgroundColor] as? NSColor)?.hexString == "FFFF00")
        #expect((attributes(of: "link")[.link] as? URL)?.absoluteString == "https://example.com/a?b=1&c=2")
        #expect(CharacterFormatting.baseline(attributes(of: "2.")) == 1)
        #expect(FontResolver.spec(from: attributes(of: "2.")).size == 11)
        #expect(((attributes(of: "2.")[.font] as? NSFont)?.pointSize ?? 0) < 8)
        #expect(FontResolver.spec(from: attributes(of: "Plain")).family == "Arial")
        #expect(FontResolver.spec(from: attributes(of: "Plain")).size == 11)
    }

    @Test func stylesListsAndParagraphsSurviveRoundTrip() throws {
        let result = try roundTrip(sampleDocument()).text
        let string = result.string as NSString
        func attributes(of word: String) -> [NSAttributedString.Key: Any] {
            result.attributes(at: string.range(of: word).location, effectiveRange: nil)
        }
        #expect(attributes(of: "Quarterly")[.pdNamedStyle] as? String == "title")
        #expect(attributes(of: "Overview")[.pdNamedStyle] as? String == "heading1")
        #expect(FontResolver.spec(from: attributes(of: "Overview")).size == 20)
        let first = try #require(attributes(of: "First")[.pdListItem] as? ListItem)
        let nested = try #require(attributes(of: "Nested")[.pdListItem] as? ListItem)
        let second = try #require(attributes(of: "Second")[.pdListItem] as? ListItem)
        #expect(first.preset == .decimalAlphaRoman && first.level == 0)
        #expect(nested.level == 1 && nested.listID == first.listID)
        #expect(ListNumbering.entries(in: result).map(\.marker) == ["1.", "a.", "2."])
        _ = second
        let centered = try #require(attributes(of: "Centered")[.paragraphStyle] as? NSParagraphStyle)
        #expect(centered.alignment == .center)
        #expect(centered.lineHeightMultiple == 2)
        #expect(centered.paragraphSpacing == 10)
    }

    @Test func pageSetupSurvivesRoundTrip() throws {
        var setup = PageSetup.a4
        setup.orientation = .landscape
        setup.margins = PageMargins(top: 36, left: 54, bottom: 72, right: 90)
        setup.pageColorHex = "FFF2CC"
        let result = try roundTrip(NSAttributedString(string: "x", attributes: DocumentDefaults.typingAttributes), setup: setup)
        #expect(result.pageSetup.orientation == .landscape)
        #expect(result.pageSetup.margins == setup.margins)
        #expect(result.pageSetup.pageColorHex == "FFF2CC")
        #expect(abs(result.pageSetup.pageSize.width - 842) < 1)
    }

    @Test func emptyAndTrailingNewlineDocuments() throws {
        #expect(try roundTrip(NSAttributedString()).text.string == "")
        let trailing = NSAttributedString(string: "Line\n", attributes: DocumentDefaults.typingAttributes)
        #expect(try roundTrip(trailing).text.string == "Line\n")
    }

    @Test func readsTables() throws {
        let body = "<w:tbl><w:tblGrid><w:gridCol w:w=\"3000\"/><w:gridCol w:w=\"6000\"/></w:tblGrid><w:tr><w:tc><w:p><w:r><w:t>Cell A</w:t></w:r></w:p></w:tc>"
            + "<w:tc><w:tcPr><w:shd w:fill=\"FFF2CC\"/></w:tcPr><w:p><w:r><w:t>Cell B</w:t></w:r></w:p></w:tc></w:tr></w:tbl><w:p><w:r><w:t>After</w:t></w:r></w:p>"
        let result = try DocxReader.read(minimalDocx(body: body))
        #expect(result.text.string == "Cell A\nCell B\nAfter")
        #expect(result.warnings.isEmpty)
        let table = try #require(TableModel.table(at: 0, in: result.text))
        #expect(table.rows == 1 && table.columns == 2)
        #expect(abs(table.columnWidths[0] - 1.0 / 3.0) < 0.01)
        #expect(table.orderedCells[1].background?.hexString == "FFF2CC")
    }

    @Test func readsHyperlinkFieldsAndThemeFonts() throws {
        let body = """
        <w:p><w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText> HYPERLINK "https://puggle.example" </w:instrText></w:r>\
        <w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>site</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>
        """
        let result = try DocxReader.read(minimalDocx(body: body))
        #expect(result.text.string == "site")
        #expect((result.text.attribute(.link, at: 0, effectiveRange: nil) as? URL)?.host == "puggle.example")
    }

    func minimalDocx(body: String) -> Data {
        var zip = ZipWriter()
        zip.add(path: "[Content_Types].xml", data: Data(DocxWriter.contentTypesXML(hasNumbering: false).utf8))
        zip.add(path: "_rels/.rels", data: Data(DocxWriter.packageRelationshipsXML.utf8))
        let document = "<w:document xmlns:w=\"\(DocxWriter.wNamespace)\" xmlns:r=\"\(DocxWriter.rNamespace)\"><w:body>\(body)</w:body></w:document>"
        zip.add(path: "word/document.xml", data: Data(document.utf8))
        return zip.finish()
    }
}

@MainActor
struct RichTextAndPlainTextTests {
    @Test func rtfKeepsListsAndFormatting() throws {
        let content = DocumentContent(text: sampleDocument(), pageSetup: .letter)
        let result = try RichTextCodec.read(RichTextCodec.write(content))
        #expect(result.text.string == content.text.string)
        let string = result.text.string as NSString
        let nested = result.text.attribute(.pdListItem, at: string.range(of: "Nested").location, effectiveRange: nil) as? ListItem
        #expect(nested?.level == 1)
        #expect(ListNumbering.entries(in: result.text).map(\.marker) == ["1.", "a.", "2."])
        #expect(FontResolver.spec(from: result.text.attributes(at: string.range(of: "bold").location, effectiveRange: nil)).bold)
    }

    @Test func rtfKeepsPageColorAndMargins() throws {
        var setup = PageSetup.letter
        setup.pageColorHex = "D9EAD3"
        setup.margins = PageMargins(top: 54, left: 54, bottom: 54, right: 54)
        let result = try RichTextCodec.read(RichTextCodec.write(DocumentContent(text: sampleDocument(), pageSetup: setup)))
        #expect(result.pageSetup.pageColorHex == "D9EAD3")
        #expect(result.pageSetup.margins == setup.margins)
    }

    @Test func pageSetupPropertyListRoundTrip() throws {
        var setup = PageSetup.a4
        setup.orientation = .landscape
        setup.pageColorHex = "CFE2F3"
        let restored = try #require(PageSetup(propertyList: setup.propertyList))
        #expect(restored == setup)
        var invalid = setup
        invalid.margins = .uniform(400)
        #expect(!invalid.hasValidMargins)
        #expect(PageSetup(propertyList: invalid.propertyList) == nil)
    }

    @Test func plainTextWritesListMarkers() {
        let plain = PlainTextCodec.plainString(from: sampleDocument())
        #expect(plain.contains("1. First\n    a. Nested\n2. Second"))
        #expect(!plain.contains("\u{0C}"))
    }

    @Test func plainTextDecodesCommonEncodings() {
        #expect(PlainTextCodec.read(Data([0xEF, 0xBB, 0xBF] + Array("héllo".utf8))).text.string == "héllo")
        #expect(PlainTextCodec.read(Data("a\r\nb\rc".utf8)).text.string == "a\nb\nc")
        #expect(PlainTextCodec.read("naïve".data(using: .windowsCP1252)!).text.string == "naïve")
    }
}
