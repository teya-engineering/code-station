import SwiftUI

// An ad-hoc task has no existing folder to pick. Its name is kept separate from the
// generated directory name so any useful human title remains safe as a filesystem path.
struct NewAdHocTaskView: View {
    let onCreate: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text("New ad-hoc task")
                    .font(.serif(22, .semibold))
                Text("Give the task a name. It starts in its own empty folder.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Text("NAME")
                        .font(.mono(10, .semibold))
                        .kerning(0.6)
                        .foregroundStyle(.tertiary)
                    TextField("Task name", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .semibold))
                        .focused($nameFocused)
                        .onSubmit(create)
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
                .padding(.top, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            footer
        }
        .frame(width: 440)
        .background(Theme.background)
        .task { nameFocused = true }
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

                Button(action: create) {
                    Text("Create task")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
                .opacity(canCreate ? 1 : 0.45)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Theme.card)
        }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func create() {
        guard canCreate else { return }
        onCreate(name)
        dismiss()
    }
}
