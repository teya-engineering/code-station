import SwiftUI

// Asking for a shortcut. Two places open it: the shortcuts sheet, where nothing is known
// about what the shortcut is for, and a session, which already knows the project and the
// folder in front of you and hands both over as the starting point.
struct ShortcutEditorRequest: Identifiable {
    let id = UUID()
    var shortcut: CommandShortcut?
    // Filled in for a new shortcut opened from somewhere that knows where it belongs.
    var projectID: UUID?
    var location: ShortcutLocation = .mac
    // A command the reader has already seen run, so promoting it is a naming job rather
    // than a retype.
    var command: String?
}

struct ShortcutEditorView: View {
    @Environment(ProjectStore.self) private var projects
    @Environment(\.dismiss) private var dismiss

    private let id: CommandShortcut.ID
    private let editing: Bool
    private let onSave: (CommandShortcut) -> Void

    @State private var name: String
    @State private var command: String
    @State private var location: ShortcutLocation
    @State private var projectID: UUID?

    init(request: ShortcutEditorRequest, onSave: @escaping (CommandShortcut) -> Void) {
        let shortcut = request.shortcut
        id = shortcut?.id ?? UUID()
        editing = shortcut != nil
        self.onSave = onSave
        _name = State(initialValue: shortcut?.name ?? "")
        _command = State(initialValue: shortcut?.command ?? request.command ?? "")
        _location = State(initialValue: shortcut?.location ?? request.location)
        _projectID = State(initialValue: shortcut?.projectID ?? request.projectID)
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
                    .frame(height: 110)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
                Text("Runs with zsh. Output is captured, so the run can report how it ended.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            runsIn

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
                    onSave(CommandShortcut(id: id, name: trimmedName, command: trimmedCommand,
                                           projectID: projectID, location: location))
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
        .frame(width: 560)
        .background(Theme.background)
    }

    // MARK: - Where it runs

    private var runsIn: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "RUNS IN")
            HStack(alignment: .top, spacing: 10) {
                ForEach(ShortcutLocation.allCases, id: \.self) { option in
                    LocationCard(title: option.title,
                                 detail: detail(for: option),
                                 selected: location == option) {
                        location = option
                        if option != .mac, projectID == nil {
                            projectID = candidateProjects.first?.id
                        }
                    }
                    .disabled(option != .mac && candidateProjects.isEmpty)
                    .opacity(option != .mac && candidateProjects.isEmpty ? 0.4 : 1)
                }
            }
            // Which project the last two cards are talking about. It stays out of the way
            // when the folder is already decided, which is every Mac shortcut.
            if location != .mac, candidateProjects.count > 1 {
                projectPicker
            }
        }
    }

    private func detail(for option: ShortcutLocation) -> String {
        switch option {
        case .mac:
            return "Your home directory"
        case .projectFolder:
            return selectedProject.map { "Always the main \($0.name) checkout" }
                ?? "The main checkout of a project"
        case .activeWorkspace:
            return "The worktree the session in use created - else the project folder"
        }
    }

    private var projectPicker: some View {
        HStack(spacing: 8) {
            Text("Project")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            HStack(spacing: 7) {
                ProjectDot(tint: Theme.projectTint(for: selectedProject?.name ?? ""))
                Text(selectedProject?.name ?? "Choose a project")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            .appMenu {
                candidateProjects.map { project in
                    .item(project.name, checked: project.id == projectID) {
                        projectID = project.id
                    }
                }
            }
            Spacer()
        }
    }

    // Ad-hoc tasks live in a private folder the app made for one prompt, so a saved
    // command has nowhere useful to run in them.
    private var candidateProjects: [Project] {
        projects.projects.filter { $0.kind == .project }
    }

    private var selectedProject: Project? {
        projectID.flatMap { id in candidateProjects.first { $0.id == id } }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedCommand: String {
        command.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        guard !trimmedName.isEmpty, !trimmedCommand.isEmpty else { return false }
        return location == .mac || projectID != nil
    }
}

// One choice in a column of them: the ring, the words, and the sentence saying what
// picking it means. A row of these rather than a native radio group, since the whole
// point is that the explanation reads at the moment of choosing.
private struct LocationCard: View {
    let title: String
    let detail: String
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .stroke(selected ? Theme.accent : Theme.border,
                                lineWidth: selected ? 3 : 1.5)
                        .frame(width: 14, height: 14)
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Theme.accent.opacity(0.07) : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(selected ? Theme.accent.opacity(0.5) : Theme.border))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
