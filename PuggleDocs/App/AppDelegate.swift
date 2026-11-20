import AppKit
import CloudKit
import PuggleDocsKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MenuBuilder.makeMainMenu()
        UserDefaults.standard.register(defaults: ["NSFullScreenMenuItemEverywhere": false])
        CollaborationController.shared = CollaborationController(service: makeCollaborationService())
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        CollaborationController.shared.start()
        #if DEBUG
        DebugLaunchOptions.runIfRequested()
        SelfTest.runIfRequested()
        #endif
    }

    /// iCloud, where documents are shared; in debug runs that ask for it, a stand-in for it.
    private func makeCollaborationService() -> CollaborationService {
        #if DEBUG
        if StandInCloud.isRequested { return StandInCollaboration(me: StandInCloud.me, cloud: .shared) }
        #endif
        if CloudKitCollaboration.isEntitled { return CloudKitCollaboration() }
        return UnavailableCollaboration(reason: "Sharing goes through iCloud, which this copy of PuggleDocs isn’t signed to use.")
    }

    // MARK: Shared documents

    /// Joins a document someone shared, from the link they sent, and opens it.
    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        CollaborationController.shared.accept(metadata)
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        CollaborationController.shared.receivedPush(userInfo)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @objc func showAboutWindow(_ sender: Any?) { AboutWindowController.show() }
}

#if DEBUG
/// `-PDComments sample|active|draft|history` adds example comment threads to the sample document.
@MainActor
func addSampleComments(_ controller: DocumentWindowController, mode: String) {
    let editor = controller.editor
    let string = editor.textStorage.string as NSString
    let now = Date()
    let samples: [(String, CommentThread)] = [
        ("familiar layout", CommentThread(author: "Ana Lopez", date: now.addingTimeInterval(-3_600), text: "Should we name the layout we mean here?",
                                          replies: [CommentReply(author: "Ben Carter", date: now.addingTimeInterval(-1_800), text: "Yes, let's say “like an online word processor”.")])),
        ("Look and feel familiar", CommentThread(author: "Ben Carter", date: now.addingTimeInterval(-90_000), text: "Love this goal.")),
        ("File formats", CommentThread(author: "Chen Wu", date: now.addingTimeInterval(-400_000), text: "Does this include EPUB and Markdown?")),
        ("Ship phase one", CommentThread(author: "Ana Lopez", date: now.addingTimeInterval(-500_000), text: "Done!", resolved: true)),
    ]
    var threads: [CommentThread] = []
    for (phrase, thread) in samples {
        let range = string.range(of: phrase)
        guard range.location != NSNotFound else { continue }
        CommentAnchors.add(thread.id, to: editor.textStorage, range: range)
        threads.append(thread)
    }
    editor.document?.comments = threads
    editor.comments.reload()
    switch mode {
    case "active":
        editor.comments.activate(threads.first?.id)
    case "draft":
        let range = string.range(of: "Milestones")
        editor.focus()
        editor.activeTextView.setSelectedRange(range)
        editor.comments.startDraft()
        editor.comments.model.draft?.text = "Can we add dates to these?"
    case "selection":
        editor.focus()
        editor.activeTextView.setSelectedRange(string.range(of: "lightweight word processor"))
    case "history":
        editor.comments.model.showsHistory = true
    case "suggestions":
        // A few edits made in Suggesting mode, with the first suggestion's card open.
        editor.focus()
        controller.pdSetMode(MenuBuilder.item("", nil, tag: EditingMode.allCases.firstIndex(of: .suggesting)!))
        let view = editor.activeTextView
        func find(_ phrase: String) -> NSRange { (editor.textStorage.string as NSString).range(of: phrase) }
        view.setSelectedRange(NSRange(location: find("word processor").location, length: 0))
        view.insertText("fast ", replacementRange: view.selectedRange())
        view.setSelectedRange(find(" and plain text too"))
        view.deleteBackward(nil)
        view.setSelectedRange(find("Ship"))
        view.insertText("Release", replacementRange: view.selectedRange())
        view.setSelectedRange(NSRange(location: find("fast").location + 1, length: 0))
    default:
        break
    }
}

