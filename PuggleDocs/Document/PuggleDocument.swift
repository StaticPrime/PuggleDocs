import AppKit
import PuggleDocsKit

/// A document window's model: the text, page setup, and file handling.
@objc(PuggleDocument)
final class PuggleDocument: NSDocument {
    /// Recording storages, so that while the document is shared each round of editing becomes a change for the
    /// others (see `DocumentCollaboration`); they record nothing otherwise.
    let textStorage = RecordingTextStorage()
    let headerStorage = RecordingTextStorage()
    let footerStorage = RecordingTextStorage()
    var pageSetup = PageSetupDefaults.current {
        didSet { if pageSetup != oldValue { onPageSetupChange?(pageSetup) } }
    }
    /// Comment threads; their text is marked with `.pdComments` in `textStorage`.
    var comments: [CommentThread] = [] {
        didSet { if comments != oldValue { onCommentsChange?(oldValue) } }
    }
    /// Called with the threads as they were whenever they change.
    var onCommentsChange: (([CommentThread]) -> Void)?
    /// Called when the person changes the page setup (not when it arrives from someone else).
    var onPageSetupEdited: (() -> Void)?
    /// For a document someone shared with this person: which one it is. It has no file here.
    var sharedCopy: SharedCopy?
    /// While the document is shared: its part in that.
    var collaboration: DocumentCollaboration?
    /// Features found while importing that could not be kept.
    private(set) var importWarnings: Set<ImportWarning> = []
    /// Title typed into the header before the document has a file.
    var customTitle: String?
    /// The original file name when a lossy import was reopened as an untitled copy.
    private(set) var importedFileName: String?

    var onPageSetupChange: ((PageSetup) -> Void)?
    var onStatusChange: (() -> Void)?

    /// Content parsed off the main thread, applied once the main actor can take it.
    nonisolated(unsafe) private var pendingContent: DocumentContent?

    override init() {
        super.init()
        textStorage.setAttributedString(NSAttributedString(string: "", attributes: DocumentDefaults.typingAttributes))
        hasUndoManager = true
    }

    nonisolated override class var autosavesInPlace: Bool { true }

    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { false }

    override func makeWindowControllers() {
        if let content = pendingContent {
            pendingContent = nil
            apply(content)
        }
        #if DEBUG
        if fileURL == nil, textStorage.length == 0, DebugLaunchOptions.wantsSample {
            textStorage.setAttributedString(SampleContent.make())
        }
        #endif
        if !importWarnings.isEmpty, let url = fileURL {
            // Never overwrite a file with a lossy copy: continue as an untitled document.
            importedFileName = url.deletingPathExtension().lastPathComponent
            fileURL = nil
            fileType = DocumentFormat.docx.typeIdentifier
        }
        let controller = DocumentWindowController(document: self)
        addWindowController(controller)
        CollaborationController.shared?.documentOpened(self, in: controller)
    }

    // MARK: Reading and writing

    nonisolated override func read(from data: Data, ofType typeName: String) throws {
        guard let format = DocumentFormat(typeName: typeName) else {
            throw DocumentIOError.unreadable("PuggleDocs can't open files of this type.")
        }
        let content = try DocumentIO.read(data, format: format)
        if Thread.isMainThread {
            MainActor.assumeIsolated { apply(content) }
        } else {
            pendingContent = content
        }
    }

    private func apply(_ content: DocumentContent) {
        textStorage.setAttributedString(content.text)
        headerStorage.setAttributedString(content.header ?? NSAttributedString())
        footerStorage.setAttributedString(content.footer ?? NSAttributedString())
        comments = content.comments
        pageSetup = content.pageSetup
        importWarnings = content.warnings
        undoManager?.removeAllActions()
    }

    override func data(ofType typeName: String) throws -> Data {
        guard let format = DocumentFormat(typeName: typeName) else {
            throw DocumentIOError.unwritable("PuggleDocs can't save files of this type.")
        }
        return try DocumentIO.write(content, format: format)
    }

    var title: String { (displayName as NSString?)?.deletingPathExtension ?? "Document" }

    /// Everything a file needs, as it stands now.
    var content: DocumentContent {
        let header = headerStorage.string.isEmpty ? nil : NSAttributedString(attributedString: headerStorage)
        let footer = footerStorage.string.isEmpty ? nil : NSAttributedString(attributedString: footerStorage)
        return DocumentContent(text: textStorage, pageSetup: pageSetup, title: title, header: header, footer: footer, comments: comments)
    }

    var format: DocumentFormat? { fileType.flatMap(DocumentFormat.init(typeName:)) }

    // MARK: Names

