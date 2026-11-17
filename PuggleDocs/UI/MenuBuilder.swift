import AppKit
import PuggleDocsKit

/// Actions implemented by `DocumentWindowController` and reached through the responder chain.
@objc protocol DocumentCommands {
    func pdToggleBold(_ sender: Any?)
    func pdToggleItalic(_ sender: Any?)
    func pdToggleUnderline(_ sender: Any?)
    func pdToggleStrikethrough(_ sender: Any?)
    func pdSuperscript(_ sender: Any?)
    func pdSubscript(_ sender: Any?)
    func pdIncreaseFontSize(_ sender: Any?)
    func pdDecreaseFontSize(_ sender: Any?)
    func pdLowercase(_ sender: Any?)
    func pdUppercase(_ sender: Any?)
    func pdTitleCase(_ sender: Any?)
    func pdApplyStyle(_ sender: Any?)
    func pdAlign(_ sender: Any?)
    func pdIncreaseIndent(_ sender: Any?)
    func pdDecreaseIndent(_ sender: Any?)
    func pdLineSpacing(_ sender: Any?)
    func pdToggleSpaceBefore(_ sender: Any?)
    func pdToggleSpaceAfter(_ sender: Any?)
    func pdCustomSpacing(_ sender: Any?)
    func pdBulletedList(_ sender: Any?)
    func pdNumberedList(_ sender: Any?)
    func pdChecklist(_ sender: Any?)
    func pdListPreset(_ sender: Any?)
    func pdClearFormatting(_ sender: Any?)
    func pdInsertPageBreak(_ sender: Any?)
    func pdZoomIn(_ sender: Any?)
    func pdZoomOut(_ sender: Any?)
    func pdActualSize(_ sender: Any?)
    func pdZoomToFit(_ sender: Any?)
    func pdSetZoom(_ sender: Any?)
    func pdToggleRuler(_ sender: Any?)
    func pdToggleInvisibles(_ sender: Any?)
    func pdSetMode(_ sender: Any?)
    func pdWordCount(_ sender: Any?)
    func pdToggleSpellCheck(_ sender: Any?)
    func pdDownload(_ sender: Any?)
    func pdRename(_ sender: Any?)
    func pdMoreFonts(_ sender: Any?)
    func pdSetFont(_ sender: Any?)
    func pdSetFontSize(_ sender: Any?)
    func pdShowShortcuts(_ sender: Any?)
    func pdPageSetup(_ sender: Any?)
    func pdSetWordCountMetric(_ sender: Any?)
    func pdToggleWordCount(_ sender: Any?)
    func pdFind(_ sender: Any?)
    func pdFindAndReplace(_ sender: Any?)
    func pdFindNext(_ sender: Any?)
    func pdFindPrevious(_ sender: Any?)
    func pdInsertLink(_ sender: Any?)
    func pdRemoveLink(_ sender: Any?)
    func pdOpenLink(_ sender: Any?)
    func pdCopyLink(_ sender: Any?)
    func pdToggleOutline(_ sender: Any?)
    func pdInsertImage(_ sender: Any?)
    func pdImageOptions(_ sender: Any?)
    func pdEditHeader(_ sender: Any?)
    func pdEditFooter(_ sender: Any?)
    func pdInsertPageNumber(_ sender: Any?)
    func pdInsertPageCount(_ sender: Any?)
    func pdToggleDifferentFirstPage(_ sender: Any?)
    func pdRemoveHeader(_ sender: Any?)
    func pdRemoveFooter(_ sender: Any?)
    func pdInsertTable(_ sender: Any?)
    func pdTableInsertRow(_ sender: Any?)
    func pdTableInsertColumn(_ sender: Any?)
    func pdTableDeleteRow(_ sender: Any?)
    func pdTableDeleteColumn(_ sender: Any?)
    func pdTableDelete(_ sender: Any?)
    func pdTableProperties(_ sender: Any?)
    func pdInsertComment(_ sender: Any?)
    func pdCommentHistory(_ sender: Any?)
    func pdAcceptAllSuggestions(_ sender: Any?)
    func pdRejectAllSuggestions(_ sender: Any?)
}

