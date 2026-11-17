import AppKit
import UniformTypeIdentifiers

/// Draws an inline image at its display size (stored in the attachment's `bounds`).
public final class ImageAttachmentCell: NSTextAttachmentCell {
    public let picture: NSImage

    public init(picture: NSImage) {
        self.picture = picture
        super.init(imageCell: picture)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var displaySize: NSSize {
        let size = attachment?.bounds.size ?? .zero
        return size.width > 0 && size.height > 0 ? size : picture.size
    }

    public override func cellSize() -> NSSize { displaySize }
    public override func cellBaselineOffset() -> NSPoint { .zero }
    public override func wantsToTrackMouse() -> Bool { false }

    public override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        picture.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                     hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
    }

    public override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int) {
        draw(withFrame: cellFrame, in: controlView)
    }

    public override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
    }
}

/// Creating and inspecting inline image attachments.
public enum ImageAttachments {
    public struct Info {
        public let data: Data
        public let type: UTType
        public let size: CGSize
    }

    /// Image types every target format understands; others are converted to PNG on export.
    public static let portableTypes: [UTType] = [.png, .jpeg, .gif]

    public static func make(data: Data, type: UTType? = nil, size: CGSize? = nil, maxWidth: CGFloat? = nil) -> NSTextAttachment? {
        guard let picture = NSImage(data: data), picture.size.width > 0, picture.size.height > 0 else { return nil }
        let resolvedType = type ?? sniff(data) ?? .png
        let attachment = NSTextAttachment(data: data, ofType: resolvedType.identifier)
        var displaySize = size.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil } ?? picture.size
        if let maxWidth, displaySize.width > maxWidth {
            displaySize = CGSize(width: maxWidth, height: (displaySize.height * maxWidth / displaySize.width).rounded())
        }
        attachment.bounds = CGRect(origin: .zero, size: displaySize)
        let cell = ImageAttachmentCell(picture: picture)
        attachment.attachmentCell = cell
        return attachment
    }

    public static func info(_ attachment: NSTextAttachment) -> Info? {
        let data = attachment.contents ?? attachment.fileWrapper?.regularFileContents
        guard let data, !data.isEmpty else { return nil }
        let type = attachment.fileType.flatMap(UTType.init)
            ?? attachment.fileWrapper?.preferredFilename.flatMap { UTType(filenameExtension: ($0 as NSString).pathExtension) }
            ?? sniff(data)
            ?? .png
        var size = attachment.bounds.size
        if size.width <= 0 || size.height <= 0 {
            size = (attachment.attachmentCell as? NSTextAttachmentCell)?.cellSize() ?? NSImage(data: data)?.size ?? CGSize(width: 100, height: 100)
        }
        return Info(data: data, type: type, size: size)
    }

    /// The image data in a widely supported format (PNG/JPEG/GIF), converting when needed.
    public static func portableData(_ info: Info) -> (data: Data, type: UTType)? {
        if portableTypes.contains(where: { info.type.conforms(to: $0) }) {
            let type = portableTypes.first { info.type.conforms(to: $0) } ?? .png
            return (info.data, type)
        }
        guard let rep = NSBitmapImageRep(data: info.data) ?? NSImage(data: info.data)?.tiffRepresentation.flatMap(NSBitmapImageRep.init),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return (png, .png)
    }

    /// Makes sure an attachment that holds an image draws with `ImageAttachmentCell`.
    @discardableResult
    public static func installCell(_ attachment: NSTextAttachment, maxWidth: CGFloat? = nil) -> Bool {
        if attachment.attachmentCell is ImageAttachmentCell { return true }
        guard let info = info(attachment), let picture = NSImage(data: info.data) else { return false }
        if attachment.contents == nil {
            attachment.contents = info.data
            attachment.fileType = info.type.identifier
        }
        var size = attachment.bounds.size.width > 0 ? attachment.bounds.size : picture.size
        if let maxWidth, size.width > maxWidth {
            size = CGSize(width: maxWidth, height: (size.height * maxWidth / size.width).rounded())
        }
        attachment.bounds = CGRect(origin: .zero, size: size)
        attachment.attachmentCell = ImageAttachmentCell(picture: picture)
        return true
    }

    public static func sniff(_ data: Data) -> UTType? {
        let bytes = [UInt8](data.prefix(16))
        guard bytes.count >= 4 else { return nil }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .png }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if bytes.starts(with: [0x47, 0x49, 0x46]) { return .gif }
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if bytes.starts(with: [0x42, 0x4D]) { return .bmp }
        if bytes.count >= 12, bytes[0..<4] == [0x52, 0x49, 0x46, 0x46], bytes[8..<12] == [0x57, 0x45, 0x42, 0x50] { return .webP }
        if bytes.count >= 12, String(decoding: bytes[4..<12], as: UTF8.self).hasPrefix("ftyphei") { return .heic }
        return nil
    }

    public static func fileExtension(_ type: UTType) -> String {
        type.preferredFilenameExtension ?? "png"
    }

    public static func mimeType(_ type: UTType) -> String {
        type.preferredMIMEType ?? "image/png"
    }
}
