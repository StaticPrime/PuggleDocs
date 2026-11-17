import AppKit

public struct PageMargins: Equatable, Sendable {
    public var top: CGFloat
    public var left: CGFloat
    public var bottom: CGFloat
    public var right: CGFloat

    public init(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public static func uniform(_ value: CGFloat) -> PageMargins {
        PageMargins(top: value, left: value, bottom: value, right: value)
    }
}

/// Paper size, orientation and margins. All values are in points (1/72 inch).
public struct PageSetup: Equatable, Sendable {
    public enum Orientation: String, Sendable { case portrait, landscape }

    public struct PaperSize: Equatable, Sendable, Identifiable {
        public let name: String
        public let size: CGSize
        public var id: String { name }

        public init(name: String, size: CGSize) {
            self.name = name
            self.size = size
        }
    }

    public static let paperSizes: [PaperSize] = [
        PaperSize(name: "Letter (8.5\" x 11\")", size: CGSize(width: 612, height: 792)),
        PaperSize(name: "Tabloid (11\" x 17\")", size: CGSize(width: 792, height: 1224)),
        PaperSize(name: "Legal (8.5\" x 14\")", size: CGSize(width: 612, height: 1008)),
        PaperSize(name: "Statement (5.5\" x 8.5\")", size: CGSize(width: 396, height: 612)),
        PaperSize(name: "Executive (7.25\" x 10.5\")", size: CGSize(width: 522, height: 756)),
        PaperSize(name: "Folio (8.5\" x 13\")", size: CGSize(width: 612, height: 936)),
        PaperSize(name: "A3 (29.7 cm x 42 cm)", size: CGSize(width: 842, height: 1191)),
        PaperSize(name: "A4 (21 cm x 29.7 cm)", size: CGSize(width: 595, height: 842)),
        PaperSize(name: "A5 (14.8 cm x 21 cm)", size: CGSize(width: 420, height: 595)),
        PaperSize(name: "B4 (25 cm x 35.3 cm)", size: CGSize(width: 709, height: 1001)),
        PaperSize(name: "B5 (17.6 cm x 25 cm)", size: CGSize(width: 499, height: 709)),
    ]

    /// Portrait dimensions of the paper.
    public var paperSize: CGSize
    public var orientation: Orientation
    public var margins: PageMargins
    public var headerDistance: CGFloat = 36
    public var footerDistance: CGFloat = 36
    /// "RRGGBB", or nil for white paper.
    public var pageColorHex: String?
    /// The first page shows no header or footer.
    public var differentFirstPage = false

    public var pageColor: NSColor { pageColorHex.flatMap(NSColor.init(hex:)) ?? .white }

    public init(paperSize: CGSize, orientation: Orientation = .portrait, margins: PageMargins = .uniform(72)) {
        self.paperSize = CGSize(width: min(paperSize.width, paperSize.height), height: max(paperSize.width, paperSize.height))
        self.orientation = orientation
        self.margins = margins
    }

    public static let letter = PageSetup(paperSize: CGSize(width: 612, height: 792))
    public static let a4 = PageSetup(paperSize: CGSize(width: 595, height: 842))

    /// Letter for regions that use US customary units, A4 everywhere else.
    public static var localeDefault: PageSetup {
        Locale.current.measurementSystem == .us ? .letter : .a4
    }

    /// Page size taking orientation into account.
    public var pageSize: CGSize {
        orientation == .portrait ? paperSize : CGSize(width: paperSize.height, height: paperSize.width)
    }

    /// Size of the text area inside the margins.
    public var contentSize: CGSize {
        CGSize(width: max(72, pageSize.width - margins.left - margins.right),
               height: max(72, pageSize.height - margins.top - margins.bottom))
    }

    /// The named paper size matching `paperSize`, if any.
    public var namedPaperSize: PaperSize? {
        PageSetup.paperSizes.first { abs($0.size.width - paperSize.width) < 1.5 && abs($0.size.height - paperSize.height) < 1.5 }
    }

