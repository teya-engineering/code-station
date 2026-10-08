import AppKit
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

    // What a deletion takes away and what it leaves behind, one row each, so nothing about
    // it is buried in a paragraph the reader skims past.
    struct Impact {
        struct Subject {
            enum Kind { case project, task, workspace }

            let name: String
            var kind: Kind = .project
        }

        struct Row {
            let title: String
            let detail: String
            var kept = false
        }

        // The project, task or workspace the deletion happens in, drawn as its tile.
        var subject: Subject?
        let rows: [Row]
        var warning: String?
        var compact = false
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
    var impact: Impact?
    var isModal = false
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

    // A confirmation for a deletion with more than one consequence. The rows make the
    // dialog wider than a plain question, so the details do not wrap into a column.
    static func impact(_ title: String, message: String? = nil, subject: Impact.Subject? = nil,
                       rows: [Impact.Row], warning: String? = nil, compact: Bool = false, action: String,
                       handler: @escaping () -> Void) -> Dialog {
        var dialog = confirm(title, message: message, action: action, handler: handler)
        dialog.width = compact ? 420 : 500
        dialog.impact = Impact(subject: subject, rows: rows, warning: warning, compact: compact)
        return dialog
    }
}

// Holds whatever dialog is open. It lives at the top of the window so a question asked
// from the sidebar is still centred over the whole app.
@MainActor
@Observable
final class DialogPresenter {
    private(set) var current: Dialog?

    private weak var previousResponder: NSResponder?
    private weak var presentingWindow: NSWindow?

    func show(_ dialog: Dialog) {
        if current == nil, dialog.impact != nil || dialog.isModal {
            presentingWindow = NSApp?.keyWindow
            previousResponder = presentingWindow?.firstResponder
        }
        current = dialog
    }

    func restoreFocus() {
        guard current == nil, let previousResponder else { return }
        presentingWindow?.makeFirstResponder(previousResponder)
        self.previousResponder = nil
        presentingWindow = nil
    }

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
    @FocusState private var focusedAction: UUID?

