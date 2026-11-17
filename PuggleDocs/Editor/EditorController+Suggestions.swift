import AppKit
import PuggleDocsKit

/// Colors that tell authors apart on avatars and on their suggestions.
nonisolated enum AuthorColors {
    static let palette: [NSColor] = [
        NSColor(srgbRed: 0.10, green: 0.45, blue: 0.91, alpha: 1), NSColor(srgbRed: 0.85, green: 0.19, blue: 0.15, alpha: 1),
        NSColor(srgbRed: 0.09, green: 0.50, blue: 0.22, alpha: 1), NSColor(srgbRed: 0.89, green: 0.45, blue: 0.00, alpha: 1),
        NSColor(srgbRed: 0.58, green: 0.20, blue: 0.90, alpha: 1), NSColor(srgbRed: 0.90, green: 0.15, blue: 0.57, alpha: 1),
        NSColor(srgbRed: 0.07, green: 0.58, blue: 0.66, alpha: 1), NSColor(srgbRed: 0.37, green: 0.39, blue: 0.41, alpha: 1),
    ]

    /// The same name always gets the same color.
    static func color(for name: String) -> NSColor {
        var hash: UInt32 = 5381
        for scalar in name.unicodeScalars { hash = (hash &* 33) &+ scalar.value }
        return palette[Int(hash % UInt32(palette.count))]
    }
}

extension EditorController {
    var isSuggesting: Bool { state.mode == .suggesting }

    /// Structural edits (tables, images, page breaks…) are made directly, even while suggesting.
    @discardableResult
    func withDirectEdits<T>(_ body: () -> T) -> T {
        directEditDepth += 1
        defer { directEditDepth -= 1 }
        return body()
    }

    // MARK: Turning edits into suggestions

    func textView(_ textView: NSTextView, shouldChangeTextInRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        // Undo and redo replay earlier edits exactly; they must not become suggestions themselves.
        guard isSuggesting, let replacementStrings, directEditDepth == 0, !isApplyingSuggestion, composingDepth == 0,
              undoManager?.isUndoing != true, undoManager?.isRedoing != true,
              textView is DocumentTextView, replacementStrings.count == affectedRanges.count else { return true }
        // Later ranges first, so earlier ones keep their positions.
        let edits = zip(affectedRanges.map(\.rangeValue), replacementStrings).sorted { $0.0.location > $1.0.location }
        let attributes = suggestionTypingAttributes(textView)
        for (range, string) in edits {
            suggestEdit(replacing: range, with: NSAttributedString(string: string, attributes: attributes), in: textView)
        }
        return false
    }

    /// Typing attributes without review markup: new suggestions get their own marks.
    func suggestionTypingAttributes(_ textView: NSTextView) -> [NSAttributedString.Key: Any] {
        var attributes = textView.typingAttributes
        attributes[.pdSuggestion] = nil
        return attributes
    }

    private func isDeletedSuggestion(at index: Int) -> Bool { Suggestions.mark(at: index, in: textStorage)?.kind == .deletion }

