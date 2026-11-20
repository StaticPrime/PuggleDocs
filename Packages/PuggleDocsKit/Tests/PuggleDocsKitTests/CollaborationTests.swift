import AppKit
import Testing
@testable import PuggleDocsKit

/// The same random numbers every run, so a failure can be run again.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Text as a list of characters with attributes, to apply changes to without AppKit.
private struct ModelText: Equatable {
    var characters: [(UInt16, DeltaAttributes)]

    static func == (a: ModelText, b: ModelText) -> Bool {
        a.characters.count == b.characters.count && zip(a.characters, b.characters).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }

    func applying(_ delta: TextDelta) -> ModelText {
        var result: [(UInt16, DeltaAttributes)] = []
        var index = 0
        for op in delta.ops {
            switch op {
            case let .insert(text, attributes):
                for unit in text.units { result.append((unit, attributes)) }
            case let .retain(count, attributes):
                for offset in 0..<count {
                    var character = characters[index + offset]
                    for (key, value) in attributes {
                        if value == .removed { character.1[key] = nil } else { character.1[key] = value }
                    }
                    result.append(character)
                }
                index += count
            case let .delete(count):
                index += count
            }
        }
        result.append(contentsOf: characters[index...])
        return ModelText(characters: result)
    }
}

private func randomAttributes(_ random: inout SeededGenerator) -> DeltaAttributes {
    var attributes: DeltaAttributes = [:]
    if Bool.random(using: &random) { attributes["b"] = .value(Data([UInt8.random(in: 0...2, using: &random)])) }
    if Bool.random(using: &random) { attributes["c"] = .value(Data([UInt8.random(in: 0...2, using: &random)])) }
    return attributes
}

/// A random change to text `length` long.
private func randomDelta(length: Int, _ random: inout SeededGenerator) -> TextDelta {
    var delta = TextDelta()
    var left = length
    for _ in 0..<Int.random(in: 1...5, using: &random) {
        switch Int.random(in: 0..<4, using: &random) {
        case 0:
            let text = (0..<Int.random(in: 1...4, using: &random)).map { _ in UInt16.random(in: 97...122, using: &random) }
            delta.insert(DeltaText(units: text), randomAttributes(&random))
        case 1 where left > 0:
            let count = Int.random(in: 1...min(left, 4), using: &random)
            delta.delete(count)
            left -= count
        case 2 where left > 0:
            let count = Int.random(in: 1...min(left, 5), using: &random)
            var change = randomAttributes(&random)
            if Bool.random(using: &random) { change["b"] = .removed }
            delta.retain(count, change)
            left -= count
        default:
            if left > 0 {
                let count = Int.random(in: 1...min(left, 3), using: &random)
                delta.retain(count)
                left -= count
            }
        }
    }
    return delta
}

private func randomText(_ random: inout SeededGenerator) -> ModelText {
    ModelText(characters: (0..<Int.random(in: 0...12, using: &random)).map { _ in (UInt16.random(in: 65...90, using: &random), randomAttributes(&random)) })
}

@MainActor
struct TextDeltaTests {
    @Test func changesMadeAtTheSameTimeEndTheSame() {
        var random = SeededGenerator(seed: 7)
        for _ in 0..<3_000 {
            let base = randomText(&random)
            let a = randomDelta(length: base.characters.count, &random)
            let b = randomDelta(length: base.characters.count, &random)
            let viaA = base.applying(a).applying(a.transform(b, priority: true))
            let viaB = base.applying(b).applying(b.transform(a, priority: false))
            #expect(viaA == viaB)
            if viaA != viaB { return }
        }
    }

    @Test func composedChangesDoWhatTheyDidInTurn() {
        var random = SeededGenerator(seed: 11)
        for _ in 0..<3_000 {
            let base = randomText(&random)
            let first = randomDelta(length: base.characters.count, &random)
            let middle = base.applying(first)
            let second = randomDelta(length: middle.characters.count, &random)
            #expect(base.applying(first.compose(second)) == middle.applying(second))
        }
    }

