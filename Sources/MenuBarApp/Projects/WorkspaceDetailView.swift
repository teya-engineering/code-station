import AppKit
import SwiftUI

// A workspace is both a saved group and the starting point for future sessions. This
// pane keeps its current activity beside the defaults that shape the next session.
struct WorkspaceDetailView: View {
    let workspaceID: UUID

    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(DialogPresenter.self) private var dialogs

    @State private var draftName = ""
    @State private var creatingSession: ProjectWorkspace?

    var body: some View {
        if let workspace = store.workspace(workspaceID) {
            VStack(spacing: 0) {
                header(workspace)
                content(workspace)
            }
            .background(Theme.background)
            .task(id: workspace.id) { draftName = workspace.name }
            .sheet(item: $creatingSession) { workspace in
                NewWorkspaceSessionView(workspace: workspace) { choice in
                    startSession(choice, in: workspace)
                }
                .appOverlays()
            }
        } else {
            PaneMessage(icon: "square.stack.3d.up.slash",
                        title: "This workspace is gone",
                        detail: "Choose another workspace or project from the sidebar.")
        }
    }

    private func header(_ workspace: ProjectWorkspace) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(workspace.name)
                    .font(.serif(22))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("Multi-project workspace")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            Button { creatingSession = workspace } label: {
                Label("New session", systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(hasMissingProjects(workspace))
            .opacity(hasMissingProjects(workspace) ? 0.45 : 1)
        }
        .padding(.horizontal, 20)
        .headerBand()
    }

