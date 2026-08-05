import Foundation
import Observation
import SwiftUI

// Projects and their conversations, persisted as one JSON file. Everything the app
// knows lives here; the running Claude Code process itself is owned by SessionRunner.
@MainActor
@Observable
final class ProjectStore {
    private(set) var projects: [Project] = []
    private(set) var sessions: [ChatSession] = []
    var selection: SidebarSelection? {
        // Opening a session is reading it, wherever the click came from.
        didSet {
            if case .session(let id) = selection { finished.remove(id) }
        }
    }
    var selectedProjectID: UUID?

    // Sessions that ended a turn while the user was looking somewhere else. This is about
    // sitting in front of the app rather than about the conversation, so it is not saved:
    // a relaunch is not something to catch up on.
    private(set) var finished: Set<UUID> = []

    let storeURL: URL

    private struct Persisted: Codable {
        var projects: [Project]
        var sessions: [ChatSession]
        // Written by an earlier version, which kept what was open in this file. It is a
        // preference now, so these are only read, to carry that choice over once.
        var selectedSessionID: UUID?
        var selectedProjectID: UUID?
    }

    init() {
        storeURL = ProcessInfo.processInfo.environment["CONDUCTOR_STORE"]
            .map { URL(fileURLWithPath: $0) }
            ?? AppPaths.supportFile("projects.json", movedFrom: AppPaths.legacy("projects.json"))
        load()
    }

    // MARK: - Lookups

    func project(_ id: UUID) -> Project? { projects.first { $0.id == id } }
    func session(_ id: UUID) -> ChatSession? { sessions.first { $0.id == id } }

    func sessions(for projectID: UUID) -> [ChatSession] {
        sessions.filter { $0.projectID == projectID }.sorted { $0.createdAt > $1.createdAt }
    }

    var selectedSession: ChatSession? {
        guard case .session(let id) = selection else { return nil }
        return session(id)
    }

    var selectedProject: Project? {
        guard let session = selectedSession else { return selectedProjectID.flatMap(project) }
        return project(session.projectID)
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
        sessions.filter { $0.projectID == projectID && finished.contains($0.id) }.count
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
        save()
        return project
    }

    func removeProject(_ id: UUID) {
        projects.removeAll { $0.id == id }
        for session in sessions where session.projectID == id { finished.remove(session.id) }
        sessions.removeAll { $0.projectID == id }
        if selectedProjectID == id { selectedProjectID = projects.first?.id }
        if let session = selectedSession, session.projectID == id { selection = nil }
        save()
    }

