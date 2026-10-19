import Foundation
import Observation

// One client of a station host in the same process. It keeps what this client follows
// and shows, and passes everything else to the host's engine, so two clients can follow
// one session and one closing it, or going away, leaves the other where it was.
@MainActor
public final class StationConnection: StationInterface {
    let client = StationClientID()
    let host: StationCommands
    private var sessionWatches: [UUID: SessionWatch] = [:]
    private var disconnected = false

    init(host: StationCommands) {
        self.host = host
    }

    private var store: ProjectStore { host.store }

    // MARK: - List directory

    public func listDirectory() -> RemoteDirectory {
        host.listDirectory()
    }

    public func directoryUpdates() -> AsyncStream<RemoteDirectory> {
        host.directoryUpdates()
    }

    public func hostEvents() -> AsyncStream<StationHostEvent> {
        host.hostEvents()
    }

    // MARK: - Open session

    // The session as it stands, then a stream of what moves in it. The transcript stays
    // held for this client until it closes the session. Opening it again starts a fresh
    // stream and ends the last one. Following a session is not reading it: a turn ending
    // there counts as read only while a front end shows it (see `show`).
    //
    // `conversation` picks the session's own conversation or its Design one, as the phone
    // does: a list row says which of the two it speaks for, so a Design companion waiting
    // on the person can be opened and answered. The snapshot's `sessionID` is the id of
    // the conversation opened, which is what every later command (send, stop, answer,
    // resync, close, recall, read changes) is addressed to. Nil when there is no such
    // session, or it has no Design conversation.
    public func openSession(_ sessionID: String,
                            conversation: RemoteCommand.Conversation) -> OpenedSession? {
        guard !disconnected,
              let main = UUID(uuidString: sessionID), store.session(main) != nil else { return nil }
        let target = conversation == .main ? store.session(main) : store.designConversation(for: main)
        guard let id = target?.id else { return nil }
        sessionWatches.removeValue(forKey: id)?.stop()
        store.hold(id, for: .client(client))
        guard let state = host.sessionState(id) else {
            store.release(id, for: .client(client))
            return nil
        }
        let (stream, continuation) = AsyncStream.makeStream(of: StationSessionEvent.self)
        let watch = SessionWatch(sessionID: id, conversation: conversation, continuation: continuation,
                                 baseline: RemoteSessionBaseline(state: state, marker: host.marker(id)))
        sessionWatches[id] = watch
        watch.timer = Task { @MainActor [weak self, weak watch] in
            while !Task.isCancelled {
                guard let self, let watch else { return }
                self.host.refreshWorkingTree(id)
                self.publish(to: watch)
                try? await Task.sleep(for: self.host.refreshInterval)
            }
        }
        continuation.onTermination = { _ in
            Task { @MainActor in watch.stop() }
        }
        return OpenedSession(snapshot: host.snapshot(id, state, conversation: conversation), events: stream)
    }

    // Ends the session's stream and lets go of its transcript. A session this client
    // showed is no longer on its screen.
    public func closeSession(_ sessionID: String) {
        guard let id = UUID(uuidString: sessionID),
              let watch = sessionWatches.removeValue(forKey: id) else { return }
        watch.stop()
        store.release(id, for: .client(client))
        if shown == id { show(nil) }
    }

    // Sends the session whole down its open stream, in order with the changes, for a
    // reader whose copy no longer fits the patches it is sent.
    public func resync(_ sessionID: String) {
        guard let id = UUID(uuidString: sessionID), let watch = sessionWatches[id] else { return }
        guard let state = host.sessionState(id) else {
            closeSession(sessionID)
            return
        }
        watch.baseline = RemoteSessionBaseline(state: state, marker: host.marker(id))
        watch.send(.snapshot(host.snapshot(id, state, conversation: watch.conversation)))
    }

