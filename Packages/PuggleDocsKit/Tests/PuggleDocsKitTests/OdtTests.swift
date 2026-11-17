import AppKit
import Testing
@testable import PuggleDocsKit

@MainActor
struct OdtTests {
    func roundTrip(_ text: NSAttributedString, setup: PageSetup = .letter) throws -> DocumentContent {
        try OdtReader.read(OdtWriter.write(DocumentContent(text: text, pageSetup: setup)))
    }

    @Test func packageIsValid() throws {
        let data = try OdtWriter.write(DocumentContent(text: sampleDocument(), pageSetup: .letter))
        // "mimetype" must be the first entry, stored, so its name and value sit at fixed offsets.
        #expect(data.readLE16(at: 8) == 0)
        #expect(String(decoding: data[30..<38], as: UTF8.self) == "mimetype")
        #expect(String(decoding: data[38..<(38 + 39)], as: UTF8.self) == OdtWriter.mimeType)
        let zip = try ZipReader(data: data)
        for path in ["content.xml", "styles.xml", "meta.xml", "META-INF/manifest.xml"] {
            let part = try #require(try zip.read(path))
            #expect(XMLParser(data: part).parse(), "\(path) is not well-formed")
        }
    }

    @Test func roundTripKeepsTextStylesAndLists() throws {
        let original = sampleDocument()
        let result = try roundTrip(original).text
        #expect(result.string == original.string)
        let string = result.string as NSString
        func attributes(of word: String) -> [NSAttributedString.Key: Any] {
            result.attributes(at: string.range(of: word).location, effectiveRange: nil)
        }
        #expect(attributes(of: "Quarterly")[.pdNamedStyle] as? String == "title")
        #expect(attributes(of: "Overview")[.pdNamedStyle] as? String == "heading1")
        #expect(FontResolver.spec(from: attributes(of: "bold")).bold)
        #expect(FontResolver.spec(from: attributes(of: "italic red")).italic)
        #expect((attributes(of: "italic red")[.foregroundColor] as? NSColor)?.hexString == "CC0000")
        #expect((attributes(of: "highlighted")[.backgroundColor] as? NSColor)?.hexString == "FFFF00")
        #expect((attributes(of: "link")[.link] as? URL)?.absoluteString == "https://example.com/a?b=1&c=2")
        #expect(CharacterFormatting.baseline(attributes(of: "2.")) == 1)
        #expect(ListNumbering.entries(in: result).map(\.marker) == ["1.", "a.", "2."])
        let centered = try #require(attributes(of: "Centered")[.paragraphStyle] as? NSParagraphStyle)
        #expect(centered.alignment == .center && centered.lineHeightMultiple == 2 && centered.paragraphSpacing == 10)
    }

    @Test func roundTripKeepsWhitespaceAndPageSetup() throws {
        let text = NSAttributedString(string: "  two leading\tand  double  spaces  ", attributes: DocumentDefaults.typingAttributes)
        var setup = PageSetup.a4
        setup.orientation = .landscape
        setup.pageColorHex = "D0E0E3"
        let result = try roundTrip(text, setup: setup)
        #expect(result.text.string == text.string)
        #expect(result.pageSetup.orientation == .landscape)
        #expect(result.pageSetup.pageColorHex == "D0E0E3")
        #expect(abs(result.pageSetup.pageSize.width - 842) < 1)
    }

    @Test func readsHandWrittenDocument() throws {
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content \(OdtWriter.namespaces) office:version="1.2">
          <office:automatic-styles>
            <style:style style:name="T1" style:family="text"><style:text-properties fo:font-weight="bold"/></style:style>
            <style:style style:name="P9" style:family="paragraph" style:parent-style-name="Standard">
              <style:paragraph-properties fo:break-before="page"/></style:style>
            <text:list-style style:name="LX"><text:list-level-style-number text:level="1" style:num-suffix="." style:num-format="1"/></text:list-style>
          </office:automatic-styles>
          <office:body><office:text>
            <text:h text:outline-level="2">Plain   heading
            </text:h>
            <text:p>Some <text:span text:style-name="T1">bold</text:span> text<text:s text:c="2"/>here</text:p>
            <text:list xml:id="a" text:style-name="LX"><text:list-item><text:p>One</text:p></text:list-item></text:list>
            <text:p>Interruption</text:p>
            <text:list text:continue-list="a" text:style-name="LX"><text:list-item><text:p>Two</text:p></text:list-item></text:list>
            <table:table xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0"><table:table-row><table:table-cell><text:p>Cell</text:p></table:table-cell></table:table-row></table:table>
            <text:p text:style-name="P9">After break</text:p>
          </office:text></office:body>
        </office:document-content>
        """
        var zip = ZipWriter()
        zip.add(path: "mimetype", data: Data(OdtWriter.mimeType.utf8), compress: false)
        zip.add(path: "content.xml", data: Data(content.utf8))
        let result = try OdtReader.read(zip.finish())
        #expect(result.text.string == "Plain heading\nSome bold text  here\nOne\nInterruption\nTwo\nCell\n\u{0C}\nAfter break")
        #expect(result.text.attribute(.pdNamedStyle, at: 0, effectiveRange: nil) as? String == "heading2")
        let bold = (result.text.string as NSString).range(of: "bold")
        #expect(FontResolver.spec(from: result.text.attributes(at: bold.location, effectiveRange: nil)).bold)
        #expect(ListNumbering.entries(in: result.text).map(\.marker) == ["1.", "2."])
        #expect(TableModel.table(at: (result.text.string as NSString).range(of: "Cell").location, in: result.text)?.cells.count == 1)
    }
}
