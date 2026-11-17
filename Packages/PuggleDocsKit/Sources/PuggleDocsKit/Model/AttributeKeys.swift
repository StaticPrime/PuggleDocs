import AppKit

public extension NSAttributedString.Key {
    /// Paragraph-level. The raw value of a `NamedStyle` ("normal", "heading1", ...).
    static let pdNamedStyle = NSAttributedString.Key("PuggleDocs.namedStyle")

    /// Paragraph-level. A `ListItem` describing list membership, nesting level and marker style.
    static let pdListItem = NSAttributedString.Key("PuggleDocs.listItem")

    /// Character-level. Records the font family a file asked for when that family is not
    /// installed, so the original name survives a round trip. Value: `RequestedFont`.
    static let pdRequestedFont = NSAttributedString.Key("PuggleDocs.requestedFont")

    /// Character-level. For superscript/subscript runs, the font size the text logically has; the
    /// font itself is rendered smaller. Value: NSNumber (points).
    static let pdScriptBaseSize = NSAttributedString.Key("PuggleDocs.scriptBaseSize")
}

/// Keys whose value must be identical for every character of a paragraph.
public enum ParagraphAttributeKeys {
    public static let all: [NSAttributedString.Key] = [.paragraphStyle, .pdNamedStyle, .pdListItem]
}

/// The font family a document requested, plus the installed family used to render it.
public final class RequestedFont: NSObject, NSSecureCoding, @unchecked Sendable {
    public let family: String
    public let substitute: String

    public init(family: String, substitute: String) {
        self.family = family
        self.substitute = substitute
    }

    public static var supportsSecureCoding: Bool { true }

    public func encode(with coder: NSCoder) {
        coder.encode(family as NSString, forKey: "family")
        coder.encode(substitute as NSString, forKey: "substitute")
    }

    public init?(coder: NSCoder) {
        guard let family = coder.decodeObject(of: NSString.self, forKey: "family") as String?,
              let substitute = coder.decodeObject(of: NSString.self, forKey: "substitute") as String?
        else { return nil }
        self.family = family
        self.substitute = substitute
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? RequestedFont else { return false }
        return family == other.family && substitute == other.substitute
    }

    public override var hash: Int {
        var hasher = Hasher()
        hasher.combine(family)
        hasher.combine(substitute)
        return hasher.finalize()
    }
}
