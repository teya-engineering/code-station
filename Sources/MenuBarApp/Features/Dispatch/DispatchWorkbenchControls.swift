import SwiftUI

struct DispatchTabs<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let namespace: Namespace.ID
    let label: (Item) -> String
    var detail: (Item) -> String? = { _ in nil }
    @FocusState private var focused: Item?
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: Space.xxl) {
            ForEach(items, id: \.self) { item in
                Button { selection = item } label: {
                    HStack(spacing: Space.xs) {
                        Text(label(item))
                        if let detail = detail(item) {
                            Text(detail).font(Font.system(size: Typography.Size.micro))
                                .padding(.horizontal, Space.xs).padding(.vertical, 1)
                                .background(Theme.field, in: RoundedRectangle(cornerRadius: Radius.tag))
                        }
                    }
                    .font(Typography.detail.weight(selection == item ? .semibold : .regular))
                    .foregroundStyle(selection == item ? Theme.accent : .secondary)
                    // Lifted before the underline is drawn, so the underline stays still.
                    .hoverLift()
                    .frame(height: 37)
                    .overlay(alignment: .bottom) {
                        if selection == item {
                            Capsule().fill(Theme.accent).frame(height: 2)
                                .matchedGeometryEffect(id: "indicator", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(isEnabled).focused($focused, equals: item).focusEffectDisabled()
                .overlay(RoundedRectangle(cornerRadius: Radius.tag)
                    .stroke(focused == item ? Theme.accent : .clear, lineWidth: 2).padding(Space.xxs))
                .onKeyPress(keys: [.leftArrow, .rightArrow, .home, .end]) { key in
                    guard isEnabled, let index = items.firstIndex(of: item), !items.isEmpty else { return .ignored }
                    let next = key.key == .home ? 0 : key.key == .end ? items.count - 1
                        : (index + (key.key == .rightArrow ? 1 : items.count - 1)) % items.count
                    selection = items[next]
                    focused = selection
                    return .handled
                }
                .onKeyPress(keys: [.space, .return]) { _ in
                    guard isEnabled else { return .ignored }
                    selection = item
                    return .handled
                }
                .accessibilityLabel("\(label(item)) tab")
                .accessibilityAddTraits(selection == item ? [.isSelected] : [])
                .accessibilityLabeledPair(role: .label, id: item, in: namespace)
            }
        }
        .motion(Motion.control, value: selection)
        .accessibilityElement(children: .contain)
    }
}

struct DispatchResponseGrip: View {
    let height: CGFloat
    let availableHeight: CGFloat
    @Binding var dragHeight: CGFloat?
    @Environment(DispatchStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragStart: CGFloat?
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        Capsule().fill(focused || hovering ? Theme.accent : Theme.border)
            .frame(width: focused || hovering ? 40 : 28, height: 3)
            .frame(maxWidth: .infinity)
            .frame(height: DispatchSplitLayout.handleHeight)
            .background(Theme.sidebar)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStart ?? height
                    dragStart = start
                    dragHeight = DispatchSplitLayout.responseHeight(start - value.translation.height,
                                                                    available: availableHeight)
                }
                .onEnded { _ in
                    if let dragHeight { store.responseHeight = dragHeight }
                    dragHeight = nil
                    dragStart = nil
                })
            .onPointerHover { hovering = $0 }
            .cursorOnHover(.resizeUpDown)
            .focusable().focused($focused).focusEffectDisabled()
            .overlay(Rectangle().stroke(focused ? Theme.accent : .clear))
            .onKeyPress(keys: [.upArrow, .downArrow]) { key in
                resize(by: key.key == .upArrow ? 24 : -24)
                return .handled
            }
            .accessibilityElement()
            .accessibilityLabel("Resize response pane")
            .accessibilityValue("\(Int(height)) points high")
            .accessibilityHint("Use Up and Down to resize")
            .accessibilityAdjustableAction { direction in
                resize(by: direction == .increment ? 24 : -24)
            }
            .appTooltip("Drag or use Up and Down to resize the response")
            .motion(Motion.hover, value: hovering || focused)
    }

    private func resize(by change: CGFloat) {
        withAnimation(reduceMotion ? nil : Motion.control) {
            store.responseHeight = DispatchSplitLayout.responseHeight(height + change, available: availableHeight)
        }
    }
}

