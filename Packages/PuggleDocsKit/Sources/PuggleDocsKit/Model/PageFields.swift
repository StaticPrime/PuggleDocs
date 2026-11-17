import AppKit

/// Supplies the page a header or footer is being drawn on (implemented by the editor's layout managers).
@objc public protocol PageNumberProviding {
    var pageNumber: Int { get }
    var pageCount: Int { get }
}

/// A page number or page count field in a header or footer.
public final class PageFieldAttachment: NSTextAttachment {
    @objc public enum Kind: Int, Sendable {
        case pageNumber, pageCount
    }

    public let kind: Kind

    public init(kind: Kind) {
        self.kind = kind
        super.init(data: nil, ofType: nil)
        attachmentCell = PageFieldCell(kind: kind)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public static func string(_ kind: Kind = .pageNumber) -> NSAttributedString {
        NSAttributedString(attachment: PageFieldAttachment(kind: kind))
    }
}

/// Draws the current page number (or page count) in the field's font and color.
public final class PageFieldCell: NSTextAttachmentCell {
    let kind: PageFieldAttachment.Kind

    init(kind: PageFieldAttachment.Kind) {
        self.kind = kind
        super.init(textCell: "")
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private nonisolated func value(_ layoutManager: NSLayoutManager?) -> Int {
        guard let provider = layoutManager as? PageNumberProviding else { return 1 }
        return kind == .pageNumber ? provider.pageNumber : provider.pageCount
    }

    private nonisolated func attributes(at index: Int, in layoutManager: NSLayoutManager?) -> [NSAttributedString.Key: Any] {
        guard let storage = layoutManager?.textStorage, index < storage.length else { return DocumentDefaults.typingAttributes }
        var attributes = storage.attributes(at: index, effectiveRange: nil)
        attributes[.attachment] = nil
        return attributes
    }

    public override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                                   glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let layoutManager = textContainer.layoutManager
        let attributes = attributes(at: charIndex, in: layoutManager)
        // Reserve room for the widest number this field can show.
        let digits = String(max(value(layoutManager), (layoutManager as? PageNumberProviding)?.pageCount ?? 1))
        let sample = String(repeating: "0", count: digits.count) as NSString
        let size = sample.size(withAttributes: attributes)
        let font = attributes[.font] as? NSFont
        return NSRect(x: 0, y: font.map { $0.descender } ?? -2, width: ceil(size.width), height: ceil(size.height))
    }

    public override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        let attributes = attributes(at: charIndex, in: layoutManager)
        let text = String(value(layoutManager)) as NSString
        let font = attributes[.font] as? NSFont
        let flipped = controlView?.isFlipped ?? true
        let baseline = flipped ? cellFrame.maxY + (font?.descender ?? -2) : cellFrame.minY - (font?.descender ?? -2)
        let origin = NSPoint(x: cellFrame.minX, y: flipped ? baseline - (font?.ascender ?? 9) : baseline)
        text.draw(at: origin, withAttributes: attributes)
    }

    public override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let text = "#" as NSString
        text.draw(at: cellFrame.origin, withAttributes: DocumentDefaults.typingAttributes)
    }

    public override func wantsToTrackMouse() -> Bool { false }
}
