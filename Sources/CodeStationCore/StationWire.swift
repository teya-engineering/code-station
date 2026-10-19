import Foundation

// What travels on the station socket: one JSON object per line.
//
// 1. The client says hello with its version. The host answers with its own (welcome) or
//    with a refusal naming both, then closes. A peer of another user is refused before
//    it says anything.
// 2. The client sends requests, each with an id. The host answers each with the same id
//    and either a value or a refusal, in the order the requests came.
// 3. A request that subscribes (the live list, an open session) is answered first; the
//    host then pushes what the stream sends, each push naming the request's id as its
//    subscription.
//
//   → {"hello":{"protocolVersion":1,"build":"1.2.3 (45)"}}
//   ← {"welcome":{"protocolVersion":1,"build":"1.2.3 (45)"}}
//   → {"id":1,"request":{"openSession":{"sessionID":"…","conversation":"main"}}}
//   ← {"id":1,"value":{"type":"snapshot",…}}
//   ← {"subscription":1,"push":{"session":{"event":{"type":"update",…}}}}
//   → {"id":2,"request":{"sendPrompt":{"sessionID":"…","prompt":"hi"}}}
//   ← {"id":2,"refusal":{"message":"Write a prompt first."}}
//
// A new command is one case in `StationRequest`, one line in its `perform`, and the
// client's method that sends it (`StationSocketClient`).
public enum StationWire {
    // Bumped whenever a change would confuse the other side. Additive fields are not.
    public static let protocolVersion = 1

    public struct Version: Codable, Equatable, Sendable, CustomStringConvertible {
        public var protocolVersion: Int
        public var build: String

        public init(protocolVersion: Int = StationWire.protocolVersion, build: String) {
            self.protocolVersion = protocolVersion
            self.build = build
        }

        // This binary's: the app's version when it runs from the app bundle, which ships
        // the GUI and the terminal binary together.
        public static let current = Version(build: StationWire.buildVersion())

        public var description: String { "build \(build), protocol \(protocolVersion)" }
    }

    static func buildVersion(_ info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?): return "\(short) (\(build))"
        case let (short?, nil): return short
        default: return "development"
        }
    }

    // MARK: - Frames

    struct Hello: Codable {
        let hello: Version
    }

    struct Greeting: Codable {
        var welcome: Version?
        var refused: StationRefusal?
    }

    struct RequestFrame: Codable, Sendable {
        let id: Int
        let request: StationRequest
    }

    struct ReplyFrame<Value: Encodable>: Encodable {
        let id: Int
        let value: Value
    }

    struct RefusalFrame: Codable {
        let id: Int
        let refusal: StationRefusal
    }

    struct PushFrame: Codable {
        let subscription: Int
        let push: StationPush
    }

    // What a client reads first from any line after the greeting, to route it.
    struct Incoming: Decodable {
        let id: Int?
        let refusal: StationRefusal?
        let subscription: Int?
        let push: StationPush?
    }

    struct Reply<Value: Decodable>: Decodable {
        let value: Value
    }

    // The value of a command that answers nothing.
    struct Nothing: Codable, Sendable {}

    static func encode(_ value: some Encodable) -> Data? {
        try? JSONEncoder().encode(value)
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) -> Value? {
        try? JSONDecoder().decode(type, from: data)
    }
}

// What a host pushes down a subscription.
enum StationPush: Codable, Sendable {
    case directory(listing: RemoteDirectory)
    case session(event: StationSessionEvent)
    // The open session's stream ended on the host: it was closed, opened again, or the
    // session went away.
    case ended
    // What the host told the person, down a host events subscription.
    case host(event: StationHostEvent)
    // A session's changes, down a changes subscription.
    case changes(RemoteChanges)
}