    /// Smallest text area allowed between the margins.
    public static let minimumContent: CGFloat = 72

    /// True when the margins leave at least one inch for text in both directions.
    public var hasValidMargins: Bool {
        let size = pageSize
        return [margins.top, margins.left, margins.bottom, margins.right].allSatisfy { $0 >= 0 }
            && size.width - margins.left - margins.right >= PageSetup.minimumContent
            && size.height - margins.top - margins.bottom >= PageSetup.minimumContent
    }

    // MARK: Persistence (property-list form, used for "Set as default")

    public var propertyList: [String: Any] {
        var plist: [String: Any] = [
            "paperWidth": Double(paperSize.width), "paperHeight": Double(paperSize.height),
            "orientation": orientation.rawValue,
            "top": Double(margins.top), "left": Double(margins.left), "bottom": Double(margins.bottom), "right": Double(margins.right),
        ]
        plist["pageColor"] = pageColorHex
        plist["differentFirstPage"] = differentFirstPage
        return plist
    }

    public init?(propertyList plist: [String: Any]) {
        func number(_ key: String) -> CGFloat? { (plist[key] as? NSNumber).map { CGFloat($0.doubleValue) } }
        guard let width = number("paperWidth"), let height = number("paperHeight"), width > 72, height > 72,
              let top = number("top"), let left = number("left"), let bottom = number("bottom"), let right = number("right")
        else { return nil }
        self.init(paperSize: CGSize(width: width, height: height),
                  orientation: Orientation(rawValue: plist["orientation"] as? String ?? "") ?? .portrait,
                  margins: PageMargins(top: top, left: left, bottom: bottom, right: right))
        pageColorHex = plist["pageColor"] as? String
        differentFirstPage = plist["differentFirstPage"] as? Bool ?? false
        guard hasValidMargins else { return nil }
    }

    /// Builds a setup from an explicit page size, inferring the orientation.
    public static func from(pageSize: CGSize, margins: PageMargins) -> PageSetup {
        let orientation: Orientation = pageSize.width > pageSize.height ? .landscape : .portrait
        return PageSetup(paperSize: pageSize, orientation: orientation, margins: margins)
    }
}

/// Elements found while importing that PuggleDocs could not keep.
public enum ImportWarning: String, Sendable, CaseIterable {
    case tables, images, headersAndFooters, footnotes, comments, textBoxes, trackedChanges, equations, fields

    public var userDescription: String {
        switch self {
        case .tables: "tables (their text was kept as plain paragraphs)"
        case .images: "images"
        case .headersAndFooters: "headers and footers"
        case .footnotes: "footnotes"
        case .comments: "comments"
        case .textBoxes: "text boxes and shapes"
        case .trackedChanges: "tracked changes (insertions were accepted, deletions removed)"
        case .equations: "equations"
        case .fields: "fields (their current values were kept as text)"
        }
    }
}

/// Everything a document file contains, in the editor's representation.
public struct DocumentContent {
    public var text: NSAttributedString
    public var pageSetup: PageSetup
    public var warnings: Set<ImportWarning>
    /// Document title, used where a format stores one (the HTML <title>).
    public var title: String?
    /// Header and footer text shown on every page (nil or empty for none).
    public var header: NSAttributedString?
    public var footer: NSAttributedString?
    /// Comment threads anchored in `text` with `.pdComments`.
    public var comments: [CommentThread]

    public init(text: NSAttributedString, pageSetup: PageSetup = .localeDefault, warnings: Set<ImportWarning> = [], title: String? = nil,
                header: NSAttributedString? = nil, footer: NSAttributedString? = nil, comments: [CommentThread] = []) {
        self.text = text
        self.pageSetup = pageSetup
        self.warnings = warnings
        self.title = title
        self.header = header
        self.footer = footer
        self.comments = comments
    }

    var hasHeader: Bool { (header?.length ?? 0) > 0 }
    var hasFooter: Bool { (footer?.length ?? 0) > 0 }
}
