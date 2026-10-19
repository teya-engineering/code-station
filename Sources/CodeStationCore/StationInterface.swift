import Foundation

// The station as one front end sees it: every command a client can give, answered with
// plain Codable values in the phone remote's vocabulary. A front end other than the GUI
// host holds nothing but this, so it cannot tell whether the host's engine is in its own
// process (`StationConnection`) or on the far side of a socket.
//
// Each value is one client. What a client opens and shows is its own: two clients can
// follow the same session, and one closing it or going away leaves it open for the other.
//
// Every command is async, since a client may be waiting on a host elsewhere, and a
// command that answers can be refused with a `StationRefusal` to say why.
//
// Commands so far:
// - list directory: every project with its session rows, and a stream of the list as it
//   changes.
// - open session: a snapshot of one session, or of its Design conversation, then a
//   stream of what moves in it (whole messages and patches, as the phone is sent).
// - close session: ends that stream and lets go of the transcript.
// - resync: sends a fresh snapshot down the open stream.
// - show: says which session this client has on screen, so a turn ending there counts as
//   read.
// - send prompt: hands a prompt to the session's runner, which queues it behind a running
//   turn.
// - stop turn: stops the running turn.
// - answer permission: allow once, allow always or deny a tool waiting for permission, or
//   answer the agent's question.
// - recall prompt: steps through the prompts a session has sent, for the composer.
// - session options, discover models and create session: what a new-session form offers,
//   and starting the session it describes.
// - read changes: a session's branch, status and changed files, each with its diff.
// - changes updates: the same, then again each time git answers differently, as the
//   agent edits files.
// - commit and discard changes: commit every change or chosen files in one of the
//   session's checkouts with a message, or throw away chosen files' changes there.
// - sync and branches: push, pull or fetch a session's or project's checkout, list its
//   branches, and switch to or create one.
// - read history and read commit: the commits of each of the session's checkouts with
//   the pull requests it opened, and one commit's files with their diffs.
// - confirm scheduled run: run, skip or turn off the timer of a task whose scheduled run
//   waits for confirmation (the directory shows it as waiting).
// - read settings and change setting: the settings that matter outside the GUI, each
//   agent's readiness and any app update waiting, read from and written to the shared
//   station preferences.
// - read log: a session's own lines from the session log, for a pager.
// - session action and session removal impact: looking after a session as the GUI's card
//   menu and transcript do (rename, regenerate the title, pin, mark read or unread,
//   delete, rewind or fork from a prompt, continue, retry, dismiss a failure, take back a
//   queued prompt, recap, the suggested next prompt), and what a deletion would take.
// - compact and clear context: the top bar's context actions. Compact hands Claude Code
//   its own `/compact` as a turn; clear drops the conversation so the next turn starts a
//   fresh one. The header says which of the two is on offer.
// - read container status: what the strip under a project, workspace or task screen
//   reads (its checkout, its projects and their checkouts, its runs and timer).
// - command shortcuts: list a project's, a session's or the Mac's saved commands, run and
//   stop one, read what it printed, and add, edit or remove one.
// - explorer: a folder of the session's checkout, file name search, find in files, and
//   creating, renaming and trashing a file, as the GUI's Explorer tab does them.
// - host events: what the host would tell the person (a turn that ended, a question
//   waiting, a wait gone stale, the session sound), for the client to tell its own.
// - hand over and release station: the next host asks this one to hand the station over
//   (new turns are refused, the turns still running are listed), and to let go once
//   none is left (ADR-0003).
// - link updates: whether the host answers this client, so a front end can say that the
//   station is not answering while a client of a host elsewhere keeps trying.
// - add project, change project: add a folder as a project by its path on the host's
//   machine, and rename, pin, unpin, snooze or wake a project or task.
// - create, read, change and run task: make a task from a prompt template, read it with
//   its inputs, schedule and runs, change its prompt, an input, its agent or its
//   schedule, and run it with its inputs filled in.
// - read removal and remove: what clearing a project's idle sessions, or removing the
//   project, would take and leave, then doing it once the person confirms.
// - run settings, send a composed prompt, list commands: the composer's bar (the agent,
//   model, effort, permission mode or access, design ambition) read and changed for the
//   session's next turn, a prompt sent with files attached by path and custom
//   instructions, and the slash commands the session can be sent (`StationComposer`).
// - workspaces: create one from several projects with a lead, change its lead, members'
//   checkouts, name and pin, read what deleting it takes and delete it, start a session
//   across its projects, and read what its members' folders have changed.
// - design: read where a session's Design stands, start one, approve the canvas, and
//   implement it (`StationDesign`).
// - diagnosis: what a diagnosis offers, and starting one from a brief (`StationDiagnosis`).
// - cleanup: rebuild a session's lost worktree after reading what would come back,
//   read and prune the worktrees no session owns, and review the sessions past the
//   shared age with what deleting each costs, then delete the ones chosen.
// - disconnect: the client is going; everything it had open is let go.
@MainActor
public protocol StationInterface: AnyObject {
    func listDirectory() async throws(StationRefusal) -> RemoteDirectory
    // The list now, then again each time it changes. The stream ends when the reader
    // stops iterating.
    func directoryUpdates() -> AsyncStream<RemoteDirectory>

