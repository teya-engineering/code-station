import AppKit
import SwiftUI

// Segmented choices used in pane headers. Keeping the control shared means project and
// session navigation have the same hit areas, spacing and selected state.
struct HeaderTabToggle<Selection: Hashable>: View {
    @Binding var selection: Selection
    let options: [(label: String, value: Selection)]

    // Ties the selected pill to whichever segment holds it, so picking another one moves
    // the same shape across instead of hiding it here and showing a new one there.
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                segment(options[index])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
        // A header row hands out its width between its children, so without this the
        // control is offered less than its labels need and every one of them wraps onto
        // two lines. It is a fixed set of short words: it should hold its size and let
        // the title beside it give way instead.
        .fixedSize(horizontal: true, vertical: false)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: selection)
    }

    private func segment(_ option: (label: String, value: Selection)) -> some View {
        let active = selection == option.value
        return Button { selection = option.value } label: {
            Text(option.label)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(active ? Color.primary : Color.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background {
                    if active {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Theme.card)
                            .shadow(color: .black.opacity(0.08), radius: 1, y: 0.5)
                            .matchedGeometryEffect(id: "selected", in: pill)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// The app's own switch and checkbox. The native toggle styles draw with the system's
// chrome and accent, which reads as a piece of another program next to the rest of
// the app, so everything interactive is drawn here with the shared palette instead.

// A switch trails its label, the way a row of settings expects.
struct AppSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 12) {
                configuration.label
                Capsule()
                    .fill(configuration.isOn ? Theme.accentFill : Theme.dotOff)
                    .frame(width: 34, height: 20)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(.white)
                            .padding(2)
                            .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: configuration.isOn)
    }
}

// A checkbox leads its label, the way a tickable line expects.
struct AppCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(configuration.isOn ? Theme.accentFill : Theme.card)
                    .frame(width: 16, height: 16)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(configuration.isOn ? .clear : Theme.border, lineWidth: 1.5))
                    .overlay {
                        if configuration.isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension ToggleStyle where Self == AppSwitchStyle {
    static var appSwitch: AppSwitchStyle { AppSwitchStyle() }
}

extension ToggleStyle where Self == AppCheckboxStyle {
    static var appCheckbox: AppCheckboxStyle { AppCheckboxStyle() }
}

// MARK: - Fields

extension View {
    // The app's text field: no system chrome, a quiet fill and a hairline. Applied to a
    // TextField or a SecureField, so a form does not restate the recipe per field.
    func appTextField(size: CGFloat = 13, cornerRadius: CGFloat = 8) -> some View {
        textFieldStyle(.plain)
            .font(.system(size: size))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .fieldSurface(cornerRadius: cornerRadius)
    }

    // Shows a cursor while the pointer is over the view and puts the old one back when
    // it leaves, for a control sitting on a strip that shows a cursor of its own.
    func cursorOnHover(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}

// The multi-line field, with the placeholder drawn over it because TextEditor has none
// of its own. The placeholder takes no clicks, so the first click still lands in the
// editor.
struct AppTextEditor: View {
    @Binding var text: String
    let placeholder: String
    var minHeight: CGFloat = 80

    init(text: Binding<String>, placeholder: String, minHeight: CGFloat = 80) {
        _text = text
        self.placeholder = placeholder
        self.minHeight = minHeight
    }

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(minHeight: minHeight)
            .fieldSurface(cornerRadius: 10)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
    }
}

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

// MARK: - Copy

// Puts text on the clipboard and says so for a moment. The text is asked for at the
// click, so the button can sit beside a value that is still being edited.
struct CopyButton: View {
    let title: String?
    var size: CGFloat = 11
    let text: () -> String

    init(_ title: String? = nil, size: CGFloat = 11, text: @escaping () -> String) {
        self.title = title
        self.size = size
        self.text = text
    }

    // Long enough to be seen, short enough that the button is ready for the next value
    // by the time the pointer moves on.
    private static let confirmation = Duration.milliseconds(1_500)

    @State private var copied = false
    @State private var reset: Task<Void, Never>?

    var body: some View {
        Button {
            Pasteboard.copy(text())
            copied = true
            reset?.cancel()
            reset = Task {
                try? await Task.sleep(for: Self.confirmation)
                guard !Task.isCancelled else { return }
                copied = false
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: size, weight: .semibold))
                if let title {
                    Text(copied ? "Copied" : title)
                        .font(.system(size: size, weight: .semibold))
                        .fixedSize()
                }
            }
            .foregroundStyle(copied ? Theme.addition : Theme.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: copied)
    }
}

