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
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
    }

    private func button(_ action: Dialog.Action) -> some View {
        let enabled = action.isEnabled()
        return Button {
            presenter.run(action)
        } label: {
            Text(action.label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(foreground(action.kind))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 9).fill(background(action.kind)))
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .stroke(action.kind == .primary || action.kind == .destructive
                            ? .clear : Theme.border))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        // Escape leaves; return takes the main action, the way a dialog is expected to
        // behave when the mouse is not involved. Only those two get a key, so a middle
        // choice never steals one.
        .modifier(DialogShortcut(kind: action.kind))
    }

    private func foreground(_ kind: Dialog.Action.Kind) -> Color {
        switch kind {
        case .primary, .destructive: .white
        case .plain, .cancel: .primary
        }
    }

    private func background(_ kind: Dialog.Action.Kind) -> Color {
        switch kind {
        case .primary: Color.black.opacity(0.88)
        case .destructive: Theme.deletion
        case .plain, .cancel: Theme.field
        }
    }
}

private struct DialogShortcut: ViewModifier {
    let kind: Dialog.Action.Kind

    func body(content: Content) -> some View {
        switch kind {
        case .primary, .destructive:
            content.keyboardShortcut(.return, modifiers: [])
        case .cancel:
            content.keyboardShortcut(.escape, modifiers: [])
        case .plain:
            content
        }
    }
}
