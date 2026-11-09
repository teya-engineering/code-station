import AppKit
import SwiftUI

@MainActor @Observable
final class NoteEditorController {
    @ObservationIgnored weak var view: NoteTextView?
    var bold = false
    var italic = false
    var block = NoteDocument.Block.text
    var indent = 0
    var checked = false

    func focus() { if let view { view.window?.makeFirstResponder(view) } }

    func readSelection() {
        guard let view else { return }
        let range = view.selectedRange()
        let attributes = range.length > 0 && range.location < (view.textStorage?.length ?? 0)
            ? view.textStorage?.attributes(at: range.location, effectiveRange: nil) ?? [:]
            : view.typingAttributes
        let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
        bold = traits.contains(.bold)
        italic = traits.contains(.italic)
        block = (attributes[.noteBlock] as? String).flatMap(NoteDocument.Block.init(rawValue:)) ?? .text
        indent = attributes[.noteIndent] as? Int ?? 0
        let paragraph = (view.string as NSString).paragraphRange(for: range)
        checked = (view.string as NSString).substring(with: paragraph).hasPrefix("☑")
    }

    func toggleTrait(_ trait: NSFontTraitMask) {
        guard let view, view.isEditable else { return }
        focus()
        let range = view.selectedRange()
        let removing = trait == .boldFontMask ? bold : italic
        func converted(_ attributes: [NSAttributedString.Key: Any]) -> NSFont {
            let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 14)
            return removing ? NSFontManager.shared.convert(font, toNotHaveTrait: trait)
                : NSFontManager.shared.convert(font, toHaveTrait: trait)
        }
        if range.length == 0 {
            view.typingAttributes[.font] = converted(view.typingAttributes)
        } else if let storage = view.textStorage {
            let selection = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
            selection.enumerateAttributes(in: NSRange(location: 0, length: selection.length)) { attributes, range, _ in
                selection.addAttribute(.font, value: converted(attributes), range: range)
            }
            view.insertText(selection, replacementRange: range)
            view.setSelectedRange(range)
        }
        readSelection()
    }

    func setBlock(_ block: NoteDocument.Block) {
        guard let view, view.isEditable, let storage = view.textStorage else { return }
        focus()
        let selected = view.selectedRange()
        let range = (view.string as NSString).paragraphRange(for: selected)
        if range.length == 0 {
            view.typingAttributes = NoteDocument.attributes(block: block)
            let marker = Self.marker(for: block)
            if !marker.isEmpty { view.insertText(NSAttributedString(string: marker, attributes: view.typingAttributes), replacementRange: range) }
            readSelection()
            return
        }
        let replacement = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        var offset = 0
        var number = 1
        while offset < replacement.length {
            let line = (replacement.string as NSString).paragraphRange(for: NSRange(location: offset, length: 0))
            let old = (replacement.attribute(.noteBlock, at: offset, effectiveRange: nil) as? String)
                .flatMap(NoteDocument.Block.init(rawValue:)) ?? .text
            // A table keeps its own shape. Restyling it would turn its source into prose.
            if old == .table { offset = NSMaxRange(line); continue }
            let value = (replacement.string as NSString).substring(with: line)
            let markerLength = NoteDocument.markerLength(value, block: old)
            let text = NSMutableAttributedString(attributedString: replacement.attributedSubstring(from: line))
            if markerLength > 0 { text.deleteCharacters(in: NSRange(location: 0, length: markerLength)) }
            let normalized = NoteDocument(text)
            let indent = NoteDocument.Block.lists.contains(block) ? normalized.runs.first?.indent ?? 0 : 0
            text.setAttributedString(NoteDocument(runs: normalized.runs.map {
                var run = $0; run.block = block; run.indent = indent; return run
            }).attributed)
            let marker = Self.marker(for: block, number: number)
            text.insert(NSAttributedString(string: marker, attributes: NoteDocument.attributes(block: block, indent: indent)), at: 0)
            replacement.replaceCharacters(in: line, with: text)
            offset += text.length
            number += 1
        }
        view.insertText(replacement, replacementRange: range)
        if selected.length > 0 { view.setSelectedRange(NSRange(location: range.location, length: replacement.length)) }
        view.typingAttributes = NoteDocument.attributes(block: block)
        readSelection()
    }

    static func marker(for block: NoteDocument.Block, number: Int = 1) -> String {
        switch block {
        case .bullet: "• "
        case .numbered: "\(number). "
        case .checklist: "☐ "
        default: ""
        }
    }

    // A list item can sit at most one level below the item before it, so Markdown can
    // still nest it under a parent.
    func changeIndent(by delta: Int) {
        guard let view, view.isEditable, let storage = view.textStorage, storage.length > 0 else { return }
        let string = view.string as NSString
        let range = string.paragraphRange(for: view.selectedRange())
        guard range.location < storage.length else { return }
        func listIndent(at location: Int) -> Int? {
            guard location >= 0, location < storage.length,
                  let block = (storage.attribute(.noteBlock, at: location, effectiveRange: nil) as? String)
                    .flatMap(NoteDocument.Block.init(rawValue:)),
                  NoteDocument.Block.lists.contains(block) else { return nil }
            return storage.attribute(.noteIndent, at: location, effectiveRange: nil) as? Int ?? 0
        }
        let previous = range.location > 0 ? string.paragraphRange(for: NSRange(location: range.location - 1, length: 0)).location : -1
        var limit = (listIndent(at: previous) ?? -1) + 1
        let replacement = NSMutableAttributedString()
        var offset = range.location
        while offset < NSMaxRange(range) {
            let line = string.paragraphRange(for: NSRange(location: offset, length: 0))
            let current = listIndent(at: line.location) ?? 0
            let indent = max(0, min(current + delta, limit))
            let document = NoteDocument(storage.attributedSubstring(from: line))
            replacement.append(NoteDocument(runs: document.runs.map {
                var run = $0
                if NoteDocument.Block.lists.contains(run.block) { run.indent = indent }
                return run
            }).attributed)
            limit = indent + 1
            offset = NSMaxRange(line)
        }
        let selected = view.selectedRange()
        view.insertText(replacement, replacementRange: range)
        view.setSelectedRange(selected)
        readSelection()
    }

    func toggleChecklist() {
        guard let view, view.isEditable else { return }
        view.toggleChecklist(at: view.selectedRange().location)
        readSelection()
    }

    func insertLink(_ url: String) {
        guard let view, view.isEditable, let url = NoteDocument.safeLink(url) else { return }
        focus()
        let range = view.selectedRange()
        let text = range.length > 0
            ? NSMutableAttributedString(attributedString: view.attributedSubstring(forProposedRange: range, actualRange: nil) ?? NSAttributedString())
            : NSMutableAttributedString(string: url, attributes: view.typingAttributes)
        text.addAttribute(.link, value: url, range: NSRange(location: 0, length: text.length))
        view.insertText(text, replacementRange: range)
        view.typingAttributes.removeValue(forKey: .link)
    }
}

