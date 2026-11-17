import AppKit
import PuggleDocsKit

/// Formatting commands used by the toolbar and menus. Every change to existing text goes through
/// `shouldChangeText`/`didChangeText` so it is undoable; a bare caret changes the typing attributes.
extension EditorController {
    var selectedRanges: [NSRange] { focusedTextView.selectedRanges.map(\.rangeValue) }
    var hasSelection: Bool { selectedRanges.contains { $0.length > 0 } }

    // MARK: Core helpers

    func applyCharacterFormatting(_ actionName: String, _ transform: @escaping AttributeTransform) {
        guard state.isEditable else { return }
        let textView = focusedTextView
        let storage = focusedStorage
        let ranges = selectedRanges.filter { $0.length > 0 }
        if !ranges.isEmpty {
            textView.breakUndoCoalescing()
            guard textView.shouldChangeText(inRanges: ranges.map { NSValue(range: $0) }, replacementStrings: nil) else { return }
            storage.beginEditing()
            for range in ranges { CharacterFormatting.apply(transform, to: storage, range: range) }
            storage.endEditing()
            textView.didChangeText()
            undoManager?.setActionName(actionName)
        }
        textView.typingAttributes = CharacterFormatting.apply(transform, to: textView.typingAttributes)
        updateSummaryNow()
        focus()
        onFormattingApplied?()
    }

