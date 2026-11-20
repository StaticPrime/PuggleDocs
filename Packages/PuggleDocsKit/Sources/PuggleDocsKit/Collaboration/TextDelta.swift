import Foundation

/// Text as UTF-16 code units, the units `NSString` counts in. Kept as units rather than a `String` so that a change
/// can be cut anywhere without spoiling a character on its way between Macs.
public struct DeltaText: Hashable, Sendable {
    public var units: [UInt16]

    public init(units: [UInt16]) { self.units = units }
    public init(_ string: String) { units = Array(string.utf16) }
    public init(_ string: NSString) {
        var buffer = [UInt16](repeating: 0, count: string.length)
        string.getCharacters(&buffer, range: NSRange(location: 0, length: string.length))
        units = buffer
    }

    public var count: Int { units.count }
    public var string: String { String(decoding: units, as: UTF16.self) }
    public var nsString: NSString {
        units.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return "" }
            return NSString(characters: base, length: buffer.count)
        }
    }

    func slice(_ start: Int, _ length: Int) -> DeltaText { DeltaText(units: Array(units[start..<(start + length)])) }
}

/// One attribute's value in a change: its encoding (see `SyncAttributeCoder`), or that the attribute is removed.
public enum DeltaValue: Hashable, Sendable {
    case value(Data)
    case removed
}

/// Attributes by name. Inserted text only ever has values; a restyle can also remove attributes.
public typealias DeltaAttributes = [String: DeltaValue]

/// A change to a run of rich text, as the steps that turn the text before it into the text after it: keep (and
/// perhaps restyle) so many characters, insert text, delete so many characters. Two changes made at the same time to
/// the same text can each be rewritten to follow the other (`transform`), so that every Mac ends up with the same text
/// whichever it applied first; changes in a row combine into one (`compose`).
public struct TextDelta: Hashable, Sendable {
    public enum Op: Hashable, Sendable {
        case insert(DeltaText, DeltaAttributes)
        /// Keeps characters; non-empty attributes restyle them.
        case retain(Int, DeltaAttributes)
        case delete(Int)

        public var length: Int {
            switch self {
            case let .insert(text, _): text.count
            case let .retain(count, _): count
            case let .delete(count): count
            }
        }

        var attributes: DeltaAttributes {
            switch self {
            case let .insert(_, attributes), let .retain(_, attributes): attributes
            case .delete: [:]
            }
        }

        var isInsert: Bool { if case .insert = self { true } else { false } }
        var isDelete: Bool { if case .delete = self { true } else { false } }
        var isRetain: Bool { if case .retain = self { true } else { false } }
    }

    public private(set) var ops: [Op] = []

    public init() {}
    public init(ops: [Op]) { for op in ops { push(op) } }

    /// Nothing changes.
    public var isEmpty: Bool { ops.allSatisfy { if case let .retain(_, attributes) = $0 { attributes.isEmpty } else { false } } }

    /// How long the text it applies to must be at least.
    public var baseLength: Int { ops.reduce(0) { $1.isInsert ? $0 : $0 + $1.length } }
    /// How much longer (or shorter) it makes the text.
    public var lengthChange: Int {
        ops.reduce(0) { total, op in
            switch op {
            case let .insert(text, _): total + text.count
            case let .delete(count): total - count
            case .retain: total
            }
        }
    }

    // MARK: Building

    public mutating func retain(_ count: Int, _ attributes: DeltaAttributes = [:]) {
        if count > 0 { push(.retain(count, attributes)) }
    }

    public mutating func insert(_ text: DeltaText, _ attributes: DeltaAttributes = [:]) {
        if text.count > 0 { push(.insert(text, attributes.filter { $0.value != .removed })) }
    }

    public mutating func delete(_ count: Int) {
        if count > 0 { push(.delete(count)) }
    }

    /// Appends an op, merging it with the last where they combine. Inserts go before deletes at the same place, so
    /// the same change always has the same ops.
    public mutating func push(_ op: Op) {
        guard op.length > 0 else { return }
        var index = ops.count
        guard var last = ops.last else {
            ops.append(op)
            return
        }
        if case let .delete(count) = op, case let .delete(lastCount) = last {
            ops[index - 1] = .delete(count + lastCount)
            return
        }
        if last.isDelete, op.isInsert {
            index -= 1
            guard index > 0 else {
                ops.insert(op, at: 0)
                return
            }
            last = ops[index - 1]
        }
        if op.attributes == last.attributes {
            switch (op, last) {
            case let (.insert(text, attributes), .insert(lastText, _)):
                ops[index - 1] = .insert(DeltaText(units: lastText.units + text.units), attributes)
                return
            case let (.retain(count, attributes), .retain(lastCount, _)):
                ops[index - 1] = .retain(count + lastCount, attributes)
                return
            default:
                break
            }
        }
        ops.insert(op, at: index)
    }

    /// Drops a trailing plain retain, which changes nothing.
    public mutating func chop() {
        if case let .retain(_, attributes)? = ops.last, attributes.isEmpty { ops.removeLast() }
    }