    @Test func placesFollowChanges() {
        var delta = TextDelta()
        delta.retain(2)
        delta.insert(DeltaText("xyz"))
        delta.delete(1)
        // "ab|c|de" → "abxyzde"
        #expect(delta.transformPosition(0, priority: false) == 0)
        #expect(delta.transformPosition(2, priority: false) == 5)
        #expect(delta.transformPosition(2, priority: true) == 2)
        #expect(delta.transformPosition(4, priority: false) == 6)
        #expect(delta.positionBefore(6) == 4)
        #expect(delta.positionBefore(3) == 2)
        #expect(delta.positionBefore(1) == 1)
    }

    @Test func encodingKeepsEveryOp() throws {
        var delta = TextDelta()
        delta.retain(3, ["k": .value(Data([1, 2])), "x": .removed])
        delta.insert(DeltaText("héllo 😀"), ["f": .value(Data([9]))])
        delta.delete(4)
        #expect(try TextDelta(encoded: delta.encoded) == delta)
        let change = DocumentChange(body: delta, footer: delta, pageSetup: .a4)
        #expect(try DocumentChange(encoded: change.encoded) == change)
    }
}

@MainActor
struct RecordingTests {
    private func styled(_ string: String) -> NSAttributedString {
        NSAttributedString(string: string, attributes: DocumentDefaults.typingAttributes)
    }

    /// The text's runs as a change inserting them, to compare texts by what travels.
    private func runs(_ text: NSAttributedString, _ coder: SyncAttributeCoder) -> TextDelta { coder.insertion(of: text) }

    @Test func recordedChangesRedoAndUndoEachRound() {
        var random = SeededGenerator(seed: 3)
        let coder = SyncAttributeCoder()
        let storage = RecordingTextStorage(attributedString: styled("The quick brown fox jumps over the lazy dog.\nSecond line."))
        storage.coder = coder
        storage.isRecording = true
        var edits: [RecordedEdit] = []
        storage.onEdit = { edits.append($0) }
        let colors: [NSColor] = [.red, .blue, .black]
        for round in 0..<400 {
            let before = NSAttributedString(attributedString: storage)
            edits = []
            storage.beginEditing()
            for _ in 0..<Int.random(in: 1...3, using: &random) {
                let length = storage.length
                let location = Int.random(in: 0...length, using: &random)
                let span = Int.random(in: 0...min(6, length - location), using: &random)
                let range = NSRange(location: location, length: span)
                switch Int.random(in: 0..<5, using: &random) {
                // Not emoji: AppKit gives those their font later, on every Mac alike, after the round is recorded.
                case 0: storage.replaceCharacters(in: range, with: ["x", "yz", "\n", "é", ""].randomElement(using: &random)!)
                case 1: storage.deleteCharacters(in: range)
                case 2: if span > 0 { storage.addAttribute(.foregroundColor, value: colors.randomElement(using: &random)!, range: range) }
                case 3: if span > 0 { storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 13), range: range) }
                default: storage.insert(NSAttributedString(string: "ab", attributes: [.font: NSFont.systemFont(ofSize: 20)]), at: location)
                }
            }
            storage.endEditing()
            let after = NSAttributedString(attributedString: storage)
            if before.isEqual(to: after) { continue }
            guard let edit = edits.first, edits.count == 1 else {
                // Only attributes that don't travel changed.
                #expect(runs(before, coder) == runs(after, coder))
                continue
            }
            let redone = NSMutableAttributedString(attributedString: before)
            #expect(coder.apply(edit.change, to: redone))
            #expect(runs(redone, coder) == runs(after, coder), "round \(round)")
            let undone = NSMutableAttributedString(attributedString: after)
            #expect(coder.apply(edit.inverse, to: undone))
            #expect(runs(undone, coder) == runs(before, coder), "round \(round)")
            if runs(undone, coder) != runs(before, coder) { return }
        }
    }

    @Test func commentHighlightsStayOnThisMac() {
        let coder = SyncAttributeCoder()
        let storage = RecordingTextStorage(attributedString: styled("Hello there"))
        storage.coder = coder
        storage.isRecording = true
        var edits: [RecordedEdit] = []
        storage.onEdit = { edits.append($0) }
        storage.addAttribute(.pdComments, value: "thread", range: NSRange(location: 0, length: 5))
        #expect(edits.isEmpty)
        storage.replaceCharacters(in: NSRange(location: 5, length: 0), with: "!")
        #expect(edits.count == 1)
        #expect(edits.first?.inserted.first?.text.string == "!")
    }
}

