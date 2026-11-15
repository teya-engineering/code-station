import SwiftUI

// A stepped track for how much of something to take, from the narrowest stop on the left
// to the widest on the right. The knob slides to the stop picked, and the stretch behind
// it is tinted, so the track reads as "this much" rather than as a row of separate
// choices. It is one radio group: click a stop, or move along it with the arrow keys.
struct ScopeTrack<Stop: Hashable>: View {
    let label: String
    let stops: [Stop]
    @Binding var selection: Stop
    let title: (Stop) -> String

    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var index: Int { stops.firstIndex(of: selection) ?? 0 }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(stops.enumerated()), id: \.element) { position, stop in
                stopButton(stop, at: position)
            }
        }
        .frame(height: ControlHeight.md)
        .background { track }
        .overlay { FocusRingStroke(focused: focused, cornerRadius: Radius.control) }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
        .motion(Motion.control, value: index)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .accessibilityValue(title(selection))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: _ = step(1)
            case .decrement: _ = step(-1)
            @unknown default: break
            }
        }
    }

    private func stopButton(_ stop: Stop, at position: Int) -> some View {
        let picked = position == index
        return Button {
            selection = stop
        } label: {
            Text(title(stop))
                .font(Typography.caption.weight(picked ? .semibold : .regular))
                .foregroundStyle(picked ? Theme.onFill : position < index ? Color.primary : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, Space.xs)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? [.isSelected] : [])
    }

    // The tinted stretch and the knob are shapes over the track, moved by their width and
    // offset, so nothing with AppKit inside it is ever moved.
    private var track: some View {
        GeometryReader { proxy in
            let share = proxy.size.width / CGFloat(max(stops.count, 1))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Radius.control).fill(Theme.field)
                RoundedRectangle(cornerRadius: Radius.control).fill(Theme.accent.opacity(0.12))
                    .frame(width: share * CGFloat(index + 1))
                RoundedRectangle(cornerRadius: Radius.inset).fill(Theme.accentFill)
                    .padding(Space.xxs)
                    .frame(width: share)
                    .elevation(.raised)
                    .offset(x: share * CGFloat(index))
            }
            .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Theme.border))
        }
    }

    private func step(_ by: Int) -> KeyPress.Result {
        let next = index + by
        guard stops.indices.contains(next) else { return .ignored }
        selection = stops[next]
        return .handled
    }
}