    // Sends what moved since the reader's baseline. The marker is read under observation,
    // so the next change to anything it depends on publishes at once; the tick catches
    // what moves with time alone.
    private func publish(to watch: SessionWatch) {
        guard !watch.stopped else { return }
        let id = watch.sessionID
        let current: RemoteSessionMarker
        if watch.tracking {
            current = host.marker(id)
        } else {
            // As for the list, one tracker at most is pending.
            watch.tracking = true
            current = withObservationTracking {
                host.marker(id)
            } onChange: { [weak self, weak watch] in
                Task { @MainActor in
                    guard let self, let watch else { return }
                    watch.tracking = false
                    self.host.changeRebuilds += 1
                    self.publish(to: watch)
                }
            }
        }
        guard current != watch.baseline.marker else { return }
        guard let state = host.sessionState(id) else {
            closeSession(id.uuidString)
            return
        }
        let update = watch.baseline.update(to: state)
        watch.baseline = RemoteSessionBaseline(state: state, marker: current)
        if !update.isEmpty { watch.send(.update(update)) }
    }

    // MARK: - On screen

    private var shown: UUID?

    // The session this client has on screen, or none. A turn that ends there counts as
    // read, and what had finished there unseen is read now.
    public func show(_ sessionID: String?) {
        guard !disconnected else { return }
        let id = sessionID.flatMap(UUID.init(uuidString:)).flatMap { store.session($0)?.id }
        shown = id
        store.show(id, by: client)
    }

    // MARK: - Everything else is the host's

    public func sendPrompt(_ sessionID: String, prompt: String) throws(StationRefusal) {
        try host.sendPrompt(sessionID, prompt: prompt)
    }

    public func recallPrompt(_ sessionID: String, _ direction: PromptRecall, draft: String) -> String? {
        host.recallPrompt(sessionID, direction, draft: draft)
    }

    public func stopTurn(_ sessionID: String) throws(StationRefusal) {
        try host.stopTurn(sessionID)
    }

    public func answerPermission(_ sessionID: String, requestID: String, answer: RemoteCommand.Answer,
                                 answers: [String: String]?, reason: String?) throws(StationRefusal) {
        try host.answerPermission(sessionID, requestID: requestID, answer: answer,
                                  answers: answers, reason: reason)
    }

    public func sessionOptions() -> RemoteSessionOptions {
        host.sessionOptions()
    }

    public func discoverModels(for agent: AgentKind) async -> RemoteSessionOptions {
        await host.discoverModels(for: agent)
    }

    public func createSession(_ request: RemoteNewSession) async throws(StationRefusal) -> String {
        try await host.createSession(request)
    }

    public func readChanges(_ sessionID: String) async -> RemoteChanges? {
        await host.readChanges(sessionID)
    }

    public func changesUpdates(_ sessionID: String) -> AsyncStream<RemoteChanges> {
        host.changesUpdates(sessionID)
    }

    public func commitChanges(_ sessionID: String, checkout: String, message: String,
                              paths: [String]?) async throws(StationRefusal) {
        try await host.commitChanges(sessionID, checkout: checkout, message: message, paths: paths)
    }

    public func discardChanges(_ sessionID: String, checkout: String, paths: [String]) async throws(StationRefusal) {
        try await host.discardChanges(sessionID, checkout: checkout, paths: paths)
    }

    public func readBranches(_ scope: String, checkout: String) async throws(StationRefusal) -> RemoteBranches {
        try await host.readBranches(scope, checkout: checkout)
    }

    public func sync(_ scope: String, checkout: String,
                     _ action: RemoteSyncAction) async throws(StationRefusal) -> RemoteSyncResult {
        try await host.sync(scope, checkout: checkout, action)
    }

    public func switchBranch(_ scope: String, checkout: String, to branch: String,
                             creating: Bool) async throws(StationRefusal) {
        try await host.switchBranch(scope, checkout: checkout, to: branch, creating: creating)
    }

    public func readHistory(_ sessionID: String) async throws(StationRefusal) -> RemoteHistory {
        try await host.readHistory(sessionID)
    }

    public func readCommit(_ sessionID: String, checkout: String, hash: String) async throws(StationRefusal) -> RemoteCommit {
        try await host.readCommit(sessionID, checkout: checkout, hash: hash)
    }

    public func confirmScheduledRun(_ taskID: String, _ choice: ScheduledRunChoice) throws(StationRefusal) -> String? {
        try host.confirmScheduledRun(taskID, choice)
    }

