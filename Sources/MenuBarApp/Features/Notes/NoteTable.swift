import AppKit
import SwiftUI

// A Markdown table in the rich editor. The text view holds one attachment character for
// it, and this cell draws the grid in its place. The source rides along on the cell, so
// the table goes back to disk exactly as it was written.
final class NoteTableCell: NSTextAttachmentCell {
    let source: String
    // The header first, then each body row.
    private let rows: [[NSAttributedString]]
    private var layout: (width: CGFloat, columns: [CGFloat], rows: [CGFloat])?

    private static let horizontalPadding: CGFloat = 10
    private static let verticalPadding: CGFloat = 6
    private static let cornerRadius: CGFloat = 8
    // How far the grid reaches below the baseline of its line. It covers the descent of
    // the line, so nothing of the line shows under the grid, not even the selection.
    private nonisolated static let baselineOffset: CGFloat = -NSFont.systemFont(ofSize: 14).descender

    static func attachment(source: String) -> NSTextAttachment {
        let attachment = NSTextAttachment(data: nil, ofType: nil)
        attachment.attachmentCell = NoteTableCell(source: source)
        return attachment
    }

    static func source(of attachment: Any?) -> String? {
        ((attachment as? NSTextAttachment)?.attachmentCell as? NoteTableCell)?.source
    }

    init(source: String) {
        self.source = source
        if let table = MarkdownTable.read(source.components(separatedBy: "\n"), from: 0)?.table {
            rows = ([table.header] + table.rows).enumerated().map { row, cells in
                cells.enumerated().map { column, text in
                    Self.text(text, header: row == 0,
                              alignment: table.alignments.indices.contains(column) ? table.alignments[column] : .leading)
                }
            }
        } else {
            rows = [[Self.text(source, header: false, alignment: .leading)]]
        }
        super.init(textCell: "")
    }

    required init(coder: NSCoder) { fatalError("A table cell is never archived") }

    // The pipes inside a cell were unescaped when the row was split, and the inline
    // reader needs them escaped again to take them as text.
    private static func text(_ raw: String, header: Bool, alignment: MarkdownTable.ColumnAlignment) -> NSAttributedString {
        let runs = MarkdownWritingDocument.inline(raw.replacingOccurrences(of: "|", with: "\\|"), block: .text)
            ?? [NoteDocument.Run(text: raw)]
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.alignment = switch alignment {
        case .leading: .natural
        case .center: .center
        case .trailing: .right
        }
        let result = NSMutableAttributedString()
        for run in runs {
            let weight: NSFont.Weight = header || run.bold ? .semibold : .regular
            var font = run.code ? NSFont.monospacedSystemFont(ofSize: 12, weight: weight) : NSFont.systemFont(ofSize: 13, weight: weight)
            if run.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .paragraphStyle: paragraph,
                .foregroundColor: run.link == nil ? NSColor.labelColor : Theme.accentNSColor
            ]
            if run.code { attributes[.backgroundColor] = Theme.accentNSColor.withAlphaComponent(0.07) }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }

    // Columns take the width their longest line needs. When the page is too narrow for
    // that, a column that fits its even share of the page keeps its width, and the wider
    // ones each get at least an even share and split the rest by how much more they want.
    private func layout(for available: CGFloat) -> (columns: [CGFloat], rows: [CGFloat]) {
        if let layout, layout.width == available { return (layout.columns, layout.rows) }
        let padding = Self.horizontalPadding * 2
        let count = rows.map(\.count).max() ?? 0
        let natural = (0..<count).map { column in
            rows.map { row in
                column < row.count ? ceil(row[column].boundingRect(with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                                                                   options: [.usesLineFragmentOrigin, .usesFontLeading]).width) : 0
            }.max().map { $0 + padding } ?? padding
        }
        var columns = natural
        let total = natural.reduce(0, +)
        if total > available, count > 0 {
            let share = available / CGFloat(count)
            let wide = natural.filter { $0 > share }
            let spare = available - natural.filter { $0 <= share }.reduce(0, +) - share * CGFloat(wide.count)
            let wanted = wide.reduce(0) { $0 + $1 - share }
            columns = natural.map { $0 <= share ? $0 : floor(share + ($0 - share) * spare / wanted) }
        }
        let lineHeight = ceil(NSFont.systemFont(ofSize: 13).boundingRectForFont.height)
        let heights = rows.map { row in
            let content = row.enumerated().map { column, text in
                ceil(text.boundingRect(with: NSSize(width: max(1, columns[column] - padding), height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
            }.max() ?? 0
            return max(content, lineHeight) + Self.verticalPadding * 2
        }
        layout = (available, columns, heights)
        return (columns, heights)
    }

    // The column widths and row heights the grid was last laid out with. Nil until the
    // text view has laid the table out once.
    var grid: (columns: [CGFloat], rows: [CGFloat])? { layout.map { ($0.columns, $0.rows) } }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        // The editor's text view lays out on the main thread.
        MainActor.assumeIsolated {
            let (columns, heights) = layout(for: max(1, floor(lineFrag.width - position.x)))
            return NSRect(x: 0, y: -Self.baselineOffset, width: columns.reduce(0, +), height: heights.reduce(0, +))
        }
    }

    override func cellSize() -> NSSize {
        MainActor.assumeIsolated {
            guard let layout else { return NSSize(width: 1, height: 1) }
            return NSSize(width: layout.columns.reduce(0, +), height: layout.rows.reduce(0, +))
        }
    }

    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -Self.baselineOffset) }

