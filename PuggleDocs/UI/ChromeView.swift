import AppKit
import PuggleDocsKit
import SwiftUI

enum ToolbarMenu {
    case zoom, style, font, align, lineSpacing, bullets, numbers, checklist, mode, download, wordCount
}

/// Floating word count box over the bottom-left of the page area.
struct WordCountBadge: View {
    let state: EditorState
    let actions: ChromeActions

    var body: some View {
        if state.showsWordCount {
            ToolbarDropdown(help: "Word count options", open: { actions.popUp(.wordCount, from: $0) }) {
                Text(state.wordCountText)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.primaryText)
                    .monospacedDigit()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white).shadow(color: .black.opacity(0.2), radius: 3, y: 1))
            .padding(4)
        }
    }
}

/// What the header and toolbar ask their window to do.
protocol ChromeActions: AnyObject {
    var editor: EditorController { get }
    func popUp(_ menu: ToolbarMenu, from view: NSView?)
    func rename(to title: String)
    func showVersionHistory()
    func printDocument()
    func showCustomColorPanel(highlight: Bool)
    func dismissBanner()
    func showLinkEditor()
    func insertImageFromFile()
    func showCollaborate()
}

/// Header, toolbar and info banner above the ruler.
struct ChromeView: View {
    let state: EditorState
    let actions: ChromeActions

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(state: state, actions: actions, comments: actions.editor.comments.model)
            FormattingToolbar(state: state, actions: actions)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            if let banner = state.banner {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill").foregroundStyle(Color.orange)
                    Text(banner).font(.system(size: 12.5)).foregroundStyle(Theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Dismiss") { actions.dismissBanner() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Theme.bannerFill)
            }
        }
        .background(Color(nsColor: Theme.canvas))
        // The header shares the title bar band with the window buttons.
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// Lines a header row up with the window's close, minimise and zoom buttons.
enum TitlebarMetrics {
    static let rowHeight: CGFloat = 32

    /// Leading inset after the window buttons and the vertical center of those buttons, from the window top.
    @MainActor
    static func measure(_ window: NSWindow) -> (leading: CGFloat, centerY: CGFloat) {
        if window.styleMask.contains(.fullScreen) { return (18, 22) }
        guard let close = window.standardWindowButton(.closeButton),
              let zoom = window.standardWindowButton(.zoomButton), close.superview != nil else { return (78, 18) }
        let closeFrame = close.convert(close.bounds, to: nil)
        let zoomFrame = zoom.convert(zoom.bounds, to: nil)
        return (zoomFrame.maxX + 16, window.frame.height - closeFrame.midY)
    }
}

/// Document header: icon, editable title, format badge and save status, with version history and
/// Download on the right. Menus live in the macOS menu bar, as in every Mac app.
struct HeaderView: View {
    let state: EditorState
    let actions: ChromeActions
    @Bindable var comments: CommentsModel
    @State private var titleText = ""
    @FocusState private var titleFocused: Bool

