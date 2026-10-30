import SwiftUI

// A value picked along a line. The track can carry a gradient showing what the ends mean,
// such as the colour of the light a warmth slider chooses. The thumb grows a little under
// the pointer, in place: it is positioned by an offset, and a scale would turn about the
// spot it was laid out at and slide it along. The arrow keys walk it when it has focus.
// `onEditingChanged` reports while the pointer holds it, for anything that wants to
// preview the value as it is chosen.
struct AppSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var track: AnyShapeStyle = AnyShapeStyle(Theme.accent)
    var label: String
    var readout: (Double) -> String = { $0.formatted() }
    var onEditingChanged: (Bool) -> Void = { _ in }

    private static let thumb: CGFloat = 16
    private static let grownThumb: CGFloat = 20
    private static let trackHeight: CGFloat = 6

    @State private var hovering = false
    @State private var dragging = false
    @FocusState private var focused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var grown: Bool { (hovering || dragging) && !reduceMotion }

    private var fraction: Double {
        (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    var body: some View {
        GeometryReader { geometry in
            let travel = max(0, geometry.size.width - Self.thumb)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.field).frame(height: Self.trackHeight)
                Capsule().fill(track)
                    .frame(width: Self.thumb / 2 + travel * fraction, height: Self.trackHeight)
                // The grown circle sits centred in a slot of the resting size, so growing
                // never moves the point it marks.
                Circle()
                    .fill(Theme.card)
                    .overlay(Circle().stroke(focused || dragging ? Theme.accent : Theme.settingsBorder,
                                             lineWidth: focused ? 2 : 1))
                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                    .frame(width: grown ? Self.grownThumb : Self.thumb,
                           height: grown ? Self.grownThumb : Self.thumb)
                    .frame(width: Self.thumb, height: Self.thumb)
                    .offset(x: travel * fraction)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if !dragging {
                        dragging = true
                        onEditingChanged(true)
                    }
                    let fraction = min(1, max(0, (drag.location.x - Self.thumb / 2) / max(1, travel)))
                    set(range.lowerBound + fraction * (range.upperBound - range.lowerBound))
                }
                .onEnded { _ in
                    dragging = false
                    onEditingChanged(false)
                })
        }
        .frame(height: 24)
        .onPointerHover { hovering = $0 }
        .motion(Motion.hover, value: grown)
        .motion(Motion.control, value: focused)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            if direction == .right || direction == .up { set(value + step) }
            if direction == .left || direction == .down { set(value - step) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(readout(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: set(value + step)
            case .decrement: set(value - step)
            @unknown default: break
            }
        }
    }

    private func set(_ raw: Double) {
        let stepped = (raw / step).rounded() * step
        value = min(range.upperBound, max(range.lowerBound, stepped))
    }
}
