import SwiftUI

// What the prompt asks for, listed under it. Rows appear and disappear as the prompt is
// written, because the prompt is where a hole is declared: this is where each hole is
// dressed up, not where it is created. A row left untouched is a required line of text,
// which is what most holes want to be.
struct TaskInputsCard: View {
    let inputs: [TaskInput]
    let onChange: (TaskInput) -> Void

    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionRule(title: "INPUTS") {
                Text("\(inputs.count)")
                    .font(.mono(10))
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: 8) {
                ForEach(inputs, id: \.name) { input in
                    row(input)
                }
            }
        }
    }

    private func row(_ input: TaskInput) -> some View {
        let key = TaskTemplate.key(input.name)
        let open = expanded.contains(key)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if open { expanded.remove(key) } else { expanded.insert(key) }
            } label: {
                HStack(spacing: 10) {
                    Text("{{\(input.name)}}")
                        .font(.mono(11))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
                    Text(input.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(input.kind.title.lowercased())
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if !input.required {
                        Text("optional")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                VStack(alignment: .leading, spacing: 0) {
                    Divider().overlay(Theme.hairline)
                    editor(input)
                        .padding(12)
                }
                .transition(.reveal)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
        .smoothlyResizes(when: "\(open):\(input.kind.rawValue)")
    }

    private func editor(_ input: TaskInput) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                field("LABEL", placeholder: input.title,
                      text: binding(input, \.label))
                kindMenu(input)
            }

            switch input.kind {
            case .choice:
                field("OPTIONS", placeholder: "dev, staging, production",
                      text: optionList(input),
                      note: "One line of choices, separated by commas.")
            case .toggle:
                HStack(alignment: .top, spacing: 12) {
                    field("WHEN ON", placeholder: "yes", text: option(input, 0))
                    field("WHEN OFF", placeholder: "left out", text: option(input, 1))
                }
            default:
                EmptyView()
            }

            HStack(alignment: .top, spacing: 12) {
                if input.kind != .toggle {
                    field("DEFAULT", placeholder: "empty", text: binding(input, \.defaultValue))
                        .transition(.reveal)
                }
                field("HINT", placeholder: "What this is for",
                      text: binding(input, \.hint))
            }

            if input.kind != .toggle {
                Toggle(isOn: Binding(get: { input.required },
                                     set: { required in
                                         var updated = input
                                         updated.required = required
                                         onChange(updated)
                                     })) {
                    Text("Required")
                        .font(.system(size: 12, weight: .medium))
                }
                .toggleStyle(.appSwitch)
                .transition(.reveal)
            }
        }
    }

    private func kindMenu(_ input: TaskInput) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: "KIND")
            HStack(spacing: 6) {
                Text(input.kind.title)
                    .font(.system(size: 12))
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(width: 150)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            .appMenu(matchWidth: true) {
                TaskInput.Kind.allCases.map { kind in
                    .item(kind.title, checked: kind == input.kind) {
                        var updated = input
                        updated.kind = kind
                        onChange(updated)
                    }
                }
            }
        }
    }

    private func field(_ label: String, placeholder: String, text: Binding<String>,
                       note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: label)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Editing

    // An emptied field reads as nothing saved rather than as a saved empty string, so the
    // input falls back to what it would have shown anyway.
    private func binding(_ input: TaskInput,
                         _ path: WritableKeyPath<TaskInput, String?>) -> Binding<String> {
        Binding(get: { input[keyPath: path] ?? "" },
                set: { text in
                    var updated = input
                    updated[keyPath: path] = text.isEmpty ? nil : text
                    onChange(updated)
                })
    }

    private func optionList(_ input: TaskInput) -> Binding<String> {
        Binding(get: { input.options.joined(separator: ", ") },
                set: { text in
                    var updated = input
                    updated.options = text.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    onChange(updated)
                })
    }

    // A toggle keeps its two words in the same list a choice uses, so the slot has to
    // exist before it can be typed into.
    private func option(_ input: TaskInput, _ index: Int) -> Binding<String> {
        Binding(get: { index < input.options.count ? input.options[index] : "" },
                set: { text in
                    var updated = input
                    while updated.options.count <= index { updated.options.append("") }
                    updated.options[index] = text
                    onChange(updated)
                })
    }
}
