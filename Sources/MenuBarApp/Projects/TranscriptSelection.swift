import AppKit
import SwiftUI

// What a piece of the transcript is, as far as copying it is concerned. Most of it is
// simply a run of text. A table cell also knows which table and row it belongs to, so a
// selection over a table can be put back together as a grid.
enum TranscriptTextRole: Equatable {
    case block
    case tableCell(table: UUID, row: Int)
}

// One selection running across the many text views a transcript is built from.
//
// A transcript draws every paragraph, heading, list item and quote as its own text
// view, and a text view only ever selects inside itself, so a drag would stop where
// the block does. This keeps the views in reading order and hands each one the part
// of the selection that falls inside it, so a sweep down the page reads as a single
// selection and copies as one piece of text.
//
// Views with no coordinator in scope keep selecting on their own, which is what a
// file preview wants.
@MainActor
final class TranscriptSelection {
    private struct Caret {
        let view: NSTextView
        let character: Int
    }

    // The views are held weakly: a block that scrolls out of the window or is replaced
    // while a turn streams must not be kept alive by the selection that crossed it.
    private struct Registration {
        weak var view: NSTextView?
        var role: TranscriptTextRole
    }

    // A registered view together with where it sits and what it is.
    private struct Block {
        let view: NSTextView
        let frame: CGRect
        let role: TranscriptTextRole
    }

    private var registrations: [Registration] = []
    private var anchor: Caret?
    private var focus: Caret?

    // MARK: - Membership

    func register(_ view: NSTextView, role: TranscriptTextRole = .block) {
        prune()
        // A table being rewritten as a turn streams can move a cell to another row, so
        // a view already known still takes the role it arrives with.
        if let index = registrations.firstIndex(where: { $0.view === view }) {
            registrations[index].role = role
            return
        }
        registrations.append(Registration(view: view, role: role))
    }

    func unregister(_ view: NSTextView) {
        registrations.removeAll { $0.view == nil || $0.view === view }
        if anchor?.view === view || focus?.view === view {
            anchor = nil
            focus = nil
        }
    }

    // MARK: - Dragging

    func begin(in view: NSTextView, at point: CGPoint) {
        let caret = Caret(view: view, character: view.characterIndexForInsertion(at: point))
        anchor = caret
        focus = caret
        apply()
    }

    func extend(toWindowPoint windowPoint: CGPoint) {
        guard anchor != nil, let caret = caret(atWindowPoint: windowPoint) else { return }
        focus = caret
        apply()
    }

    func selectAll() {
        let views = ordered()
        guard let first = views.first, let last = views.last else { return }
        anchor = Caret(view: first, character: 0)
        focus = Caret(view: last, character: length(of: last))
        apply()
    }

    // A press on the page rather than on any of its words puts the selection away, the
    // same way a press inside a block would start a new one.
    func clearUnlessInsideText(atWindowPoint windowPoint: CGPoint) {
        guard !placed().contains(where: { $0.frame.contains(windowPoint) }) else { return }
        clear()
    }

    func clear() {
        anchor = nil
        focus = nil
        for view in ordered() {
            view.setSelectedRange(NSRange(location: 0, length: 0))
            view.needsDisplay = true
        }
    }

    // MARK: - Reading

    // The blocks are joined by a blank line because that is the gap the transcript
    // draws between them, so pasted text keeps the shape it was read in.
    var selectedText: String? {
        let taken = placed().compactMap { block -> (role: TranscriptTextRole, text: String)? in
            let range = block.view.selectedRange()
            guard range.length > 0, let storage = block.view.textStorage,
                  NSMaxRange(range) <= storage.length else { return nil }
            return (block.role, storage.attributedSubstring(from: range).string)
        }
        guard !taken.isEmpty else { return nil }

        var pieces: [String] = []
        var index = 0
        while index < taken.count {
            guard case .tableCell(let table, _) = taken[index].role else {
                pieces.append(taken[index].text)
                index += 1
                continue
            }

            // Every cell taken from one table becomes a single piece: a tab between the
            // cells of a row and a newline between the rows. Pasted anywhere that reads
            // tabs, such as a spreadsheet, the grid arrives as a grid.
            var rows: [[String]] = []
            var current: Int?
            while index < taken.count,
                  case .tableCell(let next, let row) = taken[index].role,
                  next == table {
                if row != current {
                    rows.append([])
                    current = row
                }
                rows[rows.count - 1].append(taken[index].text)
                index += 1
            }
            pieces.append(rows.map { $0.joined(separator: "\t") }.joined(separator: "\n"))
        }
        return pieces.joined(separator: "\n\n")
    }

    // MARK: - Order

    // Reading order comes from where the views actually sit, not from how they were
    // built, so a list item indented inside a row and a paragraph in the next message
    // need no bookkeeping to land in the right place. Window coordinates are used
    // because they always run from the bottom left, whatever the views in between do
    // with their own axes.
    private func ordered() -> [NSTextView] {
        placed().map(\.view)
    }

