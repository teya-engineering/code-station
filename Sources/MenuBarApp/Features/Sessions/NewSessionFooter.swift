import SwiftUI
import CodeStationCore

// Shared readiness and actions for single-project and workspace sessions.
struct NewSessionFooter: View {
    let sessionID: UUID
    // What creating will do. Shown once nothing is running.
    let note: String
    // The fetch pass is still running. Creating waits for it, so a session cannot start
    // from an answer that was about to change, and so the warning a fetch turns up is
    // seen before the choice is made rather than after.
    let fetching: Bool
    // What a requested pull is moving while it runs: a branch name, or "checkouts".
    var updating: String? = nil
    // The sheet's own condition on top of the shared ones, such as having enough
    // projects.
    var ready = true
    // Leaving the agent unset is deliberate: the app-wide choice remains the default
    // until this one launch says otherwise, so cancelling the sheet cannot change it.
    @Binding var selectedAgent: AgentKind?
    @Binding var selectedAvatarName: String
    let create: () -> Void
    let dismiss: () -> Void

    @Environment(SessionRunner.self) private var runner
    @Environment(AppSettings.self) private var appSettings

    // Only the fetch itself is bounded, and every git command in the app shares one
    // queue, so the pass can take longer than the sheet should ever hold the button
    // for. Past this the footer gives up waiting rather than becoming a dead end; a
    // report that lands afterwards is still shown.
    private static let longestWait: Duration = .seconds(12)
    @State private var gaveUpWaiting = false

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.hairline)
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    if waitingOn != nil { ProgressView().controlSize(.small) }
                    Text(waitingOn ?? (chosenAgent == nil ? "No coding agent found on PATH." : note))
                        .font(.system(size: 12))
                        .foregroundStyle(chosenAgent == nil ? Theme.deletion : Theme.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .bottom, spacing: 12) {
                        selectors
                        Spacer(minLength: 12)
                        actions
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        selectors
                        HStack { Spacer(); actions }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Theme.card)
        }
        .task {
            try? await Task.sleep(for: Self.longestWait)
            withAnimation(.easeOut(duration: 0.2)) { gaveUpWaiting = true }
        }
    }

    private var selectors: some View {
        AgentAndBotPicker(avatars: appSettings.agentAvatars,
                          selectedAvatarName: $selectedAvatarName, sessionID: sessionID,
                          agentTitle: chosenAgent?.title ?? "Unavailable",
                          agentEnabled: !runner.availableAgents.isEmpty,
                          agentMenu: agentMenu)
    }

    private var actions: some View {
        HStack(spacing: 9) {
            ActionButton(title: "Cancel", tone: .outlined, height: 38, size: 13,
                         keyboardShortcut: .cancelAction, action: dismiss)
            ActionButton(title: "Create session", tone: .green, height: 38, size: 13,
                         keyboardShortcut: .defaultAction, action: create)
                .disabled(!canCreate)
        }
    }

    // What git still has in hand. A pull outranks a fetch, since it is moving the very
    // checkout the fetch was reading.
    private var waitingOn: String? {
        if let updating { return "Updating \(updating) from origin…" }
        if fetching && !gaveUpWaiting { return "Fetching branch information…" }
        return nil
    }

    private var chosenAgent: AgentKind? {
        runner.agentForNewSession(selected: selectedAgent)
    }

    private var canCreate: Bool {
        ready && waitingOn == nil && chosenAgent != nil
    }

    private var agentMenu: [MenuEntry] {
        runner.availableAgents.map { agent in
            .item(agent.title,
                  checked: chosenAgent == agent,
                  subtitle: agent.blurb) {
                selectedAgent = agent
            }
        }
    }
}

extension Dialog {
    // The pull a new-session sheet ran for the user has failed, so no session was
    // created: the user asked to start from the latest commits, and quietly starting
    // from stale ones instead would betray that. A worktree does not need the checkout
    // moved, since it can fork from the remote tip instead, so that is offered whenever
    // the sheet knows the ref.
    static func updateFailure(_ error: String, project: String, report: GitFreshness.Report,
                              forWorktree: Bool,
                              startFromRemote: @escaping () -> Void) -> Dialog {
        var actions: [Action] = []
        if forWorktree, let remote = report.remoteRef {
            actions.append(Action(label: "Start from \(remote)", kind: .primary,
                                  handler: startFromRemote))
        }
        actions.append(Action(label: actions.isEmpty ? "OK" : "Cancel", kind: .cancel))
        return Dialog(title: report.defaultBranchHasDiverged
                          ? "Could not rebase \(report.defaultBranch ?? "the checkout")"
                          : "Could not update \(project)",
                      message: error,
                      actions: actions)
    }
}
