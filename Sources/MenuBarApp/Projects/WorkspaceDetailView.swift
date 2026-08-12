import AppKit
import SwiftUI

// One multi-project conversation. The structure carries the meaning: the lead project is
// the working directory and the others are indented under it, so nothing has to say in
// words which folder the agent will actually run in.
struct WorkspaceDetailView: View {
    let workspaceID: UUID

    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(TerminalStore.self) private var terminals

    @State private var draftName = ""
    @State private var creatingSession: ProjectWorkspace?
    @State private var terminalFocused = false
    // How each repository's checkout relates to the default branch and its remote, so
    // the rows can say which projects are on main and up to date. Filled in two passes:
    // the local refs first, then the same read again after a fetch.
    @State private var freshness: [UUID: GitFreshness.Report] = [:]

    private var terminalScope: TerminalScope { .project(workspaceID) }

    var body: some View {
        if let workspace = store.workspace(workspaceID) {
            VStack(spacing: 0) {
                header(workspace)
                content(workspace)
                if terminals.isOpen(terminalScope), let lead = store.project(workspace.leadProjectID) {
                    TerminalDrawer(scope: terminalScope,
                                   directory: lead.path,
                                   focusTerminal: $terminalFocused)
                }
            }
            .background(Theme.background)
            .task(id: workspace.id) { draftName = workspace.name }
            .task(id: workspace.projectIDs) { await checkFreshness(workspace) }
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

    // MARK: - Header

    private func header(_ workspace: ProjectWorkspace) -> some View {
        HStack(spacing: 12) {
            ProjectDot(tint: Theme.workspaceTint)

            // The name is edited where it is read, so renaming is not a separate block
            // further down the screen with a button of its own.
            TextField("Workspace name", text: $draftName)
                .textFieldStyle(.plain)
                .font(.serif(20, .semibold))
                .fixedSize()
                .onSubmit { saveName(workspace) }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                .overlay(alignment: .trailing) {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.trailing, 7)
                        .allowsHitTesting(false)
                }
                .appTooltip("Rename this workspace")

            MonoChip(text: "WORKSPACE · \(workspace.projectIDs.count) PROJECTS",
                     size: 10, tint: Theme.workspaceTint.ink)

            Spacer(minLength: 12)

            HStack(spacing: 12) {
                TerminalToggle(isOpen: terminals.isOpen(terminalScope)) {
                    toggleTerminal(workspace)
                }
                .disabled(hasMissingProjects(workspace))
                .opacity(hasMissingProjects(workspace) ? 0.4 : 1)

                ActionButton(title: "New session", tone: .green, size: 12) {
                    creatingSession = workspace
                }
                .disabled(hasMissingProjects(workspace))
                .opacity(hasMissingProjects(workspace) ? 0.45 : 1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
        .padding(.horizontal, 24)
        .headerBand()
    }

    // MARK: - Body

    private func content(_ workspace: ProjectWorkspace) -> some View {
        let sessions = store.sessions(in: workspace.id)
            .sorted { $0.lastActivity > $1.lastActivity }

        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if hasMissingProjects(workspace) { missingFolders(workspace) }
                projects(workspace)
                sessionList(workspace, sessions: sessions)
                defaults(workspace)
            }
            .padding(24)
        }
    }

    private func projects(_ workspace: ProjectWorkspace) -> some View {
        let lead = store.project(workspace.leadProjectID)
        let attached = workspace.projectIDs
            .filter { $0 != workspace.leadProjectID }
            .compactMap(store.project)

        return VStack(alignment: .leading, spacing: 11) {
            SectionRule(title: "PROJECTS") {
                Text("The lead project is the working directory. Defaults can still be changed per session.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 14) {
                if let lead { leadRow(lead, workspace: workspace) }

                VStack(alignment: .leading, spacing: 9) {
                    Text("ATTACHED TO THE SAME CONVERSATION")
                        .font(.mono(9, .semibold))
                        .kerning(1.2)
                        .foregroundStyle(.tertiary)
                    ForEach(attached) { project in
                        attachedRow(project, workspace: workspace)
                    }
                    addProjectRow(workspace)
                }
                .padding(.leading, 18)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Theme.border).frame(width: 1.5)
                }
                .padding(.leading, 17)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.accent.opacity(0.45), lineWidth: 1.4))
        }
    }

