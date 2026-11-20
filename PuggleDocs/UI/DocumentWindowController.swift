import AppKit
import PuggleDocsKit
import SwiftUI
import UniformTypeIdentifiers

final class DocumentWindowController: NSWindowController, NSWindowDelegate, ChromeActions {
    let state = EditorState()
    let editor: EditorController
    let find: FindController
    private let ruler = RulerView()
    private var rulerHeight: NSLayoutConstraint!
    private var outlineWidth: NSLayoutConstraint!
    private var outlineRefreshScheduled = false
    private var chromeHost: NSHostingView<ChromeView>!
    private var colorPanelTargetsHighlight = false

    var puggleDocument: PuggleDocument? { document as? PuggleDocument }

    init(document: PuggleDocument) {
        editor = EditorController(document: document, state: state)
        find = FindController(editor: editor)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 880),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = Theme.canvas
        window.appearance = NSAppearance(named: .aqua)
        window.minSize = NSSize(width: 720, height: 480)
        window.isRestorable = true
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = true
        buildContent()

        document.onPageSetupChange = { [weak self] setup in self?.editor.apply(pageSetup: setup) }
        document.onStatusChange = { [weak self] in self?.updateStatus() }
        editor.onSelectionChange = { [weak self] in
            self?.ruler.needsDisplay = true
            self?.scheduleWordCountUpdate()
            self?.updateCurrentOutlineEntry()
        }
        editor.onFormattingApplied = { [weak self] in self?.warnAboutPlainTextFormatting() }
        editor.onTextChange = { [weak self] in
            self?.find.scheduleRefresh()
            self?.scheduleOutlineRefresh()
        }
        editor.onLinkClicked = { [weak self] index in self?.showLinkPreview(at: index) }
        editor.onAccessChange = { [weak self] in
            guard let self else { return }
            ruler.isEnabled = state.isEditable
            updateStatus()
        }
        editor.onImageOptions = { [weak self] in self?.pdImageOptions(nil) }
        if let warnings = Optional(document.importWarnings), !warnings.isEmpty, let name = document.importedFileName {
            let list = warnings.map(\.userDescription).sorted().joined(separator: ", ")
            state.banner = "This is a copy of “\(name)”. PuggleDocs can’t keep \(list) yet, so your original file was left untouched. Saving creates a new file."
        }
        editor.refreshUsedHeadings()
        updateStatus()
        if state.showsWordCount { updateWordCount() }
        refreshOutline()
        window.setContentSize(NSSize(width: 1280, height: 880))
        window.center()
        updateTitlebarMetrics()
        DispatchQueue.main.async { [weak self] in self?.updateTitlebarMetrics() }
        window.makeFirstResponder(editor.firstTextView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildContent() {
        guard let window else { return }
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.canvas.cgColor
        window.contentView = content

        chromeHost = NSHostingView(rootView: ChromeView(state: state, actions: self))
        chromeHost.sizingOptions = [.intrinsicContentSize]
        // The header sits in the title bar band, so the title bar must not count as a safe-area inset.
        chromeHost.safeAreaRegions = []
        let scrollView = editor.scrollView
        let outline = NSHostingView(rootView: OutlinePanel(state: state, select: { [weak self] entry in self?.go(to: entry) },
                                                            close: { [weak self] in self?.setShowsOutline(false) }))
        // The panel fills whatever space the constraints give it; it must not size the window.
        outline.sizingOptions = []
        chromeHost.setContentHuggingPriority(.required, for: .vertical)
        chromeHost.setContentCompressionResistancePriority(.required, for: .vertical)
        for view in [chromeHost!, ruler, outline, scrollView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        let findBar = NSHostingView(rootView: FindBarView(state: find.state, controller: find))
        findBar.sizingOptions = [.intrinsicContentSize]
        findBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(findBar)
        let badge = NSHostingView(rootView: WordCountBadge(state: state, actions: self))
        badge.sizingOptions = [.intrinsicContentSize]
        badge.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(badge)
        let outlineButton = NSHostingView(rootView: OutlineToggleButton(state: state) { [weak self] in self?.setShowsOutline(true) })
        outlineButton.sizingOptions = [.intrinsicContentSize]
        outlineButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(outlineButton)
        outlineWidth = outline.widthAnchor.constraint(equalToConstant: state.showsOutline ? 250 : 0)
        rulerHeight = ruler.heightAnchor.constraint(equalToConstant: RulerView.height)
        NSLayoutConstraint.activate([
            chromeHost.topAnchor.constraint(equalTo: content.topAnchor),
            chromeHost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            chromeHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ruler.topAnchor.constraint(equalTo: chromeHost.bottomAnchor),
            ruler.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            ruler.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rulerHeight,
            outline.topAnchor.constraint(equalTo: ruler.bottomAnchor),
            outline.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            outline.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            outlineWidth,
            outlineButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            outlineButton.topAnchor.constraint(equalTo: ruler.bottomAnchor, constant: 6),
            scrollView.topAnchor.constraint(equalTo: ruler.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: outline.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            findBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            findBar.topAnchor.constraint(equalTo: ruler.bottomAnchor, constant: 4),
            badge.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            badge.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])

        ruler.geometry = { [weak self] in self?.rulerGeometry() }
        ruler.onIndentsChanged = { [weak self] left, first, right in self?.editor.setIndents(left: left, firstLine: first, right: right) }
        ruler.onMarginsChanged = { [weak self] left, right in self?.setHorizontalMargins(left: left, right: right) }
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ruler.needsDisplay = true }
        }
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ruler.needsDisplay = true }
        }
    }

    private func rulerGeometry() -> RulerGeometry? {
        guard let page = editor.pages.first else { return nil }
        let left = ruler.convert(NSPoint(x: page.frame.minX, y: 0), from: editor.canvas).x
        let right = ruler.convert(NSPoint(x: page.frame.maxX, y: 0), from: editor.canvas).x
        let setup = editor.pageSetup
        let summary = state.summary
        return RulerGeometry(pageLeft: left, scale: (right - left) / setup.pageSize.width, pageWidth: setup.pageSize.width,
                             marginLeft: setup.margins.left, marginRight: setup.margins.right,
                             headIndent: summary.headIndent, firstLineIndent: summary.firstLineHeadIndent,
                             rightIndent: max(0, -summary.tailIndent), isListItem: summary.listKind != nil)
    }

    private func setHorizontalMargins(left: CGFloat, right: CGFloat) {
        guard let document = puggleDocument else { return }
        let old = document.pageSetup
        var setup = old
        setup.margins.left = left
        setup.margins.right = right
        changePageSetup(to: setup, from: old)
    }

    private func changePageSetup(to setup: PageSetup, from old: PageSetup) {
        guard let document = puggleDocument, setup != old else { return }
        document.pageSetup = setup
        document.onPageSetupEdited?()
        document.undoManager?.registerUndo(withTarget: self) { controller in
            controller.changePageSetup(to: old, from: setup)
        }
        document.undoManager?.setActionName("Page Setup")
    }

    // MARK: Status and title

    override func synchronizeWindowTitleWithDocumentName() {
        super.synchronizeWindowTitleWithDocumentName()
        updateStatus()
        // A shared document of this person's that moved or was renamed is still found by its new name.
        if let document = puggleDocument, let collaboration = document.collaboration, collaboration.isOwner, let url = document.fileURL {
            CollaborationController.shared?.link(collaboration.id, to: url)
        }
    }

    func updateStatus() {
        guard let document = puggleDocument else { return }
        var title = document.displayName ?? "Untitled document"
        if let ext = document.fileURL?.pathExtension, !ext.isEmpty, title.lowercased().hasSuffix("." + ext.lowercased()) {
            title = String(title.dropLast(ext.count + 1))
        }
        state.title = title
        state.formatBadge = document.fileURL == nil ? nil : document.format?.badge
        if document.sharedCopy != nil {
            state.saveStatus = .saved
        } else if document.fileURL == nil {
            state.saveStatus = .draft
        } else {
            state.saveStatus = document.isDocumentEdited ? .edited : .saved
        }
    }

    // MARK: Outline

    func setShowsOutline(_ show: Bool) {
        state.showsOutline = show
        UserDefaults.standard.set(show, forKey: "PDShowOutline")
        outlineWidth.constant = show ? 250 : 0
        if show { refreshOutline() }
        ruler.needsDisplay = true
    }

    func scheduleOutlineRefresh() {
        guard !outlineRefreshScheduled else { return }
        outlineRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.outlineRefreshScheduled = false
            self?.refreshOutline()
        }
    }

    func refreshOutline() {
        let entries = OutlineBuilder.entries(in: editor.textStorage)
        if entries != state.outline { state.outline = entries }
        updateCurrentOutlineEntry()
    }

    func updateCurrentOutlineEntry() {
        let index = OutlineBuilder.currentIndex(in: state.outline, location: editor.activeTextView.selectedRange().location)
        if index != state.currentOutlineIndex { state.currentOutlineIndex = index }
    }

    /// Selects a heading and scrolls it near the top of the view.
    func go(to entry: OutlineEntry) {
        guard entry.location <= editor.textStorage.length else { return }
        let range = NSRange(location: entry.location, length: 0)
        editor.activeTextView.setSelectedRange(range)
        if let (textView, rect) = editor.rect(for: range) {
            let clip = editor.scrollView.contentView
            let point = clip.convert(rect.origin, from: textView)
            let target = NSRect(origin: NSPoint(x: clip.bounds.origin.x, y: point.y - 24), size: clip.bounds.size)
            clip.scroll(to: clip.constrainBoundsRect(target).origin)
            editor.scrollView.reflectScrolledClipView(clip)
        }
        editor.textView(forCharacterAt: entry.location).map { window?.makeFirstResponder($0) }
        updateCurrentOutlineEntry()
    }

    // MARK: Word count

    private var wordCountUpdate: DispatchWorkItem?

    func scheduleWordCountUpdate() {
        guard state.showsWordCount else { return }
        wordCountUpdate?.cancel()
        let update = DispatchWorkItem { [weak self] in self?.updateWordCount() }
        wordCountUpdate = update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: update)
    }

    func updateWordCount() {
        let total = editor.statistics(selectionOnly: false)
        let selection = editor.hasSelection ? editor.statistics(selectionOnly: true) : nil
        state.wordCountText = state.wordCountMetric.text(total: total, selection: selection)
    }

    func setShowsWordCount(_ show: Bool) {
        state.showsWordCount = show
        UserDefaults.standard.set(show, forKey: WordCountMetric.visibilityKey)
        if show { updateWordCount() }
    }

    private var warnedAboutPlainText = false

    /// Plain text files cannot store formatting; say so once instead of silently dropping it.
    private func warnAboutPlainTextFormatting() {
        guard !warnedAboutPlainText, puggleDocument?.fileURL != nil, let format = puggleDocument?.format,
              format == .plainText || format == .markdown else { return }
        warnedAboutPlainText = true
        state.banner = format == .markdown
            ? "Markdown keeps headings, bold, italic, links, lists and tables; other formatting won’t be kept when this file is saved. To keep it, use File ▸ Download ▸ Microsoft Word (.docx)."
            : "Plain text files can’t store formatting, so it won’t be kept when this file is saved. To keep it, use File ▸ Download ▸ Microsoft Word (.docx)."
    }

    // MARK: Header alignment

    func updateTitlebarMetrics() {
        guard let window else { return }
        let metrics = TitlebarMetrics.measure(window)
        if state.titlebarLeading != metrics.leading { state.titlebarLeading = metrics.leading }
        if abs(state.titlebarCenterY - metrics.centerY) > 0.5 { state.titlebarCenterY = metrics.centerY }
    }

    func windowDidResize(_ notification: Notification) { updateTitlebarMetrics() }
    func windowDidEnterFullScreen(_ notification: Notification) { updateTitlebarMetrics() }
    func windowDidExitFullScreen(_ notification: Notification) { updateTitlebarMetrics() }
    func windowDidBecomeKey(_ notification: Notification) { updateTitlebarMetrics() }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        document?.undoManager
    }

    // MARK: ChromeActions

    func rename(to title: String) {
        guard let document = puggleDocument else { return }
        guard let url = document.fileURL else {
            document.customTitle = title
            synchronizeWindowTitleWithDocumentName()
            return
        }
        let target = url.deletingLastPathComponent().appendingPathComponent(title).appendingPathExtension(url.pathExtension)
        document.move(to: target) { [weak self] error in
            guard let self, error != nil else { return }
            // Sandboxed apps may not rename in place; ask where to save under the new name instead.
            let panel = NSSavePanel()
            panel.nameFieldStringValue = target.lastPathComponent
            panel.directoryURL = url.deletingLastPathComponent()
            panel.message = "Choose where to save “\(title)”."
            panel.beginSheetModal(for: self.window!) { response in
                guard response == .OK, let chosen = panel.url else {
                    self.updateStatus()
                    return
                }
                document.move(to: chosen) { _ in self.updateStatus() }
            }
        }
    }

    func showVersionHistory() {
        guard let document = puggleDocument else { return }
        if document.fileURL == nil {
            let alert = NSAlert()
            alert.messageText = "No versions yet"
            alert.informativeText = "Version history becomes available after the document is saved to a file."
            alert.beginSheetModal(for: window!)
            return
        }
        document.browseVersions(nil)
    }

    func printDocument() {
        document?.printDocument(nil)
    }

    // MARK: Collaboration

    /// The Collaborate sheet: sharing the document, or seeing and changing who it's shared with.
    func showCollaborate() {
        guard let controller = CollaborationController.shared else { return }
        let model = CollaborateModel(controller: controller, windowController: self)
        presentSheet { dismiss in
            model.done = dismiss
            return CollaborateView(model: model)
        }
    }

    /// The document stopped being shared: it carries on here as an ordinary document, saved in its file.
    func sharingEnded() {
        state.collaboration.reset()
        editor.setAccess(.full)
        editor.collaboration = nil
        updateStatus()
        state.banner = "“\(state.title)” is no longer shared. It’s saved on this Mac, and nobody else can open it any longer."
    }

    /// A document someone shared went away: its text goes at once, the window says why, and closes.
    func sharedCopyWentAway(ownerName: String, reason: UnavailableReason) {
        guard let document = puggleDocument, let window else { return }
        let title = document.displayName ?? state.title
        editor.setAccess(.locked)
        for storage in [document.textStorage, document.headerStorage, document.footerStorage] {
            storage.isRecording = false
            storage.setAttributedString(NSAttributedString())
        }
        document.comments = []
        editor.refreshAfterLoading()
        state.collaboration.reset()
        guard reason == .stopped else {
            document.close()
            return
        }
        let alert = NSAlert()
        alert.messageText = "“\(title)” is no longer shared with you"
        alert.informativeText = "\(ownerName) stopped sharing it, so it can’t be opened here any longer."
        alert.addButton(withTitle: "OK")
        window.attachedSheet.map { window.endSheet($0) }
        alert.beginSheetModal(for: window) { _ in
            MainActor.assumeIsolated { document.close() }
        }
    }

    func showCustomColorPanel(highlight: Bool) {
        colorPanelTargetsHighlight = highlight
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = false
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        if colorPanelTargetsHighlight { editor.setHighlight(sender.color) } else { editor.setTextColor(sender.color) }
    }

    func dismissBanner() {
        state.banner = nil
    }

    func popUp(_ menu: ToolbarMenu, from view: NSView?) {
        show(ToolbarMenus.make(menu, controller: self), below: view)
    }

    private func show(_ menu: NSMenu, below view: NSView?) {
        guard let view else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 3), in: view)
    }

    // MARK: Sheets

    func presentSheet<Content: View>(_ content: (_ dismiss: @escaping () -> Void) -> Content) {
        guard let window else { return }
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let dismiss = { [weak window, weak sheet] in
            guard let window, let sheet else { return }
            window.endSheet(sheet)
        }
        let host = NSHostingController(rootView: content(dismiss))
        sheet.contentViewController = host
        // Size the sheet to its content's ideal size, not just its minimum.
        let ideal = host.view.intrinsicContentSize
        if ideal.width > 0, ideal.height > 0, ideal.width < 2_000, ideal.height < 2_000 { sheet.setContentSize(ideal) }
        sheet.appearance = NSAppearance(named: .aqua)
        window.beginSheet(sheet) { [weak self] _ in self?.editor.focus() }
    }
}

