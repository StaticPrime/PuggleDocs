import AppKit

/// Writes an EPUB 3 book: the document as one XHTML file, a table of contents from its headings,
/// its pictures as separate files, and an NCX table of contents for older readers.
public enum EpubWriter {
    public static func write(_ content: DocumentContent, title: String, language: String = Locale.current.language.languageCode?.identifier ?? "en",
                             identifier: String = UUID().uuidString, date: Date = Date()) -> Data {
        // Comments stay out of books; suggestions are shown accepted.
        let text = Suggestions.accepted(content.text)
        var options = HtmlWriter.Options()
        let book = HtmlWriter.BookParts()
        options.book = book
        let body = HtmlWriter.body(text, options: options)
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled document" : title

        var zip = ZipWriter(date: date)
        // The mimetype entry comes first, uncompressed, so readers can recognize the file.
        zip.add(path: "mimetype", data: Data("application/epub+zip".utf8), compress: false)
        zip.add(path: "META-INF/container.xml", data: Data(containerXML.utf8))
        zip.add(path: "OEBPS/content.opf", data: Data(packageXML(title: title, language: language, identifier: identifier, date: date, book: book).utf8))
        zip.add(path: "OEBPS/nav.xhtml", data: Data(navigationXHTML(title: title, language: language, book: book).utf8))
        zip.add(path: "OEBPS/toc.ncx", data: Data(ncxXML(title: title, identifier: identifier, book: book).utf8))
        zip.add(path: "OEBPS/style.css", data: Data(stylesheet(content.pageSetup).utf8))
        zip.add(path: "OEBPS/content.xhtml", data: Data(contentXHTML(title: title, language: language, body: body).utf8))
        for image in book.images {
            zip.add(path: "OEBPS/" + image.path, data: image.data, compress: false)
        }
        return zip.finish()
    }

    static let containerXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
    <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
    </container>
    """

    static func escape(_ text: String) -> String { DocxWriter.escape(text) }

    static func packageXML(title: String, language: String, identifier: String, date: Date, book: HtmlWriter.BookParts) -> String {
        let modified = ISO8601DateFormatter().string(from: date)
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"book-id\" xml:lang=\"\(escape(language))\">\n"
        xml += "<metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">\n"
        xml += "<dc:identifier id=\"book-id\">urn:uuid:\(escape(identifier))</dc:identifier>\n"
        xml += "<dc:title>\(escape(title))</dc:title>\n<dc:language>\(escape(language))</dc:language>\n"
        xml += "<meta property=\"dcterms:modified\">\(modified)</meta>\n</metadata>\n<manifest>\n"
        xml += "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\n"
        xml += "<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>\n"
        xml += "<item id=\"css\" href=\"style.css\" media-type=\"text/css\"/>\n"
        xml += "<item id=\"content\" href=\"content.xhtml\" media-type=\"application/xhtml+xml\"/>\n"
        for (index, image) in book.images.enumerated() {
            xml += "<item id=\"image\(index + 1)\" href=\"\(image.path)\" media-type=\"\(image.type)\"/>\n"
        }
        xml += "</manifest>\n<spine toc=\"ncx\">\n<itemref idref=\"content\"/>\n</spine>\n</package>\n"
        return xml
    }

    /// Headings nested by level; a document without headings gets one entry for its start.
    static func navigationXHTML(title: String, language: String, book: HtmlWriter.BookParts) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE html>\n"
        xml += "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\" lang=\"\(escape(language))\" xml:lang=\"\(escape(language))\">\n"
        xml += "<head><meta charset=\"utf-8\"/><title>\(escape(title))</title></head>\n<body>\n<nav epub:type=\"toc\" id=\"toc\">\n<h1>Contents</h1>\n"
        let entries = book.headings.isEmpty ? [(id: "", level: 1, title: title)] : book.headings
        var depth: [Int] = []
        for entry in entries {
            let link = "<a href=\"content.xhtml\(entry.id.isEmpty ? "" : "#" + entry.id)\">\(escape(entry.title))</a>"
            if depth.isEmpty {
                xml += "<ol>\n<li>" + link
                depth.append(entry.level)
            } else if entry.level > depth.last! {
                xml += "\n<ol>\n<li>" + link
                depth.append(entry.level)
            } else {
                while depth.count > 1, entry.level < depth.last! {
                    xml += "</li>\n</ol>\n"
                    depth.removeLast()
                }
                xml += "</li>\n<li>" + link
            }
        }
        while !depth.isEmpty {
            xml += "</li>\n</ol>\n"
            depth.removeLast()
        }
        xml += "</nav>\n</body>\n</html>\n"
        return xml
    }

    static func ncxXML(title: String, identifier: String, book: HtmlWriter.BookParts) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<ncx xmlns=\"http://www.daisy.org/z3986/2005/ncx/\" version=\"2005-1\">\n"
        xml += "<head><meta name=\"dtb:uid\" content=\"urn:uuid:\(escape(identifier))\"/></head>\n"
        xml += "<docTitle><text>\(escape(title))</text></docTitle>\n<navMap>\n"
        let entries = book.headings.isEmpty ? [(id: "", level: 1, title: title)] : book.headings
        for (index, entry) in entries.enumerated() {
            xml += "<navPoint id=\"point\(index + 1)\" playOrder=\"\(index + 1)\"><navLabel><text>\(escape(entry.title))</text></navLabel>"
            xml += "<content src=\"content.xhtml\(entry.id.isEmpty ? "" : "#" + entry.id)\"/></navPoint>\n"
        }
        xml += "</navMap>\n</ncx>\n"
        return xml
    }

    static func contentXHTML(title: String, language: String, body: String) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE html>\n"
        xml += "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\" lang=\"\(escape(language))\" xml:lang=\"\(escape(language))\">\n"
        xml += "<head><meta charset=\"utf-8\"/><title>\(escape(title))</title><link rel=\"stylesheet\" type=\"text/css\" href=\"style.css\"/></head>\n"
        xml += "<body>\n<div class=\"pd-doc\">\n\(body)</div>\n</body>\n</html>\n"
        return xml
    }

    /// Reading systems choose the page size, so only the text styling carries over.
    static func stylesheet(_ setup: PageSetup) -> String {
        let normal = NamedStyle.normal.definition
        return """
        body { margin: 0 4%; }
        .pd-doc { font-family: \(HtmlWriter.cssFamily(normal.fontFamily)); line-height: \(normal.lineSpacing); }
        .pd-doc p, .pd-doc h1, .pd-doc h2, .pd-doc h3, .pd-doc h4, .pd-doc h5, .pd-doc h6, .pd-doc li { margin: 0; font-weight: normal; }
        .pd-doc ul, .pd-doc ol { margin: 0; padding-left: 0; }
        .pd-doc img { max-width: 100%; height: auto; }
        .pd-doc table { border-collapse: collapse; width: 100%; }
        hr { page-break-after: always; border: none; }

        """
    }
}
