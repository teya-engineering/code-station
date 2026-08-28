import SwiftUI

// A question asked in the middle of the window, drawn by the app rather than by AppKit.
// The system dialog cannot be styled, so it arrives as a grey slab that looks like it
// belongs to another program; this one uses the same palette, type and buttons as
// everything else.
struct Dialog: Identifiable {
    struct Action: Identifiable {
        enum Kind { case primary, destructive, plain, cancel }

        let id = UUID()
        let label: String
        var kind: Kind = .plain
        var handler: () -> Void = {}
        // Asked each time the dialog draws, so a button can follow a choice made in the
        // dialog's own content without the dialog being shown again. It comes last so a
        // trailing closure still reads as the button's handler.
        var isEnabled: () -> Bool = { true }
    }

    let id = UUID()
    let title: String
    var message: String?
    // Drawn between the message and the buttons, for a question that has to show more
    // than a sentence, such as the exact request a confirmation is about.
    var content: AnyView?
    var actions: [Action]
    // Runs when the dialog is dismissed with escape or a click outside it.
    var onCancel: () -> Void = {}
    var width: CGFloat = 340
}

extension Dialog {
    // Something to read and put away. The one button is a cancel, so Return and Escape
    // both close it.
    static func notice(_ title: String, message: String? = nil) -> Dialog {
        Dialog(title: title, message: message, actions: [Action(label: "OK", kind: .cancel)])
    }

    // A question with one way forward and a way out. Most of them guard a deletion, so
    // the action is destructive unless told otherwise.
    static func confirm(_ title: String, message: String? = nil, action: String,
                        kind: Dialog.Action.Kind = .destructive, cancel: String = "Cancel",
                        handler: @escaping () -> Void) -> Dialog {
        Dialog(title: title, message: message, actions: [
            Action(label: action, kind: kind, handler: handler),
            Action(label: cancel, kind: .cancel)
        ])
    }
}

// Holds whatever dialog is open. It lives at the top of the window so a question asked
// from the sidebar is still centred over the whole app.
@MainActor
@Observable
final class DialogPresenter {
    private(set) var current: Dialog?

    func show(_ dialog: Dialog) { current = dialog }

    func dismiss() {
        let cancel = current?.onCancel
        current = nil
        cancel?()
    }

    // Buttons run their own work after the dialog is gone, so a handler that opens
    // another dialog is not closed again by its own dismissal.
    func run(_ action: Dialog.Action) {
        current = nil
        action.handler()
    }
}

struct DialogHost: View {
    @Environment(DialogPresenter.self) private var presenter

    var body: some View {
        if let dialog = presenter.current {
            ZStack {
                // The backdrop both dims the app and swallows clicks meant for it.
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { presenter.dismiss() }

                card(dialog)
                    .frame(width: dialog.width)
                    .id(dialog.id)
                    .transition(.fadeIn)
            }
            .transition(.fadeIn)
            .smoothlyResizes(when: dialog.id)
        }
    }

    private func card(_ dialog: Dialog) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(dialog.title)
                    .font(.serif(17, .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let message = dialog.message {
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let content = dialog.content {
                    content
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            VStack(spacing: 8) {
                ForEach(dialog.actions) { action in
                    button(action)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .floatingCard(cornerRadius: 14)
    }

    // The buttons are the app's own pills, so the action a dialog confirms wears the
    // same shape as the one that opened it.
    private func button(_ action: Dialog.Action) -> some View {
        ActionButton(title: action.label, tone: tone(action.kind), height: 36, size: 13,
                     fills: true, keyboardShortcut: shortcut(action.kind)) {
            presenter.run(action)
        }
        .disabled(!action.isEnabled())
    }

    private func tone(_ kind: Dialog.Action.Kind) -> ButtonTone {
        switch kind {
        case .primary: .dark
        case .destructive: .danger
        case .plain, .cancel: .sunken
        }
    }

    // Escape leaves; return takes the main action, the way a dialog is expected to
    // behave when the mouse is not involved. Only those two get a key, so a middle
    // choice never steals one.
    private func shortcut(_ kind: Dialog.Action.Kind) -> KeyboardShortcut? {
        switch kind {
        case .primary, .destructive: .defaultAction
        case .cancel: .cancelAction
        case .plain: nil
        }
    }
}