struct NoteTextEditor: NSViewRepresentable {
    let document: NoteDocument
    let controller: NoteEditorController
    let editable: Bool
    let onChange: (NoteDocument) -> Void
    let onFiles: ([URL]) -> Void
    let onImage: (Data) -> Void
    let onLink: (URL) -> Void
    // Opens a table's source, given the Markdown it was read from. Without it the table
    // menus offer no way into Source.
    var onTable: ((String) -> Void)?
    @Binding var height: CGFloat
    @Environment(MenuPresenter.self) private var menus: MenuPresenter?

    // Empty room around the text for the table controls, which sit beside a table's
    // edges. The host takes it back with a negative padding, so the text lines up with
    // what is around it.
    static let gutter = NoteTableControls.gutter

    func makeNSView(context: Context) -> NoteTextView {
        let view = NoteTextView(frame: .zero)
        // Tables are drawn by TextKit 1 attachment cells. Asking for the layout manager
        // before any text arrives keeps the view on TextKit 1 from the start.
        _ = view.layoutManager
        view.isRichText = true
        view.importsGraphics = false
        view.usesFontPanel = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.textContainerInset = NSSize(width: Self.gutter, height: 3 + Self.gutter)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textStorage?.setAttributedString(document.attributed)
        view.typingAttributes = NoteDocument.attributes()
        view.insertionPointColor = .labelColor
        view.setAccessibilityLabel("Note body")
        view.setAccessibilityHelp("Rich text. Use Command-B for bold, Command-I for italic, Tab and Shift-Tab to nest list items, and Command-Shift-Return to toggle the checklist item at the cursor.")
        view.delegate = context.coordinator
        view.controller = controller
        controller.view = view
        view.onLayout = { [weak coordinator = context.coordinator] in coordinator?.measure() }
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: NoteTextView, context: Context) {
        context.coordinator.parent = self
        if NoteDocument(view.attributedString()) != document {
            let selection = view.selectedRange()
            view.textStorage?.setAttributedString(document.attributed)
            view.setSelectedRange(NSRange(location: min(selection.location, (view.string as NSString).length), length: 0))
        }
        view.isEditable = editable
        view.onTable = onTable
        view.menus = menus
        view.onFiles = onFiles
        view.onImage = onImage
        controller.view = view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NoteTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 500
        view.textContainer?.containerSize = NSSize(width: max(1, width - Self.gutter * 2), height: .greatestFiniteMagnitude)
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        return CGSize(width: width, height: Self.height(used: view.layoutManager?.usedRect(for: view.textContainer!).height ?? 0))
    }

