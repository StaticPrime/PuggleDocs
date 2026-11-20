#if DEBUG
import AppKit
import PuggleDocsKit
import UniformTypeIdentifiers

/// Drives a real editor through common editing scenarios (`-PDSelfTest YES`), printing PASS/FAIL
/// lines and quitting. Steps run on separate run-loop turns so undo groups close as they would
/// between user events.
@MainActor
final class SelfTest {
    private let editor: EditorController
    private var steps: [(String, () -> Bool)] = []
    private var failures = 0

    init(editor: EditorController) { self.editor = editor }

    static func runIfRequested() {
        guard UserDefaults.standard.bool(forKey: "PDSelfTest") else { return }
        if UserDefaults.standard.string(forKey: "PDSelfTestSuite") == "collaboration" {
            CollaborationSelfTest.run()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard let controller = NSApp.windows.compactMap({ $0.windowController as? DocumentWindowController }).first else {
                print("SELFTEST FAIL: no window")
                NSApp.terminate(nil)
                return
            }
            let test = SelfTest(editor: controller.editor)
            test.defineSteps()
            test.next()
        }
    }

    private var view: DocumentTextView { editor.activeTextView }

    static func samplePNG(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGradient(starting: NSColor(srgbRed: 0.3, green: 0.55, blue: 0.97, alpha: 1), ending: NSColor(srgbRed: 1, green: 0.69, blue: 0.13, alpha: 1))!
            .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 30)
        let label = NSAttributedString(string: "PuggleDocs", attributes: [.font: NSFont.boldSystemFont(ofSize: CGFloat(height) / 5), .foregroundColor: NSColor.white])
        label.draw(at: NSPoint(x: CGFloat(width) * 0.08, y: CGFloat(height) * 0.4))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
    private var storage: NSTextStorage { editor.textStorage }
    private var string: String { storage.string }

    private func type(_ text: String) {
        for character in text { view.insertText(String(character), replacementRange: view.selectedRange()) }
    }

    private func command(_ selector: Selector) { view.doCommand(by: selector) }

    private func item(at index: Int) -> ListItem? {
        index < storage.length ? storage.attribute(.pdListItem, at: index, effectiveRange: nil) as? ListItem : view.typingAttributes[.pdListItem] as? ListItem
    }

    private func style(at index: Int) -> String? {
        storage.attribute(.pdNamedStyle, at: index, effectiveRange: nil) as? String
    }

    private func select(_ range: NSRange) { view.setSelectedRange(range) }

    private func step(_ name: String, _ body: @escaping () -> Bool) { steps.append((name, body)) }