// MARK: - Header navigation

// One place a header can send you. A destination is chosen and stays chosen, and the
// chosen one takes a raised card; anything that opens beside the pane rather than
// replacing it is not a tab and does not belong in the bar.
struct HeaderTab: Identifiable {
    let label: String
    let icon: String
    let selected: Bool
    // An unread mark that has to survive the label collapsing, since an icon on its own
    // cannot say the working tree moved.
    var badge = false
    let activate: () -> Void

    var id: String { label }
}

// The header's navigation. Five word-tabs do not fit beside a session title, so only the
// tab you are on keeps its word and the rest sit as icons. Reaching for the bar opens
// every label at once, which is what keeps the icons from being a guess: the labels
// arrive before the click, together, rather than one tooltip at a time. They also hold
// open for a moment after the pointer leaves, so the words can be read at a glance
// rather than chased.
//
// The bar holds destinations and nothing else, so its edge is the line between swapping
// the pane and opening something next to it.
struct HeaderTabBar: View {
    let tabs: [HeaderTab]
    // Whether the bar keeps the width its open labels need. A header with no width to
    // spare turns this off: the bar then stands in the space it shows and its labels open
    // over what is beside it, which is worth more than a rail run off the edge.
    var holdsOpenRoom = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var closing: Task<Void, Never>?
    @FocusState private var focused: String?

    // How long the labels stay open after the pointer leaves. Crossing the bar on the way
    // somewhere else should not shut it in your face, and a word half read is worse than
    // no word at all, so the bar waits long enough to finish reading before it closes.
    private static let lingerSeconds: Double = 1

    var body: some View {
        // The bar holds the room every label needs whether the labels are open or not,
        // and opens leftwards into it. Taking only the width it shows would shift the
        // rest of the rail sideways each time the pointer crossed the bar, and buttons
        // that walk away from the pointer are worse than a little unused width here.
        // Where the header has no width to spare the bar opens over the title instead,
        // which costs nothing while it is closed.
        room
            .hidden()
            .accessibilityHidden(true)
            .overlay(alignment: .trailing) {
                bar
                    .onHover { inside in
                        closing?.cancel()
                        closing = nil
                        if inside {
                            hovering = true
                        } else {
                            closing = Task { @MainActor in
                                try? await Task.sleep(for: .seconds(Self.lingerSeconds))
                                guard !Task.isCancelled else { return }
                                hovering = false
                            }
                        }
                    }
                    // The only movement in the header, so it is worth the full quarter
                    // second: the bar opening is meant to be read, not glimpsed.
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: opened)
            }
    }

    // Labels open for the pointer and for the keyboard alike, so tabbing through the
    // header names its destinations the same way hovering does.
    private var opened: Bool { hovering || focused != nil }

    private var bar: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                Button(action: tab.activate) {
                    label(tab, opened: opened)
                }
                .buttonStyle(.plain)
                .focused($focused, equals: tab.id)
                .accessibilityLabel(tab.label)
                .accessibilityAddTraits(tab.selected ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background {
            RoundedRectangle(cornerRadius: 11)
                .fill(Theme.field)
                .background {
                    // A bar with no room of its own opens over the title beside it, so it
                    // carries the header's own fill to cover what it lands on. Under a bar
                    // that has its room this is the colour already there.
                    if !holdsOpenRoom {
                        RoundedRectangle(cornerRadius: 11).fill(Theme.card)
                    }
                }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    // The width the bar is held at: every label open, or only the one the chosen tab
    // keeps where there is no room for the rest. It is built from the same pieces as the
    // bar itself so the two cannot drift apart, minus the buttons: a second set would
    // take hits and focus from the real ones.
    private var room: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                label(tab, opened: holdsOpenRoom)
            }
        }
        .padding(3)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func label(_ tab: HeaderTab, opened: Bool) -> some View {
        HStack(spacing: 0) {
            Image(systemName: tab.icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 17, height: 17)
            HeaderTabLabel(text: tab.label, expanded: opened || tab.selected)
            if tab.badge {
                Circle()
                    .fill(Theme.attention)
                    .frame(width: 5, height: 5)
                    .padding(.leading, 6)
            }
        }
        .foregroundStyle(tab.selected ? Color.primary : Color.secondary)
        .padding(.horizontal, 9)
        .frame(height: 34)
        .background {
            if tab.selected {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.card)
                    .shadow(color: .black.opacity(0.08), radius: 1, y: 0.5)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

// A tab's word, which is there or is not. Collapsing to a zero width rather than being
// taken out of the row is what lets the bar grow and shrink as one movement instead of
// five labels popping in beside each other.
private struct HeaderTabLabel: View {
    let text: String
    let expanded: Bool

    var body: some View {
        Text(text)
            .font(.system(size: Self.size, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .frame(width: expanded ? Self.width(of: text) : 0, alignment: .leading)
            .opacity(expanded ? 1 : 0)
            .clipped()
            .padding(.leading, expanded ? 7 : 0)
            .accessibilityHidden(true)
    }

    private static let size: CGFloat = 12.5

    // The word's width read from the type rather than from the word once it is on screen.
    // A width that only arrives after the label has been drawn gives the bar two widths,
    // one before that pass and a wider one after, and everything that lays out around the
    // bar has to choose between them: the header would fit itself to the narrow one, be
    // handed the wide one, fit itself again, and never come to rest.
    static func width(of text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: .semibold)
        return ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width)
    }
}

// MARK: - Header rail

// The header's actions sit in one rail to the right of the title: the tab bar, then the
// panel toggles, then the session's utilities, each group closed off by one of these.
struct HeaderRailDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(width: 1, height: 18)
    }
}

