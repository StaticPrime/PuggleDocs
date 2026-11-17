import AppKit
import PuggleDocsKit

/// Layout manager that draws list markers (bullets, numbers, checkboxes) beside list paragraphs.
/// Markers are not characters in the text; they are computed from `ListItem` attributes.
nonisolated final class PageLayoutManager: NSLayoutManager {
    private var cachedEntries: [ListNumbering.Entry]?
    /// A selected image shows resize handles; its selection highlight is not painted.
    var suppressedSelectionRange: NSRange?
    /// Comment threads whose text is highlighted, the one shown darker, and a comment being written.
    var highlightedComments = Set<String>()
    var activeComment: String?
    var draftCommentRange: NSRange?
    /// The suggestion whose card is open is shaded in its author's color.
    var activeSuggestionRange: NSRange?
    var activeSuggestionColor: NSColor?

    static let commentColor = NSColor(srgbRed: 0xFE / 255, green: 0xEF / 255, blue: 0xC3 / 255, alpha: 1)
    static let activeCommentColor = NSColor(srgbRed: 0xFC / 255, green: 0xD6 / 255, blue: 0x63 / 255, alpha: 1)

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        // Comment highlights are for the screen only: printing and PDFs leave them out.
        if NSGraphicsContext.currentContextDrawingToScreen() { drawCommentHighlights(forGlyphRange: glyphsToShow, at: origin) }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    private func drawCommentHighlights(forGlyphRange glyphs: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, glyphs.length > 0,
              !highlightedComments.isEmpty || draftCommentRange != nil || activeSuggestionRange != nil,
              let container = textContainer(forGlyphAt: glyphs.location, effectiveRange: nil) else { return }
        let characters = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        func fill(_ range: NSRange, _ color: NSColor) {
            guard range.length > 0 else { return }
            let glyphRange = NSIntersectionRange(self.glyphRange(forCharacterRange: range, actualCharacterRange: nil), glyphs)
            guard glyphRange.length > 0 else { return }
            color.setFill()
            enumerateEnclosingRects(forGlyphRange: glyphRange, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                    in: container) { rect, _ in
                rect.offsetBy(dx: origin.x, dy: origin.y).fill(using: .sourceOver)
            }
        }
        if !highlightedComments.isEmpty {
            storage.enumerateAttribute(.pdComments, in: characters, options: []) { value, range, _ in
                let ids = CommentAnchors.ids(value)
                guard ids.contains(where: highlightedComments.contains) else { return }
                fill(range, activeComment.map(ids.contains) == true ? Self.activeCommentColor : Self.commentColor)
            }
        }
        if let draft = draftCommentRange { fill(NSIntersectionRange(draft, characters), Self.activeCommentColor) }
        if let suggestion = activeSuggestionRange {
            fill(NSIntersectionRange(suggestion, characters), (activeSuggestionColor ?? .systemGreen).withAlphaComponent(0.14))
        }
    }

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        if let suppressed = suppressedSelectionRange, NSEqualRanges(suppressed, charRange) { return }
        super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
    }

    /// All list entries in document order.
    var listEntries: [ListNumbering.Entry] {
        if let cachedEntries { return cachedEntries }
        let entries = textStorage.map(ListNumbering.entries(in:)) ?? []
        cachedEntries = entries
        return entries
    }

    /// Drops cached markers; returns true when the visible markers changed.
    func invalidateListMarkers() -> Bool {
        let old = cachedEntries
        cachedEntries = nil
        guard let old else { return true }
        let new = listEntries
        guard old.count == new.count else { return true }
        return zip(old, new).contains { $0.marker != $1.marker || $0.item != $1.item || $0.paragraphRange.location != $1.paragraphRange.location }
    }

    func entries(inCharacterRange range: NSRange) -> ArraySlice<ListNumbering.Entry> {
        let entries = listEntries
        var low = 0
        var high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].paragraphRange.location < range.location { low = mid + 1 } else { high = mid }
        }
        var end = low
        while end < entries.count, entries[end].paragraphRange.location < NSMaxRange(range) { end += 1 }
        return entries[low..<end]
    }

    /// Draws each list marker immediately before its paragraph's glyphs, so printed and exported
    /// PDFs keep markers next to their text when copied or read aloud.
    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, glyphsToShow.length > 0 else {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let entries = entries(inCharacterRange: characters)
        guard !entries.isEmpty else {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        var cursor = glyphsToShow.location
        for entry in entries {
            let glyph = glyphIndexForCharacter(at: entry.paragraphRange.location)
            guard NSLocationInRange(glyph, glyphsToShow) else { continue }
            if glyph > cursor { super.drawGlyphs(forGlyphRange: NSRange(location: cursor, length: glyph - cursor), at: origin) }
            let lineRect = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let location = location(forGlyphAt: glyph)
            let attributes = storage.attributes(at: entry.paragraphRange.location, effectiveRange: nil)
            let textStart = NSPoint(x: origin.x + lineRect.minX + location.x, y: origin.y + lineRect.minY + location.y)
            ListMarkerRenderer.draw(entry: entry, attributes: attributes, textStart: textStart, layoutManager: self)
            cursor = glyph
        }
        if cursor < NSMaxRange(glyphsToShow) {
            super.drawGlyphs(forGlyphRange: NSRange(location: cursor, length: NSMaxRange(glyphsToShow) - cursor), at: origin)
        }
    }

    /// The rectangle a marker occupies, in text-container coordinates (used for checkbox clicks).
    func markerRect(for entry: ListNumbering.Entry) -> NSRect? {
        guard let storage = textStorage, entry.paragraphRange.location < storage.length else { return nil }
        let glyph = glyphIndexForCharacter(at: entry.paragraphRange.location)
        guard glyph < numberOfGlyphs else { return nil }
        let lineRect = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let location = location(forGlyphAt: glyph)
        let font = storage.attribute(.font, at: entry.paragraphRange.location, effectiveRange: nil) as? NSFont
        let size = font?.pointSize ?? 11
        return NSRect(x: lineRect.minX + location.x - ListItem.markerOffset - 2, y: lineRect.minY + location.y - size,
                      width: ListItem.markerOffset, height: size * 1.3)
    }
}

