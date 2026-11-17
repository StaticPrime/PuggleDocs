import AppKit
import PuggleDocsKit
import SwiftUI

struct DialogFrame<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 20))
            content()
        }
        .padding(24)
        .frame(minWidth: 360)
    }
}

struct CustomSpacingView: View {
    @State var lineSpacing: Double
    @State var before: Double
    @State var after: Double
    let apply: (CGFloat, CGFloat, CGFloat) -> Void
    let cancel: () -> Void

    var body: some View {
        DialogFrame(title: "Custom spacing") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Line spacing").font(.system(size: 13, weight: .semibold))
                TextField("", value: $lineSpacing, format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder).frame(width: 110)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Paragraph spacing").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 18) {
                    labeledField("Before", value: $before)
                    labeledField("After", value: $after)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Apply") { apply(CGFloat(max(0.5, min(lineSpacing, 10))), CGFloat(max(0, before)), CGFloat(max(0, after))) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func labeledField(_ label: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            HStack(spacing: 4) {
                TextField("", value: value, format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.roundedBorder).frame(width: 70)
                Text("pt").foregroundStyle(Theme.secondaryText)
            }
        }
    }
}

struct WordCountView: View {
    let document: EditorController.Statistics
    let selection: EditorController.Statistics?
    @State var showsWhileTyping: Bool
    let setShowsWhileTyping: (Bool) -> Void
    let done: () -> Void

    var body: some View {
        DialogFrame(title: "Word count") {
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                row("Pages", nil, document.pages)
                Divider()
                row("Words", selection?.words, document.words)
                Divider()
                row("Characters", selection?.characters, document.characters)
                Divider()
                row("Characters excluding spaces", selection?.charactersExcludingSpaces, document.charactersExcludingSpaces)
            }
            HStack {
                Toggle("Display word count while typing", isOn: $showsWhileTyping)
                    .onChange(of: showsWhileTyping) { _, value in setShowsWhileTyping(value) }
                Spacer()
                Button("OK", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 420)
    }

    @ViewBuilder
    private func row(_ label: String, _ selected: Int?, _ total: Int) -> some View {
        GridRow {
            Text(label).foregroundStyle(Theme.secondaryText)
            Text(selected.map { "\($0.formatted()) of \(total.formatted())" } ?? total.formatted())
                .gridColumnAlignment(.trailing)
                .monospacedDigit()
        }
    }
}

struct MoreFontsView: View {
    let choose: (String?) -> Void
    @State private var query = ""
    @State private var selection: String?
    private let families = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }

    private var filtered: [String] {
        query.isEmpty ? families : families.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        DialogFrame(title: "Fonts") {
            TextField("Search fonts", text: $query).textFieldStyle(.roundedBorder)
            List(filtered, id: \.self, selection: $selection) { family in
                Text(family).font(.custom(family, size: 15)).tag(family)
            }
            .frame(width: 380, height: 340)
            HStack {
                Spacer()
                Button("Cancel") { choose(nil) }.keyboardShortcut(.cancelAction)
                Button("OK") { choose(selection) }.keyboardShortcut(.defaultAction).disabled(selection == nil)
            }
        }
    }
}

struct KeyboardShortcutsView: View {
    let done: () -> Void

    private let groups: [(String, [(String, String)])] = [
        ("Text formatting", [("Bold", "⌘B"), ("Italic", "⌘I"), ("Underline", "⌘U"), ("Strikethrough", "⇧⌘X"),
                             ("Superscript", "⌘."), ("Subscript", "⌘,"), ("Increase font size", "⇧⌘."),
                             ("Decrease font size", "⇧⌘,"), ("Clear formatting", "⌘\\")]),
        ("Paragraph formatting", [("Normal text", "⌥⌘0"), ("Heading 1 – 6", "⌥⌘1 – 6"), ("Left / center / right", "⇧⌘L / E / R"),
                                  ("Justify", "⇧⌘J"), ("Numbered list", "⇧⌘7"), ("Bulleted list", "⇧⌘8"), ("Checklist", "⇧⌘9"),
                                  ("Increase / decrease indent", "⌘] / ⌘[")]),
        ("Document", [("Insert link", "⌘K"), ("Page break", "⌘↩"), ("Find", "⌘F"), ("Find and replace", "⇧⌘H"),
                      ("Find next / previous", "⌘G / ⇧⌘G"), ("Word count", "⇧⌘C"), ("Show outline", "⌥⌘A"),
                      ("Paste without formatting", "⇧⌘V"), ("Print", "⌘P"), ("Zoom in / out", "⌘= / ⌘−")]),
        ("Comments", [("Insert comment", "⌥⌘M"), ("Post comment or reply", "⌘↩"), ("New line in a comment", "↩"),
                      ("Cancel a comment", "Esc"), ("Comment history", "⇧⌥⌘A")]),
    ]

    var body: some View {
        DialogFrame(title: "Keyboard shortcuts") {
            // Two groups to a row.
            VStack(alignment: .leading, spacing: 22) {
                ForEach(Array(stride(from: 0, to: groups.count, by: 2)), id: \.self) { row in
                    HStack(alignment: .top, spacing: 32) {
                        ForEach(row..<min(row + 2, groups.count), id: \.self) { index in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(groups[index].0).font(.system(size: 13, weight: .semibold))
                                ForEach(groups[index].1, id: \.0) { item in
                                    HStack {
                                        Text(item.0).foregroundStyle(Theme.secondaryText)
                                        Spacer(minLength: 16)
                                        Text(item.1).monospaced()
                                    }
                                }
                            }
                            .frame(width: 260, alignment: .topLeading)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Format ▸ Image options: exact size, aspect lock and reset.
struct ImageOptionsView: View {
    @State var width: Double
    @State var height: Double
    let naturalSize: NSSize
    let maximum: NSSize
    let apply: (NSSize) -> Void
    let cancel: () -> Void
    @State private var locked = true

    private let usesMetric = Locale.current.measurementSystem != .us
    private var unit: Double { usesMetric ? 72 / 2.54 : 72 }
    private var unitName: String { usesMetric ? "cm" : "in" }
    private var ratio: Double { naturalSize.height > 0 ? Double(naturalSize.width / naturalSize.height) : 1 }

    var body: some View {
        DialogFrame(title: "Image options") {
            Text("Size").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 14) {
                field("Width", value: Binding(get: { width / unit }, set: { value in
                    width = max(16, value * unit)
                    if locked { height = width / ratio }
                }))
                field("Height", value: Binding(get: { height / unit }, set: { value in
                    height = max(16, value * unit)
                    if locked { width = height * ratio }
                }))
            }
            Toggle("Lock aspect ratio", isOn: $locked).toggleStyle(.checkbox)
            HStack {
                Button("Reset size") {
                    var size = naturalSize
                    if size.width > maximum.width { size = NSSize(width: maximum.width, height: size.height * maximum.width / size.width) }
                    width = Double(size.width)
                    height = Double(size.height)
                }
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Apply") {
                    apply(NSSize(width: min(width, Double(maximum.width)).rounded(), height: min(height, Double(maximum.height)).rounded()))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func field(_ label: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            HStack(spacing: 4) {
                TextField("", value: value, format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                Text(unitName).foregroundStyle(Theme.secondaryText)
            }
        }
    }
}
