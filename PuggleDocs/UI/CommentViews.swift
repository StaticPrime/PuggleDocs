import AppKit
import PuggleDocsKit
import SwiftUI

// MARK: - Shared pieces

enum CommentStyle {
    static let inactiveFill = Color(red: 0xF8 / 255, green: 0xFA / 255, blue: 0xFD / 255)
    static let quoteBar = Color(red: 0xFB / 255, green: 0xBC / 255, blue: 0x04 / 255)
    static let border = Color(red: 0xC4 / 255, green: 0xC7 / 255, blue: 0xC5 / 255)
}

/// "10:42 AM Today", "9:15 AM Yesterday", "Mar 3" or "Mar 3, 2025".
enum CommentDates {
    static func display(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "\(time) Today" }
        if calendar.isDateInYesterday(date) { return "\(time) Yesterday" }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

/// A round avatar with the author's initials, colored by name.
struct CommentAvatar: View {
    let name: String
    var size: CGFloat = 32

    /// The same color as the author's suggestions.
    static func color(for name: String) -> Color { Color(nsColor: AuthorColors.color(for: name)) }

    var body: some View {
        Text(CommentThread.initials(name))
            .font(.system(size: size * 0.4, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Self.color(for: name)))
            .accessibilityHidden(true)
    }
}

struct CommentPrimaryButton: View {
    let title: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isEnabled ? Color.white : Theme.primaryText.opacity(0.38))
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(Capsule().fill(isEnabled ? Theme.accent : Theme.primaryText.opacity(0.12)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(!isEnabled)
    }
}

struct CommentTextButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(hovering ? Theme.accent.opacity(0.08) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
    }
}

struct CommentIconButton: View {
    let symbol: String
    let help: String
    var rotation: Double = 0
    let action: (NSView?) -> Void
    @State private var anchor = AnchorHolder()
    @State private var hovering = false

    var body: some View {
        Button {
            action(anchor.view)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .rotationEffect(.degrees(rotation))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 28, height: 28)
                .background(Circle().fill(hovering ? Theme.hoverFill : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .background(AnchorView(holder: anchor))
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Runs a closure from a menu item (the item keeps it alive as its represented object).
final class MenuAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) { self.handler = handler }

    @objc func run(_ sender: Any?) { handler() }

    static func item(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(handler)
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        return item
    }
}

func popUpMenu(_ items: [NSMenuItem], below view: NSView?) {
    guard let view else { return }
    let menu = NSMenu()
    items.forEach(menu.addItem)
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 2), in: view)
}

// MARK: - Cards

/// One comment or reply: avatar, name and time, then the text (or an editor for it).
struct CommentEntryView: View {
    let author: String
    let date: Date
    let text: String
    let showsControls: Bool
    let isEditing: Bool
    @Binding var editText: String
    var onResolve: (() -> Void)?
    /// In a shared document, people change only their own comments.
    var canEdit = true
    var canDelete = true
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onSave: () -> Void
    let onCancelEdit: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                CommentAvatar(name: author)
                VStack(alignment: .leading, spacing: 1) {
                    Text(author)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    Text(CommentDates.display(date))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if showsControls || hovering {
                    if let onResolve {
                        CommentIconButton(symbol: "checkmark", help: "Mark as resolved and hide discussion") { _ in onResolve() }
                    }
                    if canEdit || canDelete {
                        CommentIconButton(symbol: "ellipsis", help: "More options", rotation: 90) { anchor in
                            popUpMenu((canEdit ? [MenuAction.item("Edit", onEdit)] : []) + (canDelete ? [MenuAction.item("Delete", onDelete)] : []),
                                      below: anchor)
                        }
                    }
                }
            }
            if isEditing {
                CommentInput(text: $editText, placeholder: "", focusOnAppear: true, onSubmit: onSave, onCancel: onCancelEdit)
                HStack(spacing: 6) {
                    Spacer()
                    CommentTextButton(title: "Cancel", action: onCancelEdit)
                    CommentPrimaryButton(title: "Save", isEnabled: !editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: onSave)
                }
            } else {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onHover { hovering = $0 }
    }
}

