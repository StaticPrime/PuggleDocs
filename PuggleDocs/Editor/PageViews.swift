import AppKit
import PuggleDocsKit

/// Keeps the pages horizontally centered when the window is wider than the document.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let documentFrame = documentView.frame
        if rect.width > documentFrame.width {
            rect.origin.x = (documentFrame.width - rect.width) / 2
        }
        return rect
    }
}

/// The scrolling surface: pages stacked vertically on a light gray canvas.
final class PageCanvasView: NSView {
    static let pageGap: CGFloat = 12
    static let verticalPadding: CGFloat = 12
    static let sidePadding: CGFloat = 24

    private(set) var pages: [PageView] = []
    var pageSize = PageSetup.localeDefault.pageSize {
        didSet { relayout() }
    }
    /// Room for comment cards to the right of the pages, in canvas units.
    var rightGutter: CGFloat = 0 {
        didSet { if rightGutter != oldValue { relayout() } }
    }
    /// The visible width in canvas units: with comments, pages stay centered while the cards fit
    /// beside them and slide left when they don't.
    var visibleWidth: CGFloat = 0 {
        didSet { if rightGutter > 0, abs(visibleWidth - oldValue) > 0.5 { relayout() } }
    }
    var onLayout: (() -> Void)?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var isOpaque: Bool { true }

    func add(_ page: PageView) {
        pages.append(page)
        addSubview(page)
        relayout()
    }

    func removeLastPage() {
        guard let page = pages.popLast() else { return }
        page.removeFromSuperview()
        relayout()
    }

    func relayout() {
        var width = pageSize.width + Self.sidePadding * 2
        var x = Self.sidePadding
        if rightGutter > 0 {
            width = max(width + rightGutter, floor(visibleWidth))
            x = max(Self.sidePadding, min((width - pageSize.width) / 2, width - rightGutter - Self.sidePadding - pageSize.width))
        }
        var y = Self.verticalPadding
        for page in pages {
            page.frame = NSRect(x: x, y: y, width: pageSize.width, height: pageSize.height)
            y += pageSize.height + Self.pageGap
        }
        let height = max(y - Self.pageGap + Self.verticalPadding, pageSize.height + Self.verticalPadding * 2)
        setFrameSize(NSSize(width: width, height: height))
        onLayout?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard NSGraphicsContext.currentContextDrawingToScreen() else { return }
        Theme.canvas.setFill()
        dirtyRect.fill()
    }

    /// Clicking the gray canvas places the caret at the end of the nearest page.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let page = pages.min(by: { abs($0.frame.midY - point.y) < abs($1.frame.midY - point.y) }) else { return }
        page.textView.mouseDown(with: event)
    }

    // MARK: Printing

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: pages.count)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        pages.indices.contains(page - 1) ? pages[page - 1].frame : .zero
    }
}

/// One sheet of paper hosting the text view for its text container, plus its header and footer.
final class PageView: NSView {
    let textView: DocumentTextView
    private var paperColor = NSColor.white
    private(set) var headerView: HeaderFooterTextView?
    private(set) var footerView: HeaderFooterTextView?
    private var editingHeader = false
    private var editingFooter = false
    private var optionsButton: NSButton?
    private var setup = PageSetup.localeDefault
    var isFirstPage = false

    init(textView: DocumentTextView) {
        self.textView = textView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.borderColor = NSColor(white: 0, alpha: 0.06).cgColor
        layer?.borderWidth = 0.5
        layer?.shadowColor = NSColor(srgbRed: 60 / 255, green: 64 / 255, blue: 67 / 255, alpha: 1).cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 2
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(rect: bounds, transform: nil)
    }

    func attach(header: HeaderFooterTextView, footer: HeaderFooterTextView) {
        headerView = header
        footerView = footer
        header.page = self
        footer.page = self
        addSubview(header)
        addSubview(footer)
    }

    func detachHeaderFooter() {
        headerView?.detach()
        footerView?.detach()
        headerView?.removeFromSuperview()
        footerView?.removeFromSuperview()
    }

