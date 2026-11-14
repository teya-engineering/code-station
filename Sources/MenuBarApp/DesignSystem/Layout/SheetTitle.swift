import SwiftUI

// MARK: - Titles

// How a sheet, a dialog or a screen names itself: a mark, the name, and a count. The
// name never holds a number or a sentence, so it stays the same while the sheet is open.
// What changes is shown beside it, as the badge, or under it, on the status band.
struct SheetTitle<Trailing: View>: View {
    let name: String
    var icon: String? = nil
    // The colour of the state the thing is in. Left nil, the mark is ours and the count
    // stays grey, which is right for a count that says nothing is wrong.
    var tint: Color? = nil
    // The readable twin of the tint, for the glyph and the count's figures.
    var ink: Color? = nil
    var count: Int? = nil
    var font: Font = Typography.title
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: Space.md) {
            if let icon {
                TitleMark(icon: icon, tint: tint ?? Theme.accent, ink: ink ?? tint ?? Theme.accent)
                    .padding(.trailing, Space.xs)
            }
            Text(name)
                .font(font)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityAddTraits(.isHeader)
            if let count {
                CountBadge(count: count, tint: tint, ink: ink)
            }
            Spacer(minLength: Space.md)
            trailing
        }
    }
}

extension SheetTitle where Trailing == EmptyView {
    init(_ name: String, icon: String? = nil, tint: Color? = nil, ink: Color? = nil,
         count: Int? = nil, font: Font = Typography.title) {
        self.init(name: name, icon: icon, tint: tint, ink: ink, count: count, font: font) {
            EmptyView()
        }
    }
}

// The tile beside a name, tinted by state the way a project tile is tinted by project.
struct TitleMark: View {
    let icon: String
    var tint: Color = Theme.accent
    var ink: Color = Theme.accent

    var body: some View {
        Image(systemName: icon)
            .font(Typography.body.weight(.semibold))
            .foregroundStyle(ink)
            .frame(width: ControlHeight.md, height: ControlHeight.md)
            .surface(tint.opacity(0.15), cornerRadius: Radius.control, border: tint.opacity(0.3))
            .accessibilityHidden(true)
    }
}

// The count that sits beside a name instead of inside it. It lands on each change, and
// fades away at zero rather than reading "0".
struct CountBadge: View {
    let count: Int
    var tint: Color? = nil
    var ink: Color? = nil

    var body: some View {
        Text(verbatim: "\(count)")
            .font(Typography.micro)
            .monospacedDigit()
            .foregroundStyle(ink ?? tint ?? Color.secondary)
            .contentTransition(.numericText(value: Double(count)))
            .padding(.horizontal, Space.sm)
            .padding(.vertical, Space.xxs)
            .background(tint?.opacity(0.18) ?? Theme.field, in: Capsule())
            .fixedSize()
            .opacity(count == 0 ? 0 : 1)
            .motion(Motion.pop, value: count)
            .accessibilityLabel(counted(count, "item"))
    }
}

// A question mark that keeps the explanation of a sheet one click away instead of on
// screen every time. The panel hangs under the button, lined up with its right edge.
struct WhyButton<Panel: View>: View {
    let label: String
    @Binding var isOpen: Bool
    @ViewBuilder let panel: Panel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static var panelWidth: CGFloat { 308 }

    var body: some View {
        GlyphButton(icon: "questionmark", active: isOpen) { isOpen.toggle() }
            .appTooltip(label)
            .accessibilityLabel(label)
            .accessibilityValue(isOpen ? "Shown" : "Hidden")
            .overlay(alignment: .topTrailing) {
                ZStack {
                    if isOpen {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text(label).font(Typography.body.weight(.semibold))
                            panel
                        }
                        .padding(Space.lg)
                        .frame(width: Self.panelWidth, alignment: .leading)
                        .floatingCard(cornerRadius: Radius.floating)
                        .offset(y: ControlHeight.md + Space.sm)
                        .transition(.popover(reduceMotion: reduceMotion))
                    }
                }
                .fixedSize()
            }
    }
}