    // A click places the caret beside the table rather than starting a drag of it.
    override func wantsToTrackMouse() -> Bool { false }

    override func wantsToTrackMouse(for theEvent: NSEvent, in cellFrame: NSRect, of controlView: NSView?,
                                    atCharacterIndex charIndex: Int) -> Bool { false }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        draw(cellFrame, selected: false)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int,
                       layoutManager: NSLayoutManager) {
        let selected = (controlView as? NSTextView)?.selectedRanges.contains {
            $0.rangeValue.length > 0 && NSLocationInRange(charIndex, $0.rangeValue)
        } ?? false
        draw(cellFrame, selected: selected)
    }

    private func draw(_ frame: NSRect, selected: Bool) {
        let (columns, heights) = layout(for: frame.width)
        let outline = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5),
                                   xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        // The text view paints a selection as a square behind the grid. Covering it with
        // the page keeps the corners round.
        if selected {
            NSColor(Theme.card).setFill()
            frame.fill()
        }
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        NSColor(Theme.card).setFill()
        frame.fill()
        NSColor(Theme.field).setFill()
        NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: heights.first ?? 0).fill(using: .sourceOver)
        var y = frame.minY
        for (index, row) in rows.enumerated() {
            if index > 0 {
                NSColor(Theme.hairline).setFill()
                NSRect(x: frame.minX, y: y, width: frame.width, height: 1).fill(using: .sourceOver)
            }
            var x = frame.minX
            for (column, text) in row.enumerated() where column < columns.count {
                text.draw(with: NSRect(x: x + Self.horizontalPadding, y: y + Self.verticalPadding,
                                       width: max(1, columns[column] - Self.horizontalPadding * 2),
                                       height: heights[index] - Self.verticalPadding * 2),
                          options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
                x += columns[column]
            }
            y += heights[index]
        }
        if selected {
            Theme.accentNSColor.withAlphaComponent(0.08).setFill()
            frame.fill(using: .sourceOver)
        }
        NSGraphicsContext.restoreGraphicsState()
        (selected ? Theme.accentNSColor : NSColor(Theme.border)).setStroke()
        outline.lineWidth = selected ? 1.5 : 1
        outline.stroke()
    }
}

// A change to a table's shape. Rows are counted the way the grid draws them, with the
// header as row 0, so a row index from the pointer can be used as it is.
enum NoteTableEdit: Equatable {
    case insertRow(Int), deleteRow(Int), moveRow(Int, by: Int)
    case insertColumn(Int), deleteColumn(Int), moveColumn(Int, by: Int)
    case align(Int, MarkdownTable.ColumnAlignment)
    case setCell(row: Int, column: Int, text: String)
}

// A table's Markdown, changed one edit at a time. A row an edit does not touch keeps the
// line it was written on, so changing one row shows as one changed line in a diff. An
// edit to a column has to touch every line, and writes them all in the plain
// `| a | b |` form.
struct NoteTableSource: Equatable {
    private(set) var lines: [String]
    private(set) var table: MarkdownTable

