import SwiftUI

// Asking for a shortcut: a name and a command, and nothing else. Where it runs is not a
// question, because the screen it was opened from is the answer - the Mac's list makes
// the Mac's shortcuts, a session makes its project's - so the sheet says where the
// command will run instead of asking.
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
    private let projectID: UUID?
    private let editing: Bool
    private let onSave: (CommandShortcut) -> Void

    @State private var name: String
    @State private var command: String

    init(request: ShortcutEditorRequest, onSave: @escaping (CommandShortcut) -> Void) {
        let shortcut = request.shortcut
        self.request = request
        id = shortcut?.id ?? UUID()
        projectID = shortcut?.projectID ?? request.projectID
        editing = shortcut != nil
        self.onSave = onSave
        _name = State(initialValue: shortcut?.name ?? "")
        _command = State(initialValue: shortcut?.command ?? request.command ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(editing ? "Edit shortcut" : "Add shortcut")
                .font(.serif(24, .semibold))

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "NAME")
                TextField("Local service", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "COMMAND")
                TextEditor(text: $command)
                    .font(.mono(12))
                    .scrollContentBackground(.hidden)
                    .padding(7)
                    .frame(height: 140)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
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
                                           command: trimmedCommand, projectID: projectID))
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

    // Saying where the command lands is what makes the missing question fair: the reader
    // is told the answer rather than left to guess it.
    private var runsIn: String {
        let place = request.projectName.map {
            "the worktree of whichever \($0) session runs it, or the project folder when there is none"
        } ?? "your home folder"
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
