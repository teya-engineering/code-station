import SwiftUI

// The bar both new-session sheets end with. The line at its start says what still
// stands between the sheet and a session, or what creating will mean once nothing
// does; then Cancel, the bot the session will wear, and the split button that creates
// on its left half and picks the coding agent on its right, with the agent it will use
// written underneath.
struct NewSessionFooter: View {
    let sessionType: NewSessionType
    let sessionID: UUID
    // What creating will do. Shown once nothing is running; Troubleshoot never waits on
    // git, so its line shows regardless.
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
            HStack(alignment: .top, spacing: 10) {
                if waitingOn != nil {
                    ProgressView().controlSize(.small)
                }
                Text(waitingOn ?? note)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                ActionButton(title: "Cancel", size: 13, keyboardShortcut: .cancelAction,
                             action: dismiss)
                if sessionType != .troubleshoot {
                    SessionBotPicker(avatars: appSettings.agentAvatars,
                                     selectedName: $selectedAvatarName,
                                     sessionID: sessionID)
                }
                createButton
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Theme.card)
        }
        .task {
            try? await Task.sleep(for: Self.longestWait)
            withAnimation(.easeOut(duration: 0.2)) { gaveUpWaiting = true }
        }
    }

    private var createButton: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 0) {
                Button(action: create) {
                    Text(sessionType == .troubleshoot ? "Continue" : "Create session")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 18)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)

                if sessionType != .troubleshoot, runner.availableAgents.count > 1 {
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
            .opacity(canCreate ? 1 : 0.4)
            .disabled(!canCreate)

            Text(sessionType == .troubleshoot ? "Add the problem and evidence next." : agentNote)
                .font(.system(size: 10.5))
                .foregroundStyle(sessionType != .troubleshoot && chosenAgent == nil
                                 ? Theme.deletion : .secondary)
        }
    }

    // What git still has in hand. A pull outranks a fetch, since it is moving the very
    // checkout the fetch was reading. Troubleshoot uses the folder as it is, so nothing
    // stands in its way.
    private var waitingOn: String? {
        guard sessionType != .troubleshoot else { return nil }
        if let updating { return "Updating \(updating) from origin…" }
        if fetching && !gaveUpWaiting { return "Fetching branch information…" }
        return nil
    }

    private var chosenAgent: AgentKind? {
        runner.agentForNewSession(selected: selectedAgent)
    }

    private var canCreate: Bool {
        ready && (sessionType == .troubleshoot || (waitingOn == nil && chosenAgent != nil))
    }

    private var agentNote: String {
        guard let chosenAgent else { return "No coding agent found on PATH." }
        if runner.availableAgents.count == 1 || selectedAgent != nil {
            return "Will use \(chosenAgent.title)"
        }
        return "Uses default: \(chosenAgent.title)"
    }

    private var agentMenu: [MenuEntry] {
        runner.availableAgents.map { agent in
            .item(agent.title,
                  checked: chosenAgent == agent,
                  subtitle: agent == .codex
                      ? "OpenAI's coding agent."
                      : "Anthropic's coding agent.") {
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
