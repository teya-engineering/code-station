import AppKit
import SwiftUI
import CodeStationCore

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
    // The content draws the whole card, its title and buttons included, for a dialog
    // whose header or footer follows what happens inside it. The title is still what a
    // screen reader hears.
    var framesItself = false
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

    // Takes a question away once it no longer needs an answer, without running its cancel.
    func withdraw(_ id: Dialog.ID) {
        guard current?.id == id else { return }
        current = nil
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedAction: UUID?

    // The backdrop and the card come and go as separate layers, so a dialog opened from
    // another dialog's button swaps the card while the dimmed app stays dimmed.
    var body: some View {
        ZStack {
            if presenter.current != nil {
                // The backdrop both dims the app and swallows clicks meant for it.
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { presenter.dismiss() }
                    .transition(.dialogBackdrop(reduceMotion: reduceMotion))
            }

            if let dialog = presenter.current {
                Group {
                    if dialog.impact != nil {
                        GeometryReader { geometry in
                            ImpactDialogCard(dialog: dialog, maxHeight: max(0, geometry.size.height - 32))
                                .frame(width: min(dialog.width, max(0, geometry.size.width - 32)))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else if dialog.framesItself, let content = dialog.content {
                        content
                            .frame(width: dialog.width)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .floatingCard(cornerRadius: 14)
                            .accessibilityElement(children: .contain)
                            .accessibilityAddTraits(.isModal)
                            .accessibilityLabel(dialog.title)
                    } else {
                        card(dialog)
                            .frame(width: dialog.width)
                    }
                }
                .id(dialog.id)
                .transition(.dialogCard(reduceMotion: reduceMotion))
            }
        }
        .smoothlyResizes(when: presenter.current?.id)
    }

    // The card reads its parts out in order once it has arrived: the question, what it
    // is about, then whatever else it shows. The buttons come early so the way out is
    // there almost at once.
    private func card(_ dialog: Dialog) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(dialog.title)
                    .font(.serif(17, .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .arrives(after: 0.05, rising: 4)
                if let message = dialog.message {
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .arrives(after: 0.09, rising: 4)
                }
                if let content = dialog.content {
                    content
                        .arrives(after: 0.13, rising: 4)
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
            .arrives(after: 0.06, animation: .easeOut(duration: 0.16))
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

    // When each row starts to arrive. Rows follow 70 ms apart, and a long list closes the
    // gap so the whole of it has landed within about half a second.
    private func rowStart(_ index: Int) -> Double {
        let rows = max(dialog.impact?.rows.count ?? 0, 1)
        return 0.18 + Double(index) * min(0.07, 0.27 / Double(rows))
    }

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
                            .arrives(after: 0.05, rising: 4, animation: .easeOut(duration: 0.18))
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
                        .arrives(after: 0.09, rising: 4)
                        VStack(spacing: 0) {
                            ForEach(Array(impact.rows.enumerated()), id: \.offset) { index, row in
                                let start = rowStart(index)
                                Rectangle().fill(Theme.border).frame(height: 1)
                                    .draws(after: start)
                                HStack(alignment: compact ? .top : .center, spacing: compact ? 10 : 14) {
                                    Image(systemName: row.kept ? "checkmark" : "minus")
                                        .font(.system(size: compact ? 13 : 19, weight: .medium))
                                        .foregroundStyle(row.kept ? Theme.accent : Theme.deletion)
                                        .frame(width: compact ? 22 : 34, height: compact ? 22 : 34)
                                        .background(row.kept ? Theme.accent.opacity(0.10) : Theme.warningBackground,
                                                    in: Circle())
                                        .accessibilityHidden(true)
                                        .arrives(after: start + 0.04, growing: 0.5, animation: Motion.pop)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(row.title).font(.system(size: 13, weight: .medium))
                                        Text(row.detail)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                    }
                                    .arrives(after: start + 0.06, sliding: 6, animation: .easeOut(duration: 0.22))
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, compact ? 12 : 17)
                                .accessibilityElement(children: .combine)
                            }
                            Rectangle().fill(Theme.border).frame(height: 1)
                                .draws(after: rowStart(impact.rows.count))
                        }
                        if let warning = impact.warning {
                            Label(warning, systemImage: "info.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.deletion)
                                .arrives(after: rowStart(impact.rows.count) + 0.06)
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
            .arrives(after: 0.06, animation: .easeOut(duration: 0.16))
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

// A dialog's card arrives a little below and a hair smaller than its place, and rises into
// it. It leaves with a short fade and the faintest shrink, and nothing inside it is staged
// on the way out. For anyone who asked for less motion, both become a plain crossfade.
extension AnyTransition {
    @MainActor
    static func dialogCard(reduceMotion: Bool) -> AnyTransition {
        if reduceMotion {
            return .asymmetric(insertion: .opacity.animation(.easeInOut(duration: 0.15)),
                               removal: .opacity.animation(.easeInOut(duration: 0.12)))
        }
        return .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.12))
                .combined(with: .scale(scale: 0.985).combined(with: .offset(y: 6)).animation(Motion.arrive)),
            removal: .opacity.combined(with: .scale(scale: 0.98)).animation(Motion.leave))
    }

    @MainActor
    static func dialogBackdrop(reduceMotion: Bool) -> AnyTransition {
        if reduceMotion {
            return .asymmetric(insertion: .opacity.animation(.easeInOut(duration: 0.15)),
                               removal: .opacity.animation(.easeInOut(duration: 0.12)))
        }
        return .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.18)),
                           removal: .opacity.animation(.easeIn(duration: 0.16).delay(0.02)))
    }
}

// One part of a dialog taking its place after the card has arrived. The part is laid out
// from the first frame, so nothing around it moves and its buttons and keys work at once;
// only how it looks catches up.
private struct Arrival: ViewModifier {
    let delay: Double
    let rise: CGFloat
    let slide: CGFloat
    let scale: CGFloat
    let animation: Animation

    @State private var arrived = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let shown = arrived || reduceMotion
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : scale)
            .offset(x: shown ? 0 : -slide, y: shown ? 0 : rise)
            .onAppear { withAnimation(animation.delay(delay)) { arrived = true } }
    }
}

// A dividing rule drawing itself from the leading edge.
private struct RuleDraw: ViewModifier {
    let delay: Double

    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // Never a zero scale: a singular transform can hand AppKit a NaN frame.
        content
            .scaleEffect(x: drawn || reduceMotion ? 1 : 0.01, y: 1, anchor: .leading)
            .onAppear { withAnimation(Motion.draw.delay(delay)) { drawn = true } }
    }
}

// Only for plain SwiftUI content: a scale on a view that hosts AppKit, such as an
// `ActionButton` or anything with a tooltip or a hover lift, can crash its layout.
private extension View {
    func arrives(after delay: Double, rising rise: CGFloat = 0, sliding slide: CGFloat = 0,
                 growing scale: CGFloat = 1, animation: Animation = .easeOut(duration: 0.2)) -> some View {
        modifier(Arrival(delay: delay, rise: rise, slide: slide, scale: scale, animation: animation))
    }

    func draws(after delay: Double) -> some View {
        modifier(RuleDraw(delay: delay))
    }
}