// MARK: - Commands

extension DocumentWindowController: DocumentCommands, NSMenuItemValidation {
    @objc func pdToggleBold(_ sender: Any?) { editor.toggleBold() }
    @objc func pdToggleItalic(_ sender: Any?) { editor.toggleItalic() }
    @objc func pdToggleUnderline(_ sender: Any?) { editor.toggleUnderline() }
    @objc func pdToggleStrikethrough(_ sender: Any?) { editor.toggleStrikethrough() }
    @objc func pdSuperscript(_ sender: Any?) { editor.toggleBaseline(1) }
    @objc func pdSubscript(_ sender: Any?) { editor.toggleBaseline(-1) }
    @objc func pdIncreaseFontSize(_ sender: Any?) { editor.stepFontSize(up: true) }
    @objc func pdDecreaseFontSize(_ sender: Any?) { editor.stepFontSize(up: false) }
    @objc func pdLowercase(_ sender: Any?) { editor.changeCase(.lower) }
    @objc func pdUppercase(_ sender: Any?) { editor.changeCase(.upper) }
    @objc func pdTitleCase(_ sender: Any?) { editor.changeCase(.title) }

    @objc func pdApplyStyle(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag, NamedStyle.allCases.indices.contains(tag) else { return }
        editor.applyNamedStyle(NamedStyle.allCases[tag])
    }

