import SwiftUI

// A small mark carried from one place in a view to another, such as a project tile
// flying into the workspace it was dropped on. Both frames are in the coordinate space
// of the layer the flight is drawn in.
struct Flight: Identifiable, Equatable {
    let id = UUID()
    let from: CGRect
    let to: CGRect
    var duration: TimeInterval = Motion.flightDuration
}

// Draws one flight and says when it has landed. The flying view must be plain SwiftUI:
// it is scaled on the way, and AppKit-backed parts cannot be laid out under a scale.
// Under Reduce Motion nothing travels: the flight lands at once and is never drawn.
struct FlightView<Content: View>: View {
    let flight: Flight
    let onLanded: () -> Void
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var across = false
    @State private var down = false

    var body: some View {
        let scale = flight.from.width > 0 ? flight.to.width / flight.from.width : 1
        content
            .frame(width: flight.from.width, height: flight.from.height)
            .scaleEffect(down ? max(scale, 0.1) : 1)
            .position(x: flight.from.midX, y: flight.from.midY)
            // Two offsets, each on its own curve, so across and down keep separate timing.
            .offset(x: across ? flight.to.midX - flight.from.midX : 0)
            .offset(y: down ? flight.to.midY - flight.from.midY : 0)
            .opacity(reduceMotion ? 0 : 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return onLanded() }
                withAnimation(Motion.flightAcross(flight.duration)) { across = true }
                withAnimation(Motion.flightDown(flight.duration)) {
                    down = true
                } completion: {
                    onLanded()
                }
            }
    }
}

// Two rings spreading out from a mark that has just landed, in the mark's colour, the
// second a beat after the first. Each new value of `trigger` plays them once; nil plays
// nothing. They take no room and no clicks, and are left out under Reduce Motion.
struct LandingRings: ViewModifier {
    let trigger: Int?
    let colour: Color
    let cornerRadius: CGFloat
    // How many times its own size a ring grows before it is gone.
    var reach: CGFloat = 3.1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            if let trigger, !reduceMotion {
                ZStack {
                    Ring(colour: colour, cornerRadius: cornerRadius, reach: reach, delay: 0)
                    Ring(colour: colour, cornerRadius: cornerRadius, reach: reach, delay: Motion.ringGap)
                }
                .id(trigger)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }

    private struct Ring: View {
        let colour: Color
        let cornerRadius: CGFloat
        let reach: CGFloat
        let delay: TimeInterval

        @State private var spread = false

        var body: some View {
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(colour, lineWidth: 1.5)
                .scaleEffect(spread ? reach : 1)
                .opacity(spread ? 0 : 0.9)
                .onAppear { withAnimation(Motion.ring.delay(delay)) { spread = true } }
        }
    }
}

extension View {
    func landingRings(_ trigger: Int?, colour: Color, cornerRadius: CGFloat,
                      reach: CGFloat = 3.1) -> some View {
        modifier(LandingRings(trigger: trigger, colour: colour, cornerRadius: cornerRadius, reach: reach))
    }
}