    /// Replaces `range` with `replacement` as a suggestion: existing text is struck through rather than
    /// removed, new text is marked as inserted, and suggested text that is deleted again simply goes.
    func suggestEdit(replacing range: NSRange, with replacement: NSAttributedString, in textView: NSTextView) {
        let string = textStorage.string as NSString
        let author = CommentAuthor.name
        let selection = textView.selectedRange()
        let isDeletion = replacement.length == 0
        let backward = isDeletion && selection.length == 0 && NSMaxRange(range) == selection.location
        // (NSIntersectionRange would turn a caret into {0, 0}.)
        let start = min(range.location, string.length)
        var range = NSRange(location: start, length: min(NSMaxRange(range), string.length) - start)
        // Backspace and Delete step over text that is already struck through.
        if isDeletion, range.length > 0, (range.location..<NSMaxRange(range)).allSatisfy(isDeletedSuggestion) {
            if backward {
                var location = range.location
                while location > 0, isDeletedSuggestion(at: location - 1) { location -= 1 }
                guard location > 0 else {
                    textView.setSelectedRange(NSRange(location: location, length: 0))
                    return
                }
                range = string.rangeOfComposedCharacterSequence(at: location - 1)
            } else {
                var location = NSMaxRange(range)
                while location < string.length, isDeletedSuggestion(at: location) { location += 1 }
                guard location < string.length else {
                    textView.setSelectedRange(NSRange(location: location, length: 0))
                    return
                }
                range = string.rangeOfComposedCharacterSequence(at: location)
            }
        }

        // Keep typing or deleting into the suggestion next to the caret; otherwise start a new one.
        var id = UUID().uuidString
        var date = Date()
        let neighbor: SuggestionMark?
        if !isDeletion, range.length == 0 {
            neighbor = Suggestions.mark(at: range.location - 1, in: textStorage).flatMap { $0.kind == .insertion ? $0 : nil }
        } else if isDeletion {
            neighbor = Suggestions.mark(at: backward ? NSMaxRange(range) : range.location - 1, in: textStorage)
                .flatMap { $0.kind == .deletion ? $0 : nil }
        } else {
            neighbor = nil
        }
        if let neighbor, neighbor.author == author {
            id = neighbor.id
            date = neighbor.date
        }
        let insertion = SuggestionMark(id: id, kind: .insertion, author: author, date: date)
        let deletion = insertion.with(kind: .deletion)

        let rebuilt = NSMutableAttributedString()
        if range.length > 0 {
            textStorage.enumerateAttribute(.pdSuggestion, in: range, options: []) { value, subrange, _ in
                let mark = value as? SuggestionMark
                // Text being composed (accents, input methods) and suggested insertions just go.
                if mark?.kind == .insertion { return }
                if let composing = composingRange, NSIntersectionRange(composing, subrange).length == subrange.length { return }
                let piece = NSMutableAttributedString(attributedString: textStorage.attributedSubstring(from: subrange))
                if mark == nil { piece.addAttribute(.pdSuggestion, value: deletion, range: NSRange(location: 0, length: piece.length)) }
                rebuilt.append(piece)
            }
        }
        if replacement.length > 0 {
            let inserted = NSMutableAttributedString(attributedString: replacement)
            inserted.removeAttribute(.pdComments, range: NSRange(location: 0, length: inserted.length))
            inserted.addAttribute(.pdSuggestion, value: insertion, range: NSRange(location: 0, length: inserted.length))
            rebuilt.append(inserted)
        }

        isApplyingSuggestion = true
        defer { isApplyingSuggestion = false }
        // NSTextView's typing undo assumes typed text grows and deleted text shrinks; suggestions do neither.
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(in: range, replacementString: rebuilt.string) else { return }
        textStorage.replaceCharacters(in: range, with: rebuilt)
        textView.didChangeText()
        textView.breakUndoCoalescing()
        // The caret follows new text; Backspace leaves it before what it struck through, Delete after.
        let caret = backward ? range.location : range.location + rebuilt.length
        textView.setSelectedRange(NSRange(location: min(caret, textStorage.length), length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        comments?.warnIfFormatDropsReviewMarkup()
    }

    // MARK: Reviewing

    var hasSuggestions: Bool { Suggestions.hasSuggestions(textStorage) }

    /// Accepts or rejects suggestions (all of them when `ids` is nil) as one undoable change.
    func resolveSuggestions(_ ids: Set<String>?, accept: Bool) {
        guard state.isEditable else { return }
        let summaries = Suggestions.summaries(in: textStorage).filter { ids?.contains($0.id) ?? true }
        guard let first = summaries.first else { return }
        let range = summaries.dropFirst().reduce(first.range) { NSUnionRange($0, $1.range) }
        let rebuilt = Suggestions.resolved(textStorage, in: range, ids: ids, accept: accept)
        let textView = self.textView(forCharacterAt: range.location) ?? activeTextView
        isApplyingSuggestion = true
        defer { isApplyingSuggestion = false }
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(in: range, replacementString: rebuilt.string) else { return }
        textStorage.replaceCharacters(in: range, with: rebuilt)
        textView.didChangeText()
        let name = accept ? "Accept" : "Reject"
        undoManager?.setActionName(ids == nil ? "\(name) All Suggestions" : "\(name) Suggestion")
        textView.setSelectedRange(NSRange(location: min(range.location + rebuilt.length, textStorage.length), length: 0))
    }

    // MARK: Drawing

    /// Suggestions are drawn in their author's color, struck through when they delete text.
    func layoutManager(_ layoutManager: NSLayoutManager, shouldUseTemporaryAttributes attrs: [NSAttributedString.Key: Any] = [:],
                       forDrawingToScreen toScreen: Bool, atCharacterIndex charIndex: Int,
                       effectiveRange effectiveCharRange: NSRangePointer?) -> [NSAttributedString.Key: Any]? {
        guard layoutManager === self.layoutManager, charIndex < textStorage.length else { return attrs }
        var run = NSRange()
        let mark = textStorage.attribute(.pdSuggestion, at: charIndex, effectiveRange: &run) as? SuggestionMark
        if let effectiveCharRange {
            let current = effectiveCharRange.pointee
            effectiveCharRange.pointee = current.length > 0 ? NSIntersectionRange(current, run) : run
        }
        guard let mark else { return attrs }
        var result = attrs
        let color = AuthorColors.color(for: mark.author)
        result[.foregroundColor] = color
        if mark.kind == .deletion {
            result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            result[.strikethroughColor] = color
        }
        return result
    }
}