    @objc func pdAlign(_ sender: Any?) {
        let alignments: [NSTextAlignment] = [.left, .center, .right, .justified]
        guard let tag = (sender as? NSMenuItem)?.tag, alignments.indices.contains(tag) else { return }
        editor.setAlignment(alignments[tag])
    }

    @objc func pdIncreaseIndent(_ sender: Any?) { editor.indent(increase: true) }
    @objc func pdDecreaseIndent(_ sender: Any?) { editor.indent(increase: false) }

    @objc func pdLineSpacing(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag else { return }
        editor.setLineSpacing(CGFloat(tag) / 100)
    }

    @objc func pdToggleSpaceBefore(_ sender: Any?) { editor.toggleSpaceBefore() }
    @objc func pdToggleSpaceAfter(_ sender: Any?) { editor.toggleSpaceAfter() }

    @objc func pdCustomSpacing(_ sender: Any?) {
        let summary = state.summary
        presentSheet { dismiss in
            CustomSpacingView(lineSpacing: Double(summary.lineSpacing ?? 1.15), before: Double(summary.spaceBefore), after: Double(summary.spaceAfter)) { line, before, after in
                self.editor.setCustomSpacing(line: line, before: before, after: after)
                dismiss()
            } cancel: { dismiss() }
        }
    }

