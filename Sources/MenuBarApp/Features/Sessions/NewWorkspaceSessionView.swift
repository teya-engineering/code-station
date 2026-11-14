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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    // Repositories whose uncommitted work is copied into their new worktree.
    @State private var carried: Set<UUID> = []
    // Repositories whose default branch is moved up to the remote tip their worktree
    // forks from.
    @State private var fastForwarded: Set<UUID> = []
    // Fetch passes still running, which hold the footer's button.
    @State private var activeFetches = 0
    // Fetches the user asked to run again, one per project. They hold the footer's
    // button too, for as long as they run.
    @State private var retries = FreshnessRetries()
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
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("New session in \(workspace.name)")
                    .font(Typography.display)
                Text("The lead project is the agent's working directory. Attached projects are available to the same conversation.")
                    .font(Typography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.xxl)

            ScrollView {
                VStack(spacing: Space.md) {
                    HStack {
                        Text("Projects · \(projectIDs.count)")
                            .font(Typography.body.weight(.semibold))
                        Spacer()
                        if !attachableProjects.isEmpty {
                            Label("Attach a project", systemImage: "plus")
                                .font(Typography.label)
                                .foregroundStyle(Theme.accent)
                                .contentShape(Rectangle())
                                .hoverLift()
                                .appMenu { attachMenu }
                        }
                    }
                    ForEach(projectIDs, id: \.self) { id in
                        if let project = store.project(id) {
                            projectCard(project, lead: id == workspace.leadProjectID)
                                .transition(cardTransition)
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
                        .font(Typography.detail)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Space.xxl)
                .padding(.bottom, Space.xxl)
            }
            .frame(maxHeight: 470)

            NewSessionFooter(sessionID: sessionID,
                             note: footerNote,
                             fetching: activeFetches > 0,
                             retrying: retryingNames,
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
        .onDisappear { retries.stopAll() }
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
                freshness[id] = report
                selectRecommendedStartPoint(for: id)
            }
        }
    }

    private func projectCard(_ project: Project, lead: Bool) -> some View {
        let supportsWorktree = project.isGitRepository
        let usesWorktree = supportsWorktree && worktrees.contains(project.id)
        return SessionProjectCard(
            project: project, lead: lead, usesWorktree: usesWorktree,
            report: freshness[project.id], startPoint: startPoint(project.id),
            carryChanges: Binding(get: { carried.contains(project.id) }, set: { carry in
                if carry { carried.insert(project.id) } else { carried.remove(project.id) }
            }),
            updateDefaultBranch: Binding(get: { fastForwarded.contains(project.id) }, set: { update in
                if update { fastForwarded.insert(project.id) } else { fastForwarded.remove(project.id) }
            }),
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
            retry: retries.attempts[project.id],
            reachedOrigin: retries.reached.contains(project.id),
            retryFetch: {
                guard let report = freshness[project.id] else { return }
                retries.start(project.id, path: project.path, after: report) { report in
                    freshness[project.id] = report
                    selectRecommendedStartPoint(for: project.id)
                }
            },
            stopFetch: { retries.stop(project.id) },
            detach: lead ? nil : { detach(project.id) })
    }

    private var retryingNames: String? {
        let names = projectIDs.filter { retries.attempts[$0] != nil }
            .compactMap { store.project($0)?.name }
        return names.isEmpty ? nil : names.formatted(.list(type: .and))
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
                || fastForwardsDefaultBranch($0)
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
                withAnimation(reduceMotion ? nil : Motion.reveal) {
                    projectIDs.append(project.id)
                }
                if project.isGitRepository {
                    worktrees.insert(project.id)
                    Task { await check([project]) }
                }
            }
        }
    }

    // Under Reduce Motion the list closes up at once and only the card's fade is left.
    private var cardTransition: AnyTransition {
        reduceMotion
            ? .asymmetric(insertion: AnyTransition.opacity.animation(Motion.reveal),
                          removal: AnyTransition.opacity.animation(Motion.leave))
            : .asymmetric(insertion: .fadeIn, removal: .fold)
    }

    private func detach(_ id: UUID) {
        withAnimation(reduceMotion ? nil : Motion.leave) {
            projectIDs.removeAll { $0 == id }
        }
        worktrees.remove(id)
        retries.stop(id)
        startPoints.removeValue(forKey: id)
        chosenStartPoints.remove(id)
        carried.remove(id)
        fastForwarded.remove(id)
    }

    private func fastForwardsDefaultBranch(_ id: UUID) -> Bool {
        worktrees.contains(id) && startPoints[id] == .remote && fastForwarded.contains(id)
            && freshness[id]?.canFastForwardDefaultBranch == true
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
        let fastForwards = projectIDs.compactMap { id -> (project: Project, branch: String,
                                                          remote: String)? in
            guard fastForwardsDefaultBranch(id), let report = freshness[id],
                  let branch = report.defaultBranch, let remote = report.remoteRef,
                  let project = store.project(id) else { return nil }
            return (project, branch, remote)
        }
        guard !updates.isEmpty || !fastForwards.isEmpty else {
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
            for (project, branch, remote) in fastForwards {
                if let error = await GitActions.fastForwardBranch(branch, to: remote, at: project.path) {
                    pulling = false
                    dialogs.show(.fastForwardFailure(error, branch: "\(branch) in \(project.name)") {
                        fastForwarded.remove(project.id)
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
            return WorkspaceProjectChoice(
                projectID: id, useWorktree: useWorktree, base: base,
                carryChanges: useWorktree && carried.contains(id) && freshness[id]?.dirty == true)
        }
        onCreate(WorkspaceSessionChoice(sessionID: sessionID, projects: choices,
                                        agent: agent,
                                        model: runner.defaults(for: agent).model,
                                        agentAvatarName: selectedAvatarName,
                                        mode: .chat))
        dismiss()
    }
}

struct WorkspaceSessionChoice: Equatable {
    var sessionID: UUID
    var projects: [WorkspaceProjectChoice]
    var agent: AgentKind
    var model: String? = nil
    var agentAvatarName: String? = nil
    var mode: SessionMode = .chat
}

struct WorkspaceProjectChoice: Equatable {
    var projectID: UUID
    var useWorktree: Bool
    // The ref this project's worktree forks from; without one it forks from whatever
    // the project folder has checked out.
    var base: String? = nil
    // The project folder's uncommitted work is copied into the new worktree.
    var carryChanges = false
}
