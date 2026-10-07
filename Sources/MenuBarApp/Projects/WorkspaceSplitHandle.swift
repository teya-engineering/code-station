import SwiftUI

struct WorkspaceSplitHandle: View {
    @Binding var width: CGFloat
    let displayedWidth: CGFloat
    let availableWidth: CGFloat
    @State private var dragStart: CGFloat?

    var body: some View {
        Color.clear
            .frame(width: ExplorerSplitLayout.handleWidth)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStart ?? displayedWidth
                    dragStart = start
                    width = ExplorerSplitLayout.treeWidth(start + value.translation.width,
                                                          availableWidth: availableWidth)
                }
                .onEnded { _ in dragStart = nil })
            .cursorOnHover(.resizeLeftRight)
            .appTooltip("Drag to resize")
            .accessibilityElement()
            .accessibilityLabel("Resize workspace sidebar")
            .accessibilityValue("\(Int(displayedWidth)) points wide")
            .accessibilityAdjustableAction { direction in
                let change: CGFloat = switch direction {
                case .increment: 32
                case .decrement: -32
                @unknown default: 0
                }
                width = ExplorerSplitLayout.treeWidth(displayedWidth + change, availableWidth: availableWidth)
            }
    }
}