    static func height(used: CGFloat) -> CGFloat {
        max(160, used + 12) + gutter * 2
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteTextEditor
        init(_ parent: NoteTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.onChange(NoteDocument(view.attributedString()))
            measure()
        }

        // Text typed beside a table must not take on its attributes, or it would be read
        // back as part of the table.
        func textView(_ textView: NSTextView, shouldChangeTypingAttributes oldTypingAttributes: [String: Any],
                      toAttributes newTypingAttributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            guard newTypingAttributes[.noteBlock] as? String == NoteDocument.Block.table.rawValue else { return newTypingAttributes }
            return NoteDocument.attributes()
        }

        // A table is a block of its own, so text typed against either side of it starts
        // on a new line rather than sharing the table's line.
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
            guard let text, !text.isEmpty, let storage = textView.textStorage else { return true }
            func isTable(_ location: Int) -> Bool {
                location >= 0 && location < storage.length
                    && NoteTableCell.source(of: storage.attribute(.attachment, at: location, effectiveRange: nil)) != nil
            }
            let before = isTable(range.location - 1) && !text.hasPrefix("\n")
            let after = isTable(NSMaxRange(range)) && !text.hasSuffix("\n")
            guard before || after else { return true }
            var attributes = textView.typingAttributes
            if attributes[.noteBlock] as? String == NoteDocument.Block.table.rawValue { attributes = NoteDocument.attributes() }
            attributes.removeValue(forKey: .attachment)
            let padded = (before ? "\n" : "") + text + (after ? "\n" : "")
            textView.insertText(NSAttributedString(string: padded, attributes: attributes), replacementRange: range)
            if after { textView.setSelectedRange(NSRange(location: textView.selectedRange().location - 1, length: 0)) }
            return false
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // Selection callbacks can arrive during AppKit layout inside a SwiftUI update.
            Task { @MainActor [weak self] in self?.parent.controller.readSelection() }
        }

        func measure() {
            guard let view = parent.controller.view, let container = view.textContainer,
                  let layout = view.layoutManager else { return }
            layout.ensureLayout(for: container)
            let height = NoteTextEditor.height(used: layout.usedRect(for: container).height)
            if abs(parent.height - height) > 1 {
                Task { @MainActor [weak self] in self?.parent.height = height }
            }
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let kept = NoteDocument.keptLink(String(describing: link)), let url = URL(string: kept) {
                parent.onLink(url)
            }
            return true
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let inList = NoteDocument.Block.lists.contains(parent.controller.block)
            if selector == #selector(NSResponder.insertTab(_:)) {
                if inList { parent.controller.changeIndent(by: 1) } else { textView.window?.selectNextKeyView(nil) }
                return true
            }
            if selector == #selector(NSResponder.insertBacktab(_:)) {
                if inList { parent.controller.changeIndent(by: -1) } else { textView.window?.selectPreviousKeyView(nil) }
                return true
            }
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let selected = textView.selectedRange()
            let paragraph = (textView.string as NSString).paragraphRange(for: selected)
            let line = (textView.string as NSString).substring(with: paragraph)
            let block = parent.controller.block
            if [.title, .heading, .subheading].contains(block) {
                textView.insertText(NSAttributedString(string: "\n", attributes: NoteDocument.attributes()), replacementRange: selected)
                textView.typingAttributes = NoteDocument.attributes()
                return true
            }
            guard [.bullet, .numbered, .checklist].contains(block) else { return false }
            let marker = NoteDocument.markerLength(line, block: block)
            if line.dropFirst(marker).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parent.controller.setBlock(.text)
            } else {
                let number = Int(line.prefix(while: \.isNumber)) ?? 0
                let attributes = NoteDocument.attributes(block: block, indent: parent.controller.indent)
                textView.insertText(NSAttributedString(string: "\n" + NoteEditorController.marker(for: block, number: number + 1),
                                                       attributes: attributes), replacementRange: selected)
                textView.typingAttributes = attributes
            }
            return true
        }
    }
}

