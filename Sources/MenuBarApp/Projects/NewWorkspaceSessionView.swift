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
    @Environment(SkillsManager.self) private var skills

    @State private var sessionID = UUID()
    @State private var projectIDs: [UUID]
    @State private var worktrees: Set<UUID>
    @State private var selectedAgent: AgentKind?
    @State private var selectedAvatarName = AgentAvatarSelection.defaultName
    @State private var sessionType: NewSessionType = .code
    @State private var showingTroubleshoot = false
    // One report per repository, arriving in two passes: what the local refs already
    // say, then the same read again after a fetch, so the cards are honest immediately
    // and accurate a moment later.
    @State private var freshness: [UUID: GitFreshness.Report] = [:]
    // One explicit start point per stale repository. Missing entries mean the checkout
    // as it is, which is also the choice for repositories with nothing to reconcile.
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
        if showingTroubleshoot {
            TroubleshootView(skills: skills,
                             initialProjectIDs: projectIDs,
                             initialWorkspaceID: workspace.id)
        } else {
            sessionSetup
        }
    }

    private var sessionSetup: some View {
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

                    NewSessionTypeOption(selection: $sessionType,
                                         designEnabled: appSettings.designEnabled)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .frame(maxHeight: 470)

            NewSessionFooter(sessionType: sessionType,
                             sessionID: sessionID,
                             note: footerNote,
                             fetching: activeFetches > 0,
                             updating: pulling ? "checkouts" : nil,
                             ready: hasEnoughProjects,
                             selectedAgent: $selectedAgent,
                             selectedAvatarName: $selectedAvatarName,
                             create: create,
                             dismiss: { dismiss() })
        }
        .frame(width: 680)
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
        let tint = Theme.projectTint(for: project.name)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProjectDot(tint: tint, size: 10)
                Text(project.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                MonoChip(text: lead ? "LEAD" : "ATTACHED", size: 9.5,
                         tint: lead ? Theme.accent : tint.colour)
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

            CheckoutModePicker(
                usesWorktree: usesWorktree,
                supportsWorktree: supportsWorktree,
                branch: usesWorktree ? checkout.branch : GitHead.branch(at: project.path),
                path: usesWorktree ? checkout.path.abbreviatedPath : project.collapsedPath,
                selectWorktree: {
                    worktrees.insert(project.id)
                    if let report = freshness[project.id], report.defaultBranchHasDiverged,
                       !chosenStartPoints.contains(project.id) {
                        startPoints[project.id] = .remote
                    }
                },
                selectProjectFolder: {
                    worktrees.remove(project.id)
                    if startPoints[project.id] == .remote {
                        startPoints[project.id] = .currentCheckout
                    }
                })

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

    private var footerNote: String {
        sessionType == .troubleshoot
            ? "Troubleshoot uses the project folders and opens diagnosis setup next."
            : "Deleting the session removes all of its worktrees together."
    }

    // A workspace session is a conversation across projects, so it needs at least two;
    // a troubleshoot only needs somewhere to look.
    private var hasEnoughProjects: Bool {
        sessionType == .troubleshoot ? !projectIDs.isEmpty : projectIDs.count >= 2
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
        guard sessionType != .troubleshoot else {
            showingTroubleshoot = true
            return
        }
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
                                        mode: sessionType.sessionMode))
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
}
