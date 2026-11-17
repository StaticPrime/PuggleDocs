import AppKit
import os

/// The font properties the editor manipulates independently.
public struct FontSpec: Equatable, Sendable {
    public var family: String
    public var size: CGFloat
    public var bold: Bool
    public var italic: Bool

    public init(family: String, size: CGFloat, bold: Bool = false, italic: Bool = false) {
        self.family = family
        self.size = size
        self.bold = bold
        self.italic = italic
    }
}

/// Creates fonts by family/size/traits with predictable fallbacks for missing families.
public enum FontResolver {
    public static let defaultFamily = "Arial"
    public static let minimumSize: CGFloat = 1
    public static let maximumSize: CGFloat = 400
    /// Superscript and subscript text renders at this fraction of its logical size.
    public static let scriptScale: CGFloat = 0.65

    private static let availability = OSAllocatedUnfairLock(initialState: [String: Bool]())

    public static func isInstalled(_ family: String) -> Bool {
        if let cached = availability.withLock({ $0[family] }) { return cached }
        let descriptor = NSFontDescriptor(fontAttributes: [.family: family])
        let installed = !descriptor.matchingFontDescriptors(withMandatoryKeys: [.family]).isEmpty
        availability.withLock { $0[family] = installed }
        return installed
    }

    /// A reasonable installed stand-in for a family that is not available.
    public static func substitute(for family: String) -> String {
        let name = family.lowercased()
        let candidates: [(keys: [String], fallback: String)] = [
            (["mono", "courier", "consol", "code", "menlo"], "Courier New"),
            (["times", "serif", "garamond", "georgia", "cambria", "book", "minion", "palatino", "baskerville", "merriweather", "lora"], "Times New Roman"),
            (["calibri", "aptos", "carlito", "segoe", "roboto", "open sans", "lato", "source sans", "noto sans", "inter", "montserrat", "nunito"], "Helvetica Neue"),
        ]
        // "Sans" names must not fall into the serif bucket.
        if name.contains("sans") { return isInstalled("Helvetica Neue") ? "Helvetica Neue" : defaultFamily }
        for candidate in candidates where candidate.keys.contains(where: name.contains) {
            if isInstalled(candidate.fallback) { return candidate.fallback }
        }
        return defaultFamily
    }

    public static func font(family: String, size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
        let size = min(max(size, minimumSize), maximumSize)
        let resolvedFamily = isInstalled(family) ? family : substitute(for: family)
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let base = NSFontDescriptor(fontAttributes: [.family: resolvedFamily])
        if !traits.isEmpty {
            let styled = base.withSymbolicTraits(traits)
            if let font = NSFont(descriptor: styled, size: size), font.familyName == resolvedFamily {
                return font
            }
            // Some families lack a bold-italic face; try the closest single trait.
            for single in [NSFontDescriptor.SymbolicTraits.bold, .italic] where traits.contains(single) {
                if let font = NSFont(descriptor: base.withSymbolicTraits(single), size: size), font.familyName == resolvedFamily {
                    return font
                }
            }
        }
        if let font = NSFont(descriptor: base, size: size) { return font }
        return NSFont(name: defaultFamily, size: size) ?? NSFont.systemFont(ofSize: size)
    }

    public static func font(for spec: FontSpec) -> NSFont {
        font(family: spec.family, size: spec.size, bold: spec.bold, italic: spec.italic)
    }

    public static func spec(of font: NSFont) -> FontSpec {
        let traits = font.fontDescriptor.symbolicTraits
        return FontSpec(family: font.familyName ?? defaultFamily,
                        size: font.pointSize,
                        bold: traits.contains(.bold),
                        italic: traits.contains(.italic))
    }

    /// The spec described by a run's attributes, preferring the family the file originally asked for
    /// and the logical (unscaled) size of superscript and subscript text.
    public static func spec(from attributes: [NSAttributedString.Key: Any]) -> FontSpec {
        let font = attributes[.font] as? NSFont ?? NamedStyle.normal.definition.font
        var spec = spec(of: font)
        if let requested = attributes[.pdRequestedFont] as? RequestedFont, requested.substitute == spec.family {
            spec.family = requested.family
        }
        if CharacterFormatting.baseline(attributes) != 0, let base = attributes[.pdScriptBaseSize] as? NSNumber {
            spec.size = CGFloat(base.doubleValue)
        }
        return spec
    }

    /// Writes `spec` into `attributes`, recording the requested family when a substitute is used.
    /// Superscript/subscript runs get a smaller rendered font and remember the logical size.
    public static func apply(_ spec: FontSpec, to attributes: inout [NSAttributedString.Key: Any]) {
        var rendered = spec
        if CharacterFormatting.baseline(attributes) != 0 {
            rendered.size = max(minimumSize, (spec.size * scriptScale * 2).rounded() / 2)
            attributes[.pdScriptBaseSize] = NSNumber(value: Double(spec.size))
        } else {
            attributes[.pdScriptBaseSize] = nil
        }
        let font = font(for: rendered)
        attributes[.font] = font
        let actual = font.familyName ?? spec.family
        if actual.caseInsensitiveCompare(spec.family) != .orderedSame {
            attributes[.pdRequestedFont] = RequestedFont(family: spec.family, substitute: actual)
        } else {
            attributes[.pdRequestedFont] = nil
        }
    }

    /// Families shown at the top of the font menu, filtered to what is installed.
    public static var featuredFamilies: [String] {
        let preferred = ["Arial", "Avenir Next", "Baskerville", "Calibri", "Cambria", "Comic Sans MS", "Courier New",
                         "Didot", "Futura", "Georgia", "Gill Sans", "Helvetica", "Helvetica Neue", "Hoefler Text",
                         "Impact", "Lato", "Menlo", "Merriweather", "Montserrat", "Optima", "Palatino", "Roboto",
                         "Rockwell", "Times New Roman", "Trebuchet MS", "Verdana"]
        return preferred.filter(isInstalled)
    }
}
