import AppKit
import SwiftUI

// Segmented choices used in pane headers. Keeping the control shared means project and
// session navigation have the same hit areas, spacing and selected state.
struct HeaderTabToggle<Selection: Hashable>: View {
    @Binding var selection: Selection
    let options: [(label: String, value: Selection)]

    // Ties the selected pill to whichever segment holds it, so picking another one moves
    // the same shape across instead of hiding it here and showing a new one there.
    @Namespace private var pill

    var body: some View {
        HStack(spacing: Space.xxs) {
            ForEach(options.indices, id: \.self) { index in
                segment(options[index])
            }
        }
        .padding(Space.xxs)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(Theme.field))
        // A header row hands out its width between its children, so without this the
        // control is offered less than its labels need and every one of them wraps onto
        // two lines. It is a fixed set of short words: it should hold its size and let
        // the title beside it give way instead.
        .fixedSize(horizontal: true, vertical: false)
        .motion(Motion.control, value: selection)
    }

    private func segment(_ option: (label: String, value: Selection)) -> some View {
        HeaderTabSegment(label: option.label,
                         active: selection == option.value,
                         pill: pill) { selection = option.value }
    }
}

private struct HeaderTabSegment: View {
    let label: String
    let active: Bool
    let pill: Namespace.ID
    let choose: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            Text(label)
                .font(Typography.label)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(active || hovering ? Color.primary : Color.secondary)
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.xs)
                .background {
                    if active {
                        RoundedRectangle(cornerRadius: Radius.control)
                            .fill(Theme.card)
                            .elevation(.raised)
                            .matchedGeometryEffect(id: "selected", in: pill)
                    } else if hovering {
                        // The seat the chosen segment wears, at a fraction of its weight,
                        // so pointing at one reads as a preview of picking it.
                        RoundedRectangle(cornerRadius: Radius.control).fill(Theme.card.opacity(0.5))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverLift(hovering)
        .onPointerHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
    }
}

// The app's own switch and checkbox. The native toggle styles draw with the system's
// chrome and accent, which reads as a piece of another program next to the rest of
// the app, so everything interactive is drawn here with the shared palette instead.
