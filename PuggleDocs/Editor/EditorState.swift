import AppKit
import Observation
import PuggleDocsKit

enum EditingMode: String, CaseIterable {
    case editing, suggesting, viewing

    var title: String {
        switch self {
        case .editing: "Editing"
        case .suggesting: "Suggesting"
        case .viewing: "Viewing"
        }
    }

    var detail: String {
        switch self {
        case .editing: "Edit document directly"
        case .suggesting: "Edits become suggestions"
        case .viewing: "Read or print final document"
        }
    }

    var symbol: String {
        switch self {
        case .editing: "pencil"
        case .suggesting: "pencil.line"
        case .viewing: "eye"
        }
    }
}

enum SaveStatus: Equatable {
    case draft, edited, saving, saved

    var text: String {
        switch self {
        case .draft: "Not saved to a file yet"
        case .edited: "Saving…"
        case .saving: "Saving…"
        case .saved: "Saved to this Mac"
        }
    }

    var symbol: String {
        switch self {
        case .draft: "doc.badge.clock"
        case .edited, .saving: "arrow.triangle.2.circlepath"
        case .saved: "checkmark.circle"
        }
    }
}

/// What can be done to a document's text here.
enum DocumentAccess: Equatable {
    /// Everything: the document is this person's, or shared with them to edit.
    case full
    /// Shared with them to read and comment on: comments, but no changes to the text.
    case commentOnly
    /// Nothing for now: its shared copy is still on its way.
    case locked
}

/// Everything the SwiftUI header and toolbar display for one window.
@Observable
final class EditorState {
    var summary = FormattingSummary()
    var zoom: CGFloat = 1
    var canUndo = false
    var canRedo = false
    var isSpellCheckEnabled = true
    var isPaintFormatActive = false
    var mode: EditingMode = .editing
    var title = "Untitled document"
    var formatBadge: String?
    var saveStatus: SaveStatus = .draft
    var showsRuler = true
    /// Where the header row sits next to the window buttons (see `TitlebarMetrics`).
    var titlebarLeading: CGFloat = 78
    var titlebarCenterY: CGFloat = 18
    var banner: String?
    var pageCount = 1
    var usedHeadingLevels: Set<Int> = []
    /// Incremented to ask the header to focus the title field (File ▸ Rename).
    var renameRequest = 0
    /// The floating word count box ("Display word count while typing").
    var showsWordCount = UserDefaults.standard.bool(forKey: WordCountMetric.visibilityKey)
    var wordCountMetric = WordCountMetric.saved
    var wordCountText = ""
    /// Document outline panel.
    var showsOutline = UserDefaults.standard.bool(forKey: "PDShowOutline")
    var outline: [OutlineEntry] = []
    var currentOutlineIndex: Int?

    /// What sharing allows here.
    var access: DocumentAccess = .full
    /// Who the document is shared with, and how its shared copy is keeping up.
    let collaboration = CollaborationState()

    /// Suggesting is editing too: typing and deleting become suggestions.
    var isEditable: Bool { mode != .viewing && access == .full }

    /// Comments can be added outside Viewing mode, even by people who may only comment.
    var canComment: Bool { mode != .viewing && access != .locked }

    /// The mode as the toolbar shows it: people who may only comment are commenting.
    var modeTitle: String { access == .commentOnly && mode != .viewing ? "Commenting" : mode.title }
    var modeSymbol: String { access == .commentOnly && mode != .viewing ? "text.bubble" : mode.symbol }

    var zoomLabel: String { "\(Int((zoom * 100).rounded()))%" }
}

/// What the floating word count box shows.
enum WordCountMetric: Int, CaseIterable {
    case pages, words, characters, charactersExcludingSpaces

    static let visibilityKey = "PDShowWordCount"
    static let metricKey = "PDWordCountMetric"

    static var saved: WordCountMetric {
        guard UserDefaults.standard.object(forKey: metricKey) != nil else { return .words }
        return WordCountMetric(rawValue: UserDefaults.standard.integer(forKey: metricKey)) ?? .words
    }

    var title: String {
        switch self {
        case .pages: "Pages"
        case .words: "Words"
        case .characters: "Characters"
        case .charactersExcludingSpaces: "Characters excluding spaces"
        }
    }

    private func value(_ statistics: EditorController.Statistics) -> Int {
        switch self {
        case .pages: statistics.pages
        case .words: statistics.words
        case .characters: statistics.characters
        case .charactersExcludingSpaces: statistics.charactersExcludingSpaces
        }
    }

    private func noun(_ count: Int) -> String {
        switch self {
        case .pages: count == 1 ? "page" : "pages"
        case .words: count == 1 ? "word" : "words"
        case .characters, .charactersExcludingSpaces: count == 1 ? "character" : "characters"
        }
    }

    /// "345 words", or "12 of 345 words" for a selection (pages always count the whole document).
    func text(total: EditorController.Statistics, selection: EditorController.Statistics?) -> String {
        let all = value(total)
        if let selection, self != .pages {
            return "\(value(selection).formatted()) of \(all.formatted()) \(noun(all))"
        }
        return "\(all.formatted()) \(noun(all))"
    }
}

/// Fonts the user picked recently, shown at the top of the font menu.
enum RecentFonts {
    private static let key = "PDRecentFonts"

    static var all: [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func note(_ family: String) {
        var fonts = all.filter { $0 != family }
        fonts.insert(family, at: 0)
        UserDefaults.standard.set(Array(fonts.prefix(5)), forKey: key)
    }
}
