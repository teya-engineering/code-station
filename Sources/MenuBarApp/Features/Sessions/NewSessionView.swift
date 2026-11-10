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
    // A fetch the user asked to run again after the first pass failed. It holds the
    // footer's button too, for as long as it runs.
    @State private var retries = FreshnessRetries()
    // Where the session should start when the checkout is stale. The three states are
    // shown as choices instead of making an unchecked pair of boxes mean a third answer.
    @State private var startPoint: SessionStartPoint = .currentCheckout
    @State private var startPointWasChosen = false
    // The folder's uncommitted work is copied into the worktree. Off until asked for,
    // since the work may well be meant to stay where it is.
    @State private var carryChanges = false
    // The folder's default branch is moved up to the remote tip the worktree forks
    // from. Off until asked for, since it changes the folder.
    @State private var updateDefaultBranch = false
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
                                       carryChanges: $carryChanges,
                                       updateDefaultBranch: $updateDefaultBranch,
                                       selectWorktree: selectWorktree,
                                       selectProjectFolder: selectProjectFolder,
                                       onChoose: { startPointWasChosen = true },
                                       retry: retries.attempts[project.id],
                                       reachedOrigin: retries.reached.contains(project.id),
                                       retryFetch: retryFetch,
                                       stopFetch: { retries.stop(project.id) })
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
                             note: SessionCreationImpact(updates: updatesCheckout || fastForwardsDefaultBranch ? 1 : 0,
                                                         worktrees: useWorktree ? 1 : 0).text,
                             fetching: fetching,
                             retrying: retries.isEmpty ? nil : project.name,
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
        .onDisappear { retries.stopAll() }
        .task {
            guard project.isGitRepository else { return }
            let local = await GitFreshness.check(at: project.path, fetch: false)
            freshness = local
            if let local { selectRecommendedStartPoint(for: local) }
            let fetched = await GitFreshness.check(at: project.path, fetch: true)
            if let fetched {
                freshness = fetched
                selectRecommendedStartPoint(for: fetched)
            }
            fetching = false
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

    private func retryFetch() {
        guard let freshness else { return }
        retries.start(project.id, path: project.path, after: freshness) { report in
            self.freshness = report
            selectRecommendedStartPoint(for: report)
        }
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
        if fastForwardsDefaultBranch, let branch = freshness?.defaultBranch,
           let remote = freshness?.remoteRef {
            pulling = true
            Task {
                let error = await GitActions.fastForwardBranch(branch, to: remote, at: project.path)
                pulling = false
                guard let error else { return finish() }
                dialogs.show(.fastForwardFailure(error, branch: branch) { finish() })
            }
            return
        }
        // Checked while the option was on screen, and still safe to apply now.
        guard updatesCheckout, let report = freshness, let branch = report.defaultBranch else {
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

    private var updatesCheckout: Bool {
        startPoint == .updateCheckout && freshness?.canUpdateCheckout == true
    }

    private var fastForwardsDefaultBranch: Bool {
        useWorktree && startPoint == .remote && updateDefaultBranch
            && freshness?.canFastForwardDefaultBranch == true
    }

    private func finish() {
        guard let agent = chosenAgent else { return }
        let base = startPoint == .remote ? freshness?.remoteRef : nil
        let model = runner.defaults(for: agent).model
        onCreate(useWorktree
                 ? .worktree(sessionID, base: base,
                             carryChanges: carryChanges && freshness?.dirty == true,
                             agent: agent, model: model,
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
// created with, since the branch and folder shown were named after it, the ref to fork
// from when the user chose the remote tip over their own checkout, and whether the
// folder's uncommitted work is copied in. The agent and model become part of the
// session record. Any requested pull has already run by then.
enum NewSessionChoice: Equatable {
    case worktree(UUID, base: String?, carryChanges: Bool, agent: AgentKind, model: String?,
                  agentAvatarName: String?, mode: SessionMode)
    case folder(UUID, agent: AgentKind, model: String?, agentAvatarName: String?,
                mode: SessionMode)
}

// Says when the checkout a session would fork from is not the default branch at its
// latest revision, and offers the fixes the sheet can apply itself: a worktree can fork
// from the remote tip without touching the user's checkout, and a clean checkout can be
// put on the default branch at that same tip first. A dirty folder is never changed: a
// worktree can take a copy of the uncommitted work, and when that copy would clash with
// the base, the files are named here before the session is made. Both new-session
// sheets show it: the single-project one once, the workspace one per repository.
struct FreshnessNotice: View {
    let report: GitFreshness.Report
    let forWorktree: Bool
    let projectPath: String
    @Binding var startPoint: SessionStartPoint
    @Binding var carryChanges: Bool
    @Binding var updateDefaultBranch: Bool
    let onChoose: () -> Void
    var retry: FreshnessRetries.Attempt? = nil
    var retryFetch: () -> Void = {}
    var stopFetch: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var retryActOuts = 0
    // Nil while the check runs, or when there is nothing to check.
    @State private var preview: GitCarryOver.Preview?

    private struct PreviewRequest: Equatable {
        let carry: Bool
        let base: String?
        let report: GitFreshness.Report
    }

    // Only the remote tip can clash: a worktree from the folder's own commit is the
    // commit the work was written on.
    private var carryBase: String? {
        startPoint == .remote ? report.remoteRef : nil
    }

    private var offersCarry: Bool { forWorktree && report.dirty }

    // Only beside the remote tip: that is the choice which leaves the folder alone, and
    // the one whose base the default branch would be moved up to.
    private var offersFastForward: Bool {
        forWorktree && startPoint == .remote && report.canFastForwardDefaultBranch
    }

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
                    if report.fetchFailed && retry == nil {
                        if let advice = report.fetchAdvice {
                            Text(advice)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let failure = report.fetchFailure {
                            Text(failure)
                                .font(.mono(11.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(6)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 7)
                                .frame(maxWidth: 520, alignment: .leading)
                                .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 6))
                                .padding(.top, 3)
                        }
                    }
                    if report.dirty {
                        Text(forWorktree
                             ? "The project folder has uncommitted changes. A worktree starts from the last commit, so they stay behind unless you bring them along."
                             : "The project folder has uncommitted changes. This session edits them directly.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if report.fetchFailed {
                Group {
                    if let retry {
                        FetchRetryProgress(attempt: retry, stop: stopFetch)
                            .transition(reduceMotion ? .opacity : .fadeIn)
                    } else {
                        retryButton
                            .transition(reduceMotion ? .opacity : .fadeIn)
                    }
                }
                .frame(minHeight: 30)
                .padding(.leading, 19)
                .padding(.vertical, 2)
            }
            if report.isStale {
                VStack(alignment: .leading, spacing: 8) {
                    if forWorktree, let remote = report.remoteRef {
                        choice(.remote,
                               title: "Start from \(remote)",
                               detail: remoteDetail)
                        if offersFastForward {
                            fastForwardToggle
                                .transition(reduceMotion ? .opacity : .fadeIn)
                        }
                    }
                    if report.canUpdateCheckout, let title = updateTitle {
                        choice(.updateCheckout, title: title, detail: updateDetail)
                    }
                    choice(.currentCheckout, title: currentTitle, detail: currentDetail)
                }
                .motion(Motion.reveal, value: offersFastForward)
            }
            if offersCarry {
                carryToggle
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .motion(Motion.reveal, value: retry)
        .motion(Motion.reveal, value: report)
        .background(Theme.attention.opacity(0.10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Checkout start point")
        .task(id: PreviewRequest(carry: carryChanges && offersCarry, base: carryBase,
                                 report: report)) {
            preview = nil
            guard carryChanges, offersCarry, let base = carryBase else { return }
            let result = await GitCarryOver.preview(at: projectPath, onto: base)
            if !Task.isCancelled { preview = result }
        }
    }

    // A longer wait is only offered when origin was slow. When it said no, the same
    // wait is tried again, since time would not change its answer.
    private var retryTitle: String {
        report.fetchTimedOut
            ? "Try again, waiting up to \(counted(Int(report.retryWait), "second"))"
            : "Try again"
    }

    private var retryButton: some View {
        Button {
            retryActOuts += 1
            retryFetch()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .actOut("arrow.clockwise", trigger: retryActOuts)
                Text(retryTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize()
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 13)
            .frame(height: 30)
            .background(Theme.card, in: Capsule())
            .overlay(Capsule().stroke(Theme.border))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .hoverLift()
        .accessibilityHint("Fetches from origin again.")
    }

    private var carryToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $carryChanges) {
                Text("Bring the uncommitted changes into the worktree")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.appCheckbox)
            if carryChanges, let status = carryStatus {
                Text(status.text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(status.warns ? AnyShapeStyle(Theme.attentionText)
                                                  : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 24)
                    .contentTransition(.opacity)
                    .motion(Motion.control, value: status.text)
                    .transition(reduceMotion ? .opacity : .fadeIn)
            }
        }
        .motion(Motion.reveal, value: carryChanges)
        .padding(.leading, 19)
        .padding(.top, 2)
    }

    private var fastForwardToggle: some View {
        let branch = report.defaultBranch ?? "the default branch"
        return VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $updateDefaultBranch) {
                Text("Also update \(branch) to \(report.remoteRef ?? "the remote branch")")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.appCheckbox)
            Text("Moves \(branch) forward \(counted(report.defaultBranchBehind, "commit")) in the project folder. The uncommitted changes stay in place.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 24)
        }
        .padding(.leading, 39)
    }

    private var carryStatus: (text: String, warns: Bool)? {
        let kept = "The project folder keeps them too."
        guard let base = carryBase else {
            return ("They apply cleanly, since the worktree starts from the same commit. \(kept)", false)
        }
        switch preview {
        case nil:
            return ("Checking them against \(base)…", false)
        case .clean:
            return ("They apply cleanly on top of \(base). \(kept)", false)
        case .unknown:
            return ("Could not check them against \(base) ahead of time. Any clash is left as conflict markers for the session to resolve.", true)
        case .clashes(let files):
            let shown = files.prefix(3).joined(separator: ", ")
                + (files.count > 3 ? " and \(files.count - 3) more" : "")
            let avoid = report.currentBranch.map { " Start from \($0) as it is to avoid this." } ?? ""
            return ("\(counted(files.count, "file")) clash with \(base): \(shown). "
                    + "They start with conflict markers, and the session is asked to resolve them."
                    + avoid, true)
        }
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
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .motion(Motion.control, value: startPoint == value)
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
        if let problem = report.fetchProblem { sentences.append(problem) }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }
}

// A retried fetch in flight: how long it has been going against how long it may take,
// and a way to give up on it.
private struct FetchRetryProgress: View {
    let attempt: FreshnessRetries.Attempt
    let stop: () -> Void

    @State private var elapsed = 0

    private var wait: Int { Int(attempt.wait) }

    var body: some View {
        HStack(spacing: 10) {
            LoopSpinner(colour: Theme.accent, size: 14)
            HStack(spacing: 4) {
                Text("Fetching from origin")
                Text("\(elapsed) of \(wait) s")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .motion(Motion.control, value: elapsed)
            }
            .font(.system(size: 12))
            .fixedSize()
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.accent.opacity(0.12))
                    Capsule().fill(Theme.accent)
                        .frame(width: geometry.size.width * CGFloat(elapsed) / CGFloat(max(wait, 1)))
                        .motion(Motion.draw, value: elapsed)
                }
            }
            .frame(maxWidth: 180)
            .frame(height: 3)
            InlineLink(title: "Stop", action: stop)
                .padding(.horizontal, 6)
                .accessibilityLabel("Stop fetching")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Fetching from origin, \(elapsed) of \(wait) seconds")
        .task(id: attempt) {
            while !Task.isCancelled {
                elapsed = min(wait, Int(Date.now.timeIntervalSince(attempt.started)))
                try? await Task.sleep(for: .seconds(1))
            }
        }
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
