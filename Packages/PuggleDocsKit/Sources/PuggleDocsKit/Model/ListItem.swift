import AppKit

public enum ListKind: String, Sendable {
    case bulleted, numbered, checklist
}

/// How a single list level renders its marker.
public enum ListNumberFormat: Sendable, Equatable {
    case bullet(String)
    case decimal
    case decimalZero
    case lowerAlpha
    case upperAlpha
    case lowerRoman
    case upperRoman
    case checkbox

    public func format(_ number: Int) -> String {
        switch self {
        case .bullet(let glyph): glyph
        case .checkbox: ""
        case .decimal: String(number)
        case .decimalZero: number < 10 ? "0\(number)" : String(number)
        case .lowerAlpha: ListNumberFormat.alpha(number)
        case .upperAlpha: ListNumberFormat.alpha(number).uppercased()
        case .lowerRoman: ListNumberFormat.roman(number).lowercased()
        case .upperRoman: ListNumberFormat.roman(number)
        }
    }

    /// a, b, ... z, aa, bb, ... (the convention word processors use).
    static func alpha(_ number: Int) -> String {
        guard number > 0 else { return "" }
        let letter = Character(UnicodeScalar(UInt8(97 + (number - 1) % 26)))
        return String(repeating: String(letter), count: (number - 1) / 26 + 1)
    }

    static func roman(_ number: Int) -> String {
        guard number > 0 else { return "" }
        let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
                                      (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var remaining = number
        var result = ""
        for (value, symbol) in table {
            while remaining >= value {
                result += symbol
                remaining -= value
            }
        }
        return result
    }
}

public struct ListLevelFormat: Sendable, Equatable {
    public var format: ListNumberFormat
    public var suffix: String
    /// Outline numbering ("1.2.") includes the numbers of all parent levels.
    public var outline: Bool = false
}

/// The list styles offered in the bullet, numbering and checklist dropdowns.
public enum ListPreset: String, CaseIterable, Sendable {
    case discCircleSquare, diamondArrowSquare, arrowDiamondDisc, starCircleSquare, boxArrowSquare, dashCircleSquare
    case decimalAlphaRoman, decimalOutline, decimalParen, upperAlphaLowerAlpha, upperAlphaDecimal, upperRomanUpperAlpha
    case checkbox

    public static let bulletPresets: [ListPreset] = [.discCircleSquare, .diamondArrowSquare, .arrowDiamondDisc,
                                                     .starCircleSquare, .boxArrowSquare, .dashCircleSquare]
    public static let numberPresets: [ListPreset] = [.decimalAlphaRoman, .decimalOutline, .decimalParen,
                                                     .upperAlphaLowerAlpha, .upperAlphaDecimal, .upperRomanUpperAlpha]

    public var kind: ListKind {
        switch self {
        case .checkbox: .checklist
        case .decimalAlphaRoman, .decimalOutline, .decimalParen, .upperAlphaLowerAlpha, .upperAlphaDecimal, .upperRomanUpperAlpha: .numbered
        default: .bulleted
        }
    }

    public static func defaultPreset(for kind: ListKind) -> ListPreset {
        switch kind {
        case .bulleted: .discCircleSquare
        case .numbered: .decimalAlphaRoman
        case .checklist: .checkbox
        }
    }

    /// Formats for the first three levels; deeper levels repeat the cycle.
    private var cycle: [ListLevelFormat] {
        func b(_ glyph: String) -> ListLevelFormat { ListLevelFormat(format: .bullet(glyph), suffix: "") }
        let dot = "."
        switch self {
        case .discCircleSquare: return [b("●"), b("○"), b("■")]
        case .diamondArrowSquare: return [b("❖"), b("➢"), b("■")]
        case .arrowDiamondDisc: return [b("➔"), b("◆"), b("●")]
        case .starCircleSquare: return [b("★"), b("○"), b("■")]
        case .boxArrowSquare: return [b("❏"), b("➢"), b("■")]
        case .dashCircleSquare: return [b("–"), b("○"), b("■")]
        case .decimalAlphaRoman:
            return [.init(format: .decimal, suffix: dot), .init(format: .lowerAlpha, suffix: dot), .init(format: .lowerRoman, suffix: dot)]
        case .decimalOutline:
            return [.init(format: .decimal, suffix: dot, outline: true), .init(format: .decimal, suffix: dot, outline: true),
                    .init(format: .decimal, suffix: dot, outline: true)]
        case .decimalParen:
            return [.init(format: .decimal, suffix: ")"), .init(format: .lowerAlpha, suffix: ")"), .init(format: .lowerRoman, suffix: ")")]
        case .upperAlphaLowerAlpha:
            return [.init(format: .upperAlpha, suffix: dot), .init(format: .lowerAlpha, suffix: dot), .init(format: .lowerRoman, suffix: dot)]
        case .upperAlphaDecimal:
            return [.init(format: .upperAlpha, suffix: dot), .init(format: .decimal, suffix: dot), .init(format: .lowerRoman, suffix: dot)]
        case .upperRomanUpperAlpha:
            return [.init(format: .upperRoman, suffix: dot), .init(format: .upperAlpha, suffix: dot), .init(format: .decimal, suffix: dot)]
        case .checkbox:
            return [.init(format: .checkbox, suffix: "")]
        }
    }

