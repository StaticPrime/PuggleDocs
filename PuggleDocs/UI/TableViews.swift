import AppKit
import PuggleDocsKit
import SwiftUI

/// Insert ▸ Table: hover to choose the size, click to insert.
struct TablePickerView: View {
    let pick: (_ rows: Int, _ columns: Int) -> Void
    @State private var rows = 1
    @State private var columns = 1
    private let maxRows = 8
    private let maxColumns = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                ForEach(0..<maxRows, id: \.self) { row in
                    GridRow {
                        ForEach(0..<maxColumns, id: \.self) { column in
                            let selected = row < rows && column < columns
                            RoundedRectangle(cornerRadius: 2)
                                .fill(selected ? Theme.activeFill : Color.white)
                                .overlay(RoundedRectangle(cornerRadius: 2).stroke(selected ? Theme.accent : Color.black.opacity(0.25), lineWidth: 1))
                                .frame(width: 17, height: 17)
                                .contentShape(Rectangle())
                                .onHover { inside in
                                    if inside { rows = row + 1; columns = column + 1 }
                                }
                                .onTapGesture { pick(row + 1, column + 1) }
                        }
                    }
                }
            }
            Text("\(columns) x \(rows)")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .monospacedDigit()
        }
        .padding(10)
    }
}

/// Format ▸ Table ▸ Table properties.
struct TablePropertiesView: View {
    @State var borderWidth: Double
    @State var borderColorHex: String
    @State var cellBackgroundHex: String?
    let apply: (_ borderWidth: CGFloat, _ borderColor: NSColor, _ cellBackground: NSColor?, _ distribute: Bool) -> Void
    let cancel: () -> Void
    @State private var distribute = false
    @State private var showingBorderColors = false
    @State private var showingCellColors = false

    private let widths: [Double] = [0, 0.5, 1, 1.5, 2, 3, 4, 6]

    var body: some View {
        DialogFrame(title: "Table properties") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Text("Table border").foregroundStyle(Theme.secondaryText)
                    HStack(spacing: 10) {
                        Picker("", selection: $borderWidth) {
                            ForEach(widths, id: \.self) { width in Text(width == 0 ? "None" : "\(width.formatted()) pt").tag(width) }
                        }
                        .labelsHidden()
                        .frame(width: 100)
                        swatch(hex: borderColorHex, showing: $showingBorderColors) { borderColorHex = $0 ?? "000000" }
                    }
                }
                GridRow {
                    Text("Cell background").foregroundStyle(Theme.secondaryText)
                    swatch(hex: cellBackgroundHex ?? "FFFFFF", showing: $showingCellColors) { hex in
                        cellBackgroundHex = hex == "FFFFFF" ? nil : hex
                    }
                }
                GridRow {
                    Text("Columns").foregroundStyle(Theme.secondaryText)
                    Toggle("Distribute evenly", isOn: $distribute).toggleStyle(.checkbox)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("OK") {
                    apply(CGFloat(borderWidth), NSColor(hex: borderColorHex) ?? .black, cellBackgroundHex.flatMap(NSColor.init(hex:)), distribute)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func swatch(hex: String, showing: Binding<Bool>, pick: @escaping (String?) -> Void) -> some View {
        Button {
            showing.wrappedValue = true
        } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: NSColor(hex: hex) ?? .white))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.25), lineWidth: 0.5))
                    .frame(width: 26, height: 18)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .padding(4)
            .hoverBackground()
        }
        .buttonStyle(.plain)
        .popover(isPresented: showing, arrowEdge: .bottom) {
            ColorPaletteView(isHighlight: false, selectedHex: hex) { color in
                pick(color?.hexString)
                showing.wrappedValue = false
            } custom: { showing.wrappedValue = false }
        }
    }
}
