import SwiftUI

struct AttachProjectSheet: View {
    let sessionID: UUID
    let onAttached: (_ newWorkspace: String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let longestWait: Duration = .seconds(12)

    @State private var projectID: UUID?
    @State private var useWorktree = false
    @State private var freshness: GitFreshness.Report?
    @State private var startPoint: SessionStartPoint = .currentCheckout
    @State private var startPointWasChosen = false
    @State private var carryChanges = false
    @State private var updateDefaultBranch = false
    @State private var activeFetches = 0
    @State private var gaveUpWaiting = false
    @State private var retries = FreshnessRetries()
    @State private var working: String?
    @State private var canFork = false

    var body: some View {
        VStack(spacing: 0) {
            SheetTitle("Attach project", icon: "plus.rectangle.on.folder")
                .padding(.horizontal, Space.pane)
                .headerBand()

            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    if attachableProjects.isEmpty {
                        Text("Every project is already in this session.")
                            .font(Typography.detail)
                            .foregroundStyle(.secondary)
                    } else {
                        OptionMenu(caption: "Project", value: project?.name ?? "Choose a project") {
                            projectMenu
                        }
                    }
                    if let workspaceLine {
                        Text(workspaceLine)
                            .font(Typography.detail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.opacity)
                            .transition(cardTransition)
                    }
                    if losesFork {
                        Text("After this, Fork from here is no longer available for this session.")
                            .font(Typography.detail)
                            .foregroundStyle(Theme.warningText)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(cardTransition)
                    }
                    if let project {
                        SessionProjectCard(project: project, usesWorktree: useWorktree,
                                           report: freshness, startPoint: $startPoint,
                                           carryChanges: $carryChanges,
                                           updateDefaultBranch: $updateDefaultBranch,
                                           selectWorktree: selectWorktree,
                                           selectProjectFolder: selectProjectFolder,
                                           onChoose: { startPointWasChosen = true },
                                           retry: retries.attempts[project.id],
                                           reachedOrigin: retries.reached.contains(project.id),
                                           retryFetch: retryFetch,
                                           stopFetch: { retries.stop(project.id) })
                            .id(project.id)
                            .transition(cardTransition)
                    }
                }
                .padding(Space.pane)
                .motion(Motion.reveal, value: projectID)
            }
            .frame(maxHeight: 470)

            SheetFooter(primary: SheetAction(title: "Attach", enabled: canAttach,
                                             shortcut: .defaultAction, action: attach),
                        dismissTone: .outlined, primaryLast: true, dismiss: { dismiss() }) {
                HStack(spacing: Space.md) {
                    if waitingOn != nil { LoopSpinner() }
                    Text(waitingOn ?? note)
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(width: 680)
        .background(Theme.background)
        .disabled(working != nil)
        .interactiveDismissDisabled(working != nil)
        .onAppear {
            canFork = store.transcript(of: sessionID).contains {
                store.canForkSession(sessionID, before: $0.id)
            }
        }
        .onDisappear { retries.stopAll() }
        .task(id: projectID) { await check() }
        .task(id: projectID) {
            guard (try? await Task.sleep(for: Self.longestWait)) != nil else { return }
            gaveUpWaiting = true
        }
    }

    private var session: ChatSession? { store.session(sessionID) }

    private var project: Project? { projectID.flatMap { store.project($0) } }

    private var workspace: ProjectWorkspace? {
        session?.workspaceID.flatMap { store.workspace($0) }
    }

    private var newWorkspaceName: String? {
        guard let project, let session, workspace == nil,
              let lead = store.project(session.projectID) else { return nil }

        return ProjectWorkspace.name(joining: lead.name, project.name)
    }

    private var workspaceLine: String? {
        if let newWorkspaceName {
            return "This session will move into a new workspace called \(newWorkspaceName)."
        }
        guard let project, let workspace, !workspace.projectIDs.contains(project.id) else {
            return nil
        }

        return "\(project.name) will also join \(workspace.name)."
    }

    private var losesFork: Bool { newWorkspaceName != nil && canFork }

    private var attachableProjects: [Project] {
        let attached = Set(session.map { store.checkoutProjects(for: $0).map(\.projectID) } ?? [])
        let members = workspace?.projectIDs ?? []
        let free = store.regularProjects.filter { !attached.contains($0.id) }

        return free.filter { members.contains($0.id) } + free.filter { !members.contains($0.id) }
    }

    private var projectMenu: [MenuEntry] {
        attachableProjects.map { candidate in
            .item(candidate.name, checked: candidate.id == projectID,
                  subtitle: candidate.collapsedPath) {
                choose(candidate)
            }
        }
    }

    private func choose(_ candidate: Project) {
        guard candidate.id != projectID else { return }
        retries.stopAll()
        freshness = nil
        startPoint = .currentCheckout
        startPointWasChosen = false
        carryChanges = false
        updateDefaultBranch = false
        gaveUpWaiting = false
        let member = workspace?.projectIDs.contains(candidate.id) == true
        useWorktree = candidate.isGitRepository
            && (!member || workspace?.worktreeProjectIDs.contains(candidate.id) == true)
        projectID = candidate.id
    }

    private func check() async {
        guard let project, project.isGitRepository else { return }
        activeFetches += 1
        defer { activeFetches -= 1 }
        for fetch in [false, true] {
            let report = await GitFreshness.check(at: project.path, fetch: fetch)
            guard project.id == projectID else { return }
            guard let report else { continue }
            freshness = report
            selectRecommendedStartPoint(for: report)
        }
    }

    private var cardTransition: AnyTransition {
        reduceMotion
            ? .asymmetric(insertion: AnyTransition.opacity.animation(Motion.reveal),
                          removal: AnyTransition.opacity.animation(Motion.leave))
            : .asymmetric(insertion: .fadeIn, removal: .fold)
    }

    private var waitingOn: String? {
        if let working { return working }
        if let project, !retries.isEmpty { return "Fetching \(project.name) again…" }
        if activeFetches > 0 && !gaveUpWaiting { return "Fetching branch information…" }

        return nil
    }

    private var note: String {
        guard project != nil else { return "Choose a project to attach." }

        let updates = updatesCheckout || fastForwardsDefaultBranch
        if useWorktree {
            return updates ? "Will update the project folder. 1 worktree will be created."
                : "1 worktree will be created."
        }

        return updates ? "Will update the project folder." : "The project folder is used as it is."
    }

    private var canAttach: Bool { project != nil && waitingOn == nil }

    private func selectWorktree() {
        useWorktree = true
        if let freshness { selectRecommendedStartPoint(for: freshness) }
    }

    private func selectProjectFolder() {
        useWorktree = false
        if let freshness { selectRecommendedStartPoint(for: freshness) }
        if startPoint == .remote { startPoint = .currentCheckout }
    }

    private func retryFetch() {
        guard let project, let freshness else { return }
        retries.start(project.id, path: project.path, after: freshness) { report in
            self.freshness = report
            selectRecommendedStartPoint(for: report)
        }
    }

    private func selectRecommendedStartPoint(for report: GitFreshness.Report) {
        guard !startPointWasChosen else { return }
        startPoint = .recommended(for: report, worktree: useWorktree)
    }

    private var updatesCheckout: Bool {
        startPoint == .updateCheckout && freshness?.canUpdateCheckout == true
    }

    private var fastForwardsDefaultBranch: Bool {
        useWorktree && startPoint == .remote && updateDefaultBranch
            && freshness?.canFastForwardDefaultBranch == true
    }

    private func attach() {
        guard canAttach, let project else { return }
        guard !runner.state(sessionID).isBusy, !runner.isBeingRemoved(sessionID) else {
            dialogs.show(.notice("Could not attach \(project.name)",
                                 message: "Wait for the current turn to finish, then attach the project."))
            return
        }
        working = "Attaching \(project.name)…"
        Task {
            if fastForwardsDefaultBranch, let branch = freshness?.defaultBranch,
               let remote = freshness?.remoteRef {
                working = "Updating \(branch) from origin…"
                if let error = await GitActions.fastForwardBranch(branch, to: remote,
                                                                  at: project.path) {
                    working = nil
                    dialogs.show(.fastForwardFailure(error, branch: branch) {
                        updateDefaultBranch = false
                        attach()
                    })
                    return
                }
            } else if updatesCheckout, let report = freshness, let branch = report.defaultBranch {
                working = "Updating \(branch) from origin…"
                if let error = await GitActions.updateCheckout(to: branch, at: project.path) {
                    working = nil
                    dialogs.show(.updateFailure(error, project: project.name, report: report,
                                                forWorktree: useWorktree) {
                        startPoint = .remote
                        attach()
                    })
                    return
                }
            }
            await finish(project)
        }
    }

    private func finish(_ project: Project) async {
        guard let session else { return dismiss() }
        if useWorktree { working = "Creating a worktree for \(project.name)…" }
        let movingInto = newWorkspaceName
        let result = await SessionLifecycle.attachProject(
            project, to: session, useWorktree: useWorktree,
            base: useWorktree && startPoint == .remote ? freshness?.remoteRef : nil,
            carryChanges: useWorktree && carryChanges && freshness?.dirty == true,
            store: store, composer: runner.composer)
        working = nil
        switch result {
        case .success:
            onAttached(movingInto)
            dismiss()
        case .failure(let failure):
            dialogs.show(.notice(failure.title, message: failure.message))
        }
    }
}
