import Foundation
import Observation
import SwiftUI

struct PersistenceFailure: Error, Equatable, Sendable {
    let message: String
}

struct PendingSessionRemoval: Identifiable, Codable, Equatable {
    struct Worktree: Codable, Equatable, Sendable {
        let path: String
        let projectPath: String?
        let branch: String?
    }

    var id: UUID { session.id }
    let session: ChatSession
    let worktrees: [Worktree]
}

// Projects and their conversations. What the app knows about a session - its title, what
// it cost, where it runs - lives in one index file and is always in memory. The
// conversation itself is a file per session, read when the session is opened and dropped
// when nothing needs it, so a hundred sessions cost what one of them does.
//
// The running Claude Code process itself is owned by SessionRunner.
@MainActor
@Observable
final class ProjectStore {
    private(set) var projects: [Project] = []
    private(set) var workspaces: [ProjectWorkspace] = []
    // Session records without their transcripts. `messages` on one of these is only the
    // conversation while something holds it - see `hold(_:for:)`.
    private(set) var sessions: [ChatSession] = []
    @ObservationIgnored private var sidebarSessionCache: [ChatSession] = []
    private var sidebarSessionRevision = 0
    var selection: SidebarSelection? {
        // Opening a session is reading it, wherever the click came from, and it is also
        // what brings the conversation into memory - and lets the last one go.
        didSet {
            guard selection != oldValue else { return }
            if case .session(let id) = oldValue { release(id, for: .open) }
            if case .session(let id) = selection {
                finished.remove(id)
                hold(id, for: .open)
            }
        }
    }
    var selectedProjectID: UUID?

    // Sessions that ended a turn while the user was looking somewhere else. This is about
    // sitting in front of the app rather than about the conversation, so it is not saved:
    // a relaunch is not something to catch up on.
    private(set) var finished: Set<UUID> = []

    let storeURL: URL
    // One file per conversation, named by session id.
    let transcriptsURL: URL
    let removalJournalURL: URL
    private let files: PersistentFileClient
    private(set) var loadError: String?
    private(set) var saveError: String?
    private(set) var transcriptLoadErrors: [UUID: String] = [:]
    private(set) var pendingSessionRemovals: [PendingSessionRemoval] = []
    private var indexLoadError: String?
    private var removalJournalLoadError: String?

    // Why a conversation is in memory. The session on screen is held while it is open,
    // and a session with a turn in flight is held whether or not anyone is watching it,
    // since the reply has to land somewhere. A session nobody holds gives its messages
    // back to disk.
    enum TranscriptHold: Hashable { case open, running }

    private var holds: [UUID: Set<TranscriptHold>] = [:]

    private struct Persisted: Codable {
        var projects: [Project]
        var sessions: [ChatSession]
        // Optional so an index written before workspaces existed still decodes.
        var workspaces: [ProjectWorkspace]?
        // Written by an earlier version, which kept what was open in this file. It is a
        // preference now, so these are only read, to carry that choice over once.
        var selectedSessionID: UUID?
        var selectedProjectID: UUID?
    }

    private struct RemovalJournal: Codable {
        var removals: [PendingSessionRemoval]
    }

    init(storeURL: URL? = nil, files: PersistentFileClient = .live) {
        self.storeURL = storeURL
            ?? ProcessInfo.processInfo.environment["CONDUCTOR_STORE"]
                .map { URL(fileURLWithPath: $0) }
            ?? AppPaths.supportFile("projects.json", movedFrom: AppPaths.legacy("projects.json"))
        self.files = files
        // Named after the index rather than fixed, so a store pointed somewhere else -
        // a test, a second copy of the app - takes its conversations with it.
        transcriptsURL = self.storeURL.deletingLastPathComponent()
            .appendingPathComponent(self.storeURL.deletingPathExtension().lastPathComponent
                + "-transcripts", isDirectory: true)
        removalJournalURL = self.storeURL.deletingLastPathComponent()
            .appendingPathComponent(self.storeURL.deletingPathExtension().lastPathComponent
                + "-removals.json")
        loadRemovalJournal()
        load()
    }

    // MARK: - Lookups

    func project(_ id: UUID) -> Project? { projects.first { $0.id == id } }
    func workspace(_ id: UUID) -> ProjectWorkspace? { workspaces.first { $0.id == id } }
    func session(_ id: UUID) -> ChatSession? { sessions.first { $0.id == id } }

    // The rail needs session metadata, but observing the main array would also make it
    // observe every transcript write because ChatSession is a value. This copy is
    // published only when card metadata changes and never carries message payloads.
    var sidebarSessions: [ChatSession] {
        _ = sidebarSessionRevision
        return sidebarSessionCache
    }

    func sidebarSession(_ id: UUID) -> ChatSession? {
        sidebarSessions.first { $0.id == id }
    }

