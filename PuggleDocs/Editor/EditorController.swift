import AppKit
import PuggleDocsKit

/// Owns the paged text system for one document window: one layout manager flowing the document's
/// text through one text container (and text view) per page.
final class EditorController: NSObject {
    let textStorage: NSTextStorage
    let headerStorage: NSTextStorage
    let footerStorage: NSTextStorage
    let headerFooterDelegate = HeaderFooterDelegate()
    let layoutManager = PageLayoutManager()
    let canvas = PageCanvasView()
    let scrollView = NSScrollView()
    let state: EditorState
    weak var document: PuggleDocument?

    private(set) var pageSetup: PageSetup
    private(set) var pages: [PageView] = []
    private var isAdjustingPages = false
    private var pageAdjustmentScheduled = false
    private var summaryUpdateScheduled = false

    /// Called after selection or formatting changes (the ruler listens).
    var onSelectionChange: (() -> Void)?
    /// Called whenever a formatting command runs.
    var onFormattingApplied: (() -> Void)?
    /// Called after the characters of the document change.
    var onTextChange: (() -> Void)?
    /// Called when a link is clicked while editing (the window shows its preview).
    var onLinkClicked: ((Int) -> Void)?
    /// Called to open Image options for the selected image.
    var onImageOptions: (() -> Void)?
    /// Called when sharing locks or unlocks the text.
    var onAccessChange: (() -> Void)?
    /// Resize handles around the selected image.
    var imageOverlay: ImageSelectionOverlay?
    /// Comment cards, highlights and commands.
    private(set) var comments: CommentsController!
    /// Suggesting mode: edits that bypass it, a guard while it edits, and text being composed.
    var directEditDepth = 0
    var isApplyingSuggestion = false
    var composingDepth = 0
    var composingRange: NSRange?
    /// Paint format: attributes captured from the selection, applied to the next selection.
    var paintFormatAttributes: (characters: [NSAttributedString.Key: Any], paragraph: ParagraphAttributes)?
    var paintFormatSticky = false
    /// While the document is shared: its part in that, which keeps undo for the text.
    weak var collaboration: DocumentCollaboration?
    /// Whether undo for the text is kept by the shared document rather than the text views, which can't follow other
    /// people's changes.
    var usesSharedUndo = false {
        didSet {
            textViews.forEach { $0.allowsUndo = !usesSharedUndo }
            for page in pages { [page.headerView, page.footerView].compactMap { $0 }.forEach { $0.allowsUndo = !usesSharedUndo } }
        }
    }

