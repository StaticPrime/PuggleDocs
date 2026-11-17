import AppKit
import PuggleDocsKit

extension EditorController {
    /// Normal-text attributes for new cells.
    var tableCellAttributes: [NSAttributedString.Key: Any] { NamedStyle.normal.attributes() }

    /// Inserts an empty table at the caret, on its own lines, and puts the caret in the first cell.
    func insertTable(rows: Int, columns: Int) {
        guard state.isEditable, !isEditingHeaderFooter, rows > 0, columns > 0 else { return }
        let textView = activeTextView
        let range = textView.selectedRange()
        let string = textStorage.string as NSString
        let cellAttributes = tableCellAttributes
        let insertion = NSMutableAttributedString()
        let paragraph = string.paragraphRange(for: NSRange(location: min(range.location, string.length), length: 0))
        let startsParagraph = range.location == paragraph.location
        if !startsParagraph { insertion.append(NSAttributedString(string: "\n", attributes: textView.typingAttributes)) }
        let firstCell = range.location + insertion.length
        insertion.append(TableModel.empty(rows: rows, columns: columns, attributes: cellAttributes)
            .attributedString(attributes: cellAttributes, availableWidth: pageSetup.contentSize.width))
        if NSMaxRange(range) >= string.length { insertion.append(NSAttributedString(string: "\n", attributes: cellAttributes)) }
        textView.breakUndoCoalescing()
        guard withDirectEdits({ textView.shouldChangeText(in: range, replacementString: insertion.string) }) else { return }
        textStorage.replaceCharacters(in: range, with: insertion)
        textView.didChangeText()
        undoManager?.setActionName("Insert Table")
        textView.setSelectedRange(NSRange(location: firstCell, length: 0))
        textView.typingAttributes = textStorage.attributes(at: firstCell, effectiveRange: nil)
        focus()
    }
}

extension EditorController {
    /// The table and cell at the caret.
    func tableAtCaret() -> (model: TableModel, cell: TableModel.Cell)? {
        let location = activeTextView.selectedRange().location
        guard !isEditingHeaderFooter, let model = TableModel.table(at: location, in: textStorage),
              let cell = model.cell(containing: location) else { return nil }
        return (model, cell)
    }

    var isInTable: Bool { tableAtCaret() != nil }

    /// Rebuilds the table at the caret after `change`, as one undoable edit; the caret goes to `target`.
    func modifyTable(_ actionName: String, _ change: (inout TableModel, TableModel.Cell) -> (row: Int, column: Int)?) {
        guard state.isEditable, let (original, cell) = tableAtCaret() else { return }
        var model = original
        let target = change(&model, cell)
        let replacement: NSAttributedString = model.cells.isEmpty || model.rows == 0 || model.columns == 0
            ? NSAttributedString()
            : model.attributedString(attributes: tableCellAttributes, availableWidth: pageSetup.contentSize.width)
        let textView = activeTextView
        textView.breakUndoCoalescing()
        guard withDirectEdits({ textView.shouldChangeText(in: original.range, replacementString: replacement.string) }) else { return }
        textStorage.replaceCharacters(in: original.range, with: replacement)
        textView.didChangeText()
        undoManager?.setActionName(actionName)
        if let target, let rebuilt = TableModel.table(at: original.range.location, in: textStorage),
           let destination = rebuilt.cell(row: target.row, column: target.column)?.textRange {
            textView.setSelectedRange(NSRange(location: destination.location, length: 0))
        } else {
            textView.setSelectedRange(NSRange(location: min(original.range.location, textStorage.length), length: 0))
        }
        focus()
    }

    func insertTableRow(below: Bool) {
        modifyTable(below ? "Insert Row Below" : "Insert Row Above") { model, cell in
            let row = below ? cell.row + cell.rowSpan : cell.row
            model.insertRow(at: row)
            return (row, cell.column)
        }
    }

