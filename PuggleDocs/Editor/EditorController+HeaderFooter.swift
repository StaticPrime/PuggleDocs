import AppKit
import PuggleDocsKit

extension EditorController {
    enum PageNumberPosition: Int { case headerRight, footerRight, footerCenter }

    /// The header or footer view of the page with the caret, or the first page that shows one.
    func headerFooterView(_ kind: HeaderFooterTextView.Kind) -> HeaderFooterTextView? {
        let caretPage = pages.firstIndex { $0.textView === textView(forCharacterAt: activeTextView.selectedRange().location) } ?? 0
        let candidates = [caretPage] + Array(pages.indices)
        for index in candidates where pages.indices.contains(index) {
            let page = pages[index]
            guard let view = kind == .header ? page.headerView : page.footerView, !view.isHidden else { continue }
            return view
        }
        return nil
    }

    /// Insert ▸ Headers & footers: starts editing the header or footer.
    func editHeaderFooter(_ kind: HeaderFooterTextView.Kind) {
        guard state.isEditable, let view = headerFooterView(kind) else { return }
        scrollView.window?.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: view.textStorage?.length ?? 0, length: 0))
        view.scrollToVisible(view.bounds)
    }

    /// Adds a page number to the header or footer (Insert ▸ Page numbers).
    func insertPageNumber(_ position: PageNumberPosition) {
        let kind: HeaderFooterTextView.Kind = position == .headerRight ? .header : .footer
        guard state.isEditable, let view = headerFooterView(kind), let storage = view.textStorage else { return }
        let style = DocumentDefaults.paragraphStyle()
        style.alignment = position == .footerCenter ? .center : .right
        var attributes = DocumentDefaults.typingAttributes
        attributes[.paragraphStyle] = style.copy() as! NSParagraphStyle
        let insertion = NSMutableAttributedString()
        if storage.length > 0 { insertion.append(NSAttributedString(string: "\n", attributes: attributes)) }
        var fieldAttributes = attributes
        fieldAttributes[.attachment] = PageFieldAttachment(kind: .pageNumber)
        insertion.append(NSAttributedString(string: "\u{FFFC}", attributes: fieldAttributes))
        let range = NSRange(location: storage.length, length: 0)
        guard view.shouldChangeText(in: range, replacementString: insertion.string) else { return }
        storage.replaceCharacters(in: range, with: insertion)
        view.didChangeText()
        undoManager?.setActionName("Page Numbers")
        scrollView.window?.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: storage.length, length: 0))
    }

    /// Inserts a page number or page count field at the caret of the header or footer being edited.
    func insertPageField(_ kind: PageFieldAttachment.Kind) {
        guard state.isEditable, let view = editingHeaderFooterView, let storage = view.textStorage else { return }
        let range = view.selectedRange()
        var attributes = view.typingAttributes
        attributes[.attachment] = PageFieldAttachment(kind: kind)
        let insertion = NSAttributedString(string: "\u{FFFC}", attributes: attributes)
        guard view.shouldChangeText(in: range, replacementString: insertion.string) else { return }
        storage.replaceCharacters(in: range, with: insertion)
        view.didChangeText()
        undoManager?.setActionName(kind == .pageNumber ? "Page Number" : "Page Count")
        view.setSelectedRange(NSRange(location: range.location + 1, length: 0))
    }

    func removeHeaderFooter(_ kind: HeaderFooterTextView.Kind) {
        let storage = kind == .header ? headerStorage : footerStorage
        guard state.isEditable, storage.length > 0,
              let view = pages.lazy.compactMap({ kind == .header ? $0.headerView : $0.footerView }).first else { return }
        let range = NSRange(location: 0, length: storage.length)
        guard view.shouldChangeText(in: range, replacementString: "") else { return }
        storage.replaceCharacters(in: range, with: "")
        view.didChangeText()
        undoManager?.setActionName(kind == .header ? "Remove Header" : "Remove Footer")
        focus()
    }
}
