import SwiftUI

// Chooses how each repository in a workspace is opened for one session. Every workspace
// member starts attached, while extra projects can be added to this session alone. Each
// repository is checked against the default branch and its remote, the same way the
// single-project sheet does it, so a checkout that is stale or dirty says so on its card
// before the session forks from it.
struct NewWorkspaceSessionView: View {
    let workspace: ProjectWorkspace
    let onCreate: (WorkspaceSessionChoice) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(AppSettings.self) private var appSettings

    @State private var sessionID = UUID()
    @State private var projectIDs: [UUID]
    @State private var worktrees: Set<UUID>
    @State private var selectedAgent: AgentKind?
    @State private var selectedAvatarName = AgentAvatarSelection.nonBotName
    // One report per repository, arriving in two passes: what the local refs already
    // say, then the same read again after a fetch, so the cards are honest immediately
    // and accurate a moment later.
    @State private var freshness: [UUID: GitFreshness.Report] = [:]
    // One explicit start point per stale repository. Missing entries mean the checkout
    // as it is, which is also the choice for repositories with nothing to reconcile.
    @State private var startPoints: [UUID: SessionStartPoint] = [:]
    @State private var chosenStartPoints: Set<UUID> = []
    // Fetch passes still running. Creating waits for them, so a warning a fetch turns up
    // is seen before the choice is made rather than after.
    @State private var activeFetches = 0
    // Every git command in the app shares one queue, so a workspace of slow remotes can
    // hold the fetch passes longer than the sheet should ever hold the button. Past the
    // longest wait the sheet gives up waiting; reports that land afterwards still show.
    @State private var gaveUpWaiting = false
    // A requested pull is running. The sheet stays up and quiet until it finishes, since
    // a click anywhere while git works could only start the same work twice.
    @State private var pulling = false

    private static let longestWait: Duration = .seconds(12)