    private var titleWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 16)
        let text = titleText.isEmpty ? "Untitled document" : titleText
        return min(520, max(80, (text as NSString).size(withAttributes: [.font: font]).width + 14))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
                .help("PuggleDocs")
            TextField("Untitled document", text: $titleText)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundStyle(Theme.primaryText)
                .frame(width: titleWidth, height: 24)
                .padding(.horizontal, 3)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(titleFocused ? Theme.accent : .clear, lineWidth: 1.5))
                .hoverBackground()
                .focused($titleFocused)
                .onSubmit { commitTitle() }
                .disabled(!state.collaboration.isOwner && state.collaboration.isShared)
                .help(state.collaboration.isShared && !state.collaboration.isOwner ? "Only its owner can rename it" : "Rename")
            if let badge = state.formatBadge {
                Text(badge)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.secondaryText.opacity(0.5), lineWidth: 1))
                    .help("This file is stored in \(badge.dropFirst()) format")
            }
            Image(systemName: statusSymbol)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .help(statusText)
            Spacer(minLength: 12)
            // As the window narrows, the status words go first, then the buttons' words.
            ViewThatFits(in: .horizontal) {
                trailingControls(showsStatus: true, compact: false)
                trailingControls(showsStatus: false, compact: false)
                trailingControls(showsStatus: false, compact: true)
            }
        }
        .frame(height: TitlebarMetrics.rowHeight)
        .padding(.leading, state.titlebarLeading)
        .padding(.trailing, 14)
        .padding(.top, max(0, state.titlebarCenterY - TitlebarMetrics.rowHeight / 2))
        .padding(.bottom, 8)
        .background(WindowDragArea())
        .onAppear { titleText = state.title }
        .onChange(of: state.title) { _, newValue in if !titleFocused { titleText = newValue } }
        .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
        .onChange(of: state.renameRequest) { _, _ in titleFocused = true }
        .onExitCommand { titleText = state.title; titleFocused = false; actions.editor.focus() }
    }

    private func trailingControls(showsStatus: Bool, compact: Bool) -> some View {
        HStack(alignment: .center, spacing: 8) {
            if showsStatus {
                Text(statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .fixedSize()
            }
            CollaboratorAvatars(state: state.collaboration)
            ToolbarIconButton(symbol: "text.bubble", help: "Open comment history (⇧⌥⌘A)", isOn: comments.showsHistory) {
                comments.showsHistory.toggle()
            }
            .popover(isPresented: $comments.showsHistory, arrowEdge: .bottom) {
                CommentHistoryView(model: comments, controller: actions.editor.comments)
            }
            ToolbarIconButton(symbol: "clock.arrow.circlepath", help: "Open version history") { actions.showVersionHistory() }
            Button { actions.showCollaborate() } label: {
                Group {
                    if compact {
                        Image(systemName: collaborateSymbol)
                    } else {
                        Label("Collaborate", systemImage: collaborateSymbol)
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white)
                .padding(.horizontal, compact ? 10 : 12)
                .frame(height: 30)
                .background(Capsule().fill(Theme.accent))
                .contentShape(Capsule())
                .fixedSize()
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(state.collaboration.isShared ? "See and change who this document is shared with" : "Share this document with people to work on it together")
            .accessibilityLabel("Collaborate")
            ToolbarDropdown(help: "Download a copy", showsChevron: false, open: { actions.popUp(.download, from: $0) }) {
                Group {
                    if compact {
                        Image(systemName: "arrow.down.to.line")
                    } else {
                        Label("Download", systemImage: "arrow.down.to.line")
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(red: 0.0, green: 0.12, blue: 0.27))
                .padding(.horizontal, compact ? 10 : 10)
                .frame(height: 30)
                .background(Capsule().fill(Color(red: 0.76, green: 0.87, blue: 1.0)))
                .fixedSize()
            }
        }
    }

    private var collaborateSymbol: String { state.collaboration.isShared ? "person.2.fill" : "person.badge.plus" }

    /// While shared, how its iCloud copy is keeping up; otherwise how its file is.
    private var statusText: String { state.collaboration.isShared ? state.collaboration.statusText : state.saveStatus.text }
    private var statusSymbol: String { state.collaboration.isShared ? state.collaboration.statusSymbol : state.saveStatus.symbol }

    private func commitTitle() {
        let trimmed = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == state.title {
            titleText = state.title
        } else {
            actions.rename(to: trimmed)
        }
        if titleFocused {
            titleFocused = false
            actions.editor.focus()
        }
    }
}

/// The rounded formatting bar. Groups that do not fit move into an overflow popover.
struct FormattingToolbar: View {
    let state: EditorState
    let actions: ChromeActions
    @State private var showingOverflow = false

    private var editor: EditorController { actions.editor }
    private var editable: Bool { state.isEditable }
    private var summary: FormattingSummary { state.summary }

    var body: some View {
        HStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                row(overflowFrom: 99)
                row(overflowFrom: 6)
                row(overflowFrom: 5)
                row(overflowFrom: 4)
            }
            Spacer(minLength: 4)
            modeControl
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(Capsule().fill(Theme.toolbarFill))
    }

    /// Groups 0...6; groups at index >= `overflowFrom` are reachable through the overflow button.
    private func row(overflowFrom: Int) -> some View {
        HStack(spacing: 1) {
            ForEach(0..<min(overflowFrom, groupCount), id: \.self) { index in
                if index > 0 { ToolbarDivider() }
                group(index)
            }
            if overflowFrom < groupCount {
                ToolbarDivider()
                ToolbarIconButton(symbol: "ellipsis", help: "More", isOn: showingOverflow) { showingOverflow = true }
                    .popover(isPresented: $showingOverflow, arrowEdge: .bottom) {
                        HStack(spacing: 1) {
                            ForEach(overflowFrom..<groupCount, id: \.self) { index in
                                if index > overflowFrom { ToolbarDivider() }
                                group(index)
                            }
                        }
                        .padding(8)
                    }
            }
        }
        .fixedSize()
    }

    private let groupCount = 7

    @ViewBuilder
    private func group(_ index: Int) -> some View {
        switch index {
        case 0: historyGroup
        case 1: zoomControl
        case 2: styleControl
        case 3: fontControl
        case 4: FontSizeControl(size: summary.fontSize, isEnabled: editable, set: { editor.setFontSize($0) }, step: { editor.adjustFontSize(by: $0) })
        case 5: textStyleGroup
        default: paragraphGroup
        }
    }

    private var historyGroup: some View {
        HStack(spacing: 1) {
            ToolbarIconButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)", isEnabled: state.canUndo && editable) {
                editor.undoManager?.undo()
            }
            ToolbarIconButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", isEnabled: state.canRedo && editable) {
                editor.undoManager?.redo()
            }
            ToolbarIconButton(symbol: "printer", help: "Print (⌘P)") { actions.printDocument() }
            ToolbarIconButton(symbol: "textformat.abc.dottedunderline", help: "Spelling and grammar check (⌘:)") {
                editor.focus()
                NSApp.sendAction(#selector(NSText.showGuessPanel(_:)), to: nil, from: nil)
            }
            ToolbarIconButton(symbol: "paintbrush.pointed", help: "Paint format", isOn: state.isPaintFormatActive, isEnabled: editable) {
                editor.togglePaintFormat(sticky: NSEvent.modifierFlags.contains(.option))
            }
        }
    }

    private var zoomControl: some View {
        ToolbarDropdown(help: "Zoom", open: { actions.popUp(.zoom, from: $0) }) {
            Text(state.zoomLabel).font(.system(size: 13)).foregroundStyle(Theme.primaryText).frame(width: 38)
        }
    }

    private var styleControl: some View {
        ToolbarDropdown(help: "Styles", isEnabled: editable, open: { actions.popUp(.style, from: $0) }) {
            Text(summary.namedStyle?.displayName ?? "")
                .font(.system(size: 13))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .frame(width: 84, alignment: .leading)
        }
    }

    private var fontControl: some View {
        ToolbarDropdown(help: "Font", isEnabled: editable, open: { actions.popUp(.font, from: $0) }) {
            Text(summary.fontFamily ?? "")
                .font(.system(size: 13))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .frame(width: 84, alignment: .leading)
        }
    }

    private var textStyleGroup: some View {
        HStack(spacing: 1) {
            ToolbarIconButton(symbol: "bold", help: "Bold (⌘B)", isOn: summary.isBold, isEnabled: editable) { editor.toggleBold() }
            ToolbarIconButton(symbol: "italic", help: "Italic (⌘I)", isOn: summary.isItalic, isEnabled: editable) { editor.toggleItalic() }
            ToolbarIconButton(symbol: "underline", help: "Underline (⌘U)", isOn: summary.isUnderlined, isEnabled: editable) { editor.toggleUnderline() }
            ColorToolbarButton(isHighlight: false, currentHex: summary.textColorHex, isEnabled: editable) { color in
                if let color { editor.setTextColor(color) }
            } custom: { actions.showCustomColorPanel(highlight: false) }
            ColorToolbarButton(isHighlight: true, currentHex: summary.highlightHex, isEnabled: editable) { color in
                editor.setHighlight(color)
            } custom: { actions.showCustomColorPanel(highlight: true) }
            ToolbarIconButton(symbol: "link", help: "Insert link (⌘K)", isOn: summary.link != nil, isEnabled: editable) { actions.showLinkEditor() }
            ToolbarIconButton(symbol: "plus.bubble", help: "Add comment (⌥⌘M)", isEnabled: state.canComment) {
                editor.comments.startDraft()
            }
            ToolbarIconButton(symbol: "photo", help: "Insert image", isEnabled: editable) { actions.insertImageFromFile() }
        }
    }

    private var alignmentSymbol: String {
        switch summary.alignment {
        case .center: "text.aligncenter"
        case .right: "text.alignright"
        case .justified: "text.justify"
        default: "text.alignleft"
        }
    }

    private var paragraphGroup: some View {
        HStack(spacing: 1) {
            ToolbarDropdown(help: "Align & indent", isEnabled: editable, open: { actions.popUp(.align, from: $0) }) {
                Image(systemName: alignmentSymbol).font(.system(size: 14)).foregroundStyle(Theme.secondaryText)
            }
            ToolbarDropdown(help: "Line & paragraph spacing", showsChevron: false, isEnabled: editable, open: { actions.popUp(.lineSpacing, from: $0) }) {
                Image(systemName: "arrow.up.and.down.text.horizontal").font(.system(size: 14)).foregroundStyle(Theme.secondaryText)
            }
            SplitToolbarButton(symbol: "checklist", help: "Checklist (⇧⌘9)", isOn: summary.listKind == .checklist, isEnabled: editable,
                               action: { editor.toggleList(.checklist) }, openPresets: { actions.popUp(.checklist, from: $0) })
            SplitToolbarButton(symbol: "list.bullet", help: "Bulleted list (⇧⌘8)", isOn: summary.listKind == .bulleted, isEnabled: editable,
                               action: { editor.toggleList(.bulleted) }, openPresets: { actions.popUp(.bullets, from: $0) })
            SplitToolbarButton(symbol: "list.number", help: "Numbered list (⇧⌘7)", isOn: summary.listKind == .numbered, isEnabled: editable,
                               action: { editor.toggleList(.numbered) }, openPresets: { actions.popUp(.numbers, from: $0) })
            ToolbarIconButton(symbol: "decrease.indent", help: "Decrease indent (⌘[)", isEnabled: editable) { editor.indent(increase: false) }
            ToolbarIconButton(symbol: "increase.indent", help: "Increase indent (⌘])", isEnabled: editable) { editor.indent(increase: true) }
            ToolbarIconButton(symbol: "textformat", help: "Clear formatting (⌘\\)", isEnabled: editable) { editor.clearFormatting() }
        }
    }

    private var modeControl: some View {
        ToolbarDropdown(help: "Editing mode", open: { actions.popUp(.mode, from: $0) }) {
            HStack(spacing: 5) {
                Image(systemName: state.modeSymbol).font(.system(size: 13))
                Text(state.modeTitle).font(.system(size: 13))
            }
            // Suggesting shows in green.
            .foregroundStyle(state.mode == .suggesting ? Color(red: 0.09, green: 0.50, blue: 0.22) : Theme.primaryText)
        }
    }
}
