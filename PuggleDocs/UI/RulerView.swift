import AppKit
import PuggleDocsKit

/// Positions the ruler needs, in ruler coordinates (x) and points (document values).
struct RulerGeometry {
    var pageLeft: CGFloat
    var scale: CGFloat
    var pageWidth: CGFloat
    var marginLeft: CGFloat
    var marginRight: CGFloat
    var headIndent: CGFloat
    var firstLineIndent: CGFloat
    /// Distance from the right margin.
    var rightIndent: CGFloat
    var isListItem: Bool
}

/// Horizontal ruler aligned with the page, with draggable indent and margin markers.
final class RulerView: NSView {
    static let height: CGFloat = 24

    var geometry: () -> RulerGeometry? = { nil }
    var onIndentsChanged: (_ left: CGFloat, _ firstLine: CGFloat, _ right: CGFloat) -> Void = { _, _, _ in }
    var onMarginsChanged: (_ left: CGFloat, _ right: CGFloat) -> Void = { _, _ in }
    var isEnabled = true

    private enum Handle { case firstLine, left, right, marginLeft, marginRight }
    private var dragging: Handle?
    private var dragValue: CGFloat = 0

    private var usesMetric: Bool { Locale.current.measurementSystem != .us }
    private var unit: CGFloat { usesMetric ? 72 / 2.54 : 72 }
    private var subdivisions: Int { usesMetric ? 4 : 8 }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        Theme.canvas.setFill()
        bounds.fill()
        guard var g = geometry(), g.scale > 0 else { return }
        applyDrag(to: &g)

        let stripTop: CGFloat = 3
        let stripHeight = bounds.height - 6
        let pageRight = g.pageLeft + g.pageWidth * g.scale
        let contentLeft = g.pageLeft + g.marginLeft * g.scale
        let contentRight = pageRight - g.marginRight * g.scale

        Theme.rulerMargin.setFill()
        NSRect(x: g.pageLeft, y: stripTop, width: pageRight - g.pageLeft, height: stripHeight).fill()
        NSColor.white.setFill()
        NSRect(x: contentLeft, y: stripTop, width: max(0, contentRight - contentLeft), height: stripHeight).fill()