/// A comment thread beside its text. The active card shows a reply box.
struct CommentCard: View {
    let threadID: String
    @Bindable var model: CommentsModel
    let controller: CommentsController

    var body: some View {
        if let thread = model.thread(threadID) {
            let active = model.activeID == threadID
            VStack(alignment: .leading, spacing: 14) {
                CommentEntryView(author: thread.author, date: thread.date, text: thread.text, showsControls: active,
                                 isEditing: model.editing == .thread(threadID), editText: $model.editText,
                                 onResolve: { controller.setResolved(threadID, true) },
                                 canEdit: controller.mayEdit(authorID: thread.authorID),
                                 canDelete: controller.mayDelete(authorID: thread.authorID),
                                 onEdit: { edit(.thread(threadID)) },
                                 onDelete: { controller.delete(threadID) },
                                 onSave: { controller.saveEdit() },
                                 onCancelEdit: { controller.cancelEdit() })
                ForEach(thread.replies) { reply in
                    CommentEntryView(author: reply.author, date: reply.date, text: reply.text, showsControls: active,
                                     isEditing: model.editing == .reply(thread: threadID, reply: reply.id), editText: $model.editText,
                                     canEdit: controller.mayEdit(authorID: reply.authorID),
                                     canDelete: controller.mayDelete(authorID: reply.authorID),
                                     onEdit: { edit(.reply(thread: threadID, reply: reply.id)) },
                                     onDelete: { controller.deleteReply(reply.id, in: threadID) },
                                     onSave: { controller.saveEdit() },
                                     onCancelEdit: { controller.cancelEdit() })
                }
                if active, model.editing == nil {
                    VStack(alignment: .trailing, spacing: 8) {
                        CommentInput(text: $model.replyText, placeholder: "Reply", onSubmit: { controller.reply(to: threadID) },
                                     onCancel: { controller.activate(nil) })
                        if !model.replyText.isEmpty {
                            HStack(spacing: 6) {
                                CommentTextButton(title: "Cancel") { model.replyText = "" }
                                CommentPrimaryButton(title: "Reply",
                                                     isEnabled: !model.replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                                    controller.reply(to: threadID)
                                }
                            }
                        }
                    }
                }
            }
            .padding(12)
            .frame(width: CommentsController.cardWidth, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(active ? Color.white : CommentStyle.inactiveFill))
            .shadow(color: .black.opacity(active ? 0.2 : 0.14), radius: active ? 4 : 1.2, y: active ? 2 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture { if !active { controller.activate(threadID) } }
            .padding(CommentsController.shadowPadding)
        }
    }

    private func edit(_ editing: CommentsModel.Editing) {
        controller.activate(threadID)
        controller.beginEditing(editing)
    }
}

/// A suggested edit: who suggested what, with accept and reject.
struct SuggestionCard: View {
    let suggestionID: String
    let model: CommentsModel
    let controller: CommentsController

    var body: some View {
        if let suggestion = model.suggestions.first(where: { $0.id == suggestionID }) {
            let active = model.activeSuggestion == suggestionID
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    CommentAvatar(name: suggestion.author)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(suggestion.author)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.primaryText)
                            .lineLimit(1)
                        Text(CommentDates.display(suggestion.date))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    CommentIconButton(symbol: "checkmark", help: "Accept suggestion") { _ in
                        controller.resolveSuggestion(suggestionID, accept: true)
                    }
                    CommentIconButton(symbol: "xmark", help: "Reject suggestion") { _ in
                        controller.resolveSuggestion(suggestionID, accept: false)
                    }
                }
                Text(Self.describe(suggestion))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .frame(width: CommentsController.cardWidth, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(active ? Color.white : CommentStyle.inactiveFill))
            .shadow(color: .black.opacity(active ? 0.2 : 0.14), radius: active ? 4 : 1.2, y: active ? 2 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture { if !active { controller.activateSuggestion(suggestionID) } }
            .padding(CommentsController.shadowPadding)
        }
    }

