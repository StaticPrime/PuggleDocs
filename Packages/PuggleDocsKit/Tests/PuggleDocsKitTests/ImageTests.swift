import AppKit
import Testing
import UniformTypeIdentifiers
@testable import PuggleDocsKit

/// A small solid-color PNG for tests.
func testPNG(width: Int = 40, height: Int = 20, color: NSColor = .systemTeal) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    color.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// Sample text with an inline image between two words.
func documentWithImage(size: CGSize = CGSize(width: 120, height: 60)) -> NSAttributedString {
    let text = NSMutableAttributedString(string: "Before ", attributes: DocumentDefaults.typingAttributes)
    let attachment = ImageAttachments.make(data: testPNG(), size: size)!
    var attributes = DocumentDefaults.typingAttributes
    attributes[.attachment] = attachment
    text.append(NSAttributedString(string: "\u{FFFC}", attributes: attributes))
    text.append(NSAttributedString(string: " after", attributes: DocumentDefaults.typingAttributes))
    return text
}

func imageInfo(in text: NSAttributedString) -> ImageAttachments.Info? {
    var result: ImageAttachments.Info?
    text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length), options: []) { value, _, stop in
        if let attachment = value as? NSTextAttachment { result = ImageAttachments.info(attachment); stop.pointee = true }
    }
    return result
}

@MainActor
struct ImageTests {
    @Test func makeAndInspectAttachment() throws {
        let data = testPNG()
        let attachment = try #require(ImageAttachments.make(data: data, size: CGSize(width: 80, height: 40)))
        #expect(attachment.attachmentCell is ImageAttachmentCell)
        let info = try #require(ImageAttachments.info(attachment))
        #expect(info.type == .png && info.size == CGSize(width: 80, height: 40) && info.data == data)
        let wide = try #require(ImageAttachments.make(data: testPNG(width: 2000, height: 1000), maxWidth: 400))
        #expect(wide.bounds.size == CGSize(width: 400, height: 200))
        #expect(ImageAttachments.sniff(data) == .png)
    }

    @Test func archiveKeepsImages() throws {
        let data = try #require(AttributedArchive.archive(documentWithImage()))
        let restored = try #require(AttributedArchive.unarchive(data))
        let info = try #require(imageInfo(in: restored))
        #expect(info.size == CGSize(width: 120, height: 60))
        #expect(restored.string == "Before \u{FFFC} after")
    }

    @Test func docxKeepsImages() throws {
        let content = DocumentContent(text: documentWithImage(), pageSetup: .letter)
        let data = try DocxWriter.write(content)
        let zip = try ZipReader(data: data)
        #expect(zip.entries.keys.contains { $0.hasPrefix("word/media/") })
        let result = try DocxReader.read(data)
        #expect(result.warnings.isEmpty)
        #expect(result.text.string == "Before \u{FFFC} after")
        let info = try #require(imageInfo(in: result.text))
        #expect(abs(info.size.width - 120) < 0.5 && abs(info.size.height - 60) < 0.5)
        #expect(info.type == .png)
    }

    @Test func odtKeepsImages() throws {
        let data = try OdtWriter.write(DocumentContent(text: documentWithImage(), pageSetup: .letter))
        let zip = try ZipReader(data: data)
        #expect(zip.entries.keys.contains { $0.hasPrefix("Pictures/") })
        let result = try OdtReader.read(data)
        #expect(result.warnings.isEmpty)
        #expect(result.text.string == "Before \u{FFFC} after")
        let info = try #require(imageInfo(in: result.text))
        #expect(abs(info.size.width - 120) < 0.5 && abs(info.size.height - 60) < 0.5)
    }

    @Test func rtfKeepsImages() throws {
        let data = try RichTextCodec.write(DocumentContent(text: documentWithImage(), pageSetup: .letter))
        #expect(String(decoding: data, as: UTF8.self).contains("\\pngblip"))
        let result = try RichTextCodec.read(data)
        #expect(result.text.string == "Before \u{FFFC} after")
        let info = try #require(imageInfo(in: result.text))
        #expect(abs(info.size.width - 120) < 0.5 && abs(info.size.height - 60) < 0.5)
    }

    @Test func rtfSkipsMetafilePictures() throws {
        let rtf = "{\\rtf1\\ansi{\\fonttbl{\\f0 Arial;}}\\f0 A{\\pict\\wmetafile8\\picw10\\pich10 0102}B\\par}"
        let result = try RichTextCodec.read(Data(rtf.utf8))
        #expect(result.text.string.trimmingCharacters(in: .newlines) == "AB")
        #expect(result.warnings.contains(.images))
    }

    @Test func htmlKeepsImages() throws {
        let html = HtmlWriter.html(DocumentContent(text: documentWithImage()))
        #expect(html.contains("data:image/png;base64,"))
        let result = try HtmlReader.read(Data(html.utf8))
        #expect(result.warnings.isEmpty)
        #expect(result.text.string == "Before \u{FFFC} after")
        let info = try #require(imageInfo(in: result.text))
        #expect(abs(info.size.width - 120) < 0.5 && abs(info.size.height - 60) < 0.5)
    }
}