    func place(textAreaIn setup: PageSetup) {
        self.setup = setup
        textView.frame = NSRect(x: setup.margins.left, y: setup.margins.top,
                                width: setup.contentSize.width, height: setup.contentSize.height)
        paperColor = setup.pageColor
        layer?.backgroundColor = paperColor.cgColor
        let pageHeight = setup.pageSize.height
        let headerHeight = max(14, setup.margins.top - setup.headerDistance - 6)
        let footerHeight = max(14, setup.margins.bottom - setup.footerDistance - 6)
        headerView?.frame = NSRect(x: setup.margins.left, y: min(setup.headerDistance, setup.margins.top - 14),
                                   width: setup.contentSize.width, height: headerHeight)
        footerView?.frame = NSRect(x: setup.margins.left, y: pageHeight - setup.margins.bottom + 6,
                                   width: setup.contentSize.width, height: footerHeight)
        for view in [headerView, footerView].compactMap({ $0 }) {
            view.textContainer?.size = NSSize(width: setup.contentSize.width, height: 10_000)
            view.isHidden = isFirstPage && setup.differentFirstPage
            view.invalidateTextContainerOrigin()
        }
        needsDisplay = true
    }

    func setEditing(_ kind: HeaderFooterTextView.Kind, _ editing: Bool) {
        if kind == .header { editingHeader = editing } else { editingFooter = editing }
        optionsButton?.removeFromSuperview()
        optionsButton = nil
        if editingHeader || editingFooter, let view = editingHeader ? headerView : footerView {
            let button = NSButton(title: "Options ▾", target: self, action: #selector(showOptions(_:)))
            button.isBordered = false
            button.font = NSFont.systemFont(ofSize: 11.5)
            button.contentTintColor = NSColor(srgbRed: 0.04, green: 0.34, blue: 0.82, alpha: 1)
            button.sizeToFit()
            let y = editingHeader ? view.frame.maxY + 2 : view.frame.minY - button.frame.height - 2
            button.setFrameOrigin(NSPoint(x: view.frame.maxX - button.frame.width, y: y))
            addSubview(button)
            optionsButton = button
        }
        needsDisplay = true
    }

    @objc private func showOptions(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(MenuBuilder.item("Different first page", #selector(DocumentCommands.pdToggleDifferentFirstPage(_:))))
        menu.addItem(.separator())
        if editingHeader {
            menu.addItem(MenuBuilder.item("Remove header", #selector(DocumentCommands.pdRemoveHeader(_:))))
        } else {
            menu.addItem(MenuBuilder.item("Remove footer", #selector(DocumentCommands.pdRemoveFooter(_:))))
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    override func draw(_ dirtyRect: NSRect) {
        // On screen the layer paints the paper; printing and PDF export draw it here.
        guard NSGraphicsContext.currentContextDrawingToScreen() else {
            paperColor.setFill()
            dirtyRect.fill()
            return
        }
        // While a header or footer is being edited, show its boundary and name.
        let labelAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 0.4, alpha: 1)]
        NSColor(srgbRed: 0.85, green: 0.86, blue: 0.88, alpha: 1).setFill()
        if editingHeader, let header = headerView {
            NSRect(x: 0, y: header.frame.maxY + 1, width: bounds.width, height: 1).fill()
            ("Header" as NSString).draw(at: NSPoint(x: header.frame.minX, y: header.frame.maxY + 4), withAttributes: labelAttributes)
        }
        if editingFooter, let footer = footerView {
            NSRect(x: 0, y: footer.frame.minY - 2, width: bounds.width, height: 1).fill()
            ("Footer" as NSString).draw(at: NSPoint(x: footer.frame.minX, y: footer.frame.minY - 17), withAttributes: labelAttributes)
        }
    }

    /// Clicks in the margins act like clicks on the nearest text.
    override func mouseDown(with event: NSEvent) {
        textView.mouseDown(with: event)
    }
}