    func insertTableColumn(right: Bool) {
        modifyTable(right ? "Insert Column Right" : "Insert Column Left") { model, cell in
            let column = right ? cell.column + cell.columnSpan : cell.column
            model.insertColumn(at: column)
            return (cell.row, column)
        }
    }

    func deleteTableRow() {
        modifyTable("Delete Row") { model, cell in
            if model.rows <= 1 { model.cells = []; return nil }
            model.deleteRow(cell.row)
            return (min(cell.row, model.rows - 1), cell.column)
        }
    }

    func deleteTableColumn() {
        modifyTable("Delete Column") { model, cell in
            if model.columns <= 1 { model.cells = []; return nil }
            model.deleteColumn(cell.column)
            return (cell.row, min(cell.column, model.columns - 1))
        }
    }

    func deleteTable() {
        modifyTable("Delete Table") { model, _ in
            model.cells = []
            return nil
        }
    }

    func applyTableProperties(borderWidth: CGFloat, borderColor: NSColor, cellBackground: NSColor?, distributeColumns: Bool) {
        modifyTable("Table Properties") { model, cell in
            model.borderWidth = borderWidth
            model.borderColor = borderColor
            if let index = model.index(row: cell.row, column: cell.column) { model.cells[index].background = cellBackground }
            if distributeColumns { model.columnWidths = Array(repeating: 1 / CGFloat(model.columns), count: model.columns) }
            return (cell.row, cell.column)
        }
    }

    // MARK: Keyboard

    /// Tab and Shift-Tab move between cells; Tab in the last cell adds a row.
    func handleTableTab(backwards: Bool) -> Bool {
        guard let (model, cell) = tableAtCaret() else { return false }
        let ordered = model.orderedCells
        guard let index = ordered.firstIndex(where: { $0.row == cell.row && $0.column == cell.column }) else { return false }
        if backwards {
            guard index > 0, let range = ordered[index - 1].textRange else { return true }
            activeTextView.setSelectedRange(range)
            return true
        }
        if index == ordered.count - 1 {
            modifyTable("Insert Row") { model, _ in
                model.insertRow(at: model.rows)
                return (model.rows - 1, 0)
            }
            return true
        }
        if let range = ordered[index + 1].textRange { activeTextView.setSelectedRange(range) }
        return true
    }

    /// Backspace at the start of a cell does nothing; just after a table it moves into the last cell.
    func handleTableDeleteBackward() -> Bool {
        let selection = activeTextView.selectedRange()
        guard selection.length == 0 else { return false }
        if let (_, cell) = tableAtCaret(), cell.textRange?.location == selection.location { return true }
        if selection.location > 0, TableModel.block(at: selection.location, in: textStorage) == nil,
           let previous = TableModel.table(at: selection.location - 1, in: textStorage), NSMaxRange(previous.range) == selection.location {
            let string = textStorage.string as NSString
            let paragraph = string.paragraphRange(for: NSRange(location: selection.location, length: 0))
            if paragraph.length <= 1, NSMaxRange(paragraph) < string.length {
                // An empty line between tables or before text: delete it instead.
                return false
            }
            activeTextView.setSelectedRange(NSRange(location: NSMaxRange(previous.range) - 1, length: 0))
            return true
        }
        return false
    }

    /// Delete at the end of a cell does nothing, so cells never merge.
    func handleTableDeleteForward() -> Bool {
        let selection = activeTextView.selectedRange()
        guard selection.length == 0 else { return false }
        if let (_, cell) = tableAtCaret(), let range = cell.textRange, NSMaxRange(range) == selection.location { return true }
        if selection.location < textStorage.length, TableModel.block(at: selection.location, in: textStorage) == nil,
           TableModel.block(at: selection.location + 1, in: textStorage) != nil,
           (textStorage.string as NSString).character(at: selection.location) == 0x0A {
            return true
        }
        return false
    }
}