    init(document: PuggleDocument, state: EditorState) {
        textStorage = document.textStorage
        headerStorage = document.headerStorage
        footerStorage = document.footerStorage
        pageSetup = document.pageSetup
        self.document = document
        self.state = state
        super.init()

        layoutManager.delegate = self
        layoutManager.allowsNonContiguousLayout = false
        layoutManager.backgroundLayoutEnabled = true
        textStorage.addLayoutManager(layoutManager)
        textStorage.delegate = self
        headerStorage.delegate = self
        footerStorage.delegate = self
        headerFooterDelegate.editor = self
        if textStorage.length > 0 {
            // Text loaded before the editor existed has not been through the storage delegate yet.
            textStorage.beginEditing()
            LinkStyling.styleLinks(in: textStorage, range: NSRange(location: 0, length: textStorage.length))
            textStorage.endEditing()
            prepareImages(in: NSRange(location: 0, length: textStorage.length))
            TableModel.fitTables(in: textStorage, range: NSRange(location: 0, length: textStorage.length), availableWidth: pageSetup.contentSize.width)
            // There must be somewhere to type after a table that ends the document.
            if TableModel.block(at: textStorage.length - 1, in: textStorage) != nil {
                textStorage.append(NSAttributedString(string: "\n", attributes: NamedStyle.normal.attributes()))
            }
        }

        let clipView = CenteringClipView()
        clipView.drawsBackground = true
        clipView.backgroundColor = Theme.canvas
        scrollView.contentView = clipView
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.canvas
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.25 * Theme.baseMagnification
        scrollView.maxMagnification = 4 * Theme.baseMagnification
        scrollView.borderType = .noBorder
        NotificationCenter.default.addObserver(self, selector: #selector(liveMagnifyEnded),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)

        canvas.pageSize = pageSetup.pageSize
        addPage()
        if let first = firstTextView {
            first.setSelectedRange(NSRange(location: 0, length: 0))
            if textStorage.length == 0 {
                first.typingAttributes = DocumentDefaults.typingAttributes
            } else {
                first.typingAttributes = textStorage.attributes(at: 0, effectiveRange: nil)
            }
        }
        adjustPages()
        setZoom(1)
        observeUndoManager()
        scheduleSummaryUpdate()
        comments = CommentsController(editor: self)
        canvas.onLayout = { [weak self] in self?.comments?.scheduleLayout() }
        clipView.postsBoundsChangedNotifications = true
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(visibleAreaChanged), name: name, object: clipView)
        }
    }

    @objc private func visibleAreaChanged() {
        canvas.visibleWidth = scrollView.contentView.bounds.width
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Text views

    var textViews: [DocumentTextView] { pages.map(\.textView) }
    var firstTextView: DocumentTextView? { pages.first?.textView }

    /// The text view with keyboard focus, or the first page's.
    var activeTextView: DocumentTextView {
        if let responder = scrollView.window?.firstResponder as? DocumentTextView, responder.editor === self { return responder }
        return firstTextView!
    }

    var undoManager: UndoManager? { document?.undoManager }

    /// The header or footer being edited, if any.
    var editingHeaderFooterView: HeaderFooterTextView? {
        guard let view = scrollView.window?.firstResponder as? HeaderFooterTextView, view.editor === self else { return nil }
        return view
    }

    /// Where formatting commands apply: the header or footer being edited, otherwise the body.
    var focusedTextView: NSTextView { editingHeaderFooterView ?? activeTextView }
    var focusedStorage: NSTextStorage { focusedTextView.textStorage ?? textStorage }
    var isEditingHeaderFooter: Bool { editingHeaderFooterView != nil }

    /// The page text view whose container holds the character at `location`.
    func textView(forCharacterAt location: Int) -> DocumentTextView? {
        let length = textStorage.length
        if length == 0 { return firstTextView }
        if location >= length, let container = layoutManager.extraLineFragmentTextContainer {
            return textViews.first { $0.textContainer === container }
        }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(location, length - 1))
        let container = layoutManager.textContainer(forGlyphAt: glyph, effectiveRange: nil)
        return textViews.first { $0.textContainer === container }
    }

    func focusPageContainingCaret() {
        guard let window = scrollView.window, let current = window.firstResponder as? DocumentTextView, current.editor === self else { return }
        let selection = current.selectedRange()
        guard selection.length == 0, let target = textView(forCharacterAt: selection.location), target !== current else { return }
        window.makeFirstResponder(target)
    }

    func focus() {
        guard let window = scrollView.window else { return }
        if !(window.firstResponder is DocumentTextView) {
            let range = activeTextView.selectedRange()
            let index = layoutManager.glyphIndexForCharacter(at: min(range.location, max(textStorage.length - 1, 0)))
            let container = textStorage.length == 0 ? layoutManager.textContainers.first : layoutManager.textContainer(forGlyphAt: index, effectiveRange: nil)
            let target = textViews.first { $0.textContainer === container } ?? activeTextView
            window.makeFirstResponder(target)
        }
    }

    private func configure(_ textView: DocumentTextView) {
        textView.editor = self
        textView.delegate = self
        textView.isRichText = true
        textView.importsGraphics = true
        textView.allowsUndo = !usesSharedUndo
        textView.usesFontPanel = true
        textView.usesRuler = false
        textView.drawsBackground = false
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = []
        textView.textContainerInset = .zero
        textView.minSize = pageSetup.contentSize
        textView.maxSize = pageSetup.contentSize
        textView.isEditable = state.isEditable
        textView.isContinuousSpellCheckingEnabled = state.isSpellCheckEnabled
        textView.isGrammarCheckingEnabled = state.isSpellCheckEnabled
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.isAutomaticTextReplacementEnabled = true
        textView.isAutomaticLinkDetectionEnabled = true
        textView.smartInsertDeleteEnabled = true
        textView.usesFindBar = false
        textView.displaysLinkToolTips = true
        textView.allowsDocumentBackgroundColorChange = false
        textView.insertionPointColor = .black
        textView.selectedTextAttributes = [.backgroundColor: Theme.selection]
        // Links are styled in the text itself (see LinkStyling); only the cursor changes here.
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        textView.textContainer?.lineFragmentPadding = 0
    }

    // MARK: Pages

    private func addPage() {
        let container = NSTextContainer(size: pageSetup.contentSize)
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layoutManager.addTextContainer(container)
        let textView = DocumentTextView(frame: NSRect(origin: .zero, size: pageSetup.contentSize), textContainer: container)
        configure(textView)
        let page = PageView(textView: textView)
        page.isFirstPage = pages.isEmpty
        let header = makeHeaderFooterView(.header)
        let footer = makeHeaderFooterView(.footer)
        page.attach(header: header, footer: footer)
        page.place(textAreaIn: pageSetup)
        pages.append(page)
        canvas.add(page)
        state.pageCount = pages.count
        updatePageNumbers()
    }

    private func makeHeaderFooterView(_ kind: HeaderFooterTextView.Kind) -> HeaderFooterTextView {
        let storage = kind == .header ? headerStorage : footerStorage
        let view = HeaderFooterTextView(kind: kind, storage: storage, size: NSSize(width: pageSetup.contentSize.width, height: 40))
        view.editor = self
        view.delegate = headerFooterDelegate
        view.isEditable = state.isEditable
        view.allowsUndo = !usesSharedUndo
        if storage.length == 0 { view.typingAttributes = DocumentDefaults.typingAttributes }
        return view
    }

    /// Tells each page's header and footer which page they are on.
    func updatePageNumbers() {
        let count = pages.count
        for (index, page) in pages.enumerated() {
            for view in [page.headerView, page.footerView].compactMap({ $0 }) {
                guard let layoutManager = view.headerLayoutManager,
                      layoutManager.pageNumber != index + 1 || layoutManager.pageCount != count else { continue }
                layoutManager.pageNumber = index + 1
                layoutManager.pageCount = count
                if let storage = view.textStorage, storage.length > 0 {
                    layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
                }
                view.invalidateTextContainerOrigin()
                view.needsDisplay = true
            }
        }
    }

    /// Footers are bottom-aligned, so their position depends on their text.
    func headerFooterDidChange() {
        for page in pages {
            page.footerView?.invalidateTextContainerOrigin()
            page.footerView?.needsDisplay = true
        }
    }

    /// Pages are added and removed outside of layout callbacks: creating a text view can itself
    /// trigger layout, and nested page changes would scramble the page order.
    func schedulePageAdjustment() {
        guard !pageAdjustmentScheduled else { return }
        pageAdjustmentScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.pageAdjustmentScheduled = false
            self?.adjustPages()
        }
    }

    func adjustPages() {
        guard !isAdjustingPages else { return }
        isAdjustingPages = true
        defer { isAdjustingPages = false }
        // Add pages while text overflows the last one.
        for _ in 0..<5_000 {
            guard let last = layoutManager.textContainers.last else { break }
            let range = layoutManager.glyphRange(for: last)
            let overflowing = NSMaxRange(range) < layoutManager.numberOfGlyphs
            // A trailing newline needs room for the empty line after it.
            let needsExtraLine = !overflowing && range.length > 0 && endsWithParagraphSeparator
                && layoutManager.extraLineFragmentTextContainer == nil
            guard overflowing || needsExtraLine else { break }
            addPage()
        }
        // Remove empty pages at the end that hold neither glyphs nor the caret's empty last line.
        while pages.count > 1, let last = layoutManager.textContainers.last,
              layoutManager.glyphRange(for: last).length == 0,
              layoutManager.extraLineFragmentTextContainer !== last {
            removeLastPage()
        }
    }

    private var endsWithParagraphSeparator: Bool {
        let string = textStorage.string as NSString
        return string.length > 0 && Self.isParagraphSeparator(string.character(at: string.length - 1))
    }

    private func removeLastPage() {
        guard pages.count > 1 else { return }
        let page = pages.removeLast()
        let hadFocus = scrollView.window?.firstResponder === page.textView
        layoutManager.removeTextContainer(at: layoutManager.textContainers.count - 1)
        page.detachHeaderFooter()
        canvas.removeLastPage()
        state.pageCount = pages.count
        updatePageNumbers()
        if hadFocus, let last = pages.last { scrollView.window?.makeFirstResponder(last.textView) }
    }

    func apply(pageSetup setup: PageSetup) {
        let oldWidth = pageSetup.contentSize.width
        pageSetup = setup
        if oldWidth > 0 { TableModel.rescaleTables(in: textStorage, by: setup.contentSize.width / oldWidth) }
        for (index, page) in pages.enumerated() {
            page.isFirstPage = index == 0
            page.textView.textContainer?.size = setup.contentSize
            page.textView.minSize = setup.contentSize
            page.textView.maxSize = setup.contentSize
            page.place(textAreaIn: setup)
        }
        canvas.pageSize = setup.pageSize
        onSelectionChange?()
    }

    // MARK: Access

    /// Locks or unlocks the text as sharing allows; people who may only comment can't suggest either.
    func setAccess(_ access: DocumentAccess) {
        guard state.access != access else { return }
        state.access = access
        if access != .full, state.mode == .suggesting { state.mode = .editing }
        applyEditability()
        comments?.modeDidChange()
        onAccessChange?()
    }

    func applyEditability() {
        textViews.forEach { $0.isEditable = state.isEditable }
        for page in pages { [page.headerView, page.footerView].compactMap { $0 }.forEach { $0.isEditable = state.isEditable } }
    }

    /// After the whole text was replaced (by a shared document's copy in iCloud): pages, headings, comments and the
    /// toolbar catch up.
    func refreshAfterLoading() {
        if textStorage.length > 0 {
            prepareImages(in: NSRange(location: 0, length: textStorage.length))
            TableModel.fitTables(in: textStorage, range: NSRange(location: 0, length: textStorage.length), availableWidth: pageSetup.contentSize.width)
        }
        adjustPages()
        refreshUsedHeadings()
        headerFooterDidChange()
        comments?.reload()
        let length = textStorage.length
        if activeTextView.selectedRange().location > length { activeTextView.setSelectedRange(NSRange(location: length, length: 0)) }
        updateSummaryNow()
        onTextChange?()
    }

    // MARK: Zoom

    func setZoom(_ zoom: CGFloat) {
        let clamped = min(max(zoom, 0.25), 4)
        let visible = scrollView.contentView.documentVisibleRect
        scrollView.setMagnification(clamped * Theme.baseMagnification, centeredAt: NSPoint(x: visible.midX, y: visible.midY))
        // Keep the top of the view where it was, as browsers do when zooming.
        let clip = scrollView.contentView
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: NSPoint(x: clip.bounds.origin.x, y: visible.minY), size: clip.bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)
        state.zoom = clamped
        canvas.visibleWidth = clip.bounds.width
        comments?.scheduleLayout()
        onSelectionChange?()
    }

    func zoom(by step: Int) {
        let levels = Theme.zoomLevels
        let current = state.zoom
        let next = step > 0 ? levels.first { $0 > current + 0.001 } : levels.last { $0 < current - 0.001 }
        setZoom(next ?? current)
    }

    func zoomToFit() {
        let available = scrollView.frame.width - PageCanvasView.sidePadding * 2
        setZoom(max(0.25, available / (pageSetup.pageSize.width * Theme.baseMagnification)))
    }

    @objc private func liveMagnifyEnded() {
        state.zoom = scrollView.magnification / Theme.baseMagnification
        canvas.visibleWidth = scrollView.contentView.bounds.width
        comments?.scheduleLayout()
        onSelectionChange?()
    }

    // MARK: Undo state

    private func observeUndoManager() {
        guard let undoManager else { return }
        for name in [NSNotification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(undoStateChanged), name: name, object: undoManager)
        }
    }

    @objc private func undoStateChanged() {
        state.canUndo = undoManager?.canUndo ?? false
        state.canRedo = undoManager?.canRedo ?? false
    }

    // MARK: Selection summary

    func scheduleSummaryUpdate() {
        guard !summaryUpdateScheduled else { return }
        summaryUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.summaryUpdateScheduled = false
            self?.updateSummaryNow()
        }
    }

    func updateSummaryNow() {
        guard firstTextView != nil else { return }
        let textView = focusedTextView
        let summary = FormattingSummary.make(storage: focusedStorage, selectedRanges: textView.selectedRanges.map(\.rangeValue),
                                             typingAttributes: textView.typingAttributes)
        if summary != state.summary { state.summary = summary }
        undoStateChanged()
        onSelectionChange?()
    }

    func refreshUsedHeadings() {
        var levels = Set<Int>()
        textStorage.enumerateAttribute(.pdNamedStyle, in: NSRange(location: 0, length: textStorage.length), options: []) { value, _, _ in
            if let raw = value as? String, let level = NamedStyle(rawValue: raw)?.headingLevel { levels.insert(level) }
        }
        state.usedHeadingLevels = levels
    }

    // MARK: Printing

    func makePrintOperation(printInfo: NSPrintInfo) -> NSPrintOperation {
        printInfo.orientation = pageSetup.orientation == .landscape ? .landscape : .portrait
        printInfo.paperSize = pageSetup.pageSize
        printInfo.topMargin = 0
        printInfo.bottomMargin = 0
        printInfo.leftMargin = 0
        printInfo.rightMargin = 0
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false
        printInfo.scalingFactor = 1
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: textStorage.length))
        let operation = NSPrintOperation(view: canvas, printInfo: printInfo)
        operation.jobTitle = document?.displayName ?? "PuggleDocs"
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        return operation
    }

    /// Writes the pages to a PDF file without showing any panels.
    func exportPDF(to url: URL) -> Bool {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let operation = makePrintOperation(printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        return operation.run()
    }

    // MARK: Statistics

    struct Statistics {
        var pages: Int
        var words: Int
        var characters: Int
        var charactersExcludingSpaces: Int
    }

    func statistics(selectionOnly: Bool) -> Statistics {
        let string = textStorage.string as NSString
        let ranges = selectionOnly ? activeTextView.selectedRanges.map(\.rangeValue).filter { $0.length > 0 } : [NSRange(location: 0, length: string.length)]
        var words = 0
        var characters = 0
        var nonSpace = 0
        for range in ranges {
            string.enumerateSubstrings(in: range, options: [.byWords, .substringNotRequired]) { _, _, _, _ in words += 1 }
            let substring = string.substring(with: range)
            for character in substring where !character.isNewline && character != "\u{0C}" {
                characters += 1
                if !character.isWhitespace { nonSpace += 1 }
            }
        }
        return Statistics(pages: pages.count, words: words, characters: characters, charactersExcludingSpaces: nonSpace)
    }
}