// Every command a client can send, one case each, named as the station interface names
// it. The host runs each on the client's own connection to the engine.
enum StationRequest: Codable, Sendable {
    case listDirectory
    case subscribeDirectory
    case unsubscribe(subscription: Int)
    case openSession(sessionID: String, conversation: RemoteCommand.Conversation)
    case closeSession(sessionID: String)
    case resync(sessionID: String)
    case show(sessionID: String?)
    case sendPrompt(sessionID: String, prompt: String)
    case recallPrompt(sessionID: String, direction: PromptRecall, draft: String)
    case stopTurn(sessionID: String)
    case answerPermission(sessionID: String, requestID: String, answer: RemoteCommand.Answer,
                          answers: [String: String]?, reason: String?)
    case sessionOptions
    case discoverModels(agent: AgentKind)
    case createSession(RemoteNewSession)
    case readChanges(sessionID: String)
    case subscribeChanges(sessionID: String)
    case commitChanges(sessionID: String, checkout: String, message: String, paths: [String]?)
    case discardChanges(sessionID: String, checkout: String, paths: [String])
    case readBranches(scope: String, checkout: String)
    case sync(scope: String, checkout: String, action: RemoteSyncAction)
    case switchBranch(scope: String, checkout: String, branch: String, creating: Bool)
    case readHistory(sessionID: String)
    case readCommit(sessionID: String, checkout: String, hash: String)
    case confirmScheduledRun(taskID: String, choice: ScheduledRunChoice)
    case readSettings
    case changeSetting(id: String, value: String)
    case readLog(sessionID: String)
    case sessionAction(sessionID: String, action: RemoteSessionAction)
    case sessionRemovalImpact(sessionID: String)
    case compactContext(sessionID: String)
    case clearContext(sessionID: String)
    case readContainerStatus(containerID: String)
    case listShortcuts(scope: String?)
    case runShortcut(shortcutID: String, scope: String?)
    case stopShortcut(shortcutID: String, scope: String?)
    case readShortcutOutput(shortcutID: String, scope: String?)
    case saveShortcut(RemoteShortcutDraft)
    case removeShortcut(shortcutID: String)
    case readFolder(sessionID: String, path: String)
    case searchFileNames(sessionID: String, query: String)
    case findInFiles(sessionID: String, query: String)
    case createFile(sessionID: String, folder: String, name: String, isFolder: Bool)
    case renameFile(sessionID: String, path: String, name: String)
    case trashFile(sessionID: String, path: String)
    case subscribeHostEvents
    case handOver(successor: String)
    case releaseStation
    case addProject(path: String)
    case changeProject(projectID: String, change: ProjectChange)
    case readRemoval(removal: ProjectRemovalKind, projectID: String)
    case remove(removal: ProjectRemovalKind, projectID: String)
    case readRunSettings(sessionID: String)
    case changeRunSetting(sessionID: String, id: String, value: String)
    case sendComposedPrompt(sessionID: String, prompt: RemotePrompt)
    case listCommands(sessionID: String)
    case readDesign(sessionID: String)
    case startDesign(sessionID: String)
    case approveDesign(sessionID: String)
    case implementDesign(sessionID: String, additionalContext: String?)
    case diagnosisOptions(sessionID: String?, agent: AgentKind?)
    case startDiagnosis(request: RemoteDiagnosis)
    case createWorkspace(name: String, projectIDs: [String], leadProjectID: String)
    case changeWorkspace(workspaceID: String, change: WorkspaceChange)
    case readRebuild(sessionID: String)
    case rebuild(sessionID: String)
    case readOrphanedWorktrees
    case pruneOrphanedWorktrees(paths: [String])
    case readOldSessions
    case deleteOldSessions(sessionIDs: [String])
    case readWorkspaceRemoval(workspaceID: String)
    case removeWorkspace(workspaceID: String)
    case createWorkspaceSession(RemoteNewWorkspaceSession)
    case readWorkspaceChanges(workspaceID: String)
    case createTask(RemoteNewTask)
    case readTask(taskID: String)
    case changeTask(taskID: String, change: TaskChange)
    case runTask(taskID: String, values: [String: String], note: String)
    case disconnect

    // What opens, closes or ends a stream, or lets the client go: these run one after
    // another in the order they came, so a stream is never closed before it opens.
    // Everything else starts as it arrives and does not wait for a slower command.
    var keepsOrder: Bool {
        switch self {
        case .subscribeDirectory, .subscribeHostEvents, .subscribeChanges, .unsubscribe,
             .openSession, .closeSession, .disconnect:
            true
        default:
            false
        }
    }

