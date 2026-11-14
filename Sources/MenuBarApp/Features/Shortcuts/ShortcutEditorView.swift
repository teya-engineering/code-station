import SwiftUI

// The opening screen supplies the private scope. Sharing moves the shortcut to the
// Mac so every project sees the same saved command.
struct ShortcutEditorRequest: Identifiable {
    let id = UUID()
    var shortcut: Shortcut?
    var name: String?
    // The project a new shortcut belongs to, and nil for one being saved on the Mac's
    // own list. An edit keeps whatever the shortcut already had.
    var projectID: UUID?
    // Named so the sheet can say where the shortcut lands instead of asking.
    var projectName: String?
    // A command the reader has already seen run, so promoting it is a naming job rather
    // than a retype.
    var text: String?
    var kind: ShortcutKind = .command
}

struct ShortcutEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(ShortcutStore.self) private var store
    @State private var draft: ShortcutDraft
    private let onSave: (Shortcut) -> Bool

    init(request: ShortcutEditorRequest, onSave: @escaping (Shortcut) -> Bool) {
        _draft = State(initialValue: ShortcutDraft(request: request))
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = store.loadError ?? store.saveError {
                WarningStrip(error, icon: "externaldrive.badge.exclamationmark")
            }
            ScrollView {
                ShortcutEditorForm(draft: draft, locked: store.isRunningAnywhere(draft.value.id))
                    .padding(Space.xxxl)
            }
            SheetFooter(primary: SheetAction(title: draft.isNew ? "Add shortcut" : "Save shortcut",
                                             enabled: draft.canSave && !store.isRunningAnywhere(draft.value.id),
                                             shortcut: KeyboardShortcut("s"), action: save),
                        dismiss: cancel)
        }
        .frame(minWidth: 390, idealWidth: 620, maxWidth: 720,
               minHeight: 300, idealHeight: 640, maxHeight: 780)
        .background(Theme.background)
        .interactiveDismissDisabled(draft.isDirty)
    }

    private func save() {
        guard draft.canSave, !store.isRunningAnywhere(draft.value.id) else { return }
        if onSave(draft.shortcut) { dismiss() }
    }

    private func cancel() {
        guard draft.isDirty else { dismiss(); return }
        dialogs.show(shortcutUnsavedDialog(draft: draft, save: save, discard: { dismiss() }))
    }
}

@MainActor
func shortcutUnsavedDialog(draft: ShortcutDraft, save: @escaping () -> Void,
                           discard: @escaping () -> Void) -> Dialog {
    Dialog(title: "Save your changes?",
           message: "You have unsaved changes to \(draft.value.name.isBlank ? "this shortcut" : draft.value.name).",
           actions: [
            .init(label: "Keep editing", kind: .cancel),
            .init(label: "Discard", handler: discard),
            .init(label: "Save", kind: .primary, handler: save,
                  isEnabled: { draft.canSave })
           ], isModal: true)
}