// What a rail button is saying about itself. A state is a tinted glyph on a seat of the
// same colour, so it carries as a shape as well as a hue: at 13pt the accent and the
// resting grey are close enough in value that colour alone is easy to miss, and unreadable
// for anyone who cannot separate the two.
enum HeaderRailState {
    // Nothing is happening behind the button, so it does not ask for the eye.
    case rest
    // A panel this button opened is on screen right now.
    case open
    // Something outside the app is attached, which is why it is not the colour of `open`.
    case live
    // A job this button started is running. It passes, so it takes the colour on its own
    // rather than a seat that would come and go under the glyph.
    case working

    var tint: Color {
        switch self {
        case .rest: Color.secondary
        case .open, .working: Theme.accent
        case .live: Theme.addition
        }
    }

    // The fill the button already draws on hover, in the state's own colour.
    var seat: Color? {
        switch self {
        case .rest, .working: nil
        case .open: Theme.accent.opacity(0.12)
        case .live: Theme.addition.opacity(0.14)
        }
    }
}

// An icon-only button on that rail. It stands the same height as a tab so the whole rail
// reads as one row, and it always carries a word: with no label beside the glyph, the
// tooltip is the only thing that says what the button opens. Left without an action it
// draws as a label, for the overflow that hangs a menu under itself.
struct HeaderRailButton: View {
    let icon: String
    var state: HeaderRailState = .rest
    // Says there is something new behind the button, which a glyph on its own cannot.
    var badge = false
    let label: String
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
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: state)
        .appTooltip(label, delay: .zero)
        .accessibilityLabel(label)
    }

    private var shape: some View {
        Image(systemName: icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(state.tint)
            .frame(width: 30, height: 34)
            .background {
                // The seat stands in for the hover fill rather than sitting under it, so a
                // button already saying something does not change colour when pointed at.
                if let seat = state.seat {
                    RoundedRectangle(cornerRadius: 8).fill(seat)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 8).fill(Theme.field)
                }
            }
            .overlay(alignment: .topTrailing) {
                if badge {
                    Circle()
                        .fill(Theme.attention)
                        .frame(width: 5, height: 5)
                        .offset(x: -3, y: 5)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}
