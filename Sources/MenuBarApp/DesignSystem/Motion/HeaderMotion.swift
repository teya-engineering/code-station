import SwiftUI

// How the session header moves. Every tab change and every panel shows where it came
// from: the underline stretches to the new tab before it lets go of the old one, the page
// lifts in under it, and a panel lifts into place by the button that opened it. Under
// Reduce Motion all of it is a fade.
enum HeaderMotion {
    // The underline's two legs: reaching over to the new tab, then letting go of the old
    // one. Together they run just under half a second, slow in, fast across, soft out.
    static let stretch = Animation.timingCurve(0.45, 0, 0.7, 0.6, duration: 0.21)
    static let release = Animation.timingCurve(0.2, 0.5, 0.2, 1, duration: 0.25)
    static let page = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.28)
    // Something growing in place overshoots by a hair, so it reads as thrown rather than
    // set down.
    static let grow = Animation.timingCurve(0.2, 0.9, 0.3, 1.12, duration: 0.34)
    static let shrink = Animation.timingCurve(0.4, 0, 0.6, 1, duration: 0.2)
    // Panels that come in from a window edge travel further, so they take longer.
    static let rise = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.42)
    static let slide = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.4)
    static let sink = Animation.timingCurve(0.4, 0, 0.8, 0.6, duration: 0.24)

    static let pageLift: CGFloat = 8
    static let popoverLift: CGFloat = 4
    // The share of its size a short run of words grows from. Small enough to read as
    // growing, and never zero, since a singular scale is a NaN waiting to happen in AppKit
    // layout.
    static let seed: CGFloat = 0.55
}

extension AnyTransition {
    // A new page lifts into place under the tab that chose it. The page it replaces goes
    // at once, so two heavy panes are never drawn over each other.
    static func headerPage(reduceMotion: Bool) -> AnyTransition {
        let insertion: AnyTransition = reduceMotion
            ? .opacity.animation(Motion.reveal)
            : .opacity.combined(with: .offset(y: HeaderMotion.pageLift)).animation(HeaderMotion.page)
        return .asymmetric(insertion: insertion, removal: .identity)
    }

    // A panel opened from a button fades in and lifts the last few points into place, in
    // one movement. It is never scaled or masked: panels hold buttons with tooltips, which
    // are AppKit views that cannot be laid out under a scale.
    static func popover(reduceMotion: Bool) -> AnyTransition {
        let insertion: AnyTransition = reduceMotion
            ? .opacity.animation(Motion.reveal)
            : .opacity.combined(with: .offset(y: HeaderMotion.popoverLift)).animation(Motion.reveal)
        return .asymmetric(insertion: insertion, removal: .opacity.animation(Motion.leave))
    }

    // A drawer that comes in from one edge of the window and goes back out of it.
    static func drawer(from edge: Edge, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity.animation(Motion.reveal) }
        let arriving = edge == .bottom ? HeaderMotion.rise : HeaderMotion.slide
        return .asymmetric(insertion: .move(edge: edge).animation(arriving),
                           removal: .move(edge: edge).animation(HeaderMotion.sink))
    }
}

extension View {
    // Keeps track of where a button's centre is in the window, so a panel can point back
    // at it.
    func onCentreChange(_ action: @escaping (CGPoint) -> Void) -> some View {
        onGeometryChange(for: CGPoint.self) { proxy in
            let frame = proxy.frame(in: .global)
            return CGPoint(x: frame.midX, y: frame.midY)
        } action: { action($0) }
    }
}

// MARK: - Acting out

// A glyph plays its part once when what it stands for is chosen: the brush makes a
// stroke, the counts turn over, the rest give a small hop. It moves only the drawing of
// the symbol, never the button around it.
struct ActOut: ViewModifier {
    let icon: String
    let trigger: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else if icon.hasPrefix("paintbrush") || icon.hasPrefix("magnifyingglass") {
            content.symbolEffect(.wiggle, options: .nonRepeating, value: trigger)
        } else if icon == "plusminus" {
            content.symbolEffect(.rotate, options: .nonRepeating, value: trigger)
        } else {
            content.symbolEffect(.bounce, options: .nonRepeating, value: trigger)
        }
    }
}

extension View {
    func actOut(_ icon: String, trigger: Int) -> some View {
        modifier(ActOut(icon: icon, trigger: trigger))
    }
}

// MARK: - Notes

// A short line that drops from a button whose action happens outside the window, such as
// opening Finder. Nothing in the window moves, so without it the click leaves no trace.
struct HeaderNote: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: icon)
                .font(Typography.caption.weight(.semibold))
                .foregroundStyle(Theme.brand)
            Text(text)
                .font(Typography.detail.weight(.medium))
                .foregroundStyle(Theme.terminalText)
        }
        .padding(.horizontal, Space.lg)
        .frame(height: 32)
        .background(Theme.terminal, in: RoundedRectangle(cornerRadius: Radius.card))
        .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
        .fixedSize()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
