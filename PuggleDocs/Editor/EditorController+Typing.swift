import AppKit
import PuggleDocsKit

// MARK: - Text view delegate

extension EditorController: NSTextViewDelegate {
    func undoManager(for view: NSTextView) -> UndoManager? {
        document?.undoManager
    }

    func textDidChange(_ notification: Notification) {
        if imageOverlay != nil { DispatchQueue.main.async { [weak self] in self?.updateImageSelection() } }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        scheduleSummaryUpdate()
        updateImageSelection()
        comments?.selectionDidChange()
        // Keyboard navigation can move the caret onto another page; that page's view must have focus
        // to draw the caret. Mouse drags are left alone until the button is released.
        if NSEvent.pressedMouseButtons == 0 {
            DispatchQueue.main.async { [weak self] in self?.focusPageContainingCaret() }
        }
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard state.isEditable else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)): return handleNewline(in: textView)
        case #selector(NSResponder.insertTab(_:)): return handleTableTab(backwards: false) || handleTab(in: textView, backwards: false)
        case #selector(NSResponder.insertBacktab(_:)): return handleTableTab(backwards: true) || handleTab(in: textView, backwards: true)
        case #selector(NSResponder.deleteBackward(_:)): return handleTableDeleteBackward() || handleDeleteBackward(in: textView)
        case #selector(NSResponder.deleteForward(_:)): return handleTableDeleteForward()
        default: return false
        }
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        if let url, !state.isEditable || NSEvent.modifierFlags.contains(.command) {
            NSWorkspace.shared.open(url)
        } else {
            textView.setSelectedRange(NSRange(location: charIndex, length: 0))
            onLinkClicked?(charIndex)
        }
        return true
    }
}

// MARK: - Word-processor typing behaviors

extension EditorController {
    struct ParagraphContext {
        let range: NSRange
        let contentLength: Int
        let attributes: [NSAttributedString.Key: Any]
        var listItem: ListItem? { attributes[.pdListItem] as? ListItem }
        var namedStyle: NamedStyle { (attributes[.pdNamedStyle] as? String).flatMap(NamedStyle.init(rawValue:)) ?? .normal }
        var paragraphStyle: NSParagraphStyle { (attributes[.paragraphStyle] as? NSParagraphStyle) ?? .default }
    }

    func paragraphContext(at location: Int, typing: [NSAttributedString.Key: Any]) -> ParagraphContext {
        let string = textStorage.string as NSString
        let range = string.paragraphRange(for: NSRange(location: min(location, string.length), length: 0))
        var content = range.length
        while content > 0, Self.isParagraphSeparator(string.character(at: range.location + content - 1)) { content -= 1 }
        let attributes = range.length > 0 ? textStorage.attributes(at: range.location, effectiveRange: nil) : typing
        return ParagraphContext(range: range, contentLength: content, attributes: attributes)
    }

    /// Return: empty list items end (or outdent) the list; headings are followed by normal text;
    /// new checklist items start unchecked.
    func handleNewline(in textView: NSTextView) -> Bool {
        let selection = textView.selectedRange()
        let context = paragraphContext(at: selection.location, typing: textView.typingAttributes)

        if let item = context.listItem, context.contentLength == 0, selection.length == 0 {
            if item.level > 0 {
                indent(increase: false)
            } else {
                performParagraphEdit("Remove List", edit: { storage, ranges in
                    ParagraphFormatting.apply(ParagraphFormatting.setList(nil), to: storage, paragraphRanges: ranges)
                }, trailing: { ParagraphFormatting.apply(ParagraphFormatting.setList(nil), to: $0) })
            }
            return true
        }

        let atParagraphEnd = selection.length == 0 && selection.location == context.range.location + context.contentLength
        let needsNormalStyle = context.namedStyle.isHeadingLike && atParagraphEnd && context.listItem == nil
        let isChecklist = context.listItem?.kind == .checklist
        guard needsNormalStyle || isChecklist else { return false }

        textView.breakUndoCoalescing()
        textView.insertNewline(nil)
        let newParagraph = paragraphContext(at: textView.selectedRange().location, typing: textView.typingAttributes)
        if needsNormalStyle {
            restyle(newParagraph, in: textView) { attributes in
                StyleFormatting.apply(.normal, to: attributes)
            } storageEdit: { storage, range in
                StyleFormatting.apply(.normal, to: storage, paragraphRanges: [range])
            }
        } else if let item = newParagraph.listItem, item.isChecked {
            restyle(newParagraph, in: textView) { attributes in
                var updated = CharacterFormatting.apply(CharacterFormatting.setStrikethrough(false), to: attributes)
                updated[.pdListItem] = item.with(checked: false)
                return updated
            } storageEdit: { storage, range in
                storage.addAttribute(.pdListItem, value: item.with(checked: false), range: range)
                CharacterFormatting.apply(CharacterFormatting.setStrikethrough(false), to: storage, range: range)
            }
        }
        textView.breakUndoCoalescing()
        return true
    }