extension View {
    // A pane kept alive behind the one on show, so it keeps its scroll place and does not
    // have to be laid out again each time it comes back. Only the pane coming into view
    // fades; the one going out goes at once, so two panes are never drawn over each other.
    func standbyPane(shown: Bool) -> some View {
        opacity(shown ? 1 : 0)
            .transaction { if !shown { $0.animation = nil } }
    }
}

extension View {
    // Rows that belong together sit in one card and are split by a hairline, which each
    // row after the first draws along its own top edge.
    func rowCard() -> some View {
        background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(Theme.border))
    }

    fileprivate func cardRow(first: Bool, lit: Bool) -> some View {
        padding(.leading, Space.lg).padding(.trailing, Space.sm)
            .frame(minHeight: DispatchMetrics.rowHeight)
            .background(lit ? Theme.sunken : .clear)
            .overlay(alignment: .top) {
                if !first { Theme.hairline.frame(height: 1) }
            }
    }
}

// A query parameter or a header: a tick to park it, its name, its value, and a way to
// remove it that shows once the row is under the pointer or holds the cursor.
struct DispatchFieldRow: View {
    @Binding var field: HeaderField
    var kind: String? = nil
    var namePlaceholder = "Header"
    // Only real headers are held to the header name rules. A query param is named by
    // whoever wrote the API and may hold characters a header never could.
    var isHeader = false
    var first = false
    var focusesName = false
    var focusesValue = false
    let onDelete: () -> Void

    private enum Field: Hashable { case name, value, remove }
    @FocusState private var focused: Field?
    @State private var hovering = false

    private var title: String { field.key.isEmpty ? namePlaceholder : field.key }

    // Shown once the name cannot be fixed by splitting it, so a name that arrives whole
    // is quietly put right and only a genuinely unusable one is called out.
    private var nameProblem: String? {
        guard isHeader, !field.key.isEmpty, !HeaderField.isValidName(field.key) else { return nil }
        return "A header name cannot hold spaces or colons."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.lg) {
                Toggle(isOn: $field.enabled) { EmptyView() }
                    .toggleStyle(.appCheckbox)
                    .accessibilityLabel("Include \(title)")
                if let kind {
                    Text(kind).capsText().foregroundStyle(.tertiary)
                        .frame(width: DispatchMetrics.kindWidth, alignment: .leading)
                }
                Group {
                    TextField(namePlaceholder, text: $field.key)
                        .textFieldStyle(.plain)
                        .focused($focused, equals: .name)
                        .font(Typography.code.weight(.semibold))
                        .foregroundStyle(nameProblem == nil ? Color.primary : Theme.deletion)
                        .frame(width: DispatchMetrics.nameWidth, alignment: .leading)
                        .accessibilityLabel("\(namePlaceholder) name")
                        .onChange(of: field.key) {
                            if isHeader { field.splitPastedName() }
                        }
                    TextField("value", text: $field.value)
                        .textFieldStyle(.plain)
                        .focused($focused, equals: .value)
                        .font(Typography.code)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Value for \(title)")
                }
                .opacity(field.enabled ? 1 : 0.45)
                Button(action: onDelete) {
                    Image(systemName: "xmark").font(Typography.caption)
                        .frame(width: ControlHeight.sm, height: ControlHeight.sm).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($focused, equals: .remove)
                .foregroundStyle(.secondary)
                .hoverLift(amount: Motion.smallLift)
                .opacity(hovering || focused != nil ? 1 : 0)
                .accessibilityLabel("Remove \(title)")
            }
            if let nameProblem {
                Text(nameProblem)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.deletion)
                    .padding(.bottom, Space.sm)
            }
        }
        .cardRow(first: first, lit: hovering || focused != nil)
        .onPointerHover { hovering = $0 }
        .motion(Motion.hover, value: hovering || focused != nil)
        .motion(Motion.control, value: field.enabled)
        .accessibilityAction(named: "Remove \(title)", onDelete)
        .onAppear {
            if focusesName { focused = .name } else if focusesValue { focused = .value }
        }
    }
}

