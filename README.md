# PuggleDocs

**Write anything, beautifully.**

PuggleDocs is a full word processor for the Mac, with real pages, rulers and styles. If you've used an online word processor, you'll feel right at home, and your writing never leaves your Mac.

- Paged editing with styles, lists, tables, images and links
- Comments and suggesting mode, kept as Word comments and tracked changes
- Headers, footers, page numbers and a clickable outline
- Find and replace, live word count, autosave and version history

It opens and saves Word (.docx), OpenDocument (.odt), Rich Text (.rtf), Markdown (.md), web page (.html) and plain text (.txt) files, and exports PDF and EPUB.

PuggleDocs is free, needs no account and has no tracking. It runs inside Apple's app sandbox with no permission to use the network, on macOS 14 Sonoma or later with Apple silicon or Intel. It's written in Swift with AppKit, TextKit and SwiftUI, and is part of the PuggleSoft family with [PuggleSheets](https://github.com/StaticPrime/PuggleSheets) and [PuggleSlides](https://github.com/StaticPrime/PuggleSlides).

## Features

### Writing and formatting

- **Paged editor.** Real pages (Letter or A4 by region), 1″ margins, page breaks (⌘↩), zoom from 50% to 200% plus Fit, and a ruler with draggable indents and margins.
- **Familiar chrome.** A header row next to the window buttons with an editable document title, a format badge (`.DOCX`) and save status, and the rounded formatting toolbar beneath it. The File, Edit, View, Insert, Format, Tools and Help menus are in the macOS menu bar. Toolbar groups collapse into an overflow menu in narrow windows.
- **Formatting.** Paragraph styles (Normal text, Title, Subtitle, Heading 1–6) with the familiar defaults (Arial 11, 1.15 line spacing). Also fonts, font size, bold, italic, underline, strikethrough, superscript and subscript, text and highlight colours, alignment, line and paragraph spacing, indents, paint format, capitalisation and clear formatting.
- **Lists.** Bulleted, numbered and checklist lists with several marker styles each. Return continues a list, Return on an empty item ends it, Tab and Shift-Tab change the level, and Backspace removes the marker. Typing `* `, `- `, `1. `, `1) `, `A. `, `I. ` or `[] ` starts a list. Clicking a checkbox ticks it.
- **Page setup.** File ▸ Page setup (⇧⌘P) sets orientation, paper size, page colour and margins, with **Set as default** for new documents.

### Tables, images and links

- **Tables.** Insert ▸ Table opens a hover grid. Tab and Shift-Tab move between cells, and Tab in the last cell adds a row. Rows and columns can be inserted and deleted, and Table properties sets borders, cell colour and even column widths (Format ▸ Table or the right-click menu). Tables, including merged cells, are kept in DOCX, ODT, HTML and RTF.
- **Images.** Insert from a file, paste or drag them in. Click an image to select it, drag the handles to resize, or set an exact size in Image options. Images are saved in DOCX, ODT, HTML and RTF.
- **Links.** ⌘K inserts or edits a link. Clicking a link shows a preview to open, copy, edit or remove it.
- **Headers and footers.** Double-click the top or bottom margin (or use Insert ▸ Headers & footers) to edit them. Insert ▸ Page numbers adds page numbers, and a page count field is available. "Different first page" leaves the first page blank. Headers and footers are saved in DOCX, ODT and HTML.

### Tools

- **Find and replace.** ⌘F opens a find box that counts and highlights matches on every page. ⇧⌘H adds Replace and Replace all, with match case, regular expressions and ignore diacritics.
- **Document outline.** View ▸ Show outline (⌥⌘A) lists the title and headings. Click one to jump to it.
- **Live word count.** Tick "Display word count while typing" in Tools ▸ Word count to show a floating box with words, characters or pages ("12 of 345 words" for a selection).

### Comments and suggestions

- **Comments.** Select text and choose Insert ▸ Comment (⌥⌘M), the toolbar's comment button, the right-click menu or the round button that appears beside a selection. Comments appear as cards beside the page, lined up with their text, which is highlighted (darker for the open comment). Reply, resolve and re-open, edit and delete (⋮). In the comment box Return adds a line, ⌘Return posts and Esc cancels. The comment history button in the header (⇧⌥⌘A) lists every comment, resolved ones included, and sets the name your comments are signed with. Comments are saved in DOCX using Word's comment parts (with replies and resolved state), in ODT and in HTML. Highlights never print.
- **Suggesting mode.** Switch the mode menu to Suggesting: what you type appears in your colour and what you delete is struck through, without changing the text until someone accepts it. Each suggestion gets a card with accept (✓) and reject (✗), and Tools ▸ Review suggested edits accepts or rejects them all. Suggestions are saved as tracked changes in DOCX and ODT and as `<ins>`/`<del>` in HTML, and Word's tracked changes open as suggestions.

### Files and output

- **Word, Rich Text and plain text.** Open and save **.docx** (own reader and writer: styles, numbering, links, highlights, page size and margins), **.rtf** and **.txt**. Files that contain things PuggleDocs can't keep open as an untitled copy with a notice, so the original is never overwritten with a lossy version.
- **OpenDocument and web pages.** Open and save **OpenDocument (.odt)** and **web pages (.html)**, both with their own readers and writers. Headings stay real headings, lists keep their numbering, and page size, margins and colour are stored. The HTML reader also understands the HTML that online word processors export.
- **Markdown.** Open and save **.md** files: headings, bold, italic, strikethrough, code, links, nested lists, task lists, quotes, code blocks and tables. Pictures are embedded. Files that link to pictures elsewhere open as a copy, so the original isn't overwritten.
- **PDF.** File ▸ Download ▸ PDF Document (.pdf) keeps the page size, page colour and clickable links. PDFs open in a viewer window with page thumbnails, zoom and printing. **Open as editable document** copies the PDF's text into a new document and rebuilds bulleted and numbered lists.
- **EPUB.** File ▸ Download ▸ EPUB Publication (.epub) makes an EPUB 3 book with a table of contents built from the headings.
- **Download** offers Word, OpenDocument, Rich Text, PDF, Plain Text, Web Page, EPUB and Markdown, in that order.
- **macOS integration.** Autosave, version history (File ▸ Version history), Make a copy, Move, printing, spelling and grammar checking, smart quotes and dashes, and copy/paste between PuggleDocs windows and other apps.

Help ▸ Keyboard shortcuts (⌘/) lists every keyboard shortcut.

## Known limits

- In Suggesting mode, formatting changes and edits to headers and footers apply directly rather than as suggestions.
- ODT and HTML keep suggested insertions and deletions, but a suggested paragraph break is saved as an ordinary one.
- Rich Text, plain text and Markdown can't store comments or suggestions: comments are left out and suggestions are saved as accepted text (PuggleDocs says so when it matters).

## Requirements

- macOS 14 Sonoma or later
- Xcode 16 or later (developed with Xcode 27.2, Swift 6)

## Building and running

Open `PuggleDocs.xcodeproj` in Xcode and run the **PuggleDocs** scheme. Or, from the command line:

```sh
xcodebuild -project PuggleDocs.xcodeproj -scheme PuggleDocs -configuration Debug \
  -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/PuggleDocs.app
```

The app is sandboxed and signs locally ("Sign to Run Locally"). To distribute it, set your team under *Signing & Capabilities*.

### Installer

```sh
Tools/make-installer.sh
```

This builds `build/PuggleDocs.pkg`, which installs PuggleDocs.app in /Applications for all users (macOS asks for an administrator's password). The app runs on Apple silicon and Intel Macs with macOS 14 or later.

A local build is ad-hoc signed and the installer is unsigned. That's fine on the Mac that built it, but a copy that arrives by download, email or AirDrop is blocked the first time: the user has to click **Open Anyway** in System Settings ▸ Privacy & Security. To sign with a Developer ID and have Apple notarize the installer, set the variables described at the top of `Tools/make-installer.sh` before running it. Releases built on GitHub are signed and notarized this way when the repository has the Developer ID secrets (see below).

### Releasing a new version

Versions are MAJOR.MINOR.FIX. To release the next one, run this on `main`, up to date with GitHub and with everything committed:

```sh
Tools/release.sh            # a fix:          1.2.3 → 1.2.4
Tools/release.sh minor      # a minor update: 1.2.3 → 1.3.0
Tools/release.sh major      # a major update: 1.2.3 → 2.0.0
```

The script raises the version and the build number in the Xcode project, commits "Release version 1.2.4", tags it `v1.2.4` and pushes both. The tag starts the Release workflow on GitHub, which runs the package tests, builds the installer with `Tools/make-installer.sh` and publishes it as a GitHub release. The installer keeps the same name in every release, so https://github.com/StaticPrime/PuggleDocs/releases/latest/download/PuggleDocs.pkg always downloads the newest one. `Tools/release.sh --dry-run` shows the next version without changing anything.

To sign and notarize releases, add these secrets under the repository's Settings ▸ Secrets and variables ▸ Actions. Without them, releases are published unsigned, with a warning on the run.

| Secret | What it holds |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | A .p12 file with the "Developer ID Application" and "Developer ID Installer" certificates and their private keys, base64-encoded (`base64 -i DeveloperID.p12 \| pbcopy`) |
| `DEVELOPER_ID_P12_PASSWORD` | The .p12 file's password |
| `NOTARY_API_KEY` | The text of an App Store Connect API key file (`AuthKey_….p8`), used to notarize |
| `NOTARY_KEY_ID` | That key's ID |
| `NOTARY_ISSUER_ID` | The issuer ID shown above the keys in App Store Connect |

## Tests

The document model and file formats live in a Swift package with unit tests:

```sh
cd Packages/PuggleDocsKit && swift test
```

Debug builds also include an end-to-end check that drives the real editor and prints `SELFTEST PASS/FAIL` lines. It covers typing, lists, styles, undo, copy/paste, page breaks, links, images, tables, headers and footers, find and replace, the outline, printing, PDF export, live word count, comments, suggesting mode, and DOCX/ODT/RTF/HTML round trips:

```sh
build/DerivedData/Build/Products/Debug/PuggleDocs.app/Contents/MacOS/PuggleDocs -PDSelfTest YES
```

Other debug launch arguments: `-PDSampleDocument YES` fills new documents with sample content. `-PDSnapshot name.png` saves a screenshot of the first window (or its open sheet) to the app's temporary folder and quits. Combine it with `-PDWindowWidth`, `-PDZoom`, `-PDPageColor RRGGBB`, `-PDOpenSheet pageSetup|wordCount|customSpacing|tableProperties|shortcuts`, `-PDExportPDF name.pdf`, `-PDOpenEditable YES` (when opening a PDF), `-PDFind word`, `-PDShowLink editor|preview`, `-PDInsertTestImage YES`, `-PDInsertTestTable YES`, `-PDHeaderFooter YES`, `-PDShowTablePicker YES`, `-PDShowOutline YES`, `-PDShowAbout YES` or `-PDComments sample|active|draft|selection|history|suggestions` (example comments and suggestions in the sample document) to check layouts.

## Project layout

```
PuggleDocs/                 macOS app target (files are picked up automatically by Xcode)
  App/                      Entry point, app delegate, debug-only sample and self-test
  Document/                 PuggleDocument (editable documents) and PDFViewerDocument (PDF viewer)
  Editor/                   Paged text system, list rendering, typing behaviours, commands
  UI/                       Window controllers, SwiftUI header and toolbar, ruler, menus, dialogs
  Resources/                Asset catalog (app icon, About window logo)
Packages/PuggleDocsKit/     Document model, formatting engine and file formats (no UI)
  Model/                    Named styles, list items, page setup, colour palette, comments, suggestions
  Formatting/               Character, paragraph, style and list operations; list numbering
  IO/                       DOCX and ODT (ZIP + XML), HTML, Markdown, RTF and plain-text codecs, EPUB, clipboard archive
Tools/make-icons.swift      Regenerates the app icon PNGs
Tools/make-installer.sh     Builds the PuggleDocs.pkg installer
Tools/release.sh            Releases the next version (see Releasing a new version)
```

## How it works

- **Pagination.** One `NSTextStorage` and one TextKit 1 `NSLayoutManager` flow through an `NSTextContainer` and `NSTextView` per page. Pages are added and removed as text grows or shrinks. A page break is a form feed character. When it is followed by a paragraph end, the break happens at the paragraph end, so the next page doesn't start with a blank line.
- **"100%" zoom** shows a page at 96 pixels per inch, which matches what browsers use.
- **Lists** are paragraph attributes (`ListItem`: list id, level, marker style, checked state). They are not characters in the text. Markers are drawn by the layout manager, right before each paragraph's text, and numbered across the whole document, so a list keeps counting after an interruption. List items are converted to AppKit `NSTextList`s for RTF and the clipboard, `numbering.xml` for DOCX, `text:list-style` for ODT and nested `ul`/`ol` for HTML.
- **Links** carry real blue, underlined formatting, so they look the same on screen, in print, in PDF and in other apps.
- **Images** are inline text attachments that keep the original image data, so nothing is re-encoded unless a format needs it. A drawing cell renders them at their display size.
- **Tables** are AppKit text tables: each cell's paragraphs carry an `NSTextTableBlock`. `TableModel` reads a table out of the text, edits it, and rebuilds it, which keeps structural changes to a single undoable replacement.
- **Headers and footers** are one text storage each. Every page shows them through its own layout manager, which knows the page number, so page number fields draw the right number on each page.
- **Find** highlights matches with layout-manager temporary attributes, which are never saved or printed.
- **Comments** are a list of threads plus a character attribute naming the threads anchored to each piece of text. The cards are SwiftUI views inside the zoomed page canvas, so they scroll with the pages exactly. Each card's bounds cancel the zoom, so it keeps its size and stays sharp at every zoom level. Undo covers the text and the threads together.
- **Suggestions** are a character attribute (who, when, insertion or deletion). In Suggesting mode, edits are intercepted before they reach the text: deletions become struck-through text and insertions are marked. They're drawn with layout-manager temporary attributes, so the text itself keeps its own formatting. Accepting or rejecting is a single undoable replacement.
- **Paragraph styles** are stored per paragraph (`pdNamedStyle`) and written as real Word styles (`Heading1`, `Title`, …), so headings stay headings in Word and other word processors.
- **Fonts a file asks for but the Mac doesn't have** are shown with a stand-in, and the original name is kept, so it survives saving.

## Contributing

Bug reports, ideas and pull requests are welcome. Before your first pull request is merged, you sign the [PuggleSoft Contributor License Agreement](CLA.md) by posting one comment, and a bot walks you through it. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Copyright © 2026 PuggleSoft.

PuggleDocs is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License, version 3, as published by the Free Software Foundation. It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See [LICENSE](LICENSE) for the full terms.
