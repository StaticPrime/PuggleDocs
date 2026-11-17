import AppKit

public enum StyleFormatting {
    /// Character transform that moves a run from `old` style defaults to `new` style defaults,
    /// keeping the run's own deviations (e.g. a bold word stays bold).
    public static func restyleRun(from old: NamedStyle, to new: NamedStyle) -> AttributeTransform {
        let oldDefinition = old.definition
        let newDefinition = new.definition
        return { attributes in
            var spec = FontResolver.spec(from: attributes)
            if spec.family.caseInsensitiveCompare(oldDefinition.fontFamily) == .orderedSame {
                spec.family = newDefinition.fontFamily
            }
            spec.size = newDefinition.fontSize
            if spec.bold == oldDefinition.bold { spec.bold = newDefinition.bold }
            if spec.italic == oldDefinition.italic { spec.italic = newDefinition.italic }
            FontResolver.apply(spec, to: &attributes)
            let color = attributes[.foregroundColor] as? NSColor
            if color == nil || color?.hexString == oldDefinition.colorHex {
                attributes[.foregroundColor] = newDefinition.color
            }
        }
    }

    public static func paragraphTransform(for style: NamedStyle) -> ParagraphTransform {
        { paragraph in
            let definition = style.definition
            paragraph.namedStyle = style
            paragraph.style.paragraphSpacingBefore = definition.spaceBefore
            paragraph.style.paragraphSpacing = definition.spaceAfter
            paragraph.style.lineHeightMultiple = definition.lineSpacing
        }
    }

    /// Applies a named paragraph style to whole paragraphs.
    public static func apply(_ style: NamedStyle, to storage: NSMutableAttributedString, paragraphRanges: [NSRange]) {
        for range in paragraphRanges where range.length > 0 {
            let old = (storage.attribute(.pdNamedStyle, at: range.location, effectiveRange: nil) as? String)
                .flatMap(NamedStyle.init(rawValue:)) ?? .normal
            CharacterFormatting.apply(restyleRun(from: old, to: style), to: storage, range: range)
            ParagraphFormatting.apply(paragraphTransform(for: style), to: storage, paragraphRanges: [range])
        }
    }

    public static func apply(_ style: NamedStyle, to typing: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        let old = (typing[.pdNamedStyle] as? String).flatMap(NamedStyle.init(rawValue:)) ?? .normal
        let restyled = CharacterFormatting.apply(restyleRun(from: old, to: style), to: typing)
        return ParagraphFormatting.apply(paragraphTransform(for: style), to: restyled)
    }

    /// "Clear formatting" for whole paragraphs and the selected characters.
    public static func clearFormatting(in storage: NSMutableAttributedString, characterRanges: [NSRange], paragraphRanges: [NSRange]) {
        ParagraphFormatting.apply(ParagraphFormatting.clearFormatting(), to: storage, paragraphRanges: paragraphRanges)
        for range in characterRanges where range.length > 0 {
            storage.enumerateAttribute(.pdNamedStyle, in: range, options: []) { value, subrange, _ in
                let style = (value as? String).flatMap(NamedStyle.init(rawValue:)) ?? .normal
                CharacterFormatting.apply(CharacterFormatting.clearFormatting(for: style), to: storage, range: subrange)
            }
        }
    }
}

public enum ListFormatting {
    public static func listItem(at index: Int, in storage: NSAttributedString) -> ListItem? {
        guard index < storage.length else { return nil }
        return storage.attribute(.pdListItem, at: index, effectiveRange: nil) as? ListItem
    }

    /// Toolbar/menu toggle. Removes the list when every paragraph is already in a list of `kind`
    /// (and `preset` is nil); otherwise converts the paragraphs, reusing an adjacent list's identity.
    public static func toggle(kind: ListKind, preset: ListPreset?, in storage: NSMutableAttributedString,
                              paragraphRanges: [NSRange], typing: inout [NSAttributedString.Key: Any]) {
        let items = paragraphRanges.map { range -> ListItem? in
            range.length > 0 ? listItem(at: range.location, in: storage) : typing[.pdListItem] as? ListItem
        }
        let allSameKind = !items.isEmpty && items.allSatisfy { $0?.kind == kind }

        if allSameKind, let preset {
            // Restyle every item of the affected lists.
            let ids = Set(items.compactMap { $0?.listID })
            restyle(listIDs: ids, preset: preset, in: storage)
            if let item = typing[.pdListItem] as? ListItem, ids.contains(item.listID) {
                typing[.pdListItem] = item.with(preset: preset)
            }
            return
        }

        if allSameKind {
            ParagraphFormatting.apply(ParagraphFormatting.setList(nil), to: storage, paragraphRanges: paragraphRanges)
            if paragraphRanges.contains(where: { $0.length == 0 }) || paragraphRanges.isEmpty {
                typing = ParagraphFormatting.apply(ParagraphFormatting.setList(nil), to: typing)
            }
            return
        }

        let chosenPreset = preset ?? ListPreset.defaultPreset(for: kind)
        let listID = reusableListID(kind: kind, preset: chosenPreset, before: paragraphRanges.first?.location ?? 0, in: storage)
            ?? items.compactMap({ $0 }).first(where: { $0.kind == kind })?.listID
            ?? UUID().uuidString

        for (range, existing) in zip(paragraphRanges, items) {
            let item = ListItem(listID: listID, preset: chosenPreset, level: existing?.level ?? 0)
            if range.length > 0 {
                ParagraphFormatting.apply(ParagraphFormatting.setList(item), to: storage, paragraphRanges: [range])
                if kind != .checklist {
                    CharacterFormatting.apply(CharacterFormatting.setStrikethrough(false), to: storage, range: range)
                }
            } else {
                typing = ParagraphFormatting.apply(ParagraphFormatting.setList(item), to: typing)
            }
        }
    }

    /// The list id of the paragraph just before `location` when it is a compatible list.
    static func reusableListID(kind: ListKind, preset: ListPreset, before location: Int, in storage: NSAttributedString) -> String? {
        guard location > 0 else { return nil }
        let string = storage.string as NSString
        let previous = string.paragraphRange(for: NSRange(location: location - 1, length: 0))
        guard let item = listItem(at: previous.location, in: storage), item.kind == kind, item.preset == preset else { return nil }
        return item.listID
    }

    public static func restyle(listIDs: Set<String>, preset: ListPreset, in storage: NSMutableAttributedString) {
        guard !listIDs.isEmpty, storage.length > 0 else { return }
        storage.enumerateAttribute(.pdListItem, in: NSRange(location: 0, length: storage.length), options: []) { value, range, _ in
            guard let item = value as? ListItem, listIDs.contains(item.listID) else { return }
            storage.addAttribute(.pdListItem, value: item.with(preset: preset), range: range)
        }
    }

    /// Toggles the checked state of a checklist item paragraph, striking its text through.
    public static func toggleChecked(paragraphRange range: NSRange, in storage: NSMutableAttributedString) {
        guard range.length > 0, let item = listItem(at: range.location, in: storage), item.kind == .checklist else { return }
        let checked = !item.isChecked
        storage.addAttribute(.pdListItem, value: item.with(checked: checked), range: range)
        var textRange = range
        if (storage.string as NSString).character(at: NSMaxRange(range) - 1) == 0x0A { textRange.length -= 1 }
        if textRange.length > 0 {
            CharacterFormatting.apply(CharacterFormatting.setStrikethrough(checked), to: storage, range: textRange)
        }
    }
}
