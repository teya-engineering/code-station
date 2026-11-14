import SwiftUI

// What the prompt asks for, beside it. Rows appear and disappear as the prompt is written,
// because the prompt is where a hole is declared: this is where each hole is dressed up,
// not where it is created. A row left untouched is a required line of text, which is what
// most holes want to be. The card stays even with no holes, to say how to make one.
struct TaskInputsCard: View {
    let inputs: [TaskInput]
    let onChange: (TaskInput) -> Void

    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Inputs")
                .font(Typography.body.weight(.semibold))

            if inputs.isEmpty {
                Text("None yet. Write \(Text(verbatim: "{{ticket}}").font(Typography.code).foregroundStyle(Theme.accent)) in the prompt and every run asks for a ticket first.")
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Asked for before each run, in the order they appear.")
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: Space.sm) {
                    ForEach(inputs, id: \.name) { input in
                        row(input)
                    }
                }
                .padding(.top, Space.xs)
            }
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: Radius.floating)
        .smoothlyResizes(when: inputs.map(\.name))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inputs")
    }

    private func row(_ input: TaskInput) -> some View {
        let key = TaskTemplate.key(input.name)
        let open = expanded.contains(key)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if open { expanded.remove(key) } else { expanded.insert(key) }
            } label: {
                HStack(spacing: Space.md) {
                    Text("{{\(input.name)}}")
                        .font(Typography.data)
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                        .padding(.horizontal, Space.xs)
                        .padding(.vertical, Space.xxs)
                        .background(RoundedRectangle(cornerRadius: Radius.tag).fill(Theme.field))
                        .layoutPriority(1)
                    Text(input.title)
                        .font(Typography.body.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(input.kind.title.lowercased() + (input.required ? "" : ", optional"))
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, Space.md)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverFill(cornerRadius: Radius.card)
            .accessibilityValue(open ? "Expanded" : "Collapsed")

            if open {
                editor(input)
                    .padding(.horizontal, Space.md)
                    .padding(.top, Space.xxs)
                    .padding(.bottom, Space.md)
                    .transition(.fadeIn)
            }
        }
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(Theme.sunken))
        .smoothlyResizes(when: "\(open):\(input.kind.rawValue)")
    }

    // One column, since the side card is too narrow to put two fields side by side.
    private func editor(_ input: TaskInput) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            field("LABEL", placeholder: input.title, text: binding(input, \.label))
            OptionMenu(caption: "KIND", value: input.kind.title) {
                TaskInput.Kind.allCases.map { kind in
                    .item(kind.title, checked: kind == input.kind) {
                        var updated = input
                        updated.kind = kind
                        onChange(updated)
                    }
                }
            }

            switch input.kind {
            case .choice:
                field("OPTIONS", placeholder: "dev, staging, production",
                      text: optionList(input),
                      note: "One line of choices, separated by commas.")
            case .toggle:
                field("WHEN ON", placeholder: "yes", text: option(input, 0))
                field("WHEN OFF", placeholder: "left out", text: option(input, 1))
            default:
                EmptyView()
            }

            if input.kind != .toggle {
                field("DEFAULT", placeholder: "Empty", text: binding(input, \.defaultValue))
                    .transition(.fadeIn)
            }
            field("HINT", placeholder: "What this is for", text: binding(input, \.hint))

            if input.kind != .toggle {
                Toggle(isOn: Binding(get: { input.required },
                                     set: { required in
                                         var updated = input
                                         updated.required = required
                                         onChange(updated)
                                     })) {
                    Text("Required")
                        .font(Typography.detail.weight(.medium))
                }
                .toggleStyle(.appSwitch)
                .transition(.fadeIn)
            }
        }
    }

    private func field(_ label: String, placeholder: String, text: Binding<String>,
                       note: String? = nil) -> some View {
        LabeledField(label, note: note) {
            TextField(placeholder, text: text)
                .appTextField(size: 12)
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
                        .map { String($0).trimmed }
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
