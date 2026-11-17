import AppKit
import PuggleDocsKit
import SwiftUI

struct OutlineEntry: Identifiable, Equatable {
    let location: Int
    let title: String
    /// 0 for the title, 1...6 for headings.
    let level: Int
    var id: Int { location }
}

enum OutlineBuilder {
    static func entries(in storage: NSAttributedString) -> [OutlineEntry] {
        guard storage.length > 0 else { return [] }
        let string = storage.string as NSString
        var entries: [OutlineEntry] = []
        storage.enumerateAttribute(.pdNamedStyle, in: NSRange(location: 0, length: storage.length), options: []) { value, run, _ in
            guard let raw = value as? String, let style = NamedStyle(rawValue: raw), style == .title || style.headingLevel != nil else { return }
            var location = run.location
            while location < NSMaxRange(run) {
                let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
                location = NSMaxRange(paragraph)
                guard paragraph.location >= run.location else { continue }
                let title = string.substring(with: paragraph).trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\u{0C}", with: "")
                guard !title.isEmpty else { continue }
                entries.append(OutlineEntry(location: paragraph.location, title: String(title.prefix(120)), level: style.headingLevel ?? 0))
            }
        }
        return entries
    }

    /// Index of the last entry at or before `location`.
    static func currentIndex(in entries: [OutlineEntry], location: Int) -> Int? {
        entries.lastIndex { $0.location <= location }
    }
}

/// The document outline panel on the left of the pages.
struct OutlinePanel: View {
    let state: EditorState
    let select: (OutlineEntry) -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Outline")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                ToolbarIconButton(symbol: "arrow.left", help: "Hide document outline (⌥⌘A)", action: close)
            }
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            if state.outline.isEmpty {
                Text("Headings you add to the document will appear here.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(state.outline.enumerated()), id: \.element.id) { index, entry in
                            OutlineRow(entry: entry, isCurrent: index == state.currentOutlineIndex) { select(entry) }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: Theme.canvas))
    }
}

private struct OutlineRow: View {
    let entry: OutlineEntry
    let isCurrent: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(isCurrent ? Theme.accent : Color.clear)
                    .frame(width: 3)
                Text(entry.title)
                    .font(.system(size: 13, weight: entry.level == 0 ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Theme.accent : Theme.primaryText)
                    .lineLimit(2)
                    .padding(.leading, 13 + CGFloat(max(0, entry.level - 1)) * 12)
                    .padding(.trailing, 10)
                    .padding(.vertical, 5)
                Spacer(minLength: 0)
            }
            .background(hovering ? Theme.hoverFill : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(entry.title)
    }
}

/// Small round button at the top left of the canvas that opens the outline.
struct OutlineToggleButton: View {
    let state: EditorState
    let open: () -> Void

    var body: some View {
        if !state.showsOutline {
            Button(action: open) {
                Image(systemName: "list.bullet.indent")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white).shadow(color: .black.opacity(0.15), radius: 2, y: 1))
            }
            .buttonStyle(.plain)
            .help("Show document outline (⌥⌘A)")
            .padding(6)
        }
    }
}
