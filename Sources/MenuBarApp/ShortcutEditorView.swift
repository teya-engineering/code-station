import SwiftUI

// Asking for a shortcut: what it is, a name, an optional icon, the command or prompt it
// carries, and whether every project can use it. The screen it was opened from supplies
// the private scope, while sharing deliberately moves the shortcut to the Mac so every
// project can see the same saved shortcut.
struct ShortcutEditorRequest: Identifiable {
    let id = UUID()
    var shortcut: Shortcut?
    // The project a new shortcut belongs to, and nil for one being saved on the Mac's
    // own list. An edit keeps whatever the shortcut already had.
    var projectID: UUID?
    // Named so the sheet can say where the shortcut lands instead of asking.
    var projectName: String?
    // What a new shortcut starts as, for the menu that offers each kind on its own.
    var kind: ShortcutKind = .command
    // A command the reader has already seen run, so promoting it is a naming job rather
    // than a retype.
    var text: String?
}

struct ShortcutEditorView: View {
    @Environment(\.dismiss) private var dismiss

    private let request: ShortcutEditorRequest
    private let id: Shortcut.ID
    private let projectIDWhenPrivate: UUID?
    private let editing: Bool
    private let onSave: (Shortcut) -> Void

    @State private var name: String
    @State private var text: String
    @State private var kind: ShortcutKind
    @State private var icon: String?
    @State private var availableInAllProjects: Bool

    init(request: ShortcutEditorRequest, onSave: @escaping (Shortcut) -> Void) {
        let shortcut = request.shortcut
        self.request = request
        id = shortcut?.id ?? UUID()
        projectIDWhenPrivate = shortcut?.projectID ?? request.projectID
        editing = shortcut != nil
        self.onSave = onSave
        _name = State(initialValue: shortcut?.name ?? "")
        _text = State(initialValue: shortcut?.text ?? request.text ?? "")
        _kind = State(initialValue: shortcut?.kind ?? request.kind)
        _icon = State(initialValue: shortcut?.icon)
        _availableInAllProjects = State(
            initialValue: shortcut?.availableInAllProjects ?? false)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                Text(editing ? "Edit shortcut" : "Add shortcut")
                    .font(.serif(24, .semibold))

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("KIND")
                    HStack(spacing: 7) {
                        ForEach(ShortcutKind.allCases) { option in
                            ChoicePill(title: option.title, selected: kind == option) {
                                kind = option
                            }
                        }
                    }
                    Text(kindDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("NAME")
                    TextField(kind == .command ? "Local service" : "Unfinished work",
                              text: $name)
                        .appTextField(cornerRadius: 9)
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("ICON")
                    ShortcutIconPicker(symbol: $icon)
                    Text(iconDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(kind == .command ? "COMMAND" : "PROMPT")
                    TextEditor(text: $text)
                        .font(kind == .command ? .mono(12) : .system(size: 12))
                        .scrollContentBackground(.hidden)
                        .padding(7)
                        .frame(height: 140)
                        .fieldSurface(cornerRadius: 9)

                    Toggle(isOn: $availableInAllProjects) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Available in all projects")
                                .font(.system(size: 12, weight: .semibold))
                            if let availabilityDetail {
                                Text(availabilityDetail)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.appCheckbox)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .cardSurface(cornerRadius: 9)

                    Text(landsIn)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(28)

            SheetFooter(primary: SheetAction(title: editing ? "Save" : "Add",
                                             enabled: !name.isBlank && !text.isBlank,
                                             shortcut: .defaultAction, action: save),
                        dismiss: { dismiss() })
        }
        .frame(width: 520)
        .background(Theme.background)
    }

    private func save() {
        onSave(Shortcut(id: id, name: name.trimmed,
                        text: text.trimmed,
                        kind: kind,
                        icon: icon,
                        projectID: availableInAllProjects ? nil : projectIDWhenPrivate,
                        availableInAllProjects: availableInAllProjects))
        dismiss()
    }

    private var kindDetail: String {
        switch kind {
        case .command:
            "A shell command, offered as a chip beside the composer."
        case .prompt:
            "A prompt for the agent, offered on the icon rail above the session."
        }
    }

    private var iconDetail: String {
        kind == .command
            ? "Drawn on the chip beside the name. A shortcut needs no icon."
            : "The rail has room for the glyph alone, so a prompt with no icon gets a generic one."
    }

    // A project-only shortcut needs no note: the text below already says where it lands.
    private var availabilityDetail: String? {
        if availableInAllProjects {
            return kind == .command
                ? "Shown in every project and run from the project using it."
                : "Shown in every session, whichever project it belongs to."
        }
        if request.projectName != nil {
            return nil
        }
        return "Turn this on to use the shortcut from any project."
    }

    private var landsIn: String {
        guard kind == .command else {
            return "Sent to the agent in the session you are looking at, as though you had "
                + "typed it. A session already working queues it behind the turn it is on."
        }
        let place = if availableInAllProjects {
            "the project folder or session worktree that runs it"
        } else if let projectName = request.projectName {
            "the worktree of whichever \(projectName) session runs it, "
                + "or the project folder when there is none"
        } else {
            "your home folder"
        }
        return "Runs with zsh in \(place). Output is captured, so the run can report how it ended."
    }
}
