import AppKit
import Testing
@testable import PuggleDocsKit

/// "The quick brown fox.\nJumps high." with an insertion, a deletion, a replacement and an inserted paragraph break.
func suggestedText() -> NSAttributedString {
    let text = NSMutableAttributedString(string: "The very quick brown red fox.\nJumps over high.", attributes: DocumentDefaults.typingAttributes)
    let date = Date(timeIntervalSince1970: 1_790_000_000)
    let string = text.string as NSString
    let insertion = SuggestionMark(kind: .insertion, author: "Ana Lopez", date: date)
    let deletion = SuggestionMark(kind: .deletion, author: "Ben Carter", date: date.addingTimeInterval(60))
    let replacement = SuggestionMark(kind: .deletion, author: "Ana Lopez", date: date.addingTimeInterval(120))
    let paragraph = SuggestionMark(kind: .insertion, author: "Chen Wu", date: date.addingTimeInterval(180))
    text.addAttribute(.pdSuggestion, value: insertion, range: string.range(of: "very "))
    text.addAttribute(.pdSuggestion, value: deletion, range: string.range(of: "over "))
    text.addAttribute(.pdSuggestion, value: replacement, range: string.range(of: "brown "))
    text.addAttribute(.pdSuggestion, value: replacement.with(kind: .insertion), range: string.range(of: "red "))
    text.addAttribute(.pdSuggestion, value: paragraph, range: string.range(of: "\n"))
    return text
}

/// What each suggestion adds and removes, by author, in order.
func suggestionShapes(_ text: NSAttributedString) -> [String] {
    Suggestions.summaries(in: text).map { "\($0.author): +\($0.inserted.debugDescription) -\($0.deleted.debugDescription)" }
}

@MainActor
struct SuggestionTests {
    @Test func summariesGroupReplacements() {
        let summaries = Suggestions.summaries(in: suggestedText())
        #expect(summaries.count == 4)
        #expect(suggestionShapes(suggestedText()) == [
            "Ana Lopez: +\"very \" -\"\"", "Ana Lopez: +\"red \" -\"brown \"", "Chen Wu: +\"\\n\" -\"\"", "Ben Carter: +\"\" -\"over \"",
        ])
        #expect(summaries[1].isReplacement)
    }

    @Test func acceptingAndRejecting() {
        let text = suggestedText()
        let all = NSRange(location: 0, length: text.length)
        #expect(Suggestions.resolved(text, in: all, accept: true).string == "The very quick red fox.\nJumps high.")
        #expect(Suggestions.resolved(text, in: all, accept: false).string == "The quick brown fox.Jumps over high.")
        let replacement = Suggestions.summaries(in: text)[1].id
        let partly = Suggestions.resolved(text, in: all, ids: [replacement], accept: true)
        #expect(partly.string == "The very quick red fox.\nJumps over high.")
        #expect(Suggestions.summaries(in: partly).count == 3)
        #expect(!Suggestions.hasSuggestions(Suggestions.accepted(text)))
    }

    @Test func marksArchiveForCopyAndPaste() throws {
        let data = try #require(AttributedArchive.archive(suggestedText()))
        let text = try #require(AttributedArchive.unarchive(data))
        #expect(suggestionShapes(text) == suggestionShapes(suggestedText()))
    }

    @Test func docxKeepsSuggestionsAsTrackedChanges() throws {
        let original = suggestedText()
        let data = try DocxWriter.write(DocumentContent(text: original))
        let zip = try ZipReader(data: data)
        let document = String(decoding: try #require(try zip.read("word/document.xml")), as: UTF8.self)
        #expect(XMLParser(data: Data(document.utf8)).parse())
        #expect(document.contains("<w:delText xml:space=\"preserve\">over </w:delText>"))
        #expect(document.contains("<w:rPr><w:ins "))
        let result = try DocxReader.read(data)
        #expect(!result.warnings.contains(.trackedChanges))
        #expect(result.text.string == original.string)
        #expect(suggestionShapes(result.text) == suggestionShapes(original))
    }

    @Test func odtKeepsSuggestionsAsTrackedChanges() throws {
        // ODF keeps paragraph breaks out of tracked changes here, so leave that one out.
        let original = NSMutableAttributedString(attributedString: suggestedText())
        original.removeAttribute(.pdSuggestion, range: (original.string as NSString).range(of: "\n"))
        let data = try OdtWriter.write(DocumentContent(text: original))
        let zip = try ZipReader(data: data)
        let content = try #require(try zip.read("content.xml"))
        #expect(XMLParser(data: content).parse())
        let result = try OdtReader.read(data)
        #expect(!result.warnings.contains(.trackedChanges))
        #expect(result.text.string == original.string)
        #expect(suggestionShapes(result.text) == suggestionShapes(original))
    }

    @Test func htmlKeepsSuggestionsAsInsAndDel() throws {
        let original = NSMutableAttributedString(attributedString: suggestedText())
        original.removeAttribute(.pdSuggestion, range: (original.string as NSString).range(of: "\n"))
        let html = HtmlWriter.html(DocumentContent(text: original))
        #expect(html.contains("<del data-pd-suggestion="))
        let result = try HtmlReader.read(Data(html.utf8))
        #expect(result.text.string == original.string)
        #expect(suggestionShapes(result.text) == suggestionShapes(original))
        // Suggestions are not formatting.
        let over = (result.text.string as NSString).range(of: "over").location
        #expect(result.text.attribute(.strikethroughStyle, at: over, effectiveRange: nil) == nil)
    }

    @Test func otherFormatsKeepTheAcceptedText() throws {
        let data = try DocumentIO.write(DocumentContent(text: suggestedText()), format: .plainText)
        #expect(String(decoding: data, as: UTF8.self).hasPrefix("The very quick red fox.\nJumps high."))
        let rtf = try DocumentIO.read(try DocumentIO.write(DocumentContent(text: suggestedText()), format: .rtf), format: .rtf)
        #expect(rtf.text.string == "The very quick red fox.\nJumps high.")
        #expect(!Suggestions.hasSuggestions(rtf.text))
    }

    @Test func wordRevisionsFromOtherAppsBecomeSuggestions() throws {
        let xml = """
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\
        <w:p><w:r><w:t xml:space="preserve">Keep </w:t></w:r>\
        <w:del w:id="1" w:author="Kim" w:date="2026-01-02T03:04:05Z"><w:r><w:delText>old</w:delText></w:r></w:del>\
        <w:ins w:id="2" w:author="Kim" w:date="2026-01-02T03:04:05Z"><w:r><w:t>new</w:t></w:r></w:ins>\
        <w:ins w:id="3" w:author="Lee" w:date="2026-01-03T00:00:00"><w:r><w:t> more</w:t></w:r></w:ins></w:p>\
        </w:body></w:document>
        """
        let data = try minimalDocx(document: xml, comments: "<w:comments xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"/>")
        let result = try DocxReader.read(data)
        #expect(result.text.string == "Keep oldnew more")
        #expect(suggestionShapes(result.text) == ["Kim: +\"new\" -\"old\"", "Lee: +\" more\" -\"\""])
    }
}