    // The frames come back alongside the views because a drag asks for them on every
    // mouse move, and converting each one again per comparison while sorting or
    // searching would cost far more than carrying them.
    private func placed() -> [Block] {
        prune()
        return registrations
            .compactMap { registration in
                registration.view.map {
                    Block(view: $0, frame: $0.convert($0.bounds, to: nil), role: registration.role)
                }
            }
            .filter { $0.view.window != nil }
            .sorted { a, b in
                if abs(a.frame.maxY - b.frame.maxY) > 1 { return a.frame.maxY > b.frame.maxY }
                return a.frame.minX < b.frame.minX
            }
    }

    private func prune() {
        registrations.removeAll { $0.view == nil }
    }

    private func caret(atWindowPoint windowPoint: CGPoint) -> Caret? {
        let blocks = placed()
        guard !blocks.isEmpty else { return nil }

        for block in blocks where block.frame.contains(windowPoint) {
            let local = block.view.convert(windowPoint, from: nil)
            return Caret(view: block.view,
                         character: block.view.characterIndexForInsertion(at: local))
        }

        // The pointer is in the space between two blocks, or past the end of the
        // transcript. Snapping to the nearest block keeps a drag running instead of
        // freezing it at the edge of the last block the pointer was over.
        guard let nearest = blocks.min(by: {
            distance(from: windowPoint, to: $0.frame) < distance(from: windowPoint, to: $1.frame)
        }) else { return nil }
        let above = windowPoint.y > nearest.frame.midY
        return Caret(view: nearest.view, character: above ? 0 : length(of: nearest.view))
    }

    private func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    // MARK: - Applying

    private func apply() {
        let views = ordered()
        guard let anchor, let focus,
              let anchorPosition = views.firstIndex(where: { $0 === anchor.view }),
              let focusPosition = views.firstIndex(where: { $0 === focus.view })
        else { return }

        let reversed = focusPosition < anchorPosition
        let first = reversed ? focusPosition : anchorPosition
        let last = reversed ? anchorPosition : focusPosition
        let opening = reversed ? focus : anchor
        let closing = reversed ? anchor : focus

        for (position, view) in views.enumerated() {
            let total = length(of: view)
            let range: NSRange
            if first == last, position == first {
                let lower = min(opening.character, closing.character)
                let upper = max(opening.character, closing.character)
                range = clamped(NSRange(location: lower, length: upper - lower), to: total)
            } else if position == first {
                range = clamped(NSRange(location: opening.character,
                                        length: total - opening.character), to: total)
            } else if position == last {
                range = clamped(NSRange(location: 0, length: closing.character), to: total)
            } else if position > first, position < last {
                range = NSRange(location: 0, length: total)
            } else {
                range = NSRange(location: 0, length: 0)
            }

            guard view.selectedRange() != range else { continue }
            view.setSelectedRange(range)
            // The highlight is painted from the selected range rather than by AppKit,
            // so the view has to be told the range moved.
            view.needsDisplay = true
        }
    }

    // A block's text is rewritten as a turn streams, so an index taken a moment ago can
    // sit past the end of what the block now holds.
    private func clamped(_ range: NSRange, to total: Int) -> NSRange {
        let location = min(max(0, range.location), total)
        return NSRange(location: location, length: min(max(0, range.length), total - location))
    }

    private func length(of view: NSTextView) -> Int {
        view.textStorage?.length ?? 0
    }
}

extension EnvironmentValues {
    @Entry var transcriptSelection: TranscriptSelection?
}


// Watches for a click that lands on the transcript but on none of its text, and puts the
// selection away.
//
// The click is watched rather than caught. A catcher in front would swallow presses
// meant for the blocks, and one behind would never see them: most of the page is drawn
// by SwiftUI without a view of its own, so there is nothing for a press to fall through
// from. A monitor sees the press first and passes it straight on.
struct TranscriptSelectionClearing: NSViewRepresentable {
    let selection: TranscriptSelection

    func makeNSView(context: Context) -> ClearingView {
        let view = ClearingView()
        view.selection = selection
        return view
    }

    func updateNSView(_ view: ClearingView, context: Context) {
        view.selection = selection
    }

    static func dismantleNSView(_ view: ClearingView, coordinator: ()) {
        view.stopWatching()
    }

    final class ClearingView: NSView {
        var selection: TranscriptSelection?
        private var monitor: Any?

        // Nothing is ever clicked here. The view is only a place to hang the monitor
        // and the frame that says which presses belong to this transcript.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return stopWatching() }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.clearIfNeeded(event)
                return event
            }
        }

        func stopWatching() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func clearIfNeeded(_ event: NSEvent) {
            guard let window, event.window === window else { return }
            guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            selection?.clearUnlessInsideText(atWindowPoint: event.locationInWindow)
        }
    }
}