@MainActor
struct AttributeCodingTests {
    @Test func tablesStayWholeOnAnotherMac() {
        let model = TableModel.empty(rows: 2, columns: 2, attributes: DocumentDefaults.typingAttributes)
        let table = NSMutableAttributedString(attributedString: model.attributedString(attributes: DocumentDefaults.typingAttributes))
        let sender = SyncAttributeCoder()
        let receiver = SyncAttributeCoder()
        guard let copy = receiver.text(from: sender.insertion(of: table)) else {
            Issue.record("The table didn't decode")
            return
        }
        let read = TableModel.table(at: 0, in: copy)
        #expect(read?.rows == 2)
        #expect(read?.columns == 2)
        #expect(read?.cells.count == 4)
        // Typing into a cell on this Mac sends a cell the other Mac already has: it gets the very same objects.
        let typed = NSMutableAttributedString(string: "x", attributes: table.attributes(at: 0, effectiveRange: nil))
        let again = receiver.text(from: sender.insertion(of: typed))
        let first = (copy.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.first
        let second = (again?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.first
        #expect(first != nil && first === second)
    }

    @Test func everyAttributeComesBack() {
        let coder = SyncAttributeCoder()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.headIndent = 36
        style.lineHeightMultiple = 1.5
        style.tabStops = [NSTextTab(textAlignment: .right, location: 200)]
        let link = URL(string: "https://example.com/a?b=1")!
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Helvetica-Bold", size: 17)!, .foregroundColor: NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1),
            .underlineStyle: NSUnderlineStyle.single.rawValue, .paragraphStyle: style, .link: link, .pdNamedStyle: "heading2",
            .pdListItem: ListItem(listID: "L", preset: .decimalAlphaRoman), .baselineOffset: 3.5,
            .pdSuggestion: SuggestionMark(kind: .insertion, author: "Ana"),
        ]
        let decoded = coder.decode(coder.encode(attributes))
        #expect((decoded[.font] as? NSFont)?.fontName == "Helvetica-Bold")
        #expect((decoded[.font] as? NSFont)?.pointSize == 17)
        #expect((decoded[.foregroundColor] as? NSColor)?.hexString == (attributes[.foregroundColor] as? NSColor)?.hexString)
        #expect((decoded[.underlineStyle] as? NSNumber)?.intValue == NSUnderlineStyle.single.rawValue)
        #expect((decoded[.paragraphStyle] as? NSParagraphStyle)?.isEqual(style) == true)
        #expect(decoded[.link] as? URL == link)
        #expect(decoded[.pdNamedStyle] as? String == "heading2")
        #expect((decoded[.pdListItem] as? ListItem)?.isEqual(attributes[.pdListItem]) == true)
        #expect((decoded[.baselineOffset] as? NSNumber)?.doubleValue == 3.5)
        #expect((decoded[.pdSuggestion] as? SuggestionMark)?.isEqual(attributes[.pdSuggestion]) == true)
    }

    @Test func imagesAndPageNumbersTravel() {
        let coder = SyncAttributeCoder()
        let png = NSImage(size: NSSize(width: 4, height: 2), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }!
        let image = ImageAttachments.make(data: png, type: .png, size: CGSize(width: 40, height: 20))!
        let text = NSMutableAttributedString(attachment: image)
        text.append(PageFieldAttachment.string(.pageCount))
        guard let copy = coder.text(from: coder.insertion(of: text)) else {
            Issue.record("Nothing decoded")
            return
        }
        let attachment = copy.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
        #expect(attachment?.attachmentCell is ImageAttachmentCell)
        #expect(attachment?.bounds.size == CGSize(width: 40, height: 20))
        #expect((copy.attribute(.attachment, at: 1, effectiveRange: nil) as? PageFieldAttachment)?.kind == .pageCount)
    }
}

/// Macs editing one document through a log, delivering in random orders.
@MainActor
struct SyncTests {
    final class Log {
        var changes: [Int: LoggedChange] = [:]