    @objc func pdBulletedList(_ sender: Any?) { editor.toggleList(.bulleted) }
    @objc func pdNumberedList(_ sender: Any?) { editor.toggleList(.numbered) }
    @objc func pdChecklist(_ sender: Any?) { editor.toggleList(.checklist) }

    @objc func pdListPreset(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String, let preset = ListPreset(rawValue: raw) else { return }
        editor.toggleList(preset.kind, preset: preset)
    }

    @objc func pdClearFormatting(_ sender: Any?) { editor.clearFormatting() }
    @objc func pdInsertPageBreak(_ sender: Any?) { editor.insertPageBreak() }
    @objc func pdZoomIn(_ sender: Any?) { editor.zoom(by: 1) }
    @objc func pdZoomOut(_ sender: Any?) { editor.zoom(by: -1) }
    @objc func pdActualSize(_ sender: Any?) { editor.setZoom(1) }
    @objc func pdZoomToFit(_ sender: Any?) { editor.zoomToFit() }

    @objc func pdSetZoom(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag else { return }
        if tag == 0 { editor.zoomToFit() } else { editor.setZoom(CGFloat(tag) / 100) }
    }

    @objc func pdToggleRuler(_ sender: Any?) {
        state.showsRuler.toggle()
        rulerHeight.constant = state.showsRuler ? RulerView.height : 0
        ruler.isHidden = !state.showsRuler
    }

