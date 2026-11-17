import AppKit
import SwiftUI

/// The floating find (and replace) card at the top right of the document.
struct FindBarView: View {
    @Bindable var state: FindState
    let controller: FindController

    private enum Field { case find, replace }
    @FocusState private var focus: Field?

    var body: some View {
        if state.isVisible {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    TextField("Find in document", text: $state.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($focus, equals: .find)
                        .onSubmit { NSEvent.modifierFlags.contains(.shift) ? controller.previous() : controller.next() }
                        .frame(minWidth: 150)
                    Text(state.status)
                        .font(.system(size: 12))
                        .foregroundStyle(state.message == nil ? Theme.secondaryText : Color.red)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                    ToolbarIconButton(symbol: "chevron.up", help: "Previous (⇧⌘G)", isEnabled: state.matchCount > 0) { controller.previous() }
                    ToolbarIconButton(symbol: "chevron.down", help: "Next (⌘G)", isEnabled: state.matchCount > 0) { controller.next() }
                    ToolbarIconButton(symbol: "ellipsis", help: "Find and replace (⇧⌘H)", isOn: state.showsReplace) {
                        state.showsReplace.toggle()
                        focus = state.showsReplace ? .replace : .find
                    }
                    ToolbarIconButton(symbol: "xmark", help: "Close (Esc)") { controller.close() }
                }
                if state.showsReplace {
                    HStack(spacing: 6) {
                        TextField("Replace with", text: $state.replacement)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                            .focused($focus, equals: .replace)
                            .onSubmit { controller.replaceCurrent() }
                        Button("Replace") { controller.replaceCurrent() }
                            .disabled(state.matchCount == 0)
                        Button("Replace all") { controller.replaceAll() }
                            .disabled(state.matchCount == 0)
                    }
                    HStack(spacing: 14) {
                        Toggle("Match case", isOn: $state.matchCase)
                        Toggle("Regular expressions", isOn: $state.useRegex)
                        Toggle("Ignore diacritics", isOn: $state.ignoreDiacritics)
                    }
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: state.showsReplace ? 470 : 400, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white).shadow(color: .black.opacity(0.22), radius: 6, y: 2))
            .padding(6)
            .onChange(of: state.query) { _, _ in controller.search() }
            .onChange(of: state.matchCase) { _, _ in controller.search() }
            .onChange(of: state.useRegex) { _, _ in controller.search() }
            .onChange(of: state.ignoreDiacritics) { _, _ in controller.search() }
            .onChange(of: state.focusRequest) { _, _ in focus = .find }
            .onAppear { focus = .find }
            .onExitCommand { controller.close() }
        }
    }
}
