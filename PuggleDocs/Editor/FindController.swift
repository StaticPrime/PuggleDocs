import AppKit
import Observation
import PuggleDocsKit

@Observable
final class FindState {
    var isVisible = false
    var showsReplace = false
    var query = ""
    var replacement = ""
    var matchCase = false
    var useRegex = false
    var ignoreDiacritics = false
    var matchCount = 0
    var currentIndex: Int?
    var message: String?
    /// Incremented to move keyboard focus into the find field.
    var focusRequest = 0

    var status: String {
        if let message { return message }
        guard !query.isEmpty else { return "" }
        guard matchCount > 0 else { return "0 of 0" }
        return "\((currentIndex ?? 0) + 1) of \(matchCount)"
    }
}

/// Find and replace over the whole document, highlighting every match on every page.
final class FindController {
    let state = FindState()
    private unowned let editor: EditorController
    private(set) var matches: [NSRange] = []
    private var refreshScheduled = false

    static let matchColor = NSColor(srgbRed: 1, green: 0.89, blue: 0.47, alpha: 1)
    static let currentColor = NSColor(srgbRed: 1, green: 0.62, blue: 0.2, alpha: 1)
    static let maximumMatches = 10_000

    init(editor: EditorController) {
        self.editor = editor
    }

    private var storage: NSTextStorage { editor.textStorage }

    // MARK: Showing

    func show(replace: Bool) {
        state.isVisible = true
        if replace { state.showsReplace = true }
        // Start from the selected text, as most editors do.
        let selection = editor.activeTextView.selectedRange()
        if selection.length > 0, selection.length < 200 {
            let selected = (storage.string as NSString).substring(with: selection)
            if !selected.contains("\n") { state.query = selected }
        }
        state.focusRequest += 1
        search()
    }

    func close() {
        clearHighlights()
        state.isVisible = false
        state.message = nil
        if let index = state.currentIndex, matches.indices.contains(index) {
            editor.activeTextView.setSelectedRange(matches[index])
        }
        editor.focus()
    }

    // MARK: Searching

    func search(preferring location: Int? = nil) {
        clearHighlights()
        matches = []
        state.message = nil
        let query = state.query
        guard !query.isEmpty else {
            state.matchCount = 0
            state.currentIndex = nil
            return
        }
        let string = storage.string as NSString
        let all = NSRange(location: 0, length: string.length)
        if state.useRegex {
            guard let regex = try? NSRegularExpression(pattern: query, options: state.matchCase ? [] : [.caseInsensitive]) else {
                state.message = "Invalid pattern"
                state.matchCount = 0
                state.currentIndex = nil
                return
            }
            for result in regex.matches(in: storage.string, range: all) where result.range.length > 0 {
                matches.append(result.range)
                if matches.count >= Self.maximumMatches { break }
            }
        } else {
            var options: NSString.CompareOptions = []
            if !state.matchCase { options.insert(.caseInsensitive) }
            if state.ignoreDiacritics { options.insert(.diacriticInsensitive) }
            var range = all
            while range.length > 0 {
                let found = string.range(of: query, options: options, range: range)
                guard found.location != NSNotFound, found.length > 0 else { break }
                matches.append(found)
                if matches.count >= Self.maximumMatches { break }
                range = NSRange(location: NSMaxRange(found), length: string.length - NSMaxRange(found))
            }
        }
        state.matchCount = matches.count
        let anchor = location ?? editor.activeTextView.selectedRange().location
        state.currentIndex = matches.isEmpty ? nil : (matches.firstIndex { $0.location >= anchor } ?? 0)
        applyHighlights()
        revealCurrent()
    }

    /// Re-runs the search after edits, keeping the position.
    func scheduleRefresh() {
        guard state.isVisible, !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            let location = self.state.currentIndex.flatMap { self.matches.indices.contains($0) ? self.matches[$0].location : nil }
            self.search(preferring: location)
        }
    }

    func next() { move(by: 1) }
    func previous() { move(by: -1) }

    private func move(by step: Int) {
        if !state.isVisible { show(replace: false) }
        guard !matches.isEmpty else { return }
        let current = state.currentIndex ?? (step > 0 ? -1 : 0)
        state.currentIndex = (current + step + matches.count) % matches.count
        applyHighlights()
        revealCurrent()
    }

    /// Scrolls to the current match. It is selected only when the find box closes, so the orange
    /// highlight is not hidden under the inactive selection color meanwhile.
    private func revealCurrent() {
        guard let index = state.currentIndex, matches.indices.contains(index) else { return }
        let range = matches[index]
        editor.textView(forCharacterAt: range.location)?.scrollRangeToVisible(range)
    }

    // MARK: Highlights

    private func applyHighlights() {
        let layoutManager = editor.layoutManager
        clearHighlights()
        for (index, range) in matches.enumerated() where NSMaxRange(range) <= storage.length {
            layoutManager.addTemporaryAttribute(.backgroundColor, value: index == state.currentIndex ? Self.currentColor : Self.matchColor,
                                                forCharacterRange: range)
        }
    }

    func clearHighlights() {
        guard storage.length > 0 else { return }
        editor.layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
    }

    // MARK: Replacing

    private func replacementString(for range: NSRange) -> String {
        guard state.useRegex, let regex = try? NSRegularExpression(pattern: state.query, options: state.matchCase ? [] : [.caseInsensitive]),
              let result = regex.firstMatch(in: storage.string, range: range) else { return state.replacement }
        return regex.replacementString(for: result, in: storage.string, offset: 0, template: state.replacement)
    }

    func replaceCurrent() {
        guard editor.state.isEditable, let index = state.currentIndex, matches.indices.contains(index) else { return }
        let range = matches[index]
        let replacement = replacementString(for: range)
        let textView = editor.activeTextView
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
        storage.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        editor.undoManager?.setActionName("Replace")
        search(preferring: range.location + (replacement as NSString).length)
    }

    func replaceAll() {
        guard editor.state.isEditable, !matches.isEmpty else { return }
        let ranges = matches
        let replacements = ranges.map(replacementString(for:))
        let textView = editor.activeTextView
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(inRanges: ranges.map { NSValue(range: $0) }, replacementStrings: replacements) else { return }
        storage.beginEditing()
        for (range, replacement) in zip(ranges, replacements).reversed() {
            storage.replaceCharacters(in: range, with: replacement)
        }
        storage.endEditing()
        textView.didChangeText()
        editor.undoManager?.setActionName("Replace All")
        let count = ranges.count
        search()
        state.message = "Replaced \(count)"
    }
}