    @objc func pdToggleInvisibles(_ sender: Any?) {
        let show = !editor.layoutManager.showsInvisibleCharacters
        editor.layoutManager.showsInvisibleCharacters = show
        editor.layoutManager.showsControlCharacters = show
        editor.textViews.forEach { $0.needsDisplay = true }
    }


    @objc func pdSetMode(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag, EditingMode.allCases.indices.contains(tag) else { return }
        editor.setMode(EditingMode.allCases[tag])
        ruler.isEnabled = state.isEditable
    }

    @objc func pdCollaborate(_ sender: Any?) { showCollaborate() }

    @objc func pdWordCount(_ sender: Any?) {
        let all = editor.statistics(selectionOnly: false)
        let selection = editor.hasSelection ? editor.statistics(selectionOnly: true) : nil
        presentSheet { dismiss in
            WordCountView(document: all, selection: selection, showsWhileTyping: state.showsWordCount,
                          setShowsWhileTyping: { self.setShowsWordCount($0) }, done: dismiss)
        }
    }

    @objc func pdSetWordCountMetric(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag, let metric = WordCountMetric(rawValue: tag) else { return }
        state.wordCountMetric = metric
        UserDefaults.standard.set(metric.rawValue, forKey: WordCountMetric.metricKey)
        updateWordCount()
    }

    @objc func pdToggleWordCount(_ sender: Any?) { setShowsWordCount(!state.showsWordCount) }

