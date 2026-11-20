import SwiftUI

extension View {
    // For a ScrollView that sits inside a taller page, such as a card in the transcript.
    // It grows with its content up to the cap, then scrolls.
    //
    // A capped ScrollView also shrinks when its parent offers less room. In a page that is
    // itself one long stack in a scroll view, that makes the page measure shorter than it
    // draws, and its end can no longer be scrolled into view. Fixing the vertical size
    // keeps the block at its own height whatever it is offered.
    func scrollCap(_ height: CGFloat) -> some View {
        modifier(ScrollCapModifier(height: height))
    }
}

private struct ScrollCapModifier: ViewModifier {
    @Environment(\.textScale) private var textScale

    let height: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(maxHeight: height * textScale)
            .fixedSize(horizontal: false, vertical: true)
    }
}
