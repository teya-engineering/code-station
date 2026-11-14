import SwiftUI

struct DispatchTabs<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let namespace: Namespace.ID
    let label: (Item) -> String
    var detail: (Item) -> String? = { _ in nil }
    @FocusState private var focused: Item?
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: Space.xxl) {
            ForEach(items, id: \.self) { item in
                Button { selection = item } label: {
                    HStack(spacing: Space.xs) {
                        Text(label(item))
                        if let detail = detail(item) {
                            Text(detail).font(Font.system(size: Typography.Size.micro))
                                .padding(.horizontal, Space.xs).padding(.vertical, 1)
                                .background(Theme.field, in: RoundedRectangle(cornerRadius: Radius.tag))
                        }
                    }
                    .font(Typography.detail.weight(selection == item ? .semibold : .regular))
                    .foregroundStyle(selection == item ? Theme.accent : .secondary)
                    // Lifted before the underline is drawn, so the underline stays still.
                    .hoverLift()
                    .frame(height: 37)
                    .overlay(alignment: .bottom) {
                        if selection == item {
                            Capsule().fill(Theme.accent).frame(height: 2)
                                .matchedGeometryEffect(id: "indicator", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(isEnabled).focused($focused, equals: item).focusEffectDisabled()
                .overlay(RoundedRectangle(cornerRadius: Radius.tag)
                    .stroke(focused == item ? Theme.accent : .clear, lineWidth: 2).padding(Space.xxs))
                .onKeyPress(keys: [.leftArrow, .rightArrow, .home, .end]) { key in
                    guard isEnabled, let index = items.firstIndex(of: item), !items.isEmpty else { return .ignored }
                    let next = key.key == .home ? 0 : key.key == .end ? items.count - 1
                        : (index + (key.key == .rightArrow ? 1 : items.count - 1)) % items.count
                    selection = items[next]
                    focused = selection
                    return .handled
                }
                .onKeyPress(keys: [.space, .return]) { _ in
                    guard isEnabled else { return .ignored }
                    selection = item
                    return .handled
                }
                .accessibilityLabel("\(label(item)) tab")
                .accessibilityAddTraits(selection == item ? [.isSelected] : [])
                .accessibilityLabeledPair(role: .label, id: item, in: namespace)
            }
        }
        .motion(Motion.control, value: selection)
        .accessibilityElement(children: .contain)
    }
}

struct DispatchResponseGrip: View {
    let height: CGFloat
    let availableHeight: CGFloat
    @Binding var dragHeight: CGFloat?
    @Environment(DispatchStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragStart: CGFloat?
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        Capsule().fill(focused || hovering ? Theme.accent : Theme.border)
            .frame(width: focused || hovering ? 40 : 28, height: 3)
            .frame(maxWidth: .infinity)
            .frame(height: DispatchSplitLayout.handleHeight)
            .background(Theme.sidebar)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStart ?? height
                    dragStart = start
                    dragHeight = DispatchSplitLayout.responseHeight(start - value.translation.height,
                                                                    available: availableHeight)
                }
                .onEnded { _ in
                    if let dragHeight { store.responseHeight = dragHeight }
                    dragHeight = nil
                    dragStart = nil
                })
            .onPointerHover { hovering = $0 }
            .cursorOnHover(.resizeUpDown)
            .focusable().focused($focused).focusEffectDisabled()
            .overlay(Rectangle().stroke(focused ? Theme.accent : .clear))
            .onKeyPress(keys: [.upArrow, .downArrow]) { key in
                resize(by: key.key == .upArrow ? 24 : -24)
                return .handled
            }
            .accessibilityElement()
            .accessibilityLabel("Resize response pane")
            .accessibilityValue("\(Int(height)) points high")
            .accessibilityHint("Use Up and Down to resize")
            .accessibilityAdjustableAction { direction in
                resize(by: direction == .increment ? 24 : -24)
            }
            .appTooltip("Drag or use Up and Down to resize the response")
            .motion(Motion.hover, value: hovering || focused)
    }

    private func resize(by change: CGFloat) {
        withAnimation(reduceMotion ? nil : Motion.control) {
            store.responseHeight = DispatchSplitLayout.responseHeight(height + change, available: availableHeight)
        }
    }
}

extension View {
    // A pane kept alive behind the one on show, so it keeps its scroll place and does not
    // have to be laid out again each time it comes back. Only the pane coming into view
    // fades; the one going out goes at once, so two panes are never drawn over each other.
    func standbyPane(shown: Bool) -> some View {
        opacity(shown ? 1 : 0)
            .transaction { if !shown { $0.animation = nil } }
    }
}
