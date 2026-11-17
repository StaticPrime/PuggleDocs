import AppKit

/// Tables are AppKit text tables: every cell is one or more paragraphs whose paragraph style holds
/// an `NSTextTableBlock` for that cell. `TableModel` captures a table so it can be edited and rebuilt.
public struct TableModel {
    public struct Cell {
        public var row: Int
        public var column: Int
        public var rowSpan = 1
        public var columnSpan = 1
        /// The cell's paragraphs without the final paragraph separator.
        public var content: NSAttributedString
        public var background: NSColor?
        /// Where the cell's content sits in the text the table was read from.
        public var textRange: NSRange?

        public init(row: Int, column: Int, rowSpan: Int = 1, columnSpan: Int = 1, content: NSAttributedString, background: NSColor? = nil) {
            self.row = row
            self.column = column
            self.rowSpan = rowSpan
            self.columnSpan = columnSpan
            self.content = content
            self.background = background
        }
    }

    public var rows: Int
    public var columns: Int
    public var cells: [Cell]
    /// Column widths as fractions of the table width (sum to 1).
    public var columnWidths: [CGFloat]
    public var borderWidth: CGFloat = 1
    public var borderColor: NSColor = .black
    public var padding: CGFloat = 5
    /// Range of the table in the text it was read from.
    public var range = NSRange(location: 0, length: 0)

    public init(rows: Int, columns: Int, cells: [Cell], columnWidths: [CGFloat]? = nil) {
        self.rows = rows
        self.columns = columns
        self.cells = cells
        let widths = columnWidths ?? Array(repeating: 1 / CGFloat(max(columns, 1)), count: columns)
        let total = widths.reduce(0, +)
        self.columnWidths = total > 0 ? widths.map { $0 / total } : Array(repeating: 1 / CGFloat(max(columns, 1)), count: columns)
    }

    /// An empty table with the default look of a new table.
    public static func empty(rows: Int, columns: Int, attributes: [NSAttributedString.Key: Any]) -> TableModel {
        var cells: [Cell] = []
        let empty = NSAttributedString(string: "", attributes: attributes)
        for row in 0..<rows {
            for column in 0..<columns { cells.append(Cell(row: row, column: column, content: empty)) }
        }
        return TableModel(rows: rows, columns: columns, cells: cells)
    }

    public var hasMergedCells: Bool { cells.contains { $0.rowSpan > 1 || $0.columnSpan > 1 } }

    /// Cells in reading order (row by row).
    public var orderedCells: [Cell] { cells.sorted { ($0.row, $0.column) < ($1.row, $1.column) } }

    /// The cell whose text contains `index` (cell contents plus their paragraph end).
    public func cell(containing index: Int) -> Cell? {
        orderedCells.first { cell in
            guard let range = cell.textRange else { return false }
            return index >= range.location && index <= NSMaxRange(range)
        }
    }

    public func cell(row: Int, column: Int) -> Cell? {
        cells.first { $0.row <= row && row < $0.row + $0.rowSpan && $0.column <= column && column < $0.column + $0.columnSpan }
    }

    public func index(row: Int, column: Int) -> Int? {
        cells.firstIndex { $0.row == row && $0.column == column }
    }

    // MARK: Building text

    /// The table as attributed text. Each cell ends with a newline; `attributes` style empty cells.
    /// With `availableWidth` the columns get exact widths that fit it; otherwise proportional widths.
    public func attributedString(attributes: [NSAttributedString.Key: Any], availableWidth: CGFloat? = nil) -> NSAttributedString {
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setContentWidth(100, type: .percentageValueType)
        let result = NSMutableAttributedString()
        for cell in cells.sorted(by: { ($0.row, $0.column) < ($1.row, $1.column) }) {
            let block = NSTextTableBlock(table: table, startingRow: cell.row, rowSpan: cell.rowSpan,
                                         startingColumn: cell.column, columnSpan: cell.columnSpan)
            block.setWidth(borderWidth, type: .absoluteValueType, for: .border)
            block.setBorderColor(borderColor)
            block.setWidth(padding, type: .absoluteValueType, for: .padding)
            let fraction = (cell.column..<min(cell.column + cell.columnSpan, columns)).reduce(CGFloat(0)) { $0 + columnWidths[$1] }
            if let availableWidth {
                // Each cell's width counts both of its borders, even when they collapse.
                block.setContentWidth(max(8, fraction * availableWidth - 2 * padding - 2 * borderWidth), type: .absoluteValueType)
            } else {
                block.setContentWidth(fraction * 100, type: .percentageValueType)
            }
            block.verticalAlignment = .topAlignment
            block.backgroundColor = cell.background
            let content = NSMutableAttributedString(attributedString: cell.content)
            let paragraphEnd = NSAttributedString(string: "\n", attributes: content.length > 0
                ? content.attributes(at: content.length - 1, effectiveRange: nil) : attributes)
            content.append(paragraphEnd)
            TableModel.setBlocks(in: content, prepending: block)
            result.append(content)
        }
        return result
    }

