import SwiftUI

// A whole change in one strip: a slice per file, as wide as its lines changed, green over
// red in the share it added and removed. Groups such as folders sit apart by a wider gap,
// and a group wide enough is named under its span. Hovering a slice names it, clicking
// opens it, and a focus passed in lights one group or one slice and dims the rest.
//
// It is a picture of a list drawn beside it, so it is one image to assistive tech and
// not a tab stop: the list carries the same facts and is the way in by keyboard.
struct ChangeMap: View {
    struct Slice: Identifiable, Equatable {
        let id: String
        let title: String
        let added: Int
        let removed: Int

        var lines: Int { added + removed }
    }

    struct Group: Identifiable, Equatable {
        let id: String
        let label: String
        let slices: [Slice]
    }

    struct Focus: Equatable {
        var group: Group.ID
        var slice: Slice.ID? = nil
    }

    struct Placed: Equatable {
        let slice: Slice
        let group: Group.ID
        let x: CGFloat
        let width: CGFloat
    }

    struct Span: Equatable {
        let group: Group
        let x: CGFloat
        let width: CGFloat
    }

    static let height: CGFloat = Space.lg
    static let sliceGap: CGFloat = 1
    static let groupGap: CGFloat = Space.xs
    static let minimumSlice: CGFloat = Space.xxs
    // A group narrower than this has no room for a name under it.
    static let labelledWidth: CGFloat = Space.xxxl * 2 + Space.md

    let groups: [Group]
    var focus: Focus? = nil
    var accessibilityText = "Lines changed by file"
    var hover: (Focus?) -> Void = { _ in }
    var open: (Slice) -> Void = { _ in }

    @State private var width: CGFloat = 0
    @State private var hovered: Placed?
    @State private var hintWidth: CGFloat = 0
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Every slice gets the smallest width it can be seen at, then the room left over is
    // shared by lines changed.
    static func layout(_ groups: [Group], width: CGFloat) -> (slices: [Placed], spans: [Span]) {
        let groups = groups.filter { !$0.slices.isEmpty }
        let count = groups.reduce(0) { $0 + $1.slices.count }
        guard count > 0, width > 0 else { return ([], []) }
        let gaps = CGFloat(groups.count - 1) * groupGap + CGFloat(count - groups.count) * sliceGap
        let free = max(0, width - gaps - CGFloat(count) * minimumSlice)
        let total = CGFloat(max(groups.reduce(0) { $0 + $1.slices.reduce(0) { $0 + $1.lines } }, 1))
        var slices: [Placed] = []
        var spans: [Span] = []
        var x: CGFloat = 0
        for group in groups {
            let start = x
            for (index, slice) in group.slices.enumerated() {
                if index > 0 { x += sliceGap }
                let width = minimumSlice + free * CGFloat(slice.lines) / total
                slices.append(Placed(slice: slice, group: group.id, x: x, width: width))
                x += width
            }
            spans.append(Span(group: group, x: start, width: x - start))
            x += groupGap
        }
        return (slices, spans)
    }

    var body: some View {
        let layout = Self.layout(groups, width: width)
        VStack(alignment: .leading, spacing: Space.xxs) {
            strip(layout.slices)
            labels(layout.spans)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .overlay(alignment: .topLeading) { hint.motion(Motion.reveal, value: hovered?.slice.id) }
        .onAppear { drawn = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isImage)
    }

    private func strip(_ slices: [Placed]) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(slices, id: \.slice.id) { placed in
                slice(placed)
                    .frame(width: placed.width, height: Self.height)
                    .offset(x: placed.x)
                    .opacity(opacity(placed))
            }
        }
        .frame(width: width, height: Self.height, alignment: .topLeading)
        // Drawn left to right by a window that widens over the slices, since slices must
        // not be scaled.
        .frame(width: drawn ? width : 0, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: Radius.tag / 2))
        .frame(maxWidth: .infinity, alignment: .leading)
        .motion(Motion.draw, value: drawn)
        .motion(Motion.reveal, value: focus)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            let now: Placed? = switch phase {
            case .active(let point): slices.first { point.x < $0.x + $0.width + Self.sliceGap }
            case .ended: nil
            }
            guard now != hovered else { return }
            hovered = now
            hover(now.map { Focus(group: $0.group, slice: $0.slice.id) })
        }
        .onTapGesture { if let hovered { open(hovered.slice) } }
    }

    private func slice(_ placed: Placed) -> some View {
        let slice = placed.slice
        return VStack(spacing: 0) {
            if slice.lines == 0 {
                Rectangle().fill(Theme.border)
            } else {
                Rectangle().fill(Theme.addition)
                    .frame(height: Self.height * CGFloat(slice.added) / CGFloat(slice.lines))
                Rectangle().fill(Theme.deletion)
            }
        }
    }

    private func opacity(_ placed: Placed) -> Double {
        guard let focus else { return 1 }
        guard placed.group == focus.group else { return 0.25 }
        guard let slice = focus.slice else { return 1 }
        return placed.slice.id == slice ? 1 : 0.55
    }

    private func labels(_ spans: [Span]) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(spans.filter { $0.width >= Self.labelledWidth }, id: \.group.id) { span in
                Text(span.group.label)
                    .font(Typography.caption)
                    .foregroundStyle(focus?.group == span.group.id ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: span.width, alignment: .leading)
                    .offset(x: span.x)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .motion(Motion.reveal, value: focus)
    }

    // The hovered slice's name and counts, hung above it and held inside the strip.
    @ViewBuilder private var hint: some View {
        if let hovered {
            HStack(spacing: Space.sm) {
                // Room is kept for the counts, so a long path gives up its start instead.
                Text(hovered.slice.title).font(Typography.data).lineLimit(1).truncationMode(.head)
                    .frame(maxWidth: max(0, width - Space.xxxl * 4), alignment: .leading)
                DiffPair(added: hovered.slice.added, removed: hovered.slice.removed, size: Typography.Size.micro)
                    .fixedSize()
            }
            .padding(.horizontal, Space.sm)
            .frame(height: ControlHeight.xs)
            .floatingCard(cornerRadius: Radius.inset)
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { hintWidth = $0 }
            .offset(x: min(max(0, hovered.x + hovered.width / 2 - hintWidth / 2), max(0, width - hintWidth)),
                    y: -(ControlHeight.xs + Space.xs))
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityHidden(true)
        }
    }
}
