import SwiftUI

// A row that arrives with the rows around it, each a step after the one before, so a
// list that opens reads top to bottom instead of landing as one block. The count stops
// at `limit`, so the last row of a long list is not kept waiting. Under Reduce Motion
// the row is simply there.
private struct ArrivesInTurn: ViewModifier {
    static var limit: Int { 8 }

    let index: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived = false

    func body(content: Content) -> some View {
        let shown = arrived || reduceMotion
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : Space.xs)
            .onAppear {
                guard !arrived else { return }
                let wait = Motion.stagger * Double(min(index, Self.limit) + 1)
                withAnimation(Motion.reveal.delay(wait)) { arrived = true }
            }
    }
}

// A wash of colour behind a reading that has just changed, fading off on
// `Motion.washDuration`, so the eye finds what moved. Nothing plays when the reading
// first appears, and nothing plays under Reduce Motion.
private struct ReadingWash<Value: Equatable>: ViewModifier {
    let value: Value
    let colour: Color
    let strength: Double
    let cornerRadius: CGFloat
    let outset: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.background {
            if !reduceMotion {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(colour)
                    .padding(-outset)
                    .keyframeAnimator(initialValue: 0.0, trigger: value) { wash, level in
                        wash.opacity(level)
                    } keyframes: { _ in
                        MoveKeyframe(strength)
                        CubicKeyframe(0, duration: Motion.washDuration)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    func arrivesInTurn(_ index: Int) -> some View {
        modifier(ArrivesInTurn(index: index))
    }

    func washes<Value: Equatable>(on value: Value, colour: Color = Theme.brand, strength: Double = 0.6,
                                  cornerRadius: CGFloat = Radius.tag,
                                  outset: CGFloat = Space.xxs) -> some View {
        modifier(ReadingWash(value: value, colour: colour, strength: strength,
                             cornerRadius: cornerRadius, outset: outset))
    }
}
