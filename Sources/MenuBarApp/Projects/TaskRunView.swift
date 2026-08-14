import AppKit
import SwiftUI

// What a run of this task still needs before it can start: one field per hole in the
// prompt, filled in with whatever the last run used. The prompt it will send is a
// disclosure away, so a template that reads oddly once filled in can be seen before it
// goes anywhere rather than after.
struct TaskRunView: View {
    let task: Project
    let onRun: (_ values: [String: String], _ note: String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var values: [String: String] = [:]
    @State private var note = ""
    @State private var showingPrompt = false

    private var spec: TaskSpec { task.task ?? TaskSpec(prompt: "") }
    private var inputs: [TaskInput] { TaskTemplate.inputs(in: spec) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                heading
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(inputs, id: \.name) { input in
                            TaskInputField(input: input, value: binding(for: input))
                        }
                        noteField
                        promptPreview
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 380)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            footer
        }
        .frame(width: 500)
        .background(Theme.background)
        .task { start() }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Run \(task.name)")
                .font(.serif(22, .semibold))
            Text(inputs.contains(where: { !$0.required })
                ? "Fill in what this run needs. A line that only asked for something left blank is left out."
                : "Fill in what this run needs.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var noteField: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: "ANYTHING ELSE")
            TextEditor(text: $note)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .frame(minHeight: 60)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
                .overlay(alignment: .topLeading) {
                    if note.isEmpty {
                        Text("Added to the end of the prompt, for this run only.")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    private var promptPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { showingPrompt.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: showingPrompt ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                    Text(showingPrompt ? "Hide the prompt" : "Show the prompt")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Theme.accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showingPrompt {
                Text(preview.isEmpty ? "Nothing to send yet." : preview)
                    .font(.mono(11.5))
                    .foregroundStyle(preview.isEmpty ? .tertiary : .secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sunken))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
            }
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

                Button(action: run) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Run task")
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
                .disabled(!ready)
                .opacity(ready ? 1 : 0.45)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Theme.card)
        }
    }

    private var preview: String {
        var text = TaskTemplate.render(spec, values: values)
        let extra = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { text = text.isEmpty ? extra : text + "\n\n" + extra }
        return text
    }

    private var ready: Bool {
        inputs.allSatisfy { input in
            !input.required || input.isAnswered(values[TaskTemplate.key(input.name)] ?? "")
        }
    }

    // The last run is the best guess at what this one wants, so it wins over the default
    // written on the input.
    private func start() {
        guard values.isEmpty else { return }
        values = Dictionary(uniqueKeysWithValues: inputs.map { input in
            let key = TaskTemplate.key(input.name)
            return (key, spec.lastValues[key] ?? input.startingValue)
        })
    }

    private func binding(for input: TaskInput) -> Binding<String> {
        let key = TaskTemplate.key(input.name)
        return Binding(get: { values[key] ?? input.startingValue },
                       set: { values[key] = $0 })
    }

    private func run() {
        guard ready else { return }
        onRun(values, note)
        dismiss()
    }
}

// One field on the run sheet. The kind decides what it is, but every kind wears the same
// label, hint and frame so the sheet reads as one form.
private struct TaskInputField: View {
    let input: TaskInput
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                FieldLabel(text: input.title.uppercased())
                if !input.required {
                    Text("optional")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            control
            if let hint, !hint.isEmpty {
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var hint: String? { input.hint }

    @ViewBuilder private var control: some View {
        switch input.kind {
        case .text:
            TextField(input.title, text: $value)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
        case .longText:
            TextEditor(text: $value)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .frame(minHeight: 76)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
        case .choice:
            choiceControl
        case .path:
            pathControl
        case .toggle:
            Toggle(isOn: Binding(get: { value == "on" },
                                 set: { value = $0 ? "on" : "off" })) {
                Text(value == "on" ? input.onText : "Off")
                    .font(.system(size: 13))
                    .foregroundStyle(value == "on" ? Color.primary : .secondary)
                    .lineLimit(2)
            }
            .toggleStyle(.appSwitch)
        }
    }

    private var choiceControl: some View {
        HStack(spacing: 6) {
            Text(value.isEmpty ? "Choose" : value)
                .font(.system(size: 13))
                .foregroundStyle(value.isEmpty ? .tertiary : .primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
        .appMenu(matchWidth: true) {
            var entries: [MenuEntry] = input.options.map { option in
                .item(option, checked: option == value) { value = option }
            }
            if !input.required {
                entries.insert(.item("Leave it out", checked: value.isEmpty) { value = "" },
                               at: 0)
                entries.insert(.separator, at: 1)
            }
            return entries
        }
    }

    private var pathControl: some View {
        HStack(spacing: 8) {
            Text(value.isEmpty ? "Nothing chosen" : value.abbreviatedPath)
                .font(.mono(11.5))
                .foregroundStyle(value.isEmpty ? .tertiary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            ActionButton(title: "Choose", tone: .outlined, height: 26, size: 11.5,
                         action: choosePath)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
    }

    // The file chooser is the one system surface the app keeps, since picking a path
    // belongs to the Finder rather than to this window.
    private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Pick what \(input.title.lowercased()) should point at."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        value = url.path
    }
}

// The small capitals over a field, shared by the run sheet and the task screen.
struct FieldLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.mono(10, .semibold))
            .kerning(0.6)
            .foregroundStyle(.tertiary)
    }
}

extension View {
    // Both the sidebar and the task screen start runs, so each attaches the sheet the same
    // way and a task that asks for nothing never sees one.
    func taskRunSheet(_ task: Binding<Project?>,
                      run: @escaping (Project, [String: String], String) -> Void) -> some View {
        sheet(item: task) { asking in
            TaskRunView(task: asking) { values, note in
                run(asking, values, note)
            }
            .appOverlays()
        }
    }
}
