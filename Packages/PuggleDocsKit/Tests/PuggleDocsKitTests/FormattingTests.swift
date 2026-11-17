import AppKit
import Testing
@testable import PuggleDocsKit

@MainActor
struct ListMarkerTests {
    @Test func numberFormats() {
        #expect(ListNumberFormat.lowerAlpha.format(1) == "a")
        #expect(ListNumberFormat.lowerAlpha.format(27) == "aa")
        #expect(ListNumberFormat.upperRoman.format(14) == "XIV")
        #expect(ListNumberFormat.lowerRoman.format(1999) == "mcmxcix")
        #expect(ListNumberFormat.decimalZero.format(7) == "07")
    }

    @Test func presetMarkersCycleThroughLevels() {
        let preset = ListPreset.decimalAlphaRoman
        #expect(preset.marker(level: 0, counters: [3]) == "3.")
        #expect(preset.marker(level: 1, counters: [3, 2]) == "b.")
        #expect(preset.marker(level: 2, counters: [3, 2, 4]) == "iv.")
        #expect(preset.marker(level: 3, counters: [1, 1, 1, 5]) == "5.")
        #expect(ListPreset.decimalOutline.marker(level: 2, counters: [2, 3, 1]) == "2.3.1.")
        #expect(ListPreset.discCircleSquare.marker(level: 1, counters: [1, 1]) == "○")
    }

    @Test func numberingContinuesAcrossInterruptionsAndResetsDeeperLevels() {
        let list = ListItem(listID: "A", preset: .decimalAlphaRoman)
        let text = NSMutableAttributedString()
        func add(_ string: String, _ item: ListItem?) {
            var attributes = DocumentDefaults.typingAttributes
            attributes[.pdListItem] = item
            text.append(NSAttributedString(string: string + "\n", attributes: attributes))
        }
        add("one", list)
        add("one-a", list.with(level: 1))
        add("one-b", list.with(level: 1))
        add("plain", nil)
        add("two", list)
        add("two-a", list.with(level: 1))
        let markers = ListNumbering.entries(in: text).map(\.marker)
        #expect(markers == ["1.", "a.", "b.", "2.", "a."])
    }
}

@MainActor
struct ParagraphFormattingTests {
    @Test func paragraphRangesCoverSelection() {
        let string = "abc\ndef\nghi" as NSString
        let ranges = ParagraphFormatting.paragraphRanges(in: string, covering: [NSRange(location: 2, length: 3)])
        #expect(ranges == [NSRange(location: 0, length: 4), NSRange(location: 4, length: 4)])
        let caretAtEnd = ParagraphFormatting.paragraphRanges(in: "abc\n" as NSString, covering: [NSRange(location: 4, length: 0)])
        #expect(caretAtEnd == [NSRange(location: 4, length: 0)])
        let empty = ParagraphFormatting.paragraphRanges(in: "" as NSString, covering: [NSRange(location: 0, length: 0)])
        #expect(empty == [NSRange(location: 0, length: 0)])
    }

    @Test func toggleListAddsThenRemoves() {
        let text = NSMutableAttributedString(string: "one\ntwo\n", attributes: DocumentDefaults.typingAttributes)
        var typing = DocumentDefaults.typingAttributes
        let ranges = ParagraphFormatting.paragraphRanges(in: text.string as NSString, covering: [NSRange(location: 0, length: 6)])
        ListFormatting.toggle(kind: .bulleted, preset: nil, in: text, paragraphRanges: ranges, typing: &typing)
        let first = text.attribute(.pdListItem, at: 0, effectiveRange: nil) as? ListItem
        let second = text.attribute(.pdListItem, at: 5, effectiveRange: nil) as? ListItem
        #expect(first?.kind == .bulleted)
        #expect(first?.listID == second?.listID)
        #expect((text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.headIndent == 36)
        ListFormatting.toggle(kind: .bulleted, preset: nil, in: text, paragraphRanges: ranges, typing: &typing)
        #expect(text.attribute(.pdListItem, at: 0, effectiveRange: nil) == nil)
    }

    @Test func indentChangesListLevel() {
        let item = ListItem(preset: .discCircleSquare)
        var attributes = DocumentDefaults.typingAttributes
        attributes[.pdListItem] = item
        let indented = ParagraphFormatting.apply(ParagraphFormatting.indent(increase: true, maximum: 400), to: attributes)
        #expect((indented[.pdListItem] as? ListItem)?.level == 1)
        #expect((indented[.paragraphStyle] as? NSParagraphStyle)?.headIndent == 72)
    }

    @Test func namedStyleKeepsRunDeviations() {
        var attributes = DocumentDefaults.typingAttributes
        FontResolver.apply(FontSpec(family: "Arial", size: 11, bold: true), to: &attributes)
        let text = NSMutableAttributedString(string: "Title\n", attributes: attributes)
        StyleFormatting.apply(.heading1, to: text, paragraphRanges: [NSRange(location: 0, length: 6)])
        let spec = FontResolver.spec(from: text.attributes(at: 0, effectiveRange: nil))
        #expect(spec.size == 20)
        #expect(spec.bold)
        #expect(text.attribute(.pdNamedStyle, at: 0, effectiveRange: nil) as? String == "heading1")
    }
}

@MainActor
struct ArchiveTests {
    @Test func archiveKeepsCustomAttributes() throws {
        let original = sampleDocument()
        let data = try #require(AttributedArchive.archive(original))
        let restored = try #require(AttributedArchive.unarchive(data))
        #expect(restored.string == original.string)
        #expect(ListNumbering.entries(in: restored).map(\.marker) == ["1.", "a.", "2."])
        #expect(restored.attribute(.pdNamedStyle, at: 0, effectiveRange: nil) as? String == "title")
    }
}
