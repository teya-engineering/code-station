import AppKit
import SwiftUI
import CodeStationCore

struct SideBySideDiff: View {
    let lines: [DiffLine]
    let expand: (String, DiffExpandDirection) -> Void
    // What hangs under a row, keyed by the id of the diff line it follows: the review
    // comments placed there, and the comment being written if it is about those lines.
    var threads: [Int: AnyView] = [:]
    var picked: Set<String> = []
    // A press on a line number, and whether shift was held. A diff with nowhere to send
    // comments leaves it out, and its numbers are plain text.
    var onLine: ((DiffAnchor, Bool) -> Void)?
    // A drag down the numbers, ending on another line of the same version.
    var onRange: ((DiffAnchor) -> Void)?
    // The thread to bring on screen. A new serial asks again for the same one.
    var reveal: DiffReveal?

    @State private var numberFrames: [DiffAnchor: CGRect] = [:]
    @State private var dragStart: DiffAnchor?
    @State private var dragEnd: DiffAnchor?

    private static let space = "sideBySideRows"

    var body: some View {
        GeometryReader { geometry in
          ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(spacing: 0) {
                    ForEach(DiffComparisonRow.align(lines)) { row in
                        if let gap = row.left?.gap {
                            HStack {
                                ForEach([DiffExpandDirection.up, .all, .down], id: \.self) { direction in
                                    Button("Show context \(direction.rawValue)") { expand(gap.key, direction) }
                                        .buttonStyle(.plain)
                                }
                            }
                            .font(.system(size: 11)).padding(8)
                        } else if row.left?.kind == .hunk || row.left?.kind == .meta || row.left?.kind == .section {
                            Text(row.left?.text ?? "").font(.mono(11))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                                .background(Theme.field)
                        } else {
                            HStack(alignment: .top, spacing: 0) {
                                cell(row.left, number: row.oldNumber,
                                     anchor: anchor(row.left, side: .old, number: row.oldNumber))
                                cell(row.right, number: row.newNumber,
                                     anchor: anchor(row.right, side: .new, number: row.newNumber))
                            }
                            ForEach(rowThreads(row), id: \.self) { id in
                                threads[id]
                                    .frame(maxWidth: min(760, geometry.size.width - 80), alignment: .leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, 54).padding(.trailing, 12).padding(.vertical, 6)
                                    .background(Theme.field.opacity(0.5))
                                    .id(id)
                            }
                        }
                    }
                }
                .coordinateSpace(name: Self.space)
                .onPreferenceChange(NumberFrames.self) { numberFrames = $0 }
                .frame(width: max(760, geometry.size.width))
            }
            .onChange(of: reveal) { _, reveal in
                if let reveal { withAnimation(Motion.reveal) { proxy.scrollTo(reveal.line, anchor: .center) } }
            }
            .onAppear {
                if let reveal { proxy.scrollTo(reveal.line, anchor: .center) }
            }
          }
        }
    }

    // A context line is numbered on both sides but commented on in the new version, so
    // its left number is not a place to start one.
    private func anchor(_ line: DiffLine?, side: ReviewSide, number: Int?) -> DiffAnchor? {
        guard onLine != nil, let line, let number else { return nil }
        switch line.kind {
        case .addition where side == .new, .context where side == .new: return DiffAnchor(side: .new, line: number)
        case .deletion where side == .old: return DiffAnchor(side: .old, line: number)
        default: return nil
        }
    }

    private func rowThreads(_ row: DiffComparisonRow) -> [Int] {
        var ids = [row.left?.id, row.right?.id].compactMap { $0 }
        if ids.count == 2 && ids[0] == ids[1] { ids.removeLast() }
        return ids.filter { threads[$0] != nil }
    }

    // The lines a drag in progress covers, drawn picked out before it lets go.
    private var dragged: Set<String> {
        guard let dragStart, let dragEnd else { return [] }
        return DiffComments.keys(dragStart.extended(to: dragEnd))
    }

    @ViewBuilder private func number(_ number: Int?, anchor: DiffAnchor?) -> some View {
        let label = Text(number.map(String.init) ?? "").foregroundStyle(.secondary)
            .frame(width: 36, alignment: .trailing)
        if let anchor, let onLine {
            label
                .contentShape(Rectangle())
                .hoverFill(cornerRadius: 4)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: NumberFrames.self,
                                           value: [anchor: proxy.frame(in: .named(Self.space))])
                })
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                    .onChanged { value in
                        if dragStart == nil { dragStart = anchor; dragEnd = anchor }
                        if let over = numberFrames.first(where: {
                            $0.key.side == anchor.side && $0.value.minY <= value.location.y && value.location.y < $0.value.maxY
                        })?.key {
                            dragEnd = over
                        }
                    }
                    .onEnded { _ in
                        let start = dragStart ?? anchor
                        let end = dragEnd ?? anchor
                        dragStart = nil
                        dragEnd = nil
                        if end != start, let onRange {
                            onRange(start.extended(to: end))
                        } else {
                            onLine(start, NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
                        }
                    })
                .appTooltip("Comment on this line. Drag down the numbers or shift-click to cover more.")
                .accessibilityElement()
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Comment on \(anchor.label.lowercased())")
                .accessibilityAction { onLine(anchor, false) }
        } else {
            label
        }
    }

    private func cell(_ line: DiffLine?, number: Int?, anchor: DiffAnchor? = nil) -> some View {
        let isPicked = anchor.map { !picked.union(dragged).isDisjoint(with: DiffComments.keys($0)) } == true
        return HStack(alignment: .top, spacing: 8) {
            self.number(number, anchor: anchor)
            Text(line.map { String($0.text.prefix(1)) } ?? "").frame(width: 10)
            Text(line.map { String($0.text.dropFirst()) } ?? " ")
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.mono(12)).padding(.vertical, 3).padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if line == nil {
                Canvas { context, size in
                    var stripes = Path()
                    for x in stride(from: -size.height, to: size.width, by: 8) {
                        stripes.move(to: CGPoint(x: x, y: 0))
                        stripes.addLine(to: CGPoint(x: x + size.height, y: size.height))
                    }
                    context.stroke(stripes, with: .color(Theme.border), lineWidth: 3)
                }.background(Theme.field).clipped()
            }
        }
        .background(line?.kind == .addition ? Theme.addition.opacity(0.12) :
                    line?.kind == .deletion ? Theme.deletion.opacity(0.12) : line == nil ? Theme.field : .clear)
        .background(isPicked ? Theme.accent.opacity(0.16) : .clear)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
        .accessibilityLabel(line == nil ? "No corresponding line" : line!.text)
    }
}

// Where each line number sits in the rows, so a drag can tell which number it is over.
private struct NumberFrames: PreferenceKey {
    static let defaultValue: [DiffAnchor: CGRect] = [:]
    static func reduce(value: inout [DiffAnchor: CGRect], nextValue: () -> [DiffAnchor: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
