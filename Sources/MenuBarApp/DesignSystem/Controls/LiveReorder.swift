import SwiftUI

// A list sorted by dragging, where the dragged row follows the pointer and the rows it
// passes step aside at once to show where it will land. The rows share one state, so
// anything else on the screen can read the order as it would be if the row were let go
// now, such as a button that shows whatever is on top.
//
// The rows are stacked with one gap between them. Each row is measured as it is drawn,
// so rows of different heights still make exactly the room the dragged one needs.
struct LiveReorder: Equatable {
    private(set) var itemID: UUID?
    private(set) var travel: CGFloat = 0
    private(set) var start: [UUID] = []
    private(set) var spacing: CGFloat = 0
    private var heights: [UUID: CGFloat] = [:]

    var isDragging: Bool { itemID != nil }

    // Where the dragged row would land if it were let go now, counted with the row
    // itself taken out. A row passes a neighbour once it is over that neighbour's middle.
    var target: Int? {
        guard let itemID, let from = start.firstIndex(of: itemID) else { return nil }
        var position = from
        var passed: CGFloat = 0
        let neighbours = travel > 0 ? Array(start.indices.dropFirst(from + 1))
                                    : Array(start.indices.prefix(from).reversed())
        for index in neighbours {
            let pitch = height(start[index]) + spacing
            guard abs(travel) > passed + pitch / 2 else { break }
            position = index
            passed += pitch
        }
        return position
    }

    // The order as it would be if the row were let go now.
    func preview(_ ids: [UUID]) -> [UUID] {
        guard let itemID, let target, let from = ids.firstIndex(of: itemID) else { return ids }
        var moved = ids
        moved.remove(at: from)
        moved.insert(itemID, at: min(target, moved.count))
        return moved
    }

    // How far a row is drawn from its place: the dragged one by the pointer's travel,
    // the ones it has passed by the room it takes.
    func shift(of id: UUID) -> CGFloat {
        guard let itemID, let from = start.firstIndex(of: itemID), let to = target else { return 0 }
        if id == itemID { return travel }
        guard let index = start.firstIndex(of: id) else { return 0 }
        let room = height(itemID) + spacing
        if from < to, index > from, index <= to { return -room }
        if to < from, index >= to, index < from { return room }
        return 0
    }

    func height(_ id: UUID) -> CGFloat { heights[id] ?? 0 }

    mutating func measure(_ id: UUID, height: CGFloat) {
        if heights[id] != height { heights[id] = height }
    }

    mutating func begin(_ id: UUID, in ids: [UUID], spacing: CGFloat) {
        itemID = id
        start = ids
        travel = 0
        self.spacing = spacing
    }

    mutating func follow(_ travel: CGFloat) {
        self.travel = travel
    }

    mutating func end() {
        itemID = nil
        travel = 0
        start = []
    }
}

extension View {
    // Lets a row of a stacked list be dragged into a new place. `ids` is every row of the
    // list in the order shown, and `spacing` the gap the stack puts between them. A drag
    // starts after a few points of travel, so a click on the row still reaches it. The
    // drop hands back the row and its new position, counted with the row taken out.
    func liveReorder(_ id: UUID, in ids: [UUID], spacing: CGFloat, enabled: Bool,
                     cornerRadius: CGFloat, state: Binding<LiveReorder>,
                     onDrop: @escaping (UUID, Int) -> Void) -> some View {
        modifier(LiveReorderModifier(id: id, ids: ids, spacing: spacing, enabled: enabled,
                                     cornerRadius: cornerRadius, state: state, onDrop: onDrop))
    }
}

private struct LiveReorderModifier: ViewModifier {
    let id: UUID
    let ids: [UUID]
    let spacing: CGFloat
    let enabled: Bool
    let cornerRadius: CGFloat
    @Binding var state: LiveReorder
    let onDrop: (UUID, Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Enough travel to tell a drag from a click that wobbled.
    static let slop: CGFloat = 5

    private var dragging: Bool { state.itemID == id }

    func body(content: Content) -> some View {
        let shift = state.shift(of: id)
        content
            // A row that is clear at rest still needs a solid face while it is carried
            // over the others.
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Theme.card)
                    .opacity(dragging ? 1 : 0)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Theme.accent, lineWidth: 1.5)
                    .opacity(dragging ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .elevation(dragging ? .floating : .none)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if state.height(id) != height { state.measure(id, height: height) }
            }
            // Moved by an offset only, never scaled: rows carry AppKit-backed parts that
            // cannot be laid out under a scale. The dragged row follows the pointer with no
            // curve at all, and the rows making room for it take the control curve.
            .offset(y: shift)
            .motion(Motion.control, value: dragging ? 0 : shift)
            .motion(Motion.hover, value: dragging)
            .zIndex(dragging ? 1 : 0)
            .highPriorityGesture(drag, including: enabled ? .all : .subviews)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: Self.slop, coordinateSpace: .global)
            .onChanged { value in
                if state.itemID == nil { state.begin(id, in: ids, spacing: spacing) }
                guard state.itemID == id else { return }
                state.follow(value.translation.height)
            }
            .onEnded { _ in
                guard state.itemID == id else { return }
                let target = state.target
                // The new order and the end of the drag land together, so each row that
                // made room is already where the new order puts it, and only the dragged
                // row settles into its place.
                withAnimation(reduceMotion ? nil : Motion.control) {
                    if let target, target != ids.firstIndex(of: id) { onDrop(id, target) }
                    state.end()
                }
            }
    }
}

// The marked place at the top of an ordered list whose first row has a job of its own,
// such as the shortcut on the split button. A dashed accent frame with a caption sits
// behind the first row, and stays put while rows are dragged through it.
//
// It is drawn as a top-aligned background of the list, which leaves `topRoom` above its
// first row and `inset` on each side.
struct LeadSlot: View {
    let caption: String
    var icon = "capsule"
    var keys: String?
    // How tall the row inside the frame is.
    let rowHeight: CGFloat

    static let captionHeight = ControlHeight.sm
    // How far the frame reaches past the row on each side.
    static let inset = Space.xs

    // The room a list leaves above its first row for the caption.
    static var topRoom: CGFloat { captionHeight + inset }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.sm) {
                Image(systemName: icon)
                    .accessibilityHidden(true)
                Text(caption)
                Spacer(minLength: Space.sm)
                if let keys { Keycap(keys) }
            }
            .font(Typography.caption.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, Space.sm)
            .frame(height: Self.captionHeight)
            Color.clear.frame(height: rowHeight + Self.inset)
        }
        .padding(.top, Self.inset)
        .background {
            RoundedRectangle(cornerRadius: Radius.floating)
                .fill(Theme.accent.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: Radius.floating)
                    .strokeBorder(Theme.accent.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

// The tile beside a shortcut's name, which says what kind it is without a word: a command
// wears the terminal it runs in, a prompt the leaf of the person's own messages.
struct KindTile: View {
    let kind: ShortcutKind
    let icon: String
    var side: CGFloat = ControlHeight.md

    var body: some View {
        Image(systemName: icon)
            .font(Typography.body.weight(.semibold))
            .foregroundStyle(kind == .command ? Theme.terminalText : Theme.accent)
            .frame(width: side, height: side)
            .background(RoundedRectangle(cornerRadius: Radius.control)
                .fill(kind == .command ? Theme.terminal : Theme.userMessage))
            .overlay(RoundedRectangle(cornerRadius: Radius.control)
                .strokeBorder(kind == .command ? Theme.border : Theme.userMessageRing))
            .accessibilityHidden(true)
    }
}
