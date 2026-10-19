import AppKit
import SwiftUI
import CodeStationCore

// MARK: - Rows

// The line that opens and closes a fold: a chevron that turns when the fold is open,
// then whatever the fold is called. The whole row is the target, since a chevron on its
// own is a small thing to hit.
struct DisclosureHeader<Label: View>: View {
    @Binding var isExpanded: Bool
    let show: String
    let hide: String
    @ViewBuilder let label: Label

    init(isExpanded: Binding<Bool>, show: String, hide: String,
         @ViewBuilder label: () -> Label) {
        _isExpanded = isExpanded
        self.show = show
        self.hide = hide
        self.label = label()
    }

    var body: some View {
        Button { isExpanded.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10)
                label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverLift()
        .motion(Motion.control, value: isExpanded)
        .appTooltip(isExpanded ? hide : show)
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
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .font(.mono(11, .semibold))
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
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(label, style: .field)
            content
            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
