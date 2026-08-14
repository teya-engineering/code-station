import SwiftUI

// The pieces every screen repeats. A session has to read the same in the sidebar, on its
// project and on Home, so the state light, the diff counter and the row buttons are built
// once here rather than restated on each screen with slightly different numbers.

// MARK: - State

// What a session is doing, as the one word and colour the whole app agrees on.
enum SessionTone {
    case running, needsYou, idle

    init(busy: Bool, needsInput: Bool = false, finished: Bool = false) {
        if needsInput || finished {
            self = .needsYou
        } else if busy {
            self = .running
        } else {
            self = .idle
        }
    }

    var word: String {
        switch self {
        case .running: "RUNNING"
        case .needsYou: "NEEDS YOU"
        case .idle: "IDLE"
        }
    }

    var colour: Color {
        switch self {
        case .running: Theme.dotOn
        case .needsYou: Theme.attention
        case .idle: Color.secondary
        }
    }

    // A card carries its state as a ring rather than a fill, so a column of them reads as
    // one column with a few live rows in it.
    var ring: Color {
        switch self {
        case .running: Theme.dotOn.opacity(0.45)
        case .needsYou: Theme.attention.opacity(0.5)
        case .idle: Theme.border
        }
    }

    var ringWidth: CGFloat { self == .idle ? 1 : 1.3 }
}

// The state light beside the state word. Only a running session pulses: a light that
// breathes says work is happening without the row having to animate anything else.
struct StateLight: View {
    let tone: SessionTone
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(tone.colour)
            .frame(width: size, height: size)
            .modifier(PulseModifier(active: tone == .running))
    }
}

// A green dot that breathes on its own, for the places that mark "something is running"
// without naming which session.
struct RunningDot: View {
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(Theme.dotOn)
            .frame(width: size, height: size)
            .modifier(PulseModifier(active: true))
    }
}

private struct PulseModifier: ViewModifier {
    let active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.35 : 1)
            .animation(active && !reduceMotion
                       ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                       : nil,
                       value: dim)
            .onAppear { dim = active }
            .onChange(of: active) { _, running in dim = running }
    }
}

// MARK: - Identity

// A project wherever it is not the subject of the screen: a small square of its colour
// ahead of its name. Square rather than round, so it never reads as a state light.
struct ProjectDot: View {
    let tint: Theme.ProjectTint
    var size: CGFloat = 8

    var body: some View {
        RoundedRectangle(cornerRadius: size / 4)
            .fill(tint.colour)
            .frame(width: size, height: size)
    }
}

// The initial on its tinted tile. Everything about it scales from the side, so the same
// tile serves the 26pt sidebar row and the 36pt workspace lead. Stacked draws a second
// tile peeking out behind, which is what a workspace is: a pile of projects.
struct ProjectTileView: View {
    let name: String
    let tint: Theme.ProjectTint
    var side: CGFloat = 26
    var dashed = false
    var stacked = false

    private var radius: CGFloat { side * 0.27 }

    var body: some View {
        face
            // The stack rides behind without taking room, so the front tile keeps the
            // place a plain project tile would have and a column of them stays aligned.
            .background(alignment: .center) { if stacked { backTile } }
    }

    private var face: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(tint.fill)
            .frame(width: side, height: side)
            .overlay {
                if dashed {
                    RoundedRectangle(cornerRadius: radius)
                        .stroke(tint.colour.opacity(0.65),
                                style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
                    Image(systemName: "bolt.fill")
                        .font(.system(size: side * 0.4, weight: .semibold))
                        .foregroundStyle(tint.ink)
                } else {
                    RoundedRectangle(cornerRadius: radius).stroke(tint.ring)
                    Text(String(name.prefix(1)).uppercased())
                        .font(.mono(side * 0.42, .semibold))
                        .foregroundStyle(tint.ink)
                }
            }
    }

    // The tile underneath, shifted up and to the right. The part it would share with the
    // front tile is cut away: both fills are translucent, so left whole it would darken
    // the face instead of sitting behind it.
    private var backTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius)
                .fill(tint.fill)
                .overlay(RoundedRectangle(cornerRadius: radius).stroke(tint.ring))
                .offset(x: side * 0.15, y: -side * 0.15)
            RoundedRectangle(cornerRadius: radius)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .frame(width: side, height: side)
    }
}

// MARK: - Data

