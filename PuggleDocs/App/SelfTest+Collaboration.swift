#if DEBUG
import AppKit
import PuggleDocsKit

/// Drives collaboration end to end on the stand-in "iCloud" (`-PDSelfTest YES -PDSelfTestSuite collaboration`):
/// sharing the window's document, people on other "Macs" editing and commenting along with it, undo, access, the
/// summaries sent after a quiet spell, stopping sharing, and a document someone else shares, read-only.
@MainActor
final class CollaborationSelfTest {
    private struct Step {
        let name: String
        let timeout: TimeInterval
        /// Whether the step changes this window's document, so its changes get an undo group of their own.
        let here: Bool
        let act: () -> Void
        let check: () -> Bool
    }

    private let controller: DocumentWindowController
    private var steps: [Step] = []
    private var failures = 0
    private let cloud = StandInCloud.shared
    private let ana = StandInPerson(Collaborator(id: "ana@example.com", name: "Ana Lopez", address: "ana@example.com"))
    private let ben = StandInPerson(Collaborator(id: "ben@example.com", name: "Ben Carter", address: "ben@example.com"))
    private var model: CollaborateModel!
    private var bensDocument: UUID?
    private var bensWindow: DocumentWindowController?
    private var startedNotices = 0

    init(controller: DocumentWindowController) { self.controller = controller }