    func chopped() -> TextDelta {
        var copy = self
        copy.chop()
        return copy
    }

    // MARK: Combining

    /// This change followed by `other`, as one change.
    public func compose(_ other: TextDelta) -> TextDelta {
        var this = OpIterator(ops)
        var that = OpIterator(other.ops)
        var result = TextDelta()
        if case let .retain(first, attributes)? = that.peek, attributes.isEmpty {
            var left = first
            while this.peekIsInsert, this.peekLength <= left {
                left -= this.peekLength
                result.push(this.next())
            }
            if first - left > 0 { _ = that.next(first - left) }
        }
        while this.hasNext || that.hasNext {
            if that.peekIsInsert {
                result.push(that.next())
            } else if this.peekIsDelete {
                result.push(this.next())
            } else {
                let length = min(this.peekLength, that.peekLength)
                let thisOp = this.next(length)
                let thatOp = that.next(length)
                if case let .retain(_, thatAttributes) = thatOp {
                    switch thisOp {
                    case let .retain(_, thisAttributes):
                        result.push(.retain(length, Self.compose(thisAttributes, thatAttributes, keepRemovals: true)))
                    case let .insert(text, thisAttributes):
                        result.push(.insert(text, Self.compose(thisAttributes, thatAttributes, keepRemovals: false)))
                    case .delete:
                        break
                    }
                    if !that.hasNext {
                        // The rest of `other` keeps everything: the rest of this change stands as it is.
                        for op in this.rest() { result.push(op) }
                        return result.chopped()
                    }
                } else if case .delete = thatOp, thisOp.isRetain {
                    result.push(thatOp)
                }
                // An insert this change makes that `other` deletes leaves nothing.
            }
        }
        return result.chopped()
    }

    /// `other`, made at the same time as this change to the same text, rewritten to follow this change. With
    /// `priority`, text this change inserts goes before text `other` inserts at the same place.
    public func transform(_ other: TextDelta, priority: Bool) -> TextDelta {
        var this = OpIterator(ops)
        var that = OpIterator(other.ops)
        var result = TextDelta()
        while this.hasNext || that.hasNext {
            if this.peekIsInsert, priority || !that.peekIsInsert {
                result.retain(this.next().length)
            } else if that.peekIsInsert {
                result.push(that.next())
            } else {
                let length = min(this.peekLength, that.peekLength)
                let thisOp = this.next(length)
                let thatOp = that.next(length)
                if thisOp.isDelete {
                    // What this change deletes is gone, whatever `other` did to it.
                    continue
                } else if thatOp.isDelete {
                    result.push(thatOp)
                } else {
                    result.retain(length, Self.transform(thisOp.attributes, thatOp.attributes, priority: priority))
                }
            }
        }
        return result.chopped()
    }

    /// Where `index` in the text before this change ends up after it. With `priority`, text inserted exactly at
    /// `index` goes after it (the index stays put); without, the index moves past it.
    public func transformPosition(_ index: Int, priority: Bool) -> Int {
        var iterator = OpIterator(ops)
        var index = index
        var offset = 0
        while iterator.hasNext, offset <= index {
            let length = iterator.peekLength
            let op = iterator.next()
            if op.isDelete {
                index -= min(length, index - offset)
                continue
            } else if op.isInsert, offset < index || !priority {
                index += length
            }
            offset += length
        }
        return index
    }

    /// Where `index` in the text after this change was before it. A place inside inserted text maps to where the
    /// text was inserted.
    public func positionBefore(_ index: Int) -> Int {
        var before = 0
        var after = 0
        for op in ops {
            guard after < index else { break }
            switch op {
            case let .retain(count, _):
                let step = min(count, index - after)
                before += step
                after += step
            case let .insert(text, _):
                let step = min(text.count, index - after)
                after += step
                if step < text.count { return before }
            case let .delete(count):
                before += count
            }
        }
        return before + max(0, index - after)
    }

    // MARK: Attributes

    static func compose(_ a: DeltaAttributes, _ b: DeltaAttributes, keepRemovals: Bool) -> DeltaAttributes {
        var result = b
        if !keepRemovals { result = result.filter { $0.value != .removed } }
        for (key, value) in a where b[key] == nil { result[key] = value }
        return result
    }

    static func transform(_ a: DeltaAttributes, _ b: DeltaAttributes, priority: Bool) -> DeltaAttributes {
        guard priority else { return b }
        return b.filter { a[$0.key] == nil }
    }

    /// What undoes `attributes` applied over `base`.
    static func invert(_ attributes: DeltaAttributes, base: DeltaAttributes) -> DeltaAttributes {
        var result: DeltaAttributes = [:]
        for (key, value) in attributes where base[key] != value {
            result[key] = base[key] ?? .removed
        }
        return result
    }

