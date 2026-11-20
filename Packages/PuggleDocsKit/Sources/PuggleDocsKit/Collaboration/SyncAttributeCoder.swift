import AppKit
import UniformTypeIdentifiers

/// Turns the attributes of a document's text into bytes for other Macs, and their bytes back into attributes.
///
/// A table is one `NSTextTable` shared by the paragraph styles of all its cells, and a cell one `NSTextTableBlock`
/// shared by its paragraphs: the table holds together only while they're the same objects. So each table and cell
/// travels with an identifier, and one coder per document hands back the very same object for the same identifier,
/// whether the table was made here or came from another Mac.
public final class SyncAttributeCoder {
    /// The attributes that travel with the text. Anything else stays on the Mac that set it: comment highlights,
    /// which each Mac works out for itself, and marks AppKit adds while typing or fixing fonts.
    public static let syncedKeys: [NSAttributedString.Key] = [
        .font, .foregroundColor, .backgroundColor, .underlineStyle, .underlineColor, .strikethroughStyle, .strikethroughColor,
        .baselineOffset, .superscript, .kern, .link, .paragraphStyle, .attachment, .shadow, .obliqueness, .expansion, .ligature,
        .toolTip, .pdNamedStyle, .pdListItem, .pdRequestedFont, .pdScriptBaseSize, .pdSuggestion,
    ]
    public static let syncedNames = Set(syncedKeys.map(\.rawValue))

    public static func isSynced(_ key: NSAttributedString.Key) -> Bool { syncedNames.contains(key.rawValue) }

    private let tablesByID = NSMapTable<NSString, NSTextTable>.strongToWeakObjects()
    private let tableIDs = NSMapTable<NSTextTable, NSString>.weakToStrongObjects()
    private let blocksByID = NSMapTable<NSString, NSTextBlock>.strongToWeakObjects()
    private let blockIDs = NSMapTable<NSTextBlock, NSString>.weakToStrongObjects()
    /// Values decoded before, by their bytes (never attachments: each image character needs its own).
    private var decoded: [String: [Data: Any]] = [:]
    private var decodedCount = 0

    public init() {}

    // MARK: Attributes

    /// The synced attributes of a run of text, encoded; any that can't be encoded are left out.
    public func encode(_ attributes: [NSAttributedString.Key: Any]) -> DeltaAttributes {
        var result: DeltaAttributes = [:]
        for (key, value) in attributes where Self.isSynced(key) {
            if let data = encodeValue(value, for: key) { result[key.rawValue] = .value(data) }
        }
        return result
    }

    /// Attributes from their encoding; removals and anything that can't be read are left out.
    public func decode(_ attributes: DeltaAttributes) -> [NSAttributedString.Key: Any] {
        var result: [NSAttributedString.Key: Any] = [:]
        for (name, value) in attributes {
            guard case let .value(data) = value else { continue }
            let key = NSAttributedString.Key(name)
            if let object = decodeValue(data, for: key) { result[key] = object }
        }
        return result
    }

    // MARK: Text

