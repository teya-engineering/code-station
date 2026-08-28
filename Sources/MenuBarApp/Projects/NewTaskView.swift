import SwiftUI

// Everything a new task needs before it exists: what to call it and what it runs.
struct NewTaskDraft {
    let name: String
    let prompt: String
    let runNow: Bool
}

// A task has no existing folder to pick: it starts in an empty one of its own. What it
// does have is a prompt, saved on the task so a run is one click rather than a retype.
struct NewTaskView: View {
    let onCreate: (NewTaskDraft) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var prompt = ""
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
                LabeledField("PROMPT") {
                    AppTextEditor(text: $prompt,
                                  placeholder: "What should the agent do on every run?",
                                  minHeight: 96)
                }
                timerNote
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            SheetFooter(primary: SheetAction(title: "Create and run", icon: "play.fill",
                                             enabled: canRun, shortcut: .defaultAction) {
                            create(runNow: true)
                        },
                        secondary: SheetAction(title: "Create", enabled: canCreate) {
                            create(runNow: false)
                        },
                        dismiss: { dismiss() })
        }
        .frame(width: 480)
        .background(Theme.background)
        .task { nameFocused = true }
    }

    private var nameField: some View {
        HStack(spacing: 12) {
            SectionLabel("NAME", style: .field)
            TextField("Task name", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .focused($nameFocused)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .fieldSurface(cornerRadius: 10)
    }

    private var timerNote: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "clock.arrow.2.circlepath")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 16)
            Text("You can configure a timer after creating the task, including interval "
                 + "runs, a time of day, recurrence, run limits, and confirmation.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(Theme.sunken, cornerRadius: 9)
    }

    private var canCreate: Bool { !name.isBlank }

    // Running straight away only makes sense once there is a prompt to send.
    private var canRun: Bool { canCreate && !prompt.isBlank }

    private func create(runNow: Bool) {
        guard canCreate, !runNow || canRun else { return }
        onCreate(NewTaskDraft(name: name, prompt: prompt, runNow: runNow))
        dismiss()
    }
}