    func standaloneSessions(for projectID: UUID) -> [ChatSession] {
        sessions.filter { $0.projectID == projectID && $0.workspaceID == nil }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    func sessions(in workspaceID: UUID) -> [ChatSession] {
        sessions.filter { $0.workspaceID == workspaceID }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    var selectedSession: ChatSession? {
        guard case .session(let id) = selection else { return nil }
        return session(id)
    }

    var selectedProject: Project? {
        switch selection {
        case .session(let id): return session(id).flatMap { project($0.projectID) }
        case .home, .workspace: return nil
        case nil: return selectedProjectID.flatMap(project)
        }
    }

    // Home sits above project navigation. The last project stays remembered so leaving
    // Home takes the user back to the same working context instead of changing their place.
    func selectHome() {
        selection = .home
        saveIndex()
    }

    // Choosing a project is different from opening a conversation. Keeping the two
    // actions separate leaves the project screen available until a session is chosen.
    func selectProject(_ id: UUID) {
        guard project(id) != nil else { return }
        selectedProjectID = id
        selection = nil
        saveIndex()
    }

    func selectSession(_ id: UUID) {
        guard let session = session(id) else { return }
        selectedProjectID = session.projectID
        selection = .session(id)
        saveIndex()
    }

    func selectWorkspace(_ id: UUID) {
        guard workspace(id) != nil else { return }
        selection = .workspace(id)
        saveIndex()
    }

    // MARK: - Turns worth knowing about

    // A turn that ended. The session on screen needs no marker, since its result is
    // already being read.
    func noteTurnEnded(for sessionID: UUID) {
        if case .session(let open) = selection, open == sessionID { return }
        guard sessions.contains(where: { $0.id == sessionID }) else { return }
        finished.insert(sessionID)
    }

    func hasFinished(_ sessionID: UUID) -> Bool { finished.contains(sessionID) }

    // A collapsed project hides its sessions, so the count is what says how much is
    // waiting behind it.
    func finishedCount(in projectID: UUID) -> Int {
        sidebarSessions.filter {
            $0.projectID == projectID && $0.workspaceID == nil && finished.contains($0.id)
        }.count
    }

    func finishedCount(inWorkspace workspaceID: UUID) -> Int {
        sidebarSessions.filter { $0.workspaceID == workspaceID && finished.contains($0.id) }.count
    }

    // MARK: - Projects

    // A folder can only be added once: two projects on the same directory would be two
    // agents writing to the same files.
    @discardableResult
    func addProject(at url: URL) -> Project? {
        let path = url.standardizedFileURL.path
        if let existing = projects.first(where: { $0.path == path }) {
            selectedProjectID = existing.id
            return nil
        }
        let project = Project(url: url.standardizedFileURL)
        projects.append(project)
        projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        selectedProjectID = project.id
        saveIndex()
        return project
    }

    @discardableResult
    func addAdHocTask(named name: String,
                      in root: URL = AppPaths.support
                        .appendingPathComponent("ad-hoc-tasks", isDirectory: true))
        -> Result<Project, PersistenceFailure> {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(PersistenceFailure(message: "Enter a name for the ad-hoc task."))
        }

        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
        } catch {
            return .failure(PersistenceFailure(
                message: "The empty task folder could not be created: \(error.localizedDescription)"))
        }

        let previousProjectID = selectedProjectID
        let project = Project(name: trimmed, path: directory.standardizedFileURL.path,
                              kind: .adHoc)
        projects.append(project)
        projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        selectedProjectID = project.id
        markIndexDirty()
        guard save() else {
            projects.removeAll { $0.id == project.id }
            selectedProjectID = previousProjectID
            Preferences.selectedProjectID = previousProjectID
            markIndexDirty()
            try? FileManager.default.removeItem(at: directory)
            return .failure(persistenceFailure("The ad-hoc task could not be saved."))
        }
        return .success(project)
    }

    func removeProject(_ id: UUID) {
        let affected = Set(sessions.filter { session in
            session.projectID == id
                || session.sessionProjects?.contains(where: { $0.projectID == id }) == true
        }.map(\.id))
        projects.removeAll { $0.id == id }
        for sessionID in affected {
            if case .failure(let failure) = removeSession(sessionID) {
                saveError = failure.message
                return
            }
        }
        workspaces = workspaces.compactMap { workspace in
            var updated = workspace
            updated.projectIDs.removeAll { $0 == id }
            updated.worktreeProjectIDs.removeAll { $0 == id }
            guard updated.projectIDs.count >= 2 else { return nil }
            if updated.leadProjectID == id, let first = updated.projectIDs.first {
                updated.leadProjectID = first
            }
            return updated
        }
        if selectedProjectID == id { selectedProjectID = projects.first?.id }
        if case .session(let sessionID) = selection, affected.contains(sessionID) { selection = nil }
        if case .workspace(let workspaceID) = selection, workspace(workspaceID) == nil {
            selection = nil
        }
        saveIndex()
    }