    func renameProject(_ id: UUID, to name: String) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        projects[i].name = trimmed
        save()
    }

    // MARK: - Sessions

    @discardableResult
    func newSession(in projectID: UUID, id: UUID = UUID(),
                    worktreePath: String? = nil, worktreeBranch: String? = nil) -> ChatSession {
        var session = ChatSession(id: id, projectID: projectID)
        session.worktreePath = worktreePath
        session.worktreeBranch = worktreeBranch
        sessions.append(session)
        selectedProjectID = projectID
        selection = .session(session.id)
        save()
        return session
    }

    // The folder a session's Claude Code runs in: its own worktree when it has one,
    // otherwise the project folder itself.
    func workingDirectory(for session: ChatSession) -> String? {
        session.worktreePath ?? project(session.projectID)?.path
    }

    // What the next turn in this session runs with. A turn already in flight keeps the
    // settings it started with, since its process is long past reading them.
    func setSettings(_ settings: SessionSettings, for sessionID: UUID) {
        guard let i = index(sessionID) else { return }
        guard sessions[i].settings != settings else { return }
        sessions[i].settings = settings
        save()
    }

    func recordUsage(_ turn: TurnUsage, for sessionID: UUID) {
        guard let i = index(sessionID) else { return }
        var usage = sessions[i].usage ?? SessionUsage()
        usage.add(turn)
        sessions[i].usage = usage
        scheduleSave()
    }

    func recordContext(_ tokens: Int, for sessionID: UUID) {
        guard let i = index(sessionID) else { return }
        var usage = sessions[i].usage ?? SessionUsage()
        usage.noteContext(tokens)
        sessions[i].usage = usage
        scheduleSave()
    }

    func notePullRequest(_ pullRequest: PullRequest, for sessionID: UUID) {
        guard let i = index(sessionID), sessions[i].pullRequest != pullRequest else { return }
        sessions[i].pullRequest = pullRequest
        save()
    }

    // Sessions that opened a pull request before the app watched for them, and sessions
    // resumed from a transcript the app did not see arrive. Run when a session is opened,
    // so the strip is right whatever the conversation has been through.
    func findPullRequest(in sessionID: UUID) {
        guard let i = index(sessionID), sessions[i].pullRequest == nil,
              let found = PullRequestScanner.find(in: sessions[i]) else { return }
        sessions[i].pullRequest = found
        save()
    }

    func removeSession(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        finished.remove(id)
        if case .session(id) = selection { selection = nil }
        save()
    }

    // MARK: - Mutating a conversation
    //
    // SessionRunner calls these as events stream in. Writes are frequent, so save()
    // is debounced rather than run on every token.

    func append(_ message: ChatMessage, to sessionID: UUID) {
        guard let i = index(sessionID) else { return }
        sessions[i].messages.append(message)
        if message.role == .user { sessions[i].retitleIfNeeded(from: message.text) }
        scheduleSave()
    }

    func updateMessage(_ messageID: UUID, in sessionID: UUID, _ change: (inout ChatMessage) -> Void) {
        guard let i = index(sessionID),
              let m = sessions[i].messages.firstIndex(where: { $0.id == messageID }) else { return }
        change(&sessions[i].messages[m])
        scheduleSave()
    }

    func setClaudeSessionID(_ claudeID: String, for sessionID: UUID) {
        guard let i = index(sessionID) else { return }
        guard sessions[i].claudeSessionID != claudeID else { return }
        sessions[i].claudeSessionID = claudeID
        scheduleSave()
    }

    // Claude Code keeps its own conversation history, and it can be pruned or removed
    // behind our back. Once that happens every `--resume` fails, so the id has to be
    // droppable to let the next turn start a fresh conversation instead.
    func clearClaudeSessionID(for sessionID: UUID) {
        guard let i = index(sessionID) else { return }
        sessions[i].claudeSessionID = nil
        scheduleSave()
    }

    // A turn that fails before Claude Code produces anything leaves an empty assistant
    // message behind; without this it would sit in the transcript forever.
    func removeMessage(_ messageID: UUID, from sessionID: UUID) {
        guard let i = index(sessionID) else { return }
        sessions[i].messages.removeAll { $0.id == messageID }
        scheduleSave()
    }

    private func index(_ sessionID: UUID) -> Int? {
        sessions.firstIndex { $0.id == sessionID }
    }

    // MARK: - Persistence

    private var saveTask: Task<Void, Never>?

    // Coalesce the burst of writes that a streaming reply produces into one file write.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        saveTask?.cancel()
        saveTask = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var openSessionID: UUID?
        if case .session(let id) = selection { openSessionID = id }
        Preferences.selectedSessionID = openSessionID
        Preferences.selectedProjectID = selectedProjectID

        let snapshot = Persisted(projects: projects, sessions: sessions)
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
    }

    func load() {
        guard let data = try? Data(contentsOf: storeURL), !data.isEmpty else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let saved = try? decoder.decode(Persisted.self, from: data) else { return }
        projects = saved.projects
        sessions = saved.sessions
        selectedProjectID = Preferences.selectedProjectID ?? saved.selectedProjectID ?? projects.first?.id
        if let id = Preferences.selectedSessionID ?? saved.selectedSessionID,
           sessions.contains(where: { $0.id == id }) {
            selection = .session(id)
        }
    }

    // Projects whose folder has since been moved or deleted; sessions there cannot run.
    func isMissing(_ project: Project) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: project.path, isDirectory: &isDirectory)
        return !(exists && isDirectory.boolValue)
    }
}
