import SwiftUI

// The one thing a sheet is for, when it has one: Save, Import, Run. It is what Return
// would do if a sheet had a default button.
struct SheetAction {
    var title: String
    var icon: String? = nil
    var enabled: Bool = true
    var shortcut: KeyboardShortcut? = nil
    let action: () -> Void
}

// macOS puts the button that closes a window at the bottom right, so every sheet ends
// with this bar instead of parking its closing action in the title area where it reads
// like part of the toolbar. Escape triggers the same action.
//
// A sheet that edits something puts its action next to Cancel. The action only lights
// up while there is something for it to do. The title is the line of small print at the
// other end of the bar, saying what the actions will do or where the edits will land.
struct SheetFooter<Leading: View>: View {
    private let title: String?
    private let primary: SheetAction?
    private let dismissTitle: String?
    private let dismiss: () -> Void
    private let leading: Leading

    init(title: String? = nil,
         primary: SheetAction? = nil,
         dismissTitle: String? = nil,
         dismiss: @escaping () -> Void,
         @ViewBuilder leading: () -> Leading) {
        self.title = title
        self.primary = primary
        self.dismissTitle = dismissTitle
        self.dismiss = dismiss
        self.leading = leading()
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.hairline)
            HStack(spacing: 10) {
                if let title {
                    Text(title)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                leading
                Spacer()
                if let primary {
                    ActionButton(title: primary.title, tone: .green, size: 13,
                                 icon: primary.icon, keyboardShortcut: primary.shortcut,
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
                }
                ActionButton(title: dismissTitle ?? (primary == nil ? "Done" : "Cancel"),
                             size: 13, keyboardShortcut: .cancelAction, action: dismiss)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Theme.card)
        }
    }

    private func controlTwin(_ shortcut: KeyboardShortcut) -> KeyboardShortcut? {
        guard shortcut.modifiers.contains(.command) else { return nil }
        return KeyboardShortcut(shortcut.key,
                                modifiers: shortcut.modifiers.subtracting(.command).union(.control))
    }
}

extension SheetFooter where Leading == EmptyView {
    init(title: String? = nil, primary: SheetAction? = nil, dismissTitle: String? = nil,
         dismiss: @escaping () -> Void) {
        self.init(title: title, primary: primary, dismissTitle: dismissTitle,
                  dismiss: dismiss) { EmptyView() }
    }
}