        /// The change already at the revision, if one took it first.
        func claim(_ change: LoggedChange) -> LoggedChange? {
            if let existing = changes[change.revision] { return existing }
            changes[change.revision] = change
            return nil
        }
    }

    final class Mac {
        let storage: RecordingTextStorage
        let coder = SyncAttributeCoder()
        let client: SyncClient

        init(_ name: String, text: NSAttributedString) {
            storage = RecordingTextStorage(attributedString: text)
            client = SyncClient(revision: 0, author: name, authorName: name)
            storage.coder = coder
            storage.isRecording = true
            storage.onEdit = { [unowned self] edit in client.local(DocumentChange(body: edit.change)) }
        }

        func apply(_ changes: [DocumentChange]) {
            storage.isRecording = false
            for change in changes { #expect(coder.apply(change.body, to: storage)) }
            storage.isRecording = true
        }

        func send(to log: Log) {
            guard let change = client.nextToSend() else { return }
            if let existing = log.claim(change) {
                apply(client.sendTaken(change.id, by: existing))
            } else {
                client.sent(change.id)
            }
        }

        func receive(from log: Log, _ random: inout SeededGenerator) {
            // A few at a time, in any order, as fetches bring them.
            let some = log.changes.values.filter { _ in Bool.random(using: &random) }
            apply(client.receive(Array(some)))
        }

        func edit(_ random: inout SeededGenerator) {
            let length = storage.length
            let location = Int.random(in: 0...length, using: &random)
            let span = Int.random(in: 0...min(4, length - location), using: &random)
            let range = NSRange(location: location, length: span)
            switch Int.random(in: 0..<4, using: &random) {
            case 0, 1: storage.replaceCharacters(in: range, with: ["a", "bc", "\n", "dé"].randomElement(using: &random)!)
            case 2: storage.deleteCharacters(in: range)
            default:
                if span > 0 { storage.addAttribute(.foregroundColor, value: [NSColor.red, .blue].randomElement(using: &random)!, range: range) }
            }
        }
    }

    @Test func everyMacEndsWithTheSameText() {
        for seed in 0..<40 {
            var random = SeededGenerator(seed: UInt64(seed))
            let start = NSAttributedString(string: "Shared text to start from.", attributes: DocumentDefaults.typingAttributes)
            let macs = ["ana", "ben", "cy"].map { Mac($0, text: start) }
            let log = Log()
            for _ in 0..<150 {
                let mac = macs.randomElement(using: &random)!
                switch Int.random(in: 0..<3, using: &random) {
                case 0: mac.edit(&random)
                case 1: mac.send(to: log)
                default: mac.receive(from: log, &random)
                }
            }
            // Let everything settle.
            for _ in 0..<200 {
                for mac in macs {
                    mac.send(to: log)
                    mac.apply(mac.client.receive(Array(log.changes.values)))
                }
                if macs.allSatisfy({ !$0.client.hasPending && $0.client.revision == log.changes.count }) { break }
            }
            let texts = macs.map { $0.coder.insertion(of: $0.storage) }
            #expect(macs.allSatisfy { !$0.client.hasPending })
            #expect(texts.allSatisfy { $0 == texts[0] }, "seed \(seed): \(macs.map(\.storage.string))")
            if !texts.allSatisfy({ $0 == texts[0] }) { return }
        }
    }