    /// Runs `edit` on the selected paragraphs; `trailing` updates the typing attributes when the
    /// caret sits in the empty last paragraph, which has no characters to carry attributes.
    func performParagraphEdit(_ actionName: String, edit: (NSTextStorage, [NSRange]) -> Void,
                              trailing: (([NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any])?) {
        guard state.isEditable else { return }
        let textView = focusedTextView
        let storage = focusedStorage
        let paragraphs = ParagraphFormatting.paragraphRanges(in: storage.string as NSString, covering: selectedRanges)
        let real = paragraphs.filter { $0.length > 0 }
        if !real.isEmpty {
            textView.breakUndoCoalescing()
            guard textView.shouldChangeText(inRanges: real.map { NSValue(range: $0) }, replacementStrings: nil) else { return }
            storage.beginEditing()
            edit(storage, real)
            storage.endEditing()
            textView.didChangeText()
            undoManager?.setActionName(actionName)
        }
        if paragraphs.contains(where: { $0.length == 0 }), let trailing {
            textView.typingAttributes = trailing(textView.typingAttributes)
            invalidateTrailingParagraph()
        } else {
            refreshTypingAttributes()
        }
        updateSummaryNow()
        focus()
        onFormattingApplied?()
    }

    func applyParagraphFormatting(_ actionName: String, _ transform: @escaping ParagraphTransform) {
        performParagraphEdit(actionName, edit: { storage, ranges in
            ParagraphFormatting.apply(transform, to: storage, paragraphRanges: ranges)
        }, trailing: { ParagraphFormatting.apply(transform, to: $0) })
    }

    /// Re-derives typing attributes from the text at the caret, as AppKit does on selection change.
    func refreshTypingAttributes() {
        let textView = focusedTextView
        let textStorage = focusedStorage
        let selection = textView.selectedRange()
        let string = textStorage.string as NSString
        guard string.length > 0 else { return }
        let location = min(selection.location, string.length)
        let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
        guard paragraph.length > 0 else { return }
        let index = location > paragraph.location ? location - 1 : min(location, string.length - 1)
        textView.typingAttributes = textStorage.attributes(at: index, effectiveRange: nil)
    }

    /// Forces the empty last line to re-layout with new typing attributes.
    func invalidateTrailingParagraph() {
        let length = focusedStorage.length
        let range = NSRange(location: max(0, length - 1), length: length > 0 ? 1 : 0)
        (focusedTextView.layoutManager ?? layoutManager).invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        focusedTextView.needsDisplay = true
        textViews.forEach { $0.needsDisplay = true }
    }

    // MARK: Character commands

    func toggleBold() {
        let on = !CharacterFormatting.allRuns(in: focusedStorage, ranges: selectedRanges, typing: focusedTextView.typingAttributes, satisfy: CharacterFormatting.isBold)
        applyCharacterFormatting("Bold", CharacterFormatting.setBold(on))
    }

    func toggleItalic() {
        let on = !CharacterFormatting.allRuns(in: focusedStorage, ranges: selectedRanges, typing: focusedTextView.typingAttributes, satisfy: CharacterFormatting.isItalic)
        applyCharacterFormatting("Italic", CharacterFormatting.setItalic(on))
    }

    func toggleUnderline() {
        let on = !CharacterFormatting.allRuns(in: focusedStorage, ranges: selectedRanges, typing: focusedTextView.typingAttributes, satisfy: CharacterFormatting.isUnderlined)
        applyCharacterFormatting("Underline", CharacterFormatting.setUnderline(on))
    }

    func toggleStrikethrough() {
        let on = !CharacterFormatting.allRuns(in: focusedStorage, ranges: selectedRanges, typing: focusedTextView.typingAttributes, satisfy: CharacterFormatting.isStruckThrough)
        applyCharacterFormatting("Strikethrough", CharacterFormatting.setStrikethrough(on))
    }

    func toggleBaseline(_ value: Int) {
        let current = CharacterFormatting.allRuns(in: focusedStorage, ranges: selectedRanges, typing: focusedTextView.typingAttributes) {
            CharacterFormatting.baseline($0) == value
        }
        applyCharacterFormatting(value > 0 ? "Superscript" : "Subscript", CharacterFormatting.setBaseline(current ? 0 : value))
    }

    func setFontFamily(_ family: String) {
        RecentFonts.note(family)
        applyCharacterFormatting("Font", CharacterFormatting.setFontFamily(family))
    }

    func setFontSize(_ size: CGFloat) {
        applyCharacterFormatting("Font Size", CharacterFormatting.setFontSize(size))
    }

    func adjustFontSize(by delta: CGFloat) {
        applyCharacterFormatting("Font Size", CharacterFormatting.adjustFontSize(by: delta))
    }

    func stepFontSize(up: Bool) {
        applyCharacterFormatting("Font Size", CharacterFormatting.stepFontSize(up: up))
    }

    func setTextColor(_ color: NSColor) {
        applyCharacterFormatting("Text Color", CharacterFormatting.setTextColor(color))
    }

    func setHighlight(_ color: NSColor?) {
        applyCharacterFormatting("Highlight Color", CharacterFormatting.setHighlight(color))
    }

    // MARK: Paragraph commands

    func setAlignment(_ alignment: NSTextAlignment) {
        applyParagraphFormatting("Alignment", ParagraphFormatting.setAlignment(alignment))
    }

    func setLineSpacing(_ multiple: CGFloat) {
        applyParagraphFormatting("Line Spacing", ParagraphFormatting.setLineSpacing(multiple))
    }

    func toggleSpaceBefore() {
        let value: CGFloat = state.summary.spaceBefore > 0 ? 0 : 10
        applyParagraphFormatting("Paragraph Spacing", ParagraphFormatting.setSpaceBefore(value))
    }

    func toggleSpaceAfter() {
        let value: CGFloat = state.summary.spaceAfter > 0 ? 0 : 10
        applyParagraphFormatting("Paragraph Spacing", ParagraphFormatting.setSpaceAfter(value))
    }

    func setCustomSpacing(line: CGFloat, before: CGFloat, after: CGFloat) {
        applyParagraphFormatting("Custom Spacing") { paragraph in
            ParagraphFormatting.setLineSpacing(line)(&paragraph)
            ParagraphFormatting.setSpaceBefore(before)(&paragraph)
            ParagraphFormatting.setSpaceAfter(after)(&paragraph)
        }
    }

    func setIndents(left: CGFloat, firstLine: CGFloat, right: CGFloat) {
        applyParagraphFormatting("Indent", ParagraphFormatting.setIndents(left: left, firstLine: firstLine, right: right))
    }

    func indent(increase: Bool) {
        let maximum = max(0, pageSetup.contentSize.width - 72)
        applyParagraphFormatting(increase ? "Increase Indent" : "Decrease Indent", ParagraphFormatting.indent(increase: increase, maximum: maximum))
    }

    func applyNamedStyle(_ style: NamedStyle) {
        performParagraphEdit(style.displayName, edit: { storage, ranges in
            StyleFormatting.apply(style, to: storage, paragraphRanges: ranges)
        }, trailing: { StyleFormatting.apply(style, to: $0) })
        refreshUsedHeadings()
    }

    func toggleList(_ kind: ListKind, preset: ListPreset? = nil) {
        guard state.isEditable, !isEditingHeaderFooter else { return }
        let textView = activeTextView
        let paragraphs = ParagraphFormatting.paragraphRanges(in: textStorage.string as NSString, covering: selectedRanges)
        let real = paragraphs.filter { $0.length > 0 }
        var typing = textView.typingAttributes
        if !real.isEmpty {
            // Restyling a preset touches every item of the list, so register the whole text.
            let affected = preset != nil ? [NSRange(location: 0, length: textStorage.length)] : real
            textView.breakUndoCoalescing()
            guard textView.shouldChangeText(inRanges: affected.map { NSValue(range: $0) }, replacementStrings: nil) else { return }
        }
        textStorage.beginEditing()
        ListFormatting.toggle(kind: kind, preset: preset, in: textStorage, paragraphRanges: paragraphs, typing: &typing)
        textStorage.endEditing()
        if !real.isEmpty {
            textView.didChangeText()
            undoManager?.setActionName(kind == .numbered ? "Numbered List" : (kind == .checklist ? "Checklist" : "Bulleted List"))
        }
        if paragraphs.contains(where: { $0.length == 0 }) {
            textView.typingAttributes = typing
            invalidateTrailingParagraph()
        } else {
            refreshTypingAttributes()
        }
        updateSummaryNow()
        focus()
    }

    func clearFormatting() {
        let characterRanges = selectedRanges.filter { $0.length > 0 }
        performParagraphEdit("Clear Formatting", edit: { storage, paragraphs in
            StyleFormatting.clearFormatting(in: storage, characterRanges: characterRanges, paragraphRanges: paragraphs)
        }, trailing: { typing in
            let style = (typing[.pdNamedStyle] as? String).flatMap(NamedStyle.init(rawValue:)) ?? .normal
            let cleared = CharacterFormatting.apply(CharacterFormatting.clearFormatting(for: style), to: typing)
            return ParagraphFormatting.apply(ParagraphFormatting.clearFormatting(), to: cleared)
        })
        if characterRanges.isEmpty {
            let typing = focusedTextView.typingAttributes
            let style = (typing[.pdNamedStyle] as? String).flatMap(NamedStyle.init(rawValue:)) ?? .normal
            focusedTextView.typingAttributes = CharacterFormatting.apply(CharacterFormatting.clearFormatting(for: style), to: typing)
            updateSummaryNow()
        }
    }

    // MARK: Text commands

    func insertPageBreak() {
        guard state.isEditable, !isEditingHeaderFooter else { return }
        let textView = activeTextView
        let range = textView.selectedRange()
        let attributes = textView.typingAttributes
        let insertion = NSAttributedString(string: "\u{0C}\n", attributes: attributes)
        textView.breakUndoCoalescing()
        guard withDirectEdits({ textView.shouldChangeText(in: range, replacementString: insertion.string) }) else { return }
        textStorage.replaceCharacters(in: range, with: insertion)
        textView.didChangeText()
        undoManager?.setActionName("Page Break")
        textView.setSelectedRange(NSRange(location: range.location + insertion.length, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    enum Capitalization { case lower, upper, title }

    func changeCase(_ mode: Capitalization) {
        guard state.isEditable else { return }
        let textView = focusedTextView
        let textStorage = focusedStorage
        let ranges = selectedRanges.filter { $0.length > 0 }
        guard !ranges.isEmpty else { return }
        let string = textStorage.string as NSString
        let replacements = ranges.map { range -> String in
            let original = string.substring(with: range)
            switch mode {
            case .lower: return original.lowercased()
            case .upper: return original.uppercased()
            case .title: return original.capitalized
            }
        }
        textView.breakUndoCoalescing()
        guard withDirectEdits({ textView.shouldChangeText(inRanges: ranges.map { NSValue(range: $0) }, replacementStrings: replacements) }) else { return }
        textStorage.beginEditing()
        for (range, replacement) in zip(ranges, replacements).reversed() {
            // Replace run by run so formatting is preserved where lengths allow.
            if (replacement as NSString).length == range.length {
                var offset = 0
                textStorage.enumerateAttributes(in: range, options: []) { _, subrange, _ in
                    let piece = (replacement as NSString).substring(with: NSRange(location: offset, length: subrange.length))
                    textStorage.replaceCharacters(in: subrange, with: piece)
                    offset += subrange.length
                }
            } else {
                textStorage.replaceCharacters(in: range, with: replacement)
            }
        }
        textStorage.endEditing()
        textView.didChangeText()
        undoManager?.setActionName("Capitalization")
    }

    /// Inserts pasted rich text as one undoable change.
    func insertPasted(_ text: NSAttributedString, in textView: DocumentTextView) -> Bool {
        guard state.isEditable else { return false }
        let range = textView.rangeForUserTextChange
        // Comments belong to the document they were made in; pasted text starts free of suggestions.
        let text = NSMutableAttributedString(attributedString: Suggestions.accepted(text))
        text.removeAttribute(.pdComments, range: NSRange(location: 0, length: text.length))
        if isSuggesting, range.location != NSNotFound {
            textView.breakUndoCoalescing()
            suggestEdit(replacing: range, with: text, in: textView)
            undoManager?.setActionName("Paste")
            return true
        }
        guard range.location != NSNotFound, withDirectEdits({ textView.shouldChangeText(in: range, replacementString: text.string) }) else { return false }
        textView.breakUndoCoalescing()
        textStorage.replaceCharacters(in: range, with: text)
        textView.didChangeText()
        undoManager?.setActionName("Paste")
        textView.setSelectedRange(NSRange(location: range.location + text.length, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        return true
    }

    // MARK: Modes

    func setMode(_ mode: EditingMode) {
        state.mode = mode
        textViews.forEach { $0.isEditable = mode != .viewing }
        for page in pages { [page.headerView, page.footerView].compactMap { $0 }.forEach { $0.isEditable = mode != .viewing } }
        comments?.modeDidChange()
    }

    func setSpellChecking(_ enabled: Bool) {
        state.isSpellCheckEnabled = enabled
        for textView in textViews {
            textView.isContinuousSpellCheckingEnabled = enabled
            textView.isGrammarCheckingEnabled = enabled
        }
    }

    // MARK: Paint format

    func togglePaintFormat(sticky: Bool = false) {
        if state.isPaintFormatActive {
            state.isPaintFormatActive = false
            paintFormatAttributes = nil
            return
        }
        let textView = activeTextView
        let selection = textView.selectedRange()
        let characters: [NSAttributedString.Key: Any]
        if selection.length > 0 {
            characters = textStorage.attributes(at: selection.location, effectiveRange: nil)
        } else {
            characters = textView.typingAttributes
        }
        paintFormatAttributes = (characters, ParagraphAttributes(attributes: characters))
        paintFormatSticky = sticky
        state.isPaintFormatActive = true
        focus()
    }

    func textViewDidFinishMouseSelection(_ textView: DocumentTextView) {
        focusPageContainingCaret()
        guard state.isPaintFormatActive, let paint = paintFormatAttributes else { return }
        let characterKeys: [NSAttributedString.Key] = [.font, .foregroundColor, .backgroundColor, .underlineStyle,
                                                       .strikethroughStyle, .superscript, .pdRequestedFont, .pdScriptBaseSize]
        let source = paint.characters
        applyCharacterFormatting("Paint Format") { attributes in
            for key in characterKeys { attributes[key] = source[key] }
        }
        if !paintFormatSticky {
            state.isPaintFormatActive = false
            paintFormatAttributes = nil
        }
    }

    func textViewBecameFirstResponder(_ textView: DocumentTextView) {
        scheduleSummaryUpdate()
    }
}
