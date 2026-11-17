import SwiftUI
import UniformTypeIdentifiers

struct SidebarDropSlot: Equatable {
    enum Place: Equatable {
        case before
        case after
        case into
        // Over a row that would take the dragged one in, except that it already holds
        // it. The row says so instead of quietly reordering.
        case refused

        // When a row both reorders and takes rows in, its edges reorder and its middle
        // takes the dragged row in. Dropping on the top half of a row that only reorders
        // puts the dragged one before it, the bottom half after. A row that takes the
        // dragged one in with all of itself never reorders it, which suits a row the
        // dragged one could never sit beside, such as a workspace under a project.
        static func at(_ y: CGFloat, rowHeight: CGFloat, reorders: Bool, takesIn: Bool,
                       wholeRow: Bool = false, holds: Bool = false) -> Place? {
            if holds { return .refused }
            if takesIn && wholeRow { return .into }
            switch (reorders, takesIn) {
            case (true, true):
                if y < rowHeight / 4 { return .before }
                if y > rowHeight * 3 / 4 { return .after }
                return .into
            case (true, false):
                return y > rowHeight / 2 ? .after : .before
            case (false, true):
                return .into
            case (false, false):
                return nil
            }
        }
    }

    let targetID: UUID
    let place: Place
}

// The row being dragged and where it would land. A row has to know what is coming to
// say whether it takes it in, and the dragged item itself only arrives on the drop.
struct SidebarDrag: Equatable {
    var itemID: UUID?
    var slot: SidebarDropSlot?

    // Where the carry layer and the rows it reads from meet.
    static let space = "sidebarDrag"
}

extension View {
    // Lets a sidebar row be dragged, and dropped beside or into its neighbours. The row
    // says where the drop landed; working out what that means is left to the caller.
    func sidebarDrag(_ id: UUID,
                     reorders: Bool,
                     drags: Bool,
                     drag: Binding<SidebarDrag>,
                     carriesChip: Bool = false,
                     takesIn: ((UUID) -> Bool)? = nil,
                     wholeRow: Bool = false,
                     holds: ((UUID) -> Bool)? = nil,
                     onMove: @escaping (UUID, Bool) -> Void,
                     onDropInto: @escaping (UUID) -> Void = { _ in }) -> some View {
        modifier(SidebarDragModifier(id: id,
                                     reorders: reorders,
                                     drags: drags,
                                     drag: drag,
                                     carriesChip: carriesChip,
                                     takesIn: takesIn,
                                     wholeRow: wholeRow,
                                     holds: holds,
                                     onMove: onMove,
                                     onDropInto: onDropInto))
    }
}

private struct SidebarDragModifier: ViewModifier {
    let id: UUID
    let reorders: Bool
    let drags: Bool
    @Binding var drag: SidebarDrag
    let carriesChip: Bool
    let takesIn: ((UUID) -> Bool)?
    let wholeRow: Bool
    let holds: ((UUID) -> Bool)?
    let onMove: (UUID, Bool) -> Void
    let onDropInto: (UUID) -> Void

    @State private var height: CGFloat = 0

    private var place: SidebarDropSlot.Place? {
        drag.slot?.targetID == id ? drag.slot?.place : nil
    }

    func body(content: Content) -> some View {
        if drags || reorders || takesIn != nil {
            source(content)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                .onDrop(of: [.plainText], delegate: SidebarDropDelegate(targetID: id,
                                                                        rowHeight: height,
                                                                        reorders: reorders,
                                                                        takesIn: takesIn,
                                                                        wholeRow: wholeRow,
                                                                        holds: holds,
                                                                        drag: $drag,
                                                                        onMove: onMove,
                                                                        onDropInto: onDropInto))
                // A drag that is cancelled, or let go where nothing takes it, never tells
                // the row it left, so the mark would stay. Hover never fires while a drag
                // is under way, so the first hover after one ends is a safe time to clear it.
                .onHover { _ in
                    if drag.slot != nil { drag.slot = nil }
                }
                .background {
                    RoundedRectangle(cornerRadius: Radius.control)
                        .fill(Theme.accent.opacity(place == .into ? 0.12 : 0))
                        .overlay(RoundedRectangle(cornerRadius: Radius.control)
                            .stroke(Theme.accent.opacity(place == .into ? 1 : 0), lineWidth: 1.5))
                        .motion(Motion.hover, value: place == .into)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: place == .after ? .bottom : .top) {
                    if place == .before || place == .after {
                        // Drawn in the gap between rows, so the line sits where the row
                        // will land rather than over a neighbour.
                        Capsule()
                            .fill(Theme.accent)
                            .frame(height: 2)
                            .offset(y: place == .after ? 1 : -1)
                            .allowsHitTesting(false)
                    }
                }
        } else {
            content
        }
    }

    // A row that carries a chip hands the system an empty drag image: the chip is drawn
    // by the sidebar's carry layer instead, hanging clear of the pointer and saying what
    // the row under it would do. While it is carried, the row itself stays behind as a
    // ghost of where it came from.
    @ViewBuilder
    private func source(_ content: Content) -> some View {
        if drags && carriesChip {
            content
                .opacity(drag.itemID == id ? 0.35 : 1)
                .motion(Motion.reveal, value: drag.itemID == id)
                .onDrag {
                    drag.itemID = id
                    return NSItemProvider(object: id.uuidString as NSString)
                } preview: {
                    Color.clear.frame(width: 1, height: 1)
                }
        } else if drags {
            content.onDrag {
                drag.itemID = id
                return NSItemProvider(object: id.uuidString as NSString)
            }
        } else {
            content
        }
    }
}

private struct SidebarDropDelegate: DropDelegate {
    let targetID: UUID
    let rowHeight: CGFloat
    let reorders: Bool
    let takesIn: ((UUID) -> Bool)?
    let wholeRow: Bool
    let holds: ((UUID) -> Bool)?
    @Binding var drag: SidebarDrag
    let onMove: (UUID, Bool) -> Void
    let onDropInto: (UUID) -> Void

    private func place(_ info: DropInfo) -> SidebarDropSlot.Place? {
        let other = drag.itemID.flatMap { $0 == targetID ? nil : $0 }
        return .at(info.location.y, rowHeight: rowHeight, reorders: reorders,
                   takesIn: other.map { takesIn?($0) == true } ?? false,
                   wholeRow: wholeRow,
                   holds: other.map { holds?($0) == true } ?? false)
    }

    private func slot(_ info: DropInfo) -> SidebarDropSlot? {
        place(info).map { SidebarDropSlot(targetID: targetID, place: $0) }
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText]) && place(info) != nil
    }

    func dropEntered(info: DropInfo) {
        drag.slot = slot(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let next = slot(info)
        if drag.slot != next { drag.slot = next }
        return DropProposal(operation: next == nil || next?.place == .refused ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) {
        if drag.slot?.targetID == targetID { drag.slot = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let place = place(info)
        guard place != .refused else { return false }
        drag = SidebarDrag()
        guard let place, let provider = info.itemProviders(for: [.plainText]).first else { return false }
        _ = provider.loadTransferable(type: String.self) { result in
            guard case .success(let value) = result, let id = UUID(uuidString: value) else { return }
            Task { @MainActor in
                if place == .into { onDropInto(id) } else { onMove(id, place == .after) }
            }
        }
        return true
    }
}
