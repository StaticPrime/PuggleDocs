import AppKit
import PuggleDocsKit
import SwiftUI

enum LinkAddress {
    /// Turns "example.com" into https://example.com and "me@example.com" into a mailto: link.
    static func normalized(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        if trimmed.hasPrefix("#") { return URL(string: trimmed) }
        if let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty, trimmed.contains(":") {
            if ["http", "https", "mailto", "ftp", "tel", "file"].contains(scheme.lowercased()) || trimmed.contains("://") { return url }
        }
        if trimmed.contains("@"), !trimmed.contains("/") { return URL(string: "mailto:" + trimmed) }
        return URL(string: "https://" + trimmed)
    }

    static func display(_ url: URL) -> String {
        var text = url.absoluteString
        for prefix in ["https://", "http://", "mailto:"] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }
}

/// Text and address fields for inserting or editing a link.
struct LinkEditorView: View {
    @State var text: String
    @State var address: String
    let apply: (String, URL) -> Void

    private enum Field { case text, address }
    @FocusState private var focus: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "textformat").foregroundStyle(Theme.secondaryText).frame(width: 18)
                TextField("Text", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .text)
            }
            HStack(spacing: 8) {
                Image(systemName: "link").foregroundStyle(Theme.secondaryText).frame(width: 18)
                TextField("Paste or type a link", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .address)
                    .onSubmit(submit)
                Button("Apply", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(LinkAddress.normalized(address) == nil)
            }
        }
        .padding(12)
        .frame(width: 380)
        .onAppear { focus = .address }
    }

    private func submit() {
        guard let url = LinkAddress.normalized(address) else { return }
        apply(text, url)
    }
}

/// The chip shown when clicking a link: open, copy, edit or remove.
struct LinkPreviewView: View {
    let url: URL
    let open: () -> Void
    let copy: () -> Void
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: url.scheme == "mailto" ? "envelope" : "globe")
                .foregroundStyle(Theme.secondaryText)
            Button(action: open) {
                Text(LinkAddress.display(url))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.accent)
                    .underline()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 240, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help(url.absoluteString)
            Divider().frame(height: 18)
            ToolbarIconButton(symbol: "doc.on.doc", help: "Copy link", action: copy)
            ToolbarIconButton(symbol: "pencil", help: "Edit link", action: edit)
            ToolbarIconButton(symbol: "xmark", help: "Remove link", action: remove)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

extension DocumentWindowController {
    /// The link range touching `range`, if the text there is a link.
    func linkRange(around range: NSRange) -> (NSRange, URL)? {
        let storage = editor.textStorage
        let index = range.length > 0 ? range.location : max(0, min(range.location, storage.length) - (range.location == storage.length ? 1 : 0))
        guard index < storage.length, let value = storage.attribute(.link, at: index, effectiveRange: nil) else { return nil }
        let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
        guard let url else { return nil }
        var effective = NSRange()
        _ = storage.attribute(.link, at: index, longestEffectiveRange: &effective, in: NSRange(location: 0, length: storage.length))
        return (effective, url)
    }

    func showLinkEditor() {
        guard state.isEditable else { return }
        editor.focus()
        var range = editor.activeTextView.selectedRange()
        var address = ""
        if let (linkRange, url) = linkRange(around: range), range.length == 0 || NSIntersectionRange(linkRange, range).length > 0 {
            range = linkRange
            address = url.absoluteString
        }
        let text = (editor.textStorage.string as NSString).substring(with: range)
        presentPopover(at: range) { close in
            LinkEditorView(text: text, address: address) { newText, url in
                close()
                self.editor.applyLink(text: newText, url: url, range: range)
            }
        }
    }

    func showLinkPreview(at index: Int) {
        guard let (range, url) = linkRange(around: NSRange(location: index, length: 1)) else { return }
        presentPopover(at: range) { close in
            LinkPreviewView(url: url) {
                close()
                NSWorkspace.shared.open(url)
            } copy: {
                close()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            } edit: {
                close()
                self.editor.activeTextView.setSelectedRange(range)
                self.showLinkEditor()
            } remove: {
                close()
                self.editor.removeLink(in: range)
            }
        }
    }

    func presentPopover<Content: View>(at range: NSRange, content: (_ close: @escaping () -> Void) -> Content) {
        guard let (textView, rect) = editor.rect(for: range) else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.appearance = NSAppearance(named: .aqua)
        let close = { [weak popover] in popover?.performClose(nil) ?? () }
        popover.contentViewController = NSHostingController(rootView: content(close))
        popover.show(relativeTo: rect.insetBy(dx: 0, dy: -2), of: textView, preferredEdge: .maxY)
    }
}