    private func content(_ workspace: ProjectWorkspace) -> some View {
        let projects = workspace.projectIDs.compactMap(store.project)
        let sessions = store.sessions(in: workspace.id)
        let running = sessions.filter { runner.state($0.id).isBusy }.count
        let worktreeDefaults = projects.filter {
            workspace.worktreeProjectIDs.contains($0.id) && isGitRepository($0)
        }.count

        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if hasMissingProjects(workspace) { missingFolders(workspace) }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)],
                          spacing: 12) {
                    WorkspaceMetric(label: "PROJECTS", value: "\(projects.count)",
                                    detail: "1 lead · \(max(0, projects.count - 1)) attached")
                    WorkspaceMetric(label: "SESSIONS", value: "\(sessions.count)",
                                    detail: running == 0 ? "None running" : "\(running) running",
                                    tint: running > 0 ? Theme.addition : nil)
                    WorkspaceMetric(label: "WORKTREE DEFAULTS", value: "\(worktreeDefaults)",
                                    detail: "\(projects.count - worktreeDefaults) project folders")
                    WorkspaceMetric(label: "TOTAL SPEND",
                                    value: money(sessions.reduce(0) {
                                        $0 + ($1.usage?.costUSD ?? 0)
                                    }),
                                    detail: "Across workspace sessions")
                }

                projectSection(workspace, projects: projects)
                settingsSection(workspace)
                recentSessions(workspace, sessions: sessions)
            }
            .padding(20)
            .frame(maxWidth: 940, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func projectSection(_ workspace: ProjectWorkspace,
                                projects: [Project]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Projects")
                    .font(.serif(18))
                Text("\(projects.count)")
                    .font(.mono(11, .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(Color.black.opacity(0.05)))
                Spacer()
                Text("Defaults can be changed again before each session starts.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }

            LazyVStack(spacing: 10) {
                ForEach(projects) { project in
                    projectCard(project, workspace: workspace)
                }
            }
        }
    }

    private func projectCard(_ project: Project, workspace: ProjectWorkspace) -> some View {
        let lead = project.id == workspace.leadProjectID
        let missing = store.isMissing(project)
        let git = isGitRepository(project)
        let worktree = git && workspace.worktreeProjectIDs.contains(project.id)

        return VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center, spacing: 12) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.monogram(for: project.name).opacity(0.16))
                    .frame(width: 38, height: 38)
                    .overlay(
                        Text(String(project.name.prefix(1)).uppercased())
                            .font(.serif(16, .semibold))
                            .foregroundStyle(Theme.monogram(for: project.name)))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(project.name)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        if lead { projectBadge("LEAD", tint: Theme.accent) }
                        if missing { projectBadge("MISSING", tint: Theme.deletion) }
                    }
                    Text(project.path)
                        .font(.mono(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 12)

                if !missing {
                    Button { reveal(project) } label: {
                        Label("Reveal", systemImage: "folder")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 10) {
                Label(missing ? "Folder unavailable" : git ? "Git repository" : "Plain folder",
                      systemImage: missing ? "exclamationmark.triangle.fill"
                          : git ? "arrow.triangle.branch" : "folder")
                    .font(.mono(10.5, .medium))
                    .foregroundStyle(missing ? Theme.deletion : Color.secondary)

                Spacer(minLength: 12)

                if !lead {
                    Button {
                        store.setLeadProject(project.id, inWorkspace: workspace.id)
                    } label: {
                        Text("Make lead")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.card))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if git {
                    checkoutButton("Worktree", selected: worktree) {
                        store.setUsesWorktree(true, for: project.id,
                                              inWorkspace: workspace.id)
                    }
                    checkoutButton("Project folder", selected: !worktree) {
                        store.setUsesWorktree(false, for: project.id,
                                              inWorkspace: workspace.id)
                    }
                } else if !missing {
                    Text("Uses project folder")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Button {
                    store.removeProject(project.id, fromWorkspace: workspace.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(workspace.projectIDs.count <= 2)
                .opacity(workspace.projectIDs.count <= 2 ? 0.35 : 1)
                .appTooltip(workspace.projectIDs.count <= 2
                            ? "A workspace needs at least two projects"
                            : "Remove from workspace")
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(lead ? Theme.accent.opacity(0.55) : Theme.border,
                    lineWidth: lead ? 1.5 : 1))
    }

    private func projectBadge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.mono(9, .semibold))
            .kerning(0.5)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(tint.opacity(0.1)))
    }

    private func checkoutButton(_ title: String, selected: Bool,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(selected ? AnyShapeStyle(Color.white)
                                           : AnyShapeStyle(Color.secondary))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Theme.accent : Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(selected ? Color.clear : Theme.border))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func settingsSection(_ workspace: ProjectWorkspace) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Workspace settings")
                .font(.serif(18))

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("NAME")
                        .font(.mono(10, .semibold))
                        .kerning(0.6)
                        .foregroundStyle(.tertiary)
                    TextField("Workspace name", text: $draftName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5, weight: .semibold))
                        .onSubmit { saveName(workspace) }
                }
                .padding(.horizontal, 13)
                .frame(height: 52)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))

                Button { saveName(workspace) } label: {
                    Text("Save name")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(nameCanBeSaved(workspace) ? Theme.accent : Color.secondary)
                        .padding(.horizontal, 13)
                        .frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!nameCanBeSaved(workspace))
            }

            HStack(spacing: 10) {
                Text("The lead project is the working directory. Other projects are attached to the same conversation.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)

                if !attachableProjects(workspace).isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                        Text("Add project")
                            .font(.system(size: 12, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                    .contentShape(Rectangle())
                    .appMenu { attachMenu(workspace) }
                }

                Button { addFolder(to: workspace) } label: {
                    Text("Add folder…")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.025)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
    }

    @ViewBuilder private func recentSessions(_ workspace: ProjectWorkspace,
                                             sessions: [ChatSession]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent sessions")
                    .font(.serif(18))
                Spacer()
                if sessions.count > 5 {
                    Text("Showing the latest 5 of \(sessions.count)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }
            }

            if sessions.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("No sessions yet")
                        .font(.system(size: 14, weight: .semibold))
                    Text("The checkout defaults above will be preselected for the first session.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 11).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 11)
                    .stroke(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(sessions.prefix(5)) { session in
                        sessionRow(session)
                    }
                }
            }
        }
    }

    private func sessionRow(_ session: ChatSession) -> some View {
        let busy = runner.state(session.id).isBusy
        let checkouts = store.checkoutProjects(for: session)
        let worktrees = checkouts.filter { $0.worktreePath != nil }.count

        return HStack(spacing: 12) {
            Circle()
                .fill(busy ? Theme.dotOn : Theme.dotOff)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 5) {
                Text(session.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 7) {
                    Text(busy ? "Running" : "Idle")
                    Text("·")
                    Text(worktrees == 0
                         ? "Project folders"
                         : "\(worktrees) of \(checkouts.count) worktrees")
                    Text("·")
                    Text(session.lastActivity.formatted(date: .abbreviated, time: .shortened))
                }
                .font(.mono(10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 12)

            if session.summary.added > 0 || session.summary.removed > 0 {
                HStack(spacing: 5) {
                    Text("+\(session.summary.added)").foregroundStyle(Theme.addition)
                    Text("−\(session.summary.removed)").foregroundStyle(Theme.deletion)
                }
                .font(.mono(10.5, .semibold))
            }

            Button { store.selectSession(session.id) } label: {
                Text(busy ? "Open" : "Resume")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 11)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 58)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
    }

    private func missingFolders(_ workspace: ProjectWorkspace) -> some View {
        let names = workspace.projectIDs.compactMap(store.project).filter(store.isMissing).map(\.name)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Folder not found for \(names.joined(separator: ", ")). Restore it or remove it from the workspace before starting a session.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(ChatColor.warningText)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(ChatColor.warningBackground))
    }

    private func nameCanBeSaved(_ workspace: ProjectWorkspace) -> Bool {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name != workspace.name
    }

    private func saveName(_ workspace: ProjectWorkspace) {
        guard nameCanBeSaved(workspace) else { return }
        store.renameWorkspace(workspace.id, to: draftName)
        draftName = store.workspace(workspace.id)?.name ?? draftName
    }

    private func attachableProjects(_ workspace: ProjectWorkspace) -> [Project] {
        store.projects.filter { !workspace.projectIDs.contains($0.id) }
    }

    private func attachMenu(_ workspace: ProjectWorkspace) -> [MenuEntry] {
        attachableProjects(workspace).map { project in
            .item(project.name, subtitle: project.collapsedPath) {
                store.addProject(project.id, toWorkspace: workspace.id)
            }
        }
    }

    private func addFolder(to workspace: ProjectWorkspace) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Folder"
        panel.message = "Pick a folder to add to this workspace."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let added = store.addProject(at: url)
        guard let id = added?.id ?? store.selectedProjectID else { return }
        store.addProject(id, toWorkspace: workspace.id)
        store.selectWorkspace(workspace.id)
    }

    private func reveal(_ project: Project) {
        NSWorkspace.shared.activateFileViewerSelecting([project.url])
    }

    private func isGitRepository(_ project: Project) -> Bool {
        FileManager.default.fileExists(atPath: project.path + "/.git")
    }

    private func hasMissingProjects(_ workspace: ProjectWorkspace) -> Bool {
        workspace.projectIDs.compactMap(store.project).contains(where: store.isMissing)
    }

    private func money(_ amount: Double) -> String { String(format: "$%.2f", amount) }

    private func startSession(_ choice: WorkspaceSessionChoice,
                              in workspace: ProjectWorkspace) {
        Task {
            switch await SessionLifecycle.createWorkspaceSession(
                choice, in: workspace, store: store) {
            case .success:
                runner.agent = choice.agent
            case .failure(let failure):
                showCreationError(failure.message, title: failure.title)
            }
        }
    }

    private func showCreationError(_ message: String,
                                   title: String = "Could not create the session") {
        dialogs.show(Dialog(title: title, message: message,
                            actions: [.init(label: "OK", kind: .cancel)]))
    }
}

private struct WorkspaceMetric: View {
    let label: String
    let value: String
    let detail: String
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.mono(9.5, .semibold))
                .kerning(0.55)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.serif(22))
                .foregroundStyle(tint ?? Color.primary)
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 91, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.border))
    }
}