    // Runs the command for one client and answers with what goes back as its value.
    // `id` names the subscription a subscribing command starts.
    @MainActor
    func perform(id: Int, for peer: StationSocketPeer) async throws(StationRefusal) -> any Encodable & Sendable {
        let station = peer.station
        let nothing = StationWire.Nothing()
        switch self {
        case .listDirectory:
            return try await station.listDirectory()
        case .subscribeDirectory:
            peer.forward(station.directoryUpdates(), as: id, ending: nil) { .directory(listing: $0) }
            return nothing
        case .unsubscribe(let subscription):
            peer.cancel(subscription)
            return nothing
        case .openSession(let sessionID, let conversation):
            guard let opened = try await station.openSession(sessionID, conversation: conversation) else {
                return RemoteSnapshot?.none
            }
            peer.forward(opened.events, as: id, ending: .ended) { .session(event: $0) }
            return RemoteSnapshot?.some(opened.snapshot)
        case .closeSession(let sessionID):
            await station.closeSession(sessionID)
            return nothing
        case .resync(let sessionID):
            await station.resync(sessionID)
            return nothing
        case .show(let sessionID):
            await station.show(sessionID)
            return nothing
        case .sendPrompt(let sessionID, let prompt):
            try await station.sendPrompt(sessionID, prompt: prompt)
            return nothing
        case .recallPrompt(let sessionID, let direction, let draft):
            return try await station.recallPrompt(sessionID, direction, draft: draft)
        case .stopTurn(let sessionID):
            try await station.stopTurn(sessionID)
            return nothing
        case .answerPermission(let sessionID, let requestID, let answer, let answers, let reason):
            try await station.answerPermission(sessionID, requestID: requestID, answer: answer,
                                               answers: answers, reason: reason)
            return nothing
        case .sessionOptions:
            return try await station.sessionOptions()
        case .discoverModels(let agent):
            return try await station.discoverModels(for: agent)
        case .createSession(let request):
            return try await station.createSession(request)
        case .readChanges(let sessionID):
            return try await station.readChanges(sessionID)
        case .subscribeChanges(let sessionID):
            peer.forward(station.changesUpdates(sessionID), as: id, ending: .ended) { .changes($0) }
            return nothing
        case .commitChanges(let sessionID, let checkout, let message, let paths):
            try await station.commitChanges(sessionID, checkout: checkout, message: message, paths: paths)
            return nothing
        case .discardChanges(let sessionID, let checkout, let paths):
            try await station.discardChanges(sessionID, checkout: checkout, paths: paths)
            return nothing
        case .readBranches(let scope, let checkout):
            return try await station.readBranches(scope, checkout: checkout)
        case .sync(let scope, let checkout, let action):
            return try await station.sync(scope, checkout: checkout, action)
        case .switchBranch(let scope, let checkout, let branch, let creating):
            try await station.switchBranch(scope, checkout: checkout, to: branch, creating: creating)
            return nothing
        case .readHistory(let sessionID):
            return try await station.readHistory(sessionID)
        case .readCommit(let sessionID, let checkout, let hash):
            return try await station.readCommit(sessionID, checkout: checkout, hash: hash)
        case .confirmScheduledRun(let taskID, let choice):
            return try await station.confirmScheduledRun(taskID, choice)
        case .readSettings:
            return try await station.readSettings()
        case .changeSetting(let id, let value):
            return try await station.changeSetting(id, to: value)
        case .readLog(let sessionID):
            return try await station.readLog(sessionID)
        case .sessionAction(let sessionID, let action):
            return try await station.sessionAction(sessionID, action)
        case .sessionRemovalImpact(let sessionID):
            return try await station.sessionRemovalImpact(sessionID)
        case .compactContext(let sessionID):
            try await station.compactContext(sessionID)
            return nothing
        case .clearContext(let sessionID):
            try await station.clearContext(sessionID)
            return nothing
        case .readContainerStatus(let containerID):
            return try await station.readContainerStatus(containerID)
        case .listShortcuts(let scope):
            return try await station.listShortcuts(in: scope)
        case .runShortcut(let shortcutID, let scope):
            return try await station.runShortcut(shortcutID, in: scope)
        case .stopShortcut(let shortcutID, let scope):
            return try await station.stopShortcut(shortcutID, in: scope)
        case .readShortcutOutput(let shortcutID, let scope):
            return try await station.readShortcutOutput(shortcutID, in: scope)
        case .saveShortcut(let draft):
            return try await station.saveShortcut(draft)
        case .removeShortcut(let shortcutID):
            try await station.removeShortcut(shortcutID)
            return nothing
        case .readFolder(let sessionID, let path):
            return try await station.readFolder(sessionID, path: path)
        case .searchFileNames(let sessionID, let query):
            return try await station.searchFileNames(sessionID, query: query)
        case .findInFiles(let sessionID, let query):
            return try await station.findInFiles(sessionID, query: query)
        case .createFile(let sessionID, let folder, let name, let isFolder):
            return try await station.createFile(sessionID, in: folder, name: name, isFolder: isFolder)
        case .renameFile(let sessionID, let path, let name):
            return try await station.renameFile(sessionID, path: path, to: name)
        case .trashFile(let sessionID, let path):
            try await station.trashFile(sessionID, path: path)
            return nothing
        case .subscribeHostEvents:
            peer.forward(station.hostEvents(), as: id, ending: nil) { .host(event: $0) }
            return nothing
        case .handOver(let successor):
            return try await station.handOver(to: successor)
        case .releaseStation:
            try await station.releaseStation()
            return nothing
        case .addProject(let path):
            return try await station.addProject(path: path)
        case .changeProject(let projectID, let change):
            try await station.changeProject(projectID, change)
            return nothing
        case .readRemoval(let removal, let projectID):
            return try await station.readRemoval(removal, of: projectID)
        case .remove(let removal, let projectID):
            try await station.remove(removal, of: projectID)
            return nothing
        case .readRunSettings(let sessionID):
            return try await station.readRunSettings(sessionID)
        case .changeRunSetting(let sessionID, let id, let value):
            return try await station.changeRunSetting(sessionID, id, to: value)
        case .sendComposedPrompt(let sessionID, let prompt):
            try await station.sendPrompt(sessionID, prompt)
            return nothing
        case .listCommands(let sessionID):
            return try await station.listCommands(sessionID)
        case .readDesign(let sessionID):
            return try await station.readDesign(sessionID)
        case .startDesign(let sessionID):
            return try await station.startDesign(sessionID)
        case .approveDesign(let sessionID):
            return try await station.approveDesign(sessionID)
        case .implementDesign(let sessionID, let additionalContext):
            return try await station.implementDesign(sessionID, additionalContext: additionalContext)
        case .diagnosisOptions(let sessionID, let agent):
            return try await station.diagnosisOptions(sessionID: sessionID, agent: agent)
        case .startDiagnosis(let request):
            return try await station.startDiagnosis(request)
        case .createWorkspace(let name, let projectIDs, let leadProjectID):
            return try await station.createWorkspace(name: name, projectIDs: projectIDs, leadProjectID: leadProjectID)
        case .changeWorkspace(let workspaceID, let change):
            try await station.changeWorkspace(workspaceID, change)
            return nothing
        case .readRebuild(let sessionID):
            return try await station.readRebuild(sessionID)
        case .rebuild(let sessionID):
            try await station.rebuild(sessionID)
            return nothing
        case .readOrphanedWorktrees:
            return try await station.readOrphanedWorktrees()
        case .pruneOrphanedWorktrees(let paths):
            try await station.pruneOrphanedWorktrees(paths: paths)
            return nothing
        case .readOldSessions:
            return try await station.readOldSessions()
        case .deleteOldSessions(let sessionIDs):
            try await station.deleteOldSessions(sessionIDs)
            return nothing
        case .readWorkspaceRemoval(let workspaceID):
            return try await station.readWorkspaceRemoval(workspaceID)
        case .removeWorkspace(let workspaceID):
            try await station.removeWorkspace(workspaceID)
            return nothing
        case .createWorkspaceSession(let request):
            return try await station.createWorkspaceSession(request)
        case .readWorkspaceChanges(let workspaceID):
            return try await station.readWorkspaceChanges(workspaceID)
        case .createTask(let request):
            return try await station.createTask(request)
        case .readTask(let taskID):
            return try await station.readTask(taskID)
        case .changeTask(let taskID, let change):
            try await station.changeTask(taskID, change)
            return nothing
        case .runTask(let taskID, let values, let note):
            return try await station.runTask(taskID, values: values, note: note)
        case .disconnect:
            peer.cancelAll()
            await station.disconnect()
            return nothing
        }
    }
}
