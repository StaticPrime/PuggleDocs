import AppKit

/// RTF through AppKit's reader/writer, with list conversion.
public enum RichTextCodec {
    public static func read(_ data: Data) throws -> DocumentContent {
        var documentAttributes: NSDictionary?
        let extracted = RTFPictures.extract(from: data)
        let text: NSAttributedString
        do {
            text = try NSAttributedString(data: extracted.rtf, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                          documentAttributes: &documentAttributes)
        } catch {
            throw DocumentIOError.unreadable("The file is not valid Rich Text.")
        }
        let storage = NSMutableAttributedString(attributedString: text)
        RTFPictures.restore(extracted.pictures, in: storage)
        CocoaListBridge.importLists(storage)
        DocumentIO.normalizeImported(storage)
        return DocumentContent(text: storage, pageSetup: pageSetup(from: documentAttributes as? [NSAttributedString.DocumentAttributeKey: Any]),
                               warnings: extracted.unsupported > 0 ? [.images] : [])
    }

    public static func write(_ content: DocumentContent) throws -> Data {
        var attributes = documentAttributes(for: content.pageSetup)
        attributes[.documentType] = NSAttributedString.DocumentType.rtf
        guard let data = rtfData(content.text, documentAttributes: attributes) else {
            throw DocumentIOError.unwritable("The text could not be converted to Rich Text.")
        }
        return data
    }

    /// RTF for editor text, with real lists and embedded pictures (used for files and the clipboard).
    public static func rtfData(_ text: NSAttributedString,
                               documentAttributes: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: NSAttributedString.DocumentType.rtf]) -> Data? {
        let exported = NSMutableAttributedString(attributedString: CocoaListBridge.strippingPrivateAttributes(CocoaListBridge.exportLists(text)))
        let groups = RTFPictures.replaceAttachmentsWithTokens(in: exported)
        var attributes = documentAttributes
        attributes[.documentType] = NSAttributedString.DocumentType.rtf
        guard let data = try? exported.data(from: NSRange(location: 0, length: exported.length), documentAttributes: attributes) else { return nil }
        return RTFPictures.insertGroups(groups, into: data)
    }

    static func pageSetup(from attributes: [NSAttributedString.DocumentAttributeKey: Any]?) -> PageSetup {
        guard let attributes, let size = (attributes[.paperSize] as? NSValue)?.sizeValue, size.width > 72, size.height > 72 else {
            return .localeDefault
        }
        func margin(_ key: NSAttributedString.DocumentAttributeKey) -> CGFloat {
            (attributes[key] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 72
        }
        var setup = PageSetup.from(pageSize: size, margins: PageMargins(top: margin(.topMargin), left: margin(.leftMargin),
                                                                        bottom: margin(.bottomMargin), right: margin(.rightMargin)))
        if let color = (attributes[.backgroundColor] as? NSColor)?.hexString, color != "FFFFFF" { setup.pageColorHex = color }
        return setup
    }

    static func documentAttributes(for setup: PageSetup) -> [NSAttributedString.DocumentAttributeKey: Any] {
        var attributes: [NSAttributedString.DocumentAttributeKey: Any] = [
            .paperSize: NSValue(size: setup.pageSize),
            .topMargin: setup.margins.top,
            .leftMargin: setup.margins.left,
            .bottomMargin: setup.margins.bottom,
            .rightMargin: setup.margins.right,
        ]
        if setup.pageColorHex != nil { attributes[.backgroundColor] = setup.pageColor }
        return attributes
    }
}

/// Plain text with encoding detection; lists are written as text markers.
public enum PlainTextCodec {
    public static func read(_ data: Data) -> DocumentContent {
        var string = decode(data)
        string = string.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let text = NSAttributedString(string: string, attributes: DocumentDefaults.typingAttributes)
        return DocumentContent(text: text)
    }

    static func decode(_ data: Data) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]), let string = String(data: data.dropFirst(3), encoding: .utf8) { return string }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let string = String(data: data, encoding: .utf16) { return string }
        if let string = String(data: data, encoding: .utf8) { return string }
        var converted: NSString?
        var lossy = ObjCBool(false)
        let encoding = NSString.stringEncoding(for: data, encodingOptions: [.allowLossyKey: false],
                                               convertedString: &converted, usedLossyConversion: &lossy)
        if encoding != 0, let converted { return converted as String }
        return String(decoding: data, as: UTF8.self)
    }

    public static func write(_ text: NSAttributedString) -> Data {
        plainString(from: text).data(using: .utf8) ?? Data()
    }

    public static func plainString(from text: NSAttributedString) -> String {
        let string = text.string as NSString
        var markers: [Int: (String, Int)] = [:]
        for entry in ListNumbering.entries(in: text) {
            let marker = entry.item.kind == .checklist ? (entry.item.isChecked ? "[x]" : "[ ]") : entry.marker
            markers[entry.paragraphRange.location] = (marker, entry.item.level)
        }
        var output = ""
        var location = 0
        while location < string.length {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            if let (marker, level) = markers[paragraph.location] {
                output += String(repeating: "    ", count: level) + marker + " "
            }
            output += string.substring(with: paragraph)
            location = NSMaxRange(paragraph)
        }
        return output.replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
            .replacingOccurrences(of: "\u{000C}", with: "\n")
    }
}
