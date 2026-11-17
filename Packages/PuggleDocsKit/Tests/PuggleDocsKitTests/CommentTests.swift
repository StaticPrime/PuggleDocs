import AppKit
import Testing
@testable import PuggleDocsKit

/// Three paragraphs with a reply thread, a resolved thread across a paragraph break and a comment on the last word.
func commentedContent() -> DocumentContent {
    let text = NSMutableAttributedString(string: "Intro paragraph here.\nSecond paragraph spans.\nLast word",
                                         attributes: DocumentDefaults.typingAttributes)
    let date = Date(timeIntervalSince1970: 1_790_000_000)
    let reply = CommentReply(author: "Sam Lee", date: date.addingTimeInterval(60), text: "Agreed, & fixed <soon>.")
    let first = CommentThread(author: "Ana Lopez", date: date, text: "Is this the right word?", replies: [reply])
    let spanning = CommentThread(author: "Ana Lopez", date: date, text: "Merge these\ntwo lines?", resolved: true)
    let last = CommentThread(author: "Sam Lee", date: date, text: "Ends here")
    let string = text.string as NSString
    CommentAnchors.add(first.id, to: text, range: string.range(of: "paragraph"))
    CommentAnchors.add(spanning.id, to: text, range: NSUnionRange(string.range(of: "here."), string.range(of: "Second")))
    CommentAnchors.add(last.id, to: text, range: string.range(of: "word"))
    return DocumentContent(text: text, comments: [first, spanning, last])
}

/// Each thread's anchored text, keyed by the comment text.
func anchoredText(_ content: DocumentContent) -> [String: String] {
    let ranges = CommentAnchors.ranges(in: content.text)
    var result: [String: String] = [:]
    for thread in content.comments {
        guard let range = ranges[thread.id] else { continue }
        result[thread.text] = (content.text.string as NSString).substring(with: range)
    }
    return result
}

@MainActor
struct CommentTests {
    func expectSameComments(_ result: DocumentContent, _ original: DocumentContent) {
        #expect(result.text.string == original.text.string)
        #expect(result.comments.count == original.comments.count)
        #expect(anchoredText(result) == anchoredText(original))
        for thread in original.comments {
            guard let match = result.comments.first(where: { $0.text == thread.text }) else {
                Issue.record("Missing thread \(thread.text)")
                continue
            }
            #expect(match.author == thread.author)
            #expect(abs(match.date.timeIntervalSince(thread.date)) < 1)
            #expect(match.resolved == thread.resolved)
            #expect(match.replies.map(\.text) == thread.replies.map(\.text))
            #expect(match.replies.map(\.author) == thread.replies.map(\.author))
        }
    }

    @Test func anchorsMergeAndRemove() {
        let text = NSMutableAttributedString(string: "abcdef")
        CommentAnchors.add("b", to: text, range: NSRange(location: 1, length: 3))
        CommentAnchors.add("a", to: text, range: NSRange(location: 2, length: 3))
        #expect(text.attribute(.pdComments, at: 2, effectiveRange: nil) as? String == "a,b")
        #expect(CommentAnchors.ranges(in: text) == ["a": NSRange(location: 2, length: 3), "b": NSRange(location: 1, length: 3)])
        CommentAnchors.remove("b", from: text)
        #expect(CommentAnchors.ranges(in: text) == ["a": NSRange(location: 2, length: 3)])
        #expect(text.attribute(.pdComments, at: 1, effectiveRange: nil) == nil)
        #expect(CommentThread.initials("Ana Lopez") == "AL")
        #expect(CommentThread.initials("") == "?")
    }