struct ShortcutEditorForm<CommandContent: View>: View {
    @Namespace private var typeTrack
    @FocusState private var textFocused: Bool
    @FocusState private var focusedKind: ShortcutKind?
    @Bindable var draft: ShortcutDraft
    var locked = false
    // Offered only for a saved shortcut. A new one is thrown away from the footer instead.
    var remove: (() -> Void)? = nil
    @ViewBuilder var commandContent: CommandContent

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            heading
            VStack(alignment: .leading, spacing: Space.md) {
                fieldLabel("Type")
                HStack(spacing: Space.xxs) {
                    ForEach(ShortcutKind.allCases, id: \.self) { kind in
                        ChoicePill(title: kind.title, selected: draft.value.kind == kind, thumb: typeTrack,
                                   icon: kind.icon) {
                            draft.selectKind(kind)
                            textFocused = true
                        }
                        .focused($focusedKind, equals: kind)
                        .overlay(RoundedRectangle(cornerRadius: Radius.control)
                            .stroke(focusedKind == kind ? Theme.accent : .clear, lineWidth: 2))
                    }
                }
                .padding(Space.xxs)
                .fieldSurface(cornerRadius: Radius.card)
                .fixedSize()
                .motion(Motion.control, value: draft.value.kind)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Shortcut type")
            }
            .disabled(locked)
            VStack(alignment: .leading, spacing: Space.md) {
                fieldLabel("Name")
                HStack(spacing: Space.md) {
                    ShortcutIconMenu(symbol: $draft.value.icon)
                    TextField(draft.value.kind == .prompt ? "Review changes" : "Run tests",
                              text: $draft.value.name)
                        .textFieldStyle(.plain)
                        .font(Typography.body)
                        .padding(.horizontal, Space.md)
                        .frame(height: 36)
                        .fieldSurface(cornerRadius: Radius.control)
                        .accessibilityLabel("Shortcut name")
                }
            }
            .disabled(locked)
            VStack(alignment: .leading, spacing: Space.md) {
                HStack {
                    fieldLabel(draft.value.kind.title)
                    Spacer()
                    if draft.value.kind == .prompt {
                        Text("\(draft.value.text.count) characters")
                            .font(Typography.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                }
                TextEditor(text: $draft.value.text)
                    .font(draft.value.kind == .command ? Typography.code : Typography.body)
                    .scrollContentBackground(.hidden)
                    .padding(Space.md)
                    .frame(height: draft.value.kind == .prompt ? 180 : 80)
                    .fieldSurface(cornerRadius: Radius.control)
                    .focused($textFocused)
                    .overlay(RoundedRectangle(cornerRadius: Radius.control)
                        .stroke(textFocused ? Theme.accent : .clear, lineWidth: 2))
                    .accessibilityLabel(draft.value.kind.title)
                if locked {
                    Text("Stop the command to edit it.")
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                        .transition(.fadeIn)
                }
            }
            .disabled(locked)
            if draft.value.kind == .command {
                commandContent.transition(.fadeIn)
            }
            if draft.projectIDWhenPrivate == nil {
                Label("Every project and session can use this shortcut. For one that only a single project needs, add it from that project.",
                      systemImage: "globe")
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ShortcutScopePicker(availableInAllProjects: $draft.value.availableInAllProjects,
                                    projectName: draft.projectName)
                    .disabled(locked)
            }
        }
        .motion(Motion.reveal, value: draft.value.kind)
        .motion(Motion.reveal, value: locked)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // The shortcut's own name, so the pane says which one is open while it is renamed.
    private var heading: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(draft.value.name.isBlank ? "New shortcut" : draft.value.name)
                    .font(Typography.title)
                    .foregroundStyle(draft.value.name.isBlank ? Theme.secondaryText : Color.primary)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                Text(detail)
                    .font(Typography.body)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 0)
            if let remove {
                GlyphLink(icon: "trash", title: "Remove shortcut", tint: Theme.deletion, action: remove)
                    .disabled(locked)
                    .accessibilityLabel("Remove shortcut")
            }
        }
    }

    private var detail: String {
        if draft.value.kind == .prompt { return "Fills the message input. You can edit it before sending." }
        if draft.value.availableInAllProjects {
            return "Runs with zsh in the project folder or session worktree that runs it."
        }
        if let projectName = draft.projectName {
            return "Runs with zsh in the \(projectName) session's worktree, or its project folder when there is none."
        }
        return "Runs with zsh in your home folder."
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title).font(Typography.label)
    }
}

extension ShortcutEditorForm where CommandContent == EmptyView {
    init(draft: ShortcutDraft, locked: Bool = false) {
        self.draft = draft
        self.locked = locked
        commandContent = EmptyView()
    }
}

private struct ShortcutIconMenu: View {
    @Binding var symbol: String?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: symbol ?? "slash.circle").font(.system(size: 15))
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                .opacity(0.6)
        }
        .foregroundStyle(Theme.accent)
        .frame(width: 52, height: 36)
        .surface(hovering ? Theme.border : Theme.field, cornerRadius: Radius.control)
        .contentShape(Rectangle())
        .hoverLift(hovering)
        .onPointerHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
        .appMenu {
            [.icons([MenuItem(label: "No icon", icon: "slash.circle", checked: symbol == nil,
                              handler: { symbol = nil })] + ShortcutIcon.catalogue.map { icon in
                MenuItem(label: icon.label, icon: icon.symbol, checked: symbol == icon.symbol,
                         handler: { symbol = icon.symbol })
            })]
        }
        .accessibilityLabel("Choose shortcut icon")
        .accessibilityValue(symbol.flatMap { selected in
            ShortcutIcon.catalogue.first { $0.symbol == selected }?.label
        } ?? "No icon")
    }
}

// Names both places a shortcut can show, so the narrower one is visible before anyone
// picks it. A single on/off control only names one of them.
struct ShortcutScopePicker: View {
    @Binding var availableInAllProjects: Bool
    // Set when the shortcut belongs to one project. Its narrow choice is that project,
    // not the Shortcuts window, which never lists it.
    let projectName: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var track

    static func narrowTitle(projectName: String?) -> String {
        projectName.map { "\($0) only" } ?? "Shortcuts window only"
    }

    static func help(availableInAllProjects: Bool, projectName: String?) -> String {
        if availableInAllProjects {
            return "Shows in every project and session."
        }
        if let projectName {
            return "Only \(projectName) and its sessions show it. Other projects do not."
        }
        return "Only listed here. Projects and sessions do not show it."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Show it in").font(Typography.label)
                .accessibilityHidden(true)
            HStack(spacing: Space.xxs) {
                pill("All projects", selected: availableInAllProjects) { availableInAllProjects = true }
                pill(Self.narrowTitle(projectName: projectName), selected: !availableInAllProjects) {
                    availableInAllProjects = false
                }
            }
            .padding(Space.xxs)
            .fieldSurface(cornerRadius: Radius.card)
            .fixedSize()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Show it in")
            Text(Self.help(availableInAllProjects: availableInAllProjects, projectName: projectName))
                .font(Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pill(_ title: String, selected: Bool, choose: @escaping () -> Void) -> some View {
        ChoicePill(title: title, selected: selected, thumb: track) {
            withAnimation(reduceMotion ? nil : Motion.control) { choose() }
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
