import AppKit
import SwiftUI

// Creates a reusable group of projects. The order matters because the first selected
// project is the lead and supplies the working directory for every session.
struct NewWorkspaceView: View {
    let onCreate: (ProjectWorkspace) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(ProjectStore.self) private var store

    @State private var name = ""
    @State private var selected: [UUID] = []
    @State private var leadProjectID: UUID?

    init(initialProjectIDs: [UUID] = [], onCreate: @escaping (ProjectWorkspace) -> Void) {
        var seen: Set<UUID> = []
        let projects = initialProjectIDs.filter { seen.insert($0).inserted }
        self.onCreate = onCreate
        _selected = State(initialValue: projects)
        _leadProjectID = State(initialValue: projects.first)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text("New workspace")
                    .font(.serif(22, .semibold))
                Text("Pick the projects that get worked on together. Every session starts with all of them.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Text("NAME")
                        .font(.mono(10, .semibold))
                        .kerning(0.6)
                        .foregroundStyle(.tertiary)
                    TextField("Workspace name", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .semibold))
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
                .padding(.top, 10)
            }
            .padding(20)

            ScrollView {
                VStack(spacing: 9) {
                    ForEach(store.projects) { project in
                        projectRow(project)
                    }

                    Button(action: addFolder) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .bold))
                            Text("Add a folder that isn't a project yet")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 13)
                        .frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .frame(maxHeight: 390)

            footer
        }
        .frame(width: 650)
        .background(Theme.background)
    }

    private func projectRow(_ project: Project) -> some View {
        let isSelected = selected.contains(project.id)
        let isLead = leadProjectID == project.id
        return HStack(spacing: 12) {
            Button { toggle(project.id) } label: {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Theme.accentFill : Theme.card)
                    .frame(width: 22, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? .clear : Theme.border, lineWidth: 1.5))
                    .overlay {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            RoundedRectangle(cornerRadius: 3)
                .fill(projectColour(project.id))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(project.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if isLead {
                        Text("LEAD")
                            .font(.mono(9, .semibold))
                            .kerning(0.5)
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5)
                                .fill(Theme.accent.opacity(0.1)))
                    }
                }
                Text(project.collapsedPath)
                    .font(.mono(11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 10)

            if isSelected && !isLead {
                Button { leadProjectID = project.id } label: {
                    Text("Make lead")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 9)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 62)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .stroke(isSelected ? Theme.accent : Theme.border,
                    lineWidth: isSelected ? 1.5 : 1))
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.hairline)
            HStack(spacing: 12) {
                Text("Projects can belong to several workspaces.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
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
                    Text("Create")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accentFill))
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
            && selected.count >= 2
            && leadProjectID != nil
    }

    private func toggle(_ id: UUID) {
        if let index = selected.firstIndex(of: id) {
            selected.remove(at: index)
            if leadProjectID == id { leadProjectID = selected.first }
        } else {
            selected.append(id)
            if leadProjectID == nil { leadProjectID = id }
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Folder"
        panel.message = "Pick a folder to add to this workspace."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let added = store.addProject(at: url)
        guard let id = added?.id ?? store.selectedProjectID else { return }
        if !selected.contains(id) { selected.append(id) }
        if leadProjectID == nil { leadProjectID = id }
    }

    private func create() {
        guard let leadProjectID,
              let workspace = store.addWorkspace(name: name, projectIDs: selected,
                                                 leadProjectID: leadProjectID) else { return }
        onCreate(workspace)
        dismiss()
    }

    private func projectColour(_ id: UUID) -> Color {
        let colours = [Theme.accent, Theme.secret, Theme.attention, Theme.addition]
        let value = id.uuidString.utf8.reduce(0) { ($0 + Int($1)) % colours.count }
        return colours[value]
    }
}
