import AppKit

/// What one round of editing did to a text: the change, as other Macs apply it, and the change that undoes it.
public struct RecordedEdit {
    /// Turns the text as it was into the text as it is.
    public var change: TextDelta
    /// Turns the text as it is back into the text as it was.
    public var inverse: TextDelta
    /// Text the round added, where it is now.
    public var inserted: [(location: Int, text: NSAttributedString)]
    /// Text the round took out, and where in the text as it is now it was.
    public var deleted: [(location: Int, text: NSAttributedString)]
    /// How many characters kept their place but changed their look.
    public var restyled: Int
}

/// Text storage that, while `isRecording`, notes which characters each round of editing inserts, deletes or
/// restyles, however the editing was done (typing, commands, the editor's own clean-ups), and hands over a
/// `RecordedEdit` once the round is processed. Only attributes that travel between Macs count as restyling.
public final class RecordingTextStorage: NSTextStorage {
    private let backing = NSMutableAttributedString()
    private var pieces: EditPieces?

    /// Encodes the attributes in recorded changes. Recording needs one.
    public var coder: SyncAttributeCoder?
    public var isRecording = false {
        didSet { if !isRecording { pieces = nil } }
    }
    /// Called after each recorded round of editing that changed the text.
    public var onEdit: ((RecordedEdit) -> Void)?

    public override init() {
        super.init()
    }

    public override init(attributedString: NSAttributedString) {
        super.init()
        backing.setAttributedString(attributedString)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) {
        super.init(pasteboardPropertyList: propertyList, ofType: type)
    }

    public override var string: String { backing.string }

    public override func attributes(at location: Int, effectiveRange range: NSRangePointer?) -> [NSAttributedString.Key: Any] {
        backing.attributes(at: location, effectiveRange: range)
    }

    public override func replaceCharacters(in range: NSRange, with string: String) {
        let length = (string as NSString).length
        if isRecording { recordingPieces().replace(range, with: length, current: backing) }
        beginEditing()
        backing.replaceCharacters(in: range, with: string)
        edited(.editedCharacters, range: range, changeInLength: length - range.length)
        endEditing()
    }

    public override func setAttributes(_ attributes: [NSAttributedString.Key: Any]?, range: NSRange) {
        if isRecording { recordingPieces().touch(range, current: backing) }
        beginEditing()
        backing.setAttributes(attributes, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
        endEditing()
    }

    public override func processEditing() {
        super.processEditing()
        guard isRecording, let pieces, let coder else { return }
        self.pieces = nil
        if let edit = pieces.finish(current: backing, coder: coder) { onEdit?(edit) }
    }

    private func recordingPieces() -> EditPieces {
        if let pieces { return pieces }
        let pieces = EditPieces(length: backing.length)
        self.pieces = pieces
        return pieces
    }
}

/// The text as a round of editing has left it, piece by piece: runs of the text as it was (perhaps restyled) and
/// runs of new text. What was deleted, and how restyled text looked before, is kept as it was.
final class EditPieces {
    enum Piece {
        case kept(origin: Int, length: Int, touched: Bool)
        case inserted(length: Int)

        var length: Int {
            switch self {
            case let .kept(_, length, _): length
            case let .inserted(length): length
            }
        }

        func split(_ offset: Int) -> (Piece, Piece) {
            switch self {
            case let .kept(origin, length, touched):
                (.kept(origin: origin, length: offset, touched: touched), .kept(origin: origin + offset, length: length - offset, touched: touched))
            case let .inserted(length):
                (.inserted(length: offset), .inserted(length: length - offset))
            }
        }
    }

    private var pieces: [Piece]
    private let originalLength: Int
    /// Stretches of the text as it was, where it was: what was deleted, and what was restyled, before either.
    private var originals: [(origin: Int, text: NSAttributedString)] = []

    init(length: Int) {
        originalLength = length
        pieces = length > 0 ? [.kept(origin: 0, length: length, touched: false)] : []
    }

    /// Cuts the piece that `location` falls inside; answers the index of the piece that starts there.
    private func split(at location: Int) -> Int {
        var position = 0
        for index in pieces.indices {
            if position == location { return index }
            let length = pieces[index].length
            if location < position + length {
                let (left, right) = pieces[index].split(location - position)
                pieces[index] = left
                pieces.insert(right, at: index + 1)
                return index + 1
            }
            position += length
        }
        return pieces.count
    }

    func replace(_ range: NSRange, with length: Int, current: NSAttributedString) {
        let start = split(at: range.location)
        let end = split(at: NSMaxRange(range))
        var position = range.location
        for index in start..<end {
            if case let .kept(origin, count, false) = pieces[index] {
                originals.append((origin, current.attributedSubstring(from: NSRange(location: position, length: count))))
            }
            position += pieces[index].length
        }
        pieces.removeSubrange(start..<end)
        if length > 0 { pieces.insert(.inserted(length: length), at: start) }
        merge()
    }

