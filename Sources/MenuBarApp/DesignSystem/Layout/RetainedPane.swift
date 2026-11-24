import SwiftUI

// Keep the page and its viewport alive while another pane takes its room. Giving a
// scroll view a zero-sized viewport would move its reading position even without a rebuild.
struct RetainedPane<Content: View>: View {
    let hidden: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        RetainedPaneLayout(hidden: hidden) {
            VStack(spacing: 0, content: content)
        }
        .clipped()
        .opacity(hidden ? 0 : 1)
        .disabled(hidden)
        .allowsHitTesting(!hidden)
        .accessibilityHidden(hidden)
        .motion(hidden ? Motion.leave : Motion.reveal, value: hidden)
    }
}

private struct RetainedPaneLayout: Layout {
    let hidden: Bool

    struct Cache {
        var size: CGSize?
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) {}

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard let content = subviews.first else { return .zero }
        if hidden { return CGSize(width: proposal.width ?? cache.size?.width ?? 0, height: 0) }
        return content.sizeThatFits(proposal)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        if !hidden { cache.size = bounds.size }
        let size = cache.size ?? bounds.size
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(size))
    }
}
