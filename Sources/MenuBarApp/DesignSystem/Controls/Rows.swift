import AppKit
import SwiftUI

// MARK: - Rows

// The line that opens and closes a fold: a chevron that turns when the fold is open,
// then whatever the fold is called. The whole row is the target, since a chevron on its
// own is a small thing to hit.
struct DisclosureHeader<Label: View>: View {
    @Binding var isExpanded: Bool
    // Nil leaves the chevron to speak for itself, for a fold whose label already says
    // what it hides.
    let show: String?
    let hide: String?
    @ViewBuilder let label: Label

    init(isExpanded: Binding<Bool>, show: String? = nil, hide: String? = nil,
         @ViewBuilder label: () -> Label) {
        _isExpanded = isExpanded
        self.show = show
        self.hide = hide
        self.label = label()
    }

    var body: some View {
        Button { isExpanded.toggle() } label: {
            HStack(spacing: Space.md) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10)
                label
            }
            .padding(.horizontal, Space.xs)
            .padding(.vertical, Space.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A fill rather than a lift, since the label often runs the width of its card
        // and a row that swells pushes against the lines around it. The wash gets a
        // little room past the text, then the row gives that room back so it lines up
        // with its neighbours as before.
        .hoverFill(cornerRadius: Radius.inset)
        .padding(.horizontal, -5)
        .padding(.vertical, -3)
        .motion(Motion.control, value: isExpanded)
        .appTooltip(isExpanded ? hide : show)
    }
}

private extension View {
    @ViewBuilder func appTooltip(_ text: String?) -> some View {
        if let text { appTooltip(text) } else { self }
    }
}

// A key beside its value. The keys share one column width, so a list of them reads as a
// table without ruling one.
struct LabeledRow<Content: View>: View {
    let label: String
    var width: CGFloat = 120
    @ViewBuilder let content: Content

    init(_ label: String, width: CGFloat = 120, @ViewBuilder content: () -> Content) {
        self.label = label
        self.width = width
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xl) {
            Text(label)
                .font(Typography.data.weight(.semibold))
                .kerning(0.5)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: width, alignment: .leading)
            content
            Spacer(minLength: 0)
        }
    }
}

// A form field under its small label, with room for a line saying what the field is
// for or what it will do.
struct LabeledField<Content: View>: View {
    let label: String
    var note: String? = nil
    @ViewBuilder let content: Content

    init(_ label: String, note: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionLabel(label, style: .field)
            content
            if let note {
                Text(note)
                    .font(Typography.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
