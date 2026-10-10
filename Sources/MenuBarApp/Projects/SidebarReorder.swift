import SwiftUI
import UniformTypeIdentifiers

struct SidebarDropSlot: Equatable {
    let targetID: UUID
    let after: Bool
}

extension View {
    // Lets a sidebar row be dragged and dropped on its neighbours. The row says where the
    // drop landed; working out what that means is left to the caller.
    func sidebarReorder(_ id: UUID, enabled: Bool, slot: Binding<SidebarDropSlot?>,
                        onDrop: @escaping (UUID, Bool) -> Void) -> some View {
        modifier(SidebarReorder(id: id, enabled: enabled, slot: slot, onDrop: onDrop))
    }
}

private struct SidebarReorder: ViewModifier {
    let id: UUID
    let enabled: Bool
    @Binding var slot: SidebarDropSlot?
    let onDrop: (UUID, Bool) -> Void

    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        if enabled {
            content
                .draggable(id.uuidString)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                .onDrop(of: [.plainText], delegate: SidebarDropDelegate(
                    targetID: id, rowHeight: height, slot: $slot, onDrop: onDrop))
                .overlay(alignment: slot?.after == true ? .bottom : .top) {
                    if slot?.targetID == id {
                        // Drawn in the gap between rows, so the line sits where the row
                        // will land rather than over a neighbour.
                        Capsule()
                            .fill(Theme.accent)
                            .frame(height: 2)
                            .offset(y: slot?.after == true ? 1 : -1)
                            .allowsHitTesting(false)
                    }
                }
        } else {
            content
        }
    }
}

// Dropping on the top half of a row puts the dragged one before it, the bottom half after.
private struct SidebarDropDelegate: DropDelegate {
    let targetID: UUID
    let rowHeight: CGFloat
    @Binding var slot: SidebarDropSlot?
    let onDrop: (UUID, Bool) -> Void

    private func after(_ info: DropInfo) -> Bool {
        info.location.y > rowHeight / 2
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText])
    }

    func dropEntered(info: DropInfo) {
        slot = SidebarDropSlot(targetID: targetID, after: after(info))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let next = SidebarDropSlot(targetID: targetID, after: after(info))
        if slot != next { slot = next }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if slot?.targetID == targetID { slot = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let placeAfter = after(info)
        slot = nil
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        _ = provider.loadTransferable(type: String.self) { result in
            guard case .success(let value) = result, let id = UUID(uuidString: value) else { return }
            Task { @MainActor in onDrop(id, placeAfter) }
        }
        return true
    }
}
