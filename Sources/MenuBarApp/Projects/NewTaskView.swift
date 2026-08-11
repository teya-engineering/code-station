import SwiftUI

// Everything a new task needs before it exists: what to call it, what it runs, and
// whether it is meant to run once or over and over.
struct NewTaskDraft {
    let name: String
    let prompt: String
    let repeats: Bool
    let runNow: Bool
}

// A task has no existing folder to pick: it starts in an empty one of its own. What it
// does have is a prompt, saved on the task so a run is one click rather than a retype.
struct NewTaskView: View {
    let onCreate: (NewTaskDraft) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var prompt = ""
    @State private var repeats = true
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("New task")
                        .font(.serif(22, .semibold))
                    Text("A saved prompt in its own empty folder. Every run starts a fresh session.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                nameField
                promptField
                modePicker
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            footer
        }
        .frame(width: 480)
        .background(Theme.background)
        .task { nameFocused = true }
    }

    private var nameField: some View {
        HStack(spacing: 12) {
            Text("NAME")
                .font(.mono(10, .semibold))
                .kerning(0.6)
                .foregroundStyle(.tertiary)
            TextField("Task name", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .focused($nameFocused)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
    }

    private var promptField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PROMPT")
                .font(.mono(10, .semibold))
                .kerning(0.6)
                .foregroundStyle(.tertiary)
            TaskPromptEditor(prompt: $prompt, minHeight: 96)
        }
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ChoicePill(title: "Repeatable", selected: repeats) { repeats = true }
                ChoicePill(title: "One-off", selected: !repeats) { repeats = false }
            }
            Text(repeats
                 ? "The task keeps its Run button, and every run is a session of its own."
                 : "The task runs once. After the first run the button retires, though the run history stays.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.hairline)
            HStack(spacing: 12) {
                Spacer()
                Button { dismiss() } label: {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 18)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button { create(runNow: false) } label: {
                    Text("Create")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 18)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canCreate)
                .opacity(canCreate ? 1 : 0.45)

                Button { create(runNow: true) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Create and run")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accentFill))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(!canRun)
                .opacity(canRun ? 1 : 0.45)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Theme.card)
        }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Running straight away only makes sense once there is a prompt to send.
    private var canRun: Bool {
        canCreate && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func create(runNow: Bool) {
        guard canCreate, !runNow || canRun else { return }
        onCreate(NewTaskDraft(name: name, prompt: prompt, repeats: repeats, runNow: runNow))
        dismiss()
    }
}

// The multi-line field a task's prompt is written in, shared by the creation sheet and
// the task screen so the prompt looks the same wherever it is edited.
struct TaskPromptEditor: View {
    @Binding var prompt: String
    var minHeight: CGFloat = 96

    var body: some View {
        TextEditor(text: $prompt)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(minHeight: minHeight)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
            .overlay(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text("What should the agent do on every run?")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
    }
}