    static func run() {
        DocumentCollaboration.noticeDelay = 1
        cloud.latency = 0.03
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard let controller = NSApp.windows.compactMap({ $0.windowController as? DocumentWindowController }).first else {
                print("SELFTEST FAIL: no window")
                NSApp.terminate(nil)
                return
            }
            let test = CollaborationSelfTest(controller: controller)
            test.defineSteps()
            test.next()
        }
    }

    private static var cloud: StandInCloud { .shared }

    private var editor: EditorController { controller.editor }
    private var document: PuggleDocument { controller.puggleDocument! }
    private var storage: NSTextStorage { editor.textStorage }
    private var state: CollaborationState { controller.state.collaboration }
    private var session: DocumentCollaboration? { document.collaboration }

    private func type(_ text: String, in editor: EditorController? = nil) {
        let view = (editor ?? self.editor).activeTextView
        for character in text { view.insertText(String(character), replacementRange: view.selectedRange()) }
    }

    private func select(_ phrase: String, in editor: EditorController? = nil) {
        let editor = editor ?? self.editor
        let range = (editor.textStorage.string as NSString).range(of: phrase)
        editor.focus()
        editor.activeTextView.setSelectedRange(range)
    }

    /// A step that acts, then waits until its check passes (or gives up).
    private func step(_ name: String, timeout: TimeInterval = 4, here: Bool = false, _ act: @escaping () -> Void = {},
                      until check: @escaping () -> Bool) {
        steps.append(Step(name: name, timeout: timeout, here: here, act: act, check: check))
    }

    private func next() {
        guard !steps.isEmpty else {
            print(failures == 0 ? "SELFTEST DONE: all passed" : "SELFTEST DONE: \(failures) failed")
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
        let step = steps.removeFirst()
        let undoManager = editor.undoManager
        undoManager?.groupsByEvent = false
        // AppKit groups undo by input event; steps are not events, so each that edits gets its own group.
        if step.here { undoManager?.beginUndoGrouping() }
        step.act()
        if step.here { undoManager?.endUndoGrouping() }
        let deadline = Date().addingTimeInterval(step.timeout)
        func poll() {
            if step.check() {
                print("SELFTEST PASS: \(step.name)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.next() }
            } else if Date() > deadline {
                failures += 1
                print("SELFTEST FAIL: \(step.name) — here: \(storage.string.debugDescription) ana: \(ana.text.debugDescription)")
                print("SELFTEST INFO: notices \(cloud.notices.dropFirst(startedNotices).map { "\($0.to): \($0.title) / \($0.body)" })")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.next() }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
            }
        }
        poll()
    }

    private var everythingSent: Bool { !(session?.hasUnsentChanges ?? true) }

    private func defineSteps() {
        // MARK: Sharing a document of this person's

        step("a new document isn't shared", here: true) {
            self.type("Project plan\nGoals: ship the editor together.\n")
        } until: {
            !self.state.isShared && self.storage.string.hasPrefix("Project plan")
        }
        step("it's saved on this Mac before it's shared") {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Collaboration self-test \(UUID().uuidString.prefix(6)).docx")
            self.document.save(to: url, ofType: DocumentFormat.docx.typeIdentifier, for: .saveAsOperation) { _ in }
        } until: {
            self.document.fileURL != nil
        }
        step("sharing makes it live, with undo kept for the shared text") {
            self.model = CollaborateModel(controller: CollaborationController.shared, windowController: self.controller)
            self.model.share()
        } until: {
            self.state.isShared && self.session?.phase == .live && self.editor.textViews.allSatisfy { !$0.allowsUndo }
                && self.cloud.documents[self.session?.id ?? UUID()] != nil && self.state.statusText == "Saved in iCloud"
        }
        step("invited people join, one to edit and one to comment") {
            self.model.address = "ana@example.com"
            self.model.invitePermission = .edit
            self.model.invite()
            self.model.address = "ben@example.com"
            self.model.invitePermission = .comment
            self.model.invite()
        } until: {
            self.state.collaborators.count == 3 && self.state.collaborators.allSatisfy { $0.status == .joined }
                && self.state.collaborators.first(where: { $0.id == "ben@example.com" })?.permission == .comment
        }
        step("a collaborator's Mac opens it with the same text") {
            self.ana.join(self.session!.id)
        } until: {
            self.ana.text == self.storage.string
        }
        step("their typing shows up here") {
            self.ana.type("Hello from Ana. ", at: 0)
        } until: {
            self.storage.string.hasPrefix("Hello from Ana. Project plan")
        }
        step("typing here reaches them", here: true) {
            self.editor.activeTextView.setSelectedRange(NSRange(location: self.storage.length, length: 0))
            self.type("Alex was here.")
        } until: {
            self.ana.text == self.storage.string && self.storage.string.hasSuffix("Alex was here.") && self.everythingSent
        }
        step("a paragraph to type in together", here: true) {
            // Of its own, at the end, so the text later steps look for stays as it is.
            self.editor.activeTextView.setSelectedRange(NSRange(location: self.storage.length, length: 0))
            self.type("\nScratch:")
        } until: {
            self.everythingSent && self.ana.text == self.storage.string
        }
        step("typing at the same time ends the same on both Macs", here: true) {
            var random = SystemRandomNumberGenerator()
            let view = self.editor.activeTextView
            for round in 0..<25 {
                let theirs = (self.ana.text as NSString).range(of: "Scratch:").location + 8
                self.ana.type(["a", "b ", "cd"][round % 3], at: Int.random(in: theirs...self.ana.storage.length, using: &random))
                let ours = (self.storage.string as NSString).range(of: "Scratch:").location + 8
                view.setSelectedRange(NSRange(location: Int.random(in: ours...self.storage.length, using: &random), length: 0))
                self.type(["x", "yz", " "][round % 3])
                if round % 5 == 0, self.storage.length - ours > 2 {
                    let at = Int.random(in: ours..<(self.storage.length - 2), using: &random)
                    view.setSelectedRange(NSRange(location: at, length: 2))
                    view.deleteBackward(nil)
                }
            }
        } until: {
            self.everythingSent && self.ana.client?.hasPending == false && self.ana.text == self.storage.string
        }
        step("their bold text arrives bold") {
            self.ana.storage.addAttribute(.font, value: NSFont(name: "Arial-BoldMT", size: 11) ?? NSFont.boldSystemFont(ofSize: 11),
                                          range: NSRange(location: 0, length: 5))
        } until: {
            CharacterFormatting.isBold(self.storage.attributes(at: 0, effectiveRange: nil))
        }
        step("a table made here arrives whole", here: true) {
            self.editor.activeTextView.setSelectedRange(NSRange(location: self.storage.length, length: 0))
            self.type("\n")
            self.editor.insertTable(rows: 2, columns: 2)
            self.type("Cell")
        } until: {
            let index = (self.ana.text as NSString).range(of: "Cell").location
            guard index != NSNotFound, let table = TableModel.table(at: index, in: self.ana.storage) else { return false }
            return table.rows == 2 && table.columns == 2 && self.ana.text == self.storage.string
        }
        step("undo takes back this Mac's typing, not theirs", here: true) {
            self.editor.activeTextView.setSelectedRange(NSRange(location: 0, length: 0))
            self.editor.undoManager?.beginUndoGrouping()
            self.type("MINE ")
            self.editor.undoManager?.endUndoGrouping()
        } until: {
            self.storage.string.hasPrefix("MINE ") && self.everythingSent
        }
        step("their typing comes in after it") {
            self.ana.type("Theirs ", at: self.ana.storage.length)
        } until: {
            self.storage.string.hasSuffix("Theirs ")
        }
        step("undo: only this Mac's typing goes") {
            self.editor.undoManager?.undo()
        } until: {
            !self.storage.string.hasPrefix("MINE ") && self.storage.string.hasSuffix("Theirs ") && self.ana.text == self.storage.string
        }
        step("redo: it comes back for everyone") {
            self.editor.undoManager?.redo()
        } until: {
            self.storage.string.hasPrefix("MINE ") && self.ana.text == self.storage.string
        }
        step("the header shows who else is in it, viewing now") {} until: {
            let others = self.state.others
            guard let ana = others.first(where: { $0.id == "ana@example.com" }) else { return false }
            return others.count == 2 && ana.initials == "AL" && self.state.isViewing(ana)
        }

        // MARK: Comments

        step("their comment shows here, on its text") {
            self.ana.comment("Can we add dates?", on: "Goals")
        } until: {
            guard let thread = self.document.comments.first(where: { $0.text == "Can we add dates?" }),
                  let range = CommentAnchors.ranges(in: self.storage)[thread.id] else { return false }
            return (self.storage.string as NSString).substring(with: range) == "Goals"
        }
        step("a comment here reaches them", here: true) {
            self.select("editor")
            self.editor.comments.startDraft()
            self.editor.comments.model.draft?.text = "Which editor?"
            self.editor.comments.commitDraft()
        } until: {
            self.ana.comments.values.contains { $0.thread.text == "Which editor?" && $0.thread.authorID == StandInCloud.me.id }
        }
        step("replies go both ways", here: true) {
            guard let thread = self.document.comments.first(where: { $0.text == "Can we add dates?" }) else { return }
            self.editor.comments.model.replyText = "Yes, by Friday."
            self.editor.comments.reply(to: thread.id)
            self.ana.reply("Thanks!", to: thread.id)
        } until: {
            guard let thread = self.document.comments.first(where: { $0.text == "Can we add dates?" }) else { return false }
            return Set(thread.replies.map(\.text)) == ["Yes, by Friday.", "Thanks!"]
        }

        step("resolving here reaches them", here: true) {
            guard let thread = self.document.comments.first(where: { $0.text == "Can we add dates?" }) else { return }
            self.editor.comments.setResolved(thread.id, true)
        } until: {
            self.ana.comments.values.contains { $0.thread.text == "Can we add dates?" && $0.thread.resolved }
        }
        step("their reply comes in while it's resolved") {
            guard let thread = self.document.comments.first(where: { $0.text == "Can we add dates?" }) else { return }
            self.ana.reply("One more thing", to: thread.id)
        } until: {
            self.document.comments.first { $0.text == "Can we add dates?" }?.replies.contains { $0.text == "One more thing" } == true
        }
        step("undo opens it again here and there, and keeps their reply") {
            self.editor.undoManager?.undo()
        } until: {
            guard let here = self.document.comments.first(where: { $0.text == "Can we add dates?" }),
                  let there = self.ana.comments[here.id]?.thread else { return false }
            return !here.resolved && here.replies.contains { $0.text == "One more thing" }
                && !there.resolved && there.replies.contains { $0.text == "One more thing" }
        }

        // MARK: Access

        step("taking them down to commenting stops their edits") {
            guard let ana = self.state.collaborators.first(where: { $0.id == "ana@example.com" }) else { return }
            self.model.setPermission(.comment, for: ana)
        } until: {
            self.ana.sharing?.myPermission == .comment
        }
        step("their changes are turned down, and don't reach this Mac") {
            self.ana.type("NOPE ", at: 0)
        } until: {
            self.ana.refusals > 0 && !self.storage.string.contains("NOPE")
        }
        step("but they can still comment") {
            self.ana.comment("Still reading along", on: "Alex")
        } until: {
            self.document.comments.contains { $0.text == "Still reading along" }
        }

        // MARK: Telling the others

        step("after a quiet spell the others get one summary of it all") {
            self.startedNotices = self.cloud.notices.count
        } until: {
            let fresh = self.cloud.notices.dropFirst(self.startedNotices)
            let toAna = fresh.filter { $0.to == "ana@example.com" }
            guard toAna.count == 1, let notice = toAna.first else { return false }
            return notice.title.hasPrefix("Alex Morgan edited “Collaboration self-test") && notice.body.contains("added a table")
                && notice.body.contains("added a comment") && fresh.contains { $0.to == "ben@example.com" }
        }
        step("the next quiet spell brings a summary of what's new since", here: true) {
            self.startedNotices = self.cloud.notices.count
            self.editor.activeTextView.setSelectedRange(NSRange(location: self.storage.length, length: 0))
            self.type(" Three more words.")
        } until: {
            let toAna = self.cloud.notices.dropFirst(self.startedNotices).filter { $0.to == "ana@example.com" }
            return toAna.count == 1 && toAna.first?.body == "Added 3 words."
        }

        // MARK: Stopping

        step("stopping sharing keeps the document here, and closes it for the others") {
            self.model.stopSharing()
        } until: {
            !self.state.isShared && self.document.collaboration == nil && self.ana.isGone
                && self.editor.textViews.allSatisfy(\.allowsUndo) && self.editor.state.access == .full
                && self.storage.string.contains("Alex was here.") && self.cloud.documents.isEmpty
        }

        // MARK: A document someone else shares

        step("a document shared with this person opens in a window of its own") {
            self.bensDocument = self.ben.share(title: "Ben’s notes", text: "Notes from Ben.\nYou can read these.",
                                               with: [(StandInCloud.me, .comment)])
        } until: {
            guard let id = self.bensDocument, let entry = CollaborationController.shared.sharedWithMe.first(where: { $0.id == id }) else { return false }
            if self.bensWindow == nil {
                CollaborationController.shared.openShared(entry)
                self.bensWindow = NSApp.windows.compactMap { $0.windowController as? DocumentWindowController }
                    .first { $0.puggleDocument?.sharedCopy?.id == id }
            }
            guard let window = self.bensWindow else { return false }
            return window.editor.textStorage.string == self.ben.text && window.puggleDocument?.collaboration?.phase == .live
        }
        step("it's read-only here, but can be commented on") {
            guard let window = self.bensWindow else { return }
            self.select("Ben", in: window.editor)
            window.editor.comments.startDraft()
            window.editor.comments.model.draft?.text = "Thanks for these"
            window.editor.comments.commitDraft()
        } until: {
            guard let window = self.bensWindow else { return false }
            return window.state.access == .commentOnly && window.editor.textViews.allSatisfy { !$0.isEditable }
                && window.state.modeTitle == "Commenting" && self.ben.comments.values.contains { $0.thread.text == "Thanks for these" }
        }
        step("typing in it changes nothing") {
            guard let window = self.bensWindow else { return }
            window.editor.activeTextView.setSelectedRange(NSRange(location: 0, length: 0))
            self.type("Sneaky ", in: window.editor)
        } until: {
            self.bensWindow?.editor.textStorage.string == self.ben.text && !self.ben.text.contains("Sneaky")
        }
        step("its owner's edits show up live") {
            self.ben.type("Update: ", at: 0)
        } until: {
            self.bensWindow?.editor.textStorage.string.hasPrefix("Update: Notes from Ben.") == true
        }
        step("it can still be printed, downloaded and copied") {} until: {
            guard let window = self.bensWindow, let document = window.puggleDocument else { return false }
            let print = NSMenuItem(title: "Print", action: #selector(NSDocument.printDocument(_:)), keyEquivalent: "")
            let copy = NSMenuItem(title: "Make a copy", action: #selector(NSDocument.duplicate(_:)), keyEquivalent: "")
            let download = NSMenuItem(title: "Download", action: #selector(DocumentCommands.pdDownload(_:)), keyEquivalent: "")
            download.tag = 0
            return document.validateUserInterfaceItem(print) && document.validateUserInterfaceItem(copy) && window.validateMenuItem(download)
                && (try? document.data(ofType: DocumentFormat.docx.typeIdentifier)) != nil
        }
        step("when its owner stops sharing, it goes, saying so") {
            self.ben.stopSharing()
        } until: {
            guard let window = self.bensWindow?.window else { return true }
            guard let alert = window.attachedSheet, window.windowController.map({ ($0 as? DocumentWindowController)?.editor.textStorage.length == 0 }) == true else { return false }
            window.endSheet(alert, returnCode: .alertFirstButtonReturn)
            return true
        }
        step("its window closes") {} until: {
            !NSApp.windows.contains { ($0.windowController as? DocumentWindowController)?.puggleDocument?.sharedCopy != nil }
        }
    }
}
#endif
