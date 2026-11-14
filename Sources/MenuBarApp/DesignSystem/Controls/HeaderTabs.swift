import AppKit
import SwiftUI

// MARK: - Header navigation

// One place a header can send you. A destination is chosen and stays chosen, and the
// chosen one is underlined; anything that opens beside the pane rather than replacing it
// is not a tab and does not belong in the deck.
struct HeaderTab: Identifiable {
    let label: String
    let icon: String
    let selected: Bool
    // Nil leaves ordinary tabs unchanged; false keeps the content indicator slot empty.
    var hasContent: Bool?
    // One number the destination carries for itself: how much is waiting there.
    var count: Int?
    // How far the diff behind the destination has moved. It stands where the content dot
    // sits, but only while the tab is chosen: from another tab the dot says enough.
    var lineCounts: HeaderTabLineCounts?
    let activate: () -> Void

    var id: String { label }

    var showsLineCounts: Bool { selected && lineCounts != nil }
}

struct HeaderTabLineCounts: Equatable {
    let added: Int
    let removed: Int
    // A stand-in that has not been checked against the tree yet, drawn quieter until it is.
    var provisional = false

    var spokenText: String { "\(added) lines added, \(removed) removed" }

    // Exact below ten thousand, then one decimal, then none, so the tab never asks for
    // more room than six characters a side. Truncated rather than rounded, so 99,960 reads
    // as 99.9k and not as a 100.0k that is wider than the counts it stands for.
    static func short(_ count: Int) -> String {
        switch count {
        case 100_000...: "\(count / 1_000)k"
        case 10_000...: "\(count / 1_000).\(count % 1_000 / 100)k"
        default: "\(count)"
        }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        HStack(spacing: Space.xxs) {
            ForEach(tabs) { tab in
                HeaderTabDeckItem(tab: tab, height: height)
                    .id(tab.id)
                    .anchorPreference(key: HeaderTabFrames.self, value: .bounds) { [tab.id: $0] }
                    // A fade only: the item hosts AppKit views, which cannot be laid out
                    // under a scale.
                    .transition(.opacity)
            }
        }
        // The deck asks for the same width whichever tab is chosen, so the header beside
        // it never has to lay itself out again: a header that fits its rail to what is
        // left would otherwise swap to a different rail halfway through the change. A tab
        // that only shows its counts while chosen keeps their room at the end of the row
        // when it is not, where it reads as part of the gap before the rail. A scrolling
        // deck is the header's last resort, so there is nothing to swap to and the room
        // would only push a tab out of view.
        .padding(.trailing, scrollable ? 0 : roomKeptForLineCounts)
        // Tabs come and go as a session settles into its kind of work, and the row
        // closes up around them rather than jumping.
        .animation(reduceMotion ? nil : HeaderMotion.page, value: tabs.map(\.id))
        // A tab that widens to show its counts pushes its neighbours over instead of
        // making them jump.
        .animation(reduceMotion ? nil : HeaderMotion.page, value: tabs.map(\.showsLineCounts))
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

    private var roomKeptForLineCounts: CGFloat {
        tabs.reduce(0) { room, tab in
            guard let counts = tab.lineCounts, !tab.showsLineCounts else { return room }
            return room + HeaderTabDeckItem.widening(for: counts, hasContentSlot: tab.hasContent != nil)
        }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let lineCounts = tab.lineCounts {
            button.appTooltip("\(tab.label), \(lineCounts.spokenText)", isFocused: focused)
        } else if let hasContent = tab.hasContent {
            button.appTooltip(hasContent ? "\(tab.label) has content" : "Nothing in \(tab.label) yet",
                              isFocused: focused)
        } else {
            button
        }
    }

    private var button: some View {
        Button(action: tab.activate) {
            HStack(spacing: Self.labelSpacing) {
                Image(systemName: tab.icon)
                    .font(Typography.body.weight(.semibold))
                    .actOut(tab.icon, trigger: actOuts)
                    .frame(width: 17, height: 17)
                Text(tab.label)
                    .font(.system(size: Self.wordSize, weight: .semibold))
                    .fixedSize()
                    .frame(width: Self.width(of: tab.label), alignment: .leading)
                if tab.showsLineCounts, let lineCounts = tab.lineCounts {
                    lineCountsLabel(lineCounts)
                        // Gone quickly on the way out, before the tab beside it slides
                        // over the place where they were.
                        .transition(.asymmetric(
                            insertion: reduceMotion ? .opacity : .push(from: .bottom),
                            removal: .opacity.animation(Motion.leave)))
                } else if let hasContent = tab.hasContent {
                    Circle()
                        .fill(Theme.dotOnText)
                        .frame(width: Self.dotSize, height: Self.dotSize)
                        .opacity(hasContent ? 1 : 0)
                        .animation(nil, value: hasContent)
                        .padding(.leading, Self.dotSlotWidth - Self.dotSize)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
                if let count = tab.count {
                    Text(verbatim: "\(count)")
                        .font(.mono(Self.countSize, .semibold))
                        .foregroundStyle(Theme.attentionText)
                        .frame(width: Self.width(ofCounts: "\(count)"), alignment: .leading)
                }
            }
            .foregroundStyle(tab.selected || hovering ? Color.primary : Color.secondary)
            .padding(.horizontal, Space.lg)
            .frame(height: height)
            .overlay(alignment: .bottom) {
                // A faint promise of the line under a tab being pointed at. The line
                // itself belongs to the deck, which moves it from tab to tab.
                RoundedRectangle(cornerRadius: 1)
                    .fill(Theme.accent.opacity(0.18))
                    .frame(height: 2)
                    .padding(.horizontal, Space.md)
                    .scaleEffect(x: showsHint ? 1 : 0.4)
                    .opacity(showsHint ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverLift(hovering)
        .onPointerHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
        .onChange(of: tab.selected) { _, selected in
            if selected { actOuts += 1 }
        }
        .focused($focused)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(tab.selected ? [.isSelected] : [])
    }

    private var showsHint: Bool { hovering && !tab.selected }

    // Both sides always show, even at zero, so the counts keep one shape. Each side is
    // framed to its measured width, so the tab does not wobble as the digits turn over.
    private func lineCountsLabel(_ counts: HeaderTabLineCounts) -> some View {
        let added = "+" + HeaderTabLineCounts.short(counts.added)
        let removed = "\u{2212}" + HeaderTabLineCounts.short(counts.removed)
        return HStack(spacing: Self.countSpacing) {
            Text(verbatim: added)
                .foregroundStyle(Theme.addition)
                .frame(width: Self.width(ofMono: added), alignment: .leading)
            Text(verbatim: removed)
                .foregroundStyle(Theme.deletion)
                .frame(width: Self.width(ofMono: removed), alignment: .leading)
        }
        .font(.mono(Self.countSize, .semibold).monospacedDigit())
        .fixedSize()
        .contentTransition(.numericText())
        .opacity(counts.provisional ? 0.55 : 1)
        .animation(reduceMotion ? nil : HeaderMotion.page, value: counts)
        .padding(.trailing, Self.countSpacing)
        .accessibilityHidden(true)
    }

    // The counts are spoken from every tab, not only the chosen one: the dot alone says
    // less than a screen reader can.
    private var accessibilityLabel: String {
        var label = if let lineCounts = tab.lineCounts {
            "\(tab.label), \(lineCounts.spokenText)"
        } else if tab.hasContent == true {
            "\(tab.label), has content"
        } else {
            tab.label
        }
        if let count = tab.count { label += ", \(count) waiting" }
        return label
    }

    private static let wordSize: CGFloat = Typography.Size.detail
    private static let countSize: CGFloat = Typography.Size.caption
    private static let countSpacing: CGFloat = Space.xs
    private static let labelSpacing: CGFloat = Space.sm
    private static let dotSize: CGFloat = 6
    private static let dotSlotWidth: CGFloat = 7

    // The word's width read from the type and rounded to a whole point, rather than taken
    // from the word once it is on screen. A width that only settles after the label has
    // been drawn gives the deck two widths half a point apart, and the band fitting itself
    // around the deck has to choose between them: it would fit itself to one, be handed
    // the other, fit itself again, and never come to rest.
    static func width(of text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: wordSize, weight: .semibold)
        return ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width)
    }

    // The count, measured the same way and for the same reason as the word beside it.
    // How much wider the tab is with its counts than with the dot in their place.
    static func widening(for counts: HeaderTabLineCounts, hasContentSlot: Bool) -> CGFloat {
        let countsWidth = width(ofMono: "+" + HeaderTabLineCounts.short(counts.added)) + countSpacing
            + width(ofMono: "\u{2212}" + HeaderTabLineCounts.short(counts.removed)) + countSpacing
        return hasContentSlot ? countsWidth - dotSlotWidth : countsWidth + labelSpacing
    }

    private static func width(ofCounts text: String) -> CGFloat {
        width(ofMono: text) + countSpacing
    }

    private static func width(ofMono text: String) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: countSize, weight: .semibold)
        return ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width)
    }
}
