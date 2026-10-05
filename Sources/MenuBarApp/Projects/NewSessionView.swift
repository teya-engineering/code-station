import SwiftUI

// Where a new session will do its work. Every session starts as a conversation; Design
// and Troubleshoot are tabs inside it, on a session that already has its projects and
// agent. A plain folder still shows this screen so the agent and bot remain explicit.
struct NewSessionView: View {
    let project: Project
    let onCreate: (NewSessionChoice) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(SessionRunner.self) private var runner
    @Environment(AppSettings.self) private var appSettings

    // Picked up front so the branch and folder shown here are the ones the session is
    // created with, rather than a guess at what they will look like.
    @State private var sessionID = UUID()
    @State private var useWorktree: Bool
    // How the checkout relates to the default branch and its remote. It arrives in two
    // passes: what the local refs already say, then the same read again after a fetch,
    // so the sheet is honest immediately and accurate a moment later.
    @State private var freshness: GitFreshness.Report?
    // The fetch pass is still running, which holds the footer's button.
    @State private var fetching: Bool
    // Where the session should start when the checkout is stale. The three states are
    // shown as choices instead of making an unchecked pair of boxes mean a third answer.
    @State private var startPoint: SessionStartPoint = .currentCheckout
    @State private var startPointWasChosen = false
    // The update is running. The sheet stays up until it finishes, so the whole screen
    // goes quiet: a click anywhere while git works could only start the same work twice
    // or abandon it half done.
    @State private var pulling = false
    @State private var selectedAgent: AgentKind?
    // The filename is saved with the session so the photo and its personality stay in
    // force for every turn. The built-in Default bot is ready before settings load.
    @State private var selectedAvatarName = AgentAvatarSelection.defaultName

    init(project: Project, onCreate: @escaping (NewSessionChoice) -> Void) {
        self.project = project
        self.onCreate = onCreate
        _useWorktree = State(initialValue: project.isGitRepository)
        _fetching = State(initialValue: project.isGitRepository)
    }