    init?(_ source: String) {
        let lines = source.components(separatedBy: "\n")
        guard let table = MarkdownTable.read(lines, from: 0)?.table, lines.count >= 2 else { return nil }
        self.lines = lines
        self.table = table
    }

    var text: String { lines.joined(separator: "\n") }
    var rowCount: Int { table.rows.count + 1 }
    var columnCount: Int { table.header.count }

    func cell(row: Int, column: Int) -> String {
        let grid = [table.header] + table.rows
        guard grid.indices.contains(row), grid[row].indices.contains(column) else { return "" }
        return grid[row][column]
    }

    func alignment(of column: Int) -> MarkdownTable.ColumnAlignment {
        table.alignments.indices.contains(column) ? table.alignments[column] : .leading
    }

    mutating func apply(_ edit: NoteTableEdit) {
        var grid = [table.header] + table.rows
        var alignments = table.alignments
        switch edit {
        case .setCell(let row, let column, let text):
            guard grid.indices.contains(row), grid[row].indices.contains(column) else { return }
            // A cell is one line of Markdown, so a line break typed into it becomes a space.
            grid[row][column] = text.components(separatedBy: .newlines).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            lines[Self.line(of: row)] = Self.row(grid[row])
        case .insertRow(let row):
            guard (1...grid.count).contains(row) else { return }
            lines.insert(Self.row(Array(repeating: "", count: columnCount)), at: Self.line(of: row))
        case .deleteRow(let row):
            guard row >= 1, grid.indices.contains(row) else { return }
            lines.remove(at: Self.line(of: row))
        case .moveRow(let row, let offset):
            let target = row + offset
            guard row >= 1, target >= 1, grid.indices.contains(row), grid.indices.contains(target) else { return }
            lines.swapAt(Self.line(of: row), Self.line(of: target))
        case .insertColumn(let column):
            guard (0...columnCount).contains(column) else { return }
            for index in grid.indices { grid[index].insert("", at: column) }
            alignments.insert(.leading, at: column)
            rewrite(grid, alignments)
        case .deleteColumn(let column):
            guard columnCount > 1, (0..<columnCount).contains(column) else { return }
            for index in grid.indices { grid[index].remove(at: column) }
            alignments.remove(at: column)
            rewrite(grid, alignments)
        case .moveColumn(let column, let offset):
            let target = column + offset
            guard (0..<columnCount).contains(column), (0..<columnCount).contains(target) else { return }
            for index in grid.indices { grid[index].swapAt(column, target) }
            alignments.swapAt(column, target)
            rewrite(grid, alignments)
        case .align(let column, let alignment):
            guard alignments.indices.contains(column) else { return }
            alignments[column] = alignment
            lines[1] = Self.separator(alignments)
        }
        table = MarkdownTable.read(lines, from: 0)?.table ?? table
    }

    private mutating func rewrite(_ grid: [[String]], _ alignments: [MarkdownTable.ColumnAlignment]) {
        lines = [Self.row(grid[0]), Self.separator(alignments)] + grid.dropFirst().map(Self.row)
    }

    // The header is the first line and the row of dashes the second, so body rows start
    // one line further down than their place in the grid.
    private static func line(of row: Int) -> Int { row == 0 ? 0 : row + 1 }

    private static func row(_ cells: [String]) -> String {
        "| " + cells.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |"
    }

    private static func separator(_ alignments: [MarkdownTable.ColumnAlignment]) -> String {
        "| " + alignments.map { alignment in
            switch alignment {
            case .leading: "---"
            case .center: ":---:"
            case .trailing: "---:"
            }
        }.joined(separator: " | ") + " |"
    }
}

// What the table under the pointer offers: a grip beside the row and above the column it
// is on, each opening a menu of what can be done to them, and a plus on the line between
// two rows or two columns that puts a new one there. The controls sit in a gutter around
// the grid, so they never cover the text in it.
@MainActor @Observable
final class NoteTableControls {
    enum Gap: Hashable { case row(Int), column(Int) }

    static let gutter: CGFloat = 16
    static let gripLength: CGFloat = 20
    static let gripThickness: CGFloat = 12
    static let plusSize: CGFloat = 16

    var lit = false
    var columns: [CGFloat] = []
    var rows: [CGFloat] = []
    var row: Int?
    var column: Int?
    // The line the pointer is on. A row gap of n sits above row n, and a column gap of n
    // sits left of column n, so either one is also where a new row or column would go.
    var gap: Gap?
    var source: NoteTableSource?
    @ObservationIgnored var apply: (NoteTableEdit) -> Void = { _ in }
    @ObservationIgnored var showSource: (() -> Void)?