    // Nil when there is no such session, or no such conversation in it.
    func openSession(_ sessionID: String,
                     conversation: RemoteCommand.Conversation) async throws(StationRefusal) -> OpenedSession?
    func closeSession(_ sessionID: String) async
    func resync(_ sessionID: String) async
    // The session this client has on screen, or nil for none. A front end that shows
    // nothing, a list or another session reports that too.
    func show(_ sessionID: String?) async

    func sendPrompt(_ sessionID: String, prompt: String) async throws(StationRefusal)
    func recallPrompt(_ sessionID: String, _ direction: PromptRecall,
                      draft: String) async throws(StationRefusal) -> String?
    func stopTurn(_ sessionID: String) async throws(StationRefusal)
    func answerPermission(_ sessionID: String, requestID: String, answer: RemoteCommand.Answer,
                          answers: [String: String]?, reason: String?) async throws(StationRefusal)

    func sessionOptions() async throws(StationRefusal) -> RemoteSessionOptions
    func discoverModels(for agent: AgentKind) async throws(StationRefusal) -> RemoteSessionOptions
    func createSession(_ request: RemoteNewSession) async throws(StationRefusal) -> String

    func readChanges(_ sessionID: String) async throws(StationRefusal) -> RemoteChanges?
    // The changes now, then again each time they change. The stream ends when the session
    // goes away or the reader stops iterating.
    func changesUpdates(_ sessionID: String) -> AsyncStream<RemoteChanges>
    // `checkout` is a checkout's path as the changes name it; nil `paths` commits every
    // change there.
    func commitChanges(_ sessionID: String, checkout: String, message: String,
                       paths: [String]?) async throws(StationRefusal)
    func discardChanges(_ sessionID: String, checkout: String, paths: [String]) async throws(StationRefusal)
    // The recent commits of each of the session's checkouts and the pull requests it
    // opened (`StationHistory.swift`), and one commit's files with their diffs.
    func readHistory(_ sessionID: String) async throws(StationRefusal) -> RemoteHistory
    func readCommit(_ sessionID: String, checkout: String, hash: String) async throws(StationRefusal) -> RemoteCommit

    // Sync and branches (`StationSync`): the scope is a session's id, or a project's or
    // workspace's; `checkout` is one of its checkouts' paths.
    func readBranches(_ scope: String, checkout: String) async throws(StationRefusal) -> RemoteBranches
    func sync(_ scope: String, checkout: String, _ action: RemoteSyncAction) async throws(StationRefusal) -> RemoteSyncResult
    func switchBranch(_ scope: String, checkout: String, to branch: String,
                      creating: Bool) async throws(StationRefusal)

    // Answers a task's scheduled run that waits for confirmation. A run answers with the
    // id of the session it started.
    func confirmScheduledRun(_ taskID: String, _ choice: ScheduledRunChoice) async throws(StationRefusal) -> String?

    func readSettings() async throws(StationRefusal) -> RemoteSettings
    // Answers with the settings as they stand after the change.
    func changeSetting(_ id: String, to value: String) async throws(StationRefusal) -> RemoteSettings
    func readLog(_ sessionID: String) async throws(StationRefusal) -> RemoteSessionLog

