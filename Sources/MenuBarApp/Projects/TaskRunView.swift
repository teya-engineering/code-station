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
                        LabeledField("ANYTHING ELSE") {
                            AppTextEditor(text: $note,
                                          placeholder: "Added to the end of the prompt, for this run only.",
                                          minHeight: 60)
                        }
                        promptPreview
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 380)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            SheetFooter(primary: SheetAction(title: "Run task", icon: "play.fill", enabled: ready,
                                             shortcut: .defaultAction, action: run),
                        dismiss: { dismiss() })
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

    private var promptPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureHeader(isExpanded: $showingPrompt,
                             show: "Show the prompt", hide: "Hide the prompt") {
                Text(showingPrompt ? "Hide the prompt" : "Show the prompt")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Theme.accent)

            if showingPrompt {
                Text(preview.isEmpty ? "Nothing to send yet." : preview)
                    .font(.mono(11.5))
                    .foregroundStyle(preview.isEmpty ? .tertiary : .secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .surface(Theme.sunken, cornerRadius: 10)
                    .transition(.fadeIn)
            }
        }
        .smoothlyResizes(when: showingPrompt)
    }

    private var preview: String {
        var text = TaskTemplate.render(spec, values: values)
        let extra = note.trimmed
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
                SectionLabel(input.title.uppercased(), style: .field)
                if !input.required {
                    Text("optional")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            control
            if let hint = input.hint, !hint.isEmpty {
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var control: some View {
        switch input.kind {
        case .text:
            TextField(input.title, text: $value)
                .appTextField(cornerRadius: 10)
        case .longText:
            AppTextEditor(text: $value, placeholder: input.title, minHeight: 76)
        case .choice:
            OptionMenu(value: value.isEmpty ? "Choose" : value) {
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
        .fieldSurface(cornerRadius: 10)
    }

    // The shared picker asks for a file or a folder, never either, and this input takes
    // both, so the panel is set up here.
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