    /// Gives proportionally sized cells in `range` exact widths that fit `availableWidth`,
    /// accounting for padding and borders, so tables stay inside the margins.
    public static func fitTables(in text: NSAttributedString, range: NSRange, availableWidth: CGFloat) {
        guard range.length > 0, NSMaxRange(range) <= text.length else { return }
        text.enumerateAttribute(.paragraphStyle, in: range, options: []) { value, _, _ in
            guard let style = value as? NSParagraphStyle else { return }
            for case let block as NSTextTableBlock in style.textBlocks where block.contentWidthValueType == .percentageValueType {
                let padding = block.width(for: .padding, edge: .minX) * 2
                let border = block.width(for: .border, edge: .minX)
                // Each cell's width counts both of its borders, even when they collapse.
                block.setContentWidth(max(8, block.contentWidth / 100 * availableWidth - padding - 2 * border), type: .absoluteValueType)
            }
        }
    }

    /// Scales exact cell widths when the text area changes width (new margins or paper).
    public static func rescaleTables(in text: NSAttributedString, by factor: CGFloat) {
        guard text.length > 0, factor > 0, abs(factor - 1) > 0.001 else { return }
        var seen = Set<ObjectIdentifier>()
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length), options: []) { value, _, _ in
            guard let style = value as? NSParagraphStyle else { return }
            for case let block as NSTextTableBlock in style.textBlocks where block.contentWidthValueType == .absoluteValueType {
                guard seen.insert(ObjectIdentifier(block)).inserted else { continue }
                block.setContentWidth(max(8, block.contentWidth * factor), type: .absoluteValueType)
            }
        }
    }

    /// Adds `block` as the outermost text block of every paragraph in `text`.
    public static func setBlocks(in text: NSMutableAttributedString, prepending block: NSTextBlock) {
        let string = text.string as NSString
        var location = 0
        while location < string.length {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)
            let base = (text.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle) ?? DocumentDefaults.paragraphStyle()
            let style = base.mutableCopy() as! NSMutableParagraphStyle
            style.textBlocks = [block] + style.textBlocks.filter { !($0 is NSTextTableBlock && ($0 as! NSTextTableBlock).table === (block as? NSTextTableBlock)?.table) }
            text.addAttribute(.paragraphStyle, value: style.copy() as! NSParagraphStyle, range: paragraph)
        }
    }

    // MARK: Reading text

    /// The outermost table block of the paragraph containing `index`.
    public static func block(at index: Int, in text: NSAttributedString) -> NSTextTableBlock? {
        guard index < text.length || (index == text.length && index > 0) else { return nil }
        let location = min(index, text.length - 1)
        guard let style = text.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle else { return nil }
        return style.textBlocks.first as? NSTextTableBlock
    }

    /// Reads the table containing `index`, or nil when `index` is not inside a table.
    public static func table(at index: Int, in text: NSAttributedString) -> TableModel? {
        guard let block = block(at: index, in: text) else { return nil }
        let table = block.table
        let string = text.string as NSString
        func belongs(_ paragraphStart: Int) -> Bool {
            (text.attribute(.paragraphStyle, at: paragraphStart, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.first
                .map { ($0 as? NSTextTableBlock)?.table === table } ?? false
        }
        var start = string.paragraphRange(for: NSRange(location: min(index, text.length - 1), length: 0)).location
        while start > 0 {
            let previous = string.paragraphRange(for: NSRange(location: start - 1, length: 0))
            guard belongs(previous.location) else { break }
            start = previous.location
        }
        var end = start
        var cells: [Cell] = []
        var currentBlock: NSTextTableBlock?
        var cellStart = start
        func finishCell(upTo location: Int) {
            guard let current = currentBlock else { return }
            var range = NSRange(location: cellStart, length: location - cellStart)
            if range.length > 0, string.character(at: NSMaxRange(range) - 1) == 0x0A { range.length -= 1 }
            let content = NSMutableAttributedString(attributedString: text.attributedSubstring(from: range))
            TableModel.removeBlock(of: table, from: content)
            var cell = Cell(row: current.startingRow, column: current.startingColumn, rowSpan: current.rowSpan,
                            columnSpan: current.columnSpan, content: content, background: current.backgroundColor)
            cell.textRange = range
            cells.append(cell)
        }
        while end < string.length {
            let paragraph = string.paragraphRange(for: NSRange(location: end, length: 0))
            guard belongs(paragraph.location),
                  let cellBlock = (text.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock
            else { break }
            if cellBlock !== currentBlock {
                finishCell(upTo: paragraph.location)
                currentBlock = cellBlock
                cellStart = paragraph.location
            }
            end = NSMaxRange(paragraph)
        }
        finishCell(upTo: end)
        let rows = (cells.map { $0.row + $0.rowSpan }.max() ?? 0)
        let columns = max(table.numberOfColumns, cells.map { $0.column + $0.columnSpan }.max() ?? 0)
        var widths: [CGFloat] = Array(repeating: 0, count: columns)
        for cell in cells where cell.columnSpan == 1 {
            guard let block = cellBlockFor(cell, in: text, table: table), block.contentWidth > 0 else { continue }
            if block.contentWidthValueType == .percentageValueType {
                widths[cell.column] = block.contentWidth
            } else {
                widths[cell.column] = block.contentWidth + block.width(for: .padding, edge: .minX) * 2 + block.width(for: .border, edge: .minX)
            }
        }
        var model = TableModel(rows: rows, columns: columns, cells: cells, columnWidths: widths.contains(0) ? nil : widths)
        if let first = cellBlockFor(cells.first, in: text, table: table) {
            model.borderWidth = first.width(for: .border, edge: .minX)
            model.borderColor = first.borderColor(for: .minX) ?? .black
            model.padding = first.width(for: .padding, edge: .minX)
        }
        model.range = NSRange(location: start, length: end - start)
        return model
    }

    private static func cellBlockFor(_ cell: Cell?, in text: NSAttributedString, table: NSTextTable) -> NSTextTableBlock? {
        guard let cell else { return nil }
        var found: NSTextTableBlock?
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length), options: []) { value, _, stop in
            guard let block = (value as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock, block.table === table,
                  block.startingRow == cell.row, block.startingColumn == cell.column else { return }
            found = block
            stop.pointee = true
        }
        return found
    }

    /// Removes the blocks belonging to `table` from every paragraph of `text`.
    public static func removeBlock(of table: NSTextTable, from text: NSMutableAttributedString) {
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length), options: []) { value, range, _ in
            guard let style = value as? NSParagraphStyle, style.textBlocks.contains(where: { ($0 as? NSTextTableBlock)?.table === table }) else { return }
            let updated = style.mutableCopy() as! NSMutableParagraphStyle
            updated.textBlocks = style.textBlocks.filter { ($0 as? NSTextTableBlock)?.table !== table }
            text.addAttribute(.paragraphStyle, value: updated.copy() as! NSParagraphStyle, range: range)
        }
    }

    // MARK: Editing

    public mutating func insertRow(at row: Int) {
        let row = min(max(row, 0), rows)
        for index in cells.indices where cells[index].row >= row { cells[index].row += 1 }
        let attributes = cells.first.map { $0.content.length > 0 ? $0.content.attributes(at: 0, effectiveRange: nil) : [:] } ?? [:]
        for column in 0..<columns {
            cells.append(Cell(row: row, column: column, content: NSAttributedString(string: "", attributes: attributes)))
        }
        rows += 1
    }

    public mutating func insertColumn(at column: Int) {
        let column = min(max(column, 0), columns)
        for index in cells.indices where cells[index].column >= column { cells[index].column += 1 }
        for row in 0..<rows { cells.append(Cell(row: row, column: column, content: NSAttributedString())) }
        columns += 1
        var widths = columnWidths
        widths.insert(1 / CGFloat(columns), at: column)
        let total = widths.reduce(0, +)
        columnWidths = widths.map { $0 / total }
    }

    public mutating func deleteRow(_ row: Int) {
        guard rows > 1 else { return }
        cells.removeAll { $0.row == row }
        for index in cells.indices where cells[index].row > row { cells[index].row -= 1 }
        rows -= 1
    }

    public mutating func deleteColumn(_ column: Int) {
        guard columns > 1 else { return }
        cells.removeAll { $0.column == column }
        for index in cells.indices where cells[index].column > column { cells[index].column -= 1 }
        columns -= 1
        var widths = columnWidths
        widths.remove(at: column)
        let total = widths.reduce(0, +)
        columnWidths = widths.map { $0 / total }
    }
}
