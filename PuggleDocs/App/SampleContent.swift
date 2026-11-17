#if DEBUG
import AppKit
import PuggleDocsKit

/// Sample text used by the `-PDSampleDocument YES` launch argument to check rendering.
enum SampleContent {
    static func make() -> NSAttributedString {
        let text = NSMutableAttributedString()
        func add(_ string: String, _ style: NamedStyle = .normal, _ change: (inout [NSAttributedString.Key: Any]) -> Void = { _ in }) {
            var attributes = style.attributes()
            change(&attributes)
            text.append(NSAttributedString(string: string, attributes: attributes))
        }
        func list(_ item: ListItem) -> (inout [NSAttributedString.Key: Any]) -> Void {
            { $0 = ParagraphFormatting.apply(ParagraphFormatting.setList(item), to: $0) }
        }

        add("Project Puggle\n", .title)
        add("A lightweight word processor for the Mac\n", .subtitle)
        add("Overview\n", .heading1)
        add("PuggleDocs keeps the familiar layout: ")
        add("bold", .normal, CharacterFormatting.setBold(true))
        add(", ")
        add("italic", .normal, CharacterFormatting.setItalic(true))
        add(", ")
        add("underlined", .normal, CharacterFormatting.setUnderline(true))
        add(", ")
        add("colored", .normal) { $0[.foregroundColor] = NSColor(hex: "CC0000") }
        add(" and ")
        add("highlighted", .normal, CharacterFormatting.setHighlight(NSColor(hex: "FFF2CC")))
        add(" text all work, along with links like ")
        add("example.com", .normal) { $0[.link] = URL(string: "https://example.com")! }
        add(".\n")
        add("Goals\n", .heading2)
        let bullets = ListItem(listID: "goals", preset: .discCircleSquare)
        add("Open and save Word documents\n", .normal, list(bullets))
        add("Rich Text and plain text too\n", .normal, list(bullets.with(level: 1)))
        add("Look and feel familiar from day one\n", .normal, list(bullets))
        add("Milestones\n", .heading2)
        let numbers = ListItem(listID: "steps", preset: .decimalAlphaRoman)
        add("Editor and pages\n", .normal, list(numbers))
        add("Formatting toolbar\n", .normal, list(numbers))
        add("Lists and styles\n", .normal, list(numbers.with(level: 1)))
        add("File formats\n", .normal, list(numbers))
        let checks = ListItem(listID: "todo", preset: .checkbox)
        add("Draw the app icon\n", .normal) { attributes in
            attributes = ParagraphFormatting.apply(ParagraphFormatting.setList(checks.with(checked: true)), to: attributes)
            CharacterFormatting.setStrikethrough(true)(&attributes)
        }
        add("Ship phase one\n", .normal, list(checks))
        add("Centered closing line\n", .normal) { attributes in
            attributes = ParagraphFormatting.apply(ParagraphFormatting.setAlignment(.center), to: attributes)
        }
        add("Before the page break\u{0C}\n")
        add("Second page\n", .heading1)
        add("This paragraph starts on page two.")
        return text
    }
}
#endif
