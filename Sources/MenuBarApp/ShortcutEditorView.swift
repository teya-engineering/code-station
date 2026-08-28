import SwiftUI

// Asking for a shortcut: a name, a command, and whether every project can use it. The
// screen it was opened from supplies the private scope, while sharing deliberately moves
// the shortcut to the Mac so every project can see the same saved command.
struct ShortcutEditorRequest: Identifiable {
    let id = UUID()
    var shortcut: CommandShortcut?
    // The project a new shortcut belongs to, and nil for one being saved on the Mac's
    // own list. An edit keeps whatever the shortcut already had.
    var projectID: UUID?
    // Named so the sheet can say where the command will run instead of asking.
    var projectName: String?
    // A command the reader has already seen run, so promoting it is a naming job rather
    // than a retype.
    var command: String?
}

struct ShortcutEditorView: View {
    @Environment(\.dismiss) private var dismiss

    private let request: ShortcutEditorRequest
    private let id: CommandShortcut.ID
    private let projectIDWhenPrivate: UUID?
    private let editing: Bool
    private let onSave: (CommandShortcut) -> Void

    @State private var name: String
    @State private var command: String
    @State private var availableInAllProjects: Bool

    init(request: ShortcutEditorRequest, onSave: @escaping (CommandShortcut) -> Void) {
        let shortcut = request.shortcut
        self.request = request
        id = shortcut?.id ?? UUID()
        projectIDWhenPrivate = shortcut?.projectID ?? request.projectID
        editing = shortcut != nil
        self.onSave = onSave
        _name = State(initialValue: shortcut?.name ?? "")
        _command = State(initialValue: shortcut?.command ?? request.command ?? "")
        _availableInAllProjects = State(
            initialValue: shortcut?.availableInAllProjects ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(editing ? "Edit shortcut" : "Add shortcut")
                .font(.serif(24, .semibold))

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("NAME")
                TextField("Local service", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("COMMAND")
                TextEditor(text: $command)
                    .font(.mono(12))
                    .scrollContentBackground(.hidden)
                    .padding(7)
                    .frame(height: 140)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))

                Toggle(isOn: $availableInAllProjects) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Available in all projects")
                            .font(.system(size: 12, weight: .semibold))
                        Text(availabilityDetail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.appCheckbox)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))

                Text(runsIn)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Spacer()
                Button { dismiss() } label: {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button {
                    onSave(CommandShortcut(id: id, name: trimmedName,
                                           command: trimmedCommand,
                                           projectID: availableInAllProjects
                                               ? nil : projectIDWhenPrivate,
                                           availableInAllProjects: availableInAllProjects))
                    dismiss()
                } label: {
                    Text(editing ? "Save" : "Add")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accentFill))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.4)
            }
        }
        .padding(28)
        .frame(width: 520)
        .background(Theme.background)
    }

    private var availabilityDetail: String {
        if availableInAllProjects {
            return "Shown in every project and run from the project using it."
        }
        if let name = request.projectName {
            return "Shown only in \(name)."
        }
        return "Turn this on to use the shortcut from any project."
    }

    private var runsIn: String {
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

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedCommand: String {
        command.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && !trimmedCommand.isEmpty
    }
}