// Always "+n" then "−n", in that order and those two colours, so a diff is recognised
// before it is read.
struct DiffPair: View {
    let added: Int
    let removed: Int
    var size: CGFloat = 11
    var spacing: CGFloat = 5

    var body: some View {
        HStack(spacing: spacing) {
            Text("+\(added)").foregroundStyle(Theme.addition)
            Text("−\(removed)").foregroundStyle(Theme.deletion)
        }
        .font(.mono(size, .semibold))
    }
}

// A small run of mono capitals on a quiet fill: a worktree badge, a git summary, the
// kind of thing that qualifies the name beside it.
struct MonoChip: View {
    let text: String
    var size: CGFloat = 10
    var tint: Color? = nil

    var body: some View {
        Text(text)
            .font(.mono(size, .semibold))
            .kerning(0.6)
            .foregroundStyle(tint ?? Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(tint?.opacity(0.16) ?? Theme.field))
            .fixedSize()
    }
}

// "2m", "3h", "2d": short enough to sit at the end of a narrow row.
enum RelativeTime {
    static func short(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        case ..<604_800: return "\(Int(seconds / 86_400))d"
        default: return "\(Int(seconds / 604_800))w"
        }
    }

    // "today 09:41", "yesterday 16:18", "3 Aug 11:02": what a row shows when the reader
    // is deciding which session to come back to rather than how fresh it is.
    static func stamp(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "today \(time)" }
        if calendar.isDateInYesterday(date) { return "yesterday \(time)" }
        return date.formatted(.dateTime.day().month(.abbreviated)) + " " + time
    }
}

// A name that gets replaced rather than edited, most often the moment a session's first
// prompt takes "New session" over. Swapping the words in place is easy to miss, so the
// old ones leave upward while the new ones rise into their spot, and the line widens into
// them so whatever sits after the name slides across rather than jumping.
//
// The words are stacked rather than laid out in a row: one of them is always on its way
// out, and a row would hold a slot open for it and show both names side by side.
extension View {
    func changingName(_ name: String) -> some View {
        modifier(ChangingName(name: name))
    }
}

private struct ChangingName: ViewModifier {
    let name: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Slow for an animation, and deliberately so: this runs once in a session's life,
    // while the eye is still on the composer the name came from. Anything quicker is
    // over before it is looked at, and reads as the name having always been there.
    private static let duration = 0.7

    func body(content: Content) -> some View {
        ZStack(alignment: .leading) {
            content
                .id(name)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 12)),
                    removal: .opacity.combined(with: .offset(y: -12))))
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: Self.duration), value: name)
    }
}

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
        HStack(spacing: 9) {
            if pulses {
                RunningDot()
            } else if let dot {
                Circle().fill(dot).frame(width: 6, height: 6)
            }
            Text(title)
                .font(.mono(9.5, .semibold))
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

// The connector under an expanded sidebar row stops at its last child. Each marker is
// anchored to its row so mixed row heights keep the line and dots aligned.
private struct SidebarRailMarkerKey: PreferenceKey {
    static let defaultValue: [Anchor<CGPoint>] = []

    static func reduce(value: inout [Anchor<CGPoint>],
                       nextValue: () -> [Anchor<CGPoint>]) {
        value.append(contentsOf: nextValue())
    }
}

struct SidebarRail<Content: View>: View {
    let colour: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) { content }
            .backgroundPreferenceValue(SidebarRailMarkerKey.self) { markers in
                GeometryReader { proxy in
                    if let lastMarker = markers.last {
                        Rectangle()
                            .fill(colour.opacity(0.42))
                            .frame(width: 1.5, height: proxy[lastMarker].y)
                            .offset(x: 5.25)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(.leading, 20)
            .padding(.top, 5)
            .padding(.bottom, 4)
    }
}

struct SidebarRailRow<Content: View>: View {
    let colour: Color
    var selectedColour: Color? = nil
    var selected = false
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(selected ? selectedColour ?? colour : colour.opacity(0.72))
                    .anchorPreference(key: SidebarRailMarkerKey.self, value: .center) {
                        [$0]
                    }
            }
            .frame(width: 12, height: 8)
            .padding(.top, 10)
            .accessibilityHidden(true)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// The strip that closes a screen: what the defaults are, or what has gone stale, and the
// one link that leads to the screen where it can be changed.
struct FooterStrip<Trailing: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .fixedSize()
            Text(detail)
                .font(.mono(11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.sunken))
    }
}

