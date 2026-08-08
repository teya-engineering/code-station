import Foundation
import Observation
import SwiftUI

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

    init() {
        storeURL = ProcessInfo.processInfo.environment["CONDUCTOR_STORE"]
            .map { URL(fileURLWithPath: $0) }
            ?? AppPaths.supportFile("projects.json", movedFrom: AppPaths.legacy("projects.json"))
        // Named after the index rather than fixed, so a store pointed somewhere else -
        // a test, a second copy of the app - takes its conversations with it.
        transcriptsURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent(storeURL.deletingPathExtension().lastPathComponent
                + "-transcripts", isDirectory: true)
        load()
    }

    // MARK: - Lookups

    func project(_ id: UUID) -> Project? { projects.first { $0.id == id } }
    func workspace(_ id: UUID) -> ProjectWorkspace? { workspaces.first { $0.id == id } }
    func session(_ id: UUID) -> ChatSession? { sessions.first { $0.id == id } }

    func standaloneSessions(for projectID: UUID) -> [ChatSession] {
        sessions.filter { $0.projectID == projectID && $0.workspaceID == nil }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func sessions(in workspaceID: UUID) -> [ChatSession] {
        sessions.filter { $0.workspaceID == workspaceID }.sorted { $0.createdAt > $1.createdAt }
    }

    var selectedSession: ChatSession? {
        guard case .session(let id) = selection else { return nil }
        return session(id)
    }

    var selectedProject: Project? {
        switch selection {
        case .session(let id): return session(id).flatMap { project($0.projectID) }
        case .workspace: return nil
        case nil: return selectedProjectID.flatMap(project)
        }
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
        sessions.filter {
            $0.projectID == projectID && $0.workspaceID == nil && finished.contains($0.id)
        }.count
    }

    func finishedCount(inWorkspace workspaceID: UUID) -> Int {
        sessions.filter { $0.workspaceID == workspaceID && finished.contains($0.id) }.count
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

    func removeProject(_ id: UUID) {
        let affected = Set(sessions.filter { session in
            session.projectID == id
                || session.sessionProjects?.contains(where: { $0.projectID == id }) == true
        }.map(\.id))
        projects.removeAll { $0.id == id }
        for sessionID in affected { forget(sessionID) }
        sessions.removeAll { affected.contains($0.id) }
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
            project(id).map { FileManager.default.fileExists(atPath: $0.path + "/.git") } ?? false
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
        if let project = project(projectID),
           FileManager.default.fileExists(atPath: project.path + "/.git") {
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
                    worktreePath: String? = nil, worktreeBranch: String? = nil) -> ChatSession {
        var session = ChatSession(id: id, projectID: projectID)
        session.worktreePath = worktreePath
        session.worktreeBranch = worktreeBranch
        // Nothing has been said yet, and there is no file to go looking for.
        session.transcriptLoaded = true
        sessions.append(session)
        selectedProjectID = projectID
        selection = .session(session.id)
        saveIndex()
        return session
    }

    @discardableResult
    func newSession(in workspaceID: UUID, id: UUID = UUID(),
                    projects: [SessionProject]) -> ChatSession? {
        guard let workspace = workspace(workspaceID),
              projects.count >= 2,
              Set(projects.map(\.projectID)).count == projects.count,
              projects.first?.projectID == workspace.leadProjectID,
              projects.allSatisfy({ project($0.projectID) != nil }) else { return nil }

        var session = ChatSession(id: id, projectID: workspace.leadProjectID)
        session.workspaceID = workspaceID
        session.sessionProjects = projects
        session.worktreePath = projects.first?.worktreePath
        session.worktreeBranch = projects.first?.worktreeBranch
        session.transcriptLoaded = true
        sessions.append(session)
        selectedProjectID = workspace.leadProjectID
        selection = .session(session.id)
        saveIndex()
        return session
    }

    // A diagnosis can span any set of projects without turning that one-off selection
    // into a saved workspace. The first project is the working directory and the rest
    // are attached roots, matching the way a workspace session reaches its files.
    @discardableResult
    func newSession(in projectIDs: [UUID], id: UUID = UUID()) -> ChatSession? {
        var seen: Set<UUID> = []
        let selected = projectIDs.filter { project($0) != nil && seen.insert($0).inserted }
        guard let lead = selected.first else { return nil }

        var session = ChatSession(id: id, projectID: lead)
        if selected.count > 1 {
            session.sessionProjects = selected.map {
                SessionProject(projectID: $0, worktreePath: nil, worktreeBranch: nil)
            }
        }
        session.transcriptLoaded = true
        sessions.append(session)
        selectedProjectID = lead
        selection = .session(session.id)
        saveIndex()
        return session
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

    // What the next turn in this session runs with. A turn already in flight keeps the
    // settings it started with, since its process is long past reading them.
    func setSettings(_ settings: SessionSettings, for sessionID: UUID) {
        guard let i = index(sessionID) else { return }
        guard sessions[i].settings != settings else { return }
        sessions[i].settings = settings
        saveIndex()
    }

    func recordUsage(_ turn: TurnUsage, from agent: AgentKind, for sessionID: UUID) {
        guard let i = index(sessionID) else { return }
        var usage = sessions[i].usage ?? SessionUsage()
        usage.add(turn, from: agent)
        sessions[i].usage = usage
        scheduleIndexSave()
    }

    func recordContext(_ tokens: Int, from agent: AgentKind, for sessionID: UUID) {
        guard let i = index(sessionID) else { return }
        var usage = sessions[i].usage ?? SessionUsage()
        usage.noteContext(tokens, from: agent)
        sessions[i].usage = usage
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

    func removeSession(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        forget(id)
        if case .session(id) = selection { selection = nil }
        saveIndex()
    }

    // Everything a deleted session leaves behind: its conversation on disk, its place in
    // the queue of things to write, and whatever was holding it in memory.
    private func forget(_ sessionID: UUID) {
        finished.remove(sessionID)
        holds[sessionID] = nil
        dirtyTranscripts.remove(sessionID)
        try? FileManager.default.removeItem(at: transcriptURL(sessionID))
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
    // every mutation below goes through here first. A session with no file yet - a new
    // one, or one whose file could not be read - counts as loaded and empty, which is
    // what it is.
    private func loadTranscript(_ i: Int) {
        guard !sessions[i].transcriptLoaded else { return }
        sessions[i].messages = readTranscript(sessions[i].id)
        sessions[i].transcriptLoaded = true
    }

    private func readTranscript(_ sessionID: UUID) -> [ChatMessage] {
        guard let data = try? Data(contentsOf: transcriptURL(sessionID)), !data.isEmpty else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ChatMessage].self, from: data)) ?? []
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
        if message.role == .user { sessions[i].retitleIfNeeded(from: message.text) }
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
        dirtyTranscripts.insert(sessions[i].id)
        indexDirty = true
        scheduleSave()
    }

    func setAgentSessionID(_ agentID: String, agent: AgentKind, for sessionID: UUID) {
        guard let i = index(sessionID) else { return }
        guard sessions[i].agentSessionID(for: agent) != agentID else { return }
        switch agent {
        case .claudeCode: sessions[i].claudeSessionID = agentID
        case .codex: sessions[i].codexSessionID = agentID
        }
        scheduleSave()
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
        scheduleSave()
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
    private var indexDirty = false

    // The index carries what the sidebar reads, so anything that changes a title, a
    // number or where a session runs goes through one of these.
    private func saveIndex() {
        indexDirty = true
        save()
    }

    private func scheduleIndexSave() {
        indexDirty = true
        scheduleSave()
    }

    // Encoding a long conversation and putting it on disk is too much to pay between
    // frames of a streaming reply, so writes happen here instead of on the main actor.
    // One serial queue keeps them in order, and a caller that has to see the bytes on
    // disk before its next line waits on it.
    private static let writer = DispatchQueue(label: "com.teya.conductor.project-store-writes")

    // Coalesce the burst of writes that a streaming reply produces into one file write.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.save(waiting: false)
        }
    }

    // Returns with everything on disk. This is what dropping a transcript from memory
    // relies on, debounce or no debounce.
    func save() { save(waiting: true) }

    private func save(waiting: Bool) {
        saveTask?.cancel()
        saveTask = nil

        // The summary is what the sidebar reads for every session it is not showing
        // the transcript of; deriving it walks the whole conversation, so it happens
        // once per write rather than once per streamed event.
        var transcripts: [(messages: [ChatMessage], url: URL)] = []
        for sessionID in dirtyTranscripts {
            // A session removed before its last write landed has nothing to write to.
            guard let i = index(sessionID), sessions[i].transcriptLoaded else { continue }
            let root = workingDirectory(for: sessions[i]) ?? ""
            sessions[i].summary = SessionSummary.of(sessions[i].messages, projectPath: root)
            transcripts.append((sessions[i].messages, transcriptURL(sessionID)))
        }
        dirtyTranscripts.removeAll()

        var persisted: Persisted?
        if indexDirty {
            indexDirty = false
            var openSessionID: UUID?
            var openWorkspaceID: UUID?
            if case .session(let id) = selection { openSessionID = id }
            if case .workspace(let id) = selection { openWorkspaceID = id }
            Preferences.selectedSessionID = openSessionID
            Preferences.selectedWorkspaceID = openWorkspaceID
            Preferences.selectedProjectID = selectedProjectID
            persisted = Persisted(projects: projects, sessions: sessions, workspaces: workspaces)
        }
        guard !transcripts.isEmpty || persisted != nil else { return }

        let transcriptsDirectory = transcriptsURL
        let indexURL = storeURL
        let pendingTranscripts = transcripts
        let pendingIndex = persisted
        let job: @Sendable () -> Void = {
            // Only this app reads the transcripts back, so they skip the pretty
            // formatting; the index stays readable for a human poking at it.
            let transcriptEncoder = JSONEncoder()
            transcriptEncoder.outputFormatting = .withoutEscapingSlashes
            transcriptEncoder.dateEncodingStrategy = .iso8601
            for transcript in pendingTranscripts {
                guard let data = try? transcriptEncoder.encode(transcript.messages) else { continue }
                Self.write(data, to: transcript.url, inside: transcriptsDirectory)
            }
            guard let persisted = pendingIndex else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(persisted) else { return }
            Self.write(data, to: indexURL, inside: indexURL.deletingLastPathComponent())
        }
        if waiting { Self.writer.sync(execute: job) } else { Self.writer.async(execute: job) }
    }

    private nonisolated static func write(_ data: Data, to url: URL, inside directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func load() {
        guard let data = try? Data(contentsOf: storeURL), !data.isEmpty else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let saved = try? decoder.decode(Persisted.self, from: data) else { return }
        projects = saved.projects
        workspaces = saved.workspaces ?? []
        sessions = saved.sessions
        moveTranscriptsOutOfTheIndex()
        selectedProjectID = Preferences.selectedProjectID ?? saved.selectedProjectID ?? projects.first?.id
        if let id = Preferences.selectedSessionID ?? saved.selectedSessionID,
           sessions.contains(where: { $0.id == id }) {
            selection = .session(id)
        } else if let id = Preferences.selectedWorkspaceID, workspace(id) != nil {
            selection = .workspace(id)
        }
    }

    // An index written before conversations had files of their own carries them inline,
    // and decoding one is the only time a session arrives already loaded. Each is written
    // out once and dropped, which is also what fills in the summaries that version never
    // had. Runs once: from here on the index holds no messages to find.
    private func moveTranscriptsOutOfTheIndex() {
        let inline = sessions.indices.filter { sessions[$0].transcriptLoaded }
        guard !inline.isEmpty else { return }
        for i in inline {
            let root = workingDirectory(for: sessions[i]) ?? ""
            sessions[i].summary = SessionSummary.of(sessions[i].messages, projectPath: root)
            dirtyTranscripts.insert(sessions[i].id)
        }
        indexDirty = true
        save()
        for i in inline {
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
