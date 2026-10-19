import SwiftUI
import CodeStationCore

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
    @State private var selectedAvatarName = AgentAvatarSelection.defaultName
    // One report per repository, arriving in two passes: what the local refs already
    // say, then the same read again after a fetch, so the cards are honest immediately
    // and accurate a moment later.
    @State private var freshness: [UUID: GitFreshness.Report] = [:]
    // One start point per stale repository, the recommended one until the user picks
    // another. Missing entries mean the checkout as it is, which is also the choice for
    // repositories with nothing to reconcile.
    @State private var startPoints: [UUID: SessionStartPoint] = [:]
    @State private var chosenStartPoints: Set<UUID> = []
    // Fetch passes still running, which hold the footer's button.
    @State private var activeFetches = 0
    // A requested pull is running. The sheet stays up and quiet until it finishes, since
    // a click anywhere while git works could only start the same work twice.
    @State private var pulling = false

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
                    .font(.serif(22, .semibold))
                Text("The lead project is the agent's working directory. Attached projects are available to the same conversation.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            ScrollView {
                VStack(spacing: 10) {
                    HStack {
                        Text("Projects · \(projectIDs.count)")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        if !attachableProjects.isEmpty {
                            Label("Attach a project", systemImage: "plus")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                                .appMenu { attachMenu }
                        }
                    }
                    ForEach(projectIDs, id: \.self) { id in
                        if let project = store.project(id) {
                            projectCard(project, lead: id == workspace.leadProjectID)
                        }
                    }

                    SessionCheckoutPaths(entries: projectIDs.compactMap { id in
                        guard let project = store.project(id) else { return nil }
                        let usesWorktree = project.isGitRepository && worktrees.contains(id)
                        let plan = GitWorktree.plan(projectName: project.name, projectID: id,
                                                    sessionID: sessionID)
                        return .init(name: project.name,
                                     branch: usesWorktree ? plan.branch : GitHead.branch(at: project.path),
                                     path: usesWorktree ? plan.path.abbreviatedPath : project.collapsedPath)
                    })
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Worktrees are isolated checkouts. Deleting this session removes its worktrees.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .frame(maxHeight: 470)

            NewSessionFooter(sessionID: sessionID,
                             note: footerNote,
                             fetching: activeFetches > 0,
                             updating: pulling ? "checkouts" : nil,
                             ready: hasEnoughProjects,
                             selectedAgent: $selectedAgent,
                             selectedAvatarName: $selectedAvatarName,
                             create: create,
                             dismiss: { dismiss() })
        }
        .frame(width: 780)
        .background(Theme.background)
        .disabled(pulling)
        .interactiveDismissDisabled(pulling)
        .onAppear { selectedAvatarName = appSettings.defaultAgentAvatarName }
        .task { await check(gitProjects) }
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
                    selectRecommendedStartPoint(for: id)
                }
            }
        }
    }

    private func projectCard(_ project: Project, lead: Bool) -> some View {
        let supportsWorktree = project.isGitRepository
        let usesWorktree = supportsWorktree && worktrees.contains(project.id)
        return SessionProjectCard(
            project: project, lead: lead, usesWorktree: usesWorktree,
            report: freshness[project.id], startPoint: startPoint(project.id),
            selectWorktree: {
                worktrees.insert(project.id)
                selectRecommendedStartPoint(for: project.id)
            },
            selectProjectFolder: {
                worktrees.remove(project.id)
                selectRecommendedStartPoint(for: project.id)
                if startPoints[project.id] == .remote {
                    startPoints[project.id] = .currentCheckout
                }
            },
            onChoose: { chosenStartPoints.insert(project.id) },
            detach: lead ? nil : { detach(project.id) })
    }

    private func selectRecommendedStartPoint(for id: UUID) {
        guard let report = freshness[id], !chosenStartPoints.contains(id) else { return }
        startPoints[id] = .recommended(for: report, worktree: worktrees.contains(id))
    }

    private func startPoint(_ id: UUID) -> Binding<SessionStartPoint> {
        Binding(get: { startPoints[id] ?? .currentCheckout },
                set: { startPoints[id] = $0 })
    }

    private var footerNote: String {
        let updates = projectIDs.filter {
            startPoints[$0] == .updateCheckout && freshness[$0]?.canUpdateCheckout == true
        }.count
        let trees = gitProjects.filter { worktrees.contains($0.id) }.count
        let impact = SessionCreationImpact(updates: updates, worktrees: trees).text
        return hasEnoughProjects ? impact : "Attach at least two projects to create a workspace session. " + impact
    }

    // A workspace session is a conversation across projects, so it needs at least two.
    private var hasEnoughProjects: Bool {
        projectIDs.count >= 2
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

    private func detach(_ id: UUID) {
        projectIDs.removeAll { $0 == id }
        worktrees.remove(id)
        startPoints.removeValue(forKey: id)
        chosenStartPoints.remove(id)
    }

    private var chosenAgent: AgentKind? {
        runner.agentForNewSession(selected: selectedAgent)
    }

    // The updates the user asked for run here, while the sheet is still up, one checkout
    // after another. On failure the session is not created, so the sheet stays for
    // another try or a cancel.
    private func create() {
        let updates = projectIDs.compactMap { id -> (project: Project, branch: String,
                                                      report: GitFreshness.Report)? in
            guard startPoints[id] == .updateCheckout, let report = freshness[id],
                  report.canUpdateCheckout, let branch = report.defaultBranch,
                  let project = store.project(id) else { return nil }
            return (project, branch, report)
        }
        guard !updates.isEmpty else {
            finish()
            return
        }
        pulling = true
        Task {
            for (project, branch, report) in updates {
                if let error = await GitActions.updateCheckout(to: branch, at: project.path) {
                    pulling = false
                    dialogs.show(.updateFailure(error, project: project.name, report: report,
                                                forWorktree: worktrees.contains(project.id)) {
                        startPoints[project.id] = .remote
                        create()
                    })
                    return
                }
            }
            finish()
        }
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
                                        agentAvatarName: selectedAvatarName,
                                        mode: .chat))
        dismiss()
    }
}