// MARK: - Buttons

// The shapes a button takes. Which one a button wears says how much of the screen it
// owns, so the shape is chosen here rather than restated wherever a button is drawn.
enum ButtonTone {
    // The one action a card or a screen is really offering.
    case dark
    // The same weight, in the app's green, for starting work.
    case green
    // The same weight in the deletion red, for the action a section exists to warn about.
    // It wears the same colour as the destructive button in a dialog, so the click that
    // opens the dialog and the click that confirms it read as the same action.
    case danger
    // Beside a primary one, or on its own where the action is a choice rather than the
    // point of the row.
    case outlined
    // A control that has to stay quieter than the row it sits in.
    case sunken
}

struct ActionButton: View {
    let title: String
    var tone: ButtonTone = .dark
    var height: CGFloat = 32
    var size: CGFloat = 12.5
    var icon: String? = nil
    var shortcut: String? = nil
    var disclosure = false
    var fills = false
    // Left out when the button opens a menu: `appMenu` brings a button of its own, and
    // one nested inside another swallows the click before the menu ever sees it.
    var action: (() -> Void)? = nil

    @State private var hovering = false

    var body: some View {
        Group {
            if let action {
                Button(action: action) { shape }
                    .buttonStyle(.plain)
            } else {
                shape
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }

    private var shape: some View {
        HStack(spacing: 7) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: size - 1, weight: .semibold))
            }
            Text(title)
                .font(.system(size: size, weight: .semibold))
                .lineLimit(1)
                // A button's label is the button: it holds its width and lets whatever
                // shares the row give way, rather than truncating its own words.
                .fixedSize()
            if let shortcut {
                Text(shortcut)
                    .font(.mono(size - 2.5))
                    .opacity(0.55)
            }
            if disclosure {
                Image(systemName: "chevron.down")
                    .font(.system(size: size - 4, weight: .semibold))
                    .opacity(0.65)
            }
        }
        .foregroundStyle(label)
        .padding(.horizontal, height * 0.4)
        .frame(height: height)
        .frame(maxWidth: fills ? .infinity : nil)
        .background(RoundedRectangle(cornerRadius: height * 0.25).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: height * 0.25).stroke(stroke))
        .contentShape(RoundedRectangle(cornerRadius: height * 0.25))
    }

    private var label: Color {
        switch tone {
        case .dark, .green, .danger: Color.white
        case .outlined, .sunken: Color.primary
        }
    }

    private var fill: Color {
        switch tone {
        case .dark: Color.black.opacity(hovering ? 0.82 : 0.9)
        case .green: hovering ? Theme.accentFill.opacity(0.86) : Theme.accentFill
        case .danger: hovering ? Theme.deletion.opacity(0.86) : Theme.deletion
        case .outlined: hovering ? Theme.field : .clear
        case .sunken: hovering ? Theme.border : Theme.field
        }
    }

    private var stroke: Color {
        switch tone {
        case .dark, .green, .danger: .clear
        case .outlined, .sunken: Theme.border
        }
    }
}

// The smallest way to offer an action: accent-coloured words, no shape at all. Used for
// the one link a section header or a footer strip carries.
struct InlineLink: View {
    let title: String
    var size: CGFloat = 12
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .opacity(hovering ? 0.75 : 1)
                .fixedSize()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}

// A square button holding one glyph: the overflow menu at the end of a row, a close, a
// settings cog. Destructive actions live behind the overflow rather than in the row, so
// this is the only icon-only button the layouts use.
struct GlyphButton: View {
    let icon: String
    var side: CGFloat = 30
    var action: (() -> Void)? = nil

    @State private var hovering = false

    var body: some View {
        Group {
            if let action {
                Button(action: action) { shape }
                    .buttonStyle(.plain)
            } else {
                shape
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }

    private var shape: some View {
        Image(systemName: icon)
            .font(.system(size: side * 0.42, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: side, height: side)
            .background(RoundedRectangle(cornerRadius: side * 0.27)
                .fill(hovering ? Theme.field : .clear))
            .overlay(RoundedRectangle(cornerRadius: side * 0.27).stroke(Theme.border))
            .contentShape(RoundedRectangle(cornerRadius: side * 0.27))
    }
}
