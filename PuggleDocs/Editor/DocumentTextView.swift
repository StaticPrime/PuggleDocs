import AppKit
import PuggleDocsKit

extension NSPasteboard.PasteboardType {
    static let puggleDocsRichText = NSPasteboard.PasteboardType(AttributedArchive.pasteboardTypeIdentifier)
}

/// The text view on each page. All pages share one layout manager, so they share selection,
/// typing attributes and undo; this subclass adds the word-processor behaviors on top.
final class DocumentTextView: NSTextView {
    weak var editor: EditorController?

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string
        if text == " ", let editor, editor.handleAutoListTrigger(in: self) { return }
        // Committing composed text (accents, input methods) replaces it rather than striking it through.
        editor?.composingRange = hasMarkedText() ? markedRange() : nil
        defer { editor?.composingRange = nil }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        editor?.composingDepth += 1
        defer { editor?.composingDepth -= 1 }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func mouseDown(with event: NSEvent) {
        if let editor, editor.handleMarkerClick(event, in: self) { return }
        if let editor, editor.handleImageClick(event, in: self) { return }
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        super.mouseDown(with: event)
        editor?.textViewDidFinishMouseSelection(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        editor?.drawTrailingListMarker(in: self)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { editor?.textViewBecameFirstResponder(self) }
        return accepted
    }

    // MARK: Pasteboard

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.puggleDocsRichText] + super.readablePasteboardTypes
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.puggleDocsRichText] + super.writablePasteboardTypes
    }

    private var selectedText: NSAttributedString {
        let result = NSMutableAttributedString()
        guard let storage = textStorage else { return result }
        for value in selectedRanges {
            let range = value.rangeValue
            guard range.length > 0, NSMaxRange(range) <= storage.length else { continue }
            if result.length > 0 { result.append(NSAttributedString(string: "\n")) }
            // Copy what the text says with its suggestions accepted.
            result.append(Suggestions.accepted(storage.attributedSubstring(from: range)))
        }
        return result
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let text = selectedText
        guard text.length > 0 else { return super.writeSelection(to: pboard, type: type) }
        switch type {
        case .puggleDocsRichText:
            guard let data = AttributedArchive.archive(text) else { return false }
            return pboard.setData(data, forType: type)
        case .rtf:
            // Hand other apps real lists and pictures rather than PuggleDocs-only attributes.
            guard let data = RichTextCodec.rtfData(text) else { return false }
            return pboard.setData(data, forType: type)
        case .string:
            return pboard.setString(PlainTextCodec.plainString(from: text), forType: type)
        default:
            return super.writeSelection(to: pboard, type: type)
        }
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        switch type {
        case .puggleDocsRichText:
            guard let data = pboard.data(forType: type), let text = AttributedArchive.unarchive(data) else { return false }
            return editor?.insertPasted(text, in: self) ?? false
        case .rtf:
            guard let data = pboard.data(forType: type), let content = try? RichTextCodec.read(data) else {
                return super.readSelection(from: pboard, type: type)
            }
            return editor?.insertPasted(content.text, in: self) ?? false
        case .rtfd, .html:
            guard let data = pboard.data(forType: type) else { return false }
            let documentType: NSAttributedString.DocumentType = type == .rtf ? .rtf : (type == .rtfd ? .rtfd : .html)
            guard let text = try? NSAttributedString(data: data, options: [.documentType: documentType], documentAttributes: nil) else {
                return super.readSelection(from: pboard, type: type)
            }
            let imported = NSMutableAttributedString(attributedString: text)
            CocoaListBridge.importLists(imported)
            DocumentIO.normalizeImported(imported)
            return editor?.insertPasted(imported, in: self) ?? false
        default:
            return super.readSelection(from: pboard, type: type)
        }
    }
}