enum MenuKind: String, CaseIterable {
    case file = "File", edit = "Edit", view = "View", insert = "Insert", format = "Format", tools = "Tools", help = "Help"
}

enum MenuBuilder {
    static func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command,
                     tag: Int = 0, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.tag = tag
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    static func submenu(_ title: String, symbol: String? = nil, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }

    static func makeMainMenu() -> NSMenu {
        let main = NSMenu(title: "Main")
        let appItem = NSMenuItem()
        appItem.submenu = makeAppMenu()
        main.addItem(appItem)
        for kind in MenuKind.allCases where kind != .help {
            let item = NSMenuItem(title: kind.rawValue, action: nil, keyEquivalent: "")
            item.submenu = makeMenu(kind)
            main.addItem(item)
        }
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = makeWindowMenu()
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        let helpMenu = makeMenu(.help)
        helpItem.submenu = helpMenu
        main.addItem(helpItem)
        NSApp.helpMenu = helpMenu
        return main
    }

    static func makeAppMenu() -> NSMenu {
        let menu = NSMenu(title: "PuggleDocs")
        menu.addItem(item("About PuggleDocs", #selector(AppDelegate.showAboutWindow(_:))))
        menu.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(services)
        menu.addItem(.separator())
        menu.addItem(item("Hide PuggleDocs", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit PuggleDocs", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    static func makeWindowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    static func makeMenu(_ kind: MenuKind) -> NSMenu {
        let menu = NSMenu(title: kind.rawValue)
        let items: [NSMenuItem]
        switch kind {
        case .file: items = fileItems()
        case .edit: items = editItems()
        case .view: items = viewItems()
        case .insert: items = insertItems()
        case .format: items = formatItems()
        case .tools: items = toolsItems()
        case .help: items = helpItems()
        }
        items.forEach(menu.addItem)
        return menu
    }

    private static func fileItems() -> [NSMenuItem] {
        let download = DownloadFormat.allCases.enumerated().map { index, format in
            item(format.displayName, #selector(DocumentCommands.pdDownload(_:)), tag: index)
        }
        return [
            item("New document", #selector(NSDocumentController.newDocument(_:)), "n", symbol: "doc.badge.plus"),
            item("Open…", #selector(NSDocumentController.openDocument(_:)), "o", symbol: "folder"),
            .separator(),
            item("Make a copy", #selector(NSDocument.duplicate(_:)), "s", [.command, .shift], symbol: "plus.square.on.square"),
            .separator(),
            item("Save", #selector(NSDocument.save(_:)), "s", symbol: "square.and.arrow.down"),
            submenu("Download", symbol: "arrow.down.to.line", download),
            item("Rename", #selector(DocumentCommands.pdRename(_:)), symbol: "pencil"),
            item("Move…", #selector(NSDocument.move(_:)), symbol: "folder.badge.gearshape"),
            .separator(),
            submenu("Version history", symbol: "clock.arrow.circlepath", [
                item("See version history", #selector(NSDocument.browseVersions(_:))),
                item("Revert to last saved", #selector(NSDocument.revertToSaved(_:))),
            ]),
            .separator(),
            item("Page setup", #selector(DocumentCommands.pdPageSetup(_:)), "p", [.command, .shift], symbol: "doc.text"),
            item("Print", #selector(NSDocument.printDocument(_:)), "p", symbol: "printer"),
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ]
    }

    private static func editItems() -> [NSMenuItem] {
        let find = item("Find", #selector(DocumentCommands.pdFind(_:)), "f", symbol: "magnifyingglass")
        let replace = item("Find and replace", #selector(DocumentCommands.pdFindAndReplace(_:)), "h", [.command, .shift])
        let findNext = item("Find next", #selector(DocumentCommands.pdFindNext(_:)), "g")
        let findPrevious = item("Find previous", #selector(DocumentCommands.pdFindPrevious(_:)), "g", [.command, .shift])
        return [
            item("Undo", Selector(("undo:")), "z", symbol: "arrow.uturn.backward"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift], symbol: "arrow.uturn.forward"),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x", symbol: "scissors"),
            item("Copy", #selector(NSText.copy(_:)), "c", symbol: "doc.on.doc"),
            item("Paste", #selector(NSText.paste(_:)), "v", symbol: "doc.on.clipboard"),
            item("Paste without formatting", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .shift]),
            item("Delete", #selector(NSText.delete(_:)), symbol: "trash"),
            .separator(),
            item("Select all", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            find, replace, findNext, findPrevious,
            .separator(),
            item("Emoji & Symbols", #selector(NSApplication.orderFrontCharacterPalette(_:)), " ", [.command, .control]),
        ]
    }

    private static func viewItems() -> [NSMenuItem] {
        let modes = EditingMode.allCases.enumerated().map { index, mode in
            item(mode.title, #selector(DocumentCommands.pdSetMode(_:)), tag: index, symbol: mode.symbol)
        }
        return [
            submenu("Mode", symbol: "pencil", modes),
            .separator(),
            item("Show ruler", #selector(DocumentCommands.pdToggleRuler(_:))),
            item("Show outline", #selector(DocumentCommands.pdToggleOutline(_:)), "a", [.command, .option]),
            item("Show non-printing characters", #selector(DocumentCommands.pdToggleInvisibles(_:)), "p", [.command, .control]),
            item("Comment history", #selector(DocumentCommands.pdCommentHistory(_:)), "a", [.command, .option, .shift], symbol: "text.bubble"),
            .separator(),
            item("Zoom in", #selector(DocumentCommands.pdZoomIn(_:)), "="),
            item("Zoom out", #selector(DocumentCommands.pdZoomOut(_:)), "-"),
            item("Actual size", #selector(DocumentCommands.pdActualSize(_:)), "0"),
            item("Fit to window", #selector(DocumentCommands.pdZoomToFit(_:))),
            .separator(),
            item("Full screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]
    }

    private static func insertItems() -> [NSMenuItem] {
        [
            submenu("Image", symbol: "photo", [
                item("Upload from computer…", #selector(DocumentCommands.pdInsertImage(_:))),
            ]),
            item("Table…", #selector(DocumentCommands.pdInsertTable(_:)), symbol: "tablecells"),
            item("Link", #selector(DocumentCommands.pdInsertLink(_:)), "k", symbol: "link"),
            item("Comment", #selector(DocumentCommands.pdInsertComment(_:)), "m", [.command, .option], symbol: "plus.bubble"),
            submenu("Break", symbol: "text.insert", [
                item("Page break", #selector(DocumentCommands.pdInsertPageBreak(_:)), "\r"),
            ]),
            .separator(),
            submenu("Headers & footers", symbol: "rectangle.topthird.inset.filled", [
                item("Header", #selector(DocumentCommands.pdEditHeader(_:))),
                item("Footer", #selector(DocumentCommands.pdEditFooter(_:))),
            ]),
            submenu("Page numbers", symbol: "number", [
                item("Top of page, right", #selector(DocumentCommands.pdInsertPageNumber(_:)), tag: 0),
                item("Bottom of page, right", #selector(DocumentCommands.pdInsertPageNumber(_:)), tag: 1),
                item("Bottom of page, center", #selector(DocumentCommands.pdInsertPageNumber(_:)), tag: 2),
                .separator(),
                item("Page count", #selector(DocumentCommands.pdInsertPageCount(_:))),
            ]),
            item("Special characters", #selector(NSApplication.orderFrontCharacterPalette(_:)), symbol: "character.textbox"),
        ]
    }

    private static func formatItems() -> [NSMenuItem] {
        let text = submenu("Text", symbol: "bold", [
            item("Bold", #selector(DocumentCommands.pdToggleBold(_:)), "b", symbol: "bold"),
            item("Italic", #selector(DocumentCommands.pdToggleItalic(_:)), "i", symbol: "italic"),
            item("Underline", #selector(DocumentCommands.pdToggleUnderline(_:)), "u", symbol: "underline"),
            item("Strikethrough", #selector(DocumentCommands.pdToggleStrikethrough(_:)), "x", [.command, .shift], symbol: "strikethrough"),
            item("Superscript", #selector(DocumentCommands.pdSuperscript(_:)), ".", symbol: "textformat.superscript"),
            item("Subscript", #selector(DocumentCommands.pdSubscript(_:)), ",", symbol: "textformat.subscript"),
            .separator(),
            submenu("Size", [
                item("Increase font size", #selector(DocumentCommands.pdIncreaseFontSize(_:)), ".", [.command, .shift]),
                item("Decrease font size", #selector(DocumentCommands.pdDecreaseFontSize(_:)), ",", [.command, .shift]),
            ]),
            submenu("Capitalization", [
                item("lowercase", #selector(DocumentCommands.pdLowercase(_:))),
                item("UPPERCASE", #selector(DocumentCommands.pdUppercase(_:))),
                item("Title Case", #selector(DocumentCommands.pdTitleCase(_:))),
            ]),
        ])
        let styles = submenu("Paragraph styles", symbol: "textformat.size", NamedStyle.allCases.enumerated().map { index, style in
            if let digit = style.shortcutDigit {
                return item(style.displayName, #selector(DocumentCommands.pdApplyStyle(_:)), digit, [.command, .option], tag: index)
            }
            return item(style.displayName, #selector(DocumentCommands.pdApplyStyle(_:)), tag: index)
        })
        let align = submenu("Align & indent", symbol: "text.alignleft", [
            item("Left", #selector(DocumentCommands.pdAlign(_:)), "l", [.command, .shift], tag: 0, symbol: "text.alignleft"),
            item("Center", #selector(DocumentCommands.pdAlign(_:)), "e", [.command, .shift], tag: 1, symbol: "text.aligncenter"),
            item("Right", #selector(DocumentCommands.pdAlign(_:)), "r", [.command, .shift], tag: 2, symbol: "text.alignright"),
            item("Justified", #selector(DocumentCommands.pdAlign(_:)), "j", [.command, .shift], tag: 3, symbol: "text.justify"),
            .separator(),
            item("Increase indent", #selector(DocumentCommands.pdIncreaseIndent(_:)), "]", symbol: "increase.indent"),
            item("Decrease indent", #selector(DocumentCommands.pdDecreaseIndent(_:)), "[", symbol: "decrease.indent"),
        ])
        let spacing = submenu("Line & paragraph spacing", symbol: "arrow.up.and.down.text.horizontal", lineSpacingItems())
        let lists = submenu("Bullets & numbering", symbol: "list.bullet", [
            item("Bulleted list", #selector(DocumentCommands.pdBulletedList(_:)), "8", [.command, .shift], symbol: "list.bullet"),
            item("Numbered list", #selector(DocumentCommands.pdNumberedList(_:)), "7", [.command, .shift], symbol: "list.number"),
            item("Checklist", #selector(DocumentCommands.pdChecklist(_:)), "9", [.command, .shift], symbol: "checklist"),
        ])
        return [
            text, styles, align, spacing, lists,
            .separator(),
            item("Clear formatting", #selector(DocumentCommands.pdClearFormatting(_:)), "\\", symbol: "textformat"),
            .separator(),
            item("Image options…", #selector(DocumentCommands.pdImageOptions(_:)), symbol: "photo"),
            submenu("Table", symbol: "tablecells", tableItems()),
            submenu("Headers & footers", symbol: "rectangle.topthird.inset.filled", [
                item("Different first page", #selector(DocumentCommands.pdToggleDifferentFirstPage(_:))),
                .separator(),
                item("Remove header", #selector(DocumentCommands.pdRemoveHeader(_:))),
                item("Remove footer", #selector(DocumentCommands.pdRemoveFooter(_:))),
            ]),
            .separator(),
            item("Show fonts", #selector(NSFontManager.orderFrontFontPanel(_:)), "t"),
        ]
    }

    static func tableItems() -> [NSMenuItem] {
        [
            item("Insert row above", #selector(DocumentCommands.pdTableInsertRow(_:)), tag: 0, symbol: "arrow.up.to.line"),
            item("Insert row below", #selector(DocumentCommands.pdTableInsertRow(_:)), tag: 1, symbol: "arrow.down.to.line"),
            item("Insert column left", #selector(DocumentCommands.pdTableInsertColumn(_:)), tag: 0, symbol: "arrow.left.to.line"),
            item("Insert column right", #selector(DocumentCommands.pdTableInsertColumn(_:)), tag: 1, symbol: "arrow.right.to.line"),
            .separator(),
            item("Delete row", #selector(DocumentCommands.pdTableDeleteRow(_:)), symbol: "minus.rectangle"),
            item("Delete column", #selector(DocumentCommands.pdTableDeleteColumn(_:))),
            item("Delete table", #selector(DocumentCommands.pdTableDelete(_:)), symbol: "trash"),
            .separator(),
            item("Table properties…", #selector(DocumentCommands.pdTableProperties(_:)), symbol: "tablecells.badge.ellipsis"),
        ]
    }

    static func lineSpacingItems() -> [NSMenuItem] {
        [
            item("Single", #selector(DocumentCommands.pdLineSpacing(_:)), tag: 100),
            item("1.15", #selector(DocumentCommands.pdLineSpacing(_:)), tag: 115),
            item("1.5", #selector(DocumentCommands.pdLineSpacing(_:)), tag: 150),
            item("Double", #selector(DocumentCommands.pdLineSpacing(_:)), tag: 200),
            .separator(),
            item("Add space before paragraph", #selector(DocumentCommands.pdToggleSpaceBefore(_:))),
            item("Add space after paragraph", #selector(DocumentCommands.pdToggleSpaceAfter(_:))),
            .separator(),
            item("Custom spacing…", #selector(DocumentCommands.pdCustomSpacing(_:))),
        ]
    }

    private static func toolsItems() -> [NSMenuItem] {
        [
            submenu("Spelling and grammar", symbol: "textformat.abc.dottedunderline", [
                item("Check spelling and grammar", #selector(NSText.showGuessPanel(_:)), ":"),
                item("Check document now", #selector(NSText.checkSpelling(_:)), ";"),
                .separator(),
                item("Show spelling and grammar suggestions", #selector(DocumentCommands.pdToggleSpellCheck(_:))),
                item("Correct spelling automatically", #selector(NSTextView.toggleAutomaticSpellingCorrection(_:))),
            ]),
            item("Word count", #selector(DocumentCommands.pdWordCount(_:)), "c", [.command, .shift], symbol: "number"),
            submenu("Review suggested edits", symbol: "pencil.line", [
                item("Accept all", #selector(DocumentCommands.pdAcceptAllSuggestions(_:)), symbol: "checkmark"),
                item("Reject all", #selector(DocumentCommands.pdRejectAllSuggestions(_:)), symbol: "xmark"),
            ]),
            item("Display word count while typing", #selector(DocumentCommands.pdToggleWordCount(_:))),
            .separator(),
            submenu("Preferences", symbol: "gearshape", [
                item("Use smart quotes", #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:))),
                item("Use smart dashes", #selector(NSTextView.toggleAutomaticDashSubstitution(_:))),
                item("Automatically detect links", #selector(NSTextView.toggleAutomaticLinkDetection(_:))),
                item("Use text replacements", #selector(NSTextView.toggleAutomaticTextReplacement(_:))),
                item("Smart copy and paste", #selector(NSTextView.toggleSmartInsertDelete(_:))),
            ]),
            .separator(),
            submenu("Speech", symbol: "waveform", [
                item("Start speaking", #selector(NSTextView.startSpeaking(_:))),
                item("Stop speaking", #selector(NSTextView.stopSpeaking(_:))),
            ]),
        ]
    }

    private static func helpItems() -> [NSMenuItem] {
        [item("Keyboard shortcuts", #selector(DocumentCommands.pdShowShortcuts(_:)), "/", symbol: "keyboard")]
    }
}
