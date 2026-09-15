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
// chosen one is underlined; anything that opens beside the pane rather than replacing it
// is not a tab and does not belong in the deck.
struct HeaderTab: Identifiable {
    let label: String
    let icon: String
    let selected: Bool
    // Counts the destination carries for itself. They sit on the tab that opens them,
    // where they say what has changed rather than only that something has.
    var diff: Diff?
    let activate: () -> Void

    var id: String { label }

    struct Diff: Equatable {
        let added: Int
        let removed: Int
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
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                HeaderTabDeckItem(tab: tab, height: height)
                    .id(tab.id)
            }
        }
        .scrollTargetLayout(isEnabled: scrollable)
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct HeaderTabDeckItem: View {
    let tab: HeaderTab
    let height: CGFloat

    @State private var hovering = false

    var body: some View {
        Button(action: tab.activate) {
            HStack(spacing: 7) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 17, height: 17)
                Text(tab.label)
                    .font(.system(size: Self.wordSize, weight: .semibold))
                    .fixedSize()
                    .frame(width: Self.width(of: tab.label), alignment: .leading)
                if let diff = tab.diff {
                    DiffPair(added: diff.added, removed: diff.removed,
                             size: Self.countSize, spacing: Self.countSpacing)
                        .frame(width: Self.width(of: diff), alignment: .leading)
                }
            }
            .foregroundStyle(tab.selected || hovering ? Color.primary : Color.secondary)
            .padding(.horizontal, 11)
            .frame(height: height)
            .overlay(alignment: .bottom) {
                // Drawn under every tab and inked only under the chosen one, so choosing
                // moves the line rather than changing what the deck asks for in width.
                RoundedRectangle(cornerRadius: 1)
                    .fill(tab.selected ? Theme.accent : Color.clear)
                    .frame(height: 2)
                    .padding(.horizontal, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(tab.selected ? [.isSelected] : [])
    }

    // The counts are read out with the destination rather than left as two numbers beside
    // it, so the tab says the same thing whether it is seen or heard.
    private var accessibilityLabel: String {
        guard let diff = tab.diff else { return tab.label }
        return "\(tab.label), \(diff.added) added, \(diff.removed) removed"
    }

    private static let wordSize: CGFloat = 12.5
    private static let countSize: CGFloat = 10.5
    private static let countSpacing: CGFloat = 5

    // The word's width read from the type and rounded to a whole point, rather than taken
    // from the word once it is on screen. A width that only settles after the label has
    // been drawn gives the deck two widths half a point apart, and the band fitting itself
    // around the deck has to choose between them: it would fit itself to one, be handed
    // the other, fit itself again, and never come to rest.
    static func width(of text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: wordSize, weight: .semibold)
        return ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width)
    }

    // The counts, measured the same way and for the same reason as the word beside them.
    static func width(of diff: HeaderTab.Diff) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: countSize, weight: .semibold)
        let counts = "+\(diff.added)−\(diff.removed)"
        let width = NSAttributedString(string: counts, attributes: [.font: font]).size().width
        return ceil(width + countSpacing)
    }
}

// MARK: - Header rail

// The header's actions sit in one rail at the trailing end of the band: the panel
// toggles, then the session's utilities, each group closed off by one of these.
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
    // The saved text behind a button whose name is not the whole story - a prompt, where
    // what is about to be sent matters more than what it was called.
    var hint: String? = nil
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
        .appTooltip(delay: .zero) { Tooltip(title: label, subtitle: hint) }
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
