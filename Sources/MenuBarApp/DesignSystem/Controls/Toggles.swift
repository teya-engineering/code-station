import SwiftUI

// A switch trails its label, the way a row of settings expects.
//
// A style cannot hold state of its own, so the drawing lives in a view below it. That is
// what lets the whole row, label included, be the thing the pointer is tested against
// while only the switch answers.

struct AppSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        AppSwitch(configuration: configuration)
    }
}

private struct AppSwitch: View {
    let configuration: ToggleStyleConfiguration

    private static let trackWidth: CGFloat = 34
    private static let trackHeight: CGFloat = 20
    private static let knob: CGFloat = 16
    private static let inset: CGFloat = 2
    private static var travel: CGFloat { trackWidth - knob - inset * 2 }

    @State private var hovering = false

    var body: some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: Space.lg) {
                configuration.label
                Capsule()
                    .fill(configuration.isOn ? Theme.accentFill : Theme.dotOff)
                    .frame(width: Self.trackWidth, height: Self.trackHeight)
                    .overlay(alignment: .leading) {
                        // The knob is given its own size and slid along the track. A shape
                        // in an overlay otherwise takes the whole track and draws itself in
                        // the middle of it, whichever end the switch is aligned to.
                        Circle()
                            .fill(.white)
                            .frame(width: Self.knob, height: Self.knob)
                            .elevation(.raised)
                            .offset(x: Self.inset + (configuration.isOn ? Self.travel : 0))
                    }
                    // Only the switch lifts. A label that grew with it would drag the
                    // sentence beside it around every time the pointer crossed the row.
                    .hoverLift(hovering, amount: Motion.smallLift)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onPointerHover { hovering = $0 }
        .motion(Motion.control, value: configuration.isOn)
    }
}

// A checkbox leads its label, the way a tickable line expects.
struct AppCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        AppCheckbox(configuration: configuration)
    }
}

private struct AppCheckbox: View {
    let configuration: ToggleStyleConfiguration

    @State private var hovering = false

    var body: some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .top, spacing: Space.md) {
                CheckboxMark(isOn: configuration.isOn)
                    .hoverLift(hovering, amount: Motion.smallLift)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onPointerHover { hovering = $0 }
        .motion(Motion.control, value: configuration.isOn)
    }
}

// The box alone, for a row that is itself the thing being ticked and has no toggle of
// its own to put it in. A box heading a list can be mixed, when only some of the list is
// ticked: it fills like a ticked one and carries a dash instead of the tick.
struct CheckboxMark: View {
    let isOn: Bool
    var mixed = false

    private var filled: Bool { isOn || mixed }

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.inset)
            .fill(filled ? Theme.accentFill : Theme.card)
            .frame(width: 16, height: 16)
            .overlay(RoundedRectangle(cornerRadius: Radius.inset)
                .stroke(filled ? .clear : Theme.border, lineWidth: 1.5))
            .overlay {
                // The tick is always there and grows into the filled box, so ticking a
                // line is one movement rather than a mark appearing on top of a box that
                // has already changed colour.
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .scaleEffect(isOn && !mixed ? 1 : 0.4)
                    .opacity(isOn && !mixed ? 1 : 0)
            }
            .overlay {
                Capsule()
                    .fill(.white)
                    .frame(width: mixed ? 8 : 3, height: 2)
                    .opacity(mixed ? 1 : 0)
            }
    }
}

extension ToggleStyle where Self == AppSwitchStyle {
    static var appSwitch: AppSwitchStyle { AppSwitchStyle() }
}

extension ToggleStyle where Self == AppCheckboxStyle {
    static var appCheckbox: AppCheckboxStyle { AppCheckboxStyle() }
}
