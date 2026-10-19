import SwiftUI
import CodeStationCore

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
                    .padding(28)
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
    @Bindable var draft: ShortcutDraft
    var locked = false
    var showsCommandOutput = false
    @ViewBuilder var commandContent: CommandContent

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("Name")
                    TextField("Local service",
                              text: $draft.value.name)
                        .appTextField(size: 14, cornerRadius: 8)
                        .accessibilityLabel("Shortcut name")
                }
                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("Icon")
                    ShortcutIconMenu(symbol: $draft.value.icon)
                }
                .frame(width: 75)
            }
            .disabled(locked)
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Command")
                TextEditor(text: $draft.value.text)
                    .font(.mono(12))
                    .scrollContentBackground(.hidden)
                    .padding(9)
                    .frame(height: 80)
                    .fieldSurface(cornerRadius: 8)
                    .accessibilityLabel("Command")
                Text(commandHelp)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .disabled(locked)
            commandContent
            ShortcutScopePicker(availableInAllProjects: $draft.value.availableInAllProjects,
                                projectName: draft.projectName)
                .disabled(locked)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heading: some View {
        Text(draft.isNew ? "Add shortcut" : "Edit shortcut")
            .font(.system(size: 17, weight: .semibold))
    }

    private var commandHelp: String {
        if showsCommandOutput { return "Run it here, or from a project using this shortcut." }
        if draft.value.availableInAllProjects {
            return "Runs with zsh in the project folder or session worktree that runs it."
        }
        if let projectName = draft.projectName {
            return "Runs with zsh in the \(projectName) session's worktree, or its project folder when there is none."
        }
        return "Runs with zsh in your home folder."
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold))
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

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: symbol ?? "slash.circle").font(.system(size: 17))
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
        }
        .foregroundStyle(Theme.accent)
        .frame(width: 75, height: 38)
        .cardSurface(cornerRadius: 8)
        .contentShape(Rectangle())
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

    @Namespace private var track

    static func narrowTitle(projectName: String?) -> String {
        projectName.map { "\($0) only" } ?? "Shortcuts window only"
    }

    static func help(availableInAllProjects: Bool, projectName: String?) -> String {
        if availableInAllProjects {
            return "Shows in every project and session. Runs in that project folder or session worktree."
        }
        if let projectName {
            return "Only \(projectName) and its sessions show it. Other projects do not."
        }
        return "Only listed here. Projects and sessions do not show it."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Show it in").font(.system(size: 12, weight: .semibold))
                .accessibilityHidden(true)
            HStack(spacing: 2) {
                pill("All projects", selected: availableInAllProjects) { availableInAllProjects = true }
                pill(Self.narrowTitle(projectName: projectName), selected: !availableInAllProjects) {
                    availableInAllProjects = false
                }
            }
            .padding(3)
            .fieldSurface(cornerRadius: 10)
            .fixedSize()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Show it in")
            Text(Self.help(availableInAllProjects: availableInAllProjects, projectName: projectName))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pill(_ title: String, selected: Bool, choose: @escaping () -> Void) -> some View {
        ChoicePill(title: title, selected: selected, thumb: track) {
            withAnimation(Motion.control) { choose() }
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
