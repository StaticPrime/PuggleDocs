import AppKit

/// Links carry their look (blue, underlined) as real formatting, so they print and export the
/// same as they appear on screen.
public enum LinkStyling {
    public static var color: NSColor { NSColor(hex: ColorPalette.linkHex) ?? .systemBlue }

    /// Styles link runs in `range` that still have the default text look (black, not underlined).
    public static func styleLinks(in storage: NSMutableAttributedString, range: NSRange) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        storage.enumerateAttribute(.link, in: range, options: []) { value, linkRange, _ in
            guard value != nil else { return }
            storage.enumerateAttributes(in: linkRange, options: []) { attributes, run, _ in
                let underlined = ((attributes[.underlineStyle] as? Int) ?? 0) != 0
                let colorHex = (attributes[.foregroundColor] as? NSColor)?.hexString ?? "000000"
                guard !underlined, colorHex == "000000" else { return }
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: run)
                storage.addAttribute(.foregroundColor, value: color, range: run)
            }
        }
    }
}
