import AppKit
import Testing
@testable import MenuBarApp

@MainActor struct NoteTableEditTests {
    private let source = "| Environment   | Parked deploy |\n|:--------------|--------------:|\n| `dev`         | Not parked.   |\n| prd \\| shared | Waits         |"

    @Test func rowEditsLeaveTheOtherLinesAsTheyWereWritten() throws {
        var table = try #require(NoteTableSource(source))
        let lines = source.components(separatedBy: "\n")
        table.apply(.insertRow(2))
        #expect(table.lines == [lines[0], lines[1], lines[2], "|  |  |", lines[3]])
        table.apply(.setCell(row: 2, column: 0, text: "stg"))
        table.apply(.setCell(row: 2, column: 1, text: "Goes\nahead | fast"))
        #expect(table.lines[3] == "| stg | Goes ahead \\| fast |")
        #expect(table.cell(row: 2, column: 1) == "Goes ahead | fast")
        table.apply(.moveRow(2, by: -1))
        #expect(table.lines == [lines[0], lines[1], "| stg | Goes ahead \\| fast |", lines[2], lines[3]])
        table.apply(.deleteRow(1))
        #expect(table.text == source)
    }

    @Test func theHeaderStaysFirstAndOutOfReachOfRowEdits() throws {
        var table = try #require(NoteTableSource(source))
        for edit: NoteTableEdit in [.deleteRow(0), .moveRow(1, by: -1), .moveRow(0, by: 1), .insertRow(0), .moveRow(3, by: 1)] {
            table.apply(edit)
        }
        #expect(table.text == source)
    }

    @Test func columnEditsRewriteEveryLineAndCarryTheAlignment() throws {
        var table = try #require(NoteTableSource(source))
        table.apply(.insertColumn(1))
        #expect(table.text == "| Environment |  | Parked deploy |\n| --- | --- | ---: |\n| `dev` |  | Not parked. |\n| prd \\| shared |  | Waits |")
        table.apply(.align(1, .center))
        table.apply(.moveColumn(1, by: 1))
        #expect(table.alignment(of: 1) == .trailing)
        #expect(table.alignment(of: 2) == .center)
        #expect(table.cell(row: 0, column: 1) == "Parked deploy")
        table.apply(.deleteColumn(2))
        table.apply(.deleteColumn(1))
        table.apply(.deleteColumn(0))
        #expect(table.columnCount == 1)
        #expect(table.cell(row: 2, column: 0) == "prd | shared")
    }

    @Test func aCellEditedInPlaceGoesBackIntoTheDocumentAndCanBeUndone() throws {
        let writing = try #require(MarkdownWritingDocument("Intro\n\n\(source)\n\nOutro\n"))
        let view = NoteTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let undo = UndoManager()
        let window = UndoWindow(view: view, undo: undo)
        defer { window.close() }
        view.allowsUndo = true
        view.isEditable = true
        view.textStorage?.setAttributedString(writing.document.attributed)
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let tableAt = (view.string as NSString).range(of: "\u{FFFC}").location

        view.editCell(table: tableAt, row: 1, column: 1)
        let editor = try #require(view.subviews.compactMap { $0 as? NoteTableCellEditor }.first)
        #expect(editor.field.stringValue == "Not parked.")
        editor.field.stringValue = "Parked for review."
        // Tab moves on to the next cell, which is the first one of the next row.
        _ = editor.control(editor.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:)))
        let next = try #require(view.subviews.compactMap { $0 as? NoteTableCellEditor }.first { $0 !== editor })
        #expect((next.row, next.column) == (2, 0))
        _ = next.control(next.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))

        let edited = NoteDocument(view.attributedString())
        #expect(writing.markdown(afterEditing: edited).contains("\n| `dev` | Parked for review. |\n"))
        #expect(edited.runs.filter { $0.block == .table }.count == 1)
        undo.undo()
        #expect(writing.markdown(afterEditing: NoteDocument(view.attributedString())) == "Intro\n\n\(source)\n\nOutro\n")
    }

    @Test func tabbingOutOfTheLastCellAddsARow() throws {
        let view = NoteTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.isEditable = true
        view.textStorage?.setAttributedString(NoteDocument(runs: [.init(text: "| A | B |\n| - | - |\n| 1 | 2 |", block: .table)]).attributed)
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        view.editCell(table: 0, row: 1, column: 1)
        let editor = try #require(view.subviews.compactMap { $0 as? NoteTableCellEditor }.first)
        _ = editor.control(editor.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:)))
        let next = try #require(view.subviews.compactMap { $0 as? NoteTableCellEditor }.first { $0 !== editor })
        #expect((next.row, next.column) == (2, 0))
        #expect(NoteDocument(view.attributedString()).runs.first?.text == "| A | B |\n| - | - |\n| 1 | 2 |\n|  |  |")
    }
}

// A text view only reaches an undo manager through its window.
private final class UndoWindow: NSWindow, NSWindowDelegate {
    private let undo: UndoManager

    init(view: NSView, undo: UndoManager) {
        self.undo = undo
        super.init(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        isReleasedWhenClosed = false
        contentView = view
        delegate = self
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undo }
}