final class NoteTextView: NSTextView {
    weak var controller: NoteEditorController?
    var onFiles: (([URL]) -> Void)?
    var onImage: ((Data) -> Void)?
    var onLayout: (() -> Void)?
    var onTable: ((String) -> Void)?
    // The table controls open their menus through this. Without it a table offers no
    // controls on hover, though its cells can still be edited.
    var menus: MenuPresenter?
    private let tableControls = NoteTableControls()
    private var tableControlsHost: NoteTableControlsHost?
    private var hoveredTable: Int?
    private var tableTracking: NSTrackingArea?
    private var cellEditor: NoteTableCellEditor?

    // A new width moves and resizes the tables, so the controls and an open cell editor
    // follow the table they belong to.
    override func layout() {
        super.layout()
        onLayout?()
        if let hoveredTable, tableControls.lit {
            if let table = tables().first(where: { $0.location == hoveredTable }), let grid = table.cell.grid {
                tableControls.columns = grid.columns
                tableControls.rows = grid.rows
                placeTableControls(over: table.frame)
            } else { tableControls.lit = false }
        }
        if let cellEditor {
            if let rect = cellRect(table: cellEditor.table, row: cellEditor.row, column: cellEditor.column) {
                cellEditor.place(over: rect.insetBy(dx: 2, dy: 2))
            } else { cellEditor.onEnd?(cellEditor, .cancel) }
        }
    }

