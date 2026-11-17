import AppKit
import PuggleDocsKit

/// Native menus opened from toolbar dropdowns.
enum ToolbarMenus {
    static func make(_ kind: ToolbarMenu, controller: DocumentWindowController) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = true
        let state = controller.state
        let summary = state.summary
        func add(_ item: NSMenuItem) {
            if item.action != nil && item.target == nil { item.target = controller }
            menu.addItem(item)
        }

        switch kind {
        case .zoom:
            add(MenuBuilder.item("Fit", #selector(DocumentCommands.pdSetZoom(_:)), tag: 0))
            for level in Theme.zoomLevels {
                let item = MenuBuilder.item("\(Int(level * 100))%", #selector(DocumentCommands.pdSetZoom(_:)), tag: Int(level * 100))
                item.state = abs(state.zoom - level) < 0.005 ? .on : .off
                add(item)
            }

        case .style:
            let visible = NamedStyle.allCases.filter { style in
                guard let level = style.headingLevel, level > 3 else { return true }
                return state.usedHeadingLevels.contains(level) || summary.namedStyle == style
            }
            for style in visible {
                let index = NamedStyle.allCases.firstIndex(of: style)!
                let item = MenuBuilder.item(style.displayName, #selector(DocumentCommands.pdApplyStyle(_:)), tag: index)
                let definition = style.definition
                let font = FontResolver.font(family: definition.fontFamily, size: min(definition.fontSize, 22) * 1.05,
                                             bold: definition.bold, italic: definition.italic)
                item.attributedTitle = NSAttributedString(string: style.displayName,
                                                          attributes: [.font: font, .foregroundColor: definition.color])
                item.state = summary.namedStyle == style ? .on : .off
                if let digit = style.shortcutDigit {
                    item.keyEquivalent = digit
                    item.keyEquivalentModifierMask = [.command, .option]
                }
                add(item)
            }

        case .font:
            add(MenuBuilder.item("More fonts…", #selector(DocumentCommands.pdMoreFonts(_:)), symbol: "textformat"))
            let recent = RecentFonts.all.filter(FontResolver.isInstalled)
            if !recent.isEmpty {
                menu.addItem(.separator())
                menu.addItem(sectionHeader("RECENT"))
                recent.forEach { add(fontItem($0, current: summary.fontFamily)) }
            }
            menu.addItem(.separator())
            FontResolver.featuredFamilies.forEach { add(fontItem($0, current: summary.fontFamily)) }

        case .align:
            let options: [(String, String, NSTextAlignment)] = [("Left align", "text.alignleft", .left), ("Center align", "text.aligncenter", .center),
                                                                ("Right align", "text.alignright", .right), ("Justify", "text.justify", .justified)]
            for (index, option) in options.enumerated() {
                let item = MenuBuilder.item(option.0, #selector(DocumentCommands.pdAlign(_:)), tag: index, symbol: option.1)
                item.state = summary.alignment == option.2 ? .on : .off
                add(item)
            }

        case .lineSpacing:
            MenuBuilder.lineSpacingItems().forEach(add)

        case .bullets, .numbers, .checklist:
            let presets: [ListPreset] = kind == .bullets ? ListPreset.bulletPresets : (kind == .numbers ? ListPreset.numberPresets : [.checkbox])
            for preset in presets {
                let title = preset == .checkbox ? "☐  Checklist" : preset.previewText
                let item = MenuBuilder.item(title, #selector(DocumentCommands.pdListPreset(_:)))
                item.representedObject = preset.rawValue
                item.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 15)])
                item.state = summary.listPreset == preset ? .on : .off
                add(item)
            }

        case .mode:
            for (index, mode) in EditingMode.allCases.enumerated() {
                let item = MenuBuilder.item(mode.title, #selector(DocumentCommands.pdSetMode(_:)), tag: index, symbol: mode.symbol)
                item.toolTip = mode.detail
                if #available(macOS 14.4, *) { item.subtitle = mode.detail }
                add(item)
            }

        case .wordCount:
            for metric in WordCountMetric.allCases {
                let item = MenuBuilder.item(metric.title, #selector(DocumentCommands.pdSetWordCountMetric(_:)), tag: metric.rawValue)
                item.state = state.wordCountMetric == metric ? .on : .off
                add(item)
            }
            menu.addItem(.separator())
            add(MenuBuilder.item("Hide word count", #selector(DocumentCommands.pdToggleWordCount(_:))))

        case .download:
            for (index, format) in DownloadFormat.allCases.enumerated() {
                add(MenuBuilder.item(format.displayName, #selector(DocumentCommands.pdDownload(_:)), tag: index))
            }
        }
        return menu
    }

    private static func fontItem(_ family: String, current: String?) -> NSMenuItem {
        let item = MenuBuilder.item(family, #selector(DocumentCommands.pdSetFont(_:)))
        item.representedObject = family
        item.attributedTitle = NSAttributedString(string: family, attributes: [.font: FontResolver.font(family: family, size: 14)])
        item.state = family == current ? .on : .off
        return item
    }

    private static func sectionHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14, *) { return NSMenuItem.sectionHeader(title: title) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