/// Launch arguments used during development to verify rendering without manual interaction:
/// `-PDSampleDocument YES` fills new documents with sample content,
/// `-PDSnapshot <file name>` writes a PNG of the first window to the app's temporary folder and quits.
enum DebugLaunchOptions {
    static var wantsSample: Bool { UserDefaults.standard.bool(forKey: "PDSampleDocument") }

    static func runIfRequested() {
        guard let name = UserDefaults.standard.string(forKey: "PDSnapshot") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if UserDefaults.standard.bool(forKey: "PDOpenEditable"),
               let viewer = NSApp.windows.compactMap({ $0.windowController as? PDFWindowController }).first {
                viewer.openAsEditableDocument()
            }
            guard let controller = NSApp.windows.compactMap({ $0.windowController as? DocumentWindowController }).first else { return }
            let width = UserDefaults.standard.double(forKey: "PDWindowWidth")
            if width > 0, let window = controller.window {
                window.setContentSize(NSSize(width: width, height: window.contentLayoutRect.height))
            }
            let zoom = UserDefaults.standard.double(forKey: "PDZoom")
            if zoom > 0 { controller.editor.setZoom(zoom) }
            if let color = UserDefaults.standard.string(forKey: "PDPageColor"), let document = controller.puggleDocument {
                document.pageSetup.pageColorHex = color
            }
            if UserDefaults.standard.bool(forKey: "PDHeaderFooter") {
                let editor = controller.editor
                let style = DocumentDefaults.paragraphStyle()
                var attributes = DocumentDefaults.typingAttributes
                attributes[.foregroundColor] = NSColor(hex: "666666")
                attributes[.paragraphStyle] = style
                editor.headerStorage.setAttributedString(NSAttributedString(string: "Project Puggle · Quarterly plan", attributes: attributes))
                editor.insertPageNumber(.footerCenter)
                editor.focus()
            }
            if UserDefaults.standard.bool(forKey: "PDInsertTestTable") {
                let editor = controller.editor
                let location = (editor.textStorage.string as NSString).range(of: "Milestones").location
                editor.activeTextView.setSelectedRange(NSRange(location: location == NSNotFound ? 0 : location, length: 0))
                editor.insertTable(rows: 3, columns: 3)
                for word in ["Task", "Owner", "Due", "Editor", "Ana", "Nov", "Formats", "Ben", "Dec"] {
                    editor.activeTextView.insertText(word, replacementRange: editor.activeTextView.selectedRange())
                    editor.activeTextView.doCommand(by: #selector(NSResponder.insertTab(_:)))
                }
            }
            if UserDefaults.standard.bool(forKey: "PDInsertTestImage") {
                let string = controller.editor.textStorage.string as NSString
                let location = string.range(of: "Goals").location
                controller.editor.activeTextView.setSelectedRange(NSRange(location: location == NSNotFound ? 0 : location, length: 0))
                _ = controller.editor.insertImage(data: SelfTest.samplePNG(width: 600, height: 240), type: .png)
                if let (range, _) = controller.editor.selectedImage {
                    controller.editor.setImageSize(NSSize(width: 300, height: 120), at: range)
                    controller.editor.activeTextView.setSelectedRange(range)
                    controller.editor.updateImageSelection()
                }
            }
            if let query = UserDefaults.standard.string(forKey: "PDFind") {
                controller.find.show(replace: UserDefaults.standard.bool(forKey: "PDFindReplace"))
                controller.find.state.query = query
                controller.find.search(preferring: 0)
            }
            if let name = UserDefaults.standard.string(forKey: "PDExportPDF") {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                print("PDExportPDF: \(controller.editor.exportPDF(to: url)) \(url.path)")
            }
            switch UserDefaults.standard.string(forKey: "PDShowLink") {
            case "editor":
                controller.editor.activeTextView.setSelectedRange(NSRange(location: 8, length: 7))
                controller.showLinkEditor()
            case "preview":
                let index = (controller.editor.textStorage.string as NSString).range(of: "example.com").location
                if index != NSNotFound { controller.showLinkPreview(at: index) }
            default: break
            }
            if let mode = UserDefaults.standard.string(forKey: "PDComments") { addSampleComments(controller, mode: mode) }
            if UserDefaults.standard.bool(forKey: "PDCollaborationDemo") { CollaborationDemo.start(controller) }
            if UserDefaults.standard.bool(forKey: "PDShowTablePicker") { controller.pdInsertTable(nil) }
            switch UserDefaults.standard.string(forKey: "PDOpenSheet") {
            case "pageSetup": controller.pdPageSetup(nil)
            case "wordCount": controller.pdWordCount(nil)
            case "customSpacing": controller.pdCustomSpacing(nil)
            case "tableProperties": controller.pdTableProperties(nil)
            case "shortcuts": controller.pdShowShortcuts(nil)
            case "collaborate":
                DispatchQueue.main.asyncAfter(deadline: .now() + (UserDefaults.standard.bool(forKey: "PDCollaborationDemo") ? 1.6 : 0)) {
                    controller.showCollaborate()
                }
            default: break
            }
            // Through the menu item itself, so the snapshot also checks the menu's wiring.
            if UserDefaults.standard.bool(forKey: "PDShowAbout"), let appMenu = NSApp.mainMenu?.items.first?.submenu {
                appMenu.performActionForItem(at: appMenu.indexOfItem(withTitle: "About PuggleDocs"))
            }
        }
        let settle = UserDefaults.standard.bool(forKey: "PDCollaborationDemo") ? 5.0 : (UserDefaults.standard.string(forKey: "PDComments") == nil ? 2.5 : 3.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
            guard let documentWindow = NSApp.windows.first(where: { $0.windowController is DocumentWindowController })
                    ?? NSApp.windows.first(where: { $0.windowController is PDFWindowController }),
                  case let popover = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("Popover") && $0.isVisible }),
                  case let about = NSApp.windows.first(where: { $0.windowController is AboutWindowController && $0.isVisible }),
                  case let window = about ?? popover ?? documentWindow.attachedSheet ?? documentWindow,
                  let view = window.contentView?.superview ?? window.contentView else {
                print("PDSnapshot: no document window")
                NSApp.terminate(nil)
                return
            }
            if let controller = documentWindow.windowController as? DocumentWindowController {
                let editor = controller.editor
                print("PDSnapshot: pages=\(editor.pages.count) zoom=\(controller.state.zoom) window=\(window.frame.size)")
            }
            let bounds = view.bounds
            if let rep = view.bitmapImageRepForCachingDisplay(in: bounds) {
                view.cacheDisplay(in: bounds, to: rep)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                print("PDSnapshot: \(url.path)")
            }
            // Exit directly: quitting normally would wait on any open sheet or unsaved-changes prompt.
            fflush(stdout)
            exit(0)
        }
    }
}
/// `-PDCollaborationDemo YES` (with `-PDStandInCloud YES`) shares the window's document on the stand-in "iCloud" with
/// two people, who open it, type and comment, for screenshots of a shared document.
enum CollaborationDemo {
    static let ana = StandInPerson(Collaborator(id: "ana@example.com", name: "Ana Lopez", address: "ana@example.com"))
    static let ben = StandInPerson(Collaborator(id: "ben@example.com", name: "Ben Carter", address: "ben@example.com"))

    static func start(_ controller: DocumentWindowController) {
        guard let document = controller.puggleDocument else { return }
        DocumentCollaboration.noticeDelay = 3
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Project Puggle plan.docx")
        document.save(to: url, ofType: DocumentFormat.docx.typeIdentifier, for: .saveAsOperation) { _ in
            MainActor.assumeIsolated {
                CollaborationController.shared.share(document, in: controller, access: .invited, permission: .edit) { _ in
                    guard let id = document.collaboration?.id else { return }
                    let service = CollaborationController.shared.service
                    service.invite("ana@example.com", permission: .edit, to: id) { result in
                        if case let .success(sharing) = result { document.collaboration?.sharingUpdated(sharing) }
                    }
                    service.invite("ben@example.com", permission: .comment, to: id) { result in
                        if case let .success(sharing) = result { document.collaboration?.sharingUpdated(sharing) }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        ana.join(id)
                        ben.join(id)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        ana.type("Updated by Ana: ", at: 0)
                        ben.comment("Can we add a date for each milestone?", on: "Milestones")
                    }
                }
            }
        }
    }
}
#endif
