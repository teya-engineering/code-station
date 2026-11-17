import SwiftUI
import UniformTypeIdentifiers

struct SidebarDropSlot: Equatable {
    enum Place: Equatable {
        case before
        case after
        case into

        // When a row both reorders and takes rows in, its edges reorder and its middle
        // takes the dragged row in. Dropping on the top half of a row that only reorders
        // puts the dragged one before it, the bottom half after.
        static func at(_ y: CGFloat, rowHeight: CGFloat, reorders: Bool, takesIn: Bool) -> Place? {
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
}

extension View {
    // Lets a sidebar row be dragged, and dropped beside or into its neighbours. The row
    // says where the drop landed; working out what that means is left to the caller.
    func sidebarDrag(_ id: UUID,
                     reorders: Bool,
                     drags: Bool,
                     drag: Binding<SidebarDrag>,
                     takesIn: ((UUID) -> Bool)? = nil,
                     onMove: @escaping (UUID, Bool) -> Void,
                     onDropInto: @escaping (UUID) -> Void = { _ in }) -> some View {
        modifier(SidebarDragModifier(id: id,
                                     reorders: reorders,
                                     drags: drags,
                                     drag: drag,
                                     takesIn: takesIn,
                                     onMove: onMove,
                                     onDropInto: onDropInto))
    }
}

private struct SidebarDragModifier: ViewModifier {
    let id: UUID
    let reorders: Bool
    let drags: Bool
    @Binding var drag: SidebarDrag
    let takesIn: ((UUID) -> Bool)?
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

    @ViewBuilder
    private func source(_ content: Content) -> some View {
        if drags {
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
    @Binding var drag: SidebarDrag
    let onMove: (UUID, Bool) -> Void
    let onDropInto: (UUID) -> Void

    private func place(_ info: DropInfo) -> SidebarDropSlot.Place? {
        let canTakeIn = drag.itemID.map { $0 != targetID && takesIn?($0) == true } ?? false
        return .at(info.location.y, rowHeight: rowHeight, reorders: reorders, takesIn: canTakeIn)
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
        return DropProposal(operation: next == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) {
        if drag.slot?.targetID == targetID { drag.slot = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let place = place(info)
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
