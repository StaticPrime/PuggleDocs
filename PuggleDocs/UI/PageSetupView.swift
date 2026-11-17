import AppKit
import PuggleDocsKit
import SwiftUI

/// The page setup used for new documents: the user's saved default, or Letter/A4 by region.
enum PageSetupDefaults {
    private static let key = "PDDefaultPageSetup"

    static var current: PageSetup {
        if let plist = UserDefaults.standard.dictionary(forKey: key), let setup = PageSetup(propertyList: plist) {
            return setup
        }
        return .localeDefault
    }

    static func save(_ setup: PageSetup) {
        UserDefaults.standard.set(setup.propertyList, forKey: key)
    }
}

/// File ▸ Page setup: orientation, paper size, page color and margins.
struct PageSetupView: View {
    @State var setup: PageSetup
    let apply: (PageSetup) -> Void
    let setDefault: (PageSetup) -> Void
    let cancel: () -> Void

    @State private var showingColors = false
    @State private var savedAsDefault = false

    private let usesMetric = Locale.current.measurementSystem != .us
    private var unitPoints: CGFloat { usesMetric ? 72 / 2.54 : 72 }
    private var unitName: String { usesMetric ? "centimeters" : "inches" }

    private var paperChoices: [PageSetup.PaperSize] {
        if setup.namedPaperSize != nil { return PageSetup.paperSizes }
        let custom = PageSetup.PaperSize(name: "Custom (\(format(setup.paperSize.width)) x \(format(setup.paperSize.height)))", size: setup.paperSize)
        return PageSetup.paperSizes + [custom]
    }

    private var selectedPaper: Binding<String> {
        Binding {
            setup.namedPaperSize?.name ?? paperChoices.last!.name
        } set: { name in
            if let paper = paperChoices.first(where: { $0.name == name }) { setup.paperSize = paper.size }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Page setup").font(.system(size: 20))
            HStack(alignment: .top, spacing: 36) {
                VStack(alignment: .leading, spacing: 16) {
                    section("Orientation") {
                        Picker("", selection: $setup.orientation) {
                            Text("Portrait").tag(PageSetup.Orientation.portrait)
                            Text("Landscape").tag(PageSetup.Orientation.landscape)
                        }
                        .pickerStyle(.radioGroup)
                        .horizontalRadioGroupLayout()
                        .labelsHidden()
                    }
                    section("Paper size") {
                        Picker("", selection: selectedPaper) {
                            ForEach(paperChoices) { paper in Text(paper.name).tag(paper.name) }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }
                    section("Page color") {
                        Button {
                            showingColors = true
                        } label: {
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color(nsColor: setup.pageColor))
                                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.25), lineWidth: 0.5))
                                    .frame(width: 26, height: 18)
                                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                            }
                            .padding(4)
                            .hoverBackground()
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showingColors, arrowEdge: .bottom) {
                            ColorPaletteView(isHighlight: false, selectedHex: setup.pageColorHex ?? "FFFFFF") { color in
                                let hex = color?.hexString
                                setup.pageColorHex = (hex == nil || hex == "FFFFFF") ? nil : hex
                                showingColors = false
                            } custom: {
                                showingColors = false
                            }
                        }
                    }
                }
                section("Margins (\(unitName))") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        marginRow("Top", \.top)
                        marginRow("Bottom", \.bottom)
                        marginRow("Left", \.left)
                        marginRow("Right", \.right)
                    }
                }
            }
            if !setup.hasValidMargins {
                Label("The margins leave too little room for text.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.red)
            }
            HStack {
                Button(savedAsDefault ? "Saved as default" : "Set as default") {
                    setDefault(setup)
                    savedAsDefault = true
                }
                .disabled(!setup.hasValidMargins || savedAsDefault)
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("OK") { apply(setup) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!setup.hasValidMargins)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onChange(of: setup) { _, _ in savedAsDefault = false }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content()
        }
    }

    private func marginRow(_ label: String, _ keyPath: WritableKeyPath<PageMargins, CGFloat>) -> some View {
        GridRow {
            Text(label).foregroundStyle(Theme.secondaryText)
            TextField("", value: Binding<Double> {
                Double(setup.margins[keyPath: keyPath] / unitPoints)
            } set: { value in
                setup.margins[keyPath: keyPath] = max(0, CGFloat(value) * unitPoints)
            }, format: .number.precision(.fractionLength(0...2)))
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)
        }
    }

    private func format(_ points: CGFloat) -> String {
        let value = points / unitPoints
        return String(format: "%.2f", value) + (usesMetric ? " cm" : "\"")
    }
}
