import AppKit
import SwiftUI

// MARK: - Structure

// The label over a section: mono capitals, a hairline taking the rest of the width, and
// whatever the section wants to say or offer on the right.
struct SectionRule<Trailing: View>: View {
    let title: String
    var dot: Color? = nil
    // A section about work in flight breathes with it, the same way its rows do.
    var pulses = false
    var tint: Color? = nil
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: Space.md) {
            if pulses {
                RunningDot()
            } else if let dot {
                Circle().fill(dot).frame(width: 6, height: 6)
            }
            Text(title)
                .font(Typography.caps)
                .kerning(1.3)
                .foregroundStyle(tint ?? Color.secondary)
                .fixedSize()
            Rectangle().fill(Theme.border).frame(height: 1)
            trailing
        }
    }
}

extension SectionRule where Trailing == EmptyView {
    init(_ title: String, dot: Color? = nil, pulses: Bool = false, tint: Color? = nil) {
        self.init(title: title, dot: dot, pulses: pulses, tint: tint) { EmptyView() }
    }
}

// The label over a block of a form. A section, like COMMAND or ENVIRONMENT VARIABLES,
// is led by a dot, which is the only thing separating it from the last one in a plain
// scroll. A field label is smaller and quieter, since the field under it is the point.
struct SectionLabel: View {
    enum Style { case section, field }

    let text: String
    var style: Style = .section
    var tint: Color?

    init(_ text: String, style: Style = .section, tint: Color? = nil) {
        self.text = text
        self.style = style
        self.tint = tint
    }

    var body: some View {
        switch style {
        case .section:
            HStack(spacing: Space.sm) {
                RunningDot(size: 5)
                Text(text)
                    .font(Typography.label)
                    .kerning(0.6)
                    .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
            }
        case .field:
            Text(text)
                .font(Typography.caps)
                .kerning(0.6)
                .foregroundStyle(.tertiary)
        }
    }
}

// The strip that closes a screen: what the defaults are, or what has gone stale, and the
// one link that leads to the screen where it can be changed.
struct FooterStrip<Trailing: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: Space.lg) {
            Text(title)
                .font(Typography.body.weight(.semibold))
                .fixedSize()
            Text(detail)
                .font(Typography.data)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.lg)
        .background(RoundedRectangle(cornerRadius: Radius.floating).fill(Theme.sunken))
    }
}

// Sizes a scroll view to what it holds. A scroll view grows to fill all the height it is
// offered, so a short list in one would leave a gap below its last row. This asks the
// content for the height it needs and takes that, up to the limit or the room offered,
// whichever is smaller, and only then does the content scroll.
struct HuggingHeight: Layout {
    var limit: CGFloat = .infinity

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let ideal = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        let height = min(ideal.height, limit, proposal.height ?? .infinity)
        return CGSize(width: proposal.width ?? ideal.width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        subviews.first?.place(at: bounds.origin,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

// A label and a flexible field share a row, or stack when the field needs the room.
// A single child keeps the field's inset without leaving an empty label above it.
struct FormRow: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.last else { return .zero }
        let width = proposal.width ?? FormMetrics.dialogWidth
        let stacked = width < FormMetrics.inlineRowWidth
        let inset = stacked ? 0 : FormMetrics.rowLabelWidth + Space.lg
        let contentSize = content.sizeThatFits(.init(width: max(0, width - inset), height: nil))
        guard subviews.count > 1, let label = subviews.first else {
            return CGSize(width: width, height: contentSize.height)
        }
        let labelSize = label.sizeThatFits(.init(width: stacked ? width : FormMetrics.rowLabelWidth, height: nil))
        return CGSize(width: width, height: stacked ? labelSize.height + Space.sm + contentSize.height
                      : max(labelSize.height, contentSize.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.last else { return }
        let stacked = bounds.width < FormMetrics.inlineRowWidth
        var point = bounds.origin
        if subviews.count > 1, let label = subviews.first {
            let labelProposal = ProposedViewSize(width: stacked ? bounds.width : FormMetrics.rowLabelWidth, height: nil)
            label.place(at: point, proposal: labelProposal)
            if stacked { point.y += label.sizeThatFits(labelProposal).height + Space.sm }
        }
        let inset = stacked ? 0 : FormMetrics.rowLabelWidth + Space.lg
        point.x += inset
        content.place(at: point, proposal: .init(width: max(0, bounds.width - inset), height: nil))
    }
}

// Two fields share a row while there is room to read both controls.
struct FormPair: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? FormMetrics.pairedFieldsWidth
        let stacked = width < FormMetrics.pairedFieldsWidth
        let fieldWidth = stacked ? width : (width - Space.lg) / 2
        let sizes = subviews.map { $0.sizeThatFits(.init(width: fieldWidth, height: nil)) }
        let height = stacked ? sizes.reduce(0) { $0 + $1.height } + Space.lg
            : sizes.map(\.height).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let stacked = bounds.width < FormMetrics.pairedFieldsWidth
        let width = stacked ? bounds.width : (bounds.width - Space.lg) / 2
        var point = bounds.origin
        for subview in subviews {
            let size = subview.sizeThatFits(.init(width: width, height: nil))
            subview.place(at: point, proposal: .init(width: width, height: size.height))
            if stacked { point.y += size.height + Space.lg }
            else { point.x += width + Space.lg }
        }
    }
}

// A line drawn down the leading edge of whatever a floating card is about, such as the
// answer a second opinion will read, so the subject is marked in the window and not only
// named in the card. It draws from the top while shown and fades when put away.
struct SubjectRail: ViewModifier {
    let shown: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static let width: CGFloat = 3

    func body(content: Content) -> some View {
        content.overlay(alignment: .leading) {
            RailLine()
                .trim(from: 0, to: shown || reduceMotion ? 1 : 0)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: Self.width, lineCap: .round))
                .frame(width: Self.width)
                .opacity(shown ? 1 : 0)
                .offset(x: -Space.lg)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .motion(shown ? Motion.draw : Motion.leave, value: shown)
        }
    }

    private struct RailLine: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.midX, y: rect.minY + Self.cap))
                path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - Self.cap))
            }
        }

        private static let cap = SubjectRail.width / 2
    }
}

extension View {
    func subjectRail(_ shown: Bool) -> some View {
        modifier(SubjectRail(shown: shown))
    }
}
