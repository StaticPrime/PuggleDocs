import Foundation

extension XMLElement {
    /// Attribute value by local name, ignoring the namespace prefix.
    func value(_ localName: String) -> String? {
        for attribute in attributes ?? [] where attribute.localName == localName || attribute.name == localName {
            return attribute.stringValue
        }
        return nil
    }

    var elementChildren: [XMLElement] { (children ?? []).compactMap { $0 as? XMLElement } }

    func firstChild(_ localName: String) -> XMLElement? {
        elementChildren.first { $0.localName == localName }
    }

    func childElements(_ localName: String) -> [XMLElement] {
        elementChildren.filter { $0.localName == localName }
    }

    func firstDescendant(_ localName: String) -> XMLElement? {
        for child in elementChildren {
            if child.localName == localName { return child }
            if let found = child.firstDescendant(localName) { return found }
        }
        return nil
    }
}

/// CSS/ODF length and color parsing shared by the ODT and HTML readers.
enum Lengths {
    /// Converts "12pt", "0.5in", "1.27cm", "12.7mm", "1pc", "16px" or a bare number (points) to points.
    static func points(_ text: String?) -> CGFloat? {
        guard var value = text?.trimmingCharacters(in: .whitespaces).lowercased(), !value.isEmpty else { return nil }
        let units: [(String, CGFloat)] = [("pt", 1), ("in", 72), ("cm", 72 / 2.54), ("mm", 72 / 25.4), ("pc", 12), ("px", 0.75), ("em", 11), ("rem", 11)]
        var factor: CGFloat = 1
        for (suffix, unitFactor) in units where value.hasSuffix(suffix) {
            value.removeLast(suffix.count)
            factor = unitFactor
            break
        }
        guard let number = Double(value.trimmingCharacters(in: .whitespaces)) else { return nil }
        return CGFloat(number) * factor
    }

    /// Parses a percentage like "115%" into 1.15.
    static func percentage(_ text: String?) -> CGFloat? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), text.hasSuffix("%"), let value = Double(text.dropLast()) else { return nil }
        return CGFloat(value) / 100
    }

    static let namedColors: [String: String] = [
        "black": "000000", "white": "FFFFFF", "red": "FF0000", "green": "008000", "blue": "0000FF", "yellow": "FFFF00",
        "gray": "808080", "grey": "808080", "silver": "C0C0C0", "maroon": "800000", "purple": "800080", "fuchsia": "FF00FF",
        "lime": "00FF00", "olive": "808000", "navy": "000080", "teal": "008080", "aqua": "00FFFF", "orange": "FFA500",
    ]

    /// "#RRGGBB", "#RGB", "rgb(r, g, b)" or a basic color name to "RRGGBB"; nil for transparent or unknown.
    static func hexColor(_ text: String?) -> String? {
        guard let raw = text?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty, raw != "transparent", raw != "none" else { return nil }
        if raw.hasPrefix("#") {
            let hex = String(raw.dropFirst())
            if hex.count == 6, UInt32(hex, radix: 16) != nil { return hex.uppercased() }
            if hex.count == 3, UInt32(hex, radix: 16) != nil { return hex.map { "\($0)\($0)" }.joined().uppercased() }
            return nil
        }
        if raw.hasPrefix("rgb") {
            let numbers = raw.drop { $0 != "(" }.dropFirst().prefix { $0 != ")" }.split(separator: ",")
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")) }
            guard numbers.count >= 3 else { return nil }
            if numbers.count == 4, numbers[3] == 0 { return nil }
            return String(format: "%02X%02X%02X", Int(min(max(numbers[0], 0), 255)), Int(min(max(numbers[1], 0), 255)), Int(min(max(numbers[2], 0), 255)))
        }
        return namedColors[raw]
    }
}
