import AppKit
import SwiftUI
import CodeStationCore

// MARK: - Header navigation

// One place a header can send you. A destination is chosen and stays chosen, and the
// chosen one is underlined; anything that opens beside the pane rather than replacing it
// is not a tab and does not belong in the deck.
struct HeaderTab: Identifiable {
    let label: String
    let icon: String
    let selected: Bool
    // Counts the destination carries for itself. They sit on the tab that opens them,
    // where they say what has changed rather than only that something has.
    var diff: Diff?
    // Nil leaves ordinary tabs unchanged; false keeps the content indicator slot empty.
    var hasContent: Bool?
    let activate: () -> Void

    var id: String { label }

    struct Diff: Equatable {
        let added: Int
        let removed: Int
    }
}

// The header's destinations, each with its word beside its icon and a line under the one
// you are on. Every word is drawn all the time: a destination that only names itself when
// pointed at cannot be read by someone who is not pointing, and the deck is the one place
// in the pane where knowing where you are going is the whole job.
//
// The deck holds destinations and nothing else, so its edge is the line between swapping
// the pane and opening something next to it.
struct HeaderTabDeck: View {
    let tabs: [HeaderTab]
    // The deck stands the full height of the band it is on, so the underline of the
    // chosen tab lands on the band's own bottom edge rather than floating above it.
    var height: CGFloat = 40
    var scrollable = false
    @State private var scrolledTabID: HeaderTab.ID?

    var body: some View {
        if scrollable {
            ScrollView(.horizontal, showsIndicators: false) {
                items
            }
            .scrollPosition(id: $scrolledTabID, anchor: .center)
            .frame(height: height)
            .background {
                GeometryReader { geometry in
                    Color.clear.task(id: geometry.size.width) {
                        // An unchanged target can keep its old offset after a resize.
                        // Reapply it once the viewport has its new width.
                        scrolledTabID = nil
                        await Task.yield()
                        scrolledTabID = tabs.first(where: \.selected)?.id
                    }
                }
            }
            .onChange(of: tabs.first(where: \.selected)?.id, initial: true) { _, selected in
                scrolledTabID = selected
            }
        } else {
            items
        }
    }

