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
                    SectionLabel("NAME", style: .field)
                    TextField("Workspace name", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .semibold))
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .fieldSurface(cornerRadius: 10)
                .padding(.top, 10)
            }
            .padding(20)

            ScrollView {
                VStack(spacing: 9) {
                    ForEach(store.regularProjects) { project in
                        projectRow(project)
                    }

                    ActionButton(title: "Add a folder that isn't a project yet", tone: .outlined,
                                 height: 36, size: 13, icon: "plus", action: addFolder)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .frame(maxHeight: 390)

            SheetFooter(title: "Projects can belong to several workspaces.",
                        primary: SheetAction(title: "Create", enabled: canCreate,
                                             shortcut: .defaultAction, action: create),
                        dismiss: { dismiss() })
        }
        .frame(width: 650)
        .background(Theme.background)
    }

    private func projectRow(_ project: Project) -> some View {
        let isSelected = selected.contains(project.id)
        let isLead = leadProjectID == project.id
        return HStack(spacing: 12) {
            Toggle(isOn: Binding(get: { selected.contains(project.id) },
                                 set: { _ in toggle(project.id) })) {
                EmptyView()
            }
            .toggleStyle(.appCheckbox)

            ProjectDot(tint: Theme.projectTint(for: project.name), size: 10)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(project.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if isLead {
                        MonoChip(text: "LEAD", size: 9, tint: Theme.accent)
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
                ActionButton(title: "Make lead", tone: .outlined, height: 26, size: 11) {
                    leadProjectID = project.id
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 62)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .stroke(isSelected ? Theme.accent : Theme.border,
                    lineWidth: isSelected ? 1.5 : 1))
    }

    private var canCreate: Bool {
        !name.isBlank && selected.count >= 2 && leadProjectID != nil
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
        guard let url = FilePicker.chooseFolder(prompt: "Add Folder",
                                                message: "Pick a folder to add to this workspace.")
        else { return }
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
}