    private func next() {
        guard !steps.isEmpty else {
            print(failures == 0 ? "SELFTEST DONE: all passed" : "SELFTEST DONE: \(failures) failed")
            editor.document?.updateChangeCount(.changeCleared)
            NSApp.terminate(nil)
            return
        }
        let (name, body) = steps.removeFirst()
        // AppKit groups undo by input event; steps are not events, so give each one its own group.
        let undoManager = editor.undoManager
        undoManager?.groupsByEvent = false
        let isUndoStep = name.hasPrefix("undo")
        if !isUndoStep { undoManager?.beginUndoGrouping() }
        let passed = body()
        if !isUndoStep { undoManager?.endUndoGrouping() }
        if !passed { failures += 1 }
        print("SELFTEST \(passed ? "PASS" : "FAIL"): \(name)\(passed ? "" : " — text: \(string.debugDescription)")")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.next() }
    }

    private func defineSteps() {
        step("typing uses Normal text defaults") {
            self.type("Hello world")
            let spec = FontResolver.spec(from: self.storage.attributes(at: 0, effectiveRange: nil))
            return self.string == "Hello world" && spec.family == "Arial" && spec.size == 11 && self.style(at: 0) == "normal"
        }
        step("bold applies to the selection") {
            self.select(NSRange(location: 0, length: 5))
            self.editor.toggleBold()
            return CharacterFormatting.isBold(self.storage.attributes(at: 0, effectiveRange: nil))
                && !CharacterFormatting.isBold(self.storage.attributes(at: 6, effectiveRange: nil))
        }
        step("undo removes bold but keeps the text") {
            self.editor.undoManager?.undo()
            guard self.string == "Hello world" else { return false }
            return !CharacterFormatting.isBold(self.storage.attributes(at: 0, effectiveRange: nil))
        }
        step("heading style then Return gives Normal text") {
            self.select(NSRange(location: 11, length: 0))
            self.editor.applyNamedStyle(.heading1)
            self.command(#selector(NSResponder.insertNewline(_:)))
            self.type("Body")
            return self.style(at: 0) == "heading1" && self.style(at: 12) == "normal"
                && FontResolver.spec(from: self.storage.attributes(at: 12, effectiveRange: nil)).size == 11
        }
        step("bulleted list toggle") {
            self.editor.toggleList(.bulleted)
            return self.item(at: 12)?.kind == .bulleted
        }
        step("Return continues the list") {
            self.command(#selector(NSResponder.insertNewline(_:)))
            self.type("Second")
            let first = self.item(at: 12)
            let second = self.item(at: 17)
            return second?.kind == .bulleted && second?.listID == first?.listID
        }
        step("Tab at item start nests, Shift-Tab outdents") {
            self.select(NSRange(location: 17, length: 0))
            self.command(#selector(NSResponder.insertTab(_:)))
            let nested = self.item(at: 17)?.level == 1 && !self.string.contains("\t")
            self.command(#selector(NSResponder.insertBacktab(_:)))
            return nested && self.item(at: 17)?.level == 0
        }
        step("Return on an empty item ends the list") {
            self.select(NSRange(location: self.storage.length, length: 0))
            self.command(#selector(NSResponder.insertNewline(_:)))
            let emptyIsItem = self.item(at: self.storage.length) != nil
            self.command(#selector(NSResponder.insertNewline(_:)))
            return emptyIsItem && self.item(at: self.storage.length) == nil
        }
        step("typing \"1. \" starts a numbered list") {
            self.type("1. Step one")
            let start = self.storage.length - "Step one".count
            return self.item(at: start)?.kind == .numbered && self.string.hasSuffix("\nStep one")
        }
        step("numbered markers count up") {
            self.command(#selector(NSResponder.insertNewline(_:)))
            self.type("Step two")
            let markers = self.editor.layoutManager.listEntries.filter { $0.item.kind == .numbered }.map(\.marker)
            return markers == ["1.", "2."]
        }
        step("Backspace at item start removes the marker but keeps the indent") {
            let start = self.storage.length - "Step two".count
            self.select(NSRange(location: start, length: 0))
            self.command(#selector(NSResponder.deleteBackward(_:)))
            let style = self.storage.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle
            return self.item(at: start) == nil && style?.headIndent == 36 && self.string.hasSuffix("Step two")
        }
        step("increase and decrease indent") {
            let start = self.storage.length - "Step two".count
            self.editor.indent(increase: true)
            let indented = (self.storage.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle)?.headIndent == 72
            self.editor.indent(increase: false)
            self.editor.indent(increase: false)
            return indented && (self.storage.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle)?.headIndent == 0
        }
        step("alignment and line spacing") {
            self.editor.setAlignment(.center)
            self.editor.setLineSpacing(2)
            let style = self.storage.attribute(.paragraphStyle, at: self.storage.length - 1, effectiveRange: nil) as? NSParagraphStyle
            return style?.alignment == .center && style?.lineHeightMultiple == 2
        }
        step("checklist items start unchecked after Return") {
            self.select(NSRange(location: self.storage.length, length: 0))
            self.command(#selector(NSResponder.insertNewline(_:)))
            self.editor.setAlignment(.left)
            self.editor.toggleList(.checklist)
            self.type("Task")
            let start = self.storage.length - 4
            self.storage.addAttribute(.pdListItem, value: self.item(at: start)!.with(checked: true), range: NSRange(location: start, length: 4))
            self.command(#selector(NSResponder.insertNewline(_:)))
            self.type("Next")
            return self.item(at: start)?.isChecked == true && self.item(at: self.storage.length - 1)?.isChecked == false
        }
        step("page break adds a page") {
            self.select(NSRange(location: self.storage.length, length: 0))
            self.editor.insertPageBreak()
            self.type("On page two")
            self.editor.adjustPages()
            return self.editor.pages.count == 2
        }
        step("scrolling to text on page two shows page two") {
            let range = (self.string as NSString).range(of: "On page two")
            self.select(range)
            self.view.scrollRangeToVisible(range)
            let visible = self.editor.scrollView.contentView.documentVisibleRect
            return self.editor.pages.count == 2 && visible.intersects(self.editor.pages[1].frame)
        }
        step("arrow keys move the caret onto page two and focus follows") {
            let pageOneEnd = (self.string as NSString).range(of: "\u{0C}").location
            self.select(NSRange(location: pageOneEnd, length: 0))
            self.editor.firstTextView?.window?.makeFirstResponder(self.editor.pages[0].textView)
            self.editor.pages[0].textView.doCommand(by: #selector(NSResponder.moveDown(_:)))
            self.editor.pages[0].textView.doCommand(by: #selector(NSResponder.moveDown(_:)))
            let location = self.view.selectedRange().location
            let responder = self.editor.scrollView.window?.firstResponder
            print("SELFTEST INFO: caret at \(location) of \(self.storage.length); responder is page two: \(responder === self.editor.pages[1].textView)")
            return location > pageOneEnd
        }
        step("focus is on page two after the selection settles") {
            self.editor.scrollView.window?.firstResponder === self.editor.pages[1].textView
        }
        step("copy and paste keeps list formatting") {
            let numbered = self.editor.layoutManager.listEntries.first { $0.item.kind == .numbered }!
            self.select(numbered.paragraphRange)
            let board = NSPasteboard(name: NSPasteboard.Name("PuggleDocsSelfTest"))
            board.clearContents()
            _ = self.view.writeSelection(to: board, types: [.puggleDocsRichText, .rtf, .string])
            self.select(NSRange(location: self.storage.length, length: 0))
            self.command(#selector(NSResponder.insertNewline(_:)))
            let ok = self.view.readSelection(from: board, type: .puggleDocsRichText)
            let pastedStart = self.storage.length - (numbered.paragraphRange.length)
            return ok && self.item(at: max(0, pastedStart))?.kind == .numbered
        }
        step("new links get blue underlined formatting") {
            let range = NSRange(location: 6, length: 5)
            self.storage.addAttribute(.link, value: URL(string: "https://example.com")!, range: range)
            let attributes = self.storage.attributes(at: 7, effectiveRange: nil)
            return CharacterFormatting.isUnderlined(attributes) && (attributes[.foregroundColor] as? NSColor)?.hexString == ColorPalette.linkHex
        }
        step("inserting a link replaces the selection with linked text") {
            self.select(NSRange(location: 6, length: 5))
            self.editor.applyLink(text: "planet", url: LinkAddress.normalized("example.org")!, range: NSRange(location: 6, length: 5))
            let attributes = self.storage.attributes(at: 7, effectiveRange: nil)
            let url = attributes[.link] as? URL
            return self.string.hasPrefix("Hello planet") && url?.absoluteString == "https://example.org"
                && (attributes[.foregroundColor] as? NSColor)?.hexString == ColorPalette.linkHex
        }
        step("removing a link clears its address and look") {
            self.editor.removeLink(in: NSRange(location: 6, length: 6))
            let attributes = self.storage.attributes(at: 7, effectiveRange: nil)
            return attributes[.link] == nil && !CharacterFormatting.isUnderlined(attributes)
                && (attributes[.foregroundColor] as? NSColor)?.hexString != ColorPalette.linkHex
        }
        step("inserting an image adds a selected, page-fitting picture") {
            self.select(NSRange(location: self.storage.length, length: 0))
            guard self.editor.insertImage(data: SelfTest.samplePNG(width: 1600, height: 800), type: .png) else { return false }
            guard let (range, attachment) = self.editor.selectedImage else { return false }
            let width = attachment.bounds.width
            return range.length == 1 && attachment.attachmentCell is ImageAttachmentCell
                && abs(width - self.editor.maximumImageSize.width) < 1 && self.editor.imageOverlay?.superview != nil
        }
        step("resizing an image is undoable") {
            guard let (range, _) = self.editor.selectedImage else { return false }
            self.editor.setImageSize(NSSize(width: 200, height: 100), at: range)
            let attachment = self.storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment
            return attachment?.bounds.size == NSSize(width: 200, height: 100)
        }
        step("undo restores the image size") {
            self.editor.undoManager?.undo()
            let index = (self.string as NSString).range(of: "\u{FFFC}").location
            let attachment = self.storage.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment
            return abs((attachment?.bounds.width ?? 0) - self.editor.maximumImageSize.width) < 1
        }
        step("clear formatting resets character styles") {
            self.select(NSRange(location: 0, length: 5))
            self.editor.toggleItalic()
            self.editor.clearFormatting()
            let attributes = self.storage.attributes(at: 0, effectiveRange: nil)
            return !CharacterFormatting.isItalic(attributes) && FontResolver.spec(from: attributes).size == 20
        }
        step("DOCX round trip of the edited document") {
            guard let data = try? DocumentIO.write(DocumentContent(text: self.storage, pageSetup: self.editor.pageSetup), format: .docx),
                  let content = try? DocumentIO.read(data, format: .docx) else { return false }
            let original = ListNumbering.entries(in: self.storage).map(\.marker)
            return content.text.string == self.string && ListNumbering.entries(in: content.text).map(\.marker) == original
        }
        step("RTF round trip of the edited document") {
            guard let data = try? DocumentIO.write(DocumentContent(text: self.storage, pageSetup: self.editor.pageSetup), format: .rtf),
                  let content = try? DocumentIO.read(data, format: .rtf) else { return false }
            return content.text.string == self.string
        }
        step("ODT round trip of the edited document") {
            guard let data = try? DocumentIO.write(DocumentContent(text: self.storage, pageSetup: self.editor.pageSetup), format: .odt),
                  let content = try? DocumentIO.read(data, format: .odt) else { return false }
            return content.text.string == self.string
                && ListNumbering.entries(in: content.text).map(\.marker) == ListNumbering.entries(in: self.storage).map(\.marker)
        }
        step("HTML round trip of the edited document") {
            guard let data = try? DocumentIO.write(DocumentContent(text: self.storage, pageSetup: self.editor.pageSetup), format: .html),
                  let content = try? DocumentIO.read(data, format: .html) else { return false }
            let before = ListNumbering.entries(in: self.storage).map { "\($0.marker)@\($0.item.level)/\($0.item.preset.rawValue)" }
            let after = ListNumbering.entries(in: content.text).map { "\($0.marker)@\($0.item.level)/\($0.item.preset.rawValue)" }
            if content.text.string != self.string || before != after {
                print("SELFTEST INFO: HTML read back \(content.text.string.debugDescription)\n  markers before \(before)\n  markers after  \(after)")
                try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("selftest.html"))
            }
            return content.text.string == self.string
                && ListNumbering.entries(in: content.text).map(\.marker) == ListNumbering.entries(in: self.storage).map(\.marker)
        }
        step("printing produces one PDF page per document page") {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("selftest-print.pdf")
            try? FileManager.default.removeItem(at: url)
            let info = NSPrintInfo.shared.copy() as! NSPrintInfo
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
            let operation = self.editor.makePrintOperation(printInfo: info)
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
            let ran = operation.run()
            let pageCount = CGPDFDocument(url as CFURL)?.numberOfPages ?? -1
            print("SELFTEST INFO: printed \(pageCount) page(s) to \(url.path)")
            return ran && pageCount == self.editor.pages.count
        }
        step("PDF export keeps the page size and page count") {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("selftest-export.pdf")
            try? FileManager.default.removeItem(at: url)
            guard self.editor.exportPDF(to: url), let pdf = CGPDFDocument(url as CFURL), let page = pdf.page(at: 1) else { return false }
            let box = page.getBoxRect(.mediaBox)
            let size = self.editor.pageSetup.pageSize
            print("SELFTEST INFO: exported PDF \(pdf.numberOfPages) page(s), media box \(box.size)")
            return pdf.numberOfPages == self.editor.pages.count && abs(box.width - size.width) < 1 && abs(box.height - size.height) < 1
        }
        step("live word count shows words and selections") {
            guard let controller = self.editor.scrollView.window?.windowController as? DocumentWindowController else { return false }
            let wasShowing = controller.state.showsWordCount
            controller.setShowsWordCount(true)
            self.select(NSRange(location: 0, length: 5))
            controller.updateWordCount()
            let withSelection = controller.state.wordCountText
            self.select(NSRange(location: 0, length: 0))
            controller.updateWordCount()
            let total = controller.state.wordCountText
            controller.setShowsWordCount(wasShowing)
            print("SELFTEST INFO: word count \"\(total)\" / \"\(withSelection)\"")
            return total.hasSuffix("words") && withSelection.hasPrefix("1 of ")
        }
        step("find counts matches across pages and replaces them all") {
            guard let controller = self.editor.scrollView.window?.windowController as? DocumentWindowController else { return false }
            let find = controller.find
            find.show(replace: true)
            find.state.query = "step"
            find.search()
            let found = find.state.matchCount
            find.state.replacement = "Stage"
            find.replaceAll()
            let replaced = self.string.contains("Stage one") && !self.string.lowercased().contains("step")
            print("SELFTEST INFO: find matched \(found)")
            return found == 3 && replaced
        }
        step("undo of replace all restores the text") {
            self.editor.undoManager?.undo()
            (self.editor.scrollView.window?.windowController as? DocumentWindowController)?.find.close()
            return self.string.contains("Step one") && !self.string.contains("Stage")
        }
        step("outline lists headings and follows the caret") {
            guard let controller = self.editor.scrollView.window?.windowController as? DocumentWindowController else { return false }
            controller.refreshOutline()
            let titles = controller.state.outline.map(\.title)
            self.select(NSRange(location: self.storage.length, length: 0))
            controller.updateCurrentOutlineEntry()
            print("SELFTEST INFO: outline \(titles), current \(String(describing: controller.state.currentOutlineIndex))")
            return titles.first == "Hello planet" && controller.state.currentOutlineIndex == 0
        }
        step("page numbers in the footer show each page's number") {
            self.editor.insertPageNumber(.footerRight)
            let footer = self.editor.footerStorage
            let numbers = self.editor.pages.compactMap { $0.footerView?.headerLayoutManager?.pageNumber }
            print("SELFTEST INFO: footer \(footer.string.debugDescription), page numbers \(numbers)")
            return footer.length == 1 && footer.attribute(.attachment, at: 0, effectiveRange: nil) is PageFieldAttachment
                && numbers == Array(1...self.editor.pages.count)
        }
        step("header text is shared by every page and saved with the document") {
            self.editor.editHeaderFooter(.header)
            guard let view = self.editor.editingHeaderFooterView else { return false }
            view.insertText("Acme report", replacementRange: view.selectedRange())
            view.setSelectedRange(NSRange(location: 0, length: view.textStorage?.length ?? 0))
            let bodyWasBold = CharacterFormatting.isBold(self.storage.attributes(at: 0, effectiveRange: nil))
            self.editor.toggleBold()
            let routed = CharacterFormatting.isBold(self.editor.headerStorage.attributes(at: 0, effectiveRange: nil))
                && CharacterFormatting.isBold(self.storage.attributes(at: 0, effectiveRange: nil)) == bodyWasBold
            let shared = self.editor.pages.allSatisfy { $0.headerView?.textStorage === self.editor.headerStorage }
            guard let document = self.editor.document,
                  let data = try? document.data(ofType: DocumentFormat.docx.typeIdentifier),
                  let content = try? DocumentIO.read(data, format: .docx) else { return false }
            self.editor.focus()
            return shared && routed && content.header?.string == "Acme report" && content.footer?.length == 1
        }
        step("inserting a table puts the caret in the first cell") {
            self.select(NSRange(location: self.storage.length, length: 0))
            self.editor.insertTable(rows: 2, columns: 3)
            guard let (model, cell) = self.editor.tableAtCaret() else { return false }
            return model.rows == 2 && model.columns == 3 && cell.row == 0 && cell.column == 0
        }
        step("Tab moves between cells and adds a row from the last cell") {
            for word in ["A", "B", "C", "D", "E", "F"] {
                self.type(word)
                self.command(#selector(NSResponder.insertTab(_:)))
            }
            guard let (model, cell) = self.editor.tableAtCaret() else { return false }
            let texts = model.orderedCells.prefix(6).map(\.content.string)
            print("SELFTEST INFO: table \(model.rows)x\(model.columns) cells \(texts) caret \(cell.row),\(cell.column)")
            return texts == ["A", "B", "C", "D", "E", "F"] && model.rows == 3 && cell.row == 2 && cell.column == 0
        }
        step("Backspace at the start of a cell keeps the cells apart") {
            self.command(#selector(NSResponder.deleteBackward(_:)))
            guard let (model, _) = self.editor.tableAtCaret() else { return false }
            return model.cells.count == 9 && model.orderedCells[5].content.string == "F"
        }
        step("rows and columns can be added and removed") {
            self.editor.insertTableColumn(right: true)
            let afterInsert = self.editor.tableAtCaret()?.model.columns
            self.editor.deleteTableRow()
            let afterDelete = self.editor.tableAtCaret()?.model.rows
            return afterInsert == 4 && afterDelete == 2
        }
        step("tables survive DOCX, ODT, HTML and RTF") {
            var ok = true
            for format in [DocumentFormat.docx, .odt, .html, .rtf] {
                guard let data = try? DocumentIO.write(DocumentContent(text: self.storage, pageSetup: self.editor.pageSetup), format: format),
                      let content = try? DocumentIO.read(data, format: format) else { ok = false; continue }
                let index = (content.text.string as NSString).range(of: "E").location
                let model = index == NSNotFound ? nil : TableModel.table(at: index, in: content.text)
                if model?.rows != 2 || model?.columns != 4 || !content.warnings.isEmpty {
                    print("SELFTEST INFO: \(format) table \(String(describing: model?.rows))x\(String(describing: model?.columns)) warnings \(content.warnings)")
                    ok = false
                }
            }
            return ok
        }
        step("a comment anchors to the selection") {
            self.select(NSRange(location: self.storage.length, length: 0))
            self.type("Review this sentence")
            let range = (self.string as NSString).range(of: "Review this")
            self.select(range)
            self.editor.comments.startDraft()
            self.editor.comments.model.draft?.text = "Check the wording"
            self.editor.comments.commitDraft()
            guard let thread = self.editor.document?.comments.last else { return false }
            let anchors = CommentAnchors.ranges(in: self.storage)
            return thread.text == "Check the wording" && anchors[thread.id] == range && self.editor.comments.model.activeID == thread.id
                && self.editor.layoutManager.highlightedComments.contains(thread.id) && self.editor.comments.model.draft == nil
        }
        step("typing at the end of a comment doesn't extend it") {
            let end = NSMaxRange((self.string as NSString).range(of: "Review this"))
            self.select(NSRange(location: end, length: 0))
            self.type("X")
            let added = self.storage.attribute(.pdComments, at: end, effectiveRange: nil)
            self.command(#selector(NSResponder.deleteBackward(_:)))
            return added == nil && self.string.hasSuffix("Review this sentence")
        }
        step("replying adds to the thread") {
            guard let id = self.editor.document?.comments.last?.id else { return false }
            self.editor.comments.model.replyText = "Fixed"
            self.editor.comments.reply(to: id)
            return self.editor.document?.comments.last?.replies.map(\.text) == ["Fixed"] && self.editor.comments.model.replyText.isEmpty
        }
        step("resolving hides the comment") {
            guard let id = self.editor.document?.comments.last?.id else { return false }
            self.editor.comments.setResolved(id, true)
            return self.editor.document?.comments.last?.resolved == true
                && !self.editor.layoutManager.highlightedComments.contains(id) && self.editor.comments.model.activeID == nil
        }
        step("undo re-opens the comment") {
            self.editor.undoManager?.undo()
            guard let thread = self.editor.document?.comments.last else { return false }
            return !thread.resolved && thread.replies.count == 1 && self.editor.layoutManager.highlightedComments.contains(thread.id)
        }
        step("comments are saved in the Word file") {
            guard let document = self.editor.document,
                  let data = try? document.data(ofType: DocumentFormat.docx.typeIdentifier),
                  let content = try? DocumentIO.read(data, format: .docx), let thread = content.comments.first,
                  let range = CommentAnchors.ranges(in: content.text)[thread.id] else { return false }
            return content.comments.count == 1 && thread.text == "Check the wording" && thread.replies.map(\.text) == ["Fixed"]
                && (content.text.string as NSString).substring(with: range) == "Review this"
        }
        step("deleting a thread hides it") {
            guard let id = self.editor.document?.comments.last?.id else { return false }
            self.editor.comments.remove(id)
            return self.editor.document?.comments.isEmpty == true && !self.editor.layoutManager.highlightedComments.contains(id)
        }
        step("undo brings the deleted thread back") {
            self.editor.undoManager?.undo()
            guard let id = self.editor.document?.comments.last?.id else { return false }
            return self.editor.layoutManager.highlightedComments.contains(id)
        }
        step("copied text leaves its comments behind") {
            let range = (self.string as NSString).range(of: "Review this")
            let copy = self.storage.attributedSubstring(from: range)
            self.select(NSRange(location: self.storage.length, length: 0))
            _ = self.editor.insertPasted(copy, in: self.view)
            let pasted = self.storage.attribute(.pdComments, at: self.storage.length - 1, effectiveRange: nil)
            return pasted == nil && CommentAnchors.ranges(in: self.storage).count == 1
        }
        step("suggesting mode turns typing into a suggestion") {
            self.select(NSRange(location: self.storage.length, length: 0))
            self.command(#selector(NSResponder.insertNewline(_:)))
            self.type("Alpha beta gamma")
            self.editor.setMode(.suggesting)
            self.type(" delta")
            let summaries = Suggestions.summaries(in: self.storage)
            return self.string.hasSuffix("Alpha beta gamma delta") && summaries.count == 1 && summaries.first?.inserted == " delta"
        }
        step("Backspace over suggested text just removes it") {
            self.command(#selector(NSResponder.deleteBackward(_:)))
            return self.string.hasSuffix("gamma delt") && Suggestions.summaries(in: self.storage).first?.inserted == " delt"
        }
        step("deleting existing text strikes it through") {
            let gamma = (self.string as NSString).range(of: "gamma", options: .backwards)
            self.select(NSRange(location: NSMaxRange(gamma), length: 0))
            for _ in 0..<2 { self.command(#selector(NSResponder.deleteBackward(_:))) }
            let summaries = Suggestions.summaries(in: self.storage)
            print("SELFTEST INFO: suggestions \(summaries.map { "+\($0.inserted) -\($0.deleted)" })")
            return self.string.hasSuffix("Alpha beta gamma delt") && summaries.contains { $0.deleted == "ma" && $0.inserted.isEmpty }
                && self.view.selectedRange().location == NSMaxRange(gamma) - 2
        }
        step("typing over a selection suggests a replacement") {
            let beta = (self.string as NSString).range(of: "beta", options: .backwards)
            self.select(beta)
            self.type("BETA")
            return Suggestions.summaries(in: self.storage).contains { $0.deleted == "beta" && $0.inserted == "BETA" }
        }
        step("accepting a suggestion applies it") {
            guard let replacement = Suggestions.summaries(in: self.storage).first(where: { $0.inserted == "BETA" }) else { return false }
            self.editor.comments.resolveSuggestion(replacement.id, accept: true)
            return self.string.contains("Alpha BETA gam") && !Suggestions.summaries(in: self.storage).contains { $0.id == replacement.id }
        }
        step("rejecting the rest restores the original text") {
            self.editor.resolveSuggestions(nil, accept: false)
            return !self.editor.hasSuggestions && self.string.hasSuffix("Alpha BETA gamma")
        }
        step("undo brings the suggestions back") {
            self.editor.undoManager?.undo()
            return Suggestions.summaries(in: self.storage).map { "+\($0.inserted) -\($0.deleted)" } == ["+ -ma", "+ delt -"]
        }
        step("suggestions are saved in the Word file") {
            guard let data = try? self.editor.document?.data(ofType: DocumentFormat.docx.typeIdentifier),
                  let content = try? DocumentIO.read(data, format: .docx) else { return false }
            self.editor.setMode(.editing)
            let shapes = Suggestions.summaries(in: content.text).map { "+\($0.inserted) -\($0.deleted)" }
            print("SELFTEST INFO: saved suggestions \(shapes) tail \(content.text.string.suffix(24).debugDescription)")
            return shapes == ["+ -ma", "+ delt -"] && content.text.string.hasSuffix("Alpha BETA gamma delt")
        }
        step("undo history unwinds everything") {
            var count = 0
            while self.editor.undoManager?.canUndo == true, count < 500 {
                self.editor.undoManager?.undo()
                count += 1
            }
            return self.string.isEmpty && self.editor.document?.comments.isEmpty == true
        }
    }
}
#endif
