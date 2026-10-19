import AppKit
import SwiftUI
import CodeStationCore

// MARK: - Hover

// Every button, dropdown and pill answers the pointer the same way: it swells a hair on
// the shared hover curve, alongside whatever its fill already does. One gesture across
// the whole app means a control is recognised as clickable by how it moves, before its
// colour is read.
//
// A row inside a list or a menu is left out. A row that grows pushes against the rows
// above and below it, and the fill it already takes is the established way a list says
// which line the pointer is on.
extension View {
    // Takes the hover flag the control already keeps for its fill, so the colour and the
    // lift arrive together rather than on two clocks.
    func hoverLift(_ hovering: Bool, amount: CGFloat = Motion.lift) -> some View {
        modifier(HoverLift(hovering: hovering, amount: amount))
    }

    // The same lift for a control with no hover state of its own to spend.
    func hoverLift(amount: CGFloat = Motion.lift) -> some View {
        modifier(SelfTrackedHoverLift(amount: amount))
    }
}

private struct HoverLift: ViewModifier {
    let hovering: Bool
    let amount: CGFloat

    // Set by `.disabled(...)` further out, so a control that cannot be pressed stays
    // still under the pointer instead of inviting a click it will not take.
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var lifted: Bool { hovering && isEnabled && !reduceMotion }

    func body(content: Content) -> some View {
        content
            .scaleEffect(lifted ? amount : 1)
            .motion(Motion.hover, value: lifted)
    }
}

// The row's answer to the pointer, for a line in a list or a stack of choices: the
// surface warms rather than the line growing, so the rows either side of it stay put.
// A wash over the top rather than a fill behind, since most rows already draw a
// background of their own that a fill would end up hidden under.
extension View {
    func hoverFill(cornerRadius: CGFloat = 8) -> some View {
        modifier(HoverFill(cornerRadius: cornerRadius))
    }
}

private struct HoverFill: ViewModifier {
    let cornerRadius: CGFloat

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    private var lit: Bool { hovering && isEnabled }

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    // Primary rather than a fixed colour, so the wash darkens a light
                    // theme and lightens a dark one.
                    .fill(Color.primary.opacity(lit ? 0.05 : 0))
                    .allowsHitTesting(false)
            }
            .onPointerHover { hovering = $0 }
            .motion(Motion.hover, value: lit)
    }
}

private struct SelfTrackedHoverLift: ViewModifier {
    let amount: CGFloat

    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .hoverLift(hovering, amount: amount)
            .onHover { hovering = $0 }
    }
}

// Inserted content fades into its final place. Removed content leaves immediately, so it
// cannot linger over the view that replaces it while the surrounding layout changes.
extension AnyTransition {
    static var fadeIn: AnyTransition {
        .asymmetric(insertion: .opacity, removal: .identity)
    }

    // For content that closes onto nothing rather than onto the view that replaces it: it
    // fades as the frame around it shrinks, so the close is seen out instead of cut.
    static var fold: AnyTransition { .opacity }
}

extension View {
    // Supplies the animation transaction that lets conditional content change the layout
    // around it. Keeping this shared makes cards, dialogs and menus resize at one pace.
    func smoothlyResizes<Value: Equatable>(when value: Value) -> some View {
        modifier(SmoothResizeModifier(value: value))
    }
}

private struct SmoothResizeModifier<Value: Equatable>: ViewModifier {
    let value: Value

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: value)
    }
}
