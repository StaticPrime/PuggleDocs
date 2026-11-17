import AppKit

/// Lossless serialization of editor text (including PuggleDocs attributes) for copy and paste
/// between PuggleDocs windows.
public enum AttributedArchive {
    public static let pasteboardTypeIdentifier = "com.pugglesoft.puggledocs.rich-text"
    /// Carries image display sizes through archiving (attachment bounds are not archived).
    static let imageSizeKey = NSAttributedString.Key("PuggleDocs.archivedImageSize")

    static var allowedClasses: [AnyClass] {
        [NSAttributedString.self, NSMutableAttributedString.self, NSString.self, NSNumber.self, NSDictionary.self,
         NSArray.self, NSURL.self, NSFont.self, NSColor.self, NSParagraphStyle.self, NSMutableParagraphStyle.self,
         NSTextTab.self, NSTextList.self, NSShadow.self, ListItem.self, RequestedFont.self, NSTextAttachment.self,
         FileWrapper.self, NSData.self, NSValue.self, NSTextTable.self, NSTextTableBlock.self, NSTextBlock.self,
         SuggestionMark.self, NSDate.self]
    }

    public static func archive(_ text: NSAttributedString) -> Data? {
        // Replace image attachments with plain copies: the drawing cell is not meant to be archived.
        let copy = NSMutableAttributedString(attributedString: text)
        copy.enumerateAttribute(.attachment, in: NSRange(location: 0, length: copy.length), options: []) { value, range, _ in
            guard let attachment = value as? NSTextAttachment, let info = ImageAttachments.info(attachment) else { return }
            let plain = NSTextAttachment(data: info.data, ofType: info.type.identifier)
            copy.addAttribute(.attachment, value: plain, range: range)
            copy.addAttribute(imageSizeKey, value: NSValue(size: info.size), range: range)
        }
        return try? NSKeyedArchiver.archivedData(withRootObject: copy, requiringSecureCoding: true)
    }

    public static func unarchive(_ data: Data) -> NSAttributedString? {
        guard let text = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: allowedClasses, from: data) as? NSAttributedString else { return nil }
        let result = NSMutableAttributedString(attributedString: text)
        result.enumerateAttribute(.attachment, in: NSRange(location: 0, length: result.length), options: []) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            if let size = (result.attribute(imageSizeKey, at: range.location, effectiveRange: nil) as? NSValue)?.sizeValue {
                attachment.bounds = CGRect(origin: .zero, size: size)
            }
            ImageAttachments.installCell(attachment)
        }
        result.removeAttribute(imageSizeKey, range: NSRange(location: 0, length: result.length))
        return result
    }
}
