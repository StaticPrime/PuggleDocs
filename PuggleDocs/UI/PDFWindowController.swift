import AppKit
import Observation
import PDFKit
import PuggleDocsKit
import SwiftUI

@Observable
final class PDFViewerState {
    var title = "PDF"
    var pageIndex = 0
    var pageCount = 0
    var zoom: CGFloat = 1
    var showsThumbnails = true
    var titlebarLeading: CGFloat = 78
    var titlebarCenterY: CGFloat = 18

    var pageLabel: String { pageCount == 0 ? "" : "Page \(pageIndex + 1) of \(pageCount)" }
    var zoomLabel: String { "\(Int((zoom * 100).rounded()))%" }
}

/// A viewer window for PDFs, styled like the editor.
final class PDFWindowController: NSWindowController, NSWindowDelegate {
    let state = PDFViewerState()
    let pdfView = PDFView()
    private let thumbnails = PDFThumbnailView()
    private var thumbnailWidth: NSLayoutConstraint!

    var viewerDocument: PDFViewerDocument? { document as? PDFViewerDocument }

    init(document: PDFViewerDocument) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = Theme.canvas
        window.appearance = NSAppearance(named: .aqua)
        window.minSize = NSSize(width: 640, height: 420)
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = true

        pdfView.document = document.pdf
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = Theme.canvas
        pdfView.autoScales = true
        pdfView.interpolationQuality = .high
        thumbnails.pdfView = pdfView
        thumbnails.thumbnailSize = NSSize(width: 96, height: 124)
        thumbnails.backgroundColor = Theme.canvas

        buildContent()
        state.title = (document.displayName as NSString?)?.deletingPathExtension ?? "PDF"
        state.pageCount = document.pdf?.pageCount ?? 0
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(scaleChanged), name: .PDFViewScaleChanged, object: pdfView)
        window.center()
        updateTitlebarMetrics()
        DispatchQueue.main.async { [weak self] in
            self?.scaleChanged()
            self?.updateTitlebarMetrics()
        }
    }

    func updateTitlebarMetrics() {
        guard let window else { return }
        let metrics = TitlebarMetrics.measure(window)
        state.titlebarLeading = metrics.leading
        state.titlebarCenterY = metrics.centerY
    }

    func windowDidResize(_ notification: Notification) { updateTitlebarMetrics() }
    func windowDidEnterFullScreen(_ notification: Notification) { updateTitlebarMetrics() }
    func windowDidExitFullScreen(_ notification: Notification) { updateTitlebarMetrics() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func buildContent() {
        guard let window else { return }
        let content = NSView()
        window.contentView = content
        let chrome = NSHostingView(rootView: PDFChromeView(state: state, controller: self))
        chrome.sizingOptions = [.intrinsicContentSize]
        chrome.safeAreaRegions = []
        for view in [chrome, thumbnails, pdfView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        thumbnailWidth = thumbnails.widthAnchor.constraint(equalToConstant: 132)
        NSLayoutConstraint.activate([
            chrome.topAnchor.constraint(equalTo: content.topAnchor),
            chrome.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            thumbnails.topAnchor.constraint(equalTo: chrome.bottomAnchor, constant: 8),
            thumbnails.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            thumbnails.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            thumbnailWidth,
            pdfView.topAnchor.constraint(equalTo: chrome.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: thumbnails.trailingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    override func synchronizeWindowTitleWithDocumentName() {
        super.synchronizeWindowTitleWithDocumentName()
        state.title = (document?.displayName as NSString?)?.deletingPathExtension ?? state.title
    }

    @objc private func pageChanged() {
        guard let page = pdfView.currentPage, let document = pdfView.document else { return }
        state.pageIndex = document.index(for: page)
    }

    @objc private func scaleChanged() {
        state.zoom = pdfView.scaleFactor
    }

    // MARK: Actions

    func toggleThumbnails() {
        state.showsThumbnails.toggle()
        thumbnailWidth.constant = state.showsThumbnails ? 132 : 0
        thumbnails.isHidden = !state.showsThumbnails
    }

    func zoom(in zoomIn: Bool) {
        pdfView.autoScales = false
        if zoomIn { pdfView.zoomIn(nil) } else { pdfView.zoomOut(nil) }
    }

    func fitWidth() {
        pdfView.autoScales = true
    }

    func go(toPage offset: Int) {
        if offset > 0 { pdfView.goToNextPage(nil) } else { pdfView.goToPreviousPage(nil) }
    }

    func printPDF() {
        document?.printDocument(nil)
    }

    /// Opens the PDF's text as a new editable document.
    func openAsEditableDocument() {
        guard let viewer = viewerDocument else { return }
        let text = viewer.editableText()
        let document = PuggleDocument()
        document.textStorage.setAttributedString(text)
        document.customTitle = state.title
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
    }

    @objc func zoomIn(_ sender: Any?) { zoom(in: true) }
    @objc func zoomOut(_ sender: Any?) { zoom(in: false) }
}

struct PDFChromeView: View {
    let state: PDFViewerState
    let controller: PDFWindowController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 28, height: 28)
                Text(state.title)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Text(".PDF")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.secondaryText.opacity(0.5), lineWidth: 1))
                Spacer()
                ToolbarIconButton(symbol: "printer", help: "Print (⌘P)") { controller.printPDF() }
                Button {
                    controller.openAsEditableDocument()
                } label: {
                    Label("Open as editable document", systemImage: "doc.text")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(red: 0.0, green: 0.12, blue: 0.27))
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Capsule().fill(Color(red: 0.76, green: 0.87, blue: 1.0)))
                }
                .buttonStyle(.plain)
                .help("Copy the PDF's text into a new document you can edit")
            }
            .frame(height: TitlebarMetrics.rowHeight)
            .padding(.leading, state.titlebarLeading)
            .padding(.trailing, 14)
            .padding(.top, max(0, state.titlebarCenterY - TitlebarMetrics.rowHeight / 2))
            .padding(.bottom, 8)
            .background(WindowDragArea())

            HStack(spacing: 1) {
                ToolbarIconButton(symbol: "sidebar.left", help: "Show page thumbnails", isOn: state.showsThumbnails) { controller.toggleThumbnails() }
                ToolbarDivider()
                ToolbarIconButton(symbol: "chevron.up", help: "Previous page", isEnabled: state.pageIndex > 0) { controller.go(toPage: -1) }
                ToolbarIconButton(symbol: "chevron.down", help: "Next page", isEnabled: state.pageIndex < state.pageCount - 1) { controller.go(toPage: 1) }
                Text(state.pageLabel)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.primaryText)
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                ToolbarDivider()
                ToolbarIconButton(symbol: "minus.magnifyingglass", help: "Zoom out") { controller.zoom(in: false) }
                Text(state.zoomLabel)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.primaryText)
                    .monospacedDigit()
                    .frame(width: 44)
                ToolbarIconButton(symbol: "plus.magnifyingglass", help: "Zoom in") { controller.zoom(in: true) }
                ToolbarIconButton(symbol: "arrow.left.and.right", help: "Fit to width") { controller.fitWidth() }
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
            .background(Capsule().fill(Theme.toolbarFill))
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
        .background(Color(nsColor: Theme.canvas))
        .ignoresSafeArea(.container, edges: .top)
    }
}