        // Ticks and numbers, counted from the left margin.
        let step = unit / CGFloat(subdivisions) * g.scale
        let labelAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9.5), .foregroundColor: Theme.rulerTick]
        Theme.rulerTick.setFill()
        let firstIndex = -Int((g.marginLeft * g.scale / step).rounded(.down))
        let lastIndex = Int(((g.pageWidth - g.marginLeft) * g.scale / step).rounded(.down))
        if firstIndex <= lastIndex {
            for index in firstIndex...lastIndex {
                let x = contentLeft + CGFloat(index) * step
                if index % subdivisions == 0 {
                    let number = abs(index / subdivisions)
                    guard number != 0 else { continue }
                    let label = "\(number)" as NSString
                    let size = label.size(withAttributes: labelAttributes)
                    label.draw(at: NSPoint(x: x - size.width / 2, y: stripTop + (stripHeight - size.height) / 2), withAttributes: labelAttributes)
                } else {
                    let tick: CGFloat = index % (subdivisions / 2) == 0 ? 6 : 3
                    NSRect(x: x - 0.25, y: stripTop + (stripHeight - tick) / 2, width: 0.5, height: tick).fill()
                }
            }
        }

        // Indent markers.
        Theme.indentMarker.setFill()
        let firstX = contentLeft + (g.isListItem ? g.headIndent - ListItem.markerOffset : g.firstLineIndent) * g.scale
        NSBezierPath(roundedRect: NSRect(x: firstX - 5, y: 1, width: 10, height: 4), xRadius: 1, yRadius: 1).fill()
        triangle(at: contentLeft + g.headIndent * g.scale, top: 6).fill()
        triangle(at: contentRight - g.rightIndent * g.scale, top: 6).fill()

        if dragging != nil {
            let x: CGFloat
            switch dragging {
            case .firstLine: x = firstX
            case .left: x = contentLeft + g.headIndent * g.scale
            case .right: x = contentRight - g.rightIndent * g.scale
            case .marginLeft: x = contentLeft
            default: x = contentRight
            }
            Theme.indentMarker.withAlphaComponent(0.6).setFill()
            NSRect(x: x - 0.5, y: 0, width: 1, height: bounds.height).fill()
        }
    }

    private func triangle(at x: CGFloat, top: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x - 5.5, y: top))
        path.line(to: NSPoint(x: x + 5.5, y: top))
        path.line(to: NSPoint(x: x, y: top + 7))
        path.close()
        return path
    }

    private func applyDrag(to g: inout RulerGeometry) {
        guard let dragging else { return }
        switch dragging {
        case .firstLine:
            if g.isListItem { g.headIndent = dragValue + ListItem.markerOffset } else { g.firstLineIndent = dragValue }
        case .left:
            let offset = g.firstLineIndent - g.headIndent
            g.headIndent = dragValue
            if !g.isListItem { g.firstLineIndent = dragValue + offset }
        case .right: g.rightIndent = dragValue
        case .marginLeft: g.marginLeft = dragValue
        case .marginRight: g.marginRight = dragValue
        }
    }

    // MARK: Dragging

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let g = geometry(), g.scale > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let pageRight = g.pageLeft + g.pageWidth * g.scale
        let contentLeft = g.pageLeft + g.marginLeft * g.scale
        let contentRight = pageRight - g.marginRight * g.scale
        let firstX = contentLeft + (g.isListItem ? g.headIndent - ListItem.markerOffset : g.firstLineIndent) * g.scale
        let leftX = contentLeft + g.headIndent * g.scale
        let rightX = contentRight - g.rightIndent * g.scale

        if point.y < 6, abs(point.x - firstX) <= 6 {
            dragging = .firstLine
            dragValue = g.isListItem ? g.headIndent - ListItem.markerOffset : g.firstLineIndent
        } else if abs(point.x - leftX) <= 6 {
            dragging = .left
            dragValue = g.headIndent
        } else if abs(point.x - rightX) <= 6 {
            dragging = .right
            dragValue = g.rightIndent
        } else if abs(point.x - contentLeft) <= 4 {
            dragging = .marginLeft
            dragValue = g.marginLeft
        } else if abs(point.x - contentRight) <= 4 {
            dragging = .marginRight
            dragValue = g.marginRight
        } else {
            return
        }
        trackDrag(geometry: g)
    }

    private func trackDrag(geometry g: RulerGeometry) {
        guard let window else { return }
        let snap = unit / CGFloat(subdivisions)
        let contentLeft = g.pageLeft + g.marginLeft * g.scale
        let pageRight = g.pageLeft + g.pageWidth * g.scale
        let contentRight = pageRight - g.marginRight * g.scale
        let contentWidth = g.pageWidth - g.marginLeft - g.marginRight
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let x = convert(event.locationInWindow, from: nil).x
            var value: CGFloat
            switch dragging {
            case .firstLine, .left: value = (x - contentLeft) / g.scale
            case .right: value = (contentRight - x) / g.scale
            case .marginLeft: value = (x - g.pageLeft) / g.scale
            case .marginRight: value = (pageRight - x) / g.scale
            case nil: return
            }
            if !event.modifierFlags.contains(.option) { value = (value / snap).rounded() * snap }
            switch dragging {
            case .marginLeft, .marginRight: value = min(max(value, 0), g.pageWidth / 2 - 36)
            default: value = min(max(value, 0), max(0, contentWidth - 36))
            }
            dragValue = value
            needsDisplay = true
            if event.type == .leftMouseUp { break }
        }
        var final = g
        applyDrag(to: &final)
        let handle = dragging
        dragging = nil
        needsDisplay = true
        switch handle {
        case .marginLeft, .marginRight: onMarginsChanged(final.marginLeft, final.marginRight)
        case .some: onIndentsChanged(final.headIndent, final.isListItem ? final.headIndent : final.firstLineIndent, final.rightIndent)
        case nil: break
        }
    }
}