    public func readSettings() -> RemoteSettings {
        host.readSettings()
    }

    public func changeSetting(_ id: String, to value: String) throws(StationRefusal) -> RemoteSettings {
        try host.changeSetting(id, to: value)
    }

    public func readLog(_ sessionID: String) throws(StationRefusal) -> RemoteSessionLog {
        try host.readLog(sessionID)
    }

    @discardableResult
    public func sessionAction(_ sessionID: String,
                              _ action: RemoteSessionAction) async throws(StationRefusal) -> RemoteSessionActionResult {
        guard !disconnected else { throw .noSession }
        return try await host.sessionAction(sessionID, action)
    }

    public func sessionRemovalImpact(_ sessionID: String) async throws(StationRefusal) -> RemoteImpact {
        try await host.sessionRemovalImpact(sessionID)
    }

    public func addProject(path: String) throws(StationRefusal) -> String {
        try host.addProject(path: path)
    }

    public func changeProject(_ projectID: String, _ change: ProjectChange) throws(StationRefusal) {
        try host.changeProject(projectID, change)
    }

    public func readRemoval(_ removal: ProjectRemovalKind, of projectID: String) throws(StationRefusal) -> RemoteImpact {
        try host.readRemoval(removal, of: projectID)
    }

    public func remove(_ removal: ProjectRemovalKind, of projectID: String) async throws(StationRefusal) {
        try await host.remove(removal, of: projectID)
    }

    public func createTask(_ request: RemoteNewTask) throws(StationRefusal) -> String {
        try host.createTask(request)
    }

    public func readTask(_ taskID: String) throws(StationRefusal) -> RemoteTask {
        try host.readTask(taskID)
    }

    public func changeTask(_ taskID: String, _ change: TaskChange) throws(StationRefusal) {
        try host.changeTask(taskID, change)
    }

    public func runTask(_ taskID: String, values: [String: String], note: String) throws(StationRefusal) -> String {
        try host.runTask(taskID, values: values, note: note)
    }

    public func compactContext(_ sessionID: String) throws(StationRefusal) {
        try host.compactContext(sessionID)
    }

    public func clearContext(_ sessionID: String) throws(StationRefusal) {
        try host.clearContext(sessionID)
    }

    public func readContainerStatus(_ containerID: String) async throws(StationRefusal) -> RemoteContainerStatus {
        try await host.readContainerStatus(containerID)
    }

    public func createWorkspace(name: String, projectIDs: [String],
                                leadProjectID: String) throws(StationRefusal) -> String {
        try host.createWorkspace(name: name, projectIDs: projectIDs, leadProjectID: leadProjectID)
    }

    public func changeWorkspace(_ workspaceID: String, _ change: WorkspaceChange) throws(StationRefusal) {
        try host.changeWorkspace(workspaceID, change)
    }

    public func readRebuild(_ sessionID: String) async throws(StationRefusal) -> RemoteImpact {
        try await host.readRebuild(sessionID)
    }

    public func rebuild(_ sessionID: String) async throws(StationRefusal) {
        try await host.rebuild(sessionID)
    }

    public func readOrphanedWorktrees() -> [RemoteOrphanedWorktree] {
        host.readOrphanedWorktrees()
    }

    public func pruneOrphanedWorktrees(paths: [String]) async throws(StationRefusal) {
        try await host.pruneOrphanedWorktrees(paths: paths)
    }

    public func readOldSessions() async -> RemoteOldSessions {
        await host.readOldSessions()
    }

    public func deleteOldSessions(_ sessionIDs: [String]) async throws(StationRefusal) {
        try await host.deleteOldSessions(sessionIDs)
    }

    public func readWorkspaceRemoval(_ workspaceID: String) throws(StationRefusal) -> RemoteImpact {
        try host.readWorkspaceRemoval(workspaceID)
    }

    public func removeWorkspace(_ workspaceID: String) async throws(StationRefusal) {
        try await host.removeWorkspace(workspaceID)
    }

