import AppKit
import SwiftUI
import CodeStationCore

// MARK: - Data

// Always "+n" then "−n", in that order and those two colours, so a diff is recognised
// before it is read.
struct DiffPair: View {
    let added: Int
    let removed: Int
    var size: CGFloat = 11
    var spacing: CGFloat = 5
    var weight: Font.Weight = .semibold

    var body: some View {
        HStack(spacing: spacing) {
            // Verbatim, or a four-figure count is read as a localised number and comes
            // out grouped: +1,234 beside −86.
            Text(verbatim: "+\(added)").foregroundStyle(Theme.addition)
            Text(verbatim: "−\(removed)").foregroundStyle(Theme.deletion)
        }
        .font(.mono(size, weight))
    }
}

// A small run of mono capitals on a quiet fill: a worktree badge, a git summary, the
// kind of thing that qualifies the name beside it. Its room and corners grow with the
// type, so the same chip carries a 13pt command part as well as a 9pt badge. A bordered
// one reads as a value rather than a state, which is what a command or an argument is.
struct MonoChip: View {
    let text: String
    var size: CGFloat = 10
    var tint: Color? = nil
    var bordered = false
    var mono = true

    var body: some View {
        Text(text)
            .font(mono ? .mono(size, .semibold) : .system(size: size, weight: .semibold))
            .kerning(mono ? 0.6 : 0)
            .foregroundStyle(tint ?? Color.secondary)
            .padding(.horizontal, size * 0.6)
            .padding(.vertical, size * 0.3)
            .surface(tint?.opacity(0.16) ?? Theme.field, cornerRadius: size * 0.5,
                     border: bordered ? Theme.border : .clear)
            .fixedSize()
    }
}