    var width: CGFloat { columns.reduce(0, +) }
    var height: CGFloat { rows.reduce(0, +) }
    func top(of row: Int) -> CGFloat { rows.prefix(row).reduce(0, +) }
    func left(of column: Int) -> CGFloat { columns.prefix(column).reduce(0, +) }

    var rowGrip: Int? { if case .row = gap { nil } else { row } }
    var columnGrip: Int? { if case .column = gap { nil } else { column } }

    // Frames are in the overlay, whose top left corner is a gutter above and to the left
    // of the grid.
    func rowGripFrame(_ row: Int) -> CGRect {
        CGRect(x: (Self.gutter - Self.gripThickness) / 2,
               y: Self.gutter + top(of: row) + (rows[row] - Self.gripLength) / 2,
               width: Self.gripThickness, height: Self.gripLength)
    }

    func columnGripFrame(_ column: Int) -> CGRect {
        CGRect(x: Self.gutter + left(of: column) + (columns[column] - Self.gripLength) / 2,
               y: (Self.gutter - Self.gripThickness) / 2,
               width: Self.gripLength, height: Self.gripThickness)
    }

    func plusFrame(_ gap: Gap) -> CGRect {
        let center = switch gap {
        case .row(let row): CGPoint(x: Self.gutter / 2, y: Self.gutter + top(of: row))
        case .column(let column): CGPoint(x: Self.gutter + left(of: column), y: Self.gutter / 2)
        }
        return CGRect(x: center.x - Self.plusSize / 2, y: center.y - Self.plusSize / 2,
                      width: Self.plusSize, height: Self.plusSize)
    }

    // Only the controls take clicks. Everywhere else the click belongs to the text.
    var targets: [CGRect] {
        guard lit else { return [] }
        var result: [CGRect] = []
        if let rowGrip, rows.indices.contains(rowGrip) { result.append(rowGripFrame(rowGrip)) }
        if let columnGrip, columns.indices.contains(columnGrip) { result.append(columnGripFrame(columnGrip)) }
        if let gap { result.append(plusFrame(gap)) }
        return result.map { $0.insetBy(dx: -2, dy: -2) }
    }

    func rowEntries(_ row: Int) -> [MenuEntry] {
        guard let source else { return [] }
        var entries: [MenuEntry] = []
        if row > 0 {
            entries.append(.item("Add row above", icon: "plus") { [apply] in apply(.insertRow(row)) })
        }
        entries.append(.item("Add row below", icon: "plus") { [apply] in apply(.insertRow(row + 1)) })
        if row > 0 {
            entries += [
                .separator,
                .item("Move up", icon: "arrow.up", disabled: row == 1) { [apply] in apply(.moveRow(row, by: -1)) },
                .item("Move down", icon: "arrow.down", disabled: row == source.rowCount - 1) { [apply] in apply(.moveRow(row, by: 1)) },
                .separator,
                .item("Delete row", kind: .destructive, icon: "trash") { [apply] in apply(.deleteRow(row)) }
            ]
        }
        return entries + sourceEntries
    }

    func columnEntries(_ column: Int) -> [MenuEntry] {
        guard let source else { return [] }
        let current = source.alignment(of: column)
        let alignments: [(String, String, MarkdownTable.ColumnAlignment)] = [
            ("Align left", "text.alignleft", .leading), ("Align centre", "text.aligncenter", .center),
            ("Align right", "text.alignright", .trailing)
        ]
        return alignments.map { title, icon, alignment in
            .item(title, icon: icon, checked: current == alignment) { [apply] in apply(.align(column, alignment)) }
        } + [
            .separator,
            .item("Add column left", icon: "plus") { [apply] in apply(.insertColumn(column)) },
            .item("Add column right", icon: "plus") { [apply] in apply(.insertColumn(column + 1)) },
            .separator,
            .item("Move left", icon: "arrow.left", disabled: column == 0) { [apply] in apply(.moveColumn(column, by: -1)) },
            .item("Move right", icon: "arrow.right", disabled: column == source.columnCount - 1) { [apply] in apply(.moveColumn(column, by: 1)) },
            .separator,
            .item("Delete column", kind: .destructive, icon: "trash", disabled: source.columnCount == 1) { [apply] in apply(.deleteColumn(column)) }
        ] + sourceEntries
    }