    public func createWorkspaceSession(_ request: RemoteNewWorkspaceSession) async throws(StationRefusal) -> String {
        try await host.createWorkspaceSession(request)
    }

    public func readWorkspaceChanges(_ workspaceID: String) async throws(StationRefusal) -> [RemoteCheckout] {
        try await host.readWorkspaceChanges(workspaceID)
    }

    public func readFolder(_ sessionID: String, path: String) async throws(StationRefusal) -> RemoteFolder {
        try await host.readFolder(sessionID, path: path)
    }

    public func searchFileNames(_ sessionID: String, query: String) async throws(StationRefusal) -> [RemoteFileEntry] {
        try await host.searchFileNames(sessionID, query: query)
    }

    public func findInFiles(_ sessionID: String, query: String) async throws(StationRefusal) -> RemoteFindInFiles {
        try await host.findInFiles(sessionID, query: query)
    }

    public func createFile(_ sessionID: String, in folder: String, name: String,
                           isFolder: Bool) async throws(StationRefusal) -> RemoteFileEntry {
        try await host.createFile(sessionID, in: folder, name: name, isFolder: isFolder)
    }

    public func renameFile(_ sessionID: String, path: String, to name: String) async throws(StationRefusal) -> RemoteFileEntry {
        try await host.renameFile(sessionID, path: path, to: name)
    }

    public func trashFile(_ sessionID: String, path: String) async throws(StationRefusal) {
        try await host.trashFile(sessionID, path: path)
    }

    public func handOver(to successor: String) throws(StationRefusal) -> StationHandoverStatus {
        try host.handOver(to: successor, by: client)
    }

    public func releaseStation() throws(StationRefusal) {
        try host.releaseStation()
    }

    // MARK: - Going away

    // The client is gone: every session it followed is closed and nothing it showed is
    // on screen any more.
    public func disconnect() {
        guard !disconnected else { return }
        letGo()
        disconnected = true
        host.forget(client)
    }

    func letGo() {
        for id in Array(sessionWatches.keys) { closeSession(id.uuidString) }
        show(nil)
    }
}

// One open session's reader: what it has been sent, and the tick that keeps time-based
// states fresh.
@MainActor
private final class SessionWatch {
    let sessionID: UUID
    let conversation: RemoteCommand.Conversation
    let continuation: AsyncStream<StationSessionEvent>.Continuation
    var baseline: RemoteSessionBaseline
    var timer: Task<Void, Never>?
    // Whether an observation tracker is armed and has yet to fire.
    var tracking = false
    private(set) var stopped = false

    init(sessionID: UUID, conversation: RemoteCommand.Conversation,
         continuation: AsyncStream<StationSessionEvent>.Continuation, baseline: RemoteSessionBaseline) {
        self.sessionID = sessionID
        self.conversation = conversation
        self.continuation = continuation
        self.baseline = baseline
    }

    func send(_ event: StationSessionEvent) {
        guard !stopped else { return }
        continuation.yield(event)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        timer?.cancel()
        timer = nil
        continuation.finish()
    }
}

// MARK: - Command shortcuts

extension StationConnection {
    public func listShortcuts(in scope: String?) throws(StationRefusal) -> RemoteShortcuts {
        try host.listShortcuts(in: scope)
    }

    public func runShortcut(_ shortcutID: String, in scope: String?) throws(StationRefusal) -> RemoteShortcutOutput {
        try host.runShortcut(shortcutID, in: scope)
    }

    public func stopShortcut(_ shortcutID: String, in scope: String?) throws(StationRefusal) -> RemoteShortcutOutput {
        try host.stopShortcut(shortcutID, in: scope)
    }

    public func readShortcutOutput(_ shortcutID: String, in scope: String?) throws(StationRefusal) -> RemoteShortcutOutput {
        try host.readShortcutOutput(shortcutID, in: scope)
    }

    public func saveShortcut(_ draft: RemoteShortcutDraft) throws(StationRefusal) -> String {
        try host.saveShortcut(draft)
    }

    public func removeShortcut(_ shortcutID: String) throws(StationRefusal) {
        try host.removeShortcut(shortcutID)
    }
}