    // Does one action to a session, or to the conversation opened in it, as the GUI does.
    @discardableResult
    func sessionAction(_ sessionID: String,
                       _ action: RemoteSessionAction) async throws(StationRefusal) -> RemoteSessionActionResult
    // What deleting the session would take and what it would leave, to ask with first.
    func sessionRemovalImpact(_ sessionID: String) async throws(StationRefusal) -> RemoteImpact

    func compactContext(_ sessionID: String) async throws(StationRefusal)
    func clearContext(_ sessionID: String) async throws(StationRefusal)
    func readContainerStatus(_ containerID: String) async throws(StationRefusal) -> RemoteContainerStatus

    // Command shortcuts (`StationShortcuts`): the scope is a project's or session's id,
    // or nil for the Mac's own list.
    func listShortcuts(in scope: String?) async throws(StationRefusal) -> RemoteShortcuts
    func runShortcut(_ shortcutID: String, in scope: String?) async throws(StationRefusal) -> RemoteShortcutOutput
    func stopShortcut(_ shortcutID: String, in scope: String?) async throws(StationRefusal) -> RemoteShortcutOutput
    func readShortcutOutput(_ shortcutID: String, in scope: String?) async throws(StationRefusal) -> RemoteShortcutOutput
    // Answers with the id of the shortcut saved.
    func saveShortcut(_ draft: RemoteShortcutDraft) async throws(StationRefusal) -> String
    func removeShortcut(_ shortcutID: String) async throws(StationRefusal)

    // The Explorer tab (see `StationExplorer.swift`). Paths are relative to the session's
    // working directory, "" for the root.
    func readFolder(_ sessionID: String, path: String) async throws(StationRefusal) -> RemoteFolder
    func searchFileNames(_ sessionID: String, query: String) async throws(StationRefusal) -> [RemoteFileEntry]
    func findInFiles(_ sessionID: String, query: String) async throws(StationRefusal) -> RemoteFindInFiles
    func createFile(_ sessionID: String, in folder: String, name: String,
                    isFolder: Bool) async throws(StationRefusal) -> RemoteFileEntry
    func renameFile(_ sessionID: String, path: String, to name: String) async throws(StationRefusal) -> RemoteFileEntry
    func trashFile(_ sessionID: String, path: String) async throws(StationRefusal)

    // What the host tells the person from now on, each event once. The stream ends when
    // the reader stops iterating.
    func hostEvents() -> AsyncStream<StationHostEvent>

    // Whether the host answers this client now, then each time that changes. A client in
    // the host's own process is always answered.
    func linkUpdates() -> AsyncStream<StationLink>

    // Asks the host to hand the station over to `successor`, or how the handover already
    // under way stands: the turns still running. Refused by a host that does not hand
    // over.
    func handOver(to successor: String) async throws(StationRefusal) -> StationHandoverStatus
    // Tells a host handing over, with no turn left running, to let go of the station. It
    // answers, then stops serving, saves, sweeps and releases the lock.
    func releaseStation() async throws(StationRefusal)

    // Answers with the project's id, the one it already is for a folder added before.
    func addProject(path: String) async throws(StationRefusal) -> String
    func changeProject(_ projectID: String, _ change: ProjectChange) async throws(StationRefusal)
    func readRemoval(_ removal: ProjectRemovalKind, of projectID: String) async throws(StationRefusal) -> RemoteImpact
    func remove(_ removal: ProjectRemovalKind, of projectID: String) async throws(StationRefusal)

    // The composer (see `StationComposer.swift`): the session's run settings for its next
    // turn, answered as they stand after a change.
    func readRunSettings(_ sessionID: String) async throws(StationRefusal) -> RemoteSettings
    func changeRunSetting(_ sessionID: String, _ id: String, to value: String) async throws(StationRefusal) -> RemoteSettings
    // A prompt with files attached by their path on the host and custom instructions.
    func sendPrompt(_ sessionID: String, _ prompt: RemotePrompt) async throws(StationRefusal)
    func listCommands(_ sessionID: String) async throws(StationRefusal) -> [RemoteSlashCommand]