    /// A change that inserts `text` into empty text.
    public func insertion(of text: NSAttributedString) -> TextDelta {
        var delta = TextDelta()
        let string = text.string as NSString
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length), options: []) { attributes, range, _ in
            delta.insert(DeltaText(string.substring(with: range) as NSString), encode(attributes))
        }
        return delta
    }

    /// Text made only of inserts (a whole document's text, as a snapshot holds it).
    public func text(from delta: TextDelta) -> NSAttributedString? {
        let result = NSMutableAttributedString()
        return apply(delta, to: result) ? result : nil
    }

    /// Makes a change to `text`. Answers false, leaving `text` alone, when the change doesn't fit it.
    @discardableResult
    public func apply(_ delta: TextDelta, to text: NSMutableAttributedString) -> Bool {
        guard delta.baseLength <= text.length else { return false }
        var index = 0
        text.beginEditing()
        defer { text.endEditing() }
        for op in delta.ops {
            switch op {
            case let .retain(count, attributes):
                if !attributes.isEmpty { restyle(text, range: NSRange(location: index, length: count), attributes) }
                index += count
            case let .insert(insertion, attributes):
                text.insert(NSAttributedString(string: insertion.nsString as String, attributes: decode(attributes)), at: index)
                index += insertion.count
            case let .delete(count):
                text.deleteCharacters(in: NSRange(location: index, length: count))
            }
        }
        return true
    }

    private func restyle(_ text: NSMutableAttributedString, range: NSRange, _ attributes: DeltaAttributes) {
        for (name, value) in attributes {
            let key = NSAttributedString.Key(name)
            switch value {
            case let .value(data):
                if key == .attachment {
                    // Each character gets an attachment of its own.
                    var location = range.location
                    while location < NSMaxRange(range) {
                        if let object = decodeValue(data, for: key) {
                            text.addAttribute(key, value: object, range: NSRange(location: location, length: 1))
                        }
                        location += 1
                    }
                } else if let object = decodeValue(data, for: key) {
                    text.addAttribute(key, value: object, range: range)
                }
            case .removed:
                text.removeAttribute(key, range: range)
            }
        }
    }

    // MARK: Values

    private enum Tag: UInt8 {
        case string = 1, integer, double, font, color, url, paragraphStyle, image, pageField, archive, linkString
    }

    public func encodeValue(_ value: Any, for key: NSAttributedString.Key) -> Data? {
        func tagged(_ tag: Tag, _ payload: Data) -> Data { Data([tag.rawValue]) + payload }
        switch value {
        case let field as PageFieldAttachment:
            return tagged(.pageField, Data([UInt8(field.kind.rawValue)]))
        case let attachment as NSTextAttachment:
            guard let info = ImageAttachments.info(attachment) else { return nil }
            let header = Self.json(ImageHeader(type: info.type.identifier, width: Double(info.size.width), height: Double(info.size.height)))
            var length = UInt32(header.count).bigEndian
            return tagged(.image, Data(bytes: &length, count: 4) + header + info.data)
        case let font as NSFont:
            let traits = NSFontManager.shared.traits(of: font)
            return tagged(.font, Self.json(FontCoding(name: font.fontName, family: font.familyName ?? "", size: Double(font.pointSize),
                                                     bold: traits.contains(.boldFontMask), italic: traits.contains(.italicFontMask))))
        case let color as NSColor:
            if let rgb = color.usingColorSpace(.sRGB) {
                return tagged(.color, Self.json(ColorCoding(rgb)))
            }
            return archive(color).map { tagged(.archive, $0) }
        case let style as NSParagraphStyle:
            return tagged(.paragraphStyle, Self.json(paragraphCoding(style)))
        case let url as URL:
            return tagged(.url, Data(url.absoluteString.utf8))
        case let url as NSURL:
            return tagged(.url, Data((url.absoluteString ?? "").utf8))
        case let number as NSNumber:
            if CFNumberIsFloatType(number) {
                var bits = number.doubleValue.bitPattern.bigEndian
                return tagged(.double, Data(bytes: &bits, count: 8))
            }
            var integer = number.int64Value.bigEndian
            return tagged(.integer, Data(bytes: &integer, count: 8))
        case let string as String:
            return tagged(key == .link ? .linkString : .string, Data(string.utf8))
        case let string as NSString:
            return tagged(key == .link ? .linkString : .string, Data((string as String).utf8))
        default:
            return archive(value).map { tagged(.archive, $0) }
        }
    }

    public func decodeValue(_ data: Data, for key: NSAttributedString.Key) -> Any? {
        guard let first = data.first, let tag = Tag(rawValue: first) else { return nil }
        let cacheable = tag != .image && tag != .pageField
        if cacheable, let cached = decoded[key.rawValue]?[data] { return cached }
        let payload = data.dropFirst()
        let value: Any?
        switch tag {
        case .string:
            value = String(decoding: payload, as: UTF8.self)
        case .linkString:
            value = String(decoding: payload, as: UTF8.self)
        case .url:
            value = URL(string: String(decoding: payload, as: UTF8.self))
        case .integer:
            guard payload.count == 8 else { return nil }
            value = NSNumber(value: Int64(bigEndian: payload.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }))
        case .double:
            guard payload.count == 8 else { return nil }
            value = NSNumber(value: Double(bitPattern: UInt64(bigEndian: payload.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })))
        case .font:
            value = (try? JSONDecoder().decode(FontCoding.self, from: payload)).map(\.font)
        case .color:
            value = (try? JSONDecoder().decode(ColorCoding.self, from: payload)).map(\.color)
        case .paragraphStyle:
            value = (try? JSONDecoder().decode(ParagraphCoding.self, from: payload)).map(paragraphStyle)
        case .image:
            value = image(from: Data(payload))
        case .pageField:
            value = payload.first.flatMap { PageFieldAttachment.Kind(rawValue: Int($0)) }.map { PageFieldAttachment(kind: $0) }
        case .archive:
            value = Self.unarchive(Data(payload))
        }
        if cacheable, let value {
            if decodedCount > 2_000 {
                decoded = [:]
                decodedCount = 0
            }
            decoded[key.rawValue, default: [:]][data] = value
            decodedCount += 1
        }
        return value
    }

    private func image(from payload: Data) -> NSTextAttachment? {
        guard payload.count >= 4 else { return nil }
        let length = Int(UInt32(bigEndian: payload.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
        guard payload.count >= 4 + length,
              let header = try? JSONDecoder().decode(ImageHeader.self, from: payload.dropFirst(4).prefix(length)) else { return nil }
        let bytes = Data(payload.dropFirst(4 + length))
        return ImageAttachments.make(data: bytes, type: UTType(header.type), size: CGSize(width: header.width, height: header.height))
    }

    private struct ImageHeader: Codable {
        var type: String
        var width: Double
        var height: Double
    }

    private static let archivedClasses: [AnyClass] = [
        NSString.self, NSNumber.self, NSDictionary.self, NSArray.self, NSURL.self, NSFont.self, NSColor.self, NSShadow.self,
        ListItem.self, RequestedFont.self, SuggestionMark.self, NSData.self, NSDate.self, NSValue.self,
    ]

    private func archive(_ value: Any) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: true)
    }

    private static func unarchive(_ data: Data) -> Any? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClasses: archivedClasses, from: data)
    }

    /// Sorted keys, so the same value always gives the same bytes.
    private static func json(_ value: some Encodable) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(value)) ?? Data()
    }

    // MARK: Fonts and colors

    private struct FontCoding: Codable {
        var name: String
        var family: String
        var size: Double
        var bold: Bool
        var italic: Bool

        var font: NSFont {
            if let font = NSFont(name: name, size: size) { return font }
            return FontResolver.font(family: family, size: size, bold: bold, italic: italic)
        }
    }

    struct ColorCoding: Codable, Equatable {
        var r: Double
        var g: Double
        var b: Double
        var a: Double

        init(_ color: NSColor) {
            r = Double(color.redComponent)
            g = Double(color.greenComponent)
            b = Double(color.blueComponent)
            a = Double(color.alphaComponent)
        }

        var color: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    }

    // MARK: Paragraph styles, tables and cells

    struct ParagraphCoding: Codable {
        var alignment: Int
        var firstLineHeadIndent: Double
        var headIndent: Double
        var tailIndent: Double
        var lineHeightMultiple: Double
        var maximumLineHeight: Double
        var minimumLineHeight: Double
        var lineSpacing: Double
        var paragraphSpacing: Double
        var paragraphSpacingBefore: Double
        var baseWritingDirection: Int
        var lineBreakMode: UInt
        var hyphenationFactor: Float
        var headerLevel: Int
        var defaultTabInterval: Double
        var tabs: [TabCoding]
        var blocks: [BlockCoding]
        var lists: [ListCoding]
    }

    struct TabCoding: Codable {
        var alignment: Int
        var location: Double
    }

    struct ListCoding: Codable {
        var format: String
        var options: UInt
        var start: Int
    }

    struct BlockCoding: Codable {
        var id: String
        var table: TableCoding?
        var row: Int
        var rowSpan: Int
        var column: Int
        var columnSpan: Int
        var box: BoxCoding
    }

    struct TableCoding: Codable {
        var id: String
        var columns: Int
        var layout: Int
        var collapsesBorders: Bool
        var hidesEmptyCells: Bool
        var box: BoxCoding
    }

    /// Everything an `NSTextBlock` says about its box: widths of its padding, border and margin on each edge, border
    /// colors, sizes, background and vertical alignment.
    struct BoxCoding: Codable {
        var verticalAlignment: Int
        var background: ColorCoding?
        /// Layer by layer (padding, border, margin), edge by edge (min x, min y, max x, max y): value and its type.
        var edges: [[Double]]
        var borderColors: [ColorCoding?]
        /// Width, minimum and maximum width, height, minimum and maximum height: value and type.
        var dimensions: [[Double]]
    }

    private static let layers: [NSTextBlock.Layer] = [.padding, .border, .margin]
    private static let edges: [NSRectEdge] = [.minX, .minY, .maxX, .maxY]
    private static let dimensions: [NSTextBlock.Dimension] = [.width, .minimumWidth, .maximumWidth, .height, .minimumHeight, .maximumHeight]

    private func box(of block: NSTextBlock) -> BoxCoding {
        var edges: [[Double]] = []
        for layer in Self.layers {
            for edge in Self.edges {
                edges.append([Double(block.width(for: layer, edge: edge)), Double(block.widthValueType(for: layer, edge: edge).rawValue)])
            }
        }
        let colors = Self.edges.map { edge in block.borderColor(for: edge).flatMap { $0.usingColorSpace(.sRGB) }.map(ColorCoding.init) }
        let dimensions = Self.dimensions.map { [Double(block.value(for: $0)), Double(block.valueType(for: $0).rawValue)] }
        return BoxCoding(verticalAlignment: block.verticalAlignment.rawValue,
                         background: block.backgroundColor.flatMap { $0.usingColorSpace(.sRGB) }.map(ColorCoding.init),
                         edges: edges, borderColors: colors, dimensions: dimensions)
    }

    private func setBox(_ box: BoxCoding, on block: NSTextBlock) {
        block.verticalAlignment = NSTextBlock.VerticalAlignment(rawValue: box.verticalAlignment) ?? .topAlignment
        block.backgroundColor = box.background?.color
        var index = 0
        for layer in Self.layers {
            for edge in Self.edges {
                if index < box.edges.count, box.edges[index].count == 2 {
                    let type = NSTextBlock.ValueType(rawValue: Int(box.edges[index][1])) ?? .absoluteValueType
                    block.setWidth(CGFloat(box.edges[index][0]), type: type, for: layer, edge: edge)
                }
                index += 1
            }
        }
        for (offset, edge) in Self.edges.enumerated() where offset < box.borderColors.count {
            if let color = box.borderColors[offset]?.color { block.setBorderColor(color, for: edge) }
        }
        for (offset, dimension) in Self.dimensions.enumerated() where offset < box.dimensions.count && box.dimensions[offset].count == 2 {
            let value = box.dimensions[offset]
            block.setValue(CGFloat(value[0]), type: NSTextBlock.ValueType(rawValue: Int(value[1])) ?? .absoluteValueType, for: dimension)
        }
    }

    private func identifier(of table: NSTextTable) -> String {
        if let id = tableIDs.object(forKey: table) { return id as String }
        let id = UUID().uuidString as NSString
        tableIDs.setObject(id, forKey: table)
        tablesByID.setObject(table, forKey: id)
        return id as String
    }

    private func identifier(of block: NSTextBlock) -> String {
        if let id = blockIDs.object(forKey: block) { return id as String }
        let id = UUID().uuidString as NSString
        blockIDs.setObject(id, forKey: block)
        blocksByID.setObject(block, forKey: id)
        return id as String
    }

    private func paragraphCoding(_ style: NSParagraphStyle) -> ParagraphCoding {
        let blocks = style.textBlocks.map { block -> BlockCoding in
            if let cell = block as? NSTextTableBlock {
                let table = cell.table
                let tableCoding = TableCoding(id: identifier(of: table), columns: table.numberOfColumns, layout: table.layoutAlgorithm.rawValue,
                                              collapsesBorders: table.collapsesBorders, hidesEmptyCells: table.hidesEmptyCells, box: box(of: table))
                return BlockCoding(id: identifier(of: cell), table: tableCoding, row: cell.startingRow, rowSpan: cell.rowSpan,
                                   column: cell.startingColumn, columnSpan: cell.columnSpan, box: box(of: cell))
            }
            return BlockCoding(id: identifier(of: block), table: nil, row: 0, rowSpan: 1, column: 0, columnSpan: 1, box: box(of: block))
        }
        return ParagraphCoding(
            alignment: style.alignment.rawValue, firstLineHeadIndent: Double(style.firstLineHeadIndent), headIndent: Double(style.headIndent),
            tailIndent: Double(style.tailIndent), lineHeightMultiple: Double(style.lineHeightMultiple),
            maximumLineHeight: Double(style.maximumLineHeight), minimumLineHeight: Double(style.minimumLineHeight),
            lineSpacing: Double(style.lineSpacing), paragraphSpacing: Double(style.paragraphSpacing),
            paragraphSpacingBefore: Double(style.paragraphSpacingBefore), baseWritingDirection: style.baseWritingDirection.rawValue,
            lineBreakMode: style.lineBreakMode.rawValue, hyphenationFactor: style.hyphenationFactor, headerLevel: style.headerLevel,
            defaultTabInterval: Double(style.defaultTabInterval),
            tabs: style.tabStops.map { TabCoding(alignment: $0.alignment.rawValue, location: Double($0.location)) },
            blocks: blocks,
            lists: style.textLists.map { ListCoding(format: $0.markerFormat.rawValue, options: $0.listOptions.rawValue, start: $0.startingItemNumber) })
    }

    private func paragraphStyle(_ coding: ParagraphCoding) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = NSTextAlignment(rawValue: coding.alignment) ?? .natural
        style.firstLineHeadIndent = CGFloat(coding.firstLineHeadIndent)
        style.headIndent = CGFloat(coding.headIndent)
        style.tailIndent = CGFloat(coding.tailIndent)
        style.lineHeightMultiple = CGFloat(coding.lineHeightMultiple)
        style.maximumLineHeight = CGFloat(coding.maximumLineHeight)
        style.minimumLineHeight = CGFloat(coding.minimumLineHeight)
        style.lineSpacing = CGFloat(coding.lineSpacing)
        style.paragraphSpacing = CGFloat(coding.paragraphSpacing)
        style.paragraphSpacingBefore = CGFloat(coding.paragraphSpacingBefore)
        style.baseWritingDirection = NSWritingDirection(rawValue: coding.baseWritingDirection) ?? .natural
        style.lineBreakMode = NSLineBreakMode(rawValue: coding.lineBreakMode) ?? .byWordWrapping
        style.hyphenationFactor = coding.hyphenationFactor
        style.headerLevel = coding.headerLevel
        style.defaultTabInterval = CGFloat(coding.defaultTabInterval)
        style.tabStops = coding.tabs.map { NSTextTab(textAlignment: NSTextAlignment(rawValue: $0.alignment) ?? .left, location: CGFloat($0.location)) }
        // Setting no blocks isn't the same as never setting them: the style would no longer equal one that never had
        // any, and every Mac would keep "restyling" the other's text.
        if !coding.blocks.isEmpty { style.textBlocks = coding.blocks.map(block) }
        if !coding.lists.isEmpty {
            style.textLists = coding.lists.map { list in
                let textList = NSTextList(markerFormat: NSTextList.MarkerFormat(rawValue: list.format), options: Int(list.options))
                textList.startingItemNumber = list.start
                return textList
            }
        }
        return style.copy() as! NSParagraphStyle
    }

    /// The cell or block with this identifier: the one already here, else a new one made to the description.
    private func block(_ coding: BlockCoding) -> NSTextBlock {
        if let existing = blocksByID.object(forKey: coding.id as NSString) { return existing }
        let block: NSTextBlock
        if let tableCoding = coding.table {
            let table: NSTextTable
            if let existing = tablesByID.object(forKey: tableCoding.id as NSString) {
                table = existing
            } else {
                table = NSTextTable()
                table.numberOfColumns = tableCoding.columns
                table.layoutAlgorithm = NSTextTable.LayoutAlgorithm(rawValue: tableCoding.layout) ?? .automaticLayoutAlgorithm
                table.collapsesBorders = tableCoding.collapsesBorders
                table.hidesEmptyCells = tableCoding.hidesEmptyCells
                setBox(tableCoding.box, on: table)
                tablesByID.setObject(table, forKey: tableCoding.id as NSString)
                tableIDs.setObject(tableCoding.id as NSString, forKey: table)
            }
            block = NSTextTableBlock(table: table, startingRow: coding.row, rowSpan: max(1, coding.rowSpan),
                                     startingColumn: coding.column, columnSpan: max(1, coding.columnSpan))
        } else {
            block = NSTextBlock()
        }
        setBox(coding.box, on: block)
        blocksByID.setObject(block, forKey: coding.id as NSString)
        blockIDs.setObject(coding.id as NSString, forKey: block)
        return block
    }
}