    private var sourceEntries: [MenuEntry] {
        guard let showSource else { return [] }
        return [.separator, .item("Edit table in Source", icon: "chevron.left.forwardslash.chevron.right", action: showSource)]
    }
}

struct NoteTableControlsView: View {
    let model: NoteTableControls
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredGrip: Grip?

    private enum Grip { case row, column }
    private var gutter: CGFloat { NoteTableControls.gutter }
    // The row or column a grip acts on is washed while the grip is under the pointer or
    // its menu is open, so it is clear what the menu will change.
    @State private var openGrip: Grip?
    private var marked: Grip? { hoveredGrip ?? openGrip }

    var body: some View {
        ZStack(alignment: .topLeading) {
            grid
                .frame(width: model.width, height: model.height)
                .offset(x: gutter, y: gutter)
            if let row = model.rowGrip, model.rows.indices.contains(row) {
                grip(.row, frame: model.rowGripFrame(row)) { model.rowEntries(row) }
                    .motion(Motion.control, value: row)
            }
            if let column = model.columnGrip, model.columns.indices.contains(column) {
                grip(.column, frame: model.columnGripFrame(column)) { model.columnEntries(column) }
                    .motion(Motion.control, value: column)
            }
            if let gap = model.gap {
                plus(gap).transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .motion(Motion.hover, value: model.gap)
        .opacity(model.lit ? 1 : 0)
        .motion(model.lit ? Motion.hover : Motion.leave, value: model.lit)
    }

    private var grid: some View {
        ZStack(alignment: .topLeading) {
            if marked == .row, let row = model.rowGrip, model.rows.indices.contains(row) {
                Theme.accent.opacity(0.08)
                    .frame(width: model.width, height: model.rows[row])
                    .offset(y: model.top(of: row))
                    .transition(.opacity)
            }
            if marked == .column, let column = model.columnGrip, model.columns.indices.contains(column) {
                Theme.accent.opacity(0.08)
                    .frame(width: model.columns[column], height: model.height)
                    .offset(x: model.left(of: column))
                    .transition(.opacity)
            }
            if let gap = model.gap {
                NoteTableGapLine(gap: gap, model: model, reduceMotion: reduceMotion)
                    .id(gap)
            }
        }
        .frame(width: model.width, height: model.height, alignment: .topLeading)
        .motion(Motion.hover, value: marked)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Theme.accent.opacity(0.45)))
        .allowsHitTesting(false)
    }

    private func grip(_ kind: Grip, frame: CGRect, entries: @escaping () -> [MenuEntry]) -> some View {
        NoteTableGrip(vertical: kind == .row, hovered: hoveredGrip == kind) { open in
            if open { openGrip = kind } else if openGrip == kind { openGrip = nil }
        }
        .frame(width: frame.width, height: frame.height)
        .onPointerHover { inside in
            if inside { hoveredGrip = kind } else if hoveredGrip == kind { hoveredGrip = nil }
        }
        .appMenu(entries)
        .accessibilityLabel(kind == .row ? "Row options" : "Column options")
        .offset(x: frame.minX, y: frame.minY)
    }

    private func plus(_ gap: NoteTableControls.Gap) -> some View {
        let frame = model.plusFrame(gap)
        let (label, edit): (String, NoteTableEdit) = switch gap {
        case .row(let row): ("Add row", .insertRow(row))
        case .column(let column): ("Add column", .insertColumn(column))
        }
        return Button { model.apply(edit) } label: {
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.onFill)
                .frame(width: frame.width, height: frame.height)
                .background(Circle().fill(Theme.accent))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverLift(amount: Motion.smallLift)
        .accessibilityLabel(label)
        .offset(x: frame.minX, y: frame.minY)
    }
}

// The line a new row or column would go on, drawn across the grid from the plus.
private struct NoteTableGapLine: View {
    let gap: NoteTableControls.Gap
    let model: NoteTableControls
    let reduceMotion: Bool
    @State private var drawn = false