    @objc func pdInsertLink(_ sender: Any?) { showLinkEditor() }
    @objc func pdInsertComment(_ sender: Any?) { editor.comments.startDraft() }
    @objc func pdAcceptAllSuggestions(_ sender: Any?) { editor.resolveSuggestions(nil, accept: true) }
    @objc func pdRejectAllSuggestions(_ sender: Any?) { editor.resolveSuggestions(nil, accept: false) }
    @objc func pdCommentHistory(_ sender: Any?) { editor.comments.model.showsHistory.toggle() }
    @objc func pdToggleOutline(_ sender: Any?) { setShowsOutline(!state.showsOutline) }
    @objc func pdInsertImage(_ sender: Any?) { insertImageFromFile() }
    @objc func pdEditHeader(_ sender: Any?) { editor.editHeaderFooter(.header) }

    @objc func pdInsertTable(_ sender: Any?) {
        guard state.isEditable, !editor.isEditingHeaderFooter else { return }
        editor.focus()
        presentPopover(at: editor.activeTextView.selectedRange()) { close in
            TablePickerView { rows, columns in
                close()
                self.editor.insertTable(rows: rows, columns: columns)
            }
        }
    }

    @objc func pdTableInsertRow(_ sender: Any?) { editor.insertTableRow(below: (sender as? NSMenuItem)?.tag == 1) }
    @objc func pdTableInsertColumn(_ sender: Any?) { editor.insertTableColumn(right: (sender as? NSMenuItem)?.tag == 1) }
    @objc func pdTableDeleteRow(_ sender: Any?) { editor.deleteTableRow() }
    @objc func pdTableDeleteColumn(_ sender: Any?) { editor.deleteTableColumn() }
    @objc func pdTableDelete(_ sender: Any?) { editor.deleteTable() }

    @objc func pdTableProperties(_ sender: Any?) {
        guard let (model, cell) = editor.tableAtCaret() else { return }
        presentSheet { dismiss in
            TablePropertiesView(borderWidth: Double(model.borderWidth), borderColorHex: model.borderColor.hexString ?? "000000",
                                cellBackgroundHex: cell.background?.hexString) { width, color, background, distribute in
                self.editor.applyTableProperties(borderWidth: width, borderColor: color, cellBackground: background, distributeColumns: distribute)
                dismiss()
            } cancel: { dismiss() }
        }
    }
    @objc func pdEditFooter(_ sender: Any?) { editor.editHeaderFooter(.footer) }
    @objc func pdInsertPageCount(_ sender: Any?) { editor.insertPageField(.pageCount) }
    @objc func pdRemoveHeader(_ sender: Any?) { editor.removeHeaderFooter(.header) }
    @objc func pdRemoveFooter(_ sender: Any?) { editor.removeHeaderFooter(.footer) }

    @objc func pdInsertPageNumber(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag, let position = EditorController.PageNumberPosition(rawValue: tag) else { return }
        editor.insertPageNumber(position)
    }

    @objc func pdToggleDifferentFirstPage(_ sender: Any?) {
        guard let document = puggleDocument else { return }
        let old = document.pageSetup
        var setup = old
        setup.differentFirstPage.toggle()
        changePageSetup(to: setup, from: old)
    }

