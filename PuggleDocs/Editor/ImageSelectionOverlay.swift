import AppKit

/// Blue frame with eight resize handles drawn over a selected image.
final class ImageSelectionOverlay: NSView {
    static let handleSize: CGFloat = 8

    /// Called with the new image size while dragging (`finished == false`) and once at the end.
    var onResize: ((NSSize, Bool) -> Void)?
    var maximumSize = NSSize(width: 2000, height: 2000)
    private var imageRect = NSRect.zero

    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var isCorner: Bool { [.topLeft, .topRight, .bottomRight, .bottomLeft].contains(self) }
    }

    override var isFlipped: Bool { true }

    /// Places the overlay around `rect` (in the superview's coordinates).
    func place(around rect: NSRect) {
        imageRect = NSRect(origin: NSPoint(x: Self.handleSize, y: Self.handleSize), size: rect.size)
        frame = rect.insetBy(dx: -Self.handleSize, dy: -Self.handleSize)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private func handleRect(_ handle: Handle, in rect: NSRect) -> NSRect {
        let size = Self.handleSize
        let point: NSPoint
        switch handle {
        case .topLeft: point = NSPoint(x: rect.minX, y: rect.minY)
        case .top: point = NSPoint(x: rect.midX, y: rect.minY)
        case .topRight: point = NSPoint(x: rect.maxX, y: rect.minY)
        case .right: point = NSPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: point = NSPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: point = NSPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: point = NSPoint(x: rect.minX, y: rect.maxY)
        case .left: point = NSPoint(x: rect.minX, y: rect.midY)
        }
        return NSRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard NSGraphicsContext.currentContextDrawingToScreen() else { return }
        Theme.indentMarker.setStroke()
        let border = NSBezierPath(rect: imageRect)
        border.lineWidth = 1.5
        border.stroke()
        for handle in Handle.allCases {
            let path = NSBezierPath(rect: handleRect(handle, in: imageRect))
            NSColor.white.setFill()
            path.fill()
            Theme.indentMarker.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    /// Only the handles take clicks; everything else goes to the text underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return handle(at: local) != nil ? self : nil
    }

    private func handle(at point: NSPoint) -> Handle? {
        Handle.allCases.first { handleRect($0, in: imageRect).insetBy(dx: -3, dy: -3).contains(point) }
    }

    override func resetCursorRects() {
        for handle in Handle.allCases {
            let cursor: NSCursor
            switch handle {
            case .left, .right: cursor = .resizeLeftRight
            case .top, .bottom: cursor = .resizeUpDown
            default: cursor = .crosshair
            }
            addCursorRect(handleRect(handle, in: imageRect).insetBy(dx: -3, dy: -3), cursor: cursor)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window, let handle = handle(at: convert(event.locationInWindow, from: nil)) else { return }
        let start = convert(event.locationInWindow, from: nil)
        let original = imageRect.size
        let ratio = original.width / max(original.height, 1)
        var size = original
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = convert(next.locationInWindow, from: nil)
            let dx = point.x - start.x
            let dy = point.y - start.y
            var width = original.width
            var height = original.height
            switch handle {
            case .right, .topRight, .bottomRight: width = original.width + dx
            case .left, .topLeft, .bottomLeft: width = original.width - dx
            default: break
            }
            switch handle {
            case .bottom, .bottomLeft, .bottomRight: height = original.height + dy
            case .top, .topLeft, .topRight: height = original.height - dy
            default: break
            }
            if handle.isCorner && !next.modifierFlags.contains(.shift) {
                // Corners keep the proportions (hold Shift to stretch freely).
                if abs(width - original.width) / original.width > abs(height - original.height) / original.height {
                    height = width / ratio
                } else {
                    width = height * ratio
                }
            }
            width = min(max(width, 16), maximumSize.width)
            height = min(max(height, 16), maximumSize.height)
            size = NSSize(width: width.rounded(), height: height.rounded())
            imageRect.size = size
            setFrameSize(NSSize(width: size.width + Self.handleSize * 2, height: size.height + Self.handleSize * 2))
            needsDisplay = true
            let finished = next.type == .leftMouseUp
            onResize?(size, finished)
            if finished { break }
        }
    }
}