    func renameProject(_ id: UUID, to name: String) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        projects[i].name = trimmed
        saveIndex()
    }

    // MARK: - Workspaces

    @discardableResult
    func addWorkspace(name: String, projectIDs: [UUID], leadProjectID: UUID) -> ProjectWorkspace? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen: Set<UUID> = []
        let members = projectIDs.filter { project($0) != nil && seen.insert($0).inserted }
        guard !trimmed.isEmpty, members.count >= 2, members.contains(leadProjectID) else { return nil }

        let ordered = [leadProjectID] + members.filter { $0 != leadProjectID }
        let worktreeProjectIDs = ordered.filter { id in
            project(id)?.isGitRepository ?? false
        }
        let workspace = ProjectWorkspace(name: trimmed, projectIDs: ordered,
                                         leadProjectID: leadProjectID,
                                         worktreeProjectIDs: worktreeProjectIDs)
        workspaces.append(workspace)
        workspaces.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        saveIndex()
        return workspace
    }

    func renameWorkspace(_ id: UUID, to name: String) {
        guard let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        workspaces[i].name = trimmed
        workspaces.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        saveIndex()
    }

    func setLeadProject(_ projectID: UUID, inWorkspace id: UUID) {
        guard let i = workspaces.firstIndex(where: { $0.id == id }),
              workspaces[i].projectIDs.contains(projectID) else { return }
        workspaces[i].leadProjectID = projectID
        workspaces[i].projectIDs.removeAll { $0 == projectID }
        workspaces[i].projectIDs.insert(projectID, at: 0)
        saveIndex()
    }

    func setUsesWorktree(_ usesWorktree: Bool, for projectID: UUID, inWorkspace id: UUID) {
        guard let i = workspaces.firstIndex(where: { $0.id == id }),
              workspaces[i].projectIDs.contains(projectID) else { return }
        workspaces[i].worktreeProjectIDs.removeAll { $0 == projectID }
        if usesWorktree { workspaces[i].worktreeProjectIDs.append(projectID) }
        saveIndex()
    }

    func addProject(_ projectID: UUID, toWorkspace id: UUID) {
        guard project(projectID) != nil,
              let i = workspaces.firstIndex(where: { $0.id == id }),
              !workspaces[i].projectIDs.contains(projectID) else { return }
        workspaces[i].projectIDs.append(projectID)
        if let project = project(projectID), project.isGitRepository {
            workspaces[i].worktreeProjectIDs.append(projectID)
        }
        saveIndex()
    }

    func removeProject(_ projectID: UUID, fromWorkspace id: UUID) {
        guard let i = workspaces.firstIndex(where: { $0.id == id }),
              workspaces[i].projectIDs.contains(projectID),
              workspaces[i].projectIDs.count > 2 else { return }
        workspaces[i].projectIDs.removeAll { $0 == projectID }
        workspaces[i].worktreeProjectIDs.removeAll { $0 == projectID }
        if workspaces[i].leadProjectID == projectID,
           let first = workspaces[i].projectIDs.first {
            workspaces[i].leadProjectID = first
        }
        saveIndex()
    }

    // MARK: - Sessions

    @discardableResult
    func newSession(in projectID: UUID, id: UUID = UUID(),
                    worktreePath: String? = nil, worktreeBranch: String? = nil,
                    agent: AgentKind = .claudeCode, model: String? = nil,
                    agentAvatarName: String? = nil,
                    isTroubleshooting: Bool = false) -> ChatSession {
        var session = ChatSession(id: id, projectID: projectID, agent: agent)
        session.worktreePath = worktreePath
        session.worktreeBranch = worktreeBranch
        session.settings = SessionSettings(model: ModelChoice.valid(model, for: agent))
        session.agentAvatarName = agentAvatarName
        session.isTroubleshooting = isTroubleshooting
        // Nothing has been said yet, and there is no file to go looking for.
        session.transcriptLoaded = true
        sessions.append(session)
        publishSidebarSessions()
        selectedProjectID = projectID
        selection = .session(session.id)
        saveIndex()
        return session
    }

    @discardableResult
    func newSession(in workspaceID: UUID, id: UUID = UUID(),
                    projects: [SessionProject], agent: AgentKind = .claudeCode,
                    model: String? = nil, agentAvatarName: String? = nil,
                    isTroubleshooting: Bool = false) -> ChatSession? {
        guard let workspace = workspace(workspaceID),
              projects.count >= 2,
              Set(projects.map(\.projectID)).count == projects.count,
              projects.first?.projectID == workspace.leadProjectID,
              projects.allSatisfy({ project($0.projectID) != nil }) else { return nil }

        var session = ChatSession(id: id, projectID: workspace.leadProjectID, agent: agent)
        session.workspaceID = workspaceID
        session.sessionProjects = projects
        session.worktreePath = projects.first?.worktreePath
        session.worktreeBranch = projects.first?.worktreeBranch
        session.settings = SessionSettings(model: ModelChoice.valid(model, for: agent))
        session.agentAvatarName = agentAvatarName
        session.isTroubleshooting = isTroubleshooting
        session.transcriptLoaded = true
        sessions.append(session)
        publishSidebarSessions()
        selectedProjectID = workspace.leadProjectID
        selection = .session(session.id)
        saveIndex()
        return session
    }

    func insertSession(in projectID: UUID, id: UUID = UUID(),
                       worktreePath: String? = nil, worktreeBranch: String? = nil,
                       agent: AgentKind = .claudeCode, model: String? = nil,
                       agentAvatarName: String? = nil,
                       isTroubleshooting: Bool = false)
        -> Result<ChatSession, PersistenceFailure> {
        let previousSelection = selection
        let previousProjectID = selectedProjectID
        let session = newSession(in: projectID, id: id,
                                 worktreePath: worktreePath,
                                 worktreeBranch: worktreeBranch,
                                 agent: agent,
                                 model: model,
                                 agentAvatarName: agentAvatarName,
                                 isTroubleshooting: isTroubleshooting)
        guard save() else {
            rollBackSessionInsertion(session.id, selection: previousSelection,
                                     projectID: previousProjectID)
            return .failure(persistenceFailure("The session could not be saved."))
        }
        return .success(session)
    }

    func insertSession(in workspaceID: UUID, id: UUID = UUID(),
                       projects: [SessionProject], agent: AgentKind = .claudeCode,
                       model: String? = nil, agentAvatarName: String? = nil,
                       isTroubleshooting: Bool = false)
        -> Result<ChatSession, PersistenceFailure> {
        let previousSelection = selection
        let previousProjectID = selectedProjectID
        guard let session = newSession(in: workspaceID, id: id, projects: projects,
                                       agent: agent, model: model,
                                       agentAvatarName: agentAvatarName,
                                       isTroubleshooting: isTroubleshooting) else {
            return .failure(PersistenceFailure(
                message: "The workspace no longer has a valid lead project."))
        }
        guard save() else {
            rollBackSessionInsertion(session.id, selection: previousSelection,
                                     projectID: previousProjectID)
            return .failure(persistenceFailure("The session could not be saved."))
        }
        return .success(session)
    }

    private func rollBackSessionInsertion(_ sessionID: UUID, selection: SidebarSelection?,
                                          projectID: UUID?) {
        sessions.removeAll { $0.id == sessionID }
        publishSidebarSessions()
        clearSessionMemory(sessionID)
        self.selection = selection
        selectedProjectID = projectID
        markIndexDirty()
    }

    // The folder a session's Claude Code runs in: its own worktree when it has one,
    // otherwise the project folder itself.
    func workingDirectory(for session: ChatSession) -> String? {
        workingDirectories(for: session).first
    }

    // All roots visible to the agent, with the lead first. Old single-project sessions
    // have no checkout snapshot and naturally resolve to their existing one-root form.
    func workingDirectories(for session: ChatSession) -> [String] {
        guard let checkouts = session.sessionProjects, !checkouts.isEmpty else {
            return (session.worktreePath ?? project(session.projectID)?.path).map { [$0] } ?? []
        }
        return checkouts.compactMap { checkout in
            checkout.worktreePath ?? project(checkout.projectID)?.path
        }
    }

    func checkoutProjects(for session: ChatSession) -> [SessionProject] {
        session.sessionProjects ?? [SessionProject(projectID: session.projectID,
                                                  worktreePath: session.worktreePath,
                                                  worktreeBranch: session.worktreeBranch)]
    }

    // A Git worktree keeps its writable metadata in the source repository. Codex needs
    // each of these roots explicitly because they sit outside all checkout directories.
    func gitMetadataDirectories(for session: ChatSession) -> [String] {
        checkoutProjects(for: session).compactMap { checkout in
            guard checkout.worktreePath != nil, let project = project(checkout.projectID) else {
                return nil
            }
            return project.path + "/.git"
        }
    }

    // What the next turn in this session runs with. The agent stays fixed on the session,
    // while the model and other run controls can change between turns.
    func setSettings(_ settings: SessionSettings, for sessionID: UUID) {
        guard let i = index(sessionID) else { return }
        guard sessions[i].settings != settings else { return }
        sessions[i].settings = settings
        saveIndex()
    }

    // A title the person typed is also what stops the first prompt from taking the title
    // over, since that only ever replaces the untouched "New session".
    func renameSession(_ sessionID: UUID, to title: String) {
        guard let i = index(sessionID) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, sessions[i].title != trimmed else { return }
        sessions[i].title = trimmed
        publishSidebarSessions()
        saveIndex()
    }

    func setAgentAvatarName(_ name: String?, for sessionID: UUID) {
        guard let i = index(sessionID), sessions[i].agentAvatarName != name else { return }
        sessions[i].agentAvatarName = name
        saveIndex()
    }

    func recordUsage(_ turn: TurnUsage, from agent: AgentKind, for sessionID: UUID) {
        guard let i = index(sessionID) else { return }
        var usage = sessions[i].usage ?? SessionUsage()
        usage.add(turn, from: agent)
        sessions[i].usage = usage
        publishSidebarSessions()
        scheduleIndexSave()
    }

    func recordContext(_ tokens: Int, contextWindow: Int?, model: String?,
                       from agent: AgentKind, for sessionID: UUID) {
        guard let i = index(sessionID) else { return }
        var usage = sessions[i].usage ?? SessionUsage()
        usage.noteContext(tokens, contextWindow: contextWindow, model: model, from: agent)
        sessions[i].usage = usage
        publishSidebarSessions()
        scheduleIndexSave()
    }

    func notePullRequest(_ pullRequest: PullRequest, for sessionID: UUID) {
        guard let i = index(sessionID), sessions[i].pullRequest != pullRequest else { return }
        sessions[i].pullRequest = pullRequest
        saveIndex()
    }

    // Sessions that opened a pull request before the app watched for them, and sessions
    // resumed from a transcript the app did not see arrive. Run when a session is opened,
    // so the strip is right whatever the conversation has been through.
    func findPullRequest(in sessionID: UUID) {
        guard let i = index(sessionID), sessions[i].pullRequest == nil else { return }
        loadTranscript(i)
        guard let found = PullRequestScanner.find(in: sessions[i]) else { return }
        sessions[i].pullRequest = found
        saveIndex()
    }

    @discardableResult
    func removeSession(_ id: UUID) -> Result<Void, PersistenceFailure> {
        if session(id) == nil, !pendingSessionRemovals.contains(where: { $0.id == id }) {
            return .success(())
        }
        switch prepareSessionRemoval(id) {
        case .success:
            return finishSessionRemoval(id)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    func prepareSessionRemoval(_ sessionID: UUID)
        -> Result<PendingSessionRemoval, PersistenceFailure> {
        if let pending = pendingSessionRemovals.first(where: { $0.id == sessionID }) {
            return .success(pending)
        }
        guard var session = session(sessionID) else {
            return .failure(PersistenceFailure(message: "The session is no longer in the app."))
        }
        guard save() else {
            return .failure(persistenceFailure(
                "The session could not be saved before removal started."))
        }
        let worktrees = checkoutProjects(for: session).compactMap { checkout in
            checkout.worktreePath.map { path in
                PendingSessionRemoval.Worktree(
                    path: path,
                    projectPath: project(checkout.projectID)?.path,
                    branch: checkout.worktreeBranch)
            }
        }
        session.messages = []
        session.transcriptLoaded = false
        let pending = PendingSessionRemoval(session: session, worktrees: worktrees)
        let updated = pendingSessionRemovals + [pending]
        switch persistRemovalJournal(updated) {
        case .success:
            pendingSessionRemovals = updated
            removeSessionFromMemory(sessionID)
            return .success(pending)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    // Safe only before worktree cleanup starts. Once any checkout may have been removed,
    // the durable removal has to remain pending and be retried instead.
    func cancelSessionRemoval(_ sessionID: UUID) -> Result<Void, PersistenceFailure> {
        guard let pending = pendingSessionRemovals.first(where: { $0.id == sessionID }) else {
            return .success(())
        }

        let restored = session(sessionID) == nil
        if restored {
            sessions.append(pending.session)
            markIndexDirty()
            guard save() else {
                sessions.removeAll { $0.id == sessionID }
                return .failure(persistenceFailure("The session could not be restored."))
            }
        }

        let updated = pendingSessionRemovals.filter { $0.id != sessionID }
        switch persistRemovalJournal(updated) {
        case .success:
            pendingSessionRemovals = updated
            if restored { publishSidebarSessions() }
            saveError = nil
            return .success(())
        case .failure(let failure):
            if restored { sessions.removeAll { $0.id == sessionID } }
            saveError = failure.message
            return .failure(failure)
        }
    }

    func finishSessionRemoval(_ sessionID: UUID) -> Result<Void, PersistenceFailure> {
        guard pendingSessionRemovals.contains(where: { $0.id == sessionID }) else {
            return session(sessionID) == nil
                ? .success(())
                : .failure(PersistenceFailure(
                    message: "The session removal was not prepared before cleanup."))
        }

        removeSessionFromMemory(sessionID)
        let transcriptResult = deleteTranscript(sessionID)
        markIndexDirty()
        let indexSaved = save()

        var failures: [String] = []
        if case .failure(let failure) = transcriptResult { failures.append(failure.message) }
        if !indexSaved {
            failures.append(persistenceFailure("The session index could not be saved.").message)
        }
        guard failures.isEmpty else {
            saveError = failures.joined(separator: "\n")
            return .failure(PersistenceFailure(message: saveError ?? failures[0]))
        }

        let updated = pendingSessionRemovals.filter { $0.id != sessionID }
        switch persistRemovalJournal(updated) {
        case .success:
            pendingSessionRemovals = updated
            saveError = nil
            return .success(())
        case .failure(let failure):
            saveError = failure.message
            return .failure(failure)
        }
    }

    private func removeSessionFromMemory(_ sessionID: UUID) {
        if let session = session(sessionID) {
            ToolPresentationCache.forget(session.messages.flatMap(\.tools).map(\.id))
        }
        sessions.removeAll { $0.id == sessionID }
        publishSidebarSessions()
        clearSessionMemory(sessionID)
        if case .session(sessionID) = selection { selection = nil }
    }

    private func clearSessionMemory(_ sessionID: UUID) {
        finished.remove(sessionID)
        holds[sessionID] = nil
        dirtyTranscripts.remove(sessionID)
        transcriptRevisions[sessionID] = nil
        transcriptLoadErrors[sessionID] = nil
    }

    private func deleteTranscript(_ sessionID: UUID) -> Result<Void, PersistenceFailure> {
        let url = transcriptURL(sessionID)
        // A debounced write may already be queued with an older snapshot. Delete on the
        // same queue after it, so that snapshot cannot recreate the removed transcript.
        let files = files
        return Self.writer.sync {
            do {
                try files.removeIfPresent(url)
                return .success(())
            } catch {
                return .failure(PersistenceFailure(
                    message: "The transcript at \(url.path) could not be deleted: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Holding a conversation in memory

    // Says this conversation is needed and reads it in if it is not already there. Every
    // hold has to be given back, but the same reason twice is one hold: a turn that
    // starts while the session is already running does not add a second.
    func hold(_ sessionID: UUID, for reason: TranscriptHold) {
        guard let i = index(sessionID) else { return }
        holds[sessionID, default: []].insert(reason)
        loadTranscript(i)
    }

    func release(_ sessionID: UUID, for reason: TranscriptHold) {
        holds[sessionID]?.remove(reason)
        if holds[sessionID]?.isEmpty ?? false { holds[sessionID] = nil }
        guard holds[sessionID] == nil, let i = index(sessionID),
              sessions[i].transcriptLoaded else { return }
        // Nothing may be dropped that is not on disk yet: the debounced write may still
        // be waiting on a turn that has just ended.
        save()
        guard !dirtyTranscripts.contains(sessionID) else { return }
        // The presentations were built from calls that are about to go, and the cache
        // has no other reason to hold on to them.
        ToolPresentationCache.forget(sessions[i].messages.flatMap(\.tools).map(\.id))
        sessions[i].messages = []
        sessions[i].transcriptLoaded = false
    }

    // Whether this session's conversation is in memory. Only worth asking in tests and
    // when deciding what to drop - everything else goes through a hold.
    func isTranscriptLoaded(_ sessionID: UUID) -> Bool {
        index(sessionID).map { sessions[$0].transcriptLoaded } ?? false
    }

    // A transcript nobody asked for still has to be read before it can be changed, so
    // every mutation below goes through here first. A missing file is an empty
    // conversation. A file that cannot be read stays protected from later writes.
    private func loadTranscript(_ i: Int) {
        guard !sessions[i].transcriptLoaded else { return }
        sessions[i].messages = readTranscript(sessions[i].id)
        sessions[i].transcriptLoaded = true
    }

    private func readTranscript(_ sessionID: UUID) -> [ChatMessage] {
        let url = transcriptURL(sessionID)
        do {
            guard let data = try files.readIfPresent(url) else {
                transcriptLoadErrors[sessionID] = nil
                return []
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let messages = try decoder.decode([ChatMessage].self, from: data)
            transcriptLoadErrors[sessionID] = nil
            return messages
        } catch let error as DecodingError {
            transcriptLoadErrors[sessionID] = PersistentFile.decodeMessage(for: url, error: error)
            return []
        } catch {
            transcriptLoadErrors[sessionID] = PersistentFile.loadMessage(for: url, error: error)
            return []
        }
    }

    private func transcriptURL(_ sessionID: UUID) -> URL {
        transcriptsURL.appendingPathComponent("\(sessionID.uuidString).json")
    }

    // MARK: - Mutating a conversation
    //
    // SessionRunner calls these as events stream in. Writes are frequent, so they are
    // debounced rather than run on every token.

    func append(_ message: ChatMessage, to sessionID: UUID) {
        guard let i = index(sessionID) else { return }
        loadTranscript(i)
        sessions[i].messages.append(message)
        sessions[i].summary.lastMessageAt = message.date
        if message.role == .user { sessions[i].retitleIfNeeded(from: message.text) }
        // The sidebar has its own lightweight copy, so activity must be published here
        // rather than waiting for the deferred transcript summary write.
        publishSidebarSessions()
        transcriptChanged(i)
    }

    func updateMessage(_ messageID: UUID, in sessionID: UUID, _ change: (inout ChatMessage) -> Void) {
        guard let i = index(sessionID) else { return }
        loadTranscript(i)
        guard let m = sessions[i].messages.firstIndex(where: { $0.id == messageID }) else { return }
        change(&sessions[i].messages[m])
        transcriptChanged(i)
    }

    // An answer given in the middle of a turn, written into the conversation between the
    // reply so far and the rest of it. A turn puts everything it says into the one
    // message it started with, so without splitting that in two the answer sits below
    // work that only happened because of it. Hands back the message the turn carries on
    // in, or nil if the session is gone.
    func recordAnswer(_ text: String, in sessionID: UUID, continuing messageID: UUID) -> UUID? {
        guard let i = index(sessionID) else { return nil }
        loadTranscript(i)
        // The question can come before the turn has said anything at all, and an empty
        // half of a reply is not worth keeping either side of the answer.
        if sessions[i].messages.first(where: { $0.id == messageID })?.isEmpty ?? false {
            sessions[i].messages.removeAll { $0.id == messageID }
        }
        sessions[i].messages.append(ChatMessage(role: .user, text: text))
        let carriesOn = ChatMessage(role: .assistant)
        sessions[i].messages.append(carriesOn)
        transcriptChanged(i)
        return carriesOn.id
    }

    // The conversation this session is having, read in if it is not in memory. Anything
    // that needs the messages themselves rather than what the sidebar says about them
    // comes through here.
    func transcript(of sessionID: UUID) -> [ChatMessage] {
        guard let i = index(sessionID) else { return [] }
        loadTranscript(i)
        return sessions[i].messages
    }

    // The summary the sidebar reads is rebuilt when the write lands rather than here:
    // a streaming reply changes the transcript many times a second, and deriving the
    // summary walks every call in the conversation.
    private func transcriptChanged(_ i: Int) {
        let sessionID = sessions[i].id
        dirtyTranscripts.insert(sessionID)
        transcriptRevisions[sessionID, default: 0] &+= 1
        markIndexDirty()
        scheduleSave()
    }

    func setAgentSessionID(_ agentID: String, agent: AgentKind, for sessionID: UUID) {
        guard let i = index(sessionID), sessions[i].agent == agent else { return }
        guard sessions[i].agentSessionID(for: agent) != agentID else { return }
        switch agent {
        case .claudeCode: sessions[i].claudeSessionID = agentID
        case .codex: sessions[i].codexSessionID = agentID
        }
        scheduleIndexSave()
    }

    // An agent keeps its own conversation history, and it can be pruned or removed
    // behind our back. Once that happens every resume fails, so the id has to be
    // droppable to let the next turn start a fresh conversation instead.
    func clearAgentSessionID(agent: AgentKind, for sessionID: UUID) {
        guard let i = index(sessionID) else { return }
        switch agent {
        case .claudeCode: sessions[i].claudeSessionID = nil
        case .codex: sessions[i].codexSessionID = nil
        }
        scheduleIndexSave()
    }

    // A turn that fails before Claude Code produces anything leaves an empty assistant
    // message behind; without this it would sit in the transcript forever.
    func removeMessage(_ messageID: UUID, from sessionID: UUID) {
        guard let i = index(sessionID) else { return }
        loadTranscript(i)
        sessions[i].messages.removeAll { $0.id == messageID }
        transcriptChanged(i)
    }

    private func index(_ sessionID: UUID) -> Int? {
        sessions.firstIndex { $0.id == sessionID }
    }

    // MARK: - Persistence

    private var saveTask: Task<Void, Never>?
    // What has changed since the last write. A streamed reply touches one conversation
    // and the numbers the sidebar shows for it, so those are the only two files that
    // ever need rewriting, however many sessions the app is holding.
    private var dirtyTranscripts: Set<UUID> = []
    private var transcriptRevisions: [UUID: Int] = [:]
    private var indexDirty = false
    private var indexRevision = 0
    private var saveGeneration = 0
    private var lastCompletedGeneration = 0
    private var asynchronousWriteInFlight = false
    private var saveAfterCurrentWrite = false

    // The index carries what the sidebar reads, so anything that changes a title, a
    // number or where a session runs goes through one of these.
    private func saveIndex() {
        markIndexDirty()
        save()
    }

    private func scheduleIndexSave() {
        markIndexDirty()
        scheduleSave()
    }

    private func markIndexDirty() {
        indexDirty = true
        indexRevision &+= 1
    }

    // Encoding a long conversation and putting it on disk is too much to pay between
    // frames of a streaming reply, so writes happen here instead of on the main actor.
    // One serial queue keeps them in order, and a caller that has to see the bytes on
    // disk before its next line waits on it.
    private static let writer = DispatchQueue(label: "com.teya.conductor.project-store-writes")

    private struct PendingTranscript: @unchecked Sendable {
        let sessionID: UUID
        let revision: Int
        let messages: [ChatMessage]
        let projectPath: String
        let url: URL
    }

    private struct PendingIndex: @unchecked Sendable {
        let revision: Int
        let value: Persisted
    }

    private struct WriteCompletion: Sendable {
        struct Summary: Sendable {
            let revision: Int
            let value: SessionSummary
        }

        let generation: Int
        var transcriptSuccesses: [UUID: Int] = [:]
        var summaries: [UUID: Summary] = [:]
        var transcriptFailures: [String] = []
        var indexRevision: Int?
        var indexSucceeded = false
        var indexFailure: String?
        var blockedFailures: [String] = []

        var failures: [String] {
            blockedFailures + transcriptFailures + [indexFailure].compactMap { $0 }
        }
    }

    // Coalesce the burst of writes that a streaming reply produces into one file write.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.save(waiting: false)
        }
    }

    // Returns with everything on disk. This is what dropping a transcript from memory
    // relies on, debounce or no debounce.
    @discardableResult
    func save() -> Bool { save(waiting: true) }

    @discardableResult
    private func save(waiting: Bool) -> Bool {
        saveTask?.cancel()
        saveTask = nil
        guard loadError == nil else {
            saveError = "Changes were not saved because the existing project index could not be loaded."
            return false
        }
        if !waiting, asynchronousWriteInFlight {
            saveAfterCurrentWrite = true
            return true
        }

        var transcripts: [PendingTranscript] = []
        var blockedFailures: [String] = []
        for sessionID in dirtyTranscripts {
            if let error = transcriptLoadErrors[sessionID] {
                blockedFailures.append(error)
                continue
            }
            // A session removed before its last write landed has nothing to write to.
            guard let i = index(sessionID), sessions[i].transcriptLoaded else {
                blockedFailures.append("The transcript for session \(sessionID) is not loaded and could not be saved.")
                continue
            }
            let root = workingDirectory(for: sessions[i]) ?? ""
            transcripts.append(PendingTranscript(sessionID: sessionID,
                                                 revision: transcriptRevisions[sessionID] ?? 0,
                                                 messages: sessions[i].messages,
                                                 projectPath: root,
                                                 url: transcriptURL(sessionID)))
        }

        var persisted: PendingIndex?
        if indexDirty, blockedFailures.isEmpty {
            var openSessionID: UUID?
            var openWorkspaceID: UUID?
            if case .session(let id) = selection { openSessionID = id }
            if case .workspace(let id) = selection { openWorkspaceID = id }
            Preferences.selectedSessionID = openSessionID
            Preferences.selectedWorkspaceID = openWorkspaceID
            Preferences.selectedProjectID = selectedProjectID
            persisted = PendingIndex(revision: indexRevision,
                                     value: Persisted(projects: projects, sessions: sessions,
                                                      workspaces: workspaces))
        }
        guard !transcripts.isEmpty || persisted != nil else {
            saveError = blockedFailures.isEmpty ? nil : blockedFailures.joined(separator: "\n")
            return blockedFailures.isEmpty && dirtyTranscripts.isEmpty && !indexDirty
        }

        let indexURL = storeURL
        let files = files
        let pendingTranscripts = transcripts
        let pendingIndex = persisted
        let pendingBlockedFailures = blockedFailures
        saveGeneration &+= 1
        let generation = saveGeneration
        let job: @Sendable () -> WriteCompletion = {
            var completion = WriteCompletion(generation: generation,
                                             blockedFailures: pendingBlockedFailures)
            // Only this app reads the transcripts back, so they skip the pretty
            // formatting; the index stays readable for a human poking at it.
            let transcriptEncoder = JSONEncoder()
            transcriptEncoder.outputFormatting = .withoutEscapingSlashes
            transcriptEncoder.dateEncodingStrategy = .iso8601
            for transcript in pendingTranscripts {
                let summary = SessionSummary.of(transcript.messages,
                                                projectPath: transcript.projectPath)
                do {
                    let data = try transcriptEncoder.encode(transcript.messages)
                    try files.write(data, transcript.url)
                    completion.transcriptSuccesses[transcript.sessionID] = transcript.revision
                    completion.summaries[transcript.sessionID] = WriteCompletion.Summary(
                        revision: transcript.revision, value: summary)
                } catch {
                    completion.transcriptFailures.append(
                        PersistentFile.saveMessage(for: transcript.url, error: error))
                }
            }
            guard let pendingIndex else { return completion }
            completion.indexRevision = pendingIndex.revision
            guard completion.transcriptFailures.isEmpty else {
                completion.indexFailure = "The project index was not saved because a transcript could not be saved."
                return completion
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            do {
                var value = pendingIndex.value
                for (sessionID, summary) in completion.summaries {
                    guard let i = value.sessions.firstIndex(where: { $0.id == sessionID }) else {
                        continue
                    }
                    value.sessions[i].summary = summary.value
                }
                let data = try encoder.encode(value)
                try files.write(data, indexURL)
                completion.indexSucceeded = true
            } catch {
                completion.indexFailure = PersistentFile.saveMessage(for: indexURL, error: error)
            }
            return completion
        }
        if waiting {
            finishWrite(Self.writer.sync(execute: job), asynchronous: false)
            return dirtyTranscripts.isEmpty && !indexDirty
        }
        asynchronousWriteInFlight = true
        Self.writer.async { [weak self] in
            let completion = job()
            Task { @MainActor in self?.finishWrite(completion, asynchronous: true) }
        }
        return blockedFailures.isEmpty
    }

    private func finishWrite(_ completion: WriteCompletion, asynchronous: Bool) {
        var summaryChanged = false
        for (sessionID, summary) in completion.summaries
        where transcriptRevisions[sessionID] == summary.revision {
            guard let i = index(sessionID) else { continue }
            summaryChanged = summaryChanged || sessions[i].summary != summary.value
            sessions[i].summary = summary.value
        }
        if summaryChanged { publishSidebarSessions() }
        for (sessionID, revision) in completion.transcriptSuccesses
        where transcriptRevisions[sessionID] == revision {
            dirtyTranscripts.remove(sessionID)
        }
        if completion.indexSucceeded, completion.indexRevision == indexRevision {
            indexDirty = false
        }
        if asynchronous {
            asynchronousWriteInFlight = false
            if saveAfterCurrentWrite {
                saveAfterCurrentWrite = false
                if !dirtyTranscripts.isEmpty || indexDirty { scheduleSave() }
            }
        }
        guard completion.generation >= lastCompletedGeneration else { return }
        lastCompletedGeneration = completion.generation
        let failures = completion.failures
        saveError = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    private func persistRemovalJournal(_ removals: [PendingSessionRemoval])
        -> Result<Void, PersistenceFailure> {
        guard removalJournalLoadError == nil else {
            return .failure(PersistenceFailure(
                message: "The pending removal journal could not be loaded and was not overwritten."))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(RemovalJournal(removals: removals))
            let files = files
            try Self.writer.sync { try files.write(data, removalJournalURL) }
            return .success(())
        } catch {
            let failure = PersistenceFailure(
                message: PersistentFile.saveMessage(for: removalJournalURL, error: error))
            saveError = failure.message
            return .failure(failure)
        }
    }

    private func loadRemovalJournal() {
        let data: Data?
        do {
            data = try files.readIfPresent(removalJournalURL)
        } catch {
            removalJournalLoadError = PersistentFile.loadMessage(
                for: removalJournalURL, error: error)
            refreshLoadError()
            return
        }
        guard let data else {
            removalJournalLoadError = nil
            pendingSessionRemovals = []
            refreshLoadError()
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            pendingSessionRemovals = try decoder.decode(RemovalJournal.self, from: data).removals
            removalJournalLoadError = nil
        } catch {
            removalJournalLoadError = PersistentFile.decodeMessage(
                for: removalJournalURL, error: error)
        }
        refreshLoadError()
    }

    private func refreshLoadError() {
        loadError = removalJournalLoadError ?? indexLoadError
    }

    private func persistenceFailure(_ fallback: String) -> PersistenceFailure {
        PersistenceFailure(message: saveError ?? fallback)
    }

    func load() {
        defer { publishSidebarSessions() }
        let data: Data?
        do {
            data = try files.readIfPresent(storeURL)
        } catch {
            indexLoadError = PersistentFile.loadMessage(for: storeURL, error: error)
            refreshLoadError()
            return
        }
        guard let data else {
            indexLoadError = nil
            refreshLoadError()
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved: Persisted
        do {
            saved = try decoder.decode(Persisted.self, from: data)
        } catch {
            indexLoadError = PersistentFile.decodeMessage(for: storeURL, error: error)
            refreshLoadError()
            return
        }
        indexLoadError = nil
        refreshLoadError()
        projects = saved.projects
        workspaces = saved.workspaces ?? []
        let pendingIDs = Set(pendingSessionRemovals.map(\.id))
        sessions = saved.sessions.filter { !pendingIDs.contains($0.id) }
        moveTranscriptsOutOfTheIndex()
        selectedProjectID = Preferences.selectedProjectID ?? saved.selectedProjectID ?? projects.first?.id
        if let id = Preferences.selectedSessionID ?? saved.selectedSessionID,
           sessions.contains(where: { $0.id == id }) {
            selection = .session(id)
        } else if let id = Preferences.selectedWorkspaceID, workspace(id) != nil {
            selection = .workspace(id)
        }
    }

    private func publishSidebarSessions() {
        sidebarSessionCache = sessions.map { session in
            var card = session
            card.messages = []
            card.transcriptLoaded = false
            return card
        }
        sidebarSessionRevision &+= 1
    }

    // An index written before conversations had files of their own carries them inline,
    // and decoding one is the only time a session arrives already loaded. Each is written
    // out once and dropped, which is also what fills in the summaries that version never
    // had. Runs once: from here on the index holds no messages to find.
    private func moveTranscriptsOutOfTheIndex() {
        let inline = sessions.indices.filter { sessions[$0].transcriptLoaded }
        guard !inline.isEmpty else { return }
        for i in inline {
            let sessionID = sessions[i].id
            dirtyTranscripts.insert(sessionID)
            transcriptRevisions[sessionID, default: 0] &+= 1
        }
        markIndexDirty()
        save()
        for i in inline where !dirtyTranscripts.contains(sessions[i].id) {
            ToolPresentationCache.forget(sessions[i].messages.flatMap(\.tools).map(\.id))
            sessions[i].messages = []
            sessions[i].transcriptLoaded = false
        }
    }

    // Projects whose folder has since been moved or deleted; sessions there cannot run.
    func isMissing(_ project: Project) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: project.path, isDirectory: &isDirectory)
        return !(exists && isDirectory.boolValue)
    }
}
