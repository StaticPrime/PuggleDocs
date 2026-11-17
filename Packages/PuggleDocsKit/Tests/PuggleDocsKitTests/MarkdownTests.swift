import AppKit
import Testing
@testable import PuggleDocsKit

@MainActor
struct MarkdownTests {
    static let sample = """
    # Plan

    Some *italic* and **bold** text with `code` and ~~gone~~,
    a soft break, and a hard break\\
    here. A [link](https://example.com).

    - apple
    - banana
        - nested
    - [x] done task
    - [ ] open task

    1. first
    2. second

    > quoted

    ```
    let x = 1
    let y = 2
    ```

    | Name | Value |
    | --- | --- |
    | a | 1 |
    | b | 2 |

    Last.
    """

    func paragraph(_ text: NSAttributedString, containing phrase: String) -> [NSAttributedString.Key: Any] {
        let location = (text.string as NSString).range(of: phrase).location
        return location == NSNotFound ? [:] : text.attributes(at: location, effectiveRange: nil)
    }

    @Test func readsHeadingsEmphasisListsAndTables() throws {
        let content = try MarkdownReader.read(Data(Self.sample.utf8))
        let text = content.text
        let string = text.string
        #expect(string.hasPrefix("Plan\nSome italic and bold text with code and gone, a soft break, and a hard break\u{2028}here. A link."))
        #expect(paragraph(text, containing: "Plan")[.pdNamedStyle] as? String == "heading1")
        #expect(CharacterFormatting.isItalic(paragraph(text, containing: "italic")))
        #expect(CharacterFormatting.isBold(paragraph(text, containing: "bold")))
        #expect((paragraph(text, containing: "code and")[.font] as? NSFont)?.familyName == "Courier New")
        #expect(CharacterFormatting.isStruckThrough(paragraph(text, containing: "gone")))
        #expect(paragraph(text, containing: "link")[.link] as? URL == URL(string: "https://example.com"))

        let one = paragraph(text, containing: "apple")[.pdListItem] as? ListItem
        let nested = paragraph(text, containing: "nested")[.pdListItem] as? ListItem
        let done = paragraph(text, containing: "done task")[.pdListItem] as? ListItem
        let open = paragraph(text, containing: "open task")[.pdListItem] as? ListItem
        let first = paragraph(text, containing: "first")[.pdListItem] as? ListItem
        #expect(one?.kind == .bulleted && one?.level == 0)
        #expect(nested?.kind == .bulleted && nested?.level == 1 && nested?.listID == one?.listID)
        #expect(done?.kind == .checklist && done?.isChecked == true && !string.contains("[x]"))
        #expect(open?.kind == .checklist && open?.isChecked == false)
        #expect(first?.kind == .numbered)
        #expect(((paragraph(text, containing: "quoted")[.paragraphStyle] as? NSParagraphStyle)?.headIndent ?? 0) > 0)
        #expect((paragraph(text, containing: "let y")[.font] as? NSFont)?.familyName == "Courier New")
        #expect(string.contains("let x = 1\nlet y = 2\n"))

        let index = (string as NSString).range(of: "Value").location
        let table = try #require(TableModel.table(at: index, in: text))
        #expect(table.rows == 3 && table.columns == 2)
        #expect(table.orderedCells.map(\.content.string) == ["Name", "Value", "a", "1", "b", "2"])
        #expect(string.hasSuffix("Last."))
    }

    @Test func writesGitHubFlavoredMarkdown() {
        let text = NSMutableAttributedString()
        func add(_ string: String, _ style: NamedStyle = .normal, _ change: ([NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] = { $0 }) {
            text.append(NSAttributedString(string: string, attributes: change(style.attributes())))
        }
        add("Title words\n", .title)
        add("Section\n", .heading2)
        add("Plain, ")
        add("bold", .normal) { CharacterFormatting.apply(CharacterFormatting.setBold(true), to: $0) }
        add(" and ")
        add("both ", .normal) { CharacterFormatting.apply(CharacterFormatting.setItalic(true), to: CharacterFormatting.apply(CharacterFormatting.setBold(true), to: $0)) }
        add("words with *stars*, ")
        add("a link", .normal) { var a = $0; a[.link] = URL(string: "https://example.com/a b")!; return a }
        add(".\n")
        let bullets = ListItem(listID: "b", preset: .discCircleSquare)
        add("Item\n") { ParagraphFormatting.apply(ParagraphFormatting.setList(bullets), to: $0) }
        add("Deeper\n") { ParagraphFormatting.apply(ParagraphFormatting.setList(bullets.with(level: 1)), to: $0) }
        let checks = ListItem(listID: "c", preset: .checkbox)
        add("Done\n") { ParagraphFormatting.apply(ParagraphFormatting.setList(checks.with(checked: true)), to: $0) }
        add("1. Not a list\n")
        let markdown = MarkdownWriter.markdown(text)
        #expect(markdown.contains("# Title words\n"))
        #expect(markdown.contains("## Section\n"))
        #expect(markdown.contains("Plain, **bold** and ***both*** words with \\*stars\\*, [a link](https://example.com/a%20b).\n"))
        #expect(markdown.contains("- Item\n    - Deeper\n"))
        #expect(markdown.contains("- [x] Done\n"))
        #expect(markdown.contains("1\\. Not a list\n"))
    }

    @Test func roundTripsThroughMarkdown() throws {
        let original = try MarkdownReader.read(Data(Self.sample.utf8))
        let written = MarkdownWriter.markdown(original.text)
        let reread = try MarkdownReader.read(Data(written.utf8))
        #expect(reread.text.string == original.text.string)
        #expect((paragraph(reread.text, containing: "nested")[.pdListItem] as? ListItem)?.level == 1)
        #expect((paragraph(reread.text, containing: "done task")[.pdListItem] as? ListItem)?.isChecked == true)
        #expect(CharacterFormatting.isBold(paragraph(reread.text, containing: "bold")))
        let index = (reread.text.string as NSString).range(of: "Value").location
        #expect(TableModel.table(at: index, in: reread.text)?.rows == 3)
    }

    @Test func picturesSurviveWhenEmbeddedAndWarnWhenLinked() throws {
        let png = EpubTests().imagePNG()
        let text = NSMutableAttributedString(string: "Look: ", attributes: NamedStyle.normal.attributes())
        var image = NamedStyle.normal.attributes()
        image[.attachment] = ImageAttachments.make(data: png, size: CGSize(width: 8, height: 4))
        text.append(NSAttributedString(string: "\u{FFFC}", attributes: image))
        let markdown = MarkdownWriter.markdown(text)
        #expect(markdown.contains("Look: ![][image1]") && markdown.contains("[image1]: <data:image/png;base64,"))
        let reread = try MarkdownReader.read(Data(markdown.utf8))
        #expect(reread.text.string == "Look: \u{FFFC}" && reread.warnings.isEmpty)
        #expect(reread.text.attribute(.attachment, at: 6, effectiveRange: nil) is NSTextAttachment)
        let linked = try MarkdownReader.read(Data("A ![diagram](images/diagram.png) here.".utf8))
        #expect(linked.text.string == "A diagram here." && linked.warnings.contains(.images))
    }

    @Test func formatIsRecognized() {
        #expect(DocumentFormat(typeName: "md") == .markdown)
        #expect(DocumentFormat(typeName: "net.daringfireball.markdown") == .markdown)
        #expect(DocumentFormat(typeName: "markdown") == .markdown)
        #expect(!DocumentFormat.markdown.keepsReviewMarkup)
    }
}