    init(workspace: ProjectWorkspace, onCreate: @escaping (WorkspaceSessionChoice) -> Void) {
        self.workspace = workspace
        self.onCreate = onCreate
        _projectIDs = State(initialValue: workspace.projectIDs)
        _worktrees = State(initialValue: Set(workspace.worktreeProjectIDs))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("New session in \(workspace.name)")
                    .font(.serif(21, .semibold))
                Text("The lead project is the agent's working directory. Attached projects are available to the same conversation.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(projectIDs, id: \.self) { id in
                        if let project = store.project(id) {
                            projectCard(project, lead: id == workspace.leadProjectID)
                        }
                    }

                    if !attachableProjects.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .bold))
                            Text("Attach a project")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text(attachableProjects.map(\.name).joined(separator: " · "))
                                .font(.mono(11))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .contentShape(Rectangle())
                        .appMenu { attachMenu }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .frame(maxHeight: 470)

            footer
        }
        .frame(width: 680)
        .background(Theme.background)
        .disabled(pulling)
        .interactiveDismissDisabled(pulling)
        .onAppear { selectedAvatarName = appSettings.defaultAgentAvatarName }
        .task { await check(gitProjects) }
        .task {
            try? await Task.sleep(for: Self.longestWait)
            withAnimation(.easeOut(duration: 0.2)) { gaveUpWaiting = true }
        }
    }

    private var gitProjects: [Project] {
        projectIDs.compactMap { store.project($0) }.filter(\.isGitRepository)
    }

    private func check(_ projects: [Project]) async {
        activeFetches += 1
        defer { activeFetches -= 1 }
        let repositories = projects.map { (id: $0.id, path: $0.path) }
        for fetch in [false, true] {
            await GitFreshness.checkAll(repositories, fetch: fetch) { id, report in
                withAnimation(.easeOut(duration: 0.2)) {
                    freshness[id] = report
                    if fetch, report.defaultBranchHasDiverged,
                       worktrees.contains(id), !chosenStartPoints.contains(id) {
                        startPoints[id] = .remote
                    }
                }
            }
        }
    }

    private func projectCard(_ project: Project, lead: Bool) -> some View {
        let supportsWorktree = project.isGitRepository
        let usesWorktree = supportsWorktree && worktrees.contains(project.id)
        let checkout = GitWorktree.plan(projectName: project.name, projectID: project.id,
                                        sessionID: sessionID)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(projectColour(project.id))
                    .frame(width: 10, height: 10)
                Text(project.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(lead ? "LEAD" : "ATTACHED")
                    .font(.mono(9.5, .semibold))
                    .kerning(0.5)
                    .foregroundStyle(lead ? Theme.accent : projectColour(project.id))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill((lead ? Theme.accent : projectColour(project.id)).opacity(0.1)))
                Spacer(minLength: 8)
                Text(project.collapsedPath)
                    .font(.mono(11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !lead {
                    Button { detach(project.id) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .appTooltip("Detach from this session")
                }
            }

            HStack(spacing: 8) {
                modeButton("Worktree", selected: usesWorktree,
                           enabled: supportsWorktree, tint: projectColour(project.id)) {
                    worktrees.insert(project.id)
                    if let report = freshness[project.id], report.defaultBranchHasDiverged,
                       !chosenStartPoints.contains(project.id) {
                        startPoints[project.id] = .remote
                    }
                }
                modeButton("Project folder", selected: !usesWorktree,
                           enabled: true, tint: projectColour(project.id)) {
                    worktrees.remove(project.id)
                    if startPoints[project.id] == .remote {
                        startPoints[project.id] = .currentCheckout
                    }
                }
                Spacer(minLength: 8)
                Text(usesWorktree ? checkout.path.abbreviatedPath : project.collapsedPath)
                    .font(.mono(11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if !supportsWorktree {
                Text("This folder is not a Git repository, so the session uses it directly.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            if let report = freshness[project.id],
               report.isStale || (usesWorktree && report.dirty) {
                FreshnessNotice(report: report, forWorktree: usesWorktree,
                                startPoint: startPoint(project.id)) {
                    chosenStartPoints.insert(project.id)
                }
                .transition(.fadeIn)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(lead ? Theme.accent : Theme.border, lineWidth: lead ? 1.5 : 1))
    }

    private func startPoint(_ id: UUID) -> Binding<SessionStartPoint> {
        Binding(get: { startPoints[id] ?? .currentCheckout },
                set: { startPoints[id] = $0 })
    }

    private func modeButton(_ title: String, selected: Bool, enabled: Bool,
                            tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(selected ? AnyShapeStyle(Color.white)
                                           : AnyShapeStyle(enabled ? Color.primary : Color.secondary))
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? tint : Theme.background))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Color.clear : Theme.border))
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.hairline)
            HStack(alignment: .top, spacing: 12) {
                if pulling {
                    ProgressView().controlSize(.small)
                    Text("Updating checkouts from origin…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else if fetching {
                    ProgressView().controlSize(.small)
                    Text("Fetching branch information…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Deleting the session removes all of its worktrees together.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button { dismiss() } label: {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 18)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                        .contentShape(Rectangle())
                        .opacity(pulling ? 0.5 : 1)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                SessionBotPicker(avatars: appSettings.agentAvatars,
                                 selectedName: $selectedAvatarName)

                VStack(alignment: .trailing, spacing: 3) {
                    HStack(spacing: 0) {
                        Button(action: create) {
                            Text("Create session")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 18)
                                .frame(height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canCreate)

                        if runner.availableAgents.count > 1 {
                            Rectangle()
                                .fill(.white.opacity(0.35))
                                .frame(width: 1, height: 16)

                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                                .appMenu { agentMenu }
                                .accessibilityLabel("Choose coding agent")
                        }
                    }
                    .foregroundStyle(.white)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accentFill))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .opacity(canCreate ? 1 : 0.45)

                    Text(agentNote)
                        .font(.system(size: 10.5))
                        .foregroundStyle(chosenAgent == nil ? Theme.deletion : .secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Theme.card)
        }
    }

    private var attachableProjects: [Project] {
        store.regularProjects.filter { !projectIDs.contains($0.id) }
    }

    private var attachMenu: [MenuEntry] {
        attachableProjects.map { project in
            .item(project.name, subtitle: project.collapsedPath) {
                projectIDs.append(project.id)
                if project.isGitRepository {
                    worktrees.insert(project.id)
                    Task { await check([project]) }
                }
            }
        }
    }

    private var agentMenu: [MenuEntry] {
        runner.availableAgents.map { agent in
            .item(agent.title, checked: chosenAgent == agent) { selectedAgent = agent }
        }
    }

    private func detach(_ id: UUID) {
        projectIDs.removeAll { $0 == id }
        worktrees.remove(id)
        startPoints.removeValue(forKey: id)
        chosenStartPoints.remove(id)
    }

    private var fetching: Bool { activeFetches > 0 && !gaveUpWaiting }

    // Nothing can start while git still has an answer in hand: before the fetches land
    // the sheet cannot say what each checkout would fork from, and a pull is still
    // moving one of them.
    private var busy: Bool { fetching || pulling }

    private var chosenAgent: AgentKind? {
        runner.agentForNewSession(selected: selectedAgent)
    }

    private var canCreate: Bool {
        projectIDs.count >= 2 && !busy && chosenAgent != nil
    }

    private var agentNote: String {
        guard let chosenAgent else { return "No coding agent found on PATH." }
        if runner.availableAgents.count == 1 || selectedAgent != nil {
            return "Will use \(chosenAgent.title)"
        }
        return "Uses default: \(chosenAgent.title)"
    }

    // The updates the user asked for run here, while the sheet is still up, one checkout
    // after another. On failure the session is not created - the user asked to start
    // from the latest commits, and quietly starting from stale ones instead would betray
    // that - so the sheet stays for another try or a cancel.
    private func create() {
        let updates = projectIDs.compactMap { id -> (project: Project, branch: String)? in
            guard startPoints[id] == .updateCheckout, let report = freshness[id],
                  report.canUpdateCheckout, let branch = report.defaultBranch,
                  let project = store.project(id) else { return nil }
            return (project, branch)
        }
        guard !updates.isEmpty else {
            finish()
            return
        }
        pulling = true
        Task {
            for (project, branch) in updates {
                if let error = await GitActions.updateCheckout(to: branch, at: project.path) {
                    pulling = false
                    showUpdateFailure(error, for: project, report: freshness[project.id])
                    return
                }
            }
            finish()
        }
    }

    private func showUpdateFailure(_ error: String, for project: Project,
                                   report: GitFreshness.Report?) {
        var actions: [Dialog.Action] = []
        if worktrees.contains(project.id), let remote = report?.remoteRef {
            actions.append(.init(label: "Start from \(remote)", kind: .primary) {
                startPoints[project.id] = .remote
                create()
            })
        }
        actions.append(.init(label: actions.isEmpty ? "OK" : "Cancel", kind: .cancel))
        dialogs.show(Dialog(
            title: report?.defaultBranchHasDiverged == true
                ? "Could not rebase \(report?.defaultBranch ?? "the checkout")"
                : "Could not update \(project.name)",
            message: error,
            actions: actions))
    }

    private func finish() {
        guard let agent = chosenAgent else { return }
        let choices = projectIDs.map { id -> WorkspaceProjectChoice in
            let useWorktree = store.project(id).map {
                worktrees.contains(id) && $0.isGitRepository
            } ?? false
            let base = useWorktree && startPoints[id] == .remote
                ? freshness[id]?.remoteRef : nil
            return WorkspaceProjectChoice(projectID: id, useWorktree: useWorktree, base: base)
        }
        onCreate(WorkspaceSessionChoice(sessionID: sessionID, projects: choices,
                                        agent: agent,
                                        model: runner.defaults(for: agent).model,
                                        agentAvatarName: selectedAvatarName))
        dismiss()
    }

    private func projectColour(_ id: UUID) -> Color {
        let colours = [Theme.accent, Theme.secret, Theme.attention, Theme.addition]
        let value = id.uuidString.utf8.reduce(0) { ($0 + Int($1)) % colours.count }
        return colours[value]
    }
}

struct WorkspaceSessionChoice: Equatable {
    var sessionID: UUID
    var projects: [WorkspaceProjectChoice]
    var agent: AgentKind
    var model: String? = nil
    var agentAvatarName: String? = nil
}

struct WorkspaceProjectChoice: Equatable {
    var projectID: UUID
    var useWorktree: Bool
    // The ref this project's worktree forks from; without one it forks from whatever
    // the project folder has checked out.
    var base: String? = nil
}