    func touch(_ range: NSRange, current: NSAttributedString) {
        guard range.length > 0 else { return }
        let start = split(at: range.location)
        let end = split(at: NSMaxRange(range))
        var position = range.location
        for index in start..<end {
            if case let .kept(origin, count, false) = pieces[index] {
                originals.append((origin, current.attributedSubstring(from: NSRange(location: position, length: count))))
                pieces[index] = .kept(origin: origin, length: count, touched: true)
            }
            position += pieces[index].length
        }
        merge()
    }

    private func merge() {
        var merged: [Piece] = []
        for piece in pieces where piece.length > 0 {
            switch (merged.last, piece) {
            case let (.kept(origin, length, touched)?, .kept(next, count, nextTouched)) where origin + length == next && touched == nextTouched:
                merged[merged.count - 1] = .kept(origin: origin, length: length + count, touched: touched)
            case let (.inserted(length)?, .inserted(count)):
                merged[merged.count - 1] = .inserted(length: length + count)
            default:
                merged.append(piece)
            }
        }
        pieces = merged
    }

    /// The text as it was over `range` of it, from the stretches kept.
    private func original(_ range: Range<Int>) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for chunk in originals.sorted(by: { $0.origin < $1.origin }) {
            let chunkRange = chunk.origin..<(chunk.origin + chunk.text.length)
            let overlap = chunkRange.clamped(to: range)
            guard !overlap.isEmpty else { continue }
            result.append(chunk.text.attributedSubstring(from: NSRange(location: overlap.lowerBound - chunk.origin, length: overlap.count)))
        }
        return result
    }

    /// The change and its undoing, with what was added and taken out; nil when nothing that travels changed.
    func finish(current: NSAttributedString, coder: SyncAttributeCoder) -> RecordedEdit? {
        var change = TextDelta()
        var inverse = TextDelta()
        var inserted: [(Int, NSAttributedString)] = []
        var deleted: [(Int, NSAttributedString)] = []
        var restyled = 0
        var cursor = 0
        var position = 0

        func takeOut(upTo origin: Int) {
            guard origin > cursor else { return }
            let gone = original(cursor..<origin)
            change.delete(origin - cursor)
            push(gone, into: &inverse)
            deleted.append((position, gone))
            cursor = origin
        }

        func push(_ text: NSAttributedString, into delta: inout TextDelta) {
            let string = text.string as NSString
            text.enumerateAttributes(in: NSRange(location: 0, length: text.length), options: []) { attributes, range, _ in
                delta.insert(DeltaText(string.substring(with: range) as NSString), coder.encode(attributes))
            }
        }

        for piece in pieces {
            switch piece {
            case let .kept(origin, length, touched):
                takeOut(upTo: origin)
                let before = touched ? original(origin..<(origin + length)) : nil
                if let before, before.length == length {
                    var offset = 0
                    while offset < length {
                        var oldRun = NSRange()
                        var newRun = NSRange()
                        let old = before.attributes(at: offset, longestEffectiveRange: &oldRun, in: NSRange(location: 0, length: before.length))
                        let new = current.attributes(at: position + offset, longestEffectiveRange: &newRun,
                                                     in: NSRange(location: position + offset, length: length - offset))
                        let run = min(NSMaxRange(oldRun) - offset, NSMaxRange(newRun) - (position + offset))
                        let (forward, backward) = Self.changes(from: old, to: new, coder: coder)
                        change.retain(run, forward)
                        inverse.retain(run, backward)
                        if !forward.isEmpty { restyled += run }
                        offset += run
                    }
                } else {
                    change.retain(length)
                    inverse.retain(length)
                }
                cursor = origin + length
                position += length
            case let .inserted(length):
                let text = current.attributedSubstring(from: NSRange(location: position, length: length))
                push(text, into: &change)
                inverse.delete(length)
                inserted.append((position, text))
                position += length
            }
        }
        takeOut(upTo: originalLength)
        change.chop()
        inverse.chop()
        guard !change.isEmpty else { return nil }
        return RecordedEdit(change: change, inverse: inverse, inserted: inserted, deleted: deleted, restyled: restyled)
    }

    /// The restyling that takes attributes `old` to `new`, and back, counting only attributes that travel.
    private static func changes(from old: [NSAttributedString.Key: Any], to new: [NSAttributedString.Key: Any],
                                coder: SyncAttributeCoder) -> (DeltaAttributes, DeltaAttributes) {
        var forward: DeltaAttributes = [:]
        var backward: DeltaAttributes = [:]
        for key in SyncAttributeCoder.syncedKeys {
            let before = old[key]
            let after = new[key]
            if before == nil, after == nil { continue }
            if let before, let after, (before as AnyObject).isEqual(after) { continue }
            let beforeData = before.flatMap { coder.encodeValue($0, for: key) }
            let afterData = after.flatMap { coder.encodeValue($0, for: key) }
            guard beforeData != afterData else { continue }
            forward[key.rawValue] = afterData.map(DeltaValue.value) ?? .removed
            backward[key.rawValue] = beforeData.map(DeltaValue.value) ?? .removed
        }
        return (forward, backward)
    }
}