    @Test func placesFollowTheLogAndChangesNotYetIn() {
        let start = NSAttributedString(string: "0123456789", attributes: DocumentDefaults.typingAttributes)
        let ana = Mac("ana", text: start)
        let ben = Mac("ben", text: start)
        let log = Log()
        // Ana inserts at the start and it goes in; Ben has typed at the end, not yet sent.
        ana.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "AB")
        ana.send(to: log)
        ben.storage.replaceCharacters(in: NSRange(location: 10, length: 0), with: "Z")
        ben.apply(ben.client.receive(Array(log.changes.values)))
        #expect(ben.storage.string == "AB0123456789Z")
        // A comment anchored at revision 0 on "45" is now at 6 here.
        #expect(ben.client.position(4, at: 0, priority: false) == 6)
        // And a place here is at the log's latest revision before Ben's own typing.
        #expect(ben.client.logPosition(13) == 12)
    }
}

@MainActor
struct ChangeTallyTests {
    private func text(_ string: String) -> NSAttributedString { NSAttributedString(string: string) }

    @Test func typingAndBackspaceCountAsWordsTyped() {
        var tally = ChangeTally()
        var location = 10
        for character in "Hello wonderful world" {
            tally.recordText(inserted: [(location, text(String(character)))], deleted: [], restyled: 0)
            location += 1
        }
        // Backspace over "world".
        for _ in 0..<5 {
            location -= 1
            tally.recordText(inserted: [], deleted: [(location, text("x"))], restyled: 0)
        }
        #expect(tally.wordsAdded == 2)
        #expect(tally.wordsRemoved == 0)
        let notice = tally.notice(author: "Ana Lopez", documentTitle: "Plan")
        #expect(notice?.title == "Ana Lopez edited “Plan”")
        #expect(notice?.body == "Added 2 words.")
    }

    @Test func summariesSayWhatChangedNotEveryChange() {
        var tally = ChangeTally()
        tally.recordText(inserted: [(0, text(String(repeating: "word ", count: 124)))], deleted: [(700, text("old text here"))], restyled: 4)
        tally.recordComment("Can we cut this part?")
        let notice = tally.notice(author: "Ben", documentTitle: "Quarterly plan")
        #expect(notice?.body == "Added about 120 words, removed 3 words, changed the formatting and added a comment.")

        var comments = ChangeTally()
        comments.recordComment("Should we name the layout we mean here?")
        #expect(comments.notice(author: "Cy", documentTitle: "Plan")?.title == "Cy commented on “Plan”")
        #expect(comments.notice(author: "Cy", documentTitle: "Plan")?.body == "“Should we name the layout we mean here?”")
        #expect(ChangeTally().notice(author: "Cy", documentTitle: "Plan") == nil)
    }

    @Test func aTableCountsOnceNotForEachLetterTypedInIt() {
        let attributes = DocumentDefaults.typingAttributes
        let table = TableModel.empty(rows: 2, columns: 2, attributes: attributes).attributedString(attributes: attributes)
        var tally = ChangeTally()
        tally.recordText(inserted: [(0, table)], deleted: [], restyled: 0)
        let cell = NSAttributedString(string: "C", attributes: table.attributes(at: 0, effectiveRange: nil))
        for offset in 0..<4 { tally.recordText(inserted: [(offset, cell)], deleted: [], restyled: 0) }
        #expect(tally.tablesAdded == 1)
    }

    @Test func threadsChangedOnTwoMacsKeepBoth() {
        let base = CommentThread(id: "t", author: "Ana", text: "Check this", replies: [CommentReply(id: "r1", author: "Ana", text: "First")])
        var local = base
        local.replies.append(CommentReply(id: "r2", author: "Ben", date: Date().addingTimeInterval(10), text: "Mine"))
        local.resolved = true
        var server = base
        server.replies.append(CommentReply(id: "r3", author: "Cy", date: Date().addingTimeInterval(5), text: "Theirs"))
        server.text = "Check this, please"
        let merged = SharedComment.merge(local: local, base: base, server: server)
        #expect(merged.replies.map(\.id) == ["r1", "r3", "r2"])
        #expect(merged.resolved)
        #expect(merged.text == "Check this, please")
    }
}