    private var items: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                HeaderTabDeckItem(tab: tab, height: height)
                    .id(tab.id)
                    .anchorPreference(key: HeaderTabFrames.self, value: .bounds) { [tab.id: $0] }
            }
        }
        // Drawn over the row rather than inside a tab, so there is one line that travels
        // between tabs instead of one line per tab that comes and goes, and choosing a
        // tab still changes nothing the deck asks for in width.
        .overlayPreferenceValue(HeaderTabFrames.self) { anchors in
            GeometryReader { proxy in
                HeaderTabInk(frames: anchors.mapValues { proxy[$0] },
                             selected: tabs.first(where: \.selected)?.id)
            }
        }
        .scrollTargetLayout(isEnabled: scrollable)
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct HeaderTabFrames: PreferenceKey {
    static let defaultValue: [HeaderTab.ID: Anchor<CGRect>] = [:]

    static func reduce(value: inout [HeaderTab.ID: Anchor<CGRect>],
                       nextValue: () -> [HeaderTab.ID: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

// The line under the chosen tab. On a new choice it first stretches to cover both tabs,
// thickening a little as it goes, and only then lets go of the old one, so the eye is
// carried from where it was to where it is going rather than asked to find the line again.
private struct HeaderTabInk: View {
    let frames: [HeaderTab.ID: CGRect]
    let selected: HeaderTab.ID?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var span: ClosedRange<CGFloat>?
    @State private var thickness: CGFloat = Self.restingThickness
    @State private var move = 0

    private static let restingThickness: CGFloat = 2
    private static let stretchedThickness: CGFloat = 3
    // The line sits a little inside the tab, so neighbouring tabs' lines never touch.
    private static let inset: CGFloat = 2

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let span {
                RoundedRectangle(cornerRadius: thickness / 2)
                    .fill(Theme.accent)
                    .frame(width: span.upperBound - span.lowerBound, height: thickness)
                    .offset(x: span.lowerBound)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: selected, initial: true) { previous, current in
            travel(from: previous, to: current)
        }
        // A tab that changes width - counts arriving, a window resize - takes the line
        // with it at once. Only a new choice is animated.
        .onChange(of: target) { _, target in
            guard let target, thickness == Self.restingThickness else { return }
            span = target
        }
    }

    private var target: ClosedRange<CGFloat>? {
        selected.flatMap { frames[$0] }.map(Self.span(under:))
    }

    private static func span(under frame: CGRect) -> ClosedRange<CGFloat> {
        (frame.minX + inset)...max(frame.minX + inset, frame.maxX - inset)
    }

    private func travel(from previous: HeaderTab.ID?, to current: HeaderTab.ID?) {
        move += 1
        guard let target else {
            span = nil
            return
        }
        guard !reduceMotion, let previous, previous != current, let start = span,
              frames[previous] != nil else {
            span = target
            return
        }
        let reach = min(start.lowerBound, target.lowerBound)...max(start.upperBound, target.upperBound)
        let thisMove = move
        withAnimation(HeaderMotion.stretch) {
            span = reach
            thickness = Self.stretchedThickness
        } completion: {
            // A later click has already sent the line somewhere else.
            guard thisMove == move else { return }
            withAnimation(HeaderMotion.release) {
                span = self.target ?? target
                thickness = Self.restingThickness
            }
        }
    }
}

private struct HeaderTabDeckItem: View {
    let tab: HeaderTab
    let height: CGFloat

    @State private var hovering = false
    @State private var actOuts = 0
    @FocusState private var focused: Bool

    var body: some View {
        if let hasContent = tab.hasContent {
            button.appTooltip(hasContent ? "\(tab.label) has content" : "No design content",
                              isFocused: focused)
        } else {
            button
        }
    }

    private var button: some View {
        Button(action: tab.activate) {
            HStack(spacing: 7) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .actOut(tab.icon, trigger: actOuts)
                    .frame(width: 17, height: 17)
                Text(tab.label)
                    .font(.system(size: Self.wordSize, weight: .semibold))
                    .fixedSize()
                    .frame(width: Self.width(of: tab.label), alignment: .leading)
                if let hasContent = tab.hasContent {
                    Circle()
                        .fill(Theme.dotOnText)
                        .frame(width: 6, height: 6)
                        .opacity(hasContent ? 1 : 0)
                        .padding(.leading, 1)
                        .accessibilityHidden(true)
                        .transaction { $0.animation = nil }
                }
                if let diff = tab.diff {
                    DiffPair(added: diff.added, removed: diff.removed,
                             size: Self.countSize, spacing: Self.countSpacing)
                        .frame(width: Self.width(of: diff), alignment: .leading)
                }
            }
            .foregroundStyle(tab.selected || hovering ? Color.primary : Color.secondary)
            .padding(.horizontal, 11)
            .frame(height: height)
            .overlay(alignment: .bottom) {
                // A faint promise of the line under a tab being pointed at. The line
                // itself belongs to the deck, which moves it from tab to tab.
                RoundedRectangle(cornerRadius: 1)
                    .fill(Theme.accent.opacity(0.18))
                    .frame(height: 2)
                    .padding(.horizontal, 8)
                    .scaleEffect(x: showsHint ? 1 : 0.4)
                    .opacity(showsHint ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverLift(hovering)
        .onHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
        .onChange(of: tab.selected) { _, selected in
            if selected { actOuts += 1 }
        }
        .focused($focused)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(tab.selected ? [.isSelected] : [])
    }

    private var showsHint: Bool { hovering && !tab.selected }

    // The counts are read out with the destination rather than left as two numbers beside
    // it, so the tab says the same thing whether it is seen or heard.
    private var accessibilityLabel: String {
        let label = tab.hasContent == true ? "\(tab.label), has content" : tab.label
        guard let diff = tab.diff else { return label }
        return "\(label), \(diff.added) added, \(diff.removed) removed"
    }

    private static let wordSize: CGFloat = 12.5
    private static let countSize: CGFloat = 10.5
    private static let countSpacing: CGFloat = 5

    // The word's width read from the type and rounded to a whole point, rather than taken
    // from the word once it is on screen. A width that only settles after the label has
    // been drawn gives the deck two widths half a point apart, and the band fitting itself
    // around the deck has to choose between them: it would fit itself to one, be handed
    // the other, fit itself again, and never come to rest.
    static func width(of text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: wordSize, weight: .semibold)
        return ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width)
    }

    // The counts, measured the same way and for the same reason as the word beside them.
    static func width(of diff: HeaderTab.Diff) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: countSize, weight: .semibold)
        let counts = "+\(diff.added)−\(diff.removed)"
        let width = NSAttributedString(string: counts, attributes: [.font: font]).size().width
        return ceil(width + countSpacing)
    }
}