    override var displayName: String! {
        get {
            if let sharedCopy { return sharedCopy.title }
            if fileURL == nil, let title = customTitle ?? importedFileName { return title }
            let name: String = super.displayName
            if fileURL == nil, name.hasPrefix("Untitled") { return name.replacingOccurrences(of: "Untitled", with: "Untitled document") }
            return name
        }
        set { super.displayName = newValue }
    }

    // MARK: Shared copies

    /// A document shared with this person lives in iCloud: it's never saved here unless they save a copy.
    override var isDocumentEdited: Bool {
        if sharedCopy != nil { return collaboration?.hasUnsentChanges ?? false }
        return super.isDocumentEdited
    }

    override var hasUnautosavedChanges: Bool { sharedCopy != nil ? false : super.hasUnautosavedChanges }

    override func autosave(withImplicitCancellability autosavingIsImplicitlyCancellable: Bool, completionHandler: @escaping (Error?) -> Void) {
        guard sharedCopy == nil else { return completionHandler(nil) }
        super.autosave(withImplicitCancellability: autosavingIsImplicitlyCancellable, completionHandler: completionHandler)
    }

    /// A document shared with this person has no file here to move or rename, and its name is its owner's to change.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if sharedCopy != nil, [#selector(NSDocument.move(_:)), #selector(NSDocument.revertToSaved(_:)), #selector(NSDocument.browseVersions(_:))]
            .contains(item.action) {
            return false
        }
        return super.validateUserInterfaceItem(item)
    }

    /// Saving a document shared with this person keeps a copy of it on this Mac.
    override func save(_ sender: Any?) {
        if sharedCopy != nil {
            saveTo(sender)
        } else {
            super.save(sender)
        }
    }

    /// Before closing a shared document with changes that haven't reached iCloud, the person chooses.
    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        guard let collaboration, collaboration.hasUnsentChanges, let window = windowControllers.first?.window else {
            if sharedCopy != nil {
                Self.answer(true, to: delegate, selector: shouldCloseSelector, document: self, contextInfo: contextInfo)
                return
            }
            super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
            return
        }
        collaboration.flush()
        let alert = NSAlert()
        alert.messageText = "Your latest changes to “\(displayName ?? "the document")” haven’t reached iCloud yet."
        alert.informativeText = "The people you share it with won’t see them if you close it now. Wait a moment for iCloud, or keep a copy on this Mac."
        alert.addButton(withTitle: "Keep Open")
        alert.addButton(withTitle: "Close Anyway")
        alert.buttons[1].hasDestructiveAction = true
        let context = UncheckedPointer(pointer: contextInfo)
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn, self.sharedCopy == nil {
                super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: context.pointer)
            } else {
                Self.answer(response == .alertSecondButtonReturn, to: delegate, selector: shouldCloseSelector, document: self, contextInfo: context.pointer)
            }
        }
    }

    /// Calls `-document:shouldClose:contextInfo:` on whoever asked.
    private static func answer(_ shouldClose: Bool, to delegate: Any, selector: Selector?, document: NSDocument, contextInfo: UnsafeMutableRawPointer?) {
        guard let selector, let object = delegate as? NSObject, let method = object.method(for: selector) else { return }
        typealias Callback = @convention(c) (NSObject, Selector, NSDocument, Bool, UnsafeMutableRawPointer?) -> Void
        unsafeBitCast(method, to: Callback.self)(object, selector, document, shouldClose, contextInfo)
    }

    override func close() {
        collaboration?.close()
        collaboration = nil
        super.close()
    }

    // MARK: Status

    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        onStatusChange?()
    }

    override func updateChangeCount(withToken changeCountToken: Any, for saveOperation: NSDocument.SaveOperationType) {
        super.updateChangeCount(withToken: changeCountToken, for: saveOperation)
        onStatusChange?()
    }

    // MARK: Printing

    /// Used by the system "Export as PDF" command.
    override var pdfPrintOperation: NSPrintOperation {
        guard let controller = windowControllers.first as? DocumentWindowController else { return super.pdfPrintOperation }
        let operation = controller.editor.makePrintOperation(printInfo: NSPrintInfo.shared.copy() as! NSPrintInfo)
        operation.showsPrintPanel = false
        return operation
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        guard let controller = windowControllers.first as? DocumentWindowController else {
            throw DocumentIOError.unwritable("There is no window to print.")
        }
        let info = printInfo.copy() as! NSPrintInfo
        info.dictionary().addEntries(from: printSettings)
        return controller.editor.makePrintOperation(printInfo: info)
    }
}

/// A context pointer handed through a completion handler.
private struct UncheckedPointer: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer?
}