    // Where each table sits in the view: the bounds of its attachment glyph, which is
    // where TextKit draws the grid.
    private func tables() -> [(location: Int, cell: NoteTableCell, frame: NSRect)] {
        guard let storage = textStorage, let layout = layoutManager, let container = textContainer else { return [] }
        var result: [(Int, NoteTableCell, NSRect)] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let cell = (value as? NSTextAttachment)?.attachmentCell as? NoteTableCell else { return }
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: range.location, length: 1), actualCharacterRange: nil)
            let frame = layout.boundingRect(forGlyphRange: glyphs, in: container)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            result.append((range.location, cell, frame))
        }
        return result
    }

    private func tableSource(at location: Int) -> NoteTableSource? {
        guard let storage = textStorage, location < storage.length,
              let source = NoteTableCell.source(of: storage.attribute(.attachment, at: location, effectiveRange: nil)) else { return nil }
        return NoteTableSource(source)
    }

    private static func index(in sizes: [CGFloat], at offset: CGFloat) -> Int? {
        var edge: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            edge += size
            if offset < edge { return index }
        }
        return nil
    }

    private func cellRect(table location: Int, row: Int, column: Int) -> NSRect? {
        guard let table = tables().first(where: { $0.location == location }), let grid = table.cell.grid,
              grid.rows.indices.contains(row), grid.columns.indices.contains(column) else { return nil }
        return NSRect(x: table.frame.minX + grid.columns.prefix(column).reduce(0, +),
                      y: table.frame.minY + grid.rows.prefix(row).reduce(0, +),
                      width: grid.columns[column], height: grid.rows[row])
    }

    private func updateTableHover(at point: NSPoint) {
        // The controls stay on the row or column their open menu acts on, and stay away
        // while a cell is being edited.
        if menus?.isOpen == true, tableControls.lit { return }
        let gutter = NoteTableControls.gutter
        // The plus for the last row or column is offered from just past the grid's edge.
        let reach: CGFloat = 6
        guard cellEditor == nil, isEditable, menus != nil, visibleRect.contains(point),
              let hit = tables().first(where: {
                  NSRect(x: $0.frame.minX - gutter, y: $0.frame.minY - gutter,
                         width: $0.frame.width + gutter + reach, height: $0.frame.height + gutter + reach).contains(point)
              }),
              let grid = hit.cell.grid else {
            tableControls.lit = false
            return
        }
        let x = point.x - hit.frame.minX, y = point.y - hit.frame.minY
        let width = grid.columns.reduce(0, +), height = grid.rows.reduce(0, +)
        func near(_ edges: [CGFloat], _ offset: CGFloat) -> Int? {
            edges.indices.filter { abs(edges[$0] - offset) <= 6 }.min { abs(edges[$0] - offset) < abs(edges[$1] - offset) }
        }
        // The lines between rows answer near their left end, and the lines between
        // columns near their top, where the plus sits. Answering along their whole length
        // would flash a line at every row the pointer crossed.
        let rowEdges = grid.rows.indices.map { grid.rows.prefix($0 + 1).reduce(0, +) }
        let columnEdges = (0...grid.columns.count).map { grid.columns.prefix($0).reduce(0, +) }
        var gap: NoteTableControls.Gap?
        if x < 12, let edge = near(rowEdges, y) { gap = .row(edge + 1) }
        else if y > height - 3, x >= 0 { gap = .row(grid.rows.count) }
        else if y < 8, let edge = near(columnEdges, x) { gap = .column(edge) }
        else if x > width - 3, y >= 0 { gap = .column(grid.columns.count) }
        let source = NoteTableSource(hit.cell.source)
        let controls = tableControls
        if controls.columns != grid.columns { controls.columns = grid.columns }
        if controls.rows != grid.rows { controls.rows = grid.rows }
        if controls.source != source { controls.source = source }
        let row = (0..<height).contains(y) ? Self.index(in: grid.rows, at: y) : nil
        let column = (0..<width).contains(x) ? Self.index(in: grid.columns, at: x) : nil
        if controls.row != row { controls.row = row }
        if controls.column != column { controls.column = column }
        if controls.gap != gap { controls.gap = gap }
        hoveredTable = hit.location
        let location = hit.location
        controls.apply = { [weak self] edit in self?.applyTableEdit(edit, toTableAt: location) }
        controls.showSource = onTable.map { show in { [weak self] in
            guard let source = self?.tableSource(at: location) else { return }
            show(source.text)
        } }
        placeTableControls(over: hit.frame)
        controls.lit = true
    }

    private func placeTableControls(over frame: NSRect) {
        guard let menus else { return }
        let host = tableControlsHost ?? {
            let host = NoteTableControlsHost(rootView: AnyView(NoteTableControlsView(model: tableControls).environment(menus)))
            host.model = tableControls
            addSubview(host)
            tableControlsHost = host
            return host
        }()
        let gutter = NoteTableControls.gutter
        host.frame = frame.insetBy(dx: -gutter, dy: -gutter)
    }

    private func refreshTableHover() {
        guard let window else { return }
        updateTableHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func applyTableEdit(_ edit: NoteTableEdit, toTableAt location: Int) {
        guard var source = tableSource(at: location) else { return }
        source.apply(edit)
        replaceTable(at: location, with: source)
        // A new row or column is empty, so it opens for typing straight away. That also
        // shows where it went.
        switch edit {
        case .insertRow(let row): editCell(table: location, row: row, column: 0)
        case .insertColumn(let column): editCell(table: location, row: 0, column: column)
        default: refreshTableHover()
        }
    }

    // Swaps the table for one drawn from the new Markdown. It goes through the text
    // view's own change path, so it can be undone and the document hears about it.
    private func replaceTable(at location: Int, with source: NoteTableSource) {
        guard let storage = textStorage, tableSource(at: location) != nil else { return }
        let range = NSRange(location: location, length: 1)
        let replacement = NoteDocument(runs: [.init(text: source.text, block: .table)]).attributed
        let selection = selectedRanges
        breakUndoCoalescing()
        guard shouldChangeText(in: range, replacementString: replacement.string) else { return }
        storage.replaceCharacters(in: range, with: replacement)
        didChangeText()
        undoManager?.setActionName("Edit Table")
        selectedRanges = selection
        if let layoutManager, let textContainer { layoutManager.ensureLayout(for: textContainer) }
    }

    func editCell(table location: Int, row: Int, column: Int) {
        guard isEditable, cellEditor == nil, let source = tableSource(at: location),
              let rect = cellRect(table: location, row: row, column: column) else { return }
        tableControls.lit = false
        let editor = NoteTableCellEditor(table: location, row: row, column: column,
                                         text: source.cell(row: row, column: column), alignment: source.alignment(of: column))
        editor.onEnd = { [weak self] editor, ending in self?.endCellEdit(editor, ending) }
        editor.place(over: rect.insetBy(dx: 2, dy: 2))
        editor.alphaValue = 0
        addSubview(editor)
        cellEditor = editor
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.revealDuration
            editor.animator().alphaValue = 1
        }
        window?.makeFirstResponder(editor.field)
        if let text = editor.field.currentEditor() {
            text.selectedRange = NSRange(location: (text.string as NSString).length, length: 0)
        }
        scrollToVisible(editor.frame.insetBy(dx: 0, dy: -8))
    }

    private func endCellEdit(_ editor: NoteTableCellEditor, _ ending: NoteTableCellEditor.Ending) {
        guard cellEditor === editor else { return }
        cellEditor = nil
        var move = 0
        switch ending {
        case .commit(let step): move = step
        case .cancel, .focusLost: break
        }
        // A key ended the edit while the field still has the focus, so the focus goes back
        // to the text. When the focus has already gone elsewhere it stays there.
        if case .focusLost = ending {} else if move == 0 { window?.makeFirstResponder(self) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.leaveDuration
            editor.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in editor.removeFromSuperview() }
        }
        if case .cancel = ending {} else if var source = tableSource(at: editor.table) {
            let before = source
            source.apply(.setCell(row: editor.row, column: editor.column, text: editor.field.stringValue))
            if source != before { replaceTable(at: editor.table, with: source) }
        }
        guard move != 0, var source = tableSource(at: editor.table) else { return }
        var row = editor.row, column = editor.column + move
        if column >= source.columnCount { column = 0; row += 1 }
        if column < 0 { column = source.columnCount - 1; row -= 1 }
        guard row >= 0 else { window?.makeFirstResponder(self); return }
        // Tab out of the last cell starts a new row, the way a spreadsheet does.
        if row >= source.rowCount {
            source.apply(.insertRow(source.rowCount))
            replaceTable(at: editor.table, with: source)
        }
        editCell(table: editor.table, row: row, column: column)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tableTracking { removeTrackingArea(tableTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tableTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        updateTableHover(at: point)
        if tableControls.lit || tables().contains(where: { $0.frame.contains(point) }) { NSCursor.arrow.set() }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if menus?.isOpen != true { tableControls.lit = false }
    }

    override func scrollWheel(with event: NSEvent) {
        tableControls.lit = false
        super.scrollWheel(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        tableControls.lit = false
    }

    // Rich text and plain text on the pasteboard both lose a table's attachment, so a
    // selection holding a table also goes out as the document itself. Other apps get
    // the table's Markdown as plain text.
    static let documentPasteboardType = NSPasteboard.PasteboardType("com.teya.code-station.note-document")

    private var selectionHoldsTable: Bool {
        guard let storage = textStorage else { return false }
        return selectedRanges.map(\.rangeValue).contains { range in
            var found = false
            storage.enumerateAttribute(.attachment, in: range) { value, _, stop in
                if NoteTableCell.source(of: value) != nil { found = true; stop.pointee = true }
            }
            return found
        }
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        selectionHoldsTable ? [Self.documentPasteboardType, .string] : super.writablePasteboardTypes
    }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard selectionHoldsTable, let storage = textStorage,
              let data = try? JSONEncoder().encode(NoteDocument(storage.attributedSubstring(from: selectedRange()))) else {
            return super.writeSelection(to: pboard, types: types)
        }
        pboard.declareTypes([Self.documentPasteboardType, .string], owner: nil)
        pboard.setData(data, forType: Self.documentPasteboardType)
        pboard.setString(NoteDocument(storage.attributedSubstring(from: selectedRange())).markdown, forType: .string)
        return true
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [Self.documentPasteboardType] + super.readablePasteboardTypes
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == Self.documentPasteboardType else { return super.readSelection(from: pboard, type: type) }
        return insertDocument(from: pboard, replacing: rangeForUserTextChange)
    }

    private func insertDocument(from pboard: NSPasteboard, replacing range: NSRange) -> Bool {
        guard isEditable, range.location != NSNotFound, let storage = textStorage,
              let data = pboard.data(forType: Self.documentPasteboardType),
              let document = try? JSONDecoder().decode(NoteDocument.self, from: data) else { return false }
        // A table always sits on a line of its own, so the pasted text is set apart from
        // a table it lands against, and a table it carries is set apart from the text
        // around it.
        let string = storage.string as NSString
        func isTable(_ location: Int) -> Bool {
            location >= 0 && location < storage.length
                && NoteTableCell.source(of: storage.attribute(.attachment, at: location, effectiveRange: nil)) != nil
        }
        let text = NSMutableAttributedString(attributedString: document.attributed)
        let startsWithTable = document.runs.first?.block == .table, endsWithTable = document.runs.last?.block == .table
        if range.location > 0, string.character(at: range.location - 1) != 0x0A,
           startsWithTable || isTable(range.location - 1) {
            text.insert(NSAttributedString(string: "\n", attributes: NoteDocument.attributes()), at: 0)
        }
        if NSMaxRange(range) < string.length, string.character(at: NSMaxRange(range)) != 0x0A,
           endsWithTable || isTable(NSMaxRange(range)) {
            text.append(NSAttributedString(string: "\n", attributes: NoteDocument.attributes()))
        }
        insertText(text, replacementRange: range)
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if isEditable, flags == .command {
            if event.charactersIgnoringModifiers == "b" { controller?.toggleTrait(.boldFontMask); return true }
            if event.charactersIgnoringModifiers == "i" { controller?.toggleTrait(.italicFontMask); return true }
        }
        if isEditable, flags == [.command, .shift], event.keyCode == 36 {
            controller?.toggleChecklist(); return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        let pasteboard = NSPasteboard.general
        if takeFiles(pasteboard) { return }
        if insertDocument(from: pasteboard, replacing: selectedRange()) { return }
        if let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
            onImage?(png); return
        }
        if let rtf = pasteboard.data(forType: .rtf),
           let attributed = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            insertText(NoteDocument(attributed).attributed, replacementRange: selectedRange())
        } else if let text = pasteboard.string(forType: .string) {
            insertText(NSAttributedString(string: text, attributes: typingAttributes), replacementRange: selectedRange())
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            return isEditable ? .copy : []
        }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if isEditable, takeFiles(sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    private func takeFiles(_ pasteboard: NSPasteboard) -> Bool {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        onFiles?(urls)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, isEditable, let hit = tables().first(where: { $0.frame.contains(point) }),
           let grid = hit.cell.grid,
           let row = Self.index(in: grid.rows, at: point.y - hit.frame.minY),
           let column = Self.index(in: grid.columns, at: point.x - hit.frame.minX) {
            editCell(table: hit.location, row: row, column: column)
            return
        }
        let index = characterIndexForInsertion(at: point)
        let paragraph = (string as NSString).paragraphRange(for: NSRange(location: min(index, (string as NSString).length), length: 0))
        if isEditable, index <= paragraph.location + 1, toggleChecklist(at: paragraph.location) { return }
        super.mouseDown(with: event)
    }

    @discardableResult func toggleChecklist(at index: Int) -> Bool {
        guard isEditable, let storage = textStorage, storage.length > 0 else { return false }
        let paragraph = (string as NSString).paragraphRange(for: NSRange(location: min(index, storage.length), length: 0))
        guard paragraph.location < storage.length,
              storage.attribute(.noteBlock, at: paragraph.location, effectiveRange: nil) as? String == NoteDocument.Block.checklist.rawValue,
              let first = (string as NSString).substring(with: paragraph).first, first == "☐" || first == "☑" else { return false }
        let selected = selectedRange()
        let replacement = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: paragraph))
        replacement.replaceCharacters(in: NSRange(location: 0, length: 1), with: first == "☐" ? "☑" : "☐")
        breakUndoCoalescing()
        insertText(NoteDocument(replacement).attributed, replacementRange: paragraph)
        breakUndoCoalescing()
        setSelectedRange(selected)
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: first == "☐" ? "Item checked" : "Item unchecked",
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        return true
    }
}
