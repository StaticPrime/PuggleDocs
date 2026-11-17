import AppKit
import Testing
@testable import PuggleDocsKit

@MainActor
struct EpubTests {
    func book() -> DocumentContent {
        let text = NSMutableAttributedString()
        func add(_ string: String, _ style: NamedStyle = .normal) { text.append(NSAttributedString(string: string, attributes: style.attributes())) }
        add("Chapter one\n", .heading1)
        add("Opening words & more.\n")
        add("A section\n", .heading2)
        add("Picture: ")
        var image = NamedStyle.normal.attributes()
        image[.attachment] = ImageAttachments.make(data: imagePNG(), size: CGSize(width: 40, height: 20))
        text.append(NSAttributedString(string: "\u{FFFC}", attributes: image))
        add("\nChapter two\n", .heading1)
        add("The end.")
        let suggestion = SuggestionMark(kind: .insertion, author: "Ana", date: Date())
        text.addAttribute(.pdSuggestion, value: suggestion, range: (text.string as NSString).range(of: "The end."))
        return DocumentContent(text: text)
    }

    func imagePNG() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    @Test func writesAValidEpubPackage() throws {
        let data = EpubWriter.write(book(), title: "My Book", language: "en", identifier: "1234", date: Date(timeIntervalSince1970: 1_790_000_000))
        // The first entry is "mimetype", stored without compression.
        #expect(String(decoding: data[30..<38], as: UTF8.self) == "mimetype")
        #expect(data[8] == 0 && data[9] == 0)
        let zip = try ZipReader(data: data)
        #expect(String(decoding: try #require(try zip.read("mimetype")), as: UTF8.self) == "application/epub+zip")
        for path in ["META-INF/container.xml", "OEBPS/content.opf", "OEBPS/nav.xhtml", "OEBPS/toc.ncx", "OEBPS/content.xhtml"] {
            let part = try #require(try zip.read(path), "\(path) is missing")
            #expect(XMLParser(data: part).parse(), "\(path) is not well-formed")
        }
        let opf = String(decoding: try #require(try zip.read("OEBPS/content.opf")), as: UTF8.self)
        #expect(opf.contains("<dc:title>My Book</dc:title>") && opf.contains("properties=\"nav\"") && opf.contains("images/image1.png"))
        #expect(try zip.read("OEBPS/images/image1.png") != nil)
        let nav = String(decoding: try #require(try zip.read("OEBPS/nav.xhtml")), as: UTF8.self)
        #expect(nav.contains("<a href=\"content.xhtml#heading-1\">Chapter one</a>\n<ol>\n<li><a href=\"content.xhtml#heading-2\">A section</a>"))
        #expect(nav.contains("content.xhtml#heading-3\">Chapter two</a>"))
        let content = String(decoding: try #require(try zip.read("OEBPS/content.xhtml")), as: UTF8.self)
        #expect(content.contains("id=\"heading-1\"") && content.contains("src=\"images/image1.png\""))
        #expect(content.contains("Opening words &amp; more."))
        // Suggestions read as accepted text, without review markup.
        #expect(content.contains("The end.") && !content.contains("data-pd-suggestion"))
    }
}
