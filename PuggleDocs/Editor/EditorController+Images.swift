import AppKit
import PuggleDocsKit
import UniformTypeIdentifiers

extension EditorController {
    /// Images can be at most as wide and tall as the text area.
    var maximumImageSize: NSSize { pageSetup.contentSize }

    /// Gives image attachments in `range` the drawing cell and a size that fits the page.
    func prepareImages(in range: NSRange) {
        guard range.length > 0, NSMaxRange(range) <= textStorage.length else { return }
        textStorage.enumerateAttribute(.attachment, in: range, options: []) { value, _, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            ImageAttachments.installCell(attachment, maxWidth: maximumImageSize.width)
        }
    }

    func insertImage(data: Data, type: UTType?) -> Bool {
        guard state.isEditable,
              let attachment = ImageAttachments.make(data: data, type: type, maxWidth: maximumImageSize.width) else { return false }
        if attachment.bounds.height > maximumImageSize.height {
            let size = attachment.bounds.size
            attachment.bounds.size = NSSize(width: (size.width * maximumImageSize.height / size.height).rounded(), height: maximumImageSize.height)
        }
        let textView = activeTextView
        let range = textView.selectedRange()
        var attributes = textView.typingAttributes
        attributes[.attachment] = attachment
        attributes[.link] = nil
        let insertion = NSAttributedString(string: "\u{FFFC}", attributes: attributes)
        textView.breakUndoCoalescing()
        guard withDirectEdits({ textView.shouldChangeText(in: range, replacementString: insertion.string) }) else { return false }
        textStorage.replaceCharacters(in: range, with: insertion)
        textView.didChangeText()
        undoManager?.setActionName("Insert Image")
        textView.setSelectedRange(NSRange(location: range.location, length: 1))
        focus()
        return true
    }

    /// The selected image, when exactly one image character is selected.
    var selectedImage: (range: NSRange, attachment: NSTextAttachment)? {
        let range = activeTextView.selectedRange()
        guard range.length == 1, NSMaxRange(range) <= textStorage.length,
              let attachment = textStorage.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment,
              attachment.attachmentCell is ImageAttachmentCell else { return nil }
        return (range, attachment)
    }

    /// Replaces the image with a copy at the new size, as one undoable change.
    func setImageSize(_ size: NSSize, at range: NSRange) {
        guard state.isEditable, let attachment = textStorage.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment,
              let info = ImageAttachments.info(attachment),
              let resized = ImageAttachments.make(data: info.data, type: info.type, size: size) else { return }
        let textView = activeTextView
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        textStorage.addAttribute(.attachment, value: resized, range: range)
        textView.didChangeText()
        undoManager?.setActionName("Resize Image")
        textView.setSelectedRange(range)
        updateImageSelection()
    }

    /// Shows or hides the resize handles for the selected image.
    /// The frame the image is drawn in, in its page text view's coordinates.
    func imageFrame(for range: NSRange) -> (DocumentTextView, NSRect)? {
        guard let textView = textView(forCharacterAt: range.location), let container = textView.textContainer, range.location < textStorage.length else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
        guard glyph < layoutManager.numberOfGlyphs, layoutManager.textContainer(forGlyphAt: glyph, effectiveRange: nil) === container else { return nil }
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let location = layoutManager.location(forGlyphAt: glyph)
        let size = layoutManager.attachmentSize(forGlyphAt: glyph)
        let origin = textView.textContainerOrigin
        return (textView, NSRect(x: origin.x + line.minX + location.x, y: origin.y + line.minY + location.y - size.height,
                                 width: size.width, height: size.height))
    }

    func updateImageSelection() {
        guard let (range, attachment) = selectedImage, let (textView, rect) = imageFrame(for: range) else {
            if imageOverlay != nil {
                imageOverlay?.removeFromSuperview()
                imageOverlay = nil
            }
            if layoutManager.suppressedSelectionRange != nil {
                layoutManager.suppressedSelectionRange = nil
                textViews.forEach { $0.needsDisplay = true }
            }
            return
        }
        // A selected image shows handles instead of the text highlight.
        if layoutManager.suppressedSelectionRange != range {
            layoutManager.suppressedSelectionRange = range
            textView.needsDisplay = true
        }
        let overlay = imageOverlay ?? ImageSelectionOverlay()
        if overlay.superview !== textView { textView.addSubview(overlay) }
        overlay.maximumSize = maximumImageSize
        overlay.place(around: rect)
        let originalBounds = attachment.bounds
        overlay.onResize = { [weak self, weak attachment] size, finished in
            guard let self, let attachment else { return }
            if finished {
                // Put the original size back so undo returns to it, then apply the new size undoably.
                attachment.bounds = originalBounds
                self.setImageSize(size, at: range)
            } else {
                // Live preview while dragging.
                attachment.bounds = CGRect(origin: .zero, size: size)
                self.layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
                self.layoutManager.invalidateDisplay(forCharacterRange: range)
            }
        }
        imageOverlay = overlay
    }

    /// Clicking an image selects it (a second press on a selected image starts a drag).
    func handleImageClick(_ event: NSEvent, in textView: DocumentTextView) -> Bool {
        guard let container = textView.textContainer, textStorage.length > 0 else { return false }
        let point = textView.convert(event.locationInWindow, from: nil)
        let containerPoint = NSPoint(x: point.x - textView.textContainerOrigin.x, y: point.y - textView.textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: containerPoint, in: container, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < layoutManager.numberOfGlyphs else { return false }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < textStorage.length, textStorage.attribute(.attachment, at: index, effectiveRange: nil) is NSTextAttachment else { return false }
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard rect.contains(containerPoint) else { return false }
        let range = NSRange(location: index, length: 1)
        if textView.selectedRange() == range { return false }
        if textView.window?.firstResponder !== textView { textView.window?.makeFirstResponder(textView) }
        textView.setSelectedRange(range)
        if event.clickCount >= 2 { onImageOptions?() }
        return true
    }
}