    var body: some View {
        Path { path in
            switch gap {
            case .row(let row):
                let y = min(max(model.top(of: row), 1), model.height - 1)
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: model.width, y: y))
            case .column(let column):
                let x = min(max(model.left(of: column), 1), model.width - 1)
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: model.height))
            }
        }
        .trim(from: 0, to: drawn ? 1 : 0)
        .stroke(Theme.accent, lineWidth: 2)
        .onAppear {
            if reduceMotion { drawn = true } else { withAnimation(Motion.draw) { drawn = true } }
        }
    }
}

// Three dots on a small tab. It fills with the accent while the pointer is on it or its
// menu is open.
private struct NoteTableGrip: View {
    let vertical: Bool
    let hovered: Bool
    let onOpen: (Bool) -> Void
    @Environment(\.menuIsOpen) private var open

    var body: some View {
        let lit = hovered || open
        let dots = vertical ? AnyLayout(VStackLayout(spacing: Space.xxs)) : AnyLayout(HStackLayout(spacing: Space.xxs))
        dots {
            ForEach(0..<3, id: \.self) { _ in Circle().frame(width: 2.5, height: 2.5) }
        }
        .foregroundStyle(lit ? Theme.onFill : Color.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Radius.tag).fill(lit ? Theme.accent : Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.tag).strokeBorder(lit ? Theme.accent : Theme.border))
        .contentShape(Rectangle())
        .hoverLift(lit, amount: Motion.smallLift)
        .motion(Motion.hover, value: lit)
        .onChange(of: open) { _, open in onOpen(open) }
    }
}

// Clicks on the controls go to them, and every other click goes through to the text
// view underneath.
final class NoteTableControlsHost: NSHostingView<AnyView> {
    var model: NoteTableControls?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let model, let superview else { return nil }
        let local = convert(point, from: superview)
        let top = isFlipped ? local : NSPoint(x: local.x, y: bounds.height - local.y)
        guard model.targets.contains(where: { $0.contains(top) }) else { return nil }
        return super.hitTest(point)
    }
}

// The field a table cell is edited in, laid over the cell it edits. It shows the cell's
// Markdown, and the grid is drawn again from the new Markdown when the edit ends.
final class NoteTableCellEditor: NSView, NSTextFieldDelegate {
    enum Ending { case commit(move: Int), cancel, focusLost }

    let table: Int
    let row: Int
    let column: Int
    let field = NSTextField(string: "")
    var onEnd: ((NoteTableCellEditor, Ending) -> Void)?
    private var ended = false
    private let header: Bool
    // Room between the field and the edge of the cell, so the text sits where the grid
    // drew it. A text field draws its text two points in from its own edge.
    private static let inset = NSSize(width: 6, height: 4)

    init(table: Int, row: Int, column: Int, text: String, alignment: MarkdownTable.ColumnAlignment) {
        self.table = table
        self.row = row
        self.column = column
        self.header = row == 0
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1.5
        field.stringValue = text
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13, weight: header ? .semibold : .regular)
        field.alignment = switch alignment {
        case .leading: .natural
        case .center: .center
        case .trailing: .right
        }
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.delegate = self
        field.setAccessibilityLabel(header ? "Column title" : "Table cell")
        addSubview(field)
    }

    required init?(coder: NSCoder) { fatalError("A cell editor is never archived") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor(header ? Theme.field : Theme.card).cgColor
            layer?.borderColor = Theme.accentNSColor.cgColor
        }
    }

    override func layout() {
        super.layout()
        field.frame = bounds.insetBy(dx: Self.inset.width, dy: Self.inset.height)
    }

    // Laid over the cell, and taller than it when the text needs more lines than the
    // cell has.
    func place(over cell: NSRect) {
        let width = max(1, cell.width - Self.inset.width * 2)
        let needed = (field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 0)
            + Self.inset.height * 2
        frame = NSRect(x: cell.minX, y: cell.minY, width: cell.width, height: max(cell.height, ceil(needed)))
    }

    func controlTextDidChange(_ obj: Notification) {
        place(over: NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height))
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): end(.commit(move: 0))
        case #selector(NSResponder.insertTab(_:)): end(.commit(move: 1))
        case #selector(NSResponder.insertBacktab(_:)): end(.commit(move: -1))
        case #selector(NSResponder.cancelOperation(_:)): end(.cancel)
        default: return false
        }
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) { end(.focusLost) }

    private func end(_ ending: Ending) {
        guard !ended else { return }
        ended = true
        onEnd?(self, ending)
    }
}