    func insertImageFromFile() {
        guard let window, state.isEditable else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an image to insert"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
            if !self.editor.insertImage(data: data, type: UTType(filenameExtension: url.pathExtension)) {
                let alert = NSAlert()
                alert.messageText = "This image can't be inserted"
                alert.informativeText = "PuggleDocs couldn't read “\(url.lastPathComponent)” as an image."
                alert.beginSheetModal(for: window)
            }
        }
    }

    @objc func pdImageOptions(_ sender: Any?) {
        guard let (range, attachment) = editor.selectedImage, let info = ImageAttachments.info(attachment) else { return }
        let natural = NSImage(data: info.data)?.size ?? info.size
        presentSheet { dismiss in
            ImageOptionsView(width: Double(info.size.width), height: Double(info.size.height), naturalSize: natural,
                             maximum: self.editor.maximumImageSize) { size in
                self.editor.setImageSize(size, at: range)
                dismiss()
            } cancel: { dismiss() }
        }
    }

    private func linkTarget(_ sender: Any?) -> (NSRange, URL)? {
        if let index = (sender as? NSMenuItem)?.representedObject as? Int { return linkRange(around: NSRange(location: index, length: 1)) }
        return linkRange(around: editor.activeTextView.selectedRange())
    }

    @objc func pdRemoveLink(_ sender: Any?) {
        if let (range, _) = linkTarget(sender) { editor.removeLink(in: range) }
    }

    @objc func pdOpenLink(_ sender: Any?) {
        if let (_, url) = linkTarget(sender) { NSWorkspace.shared.open(url) }
    }

    @objc func pdCopyLink(_ sender: Any?) {
        guard let (_, url) = linkTarget(sender) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @objc func pdFind(_ sender: Any?) { find.show(replace: false) }
    @objc func pdFindAndReplace(_ sender: Any?) { find.show(replace: true) }
    @objc func pdFindNext(_ sender: Any?) { find.next() }
    @objc func pdFindPrevious(_ sender: Any?) { find.previous() }

    @objc func pdToggleSpellCheck(_ sender: Any?) { editor.setSpellChecking(!state.isSpellCheckEnabled) }

    @objc func pdDownload(_ sender: Any?) {
        guard let document = puggleDocument, let window, let tag = (sender as? NSMenuItem)?.tag,
              DownloadFormat.allCases.indices.contains(tag) else { return }
        let format = DownloadFormat.allCases[tag]
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        panel.nameFieldStringValue = (state.title.isEmpty ? "Untitled document" : state.title) + "." + format.fileExtension
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            if let documentFormat = format.documentFormat {
                document.save(to: url, ofType: documentFormat.typeIdentifier, for: .saveToOperation) { error in
                    if let error { document.presentError(error) }
                }
            } else if format == .epub {
                do {
                    try EpubWriter.write(document.content, title: document.title).write(to: url, options: .atomic)
                } catch {
                    document.presentError(DocumentIOError.unwritable("The EPUB could not be written."))
                }
            } else if !self.editor.exportPDF(to: url) {
                document.presentError(DocumentIOError.unwritable("The PDF could not be created."))
            }
        }
    }

    @objc func pdRename(_ sender: Any?) { state.renameRequest += 1 }

    @objc func pdMoreFonts(_ sender: Any?) {
        presentSheet { dismiss in
            MoreFontsView { family in
                if let family { self.editor.setFontFamily(family) }
                dismiss()
            }
        }
    }

    @objc func pdSetFont(_ sender: Any?) {
        guard let family = (sender as? NSMenuItem)?.representedObject as? String else { return }
        editor.setFontFamily(family)
    }

    @objc func pdSetFontSize(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag, tag > 0 else { return }
        editor.setFontSize(CGFloat(tag))
    }

    @objc func pdPageSetup(_ sender: Any?) {
        guard let document = puggleDocument else { return }
        let original = document.pageSetup
        presentSheet { dismiss in
            PageSetupView(setup: original) { setup in
                self.changePageSetup(to: setup, from: original)
                dismiss()
            } setDefault: { setup in
                PageSetupDefaults.save(setup)
            } cancel: { dismiss() }
        }
    }

    @objc func pdShowShortcuts(_ sender: Any?) {
        presentSheet { dismiss in KeyboardShortcutsView(done: dismiss) }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else { return true }
        let summary = state.summary
        let editable = state.isEditable
        func check(_ on: Bool) { menuItem.state = on ? .on : .off }
        // While a comment is being typed, document commands stay out of the way.
        if window?.firstResponder is CommentTextView {
            return [#selector(pdZoomIn(_:)), #selector(pdZoomOut(_:)), #selector(pdActualSize(_:)), #selector(pdCommentHistory(_:)),
                    #selector(pdShowShortcuts(_:)), #selector(pdDownload(_:)), #selector(pdCollaborate(_:))].contains(action)
        }
        switch action {
        case #selector(pdCollaborate(_:)):
            menuItem.title = state.collaboration.isShared ? "Collaborators…" : "Collaborate…"
            return state.access != .locked || state.collaboration.isShared
        case #selector(pdInsertComment(_:)): return state.canComment && !editor.isEditingHeaderFooter
        case #selector(pdCommentHistory(_:)): check(editor.comments.model.showsHistory); return true
        case #selector(pdToggleBold(_:)): check(summary.isBold)
        case #selector(pdToggleItalic(_:)): check(summary.isItalic)
        case #selector(pdToggleUnderline(_:)): check(summary.isUnderlined)
        case #selector(pdToggleStrikethrough(_:)): check(summary.isStruckThrough)
        case #selector(pdSuperscript(_:)): check(summary.baseline == 1)
        case #selector(pdSubscript(_:)): check(summary.baseline == -1)
        case #selector(pdApplyStyle(_:)):
            check(NamedStyle.allCases.indices.contains(menuItem.tag) && summary.namedStyle == NamedStyle.allCases[menuItem.tag])
        case #selector(pdAlign(_:)):
            let alignments: [NSTextAlignment] = [.left, .center, .right, .justified]
            check(alignments.indices.contains(menuItem.tag) && summary.alignment == alignments[menuItem.tag])
        case #selector(pdLineSpacing(_:)):
            check(summary.lineSpacing.map { abs($0 * 100 - CGFloat(menuItem.tag)) < 1 } ?? false)
        case #selector(pdToggleSpaceBefore(_:)):
            menuItem.title = summary.spaceBefore > 0 ? "Remove space before paragraph" : "Add space before paragraph"
        case #selector(pdToggleSpaceAfter(_:)):
            menuItem.title = summary.spaceAfter > 0 ? "Remove space after paragraph" : "Add space after paragraph"
        case #selector(pdBulletedList(_:)): check(summary.listKind == .bulleted)
        case #selector(pdNumberedList(_:)): check(summary.listKind == .numbered)
        case #selector(pdChecklist(_:)): check(summary.listKind == .checklist)
        case #selector(pdToggleRuler(_:)): check(state.showsRuler); return true
        case #selector(pdToggleOutline(_:)): check(state.showsOutline); return true
        case #selector(pdToggleInvisibles(_:)): check(editor.layoutManager.showsInvisibleCharacters); return true
        case #selector(pdToggleSpellCheck(_:)): check(state.isSpellCheckEnabled); return true
        case #selector(pdToggleWordCount(_:)):
            if menuItem.title != "Hide word count" { check(state.showsWordCount) }
            return true
        case #selector(pdSetWordCountMetric(_:)), #selector(pdFind(_:)), #selector(pdFindNext(_:)), #selector(pdFindPrevious(_:)): return true
        case #selector(pdFindAndReplace(_:)), #selector(pdOpenLink(_:)), #selector(pdCopyLink(_:)): return true
        case #selector(pdSetMode(_:)):
            let modes = EditingMode.allCases
            guard modes.indices.contains(menuItem.tag) else { return false }
            let mode = modes[menuItem.tag]
            check(mode == state.mode)
            // People who may only comment comment in place of editing, and can't suggest.
            menuItem.title = mode == .editing && state.access == .commentOnly ? "Commenting" : mode.title
            return state.access == .full || mode != .suggesting
        case #selector(pdAcceptAllSuggestions(_:)), #selector(pdRejectAllSuggestions(_:)):
            return editable && editor.hasSuggestions
        case #selector(pdSetZoom(_:)):
            check(menuItem.tag != 0 && abs(state.zoom * 100 - CGFloat(menuItem.tag)) < 0.5)
            return true
        case #selector(pdPageSetup(_:)): return editable
        case #selector(pdImageOptions(_:)): return editable && editor.selectedImage != nil
        case #selector(pdToggleDifferentFirstPage(_:)): check(editor.pageSetup.differentFirstPage); return editable
        case #selector(pdInsertPageCount(_:)): return editable && editor.isEditingHeaderFooter
        case #selector(pdTableInsertRow(_:)), #selector(pdTableInsertColumn(_:)), #selector(pdTableDeleteRow(_:)),
             #selector(pdTableDeleteColumn(_:)), #selector(pdTableDelete(_:)), #selector(pdTableProperties(_:)):
            return editable && editor.isInTable
        case #selector(pdInsertTable(_:)): return editable && !editor.isEditingHeaderFooter
        case #selector(pdRemoveHeader(_:)): return editable && editor.headerStorage.length > 0
        case #selector(pdRemoveFooter(_:)): return editable && editor.footerStorage.length > 0
        case #selector(pdInsertPageBreak(_:)), #selector(pdBulletedList(_:)), #selector(pdNumberedList(_:)), #selector(pdChecklist(_:)), #selector(pdInsertImage(_:)):
            if editor.isEditingHeaderFooter { return false }
        case #selector(pdRename(_:)):
            return puggleDocument?.sharedCopy == nil
        case #selector(pdZoomIn(_:)), #selector(pdZoomOut(_:)), #selector(pdActualSize(_:)), #selector(pdZoomToFit(_:)),
             #selector(pdWordCount(_:)), #selector(pdDownload(_:)), #selector(pdShowShortcuts(_:)):
            return true
        default:
            break
        }
        return editable
    }
}