    /// "Add: “text”", "Delete: “text”" or "Replace: “old” with “new”".
    static func describe(_ suggestion: SuggestionSummary) -> AttributedString {
        func label(_ text: String) -> AttributedString {
            var piece = AttributedString(text)
            piece.font = .system(size: 13, weight: .semibold)
            return piece
        }
        func quote(_ text: String) -> AttributedString {
            let visible = text.replacingOccurrences(of: "\n", with: "↵").replacingOccurrences(of: "\u{0C}", with: "")
            return AttributedString("“" + (visible.count > 90 ? String(visible.prefix(90)) + "…" : visible) + "”")
        }
        if suggestion.isReplacement {
            return label("Replace: ") + quote(suggestion.deleted) + label(" with ") + quote(suggestion.inserted)
        }
        if !suggestion.inserted.isEmpty { return label("Add: ") + quote(suggestion.inserted) }
        return label("Delete: ") + quote(suggestion.deleted)
    }
}

/// A new comment being written.
struct CommentDraftCard: View {
    @Bindable var model: CommentsModel
    let controller: CommentsController

    private var text: Binding<String> {
        Binding(get: { model.draft?.text ?? "" }, set: { model.draft?.text = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                CommentAvatar(name: model.authorName)
                Text(model.authorName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
            }
            CommentInput(text: text, placeholder: "Comment", focusOnAppear: true,
                         onSubmit: { controller.commitDraft() }, onCancel: { controller.cancelDraft() })
            HStack(spacing: 6) {
                Spacer()
                CommentTextButton(title: "Cancel") { controller.cancelDraft() }
                CommentPrimaryButton(title: "Comment", isEnabled: !text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    controller.commitDraft()
                }
            }
        }
        .padding(12)
        .frame(width: CommentsController.cardWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        .padding(CommentsController.shadowPadding)
    }
}

/// The round button that appears beside a selection.
struct AddCommentButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus.bubble")
                .font(.system(size: 15))
                .foregroundStyle(hovering ? Theme.accent : Theme.secondaryText)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.white))
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .help("Add comment (⌥⌘M)")
        .accessibilityLabel("Add comment")
        .padding(CommentsController.shadowPadding)
    }
}

// MARK: - Comment history

