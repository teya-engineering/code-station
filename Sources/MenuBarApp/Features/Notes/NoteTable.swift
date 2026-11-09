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

// The answer a table gives the pointer. The grid itself cannot be edited in place, so
// the hover says where it can be.
@MainActor @Observable
final class NoteTableHoverState {
    var lit = false
}

struct NoteTableHover: View {
    let state: NoteTableHoverState
    // Room above the table for the tag, which sits across its top edge.
    static let tagRoom: CGFloat = 12

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent.opacity(0.45)))
                .padding(.top, Self.tagRoom)
            HStack(spacing: 5) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                Text("Double-click to edit in Source")
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Theme.card))
            .overlay(Capsule().stroke(Theme.border))
            .padding(.trailing, 10).padding(.top, 1)
        }
        .opacity(state.lit ? 1 : 0)
        .motion(state.lit ? Motion.hover : Motion.leave, value: state.lit)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// Clicks go through to the text view underneath.
final class NoteTableHoverHost: NSHostingView<NoteTableHover> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
