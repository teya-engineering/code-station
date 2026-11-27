import SwiftUI

// The one thing a sheet is for, when it has one: Save, Import, Run. It is what Return
// would do if a sheet had a default button.
struct SheetAction {
    var title: String
    var icon: String? = nil
    var enabled: Bool = true
    var shortcut: KeyboardShortcut? = nil
    // The shortcut written on the button, such as "⌘S", for a sheet where people save often.
    var hint: String? = nil
    // Left nil, the action wears the shape of its slot: green as the primary, outlined
    // as the secondary. A primary that deletes wears the danger tone instead.
    var tone: ButtonTone? = nil
    // Why the action is off, for a sheet where the reason is not plain from the form. It
    // becomes the button's hint, and a click on the dead button runs `onBlockedClick`, so
    // the sheet can point at what is missing instead of the click doing nothing.
    var blockedReason: String? = nil
    var onBlockedClick: (() -> Void)? = nil
    // Told when the pointer comes onto the button and leaves it, for a sheet that shows
    // what the action will do before it is clicked.
    var onHover: ((Bool) -> Void)? = nil
    let action: () -> Void
}

// Standard sheets close from the bottom right, and Escape does the same thing. A
// reader with its own close control in the header can hide the footer's dismiss button.
//
// A sheet that edits something puts its action next to Cancel. The action only lights
// up while there is something for it to do. A sheet with two ways forward, such as
// Create beside Create and run, puts the quieter one first as the secondary. The title
// is the line of small print at the other end of the bar, saying what the actions will
// do or where the edits will land.
struct SheetFooter<Leading: View>: View {
    var horizontalInset: CGFloat = Space.pane
    var verticalInset: CGFloat = Space.lg
    var showsDismiss = true

    private let title: String?
    private let primary: SheetAction?
    private let secondary: SheetAction?
    private let dismissTitle: String?
    private let dismissTone: ButtonTone
    // The key that dismisses, written on the button, for a sheet whose way out is a
    // choice of its own rather than a plain Cancel.
    private let dismissHint: String?
    private let primaryLast: Bool
    private let dismiss: () -> Void
    private let leading: Leading

    init(title: String? = nil,
         primary: SheetAction? = nil,
         secondary: SheetAction? = nil,
         dismissTitle: String? = nil,
         dismissTone: ButtonTone = .dark,
         dismissHint: String? = nil,
         primaryLast: Bool = false,
         dismiss: @escaping () -> Void,
         @ViewBuilder leading: () -> Leading) {
        self.title = title
        self.primary = primary
        self.secondary = secondary
        self.dismissTitle = dismissTitle
        self.dismissTone = dismissTone
        self.dismissHint = dismissHint
        self.primaryLast = primaryLast
        self.dismiss = dismiss
        self.leading = leading()
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.hairline)
            HStack(spacing: Space.md) {
                if let title {
                    Text(title)
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                leading
                Spacer()
                if let secondary {
                    ActionButton(title: secondary.title, tone: secondary.tone ?? .outlined,
                                 size: Typography.Size.body, icon: secondary.icon,
                                 keyboardShortcut: secondary.shortcut, action: secondary.action)
                        .disabled(!secondary.enabled)
                }
                if primaryLast && showsDismiss { dismissButton }
                if let primary {
                    ActionButton(title: primary.title, tone: primary.tone ?? .green, size: Typography.Size.body,
                                 icon: primary.icon, shortcut: primary.hint,
                                 keyboardShortcut: primary.shortcut,
                                 action: primary.action)
                        // The Mac shortcut is Cmd-something, but fingers trained
                        // elsewhere press Ctrl-something; both land on the same action.
                        // The twin rides behind the pill so it takes no room in the row.
                        .background {
                            if let twin = primary.shortcut.flatMap(controlTwin) {
                                Button(action: primary.action) { Text("") }
                                    .buttonStyle(.plain)
                                    .keyboardShortcut(twin)
                                    .opacity(0)
                            }
                        }
                        .disabled(!primary.enabled)
                        .onPointerHover { primary.onHover?($0) }
                        .overlay { blockedCatcher(for: primary) }
                        .accessibilityHint(primary.enabled ? "" : primary.blockedReason ?? "")
                }
                if !primaryLast && showsDismiss { dismissButton }
            }
            .padding(.horizontal, horizontalInset)
            .padding(.vertical, verticalInset)
            .background(Theme.card)
        }
    }

    private var dismissButton: some View {
        ActionButton(title: dismissTitle ?? (primary == nil && secondary == nil ? "Done" : "Cancel"),
                     tone: dismissTone, size: Typography.Size.body, shortcut: dismissHint,
                     keyboardShortcut: .cancelAction, action: dismiss)
    }

    // A disabled button takes no clicks and shows no hint, so a clear layer laid over it
    // carries both. It sits outside the `.disabled`, and Return still does nothing.
    @ViewBuilder private func blockedCatcher(for action: SheetAction) -> some View {
        if !action.enabled, let reason = action.blockedReason {
            Capsule()
                .fill(.clear)
                .contentShape(Capsule())
                .onTapGesture { action.onBlockedClick?() }
                .appTooltip(reason)
                .accessibilityHidden(true)
        }
    }

    private func controlTwin(_ shortcut: KeyboardShortcut) -> KeyboardShortcut? {
        guard shortcut.modifiers.contains(.command) else { return nil }
        return KeyboardShortcut(shortcut.key,
                                modifiers: shortcut.modifiers.subtracting(.command).union(.control))
    }
}

extension SheetFooter where Leading == EmptyView {
    init(title: String? = nil, primary: SheetAction? = nil, secondary: SheetAction? = nil,
         dismissTitle: String? = nil, dismiss: @escaping () -> Void) {
        self.init(title: title, primary: primary, secondary: secondary,
                  dismissTitle: dismissTitle, dismiss: dismiss) { EmptyView() }
    }
}