    /// What turns attributes `a` into `b`.
    public static func difference(_ a: DeltaAttributes, _ b: DeltaAttributes) -> DeltaAttributes {
        var result: DeltaAttributes = [:]
        for (key, value) in b where a[key] != value { result[key] = value }
        for key in a.keys where b[key] == nil { result[key] = .removed }
        return result
    }
}

// MARK: - Walking ops

/// Steps through ops a length at a time, cutting them where needed. Past the end it yields an endless plain retain.
struct OpIterator {
    private let ops: [TextDelta.Op]
    private var index = 0
    private var offset = 0

    init(_ ops: [TextDelta.Op]) { self.ops = ops }

    var hasNext: Bool { index < ops.count }

    var peek: TextDelta.Op? { index < ops.count ? ops[index] : nil }

    var peekLength: Int { index < ops.count ? ops[index].length - offset : Int.max }

    var peekIsInsert: Bool { peek?.isInsert ?? false }
    var peekIsDelete: Bool { peek?.isDelete ?? false }

    mutating func next(_ length: Int = Int.max) -> TextDelta.Op {
        guard index < ops.count else { return .retain(length, [:]) }
        let op = ops[index]
        let start = offset
        let remaining = op.length - start
        let taken = min(length, remaining)
        if taken == remaining {
            index += 1
            offset = 0
        } else {
            offset += taken
        }
        switch op {
        case let .insert(text, attributes):
            return .insert(start == 0 && taken == text.count ? text : text.slice(start, taken), attributes)
        case let .retain(_, attributes):
            return .retain(taken, attributes)
        case .delete:
            return .delete(taken)
        }
    }

    mutating func rest() -> [TextDelta.Op] {
        guard hasNext else { return [] }
        var result: [TextDelta.Op] = []
        if offset > 0 { result.append(next()) }
        result.append(contentsOf: ops[index...])
        index = ops.count
        return result
    }
}

// MARK: - Encoding

extension TextDelta {
    fileprivate struct EncodedOp: Codable {
        /// Inserted text, UTF-16 little-endian.
        var i: Data?
        var r: Int?
        var d: Int?
        /// Attribute values set.
        var a: [String: Data]?
        /// Attributes removed.
        var x: [String]?
    }

    private static func split(_ attributes: DeltaAttributes) -> ([String: Data]?, [String]?) {
        var values: [String: Data] = [:]
        var removed: [String] = []
        for (key, value) in attributes {
            switch value {
            case let .value(data): values[key] = data
            case .removed: removed.append(key)
            }
        }
        return (values.isEmpty ? nil : values, removed.isEmpty ? nil : removed.sorted())
    }

    private static func join(_ values: [String: Data]?, _ removed: [String]?) -> DeltaAttributes {
        var result: DeltaAttributes = [:]
        for (key, data) in values ?? [:] { result[key] = .value(data) }
        for key in removed ?? [] { result[key] = .removed }
        return result
    }

    fileprivate var encodedOps: [EncodedOp] {
        ops.map { op in
            switch op {
            case let .insert(text, attributes):
                let (values, _) = Self.split(attributes)
                return EncodedOp(i: Self.littleEndian(text.units.withUnsafeBytes { Data($0) }), a: values)
            case let .retain(count, attributes):
                let (values, removed) = Self.split(attributes)
                return EncodedOp(r: count, a: values, x: removed)
            case let .delete(count):
                return EncodedOp(d: count)
            }
        }
    }

    fileprivate init(encodedOps: [EncodedOp]) throws {
        self.init()
        for op in encodedOps {
            if let data = op.i {
                push(.insert(DeltaText(units: Self.units(fromLittleEndian: data)), Self.join(op.a, nil)))
            } else if let count = op.r, count > 0 {
                push(.retain(count, Self.join(op.a, op.x)))
            } else if let count = op.d, count > 0 {
                push(.delete(count))
            } else {
                throw CocoaError(.coderReadCorrupt)
            }
        }
    }

    private static func littleEndian(_ data: Data) -> Data {
        guard UInt16(littleEndian: 1) != 1 else { return data }
        var swapped = data
        swapped.withUnsafeMutableBytes { bytes in
            let units = bytes.bindMemory(to: UInt16.self)
            for index in units.indices { units[index] = units[index].byteSwapped }
        }
        return swapped
    }

    private static func units(fromLittleEndian data: Data) -> [UInt16] {
        let count = data.count / 2
        var units = [UInt16](repeating: 0, count: count)
        _ = units.withUnsafeMutableBytes { data.copyBytes(to: $0, count: count * 2) }
        return units.map { UInt16(littleEndian: $0) }
    }

    /// The change as bytes, to keep or send.
    public var encoded: Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return (try? encoder.encode(encodedOps)) ?? Data()
    }

    public init(encoded data: Data) throws {
        try self.init(encodedOps: PropertyListDecoder().decode([EncodedOp].self, from: data))
    }
}

extension TextDelta: Codable {
    public init(from decoder: Decoder) throws {
        try self.init(encodedOps: decoder.singleValueContainer().decode([EncodedOp].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(encodedOps)
    }
}