    @Test func docxRoundTripsThreadsRepliesAndResolvedState() throws {
        let original = commentedContent()
        let data = try DocxWriter.write(original)
        let zip = try ZipReader(data: data)
        #expect(zip.contains("word/comments.xml") && zip.contains("word/commentsExtended.xml"))
        for path in zip.entries.keys { #expect(XMLParser(data: try #require(try zip.read(path))).parse(), "\(path)") }
        let document = String(decoding: try #require(try zip.read("word/document.xml")), as: UTF8.self)
        #expect(document.components(separatedBy: "<w:commentRangeStart").count - 1 == 4)
        #expect(document.components(separatedBy: "<w:commentRangeEnd").count - 1 == 4)
        let result = try DocxReader.read(data)
        #expect(!result.warnings.contains(.comments))
        expectSameComments(result, original)
    }

    @Test func docxPointCommentAnchorsToPreviousCharacter() throws {
        let xml = """
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\
        <w:p><w:r><w:t>Hello</w:t></w:r><w:r><w:commentReference w:id="7"/></w:r><w:r><w:t> world</w:t></w:r></w:p>\
        </w:body></w:document>
        """
        let comments = """
        <w:comments xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
        <w:comment w:id="7" w:author="Kim" w:date="2026-01-02T03:04:05Z"><w:p><w:r><w:t>Point</w:t></w:r></w:p></w:comment>\
        </w:comments>
        """
        let data = try minimalDocx(document: xml, comments: comments)
        let result = try DocxReader.read(data)
        #expect(result.comments.map(\.text) == ["Point"])
        #expect(anchoredText(result) == ["Point": "o"])
    }

    @Test func odtRoundTripsAnnotationsRepliesAndResolvedState() throws {
        let original = commentedContent()
        let data = try OdtWriter.write(original)
        let zip = try ZipReader(data: data)
        let content = try #require(try zip.read("content.xml"))
        #expect(XMLParser(data: content).parse())
        let xml = String(decoding: content, as: UTF8.self)
        #expect(xml.components(separatedBy: "<office:annotation ").count - 1 == 4)
        #expect(xml.components(separatedBy: "<office:annotation-end").count - 1 == 3)
        let result = try OdtReader.read(data)
        #expect(!result.warnings.contains(.comments))
        expectSameComments(result, original)
    }

    @Test func htmlRoundTripsTheCommentList() throws {
        let original = commentedContent()
        let html = HtmlWriter.html(original)
        #expect(html.contains("data-pd-comments-list"))
        #expect(html.contains("Is this the right word?"))
        let result = try HtmlReader.read(Data(html.utf8))
        expectSameComments(result, original)
        // The highlight is presentation only and must not come back as a text background.
        #expect(result.text.attribute(.backgroundColor, at: 7, effectiveRange: nil) == nil)
        #expect(!result.text.string.contains("Comments"))
    }

    @Test func normalizeDropsUnknownAnchorsAndFillsGaps() {
        let text = NSMutableAttributedString(string: "one two three")
        CommentAnchors.add("a", to: text, range: NSRange(location: 0, length: 3))
        CommentAnchors.add("a", to: text, range: NSRange(location: 8, length: 5))
        CommentAnchors.add("zombie", to: text, range: NSRange(location: 4, length: 3))
        CommentAnchors.normalize(text, threads: [CommentThread(id: "a", author: "A", text: "x")])
        #expect(CommentAnchors.ranges(in: text) == ["a": NSRange(location: 0, length: 13)])
        var effective = NSRange()
        _ = text.attribute(.pdComments, at: 0, effectiveRange: &effective)
        #expect(effective == NSRange(location: 0, length: 13))
    }

    @Test func rangesFollowEdits() {
        let range = NSRange(location: 5, length: 5)
        // Typing before, at the start of, inside and at the end of the range.
        #expect(CommentAnchors.adjust(range, editedRange: NSRange(location: 1, length: 2), delta: 2) == NSRange(location: 7, length: 5))
        #expect(CommentAnchors.adjust(range, editedRange: NSRange(location: 5, length: 1), delta: 1) == NSRange(location: 6, length: 5))
        #expect(CommentAnchors.adjust(range, editedRange: NSRange(location: 7, length: 3), delta: 3) == NSRange(location: 5, length: 8))
        #expect(CommentAnchors.adjust(range, editedRange: NSRange(location: 10, length: 1), delta: 1) == range)
        // Deleting across the start, and deleting all of it.
        #expect(CommentAnchors.adjust(range, editedRange: NSRange(location: 3, length: 0), delta: -4) == NSRange(location: 3, length: 3))
        #expect(CommentAnchors.adjust(range, editedRange: NSRange(location: 5, length: 0), delta: -5) == NSRange(location: 5, length: 0))
        // Replacing part of it with longer text.
        #expect(CommentAnchors.adjust(range, editedRange: NSRange(location: 6, length: 4), delta: 2) == NSRange(location: 5, length: 7))
    }

    @Test func privateAttributesAreStrippedForCocoa() {
        let content = commentedContent()
        let stripped = CocoaListBridge.strippingPrivateAttributes(content.text)
        #expect(CommentAnchors.ranges(in: stripped).isEmpty)
    }
}

/// A bare-bones .docx with a body and a comments part.
func minimalDocx(document: String, comments: String) throws -> Data {
    var zip = ZipWriter(date: Date(timeIntervalSince1970: 1_790_000_000))
    zip.add(path: "[Content_Types].xml", data: Data("""
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
    <Default Extension="xml" ContentType="application/xml"/>\
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
    </Types>
    """.utf8))
    zip.add(path: "_rels/.rels", data: Data("""
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
    </Relationships>
    """.utf8))
    zip.add(path: "word/_rels/document.xml.rels", data: Data("""
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId9" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments" Target="comments.xml"/>\
    </Relationships>
    """.utf8))
    zip.add(path: "word/document.xml", data: Data(document.utf8))
    zip.add(path: "word/comments.xml", data: Data(comments.utf8))
    return zip.finish()
}