    public func levelFormat(_ level: Int) -> ListLevelFormat {
        let formats = cycle
        return formats[max(0, level) % formats.count]
    }

    /// Marker text for an item, given the counters of every level up to and including `level`.
    public func marker(level: Int, counters: [Int]) -> String {
        let format = levelFormat(level)
        let number = counters.indices.contains(level) ? counters[level] : 1
        if format.outline {
            let parts = (0...level).map { counters.indices.contains($0) ? max(counters[$0], 1) : 1 }
            return parts.map(String.init).joined(separator: ".") + format.suffix
        }
        return format.format.format(number) + format.suffix
    }

    /// A short preview such as "1. a. i." used in menus.
    public var previewText: String {
        (0..<3).map { marker(level: $0, counters: [1, 1, 1]) }.joined(separator: "  ")
    }
}

/// Paragraph attribute describing list membership. Immutable; use the `with` helpers to derive.
public final class ListItem: NSObject, NSSecureCoding, @unchecked Sendable {
    public static let maxLevel = 8
    /// Distance between nesting levels and from the marker to the text.
    public static let levelIndent: CGFloat = 36
    public static let markerOffset: CGFloat = 18

    public let listID: String
    public let preset: ListPreset
    public let level: Int
    public let isChecked: Bool

    public var kind: ListKind { preset.kind }

    public init(listID: String = UUID().uuidString, preset: ListPreset, level: Int = 0, isChecked: Bool = false) {
        self.listID = listID
        self.preset = preset
        self.level = min(max(level, 0), ListItem.maxLevel)
        self.isChecked = isChecked
    }

    public func with(level: Int) -> ListItem { ListItem(listID: listID, preset: preset, level: level, isChecked: isChecked) }
    public func with(checked: Bool) -> ListItem { ListItem(listID: listID, preset: preset, level: level, isChecked: checked) }
    public func with(preset: ListPreset) -> ListItem { ListItem(listID: listID, preset: preset, level: level, isChecked: isChecked) }

    /// Where the item's text starts, measured from the left margin.
    public static func textIndent(forLevel level: Int) -> CGFloat { levelIndent * CGFloat(level + 1) }
    public var textIndent: CGFloat { ListItem.textIndent(forLevel: level) }

    // MARK: NSSecureCoding

    public static var supportsSecureCoding: Bool { true }

    public func encode(with coder: NSCoder) {
        coder.encode(listID as NSString, forKey: "listID")
        coder.encode(preset.rawValue as NSString, forKey: "preset")
        coder.encode(level, forKey: "level")
        coder.encode(isChecked, forKey: "checked")
    }

    public init?(coder: NSCoder) {
        guard let listID = coder.decodeObject(of: NSString.self, forKey: "listID") as String?,
              let raw = coder.decodeObject(of: NSString.self, forKey: "preset") as String?,
              let preset = ListPreset(rawValue: raw)
        else { return nil }
        self.listID = listID
        self.preset = preset
        self.level = coder.decodeInteger(forKey: "level")
        self.isChecked = coder.decodeBool(forKey: "checked")
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? ListItem else { return false }
        return listID == other.listID && preset == other.preset && level == other.level && isChecked == other.isChecked
    }

    public override var hash: Int {
        var hasher = Hasher()
        hasher.combine(listID)
        hasher.combine(preset)
        hasher.combine(level)
        hasher.combine(isChecked)
        return hasher.finalize()
    }

    public override var description: String {
        "ListItem(\(preset.rawValue), level \(level)\(isChecked ? ", checked" : ""), id \(listID.prefix(8)))"
    }
}
