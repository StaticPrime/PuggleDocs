import AppKit
import Testing
@testable import PuggleDocsKit

@MainActor
struct HtmlTests {
    @Test func roundTripKeepsTextStylesAndLists() throws {
        let original = sampleDocument()
        var setup = PageSetup.letter
        setup.pageColorHex = "FCE5CD"
        let html = HtmlWriter.write(DocumentContent(text: original, pageSetup: setup), title: "Sample")
        let result = try HtmlReader.read(html)
        #expect(result.text.string == original.string)
        let text = result.text
        let string = text.string as NSString
        func attributes(of word: String) -> [NSAttributedString.Key: Any] {
            text.attributes(at: string.range(of: word).location, effectiveRange: nil)
        }
        #expect(attributes(of: "Quarterly")[.pdNamedStyle] as? String == "title")
        #expect(attributes(of: "Overview")[.pdNamedStyle] as? String == "heading1")
        #expect(FontResolver.spec(from: attributes(of: "Overview")).size == 20)
        #expect(FontResolver.spec(from: attributes(of: "bold")).bold)
        #expect((attributes(of: "italic red")[.foregroundColor] as? NSColor)?.hexString == "CC0000")
        #expect((attributes(of: "highlighted")[.backgroundColor] as? NSColor)?.hexString == "FFFF00")
        #expect((attributes(of: "link")[.link] as? URL)?.absoluteString == "https://example.com/a?b=1&c=2")
        #expect(CharacterFormatting.baseline(attributes(of: "2.")) == 1)
        #expect(ListNumbering.entries(in: text).map(\.marker) == ["1.", "a.", "2."])
        let centered = try #require(attributes(of: "Centered")[.paragraphStyle] as? NSParagraphStyle)
        #expect(centered.alignment == .center && centered.lineHeightMultiple == 2 && centered.paragraphSpacing == 10)
        #expect(result.pageSetup.pageColorHex == "FCE5CD")
        #expect(result.pageSetup.margins == setup.margins)
    }

    @Test func checklistsAndCustomBulletsRoundTrip() throws {
        let text = NSMutableAttributedString()
        let checklist = ListItem(listID: "C", preset: .checkbox)
        let stars = ListItem(listID: "S", preset: .starCircleSquare)
        for (string, item) in [("Done", checklist.with(checked: true)), ("Todo", checklist), ("Star", stars)] {
            text.append(NSAttributedString(string: string + "\n", attributes: ParagraphFormatting.apply(ParagraphFormatting.setList(item), to: DocumentDefaults.typingAttributes)))
        }
        let html = HtmlWriter.html(DocumentContent(text: text))
        #expect(!html.contains("list-style-type:\""))
        let result = try HtmlReader.read(Data(html.utf8)).text
        let entries = ListNumbering.entries(in: result)
        #expect(entries.map(\.item.preset) == [.checkbox, .checkbox, .starCircleSquare])
        #expect(entries.map(\.item.isChecked) == [true, false, false])
    }

    @Test func readsWebEditorExport() throws {
        let html = """
        <html><head><meta content="text/html; charset=UTF-8" http-equiv="content-type"><style type="text/css">
        ol.lst-kix_abc-0{list-style-type:none}.c1{font-weight:700}.c2{color:#ff0000}.c5{background-color:#ffffff;max-width:468pt;padding:72pt 72pt 72pt 72pt}
        .title{padding-top:0pt;color:#000000;font-size:26pt}
        </style></head><body class="c5 doc-content">
        <p class="title"><span>My Title</span></p>
        <h2><span>Section</span></h2>
        <p><span>Plain </span><span class="c1">bold</span><span class="c2"> red</span></p>
        <ul class="c3 lst-kix_abc-0 start"><li class="c4"><span>Top</span></li></ul>
        <ul class="c3 lst-kix_abc-1 start"><li class="c4"><span>Inner</span></li></ul>
        <ul class="c3 lst-kix_abc-0"><li class="c4"><span>Top again</span></li></ul>
        <hr style="page-break-before:always;display:none;">
        <p><span>Next page</span></p>
        </body></html>
        """
        let result = try HtmlReader.read(Data(html.utf8))
        let text = result.text
        #expect(text.string == "My Title\nSection\nPlain bold red\nTop\nInner\nTop again\u{0C}\nNext page")
        let string = text.string as NSString
        #expect(text.attribute(.pdNamedStyle, at: 0, effectiveRange: nil) as? String == "title")
        #expect(FontResolver.spec(from: text.attributes(at: 0, effectiveRange: nil)).size == 26)
        #expect(text.attribute(.pdNamedStyle, at: string.range(of: "Section").location, effectiveRange: nil) as? String == "heading2")
        #expect(FontResolver.spec(from: text.attributes(at: string.range(of: "bold").location, effectiveRange: nil)).bold)
        let red = text.attribute(.foregroundColor, at: string.range(of: "red").location, effectiveRange: nil) as? NSColor
        #expect(red?.hexString == "FF0000")
        let entries = ListNumbering.entries(in: text)
        #expect(entries.map(\.item.level) == [0, 1, 0])
        #expect(Set(entries.map(\.item.listID)).count == 1)
        #expect(result.pageSetup.margins == .uniform(72))
        #expect(abs(result.pageSetup.pageSize.width - 612) < 1)
    }

    @Test func readsMessyMarkup() throws {
        let html = "<p>Unclosed &amp; <b>bold<p>Second&nbsp;line<br>after break<ul><li>One<li>Two</ul><table><tr><td>Cell</td></tr></table><img src=\"x.png\">"
        let result = try HtmlReader.read(Data(html.utf8))
        #expect(result.text.string == "Unclosed & bold\nSecond\u{00A0}line\u{2028}after break\nOne\nTwo\nCell\n")
        #expect(ListNumbering.entries(in: result.text).map(\.marker) == ["●", "●"])
        #expect(TableModel.table(at: result.text.length - 2, in: result.text)?.cells.count == 1)
        #expect(result.warnings.contains(.images))
    }
}