    private func restyle(_ paragraph: ParagraphContext, in textView: NSTextView,
                         typing: ([NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any],
                         storageEdit: (NSTextStorage, NSRange) -> Void) {
        if paragraph.range.length > 0 {
            if textView.shouldChangeText(in: paragraph.range, replacementString: nil) {
                textStorage.beginEditing()
                storageEdit(textStorage, paragraph.range)
                textStorage.endEditing()
                textView.didChangeText()
            }
            refreshTypingAttributes()
        } else {
            textView.typingAttributes = typing(textView.typingAttributes)
            invalidateTrailingParagraph()
        }
        updateSummaryNow()
    }

    /// Tab/Shift-Tab change list levels; with several paragraphs selected they indent.
    func handleTab(in textView: NSTextView, backwards: Bool) -> Bool {
        let selection = textView.selectedRange()
        let context = paragraphContext(at: selection.location, typing: textView.typingAttributes)
        let paragraphs = ParagraphFormatting.paragraphRanges(in: textStorage.string as NSString, covering: [selection])
        if context.listItem != nil {
            if backwards || selection.length > 0 || selection.location == context.range.location {
                indent(increase: !backwards)
                return true
            }
            return false
        }
        if paragraphs.count > 1 {
            indent(increase: !backwards)
            return true
        }
        if backwards {
            if context.paragraphStyle.headIndent > 0 || context.paragraphStyle.firstLineHeadIndent > 0 { indent(increase: false) }
            return true
        }
        return false
    }

    /// Backspace at the start of a list item removes its marker; at the start of an indented
    /// paragraph it removes one indent step.
    func handleDeleteBackward(in textView: NSTextView) -> Bool {
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }
        let context = paragraphContext(at: selection.location, typing: textView.typingAttributes)
        guard selection.location == context.range.location else { return false }
        if context.listItem != nil {
            performParagraphEdit("Remove List", edit: { storage, ranges in
                ParagraphFormatting.apply(ParagraphFormatting.setList(nil, keepIndent: true), to: storage, paragraphRanges: ranges)
            }, trailing: { ParagraphFormatting.apply(ParagraphFormatting.setList(nil, keepIndent: true), to: $0) })
            return true
        }
        let style = context.paragraphStyle
        if style.headIndent > 0 || style.firstLineHeadIndent > 0 {
            if style.firstLineHeadIndent > style.headIndent {
                setIndents(left: style.headIndent, firstLine: style.headIndent, right: max(0, -style.tailIndent))
            } else {
                indent(increase: false)
            }
            return true
        }
        return false
    }

    /// Typing "* ", "- ", "1. ", "1) ", "A. ", "I. " or "[] " at the start of a paragraph starts a list.
    func handleAutoListTrigger(in textView: NSTextView) -> Bool {
        guard state.mode == .editing, textView.selectedRange().length == 0 else { return false }
        let location = textView.selectedRange().location
        let context = paragraphContext(at: location, typing: textView.typingAttributes)
        guard context.listItem == nil, location > context.range.location, location - context.range.location <= 3 else { return false }
        let prefixRange = NSRange(location: context.range.location, length: location - context.range.location)
        let prefix = (textStorage.string as NSString).substring(with: prefixRange)
        let triggers: [String: (ListKind, ListPreset)] = [
            "*": (.bulleted, .discCircleSquare), "-": (.bulleted, .dashCircleSquare),
            "1.": (.numbered, .decimalAlphaRoman), "1)": (.numbered, .decimalParen),
            "A.": (.numbered, .upperAlphaLowerAlpha), "I.": (.numbered, .upperRomanUpperAlpha), "[]": (.checklist, .checkbox),
        ]
        guard let (kind, preset) = triggers[prefix] else { return false }
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(in: prefixRange, replacementString: "") else { return false }
        textStorage.replaceCharacters(in: prefixRange, with: "")
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: context.range.location, length: 0))
        toggleList(kind, preset: preset)
        textView.breakUndoCoalescing()
        return true
    }

    /// Clicking a checklist box toggles it.
    func handleMarkerClick(_ event: NSEvent, in textView: DocumentTextView) -> Bool {
        guard state.isEditable, event.clickCount == 1, let container = textView.textContainer, textStorage.length > 0 else { return false }
        let point = textView.convert(event.locationInWindow, from: nil)
        let glyphs = layoutManager.glyphRange(for: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        for entry in layoutManager.entries(inCharacterRange: characters) where entry.item.kind == .checklist {
            guard let rect = layoutManager.markerRect(for: entry), rect.insetBy(dx: -3, dy: -2).contains(point) else { continue }
            guard textView.shouldChangeText(in: entry.paragraphRange, replacementString: nil) else { return true }
            textStorage.beginEditing()
            ListFormatting.toggleChecked(paragraphRange: entry.paragraphRange, in: textStorage)
            textStorage.endEditing()
            textView.didChangeText()
            undoManager?.setActionName(entry.item.isChecked ? "Uncheck Item" : "Check Item")
            return true
        }
        return false
    }

    /// Draws the marker of an empty last paragraph, which has no characters for the layout manager.
    func drawTrailingListMarker(in textView: DocumentTextView) {
        guard let container = textView.textContainer, layoutManager.extraLineFragmentTextContainer === container else { return }
        let typing = textView.typingAttributes
        guard let item = typing[.pdListItem] as? ListItem else { return }
        let string = textStorage.string as NSString
        guard string.length == 0 || Self.isParagraphSeparator(string.character(at: string.length - 1)) else { return }
        guard textView.selectedRange().location == string.length else { return }
        let used = layoutManager.extraLineFragmentUsedRect
        let font = (typing[.font] as? NSFont) ?? NamedStyle.normal.definition.font
        let style = (typing[.paragraphStyle] as? NSParagraphStyle) ?? .default
        let baseline = used.maxY - abs(font.descender) - font.leading
        let origin = textView.textContainerOrigin
        let entry = ListNumbering.Entry(paragraphRange: NSRange(location: string.length, length: 0), item: item,
                                        marker: ListNumbering.trailingMarker(for: item, in: textStorage))
        let textStart = NSPoint(x: origin.x + style.firstLineHeadIndent, y: origin.y + baseline)
        ListMarkerRenderer.draw(entry: entry, attributes: typing, textStart: textStart, layoutManager: layoutManager)
    }
}
