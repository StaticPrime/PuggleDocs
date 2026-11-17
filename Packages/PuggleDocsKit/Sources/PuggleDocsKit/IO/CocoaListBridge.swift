import AppKit

/// Converts between PuggleDocs list attributes and AppKit's `NSTextList` paragraph lists,
/// which is what the system RTF/HTML/ODT readers and writers understand.
public enum CocoaListBridge {
    /// AppKit lists → `ListItem` attributes. Also gives unstyled paragraphs a named style.
    public static func importLists(_ storage: NSMutableAttributedString) {
        guard storage.length > 0 else { return }
        let string = storage.string as NSString
        var listIDs: [ObjectIdentifier: String] = [:]
        var location = 0
        while location < string.length {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)
            guard let style = storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle,
                  let deepest = style.textLists.last, let top = style.textLists.first
            else { continue }
            let id = listIDs[ObjectIdentifier(top)] ?? UUID().uuidString
            listIDs[ObjectIdentifier(top)] = id
            let level = min(style.textLists.count - 1, ListItem.maxLevel)
            let preset = preset(forTopFormat: top.markerFormat, deepestFormat: deepest.markerFormat)
            let checked = deepest.markerFormat == .check
            let item = ListItem(listID: id, preset: preset, level: level, isChecked: checked)
            let updated = style.mutableCopy() as! NSMutableParagraphStyle
            updated.textLists = []
            updated.headIndent = item.textIndent
            updated.firstLineHeadIndent = item.textIndent
            storage.addAttribute(.paragraphStyle, value: updated.copy() as! NSParagraphStyle, range: paragraph)
            storage.addAttribute(.pdListItem, value: item, range: paragraph)
        }
    }

    static func preset(forTopFormat top: NSTextList.MarkerFormat, deepestFormat: NSTextList.MarkerFormat) -> ListPreset {
        let raw = top.rawValue
        if [NSTextList.MarkerFormat.box, .check].contains(deepestFormat) || [NSTextList.MarkerFormat.box, .check].contains(top) {
            return .checkbox
        }
        if raw.contains("{decimal}") { return raw.contains(")") ? .decimalParen : .decimalAlphaRoman }
        if raw.contains("{upper-roman}") { return .upperRomanUpperAlpha }
        if raw.contains("{upper-alpha}") || raw.contains("{upper-latin}") { return .upperAlphaLowerAlpha }
        if raw.contains("{lower-alpha}") || raw.contains("{lower-latin}") || raw.contains("{lower-roman}") { return .decimalAlphaRoman }
        if raw.contains("{diamond}") || raw.contains("❖") { return .diamondArrowSquare }
        if raw.contains("{hyphen}") || raw.contains("–") { return .dashCircleSquare }
        if raw.contains("★") { return .starCircleSquare }
        if raw.contains("➔") { return .arrowDiamondDisc }
        if raw.contains("❏") { return .boxArrowSquare }
        if raw.contains("{octal}") || raw.contains("hexadecimal") { return .decimalAlphaRoman }
        return .discCircleSquare
    }

    /// `ListItem` attributes → AppKit lists, for handing text to system writers or the pasteboard.
    public static func exportLists(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        guard result.length > 0 else { return result }
        var lists: [String: NSTextList] = [:]
        func list(_ item: ListItem, level: Int) -> NSTextList {
            let key = "\(item.listID)|\(level)|\(item.preset.rawValue)|\(item.kind == .checklist ? String(item.isChecked) : "")"
            if let existing = lists[key] { return existing }
            let created = NSTextList(markerFormat: markerFormat(item.preset, level: level, checked: item.isChecked), options: 0)
            lists[key] = created
            return created
        }
        result.enumerateAttribute(.pdListItem, in: NSRange(location: 0, length: result.length), options: []) { value, range, _ in
            guard let item = value as? ListItem else { return }
            let base = (result.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle) ?? .default
            let style = base.mutableCopy() as! NSMutableParagraphStyle
            style.textLists = (0...item.level).map { list(item.with(level: $0), level: $0) }
            style.headIndent = item.textIndent
            style.firstLineHeadIndent = max(0, item.textIndent - ListItem.markerOffset)
            result.addAttribute(.paragraphStyle, value: style.copy() as! NSParagraphStyle, range: range)
        }
        return result
    }

    static func markerFormat(_ preset: ListPreset, level: Int, checked: Bool) -> NSTextList.MarkerFormat {
        let format = preset.levelFormat(level)
        switch format.format {
        case .checkbox: return checked ? .check : .box
        case .bullet(let glyph):
            switch glyph {
            case "●": return .disc
            case "○": return .circle
            case "■": return .square
            case "◆": return .diamond
            case "–": return .hyphen
            default: return NSTextList.MarkerFormat(glyph)
            }
        case .decimal, .decimalZero: return NSTextList.MarkerFormat("{decimal}" + format.suffix)
        case .lowerAlpha: return NSTextList.MarkerFormat("{lower-alpha}" + format.suffix)
        case .upperAlpha: return NSTextList.MarkerFormat("{upper-alpha}" + format.suffix)
        case .lowerRoman: return NSTextList.MarkerFormat("{lower-roman}" + format.suffix)
        case .upperRoman: return NSTextList.MarkerFormat("{upper-roman}" + format.suffix)
        }
    }

    /// Removes PuggleDocs-only attributes that other apps should not see.
    public static func strippingPrivateAttributes(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        let all = NSRange(location: 0, length: result.length)
        for key in [NSAttributedString.Key.pdListItem, .pdNamedStyle, .pdRequestedFont, .pdScriptBaseSize, .pdComments, .pdSuggestion] {
            result.removeAttribute(key, range: all)
        }
        return result
    }
}