    private func leadRow(_ project: Project, workspace: ProjectWorkspace) -> some View {
        HStack(spacing: 13) {
            ProjectTileView(name: project.name,
                            tint: Theme.projectTint(for: project.name),
                            side: 36)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(project.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    MonoChip(text: "LEAD · WORKING DIRECTORY", size: 9, tint: Theme.accent)
                    if store.isMissing(project) {
                        MonoChip(text: "MISSING", size: 9, tint: Theme.deletion)
                    }
                    freshnessChip(project)
                }
                Text(summary(project, workspace: workspace))
                    .font(.mono(10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            checkoutControl(project, workspace: workspace, height: 30)
            GlyphButton(icon: "ellipsis")
                .appMenu { projectMenu(project, workspace: workspace, isLead: true) }
        }
    }

    private func attachedRow(_ project: Project, workspace: ProjectWorkspace) -> some View {
        HStack(spacing: 13) {
            ProjectTileView(name: project.name,
                            tint: Theme.projectTint(for: project.name),
                            side: 30)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(project.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                    if store.isMissing(project) {
                        MonoChip(text: "MISSING", size: 9, tint: Theme.deletion)
                    }
                    freshnessChip(project)
                }
                Text(summary(project, workspace: workspace))
                    .font(.mono(10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            checkoutControl(project, workspace: workspace, height: 28)
            InlineLink(title: "Make lead", size: 11.5) {
                store.setLeadProject(project.id, inWorkspace: workspace.id)
            }
            GlyphButton(icon: "xmark", side: 28) {
                store.removeProject(project.id, fromWorkspace: workspace.id)
            }
            .disabled(workspace.projectIDs.count <= 2)
            .opacity(workspace.projectIDs.count <= 2 ? 0.35 : 1)
            .appTooltip(workspace.projectIDs.count <= 2
                        ? "A workspace needs at least two projects"
                        : "Remove from workspace")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sunken))
    }

    // Answers "is this project on main and up to date?" at a glance, next to the name.
    // Nothing shows until the first report lands, so a repository never wears a verdict
    // that is really just "still reading". The tooltip carries the full sentence.
    @ViewBuilder private func freshnessChip(_ project: Project) -> some View {
        if let report = freshness[project.id] {
            Group {
                if !report.onDefaultBranch, let expected = report.defaultBranch {
                    MonoChip(text: "NOT ON \(expected.uppercased())", size: 9,
                             tint: Theme.attention)
                } else if report.behind > 0 {
                    MonoChip(text: "\(report.behind) BEHIND", size: 9, tint: Theme.attention)
                } else {
                    MonoChip(text: "UP TO DATE", size: 9, tint: Theme.addition)
                }
            }
            .appTooltip(report.explanation)
            .transition(.opacity)
        }
    }

    private func checkFreshness(_ workspace: ProjectWorkspace) async {
        let repositories = workspace.projectIDs.compactMap(store.project)
            .filter(\.isGitRepository)
            .map { (id: $0.id, path: $0.path) }
        for fetch in [false, true] {
            await GitFreshness.checkAll(repositories, fetch: fetch) { id, report in
                withAnimation(.easeOut(duration: 0.2)) { freshness[id] = report }
            }
        }
    }

    // One control rather than two competing buttons: the current mode is the label, and
    // the other is a menu away. A plain folder has no choice to offer, so it says so.
    @ViewBuilder private func checkoutControl(_ project: Project, workspace: ProjectWorkspace,
                                              height: CGFloat) -> some View {
        if project.isGitRepository {
            let worktree = workspace.worktreeProjectIDs.contains(project.id)
            ActionButton(title: worktree ? "Worktree" : "Project folder",
                         tone: .sunken, height: height, size: 11.5, disclosure: true)
                .appMenu {
                    [.item("Worktree", checked: worktree,
                           subtitle: "A checkout of its own for each session.") {
                        store.setUsesWorktree(true, for: project.id, inWorkspace: workspace.id)
                    },
                     .item("Project folder", checked: !worktree,
                           subtitle: "Work directly in the folder as it is checked out.") {
                        store.setUsesWorktree(false, for: project.id, inWorkspace: workspace.id)
                    }]
                }
        } else {
            Text("Project folder")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(height: height)
                .appTooltip("Not a git repository, so there are no worktrees to make.")
        }
    }

    private func addProjectRow(_ workspace: ProjectWorkspace) -> some View {
        HStack(spacing: 8) {
            Text("+ Add project")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("from your projects, or attach a folder…")
                .font(.mono(10.5))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Theme.border, lineWidth: 1.2))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .appMenu { addMenu(workspace) }
    }

    private func addMenu(_ workspace: ProjectWorkspace) -> [MenuEntry] {
        let projects = attachableProjects(workspace)
        let projectItems = projects.map { project in
            MenuItem(label: project.name, icon: "folder", subtitle: project.collapsedPath) {
                store.addProject(project.id, toWorkspace: workspace.id)
            }
        }

        var entries: [MenuEntry] = []
        if !projectItems.isEmpty {
            entries.append(.searchable(projectItems,
                                       prompt: "Filter projects by name or path",
                                       noResults: "No project matches this filter."))
            entries.append(.separator)
        }
        entries.append(.item("Attach a folder…", icon: "folder.badge.plus") {
            addFolder(to: workspace)
        })
        return entries
    }

    private func projectMenu(_ project: Project, workspace: ProjectWorkspace,
                             isLead: Bool) -> [MenuEntry] {
        var entries: [MenuEntry] = [
            .item("Open project") { store.selectProject(project.id) },
            .item("Reveal in Finder") { reveal(project) }
        ]
        if !isLead {
            entries.append(.item("Make lead") {
                store.setLeadProject(project.id, inWorkspace: workspace.id)
            })
        }
        if workspace.projectIDs.count > 2 {
            entries.append(.separator)
            entries.append(.item("Remove from workspace", kind: .destructive) {
                store.removeProject(project.id, fromWorkspace: workspace.id)
            })
        }
        return entries
    }

    // MARK: - Sessions

    private func sessionList(_ workspace: ProjectWorkspace,
                             sessions: [ChatSession]) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionRule(title: "SESSIONS · \(sessions.count)") {
                if !sessions.isEmpty {
                    Text(sessions.map { tone($0) }.tally)
                        .font(.mono(10))
                        .kerning(0.6)
                        .foregroundStyle(.tertiary)
                }
            }

            if sessions.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("No sessions yet")
                        .font(.system(size: 14, weight: .semibold))
                    Text("The checkout choices above are what the first session will start with.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 11).fill(Theme.sunken))
                .overlay(RoundedRectangle(cornerRadius: 11)
                    .stroke(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            } else {
                LazyVStack(spacing: 9) {
                    ForEach(sessions) { session in
                        SessionRow(session: session,
                                   tone: tone(session),
                                   branch: nil,
                                   activity: SessionActivity.line(for: session, store: store,
                                                                  runner: runner),
                                   detail: .repositories(repositories(session)),
                                   onOpen: { store.selectSession(session.id) },
                                   menu: { sessionMenu(session) })
                    }
                }
            }
        }
    }

    // One chip per repository, saying which mode that repository was opened in, because a
    // workspace session can mix worktrees and plain folders in the same conversation.
    private func repositories(_ session: ChatSession) -> [SessionRow.Repository] {
        store.checkoutProjects(for: session).compactMap { checkout in
            guard let project = store.project(checkout.projectID) else { return nil }
            let short = project.name.split(separator: " ").first.map(String.init) ?? project.name
            return SessionRow.Repository(
                id: project.id,
                label: "\(short.lowercased()) · \(checkout.worktreePath == nil ? "folder" : "worktree")",
                tint: Theme.projectTint(for: project.name))
        }
    }

    private func tone(_ session: ChatSession) -> SessionTone {
        SessionTone(session.id, store: store, runner: runner)
    }

    private func sessionMenu(_ session: ChatSession) -> [MenuEntry] {
        [
            .item("Open session") { store.selectSession(session.id) },
            .separator,
            .item("Delete session", kind: .destructive) { confirmRemove(session) }
        ]
    }

    private func confirmRemove(_ session: ChatSession) {
        let worktrees = store.checkoutProjects(for: session).compactMap(\.worktreePath)
        dialogs.show(Dialog(
            title: "Delete \"\(session.title)\"?",
            message: worktrees.isEmpty
                ? "Its conversation history is removed from the app."
                : "Its \(worktrees.count) worktree\(worktrees.count == 1 ? "" : "s") go with it, along with anything uncommitted there.",
            actions: [
                .init(label: worktrees.isEmpty ? "Delete session" : "Delete session and worktrees",
                      kind: .destructive) {
                    Task {
                        if case .failure(let failure) = await SessionLifecycle.remove(
                            session, from: store, runner: runner) {
                            showCreationError(failure.message, title: failure.title)
                        }
                    }
                },
                .init(label: "Cancel", kind: .cancel)
            ]))
    }

    // MARK: - Footer

    private func defaults(_ workspace: ProjectWorkspace) -> some View {
        FooterStrip(title: "Workspace defaults", detail: defaultsSummary(workspace)) {
            InlineLink(title: "Change →", size: 12.5) { creatingSession = workspace }
        }
    }

    private func defaultsSummary(_ workspace: ProjectWorkspace) -> String {
        let agent = runner.agent
        let settings = runner.defaults(for: agent)
        var parts = [agent.title]
        if let model = ModelChoice.valid(settings.model, for: agent) {
            parts.append(ModelChoice.title(of: model))
        }
        if let effort = EffortChoice.valid(settings.effort, for: agent) {
            parts.append("\(EffortChoice.summary(of: effort, agent: agent)) effort")
        }
        parts.append(worktreeSummary(workspace))
        return parts.joined(separator: " · ")
    }

    private func worktreeSummary(_ workspace: ProjectWorkspace) -> String {
        let repositories = workspace.projectIDs.compactMap(store.project).filter(\.isGitRepository)
        let worktrees = repositories.filter { workspace.worktreeProjectIDs.contains($0.id) }
        if worktrees.isEmpty { return "project folders throughout" }
        if worktrees.count == repositories.count { return "worktree on every repository" }
        if worktrees.count == 1, worktrees[0].id == workspace.leadProjectID {
            return "worktree on the lead project only"
        }
        return "worktree on \(worktrees.count) of \(repositories.count) repositories"
    }

    // MARK: - Helpers

    private func summary(_ project: Project, workspace: ProjectWorkspace) -> String {
        var parts = [project.collapsedPath]
        if let branch = GitHead.branch(at: project.path) { parts.append(branch) }
        return parts.joined(separator: " · ")
    }

    private func toggleTerminal(_ workspace: ProjectWorkspace) {
        guard let lead = store.project(workspace.leadProjectID) else { return }
        let opening = !terminals.isOpen(terminalScope)
        terminals.setOpen(opening, for: terminalScope, directory: lead.path)
        terminalFocused = opening
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

    private func saveName(_ workspace: ProjectWorkspace) {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != workspace.name else {
            draftName = workspace.name
            return
        }
        store.renameWorkspace(workspace.id, to: name)
        draftName = store.workspace(workspace.id)?.name ?? draftName
    }

    private func attachableProjects(_ workspace: ProjectWorkspace) -> [Project] {
        store.projects.filter { !workspace.projectIDs.contains($0.id) }
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

    private func hasMissingProjects(_ workspace: ProjectWorkspace) -> Bool {
        workspace.projectIDs.compactMap(store.project).contains(where: store.isMissing)
    }

    private func startSession(_ choice: WorkspaceSessionChoice,
                              in workspace: ProjectWorkspace) {
        Task {
            switch await SessionLifecycle.createWorkspaceSession(
                choice, in: workspace, store: store) {
            case .success:
                break
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