struct CommentHistoryView: View {
    @Bindable var model: CommentsModel
    let controller: CommentsController
    @State private var filter = Filter.all
    @State private var editingName = false
    @State private var nameText = ""

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", open = "Open", resolved = "Resolved"
        var id: String { rawValue }
    }

    private var rows: [CommentThread] {
        model.historyThreads.filter { thread in
            switch filter {
            case .all: true
            case .open: !thread.resolved
            case .resolved: thread.resolved
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Comments")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            if rows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 28))
                        .foregroundStyle(Theme.secondaryText)
                    Text(filter == .resolved ? "No resolved comments" : "No comments yet")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.primaryText)
                    Text("Select text, then choose Insert ▸ Comment (⌥⌘M).")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(rows) { thread in row(thread) }
                    }
                    .padding(12)
                }
                .frame(height: min(480, CGFloat(rows.count) * 132 + 24))
            }
            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(width: 380)
        .background(Color.white)
    }

    private func row(_ thread: CommentThread) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let excerpt = model.excerpts[thread.id] {
                HStack(spacing: 8) {
                    Rectangle().fill(CommentStyle.quoteBar).frame(width: 3)
                    Text(excerpt)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("The commented text was deleted")
                    .font(.system(size: 12).italic())
                    .foregroundStyle(Theme.secondaryText)
            }
            HStack(spacing: 8) {
                CommentAvatar(name: thread.author, size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(thread.author).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.primaryText).lineLimit(1)
                    Text(CommentDates.display(thread.date)).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                if thread.resolved {
                    Text("Resolved")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(red: 0.09, green: 0.50, blue: 0.22))
                    CommentTextButton(title: "Re-open") { controller.setResolved(thread.id, false) }
                }
            }
            Text(thread.text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !thread.replies.isEmpty {
                Text(thread.replies.count == 1 ? "1 reply" : "\(thread.replies.count) replies")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(CommentStyle.border.opacity(0.7), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { controller.reveal(thread.id) }
        .help(model.excerpts[thread.id] == nil ? "" : "Show in document")
    }

    @ViewBuilder
    private var footer: some View {
        if editingName {
            HStack(spacing: 6) {
                TextField("Your name", text: $nameText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveName)
                CommentTextButton(title: "Cancel") { editingName = false }
                CommentPrimaryButton(title: "Save", isEnabled: !nameText.trimmingCharacters(in: .whitespaces).isEmpty, action: saveName)
            }
        } else {
            HStack(spacing: 6) {
                CommentAvatar(name: model.authorName, size: 20)
                Text("Commenting as \(model.authorName)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                Spacer()
                CommentTextButton(title: "Change name") {
                    nameText = model.authorName
                    editingName = true
                }
            }
        }
    }

    private func saveName() {
        controller.setAuthorName(nameText)
        editingName = false
    }
}

// MARK: - Multi-line input

/// A growing text box for comments: Return adds a line, ⌘Return posts and Esc cancels.
struct CommentInput: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var focusOnAppear = false
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> CommentInputView {
        let view = CommentInputView()
        view.textView.delegate = context.coordinator
        view.textView.string = text
        view.wantsInitialFocus = focusOnAppear
        return view
    }

    func updateNSView(_ view: CommentInputView, context: Context) {
        context.coordinator.parent = self
        if view.textView.string != text { view.textView.string = text }
        view.textView.placeholder = placeholder
        let coordinator = context.coordinator
        view.textView.onSubmit = { coordinator.parent.onSubmit() }
        view.textView.onCancel = { coordinator.parent.onCancel() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CommentInputView, context: Context) -> CGSize? {
        let width = proposal.width ?? CommentsController.cardWidth - 24
        return CGSize(width: width, height: nsView.height(forWidth: width))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommentInput

        init(_ parent: CommentInput) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

final class CommentInputView: NSView {
    let textView = CommentTextView()
    var wantsInitialFocus = false
    private var focused = false {
        didSet { needsDisplay = true }
    }
    static let inset = NSSize(width: 9, height: 7)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textColor = NSColor(srgbRed: 0x1F / 255, green: 0x1F / 255, blue: 0x1F / 255, alpha: 1)
        textView.insertionPointColor = .black
        textView.drawsBackground = false
        textView.textContainerInset = Self.inset
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.focusChanged = { [weak self] in self?.focused = $0 }
        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        textView.frame = bounds
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard let container = textView.textContainer, let layoutManager = textView.layoutManager,
              let font = textView.font else { return 32 }
        let saved = container.size
        container.size = NSSize(width: max(20, width - Self.inset.width * 2), height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height
        container.size = saved
        return ceil(max(used, layoutManager.defaultLineHeight(for: font)) + Self.inset.height * 2)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard wantsInitialFocus, let window else { return }
        wantsInitialFocus = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            window.makeFirstResponder(self.textView)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let width: CGFloat = focused ? 2 : 1
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: width / 2, dy: width / 2), xRadius: 6, yRadius: 6)
        NSColor.white.setFill()
        path.fill()
        (focused ? NSColor(srgbRed: 0x0B / 255, green: 0x57 / 255, blue: 0xD0 / 255, alpha: 1)
                 : NSColor(srgbRed: 0x74 / 255, green: 0x77 / 255, blue: 0x75 / 255, alpha: 1)).setStroke()
        path.lineWidth = width
        path.stroke()
    }
}

final class CommentTextView: NSTextView {
    var placeholder = "" {
        didSet { if placeholder != oldValue { needsDisplay = true } }
    }
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    var focusChanged: ((Bool) -> Void)?
    /// Typing in a comment has its own undo, separate from the document's.
    private let localUndoManager = UndoManager()

    override var undoManager: UndoManager? { localUndoManager }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusChanged?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { focusChanged?(false) }
        return accepted
    }

    /// ⌘Return posts; it must not reach the menu, where it inserts a page break.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, event.modifierFlags.contains(.command), event.keyCode == 36 || event.keyCode == 76 {
            onSubmit?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor(srgbRed: 0x44 / 255, green: 0x47 / 255, blue: 0x46 / 255, alpha: 0.8),
        ]
        (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width, y: textContainerInset.height), withAttributes: attributes)
    }
}
