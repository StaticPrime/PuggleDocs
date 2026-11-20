# PuggleDocs

**Write anything, beautifully.**

PuggleDocs is a full word processor for the Mac, with real pages, rulers and styles. If you've used an online word processor, you'll feel right at home, and your writing never leaves your Mac unless you share it.

- Paged editing with styles, lists, tables, images and links
- Comments and suggesting mode, kept as Word comments and tracked changes
- Collaborate live with other Mac users through iCloud, each person able to edit or only comment
- Headers, footers, page numbers and a clickable outline
- Find and replace, live word count, autosave and version history

It opens and saves Word (.docx), OpenDocument (.odt), Rich Text (.rtf), Markdown (.md), web page (.html) and plain text (.txt) files, and exports PDF and EPUB.

PuggleDocs is free, needs no account of its own and has no tracking. It runs inside Apple's app sandbox with no permission to use the network (macOS takes the documents you share to and from iCloud for it), on macOS 14 Sonoma or later with Apple silicon or Intel. It's written in Swift with AppKit, TextKit and SwiftUI, and is part of the PuggleSoft family with [PuggleSheets](https://github.com/StaticPrime/PuggleSheets) and [PuggleSlides](https://github.com/StaticPrime/PuggleSlides).

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

### Collaboration

- **Collaborate.** The Collaborate button in the header, left of Download (or File ▸ Collaborate…, ⌥⌘C), which only a document's owner has, shares a document with other people who use PuggleDocs on their Macs, through iCloud. A document is kept on your Mac first: one that has never been saved asks where, and that file stays yours. Invite Collaborators sends the link by Messages, Mail or AirDrop, where you choose whether the people you invite can make changes; or choose Anyone with the Link, whether those people can edit or only comment, and Copy Link to pass it on yourself. Whoever clicks the link joins, and the document opens for them in PuggleDocs. If clicking it opens a web page instead, copy the link and choose File ▸ Shared documents ▸ Open Invitation Link….
- **Editing together.** Everyone's changes show on everyone else's Mac as they're made, typing, formatting, tables, images, headers and footers, and page setup, a moment after each change and every couple of seconds while someone else has it open. Two people typing at once both keep what they typed. Undo and Redo take back only your own changes, wherever other people's have moved them to. When the owner renames the document, its new name shows for everyone who has it open.
- **Who's here.** Everyone who has opened it shows as a round badge with their initials in the header, with a green dot while they have it open. Each person's Mac says who they are when they open it, so names show even when iCloud doesn't give them. Click a badge to see their name, their email address or phone number when iCloud says it, whether they own it, edit or comment, and when they were last there.
- **Edit or comment.** In the Collaborate sheet the owner sets, person by person, whether each can edit or only comment, and can take anyone out. People who can only comment see every change as it's made, and add comments and replies (Commenting mode), but can't change the text: iCloud itself turns their changes down. Everyone can print a shared document, save a copy of it on their Mac (File ▸ Save, Make a copy, or Download), whatever they can do.
- **Comments.** Comments, replies and resolving go to everyone, anchored to their text however it's been edited since. People edit and delete their own comments; people who can edit can delete anyone's.
- **Notifications.** When someone changes a shared document and then does nothing more to it for two minutes, everyone else gets one notification summing it up ("Ana Lopez edited “Plan”: added about 120 words, changed the formatting and added a comment"), not one for every change, even when PuggleDocs isn't open. Clicking it opens the document.
- **Stopping.** Stop Sharing… in the Collaborate sheet takes the document out of your iCloud and from everyone it was shared with, and keeps it on your Mac, saved as it was. Anyone who has it open sees it go at once, with a note saying you stopped sharing it. People can also leave a document shared with them, with File ▸ Leave shared document…. File ▸ Shared documents lists the documents shared with you and those you share.

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
- Collaborating goes through iCloud, so it needs an iCloud account, for you and for everyone you share with, and a copy of PuggleDocs signed to use it (see Sharing through iCloud); when it can't, the Collaborate sheet says why. Changes made at the same moment are merged character by character; formatting both people change on the same words at once ends as one of them made it.
- A shared document opens from iCloud, so it needs the connection to open. Changes made while iCloud can't be reached are kept and sent when it's back; closing the document before then asks first. While a document is shared, its copy in iCloud is the one that counts: the file on the owner's Mac follows it, and changes made to that file in other apps are replaced.
- Notifications reach people once they've opened the shared document in PuggleDocs, and macOS asks once whether PuggleDocs may show them. Sharing a document clears its undo history up to then.

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

The app is sandboxed. Debug builds are signed to run on the Mac that built them, unless `Config/Signing.xcconfig` names a team (see Sharing from Xcode below); releases are signed by `Tools/make-installer.sh`.

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
| `DEVELOPER_ID_PROFILE_BASE64` | The Developer ID provisioning profile for iCloud, base64-encoded (see below), which released copies need to collaborate. A signed release stops without it |

### Sharing through iCloud

Shared documents are kept in iCloud, in the container `iCloud.com.pugglesoft.PuggleDocs`, so only a copy of PuggleDocs signed for that container can share them. Any other copy, like one built from a fresh clone, says so in the Collaborate sheet; debug runs can collaborate through a stand-in for iCloud on the Mac instead (see Tests). To set it up, once:

1. In the Apple Developer account, under Certificates, Identifiers & Profiles ▸ Identifiers, register the iCloud container `iCloud.com.pugglesoft.PuggleDocs`. Then edit the App ID `com.pugglesoft.PuggleDocs`: turn on iCloud, with CloudKit and that container, and Push Notifications.
2. Under Profiles, make a Developer ID provisioning profile for that App ID and the Developer ID Application certificate, and download it.
3. Make the container's schema. iCloud's development environment adds record types as they're first saved, but production only takes what's deployed to it. Either collaborate once from Xcode in the development environment with two iCloud accounts (see Sharing from Xcode below), or add the types by hand in CloudKit Console's development environment, then deploy the schema to production:

   | Record type | Fields |
   | --- | --- |
   | `Document` | `info` (Bytes), `revision` (Int64), `snapshot` (Asset) |
   | `Change` | `revision` (Int64), `changeID` (String), `author` (String), `authorName` (String), `change` (Bytes), `changeFile` (Asset, for very large changes like a pasted photo) |
   | `Comment` | `info` (Bytes) |
   | `Presence` | `info` (Bytes) |
   | `Notice` | `title`, `body`, `document`, `owner`, `author` (all String); give `recordName` a Queryable index |

   iCloud's own record of a share, `cloudkit.share`, only appears in the development schema once a share has been saved there, so share one document in the development environment before deploying.
4. Add the profile to the repository as the secret `DEVELOPER_ID_PROFILE_BASE64` (`base64 -i PuggleDocs.provisionprofile | pbcopy`). To build a signed installer on your Mac instead, set `DEVELOPER_ID_PROFILE` to the profile's path along with the Developer ID variables before running `Tools/make-installer.sh`.

`Tools/make-installer.sh` then puts the profile inside the app and signs it for the container, the production environment and pushes. To try collaborating, install it on two Macs signed in to different iCloud accounts.

#### Sharing from Xcode

A debug build can collaborate too, once it's signed with the team. Make `Config/Signing.xcconfig` (Git ignores it) with your team's ID:

```
DEVELOPMENT_TEAM = ABCDE12345
CODE_SIGN_IDENTITY = Apple Development
CODE_SIGN_ENTITLEMENTS = Config/iCloud.entitlements
```

Add an Apple ID in that team under Xcode ▸ Settings ▸ Accounts, then build: Xcode makes the development certificate and provisioning profile itself (the App ID needs iCloud and Push Notifications turned on first, as in step 1). Set the team in that file rather than under *Signing & Capabilities*, which would write it into the project for everyone. Debug builds use iCloud's production environment, as installed copies do, so a document shared from Xcode reaches someone who installed PuggleDocs. Production only takes the kinds of records already deployed to it: when PuggleDocs starts saving a new kind, and once at the start, add `ICLOUD_ENVIRONMENT = Development` to `Config/Signing.xcconfig`, collaborate on a document, deploy the schema to production in CloudKit Console, and take the line out again. `Config/iCloud.entitlements` is `PuggleDocs/PuggleDocs.entitlements` with iCloud's added, so keep the two alike.

While debug builds use the development environment, everyone collaborating has to run a debug build too, since installed copies use production: another Mac building from Xcode with the same `Config/Signing.xcconfig` (Xcode registers it the first time), or a second account on the same Mac, signed in to another iCloud account, running a copy of the debug build. In a fresh development environment the first summary notification someone is sent adds the kind of record notifications need, so it isn't shown; the ones after it are. Anything iCloud turns down is written to the Mac's log under the Collaboration category, which Xcode's console shows.

## Tests

The document model, file formats and the engine that keeps shared documents the same on every Mac live in a Swift package with unit tests (thousands of random changes made at the same time ending the same, three simulated Macs editing one document through its log, every round of editing recorded and undone exactly, tables staying whole on another Mac):

```sh
cd Packages/PuggleDocsKit && swift test
```

Debug builds also include an end-to-end check that drives the real editor and prints `SELFTEST PASS/FAIL` lines. It covers typing, lists, styles, undo, copy/paste, page breaks, links, images, tables, headers and footers, find and replace, the outline, printing, PDF export, live word count, comments, suggesting mode, and DOCX/ODT/RTF/HTML round trips:

```sh
build/DerivedData/Build/Products/Debug/PuggleDocs.app/Contents/MacOS/PuggleDocs -PDSelfTest YES
```

A second suite checks collaboration end to end on a stand-in for iCloud, with simulated people on other "Macs": sharing a document (saved first), inviting one person to edit and one to comment, their Mac opening it with the same text, typing both ways, typing at the same time ending the same, bold text and a table arriving whole, undo and redo taking back only this Mac's typing, the badges and who's viewing, comments, replies and resolving both ways (and undoing a resolve keeping a reply that came meanwhile), taking someone down to commenting (their changes turned down, their comments still arriving), one summary notification after a quiet spell and a fresh one for what's new since, stopping sharing (the document kept here, gone for the others), and a document someone else shares opening read-only (comments allowed, typing changing nothing, their edits arriving live, printing, downloading and copying allowed, and the window saying so and closing when they stop sharing):

```sh
build/DerivedData/Build/Products/Debug/PuggleDocs.app/Contents/MacOS/PuggleDocs -PDSelfTest YES -PDSelfTestSuite collaboration
```

Other debug launch arguments: `-PDSampleDocument YES` fills new documents with sample content. `-PDSnapshot name.png` saves a screenshot of the first window (or its open sheet) to the app's temporary folder and quits. Combine it with `-PDWindowWidth`, `-PDZoom`, `-PDPageColor RRGGBB`, `-PDOpenSheet pageSetup|wordCount|customSpacing|tableProperties|shortcuts`, `-PDExportPDF name.pdf`, `-PDOpenEditable YES` (when opening a PDF), `-PDFind word`, `-PDShowLink editor|preview`, `-PDInsertTestImage YES`, `-PDInsertTestTable YES`, `-PDHeaderFooter YES`, `-PDShowTablePicker YES`, `-PDShowOutline YES`, `-PDShowAbout YES` or `-PDComments sample|active|draft|selection|history|suggestions` (example comments and suggestions in the sample document) to check layouts. `-PDStandInCloud YES` collaborates through the stand-in for iCloud, and with `-PDCollaborationDemo YES` too the window's document is shared with two simulated people who open it, type and comment (add `-PDOpenSheet collaborate` for the Collaborate sheet).

## Project layout

```
PuggleDocs/                 macOS app target (files are picked up automatically by Xcode)
  App/                      Entry point, app delegate, debug-only sample and self-tests
  Collaboration/            Sharing through iCloud: each shared document's session, iCloud, the Collaborate sheet, the
                            badges, and a stand-in for iCloud for debug runs
  Document/                 PuggleDocument (editable documents) and PDFViewerDocument (PDF viewer)
  Editor/                   Paged text system, list rendering, typing behaviours, commands
  UI/                       Window controllers, SwiftUI header and toolbar, ruler, menus, dialogs
  Resources/                Asset catalog (app icon, About window logo)
Packages/PuggleDocsKit/     Document model, formatting engine and file formats (no UI)
  Model/                    Named styles, list items, page setup, colour palette, comments, suggestions
  Formatting/               Character, paragraph, style and list operations; list numbering
  IO/                       DOCX and ODT (ZIP + XML), HTML, Markdown, RTF and plain-text codecs, EPUB, clipboard archive
  Collaboration/            Changes to rich text, recording them, a shared document's log, its iCloud records, summaries
Config/                     Signing for debug builds (see Sharing from Xcode)
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
- **Collaboration.** A shared document is two zones in its owner's iCloud. The document zone holds a snapshot of the whole document now and then, and its log: one record per revision, each one change, named for its revision so that only one change can ever take it. Each Mac sends its changes one at a time, claiming the revision after the last it knows; when another Mac got there first, it applies that change and rewrites its own to follow it (operational transformation over rich text: keep, insert, delete and restyle, with each attribute's value encoded), so every Mac ends with the same text. That zone is shared with each person as edit or read-only, so iCloud itself refuses changes from people who may only comment. The talk zone, which everyone in the document can write to through a link kept in the document zone, holds the comments (each anchored to a range at a revision of the log) and who has it open. Changes are recorded by the text storage itself, a subclass that notes what each round of editing inserted, deleted or restyled, however it was done, along with the change that undoes it; while a document is shared, undo steps are those changes, rewritten as other people's arrive. Tables travel with identifiers, so a table typed into on another Mac stays one table. Each person's Mac also keeps an inbox zone shared by link with the people they work with, who leave a short summary there after a quiet spell; a subscription on it makes iCloud show the notification.

## Contributing

Bug reports, ideas and pull requests are welcome. Before your first pull request is merged, you sign the [PuggleSoft Contributor License Agreement](CLA.md) by posting one comment, and a bot walks you through it. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Copyright © 2026 PuggleSoft.

PuggleDocs is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License, version 3, as published by the Free Software Foundation. It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See [LICENSE](LICENSE) for the full terms.
