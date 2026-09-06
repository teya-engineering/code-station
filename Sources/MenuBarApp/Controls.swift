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

// MARK: - Clustered navigation

// One place a header can send you, or one panel it can open. A destination is chosen and
// stays chosen; a toggle is switched on and off and leaves whatever is on screen where it
// is, which is why the two are drawn apart: the chosen destination takes a raised card,
// the live toggle takes the accent.
struct HeaderTab: Identifiable {
    enum Kind: Equatable {
        case destination(selected: Bool)
        case toggle(on: Bool)
    }

    let label: String
    let icon: String
    let kind: Kind
    // An unread mark that has to survive the label collapsing, since an icon on its own
    // cannot say the working tree moved.
    var badge = false
    var tooltip: Tooltip? = nil
    // A right-click menu rather than a menu button: the click itself belongs to the
    // destination or the toggle, so anything else the tab can do hangs off the secondary
    // click.
    var menu: (() -> [MenuEntry])? = nil
    let activate: () -> Void

    var id: String { label }

    var isLit: Bool {
        switch kind {
        case .destination(let selected): selected
        case .toggle(let on): on
        }
    }
}

// The header's navigation, grouped. Six word-tabs plus a dropdown do not fit beside a
// session title, so only the tab you are on keeps its word and the rest sit as icons.
// Reaching for a group opens every label in it at once, which is what keeps the icons
// from being a guess: the labels arrive before the click, together, rather than one
// tooltip at a time.
//
// The groups themselves carry the meaning a divider or a second colour would otherwise
// have to: what the agent is being set to do, and what it did.
struct HeaderTabClusters: View {
    let clusters: [[HeaderTab]]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(clusters.indices, id: \.self) { index in
                HeaderTabCluster(tabs: clusters[index])
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct HeaderTabCluster: View {
    let tabs: [HeaderTab]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @FocusState private var focused: String?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                button(tab)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.field))
        .onHover { hovering = $0 }
        // The only movement in the header, so it is worth the full quarter second: a
        // group opening is meant to be read, not glimpsed.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: opened)
    }

    // Labels open for the pointer and for the keyboard alike, so tabbing through the
    // header names its destinations the same way hovering does.
    private var opened: Bool { hovering || focused != nil }

    @ViewBuilder private func button(_ tab: HeaderTab) -> some View {
        if let menu = tab.menu {
            shape(tab).appContextMenu(menu)
        } else {
            shape(tab)
        }
    }

    private func shape(_ tab: HeaderTab) -> some View {
        Button(action: tab.activate) {
            HStack(spacing: 0) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 17, height: 17)
                HeaderTabLabel(text: tab.label, expanded: opened || tab.isLit)
                if tab.badge {
                    Circle()
                        .fill(Theme.attention)
                        .frame(width: 5, height: 5)
                        .padding(.leading, 6)
                }
            }
            .foregroundStyle(colour(tab))
            .padding(.horizontal, 9)
            .frame(height: 34)
            .background {
                if case .destination(true) = tab.kind {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.card)
                        .shadow(color: .black.opacity(0.08), radius: 1, y: 0.5)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .focused($focused, equals: tab.id)
        // Hovering the group already opens every label, so a hint that only repeats the
        // word would arrive under a tab that is spelling itself out. Only a tab with
        // something more to say than its own name carries one.
        .appTooltip { tab.tooltip ?? Tooltip(title: "") }
        .accessibilityLabel(tab.label)
        .accessibilityAddTraits(tab.isLit ? [.isSelected] : [])
    }

    private func colour(_ tab: HeaderTab) -> Color {
        switch tab.kind {
        case .destination(let selected): selected ? .primary : .secondary
        case .toggle(let on): on ? Theme.accent : .secondary
        }
    }
}

// A tab's word, which is there or is not. Collapsing to a zero width rather than being
// taken out of the row is what lets the group grow and shrink as one movement instead of
// six labels popping in beside each other.
private struct HeaderTabLabel: View {
    let text: String
    let expanded: Bool

    @State private var width: CGFloat = 0

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .background(GeometryReader { proxy in
                Color.clear.preference(key: HeaderTabLabelWidthKey.self,
                                       value: proxy.size.width)
            })
            .onPreferenceChange(HeaderTabLabelWidthKey.self) { width = $0 }
            .frame(width: expanded ? width : 0, alignment: .leading)
            .opacity(expanded ? 1 : 0)
            .clipped()
            .padding(.leading, expanded ? 7 : 0)
            .accessibilityHidden(true)
    }
}

private struct HeaderTabLabelWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