nonisolated enum ListMarkerRenderer {
    /// Draws a marker ending just before `textStart` (the first glyph's baseline origin).
    static func draw(entry: ListNumbering.Entry, attributes: [NSAttributedString.Key: Any], textStart: NSPoint, layoutManager: NSLayoutManager) {
        let font = (attributes[.font] as? NSFont) ?? NamedStyle.normal.definition.font
        let color = (attributes[.foregroundColor] as? NSColor) ?? .black
        if entry.item.kind == .checklist {
            drawCheckbox(checked: entry.item.isChecked, font: font, color: color, textStart: textStart)
            return
        }
        let markerFont: NSFont
        if entry.item.kind == .bulleted {
            // Bullet glyphs look best slightly smaller than the text, as in most word processors.
            markerFont = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits([]), size: font.pointSize * 0.8) ?? font
        } else {
            markerFont = font
        }
        let marker = NSAttributedString(string: entry.marker, attributes: [.font: markerFont, .foregroundColor: color])
        let width = marker.size().width
        let gap: CGFloat = 5
        var x = textStart.x - ListItem.markerOffset
        if width > ListItem.markerOffset - gap { x = textStart.x - gap - width }
        let baselineOffset = layoutManager.defaultBaselineOffset(for: markerFont)
        var y = textStart.y - baselineOffset
        if entry.item.kind == .bulleted {
            // Center the smaller bullet on the text's x-height.
            y -= (font.xHeight - markerFont.xHeight) / 2
        }
        marker.draw(at: NSPoint(x: x, y: y))
    }

    static func drawCheckbox(checked: Bool, font: NSFont, color: NSColor, textStart: NSPoint) {
        let side = max(8, (font.pointSize * 0.95).rounded())
        let centerY = textStart.y - font.xHeight / 2
        let rect = NSRect(x: textStart.x - ListItem.markerOffset - 1, y: centerY - side / 2, width: side, height: side)
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 2, yRadius: 2)
        if checked {
            Theme.checkboxFill.setFill()
            path.fill()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: rect.minX + side * 0.24, y: rect.minY + side * 0.52))
            check.line(to: NSPoint(x: rect.minX + side * 0.42, y: rect.minY + side * 0.70))
            check.line(to: NSPoint(x: rect.minX + side * 0.78, y: rect.minY + side * 0.30))
            check.lineWidth = max(1.4, side * 0.13)
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor.white.setStroke()
            check.stroke()
        } else {
            path.lineWidth = 1.3
            color.withAlphaComponent(0.75).setStroke()
            path.stroke()
        }
    }
}
