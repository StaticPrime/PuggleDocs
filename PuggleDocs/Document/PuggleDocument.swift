import AppKit
import PuggleDocsKit

/// A document window's model: the text, page setup, and file handling.
@objc(PuggleDocument)
final class PuggleDocument: NSDocument {
    let textStorage = NSTextStorage()
    let headerStorage = NSTextStorage()
    let footerStorage = NSTextStorage()
    var pageSetup = PageSetupDefaults.current {
        didSet { if pageSetup != oldValue { onPageSetupChange?(pageSetup) } }
    }
    /// Comment threads; their text is marked with `.pdComments` in `textStorage`.
    var comments: [CommentThread] = []
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
        addWindowController(DocumentWindowController(document: self))
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
            if fileURL == nil, let title = customTitle ?? importedFileName { return title }
            let name: String = super.displayName
            if fileURL == nil, name.hasPrefix("Untitled") { return name.replacingOccurrences(of: "Untitled", with: "Untitled document") }
            return name
        }
        set { super.displayName = newValue }
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
