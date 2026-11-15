import AppKit
import SwiftUI

// MARK: - Data

// Always "+n" then "−n", in that order and those two colours, so a diff is recognised
// before it is read.
struct DiffPair: View {
    let added: Int
    let removed: Int
    var size: CGFloat = Typography.Size.caption
    var spacing: CGFloat = Space.xs
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
    var size: CGFloat = Typography.Size.micro
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

// One changed file as a row of bars: its name, then a green bar for lines added and a red
// one for lines removed, both measured on the same scale as the other rows beside it, so
// the biggest change is seen first. A file outside what is picked keeps its grey bars and
// dims its name; one that comes into it draws its colour along the bar.
struct FileBarRow: View {
    let name: String
    let added: Int
    let removed: Int
    var lit = true
    // The line count that fills the whole bar, shared by every row in one list.
    var scale: Int

    static let nameWidth: CGFloat = 168

    var body: some View {
        HStack(spacing: Space.md) {
            Text(name).font(Typography.data).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(lit ? Color.primary : Color.secondary)
                .frame(width: Self.nameWidth, alignment: .leading)
            GeometryReader { proxy in
                let unit = proxy.size.width / CGFloat(max(scale, 1))
                HStack(spacing: Space.xxs) {
                    bar(width: max(added > 0 ? 2 : 0, unit * CGFloat(added)), colour: Theme.addition)
                    bar(width: max(removed > 0 ? 2 : 0, unit * CGFloat(removed)), colour: Theme.deletion)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 6)
            DiffPair(added: added, removed: removed, size: Typography.Size.micro)
                .opacity(lit ? 1 : 0.5)
                .fixedSize()
        }
        .motion(Motion.draw, value: lit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(added) added, \(removed) removed" + (lit ? "" : ", left out"))
    }

    private func bar(width: CGFloat, colour: Color) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Theme.border)
            Capsule().fill(colour).frame(width: lit ? width : 0)
        }
        .frame(width: width, height: 4)
    }
}