    private var planned: GitWorktree.Created {
        GitWorktree.plan(projectName: project.name, sessionID: sessionID)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            // The middle scrolls so the sheet can be squeezed into a short window. A
            // sheet that asks for more height than the window has is not shrunk but
            // clipped, and since it is clipped from the middle out, the footer and its
            // Create button are the first things to go.
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SessionProjectCard(project: project, usesWorktree: useWorktree,
                                       report: freshness, startPoint: $startPoint,
                                       selectWorktree: selectWorktree,
                                       selectProjectFolder: selectProjectFolder,
                                       onChoose: { startPointWasChosen = true })
                    SessionCheckoutPaths(entries: [
                        .init(name: project.name,
                              branch: project.isGitRepository
                                ? (useWorktree ? planned.branch : GitHead.branch(at: project.path)) : nil,
                              path: useWorktree ? planned.path.abbreviatedPath : project.collapsedPath)
                    ])
                    Text(footerNote)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .frame(maxHeight: 470)

            NewSessionFooter(sessionID: sessionID,
                             note: SessionCreationImpact(updates: startPoint == .updateCheckout && freshness?.canUpdateCheckout == true ? 1 : 0,
                                                         worktrees: useWorktree ? 1 : 0).text,
                             fetching: fetching,
                             updating: pulling ? (freshness?.defaultBranch ?? "the checkout") : nil,
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
        .task {
            guard project.isGitRepository else { return }
            let local = await GitFreshness.check(at: project.path, fetch: false)
            withAnimation(.easeOut(duration: 0.2)) {
                freshness = local
                if let local { selectRecommendedStartPoint(for: local) }
            }
            let fetched = await GitFreshness.check(at: project.path, fetch: true)
            withAnimation(.easeOut(duration: 0.2)) {
                if let fetched {
                    freshness = fetched
                    selectRecommendedStartPoint(for: fetched)
                }
                fetching = false
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("New session in \(project.name)")
                .font(.serif(22, .semibold))
                .lineLimit(2)
            Text(project.isGitRepository
                 ? "\(project.name) is a git repository, so this session can have a checkout of its own."
                 : "This folder is not a git repository, so the session works in it directly.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private var footerNote: String {
        project.isGitRepository && useWorktree
            ? "Worktrees are isolated checkouts. Deleting this session removes its worktree."
            : "Changes land straight in your project folder."
    }

    private var chosenAgent: AgentKind? {
        runner.agentForNewSession(selected: selectedAgent)
    }

    private func selectWorktree() {
        useWorktree = true
        if let freshness { selectRecommendedStartPoint(for: freshness) }
    }

    private func selectProjectFolder() {
        useWorktree = false
        if let freshness { selectRecommendedStartPoint(for: freshness) }
        if startPoint == .remote { startPoint = .currentCheckout }
    }

    private func selectRecommendedStartPoint(for report: GitFreshness.Report) {
        guard !startPointWasChosen else { return }
        startPoint = .recommended(for: report, worktree: useWorktree)
    }

    // The update the user asked for runs here, while the sheet is still up: it can take a
    // while, and a sheet that closed on the click would leave nothing saying the work is
    // still going, or free to be started again. On failure the sheet stays for another
    // try or a cancel.
    private func create() {
        // Checked while the option was on screen, and still safe to apply now.
        guard startPoint == .updateCheckout, let report = freshness, report.canUpdateCheckout,
              let branch = report.defaultBranch else {
            finish()
            return
        }
        pulling = true
        Task {
            if let error = await GitActions.updateCheckout(to: branch, at: project.path) {
                pulling = false
                dialogs.show(.updateFailure(error, project: project.name, report: report,
                                            forWorktree: useWorktree) {
                    startPoint = .remote
                    finish()
                })
                return
            }
            finish()
        }
    }

    private func finish() {
        guard let agent = chosenAgent else { return }
        let base = startPoint == .remote ? freshness?.remoteRef : nil
        let model = runner.defaults(for: agent).model
        onCreate(useWorktree
                 ? .worktree(sessionID, base: base, agent: agent, model: model,
                             agentAvatarName: selectedAvatarName, mode: .chat)
                 : .folder(sessionID, agent: agent, model: model,
                           agentAvatarName: selectedAvatarName, mode: .chat))
        dismiss()
    }
}

enum SessionStartPoint: Equatable {
    case currentCheckout
    case remote
    case updateCheckout

    // A session should start from the default branch at its latest revision, and the
    // project folder should end up there too, so updating the checkout comes first. A
    // dirty folder cannot be updated safely, so a worktree forks from the remote tip
    // instead and leaves the folder alone.
    static func recommended(for report: GitFreshness.Report, worktree: Bool) -> SessionStartPoint {
        if report.canUpdateCheckout { return .updateCheckout }
        if worktree, report.isStale, report.remoteRef != nil { return .remote }
        return .currentCheckout
    }
}

// What the sheet came back with. The worktree case carries the id the session must be
// created with, since the branch and folder shown were named after it, and the ref to
// fork from when the user chose the remote tip over their own checkout. The agent and
// model become part of the session record. Any requested pull has already run by then.
enum NewSessionChoice: Equatable {
    case worktree(UUID, base: String?, agent: AgentKind, model: String?,
                  agentAvatarName: String?, mode: SessionMode)
    case folder(UUID, agent: AgentKind, model: String?, agentAvatarName: String?,
                mode: SessionMode)
}

// Says when the checkout a session would fork from is not the default branch at its
// latest revision, and offers the fixes the sheet can apply itself: a worktree can fork
// from the remote tip without touching the user's checkout, and a clean checkout can be
// put on the default branch at that same tip first. A dirty folder only warns; saved or
// dropped, the uncommitted work is the user's to deal with. Both new-session sheets show
// it: the single-project one once, the workspace one per repository.
struct FreshnessNotice: View {
    let report: GitFreshness.Report
    let forWorktree: Bool
    @Binding var startPoint: SessionStartPoint
    let onChoose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.attentionText)
                VStack(alignment: .leading, spacing: 3) {
                    if let concern {
                        Text(concern)
                            .foregroundStyle(Theme.attentionText)
                            .font(.system(size: 12.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if report.dirty {
                        Text(forWorktree
                             ? "Uncommitted changes in the project folder stay behind: a worktree starts from the last commit."
                             : "The project folder has uncommitted changes. This session edits them directly.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if report.isStale {
                VStack(alignment: .leading, spacing: 8) {
                    if forWorktree, let remote = report.remoteRef {
                        choice(.remote,
                               title: "Start from \(remote)",
                               detail: remoteDetail)
                    }
                    if report.canUpdateCheckout, let title = updateTitle {
                        choice(.updateCheckout, title: title, detail: updateDetail)
                    }
                    choice(.currentCheckout, title: currentTitle, detail: currentDetail)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.sunken)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Checkout start point")
    }

    private func choice(_ value: SessionStartPoint, title: String, detail: String) -> some View {
        Button {
            startPoint = value
            onChoose()
        } label: {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: startPoint == value ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(startPoint == value ? AnyShapeStyle(Theme.accent)
                                                         : AnyShapeStyle(.secondary))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: 6)
        .accessibilityAddTraits(startPoint == value ? .isSelected : [])
        .padding(.leading, 19)
    }

    private var updateTitle: String? {
        guard let branch = report.defaultBranch, let remote = report.remoteRef else { return nil }
        if report.defaultBranchHasDiverged {
            return "Rebase \(branch) onto \(remote), then start"
        }
        return report.onDefaultBranch
            ? "Update \(branch), then start"
            : "Switch to \(branch), update it to \(remote), then start"
    }

    private var updateDetail: String {
        if report.defaultBranchHasDiverged {
            return "Updates the project folder, keeping \(counted(report.defaultBranchAhead, "local commit")) and including \(counted(report.defaultBranchBehind, "remote commit"))."
        }
        return "Updates \(report.defaultBranch ?? "the default branch") to \(report.remoteRef ?? "the remote branch") in the project folder."
    }

    private var remoteDetail: String {
        guard let branch = report.defaultBranch else {
            return "Leaves the project folder unchanged."
        }
        if report.defaultBranchAhead > 0 {
            return "Leaves \(branch) and \(counted(report.defaultBranchAhead, "local commit")) unchanged."
        }
        return "Leaves \(branch) and its local commits unchanged."
    }

    private var currentTitle: String {
        "Start from \(report.currentBranch ?? "the current checkout") as it is"
    }

    private var currentDetail: String {
        guard report.behind > 0, let remote = report.remoteRef ?? report.defaultBranch else {
            return "Does not change the project folder."
        }
        return "Does not include \(counted(report.behind, "commit")) from \(remote)."
    }

    // The trouble as one or two sentences: the wrong branch, the missing commits, and
    // when the fetch failed, how old the answer is.
    private var concern: String? {
        var sentences: [String] = []
        if !report.onDefaultBranch, let expected = report.defaultBranch {
            let place = report.currentBranch.map { "on \($0)" } ?? "on a detached HEAD"
            sentences.append("The project folder is \(place), not \(expected).")
        }
        if let divergence = report.divergenceExplanation {
            sentences.append(divergence)
        } else if report.behind > 0, let target = report.remoteRef ?? report.defaultBranch {
            let subject = sentences.isEmpty ? (report.currentBranch ?? "The checkout") : "It"
            sentences.append("\(subject) is \(counted(report.behind, "commit")) behind \(target).")
        }
        if report.fetchAttempted && !report.fetched {
            sentences.append(report.lastFetch.map {
                "Origin could not be reached, so this is as of the last fetch, \($0.formatted(.relative(presentation: .named)))."
            } ?? "Origin could not be reached, so this may be out of date.")
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }
}

struct CheckoutModePicker: View {
    let usesWorktree: Bool
    let supportsWorktree: Bool
    let selectWorktree: () -> Void
    let selectProjectFolder: () -> Void

    private var detail: String {
        if usesWorktree {
            return "Work in an isolated checkout"
        }
        if supportsWorktree {
            return "Work directly in your existing folder"
        }
        return "This folder is not a Git repository, so the session uses it directly."
    }

    private var worktreeTooltip: Tooltip {
        supportsWorktree
            ? Tooltip(
                title: "Worktree",
                subtitle: "Use an isolated checkout so several sessions for this project can run at once.")
            : Tooltip(
                title: "Worktree unavailable",
                subtitle: "This folder is not a Git repository, so it cannot use a worktree.")
    }

    private var worktreeAccessibilityHint: String {
        supportsWorktree
            ? "Uses an isolated checkout so sessions can run in parallel."
            : "Unavailable because this folder is not a Git repository."
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                choices
                helper
            }
            VStack(alignment: .leading, spacing: 7) {
                choices
                helper
            }
        }
    }

    private var helper: some View {
        Text(detail)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var choices: some View {
        HStack(spacing: 8) {
            ChoicePill(title: "Worktree", selected: usesWorktree,
                       enabled: supportsWorktree, choose: selectWorktree)
                .appTooltip { worktreeTooltip }
                .accessibilityHint(worktreeAccessibilityHint)
            ChoicePill(title: "Project folder", selected: !usesWorktree,
                       choose: selectProjectFolder)
                .appTooltip {
                    Tooltip(title: "Project folder",
                            subtitle: "Edit the existing checkout directly. Sessions that share this folder cannot run together.")
                }
                .accessibilityHint("Edits the existing checkout directly, one session at a time.")
        }
        .fixedSize()
    }
}
