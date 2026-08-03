import AppKit
import SwiftUI

// The left navigation for the whole window: every project with its sessions, plus a
// pinned entry for the original MCP config manager.
struct AppSidebar: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner

    // A project is expanded by default while it is the selected one; anything the user
    // clicks on the disclosure arrow is remembered here and wins over that default.
    @State private var expansion: [UUID: Bool] = [:]
    @State private var renamingID: UUID?
    @State private var pendingRemoval: Project?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
            projectList
            Spacer(minLength: 0)
            bottomBar
        }
        .frame(width: 292)
        .background(Theme.sidebar)
        .confirmationDialog(
            "Remove \(pendingRemoval?.name ?? "project")?",
            isPresented: Binding(get: { pendingRemoval != nil },
                                 set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { project in
            Button("Remove project", role: .destructive) { store.removeProject(project.id) }
            Button("Cancel", role: .cancel) {}
        } message: { project in
            Text("This drops its \(store.sessions(for: project.id).count) session(s) from the app. The folder itself stays on disk.")
        }
    }

    // MARK: - Heading

    private var heading: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Projects").font(.serif(24, .semibold))
            Text("\(busyCount) of \(store.sessions.count) running")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    private var busyCount: Int {
        store.sessions.filter { runner.state($0.id).isBusy }.count
    }

    // MARK: - Projects

    @ViewBuilder private var projectList: some View {
        if store.projects.isEmpty {
            Text("No projects yet. Add a folder and Claude Code will run right inside it.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.projects) { project in
                        projectSection(project)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder private func projectSection(_ project: Project) -> some View {
        let expanded = isExpanded(project)
        let sessions = store.sessions(for: project.id)

        ProjectHeaderRow(
            project: project,
            isExpanded: expanded,
            isMissing: store.isMissing(project),
            hasBusySession: sessions.contains { runner.state($0.id).isBusy },
            isRenaming: renamingID == project.id,
            onToggle: { expansion[project.id] = !expanded },
            onNewSession: { store.newSession(in: project.id) },
            onRename: { name in
                store.renameProject(project.id, to: name)
                renamingID = nil
            },
            onCancelRename: { renamingID = nil }
        )
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectedProjectID = project.id
            expansion[project.id] = !expanded
        }
        .contextMenu {
            Button("Rename…") { renamingID = project.id }
            Button("New session") { store.newSession(in: project.id) }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([project.url])
            }
            Button("Open in Terminal") { openInTerminal(project) }
            Divider()
            Button("Remove project", role: .destructive) { pendingRemoval = project }
        }

        if expanded {
            ForEach(sessions) { session in
                SessionRow(session: session,
                           selected: isSelected(session),
                           busy: runner.state(session.id).isBusy)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        store.selectedProjectID = project.id
                        store.selection = .session(session.id)
                    }
                    .contextMenu {
                        Button("Delete session", role: .destructive) {
                            store.removeSession(session.id)
                        }
                    }
            }
            NewSessionRow { store.newSession(in: project.id) }
        }
    }

    private func isExpanded(_ project: Project) -> Bool {
        expansion[project.id] ?? (project.id == store.selectedProject?.id)
    }

    private func isSelected(_ session: ChatSession) -> Bool {
        if case .session(let id) = store.selection { return id == session.id }
        return false
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: addProject) {
                Text("+ Add project")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.88)))
            }
            .buttonStyle(.plain)
            .padding(16)

            Divider().overlay(Theme.hairline)

            mcpRow
                .contentShape(Rectangle())
                .onTapGesture { store.selection = .mcpServers }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, runner.available ? 12 : 6)

            if !runner.available {
                Text("Claude Code was not found on PATH.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
    }

    private var mcpRow: some View {
        let selected = { if case .mcpServers = store.selection { true } else { false } }()
        return HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 13))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
            Text("MCP Servers")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Color.black.opacity(0.06) : .clear))
    }

    // MARK: - Actions

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        panel.message = "Pick the folder Claude Code should work in."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // A folder that is already a project comes back as nil, and the store has
        // pointed itself at the existing one, so there is nothing to report.
        let added = store.addProject(at: url)
        if let id = added?.id ?? store.selectedProjectID { expansion[id] = true }
    }

    // Opening a folder on its own would just reveal it in Finder, so name the app.
    private func openInTerminal(_ project: Project) {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([project.url],
                                withApplicationAt: terminal,
                                configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - Rows

private struct ProjectHeaderRow: View {
    let project: Project
    let isExpanded: Bool
    let isMissing: Bool
    let hasBusySession: Bool
    let isRenaming: Bool
    let onToggle: () -> Void
    let onNewSession: () -> Void
    let onRename: (String) -> Void
    let onCancelRename: () -> Void

    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                if isRenaming {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .focused($focused)
                        .onSubmit { onRename(draft) }
                        .onExitCommand(perform: onCancelRename)
                } else {
                    HStack(spacing: 5) {
                        if isMissing {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Text(project.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Text(project.collapsedPath)
                    .font(.mono(11))
                    .foregroundStyle(isMissing ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            // Collapsed projects would otherwise give no sign that work is running.
            if hasBusySession, !isExpanded {
                Circle().fill(Theme.dotOn).frame(width: 7, height: 7)
            }
            if hovering, !isRenaming {
                Button(action: onNewSession) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("New session")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(hovering ? Color.black.opacity(0.03) : .clear))
        .onHover { hovering = $0 }
        .onChange(of: isRenaming, initial: true) { _, renaming in
            guard renaming else { return }
            draft = project.name
            focused = true
        }
    }
}

private struct SessionRow: View {
    let session: ChatSession
    let selected: Bool
    let busy: Bool

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(busy ? Theme.dotOn : Theme.dotOff)
                .frame(width: 7, height: 7)
            Text(session.title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Text(session.createdAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.black.opacity(0.06) : .clear))
        .padding(.leading, 18)
    }
}

private struct NewSessionRow: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                Text("New session").font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Color.black.opacity(0.04) : .clear))
            .padding(.leading, 18)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
