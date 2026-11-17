import AppKit
import PuggleDocsKit

extension EditorController {
    /// The page text view showing `range` and the range's rectangle in that view's coordinates.
    func rect(for range: NSRange) -> (DocumentTextView, NSRect)? {
        let length = textStorage.length
        let location = min(range.location, length)
        guard let textView = textView(forCharacterAt: location), let container = textView.textContainer else { return nil }
        var rect: NSRect
        if range.length > 0, length > 0 {
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        } else if length > 0, location < length || layoutManager.extraLineFragmentTextContainer == nil {
            let glyph = layoutManager.glyphIndexForCharacter(at: min(location, length - 1))
            let line = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            var x = line.minX + layoutManager.location(forGlyphAt: glyph).x
            if location >= length { x = line.maxX }
            rect = NSRect(x: x, y: line.minY, width: 1, height: line.height)
        } else {
            rect = layoutManager.extraLineFragmentUsedRect
            rect.size.width = 1
        }
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        return (textView, rect)
    }

    /// Inserts a link, turns `range` into a link, or edits an existing one.
    func applyLink(text: String, url: URL, range: NSRange) {
        guard state.isEditable else { return }
        let textView = activeTextView
        let current = (textStorage.string as NSString).substring(with: range)
        let label = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? LinkAddress.display(url) : text
        textView.breakUndoCoalescing()
        if range.length == 0 || label != current {
            var attributes = range.length > 0 ? textStorage.attributes(at: range.location, effectiveRange: nil) : textView.typingAttributes
            let plain = attributes.filter { $0.key != .link }
            attributes[.link] = url
            let insertion = NSAttributedString(string: label, attributes: attributes)
            guard withDirectEdits({ textView.shouldChangeText(in: range, replacementString: label) }) else { return }
            textStorage.replaceCharacters(in: range, with: insertion)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: range.location + insertion.length, length: 0))
            textView.typingAttributes = plain
        } else {
            guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
            textStorage.addAttribute(.link, value: url, range: range)
            textView.didChangeText()
        }
        undoManager?.setActionName("Link")
        focus()
    }

    /// Removes a link and the link look it was given.
    func removeLink(in range: NSRange) {
        guard state.isEditable, range.length > 0 else { return }
        let textView = activeTextView
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        textStorage.beginEditing()
        textStorage.removeAttribute(.link, range: range)
        textStorage.enumerateAttribute(.foregroundColor, in: range, options: []) { value, subrange, _ in
            guard (value as? NSColor)?.hexString == ColorPalette.linkHex else { return }
            self.textStorage.addAttribute(.foregroundColor, value: NSColor.black, range: subrange)
            self.textStorage.removeAttribute(.underlineStyle, range: subrange)
        }
        textStorage.endEditing()
        textView.didChangeText()
        undoManager?.setActionName("Remove Link")
        focus()
    }
}

extension EditorController {
    /// Adds link actions to the text view's context menu.
    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        var items: [NSMenuItem] = []
        if charIndex < textStorage.length, textStorage.attribute(.attachment, at: charIndex, effectiveRange: nil) is NSTextAttachment {
            view.setSelectedRange(NSRange(location: charIndex, length: 1))
            items = [MenuBuilder.item("Image options…", #selector(DocumentCommands.pdImageOptions(_:)), symbol: "photo")]
        } else if charIndex < textStorage.length, textStorage.attribute(.link, at: charIndex, effectiveRange: nil) != nil {
            items = [
                MenuBuilder.item("Open link", #selector(DocumentCommands.pdOpenLink(_:))),
                MenuBuilder.item("Copy link", #selector(DocumentCommands.pdCopyLink(_:))),
                MenuBuilder.item("Edit link", #selector(DocumentCommands.pdInsertLink(_:))),
                MenuBuilder.item("Remove link", #selector(DocumentCommands.pdRemoveLink(_:))),
            ]
            for item in items { item.representedObject = charIndex }
        } else if state.isEditable {
            items = [MenuBuilder.item("Insert link", #selector(DocumentCommands.pdInsertLink(_:)), symbol: "link")]
        }
        if state.mode != .viewing, !isEditingHeaderFooter, view is DocumentTextView {
            if view.selectedRange().length == 0, charIndex < textStorage.length {
                view.setSelectedRange(view.selectionRange(forProposedRange: NSRange(location: charIndex, length: 0), granularity: .selectByWord))
            }
            items.append(MenuBuilder.item("Comment", #selector(DocumentCommands.pdInsertComment(_:)), "m", [.command, .option], symbol: "plus.bubble"))
        }
        if state.isEditable, !isEditingHeaderFooter, TableModel.block(at: charIndex, in: textStorage) != nil {
            if let current = TableModel.block(at: view.selectedRange().location, in: textStorage), current === TableModel.block(at: charIndex, in: textStorage) {
                // The caret is already in this cell.
            } else {
                view.setSelectedRange(NSRange(location: charIndex, length: 0))
            }
            items += (items.isEmpty ? [] : [.separator()]) + MenuBuilder.tableItems()
        }
        guard !items.isEmpty else { return menu }
        for (offset, item) in items.enumerated() { menu.insertItem(item, at: offset) }
        menu.insertItem(.separator(), at: items.count)
        return menu
    }
}