    // Answers with the new workspace's id.
    func createWorkspace(name: String, projectIDs: [String], leadProjectID: String) async throws(StationRefusal) -> String
    func changeWorkspace(_ workspaceID: String, _ change: WorkspaceChange) async throws(StationRefusal)
    func readWorkspaceRemoval(_ workspaceID: String) async throws(StationRefusal) -> RemoteImpact
    func removeWorkspace(_ workspaceID: String) async throws(StationRefusal)
    // Answers with the new session's id.
    func createWorkspaceSession(_ request: RemoteNewWorkspaceSession) async throws(StationRefusal) -> String
    // Each member's folder, the lead first.
    func readWorkspaceChanges(_ workspaceID: String) async throws(StationRefusal) -> [RemoteCheckout]

    // Answers with the new task's id.
    func createTask(_ request: RemoteNewTask) async throws(StationRefusal) -> String
    func readTask(_ taskID: String) async throws(StationRefusal) -> RemoteTask
    func changeTask(_ taskID: String, _ change: TaskChange) async throws(StationRefusal)
    // Answers with the id of the run's session.
    func runTask(_ taskID: String, values: [String: String], note: String) async throws(StationRefusal) -> String

    // A session's Design conversation (see `StationDesign.swift`).
    func readDesign(_ sessionID: String) async throws(StationRefusal) -> RemoteDesignState
    func startDesign(_ sessionID: String) async throws(StationRefusal) -> RemoteDesignState
    func approveDesign(_ sessionID: String) async throws(StationRefusal) -> RemoteDesignState
    // Answers with the Build session's id.
    func implementDesign(_ sessionID: String, additionalContext: String?) async throws(StationRefusal) -> String

    // Troubleshooting (see `StationDiagnosis.swift`).
    func diagnosisOptions(sessionID: String?, agent: AgentKind?) async throws(StationRefusal) -> RemoteDiagnosisOptions
    // Answers with the diagnosis session's id.
    func startDiagnosis(_ request: RemoteDiagnosis) async throws(StationRefusal) -> String

    // Cleanup (`StationCleanup`): what rebuilding a session's lost checkouts would bring
    // back, then rebuilding them; the orphaned worktrees and pruning those named; the
    // old-sessions review and deleting the sessions chosen from it.
    func readRebuild(_ sessionID: String) async throws(StationRefusal) -> RemoteImpact
    func rebuild(_ sessionID: String) async throws(StationRefusal)
    func readOrphanedWorktrees() async throws(StationRefusal) -> [RemoteOrphanedWorktree]
    func pruneOrphanedWorktrees(paths: [String]) async throws(StationRefusal)
    func readOldSessions() async throws(StationRefusal) -> RemoteOldSessions
    func deleteOldSessions(_ sessionIDs: [String]) async throws(StationRefusal)

    func disconnect() async
}

extension StationInterface {
    public func linkUpdates() -> AsyncStream<StationLink> {
        AsyncStream { continuation in
            continuation.yield(.answering)
            continuation.finish()
        }
    }

    public func openSession(_ sessionID: String) async throws(StationRefusal) -> OpenedSession? {
        try await openSession(sessionID, conversation: .main)
    }

    public func answerPermission(_ sessionID: String, requestID: String,
                                 answer: RemoteCommand.Answer) async throws(StationRefusal) {
        try await answerPermission(sessionID, requestID: requestID, answer: answer, answers: nil, reason: nil)
    }

    public func answerPermission(_ sessionID: String, requestID: String, answer: RemoteCommand.Answer,
                                 answers: [String: String]?) async throws(StationRefusal) {
        try await answerPermission(sessionID, requestID: requestID, answer: answer, answers: answers, reason: nil)
    }

    public func answerPermission(_ sessionID: String, requestID: String, answer: RemoteCommand.Answer,
                                 reason: String?) async throws(StationRefusal) {
        try await answerPermission(sessionID, requestID: requestID, answer: answer, answers: nil, reason: reason)
    }
}

// Who a hold on a transcript, or a session on screen, belongs to: one connected client.
public struct StationClientID: Hashable, Sendable {
    let id = UUID()
}