    var body: some View {
        if let dialog = presenter.current {
            ZStack {
                // The backdrop both dims the app and swallows clicks meant for it.
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { presenter.dismiss() }

                if dialog.impact != nil {
                    GeometryReader { geometry in
                        ImpactDialogCard(dialog: dialog, maxHeight: max(0, geometry.size.height - 32))
                            .frame(width: min(dialog.width, max(0, geometry.size.width - 32)))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .id(dialog.id)
                } else {
                    card(dialog)
                        .frame(width: dialog.width)
                        .id(dialog.id)
                        .transition(.fadeIn)
                }
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
                        .focused($focusedAction, equals: action.id)
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(dialog.isModal && focusedAction == action.id ? Theme.accent : .clear,
                                    lineWidth: 2))
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .floatingCard(cornerRadius: 14)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(dialog.isModal ? [.isModal] : [])
        .accessibilityLabel(dialog.title)
        .onKeyPress(keys: [.tab]) { press in
            guard dialog.isModal else { return .ignored }
            let actions = dialog.actions.filter { $0.isEnabled() }
            guard !actions.isEmpty else { return .handled }
            let index = actions.firstIndex { $0.id == focusedAction } ?? 0
            let step = press.modifiers.contains(.shift) ? -1 : 1
            focusedAction = actions[(index + step + actions.count) % actions.count].id
            return .handled
        }
        .onAppear {
            if dialog.isModal { focusedAction = dialog.actions.first { $0.kind == .cancel }?.id }
        }
        .onDisappear { if dialog.isModal { presenter.restoreFocus() } }
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

private struct ImpactDialogCard: View {
    let dialog: Dialog
    let maxHeight: CGFloat
    @Environment(DialogPresenter.self) private var presenter
    @FocusState private var focusedAction: UUID?

    private var compact: Bool { dialog.impact?.compact == true }

    var body: some View {
        VStack(spacing: 0) {
            MenuContentScrollView(maxHeight: max(0, maxHeight - (compact ? 56 : 76))) {
                VStack(alignment: .leading, spacing: compact ? 14 : 20) {
                    if let impact = dialog.impact {
                        if let subject = impact.subject {
                            HStack(spacing: compact ? 8 : 10) {
                                ProjectTileView(name: subject.name,
                                                tint: subject.kind == .workspace
                                                    ? Theme.workspaceTint
                                                    : Theme.projectTint(for: subject.name),
                                                side: compact ? 22 : 29,
                                                dashed: subject.kind == .task,
                                                stacked: subject.kind == .workspace)
                                    .accessibilityHidden(true)
                                Text(subject.name)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
                            Text(dialog.title)
                                .font(.serif(compact ? 17 : 26, compact ? .semibold : .regular))
                                .accessibilityAddTraits(.isHeader)
                            if let message = dialog.message {
                                Text(message)
                                    .font(.system(size: compact ? 12 : 13))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        VStack(spacing: 0) {
                            ForEach(Array(impact.rows.enumerated()), id: \.offset) { _, row in
                                Rectangle().fill(Theme.border).frame(height: 1)
                                HStack(alignment: compact ? .top : .center, spacing: compact ? 10 : 14) {
                                    Image(systemName: row.kept ? "checkmark" : "minus")
                                        .font(.system(size: compact ? 13 : 19, weight: .medium))
                                        .foregroundStyle(row.kept ? Theme.accent : Theme.deletion)
                                        .frame(width: compact ? 22 : 34, height: compact ? 22 : 34)
                                        .background(row.kept ? Theme.accent.opacity(0.10) : Theme.warningBackground,
                                                    in: Circle())
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(row.title).font(.system(size: 13, weight: .medium))
                                        Text(row.detail)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, compact ? 12 : 17)
                                .accessibilityElement(children: .combine)
                            }
                            Rectangle().fill(Theme.border).frame(height: 1)
                        }
                        if let warning = impact.warning {
                            Label(warning, systemImage: "info.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.deletion)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(compact ? 20 : 28)
            }
            .scrollBounceBehavior(.basedOnSize)
            HStack(spacing: compact ? 8 : 9) {
                Spacer(minLength: 0)
                ForEach(dialog.actions.reversed()) { action in
                    ActionButton(title: action.label,
                                 tone: action.kind == .destructive ? .danger : .sunken,
                                 height: compact ? 32 : 36, size: 12,
                                 keyboardShortcut: action.kind == .cancel ? .cancelAction : .defaultAction) {
                        presenter.run(action)
                    }
                    .disabled(!action.isEnabled())
                    .focused($focusedAction, equals: action.id)
                    .overlay(RoundedRectangle(cornerRadius: 9)
                        .stroke(focusedAction == action.id ? Theme.accent : .clear, lineWidth: 2)
                        .padding(-3))
                }
            }
            .padding(.horizontal, compact ? 16 : 20)
            .padding(.vertical, compact ? 12 : 20)
            .background(Theme.field)
        }
        .clipShape(RoundedRectangle(cornerRadius: compact ? 14 : 18))
        .floatingCard(cornerRadius: compact ? 14 : 18)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(dialog.title)
        .accessibilityValue(dialog.message ?? "")
        .onKeyPress(keys: [.tab]) { press in
            let actions = dialog.actions.reversed().filter { $0.isEnabled() }
            guard !actions.isEmpty else { return .handled }
            let index = actions.firstIndex { $0.id == focusedAction } ?? 0
            let step = press.modifiers.contains(.shift) ? -1 : 1
            focusedAction = actions[(index + step + actions.count) % actions.count].id
            return .handled
        }
        .onExitCommand { presenter.dismiss() }
        .onAppear {
            focusedAction = dialog.actions.first { $0.kind == .cancel }?.id
        }
        .onDisappear { presenter.restoreFocus() }
    }
}
