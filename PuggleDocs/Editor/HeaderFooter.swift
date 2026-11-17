import AppKit
import PuggleDocsKit

/// Lays out one page's copy of the shared header or footer, and tells page fields which page it is.
nonisolated final class HeaderLayoutManager: NSLayoutManager, PageNumberProviding {
    @objc dynamic var pageNumber = 1
    @objc dynamic var pageCount = 1
}

/// The header or footer text area at the top or bottom of a page.
final class HeaderFooterTextView: NSTextView {
    enum Kind { case header, footer }

    let kind: Kind
    weak var page: PageView?
    weak var editor: EditorController?

    init(kind: Kind, storage: NSTextStorage, size: NSSize) {
        self.kind = kind
        let layoutManager = HeaderLayoutManager()
        layoutManager.allowsNonContiguousLayout = false
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: size.width, height: 10_000))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        super.init(frame: NSRect(origin: .zero, size: size), textContainer: container)
        isRichText = true
        importsGraphics = false
        allowsUndo = true
        drawsBackground = false
        isVerticallyResizable = false
        isHorizontallyResizable = false
        textContainerInset = .zero
        insertionPointColor = .black
        selectedTextAttributes = [.backgroundColor: Theme.selection]
        isContinuousSpellCheckingEnabled = true
        usesFindBar = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        kind = .header
        super.init(frame: frameRect, textContainer: container)
    }

    var headerLayoutManager: HeaderLayoutManager? { layoutManager as? HeaderLayoutManager }

    func detach() {
        if let layoutManager { textStorage?.removeLayoutManager(layoutManager) }
    }

    /// Footers sit at the bottom of their area, growing upwards.
    override var textContainerOrigin: NSPoint {
        guard kind == .footer, let layoutManager, let textContainer else { return .zero }
        layoutManager.ensureLayout(for: textContainer)
        var used = layoutManager.usedRect(for: textContainer).height
        if layoutManager.extraLineFragmentTextContainer === textContainer { used = max(used, layoutManager.extraLineFragmentRect.maxY) }
        return NSPoint(x: 0, y: max(0, bounds.height - used))
    }

    /// A single click in the margin keeps editing the body; double-click edits the header.
    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self, event.clickCount < 2, let body = page?.textView {
            body.mouseDown(with: event)
            return
        }
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            page?.setEditing(kind, true)
            editor?.scheduleSummaryUpdate()
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { page?.setEditing(kind, false) }
        return accepted
    }
}

/// Undo and selection updates for header and footer editing.
final class HeaderFooterDelegate: NSObject, NSTextViewDelegate {
    weak var editor: EditorController?

    func undoManager(for view: NSTextView) -> UndoManager? { editor?.document?.undoManager }

    func textViewDidChangeSelection(_ notification: Notification) { editor?.scheduleSummaryUpdate() }

    func textDidChange(_ notification: Notification) { editor?.headerFooterDidChange() }
}