// MARK: - Layout manager delegate

extension EditorController: NSLayoutManagerDelegate {
    func layoutManager(_ layoutManager: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?, atEnd layoutFinishedFlag: Bool) {
        let isLast = textContainer === layoutManager.textContainers.last
        if textContainer == nil || (!layoutFinishedFlag && isLast) || (layoutFinishedFlag && !isLast) {
            schedulePageAdjustment()
        }
    }

    /// A page break followed by a paragraph end breaks at the paragraph end, so the next
    /// paragraph starts the new page without an empty line above it.
    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        let string = textStorage.string as NSString
        guard charIndex < string.length else { return action }
        let character = string.character(at: charIndex)
        if character == 0x0C {
            if charIndex + 1 < string.length, Self.isParagraphSeparator(string.character(at: charIndex + 1)) { return .zeroAdvancement }
            return .containerBreak
        }
        if Self.isParagraphSeparator(character), charIndex > 0, string.character(at: charIndex - 1) == 0x0C {
            return .containerBreak
        }
        return action
    }

    static func isParagraphSeparator(_ character: unichar) -> Bool {
        character == 0x0A || character == 0x0D || character == 0x2029
    }
}

// MARK: - Text storage delegate

extension EditorController: NSTextStorageDelegate {
    func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) || editedMask.contains(.editedAttributes) else { return }
        ParagraphFormatting.normalize(textStorage, in: editedRange)
        dropStaleRequestedFonts(in: editedRange, of: textStorage)
        LinkStyling.styleLinks(in: textStorage, range: editedRange)
        if textStorage === self.textStorage {
            prepareImages(in: editedRange)
            TableModel.fitTables(in: textStorage, range: editedRange, availableWidth: pageSetup.contentSize.width)
        }
    }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard textStorage === self.textStorage else {
            headerFooterDidChange()
            scheduleSummaryUpdate()
            return
        }
        if layoutManager.invalidateListMarkers() {
            textViews.forEach { $0.needsDisplay = true }
        }
        comments?.textDidChange(editedRange: editedRange, delta: delta, charactersChanged: editedMask.contains(.editedCharacters))
        if editedMask.contains(.editedCharacters) { onTextChange?() }
        scheduleSummaryUpdate()
    }

    /// When a run's font no longer is the recorded substitute (the user picked another font),
    /// forget the originally requested family.
    private func dropStaleRequestedFonts(in range: NSRange, of textStorage: NSTextStorage) {
        guard range.length > 0, NSMaxRange(range) <= textStorage.length else { return }
        textStorage.enumerateAttribute(.pdRequestedFont, in: range, options: []) { value, subrange, _ in
            guard let requested = value as? RequestedFont else { return }
            let family = (textStorage.attribute(.font, at: subrange.location, effectiveRange: nil) as? NSFont)?.familyName
            if family != requested.substitute { textStorage.removeAttribute(.pdRequestedFont, range: subrange) }
        }
    }
}