// The value for one :name in the address. The row comes and goes with the name, so it
// has a lock where the others have a tick.
struct DispatchPathRow: View {
    let name: String
    @Binding var value: String
    var first = false
    let onHover: (Bool) -> Void

    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Space.lg) {
            Image(systemName: "lock")
                .font(Typography.caption)
                .foregroundStyle(.tertiary)
                .frame(width: ControlHeight.xs - Space.xs)
                .appTooltip("Comes from :\(name) in the address")
                .accessibilityHidden(true)
            Text("PATH").capsText().foregroundStyle(Theme.attentionText)
                .frame(width: DispatchMetrics.kindWidth, alignment: .leading)
            Text(name)
                .font(Typography.code.weight(.semibold))
                .lineLimit(1).truncationMode(.middle)
                .frame(width: DispatchMetrics.nameWidth, alignment: .leading)
            TextField("value", text: $value)
                .textFieldStyle(.plain)
                .focused($focused)
                .font(Typography.code)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Value for \(name), from the address")
        }
        .padding(.trailing, ControlHeight.sm + Space.lg)
        .cardRow(first: first, lit: hovering || focused)
        .onPointerHover {
            hovering = $0
            onHover($0)
        }
        .motion(Motion.hover, value: hovering || focused)
    }
}

// Where the environment's token stands, at the end of the "Goes to" line. It is only
// there for a request that uses the token, and turns amber when there is none to send.
struct DispatchTokenChip: View {
    let environment: ApiEnvironment
    let mode: AuthMode
    let openEnvironments: () -> Void

    @Environment(DispatchAuthStore.self) private var auth

    var body: some View {
        switch mode {
        case .none:
            EmptyView()
        case .basic:
            chip("lock", "Basic sign-in", needed: false, tint: .secondary)
                .accessibilityLabel("This request signs in with a username and password")
        case .environmentToken:
            // The time left is read off the clock, so it is looked at again now and then.
            TimelineView(.periodic(from: .now, by: 30)) { _ in token }
        }
    }

    @ViewBuilder private var token: some View {
        if auth.busy.contains(environment) || auth.awaitingPaste.contains(environment) {
            chip("shield", "Signing in to \(environment.label)…", needed: true)
                .hoverLift()
                .appMenu {
                    [.item("Cancel sign-in") { auth.cancelAuthentication(environment) },
                     .item("Sign-in settings", action: openEnvironments)]
                }
        } else if auth.isAuthenticated(for: environment) {
            chip("checkmark.shield", "Token ready", detail: auth.tokens[environment]?.remainingText,
                 needed: false, tint: environment.accent)
                .hoverLift()
                .appMenu {
                    [.item("Sign in again", action: signIn),
                     .item("Sign-in settings", action: openEnvironments)]
                }
                .accessibilityLabel("\(environment.label) token ready")
                .transition(.fadeIn)
        } else {
            Button(action: signIn) {
                chip("shield", auth.failures[environment] == nil ? "Sign in to \(environment.label)"
                                                                  : "Sign-in failed. Try again",
                     needed: true)
            }
            .buttonStyle(.plain)
            .hoverLift()
            .appTooltip("This request uses \(environment.label)'s token")
        }
    }

    private func signIn() {
        dispatchSignIn(environment, auth: auth, openSettings: openEnvironments)
    }

    private func chip(_ icon: String, _ text: String, detail: String? = nil, needed: Bool,
                      tint: Color = Theme.attentionText) -> some View {
        HStack(spacing: Space.xs) {
            Image(systemName: icon)
            Text(text)
            if let detail {
                Text(detail).font(Font.mono(Typography.Size.micro)).opacity(0.8)
            }
        }
        .font(Typography.caption.weight(.semibold))
        .foregroundStyle(tint)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, Space.md)
        .frame(height: ControlHeight.xs)
        .background(needed ? Theme.attention.opacity(0.14) : .clear,
                    in: RoundedRectangle(cornerRadius: Radius.inset))
        .contentShape(Rectangle())
    }
}
