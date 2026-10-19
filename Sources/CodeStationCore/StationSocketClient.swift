import Foundation

// A client of a station host on the far side of its socket: the station interface,
// answered by sending each command as a request and turning what the host pushes back
// into the same streams the in-process client hands out.
//
// It connects on first use, or when `connect()` is called. If the host goes away after
// that, every request waiting on it is refused, and the client keeps trying the endpoint
// until a host answers there again. Then it subscribes to the list again, opens every
// session it had open again (each stream carries on with a fresh snapshot), and says
// again what it shows. A refused handshake (another version, another user) is final:
// every stream it handed out ends, and every command is refused with the reason.
//
// A host that takes the connection but does not answer the handshake within a few
// seconds (one busy handing over, with the connect queued in its listen backlog) is not
// waited on: the client lets that attempt go, says so through `linkUpdates()`, and keeps
// trying as it does after losing a host, so it attaches to whichever host advertises its
// endpoint next. After a longer limit it names who holds the station. Both limits run on
// the suspending clock, so a Mac that sleeps through them does not trip them.
@MainActor
public final class StationSocketClient: StationInterface {
    private enum State {
        case idle, connected, reconnecting, refused(StationRefusal), closed
    }

    // One stream this client hands out, and the subscription on the host that feeds it.
    @MainActor
    private final class Feed {
        enum Kind {
            case directory(AsyncStream<RemoteDirectory>.Continuation)
            case hostEvents(AsyncStream<StationHostEvent>.Continuation)
            case changes(sessionID: String, AsyncStream<RemoteChanges>.Continuation)
            // The session asked for, which conversation of it, and the id of the
            // conversation opened (what the reader addresses from then on).
            case session(requested: String, conversation: RemoteCommand.Conversation, opened: String,
                         AsyncStream<StationSessionEvent>.Continuation)
        }

        let kind: Kind
        var subscription: Int?
        // Whether a request for its subscription is on its way.
        var subscribing = false

        init(_ kind: Kind) {
            self.kind = kind
        }

        func finish() {
            switch kind {
            case .directory(let continuation): continuation.finish()
            case .hostEvents(let continuation): continuation.finish()
            case .changes(_, let continuation): continuation.finish()
            case .session(_, _, _, let continuation): continuation.finish()
            }
        }
    }

    // How long the client waits on a silent host: for the handshake's answer, and
    // before it names the station's holder to the person.
    public struct Patience: Sendable {
        public var handshake: Duration
        public var namingHolder: Duration

        public init(handshake: Duration, namingHolder: Duration) {
            self.handshake = handshake
            self.namingHolder = namingHolder
        }

        public static let standard = Patience(handshake: .seconds(3), namingHolder: .seconds(20))
    }

    private let endpoint: @Sendable () -> String?
    private let holder: @Sendable () -> StationLock.Holder?
    private let version: StationWire.Version
    private let retryInterval: Duration
    private let patience: Patience
    // How the host answers, for a front end to say, and who is following it.
    public private(set) var linkState: StationLink = .answering
    private var linkWatchers: [UUID: AsyncStream<StationLink>.Continuation] = [:]
    // Since when the host has taken connections without answering them.
    private var silentSince: SuspendingClock.Instant?
    private var state: State = .idle
    private var link: LineSocket?
    private var connecting: Task<StationRefusal?, Never>?
    private var greeting: CheckedContinuation<StationWire.Greeting?, Never>?
    private var nextID = 1
    private var pending: [Int: (Data?) -> Void] = [:]
    private var feeds: [ObjectIdentifier: Feed] = [:]
    private var bySubscription: [Int: Feed] = [:]
    private var shown: String?

    // `endpoint` is asked for the socket path at every attempt, so a client that reads
    // it from the station lock finds a host that came back on another path.
    // `holder` names who holds the station once the host has been silent past the
    // patience's longer limit.
    public init(endpoint: @escaping @Sendable () -> String?,
                holder: @escaping @Sendable () -> StationLock.Holder? = { nil },
                version: StationWire.Version = .current,
                retryInterval: Duration = .milliseconds(250), patience: Patience = .standard) {
        self.endpoint = endpoint
        self.holder = holder
        self.version = version
        self.retryInterval = retryInterval
        self.patience = patience
    }

    // A client of whichever host the station lock names, read again at every attempt.
    public convenience init(lockFile: URL, version: StationWire.Version = .current,
                            retryInterval: Duration = .milliseconds(250), patience: Patience = .standard) {
        self.init(endpoint: { StationLock.holder(at: lockFile)?.endpoint },
                  holder: { StationLock.holder(at: lockFile) },
                  version: version, retryInterval: retryInterval, patience: patience)
    }

    public convenience init(path: String, version: StationWire.Version = .current) {
        self.init(endpoint: { path }, version: version)
    }

    // Whether the host answered the handshake with a refusal, which no retry will change.
    public var isRefused: Bool {
        if case .refused = state { return true }
        return false
    }

    // Reaches the host now, rather than on the first command, so a front end can say
    // at once why it cannot.
    public func connect() async throws(StationRefusal) {
        try await ready()
    }

    // Lets go of the host at once, without waiting for it to answer. The host lets go of
    // everything this client had open when it sees the socket close.
    public func close() {
        guard !isClosed else { return }
        state = .closed
        connecting?.cancel()
        link?.close()
        link = nil
        failPending()
        for feed in feeds.values { feed.finish() }
        feeds = [:]
        bySubscription = [:]
        for watcher in linkWatchers.values { watcher.finish() }
        linkWatchers = [:]
    }

    private var isClosed: Bool {
        if case .closed = state { return true }
        return false
    }

    // MARK: - Station interface

    public func listDirectory() async throws(StationRefusal) -> RemoteDirectory {
        try await call(.listDirectory, as: RemoteDirectory.self)
    }

    public func directoryUpdates() -> AsyncStream<RemoteDirectory> {
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteDirectory.self,
                                                            bufferingPolicy: .bufferingNewest(1))
        let feed = Feed(.directory(continuation))
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.drop(feed) }
        }
        follow(feed)
        return stream
    }

    // How the host answers now, then each time that changes, until the client closes.
    public func linkUpdates() -> AsyncStream<StationLink> {
        let (stream, continuation) = AsyncStream.makeStream(of: StationLink.self,
                                                            bufferingPolicy: .bufferingNewest(1))
        guard !isClosed else {
            continuation.finish()
            return stream
        }
        let id = UUID()
        linkWatchers[id] = continuation
        continuation.yield(linkState)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.linkWatchers[id] = nil }
        }
        return stream
    }

    private func setLink(_ link: StationLink) {
        guard link != linkState else { return }
        linkState = link
        for watcher in linkWatchers.values { watcher.yield(link) }
    }

    // Followed across reconnects like the list. What the host said while this client
    // was away is not told again.
    public func hostEvents() -> AsyncStream<StationHostEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: StationHostEvent.self)
        let feed = Feed(.hostEvents(continuation))
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.drop(feed) }
        }
        follow(feed)
        return stream
    }

    // Followed across reconnects like the list. A session gone on the host ends it.
    public func changesUpdates(_ sessionID: String) -> AsyncStream<RemoteChanges> {
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteChanges.self,
                                                            bufferingPolicy: .bufferingNewest(1))
        let feed = Feed(.changes(sessionID: sessionID, continuation))
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.drop(feed) }
        }
        follow(feed)
        return stream
    }

    private func follow(_ feed: Feed) {
        feeds[ObjectIdentifier(feed)] = feed
        Task { [weak self] in await self?.subscribe(feed) }
    }

    public func openSession(_ sessionID: String,
                            conversation: RemoteCommand.Conversation) async throws(StationRefusal) -> OpenedSession? {
        if isClosed { return nil }
        try await ready()
        return try await request(.openSession(sessionID: sessionID, conversation: conversation),
                                 as: RemoteSnapshot?.self) { [weak self] id, snapshot in
            guard let self, let snapshot else { return nil }
            let (stream, continuation) = AsyncStream.makeStream(of: StationSessionEvent.self)
            let feed = Feed(.session(requested: sessionID, conversation: conversation,
                                     opened: snapshot.sessionID, continuation))
            self.register(feed, as: id)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.drop(feed, tellingHost: false) }
            }
            return OpenedSession(snapshot: snapshot, events: stream)
        }
    }

    public func closeSession(_ sessionID: String) async {
        for feed in feeds.values {
            guard case .session(_, _, let opened, _) = feed.kind, opened == sessionID else { continue }
            drop(feed, tellingHost: false)
            feed.finish()
        }
        if shown == sessionID { shown = nil }
        _ = try? await call(.closeSession(sessionID: sessionID), as: StationWire.Nothing.self)
    }

    public func resync(_ sessionID: String) async {
        _ = try? await call(.resync(sessionID: sessionID), as: StationWire.Nothing.self)
    }

    public func show(_ sessionID: String?) async {
        if isClosed { return }
        shown = sessionID
        _ = try? await call(.show(sessionID: sessionID), as: StationWire.Nothing.self)
    }

    public func sendPrompt(_ sessionID: String, prompt: String) async throws(StationRefusal) {
        _ = try await call(.sendPrompt(sessionID: sessionID, prompt: prompt), as: StationWire.Nothing.self)
    }

    public func recallPrompt(_ sessionID: String, _ direction: PromptRecall,
                             draft: String) async throws(StationRefusal) -> String? {
        try await call(.recallPrompt(sessionID: sessionID, direction: direction, draft: draft), as: String?.self)
    }

    public func stopTurn(_ sessionID: String) async throws(StationRefusal) {
        _ = try await call(.stopTurn(sessionID: sessionID), as: StationWire.Nothing.self)
    }

    public func answerPermission(_ sessionID: String, requestID: String, answer: RemoteCommand.Answer,
                                 answers: [String: String]?, reason: String?) async throws(StationRefusal) {
        _ = try await call(.answerPermission(sessionID: sessionID, requestID: requestID, answer: answer,
                                             answers: answers, reason: reason),
                           as: StationWire.Nothing.self)
    }

    public func sessionOptions() async throws(StationRefusal) -> RemoteSessionOptions {
        try await call(.sessionOptions, as: RemoteSessionOptions.self)
    }

    public func discoverModels(for agent: AgentKind) async throws(StationRefusal) -> RemoteSessionOptions {
        try await call(.discoverModels(agent: agent), as: RemoteSessionOptions.self)
    }

    public func createSession(_ request: RemoteNewSession) async throws(StationRefusal) -> String {
        try await call(.createSession(request), as: String.self)
    }

    public func readChanges(_ sessionID: String) async throws(StationRefusal) -> RemoteChanges? {
        try await call(.readChanges(sessionID: sessionID), as: RemoteChanges?.self)
    }

    public func commitChanges(_ sessionID: String, checkout: String, message: String,
                              paths: [String]?) async throws(StationRefusal) {
        _ = try await call(.commitChanges(sessionID: sessionID, checkout: checkout, message: message, paths: paths),
                           as: StationWire.Nothing.self)
    }

    public func discardChanges(_ sessionID: String, checkout: String, paths: [String]) async throws(StationRefusal) {
        _ = try await call(.discardChanges(sessionID: sessionID, checkout: checkout, paths: paths),
                           as: StationWire.Nothing.self)
    }

    public func readBranches(_ scope: String, checkout: String) async throws(StationRefusal) -> RemoteBranches {
        try await call(.readBranches(scope: scope, checkout: checkout), as: RemoteBranches.self)
    }

    public func sync(_ scope: String, checkout: String,
                     _ action: RemoteSyncAction) async throws(StationRefusal) -> RemoteSyncResult {
        try await call(.sync(scope: scope, checkout: checkout, action: action), as: RemoteSyncResult.self)
    }

    public func switchBranch(_ scope: String, checkout: String, to branch: String,
                             creating: Bool) async throws(StationRefusal) {
        _ = try await call(.switchBranch(scope: scope, checkout: checkout, branch: branch, creating: creating),
                           as: StationWire.Nothing.self)
    }

    public func readHistory(_ sessionID: String) async throws(StationRefusal) -> RemoteHistory {
        try await call(.readHistory(sessionID: sessionID), as: RemoteHistory.self)
    }

    public func readCommit(_ sessionID: String, checkout: String, hash: String) async throws(StationRefusal) -> RemoteCommit {
        try await call(.readCommit(sessionID: sessionID, checkout: checkout, hash: hash), as: RemoteCommit.self)
    }

    public func confirmScheduledRun(_ taskID: String, _ choice: ScheduledRunChoice) async throws(StationRefusal) -> String? {
        try await call(.confirmScheduledRun(taskID: taskID, choice: choice), as: String?.self)
    }

    public func readSettings() async throws(StationRefusal) -> RemoteSettings {
        try await call(.readSettings, as: RemoteSettings.self)
    }

    public func changeSetting(_ id: String, to value: String) async throws(StationRefusal) -> RemoteSettings {
        try await call(.changeSetting(id: id, value: value), as: RemoteSettings.self)
    }

    public func readLog(_ sessionID: String) async throws(StationRefusal) -> RemoteSessionLog {
        try await call(.readLog(sessionID: sessionID), as: RemoteSessionLog.self)
    }

    @discardableResult
    public func sessionAction(_ sessionID: String,
                              _ action: RemoteSessionAction) async throws(StationRefusal) -> RemoteSessionActionResult {
        try await call(.sessionAction(sessionID: sessionID, action: action), as: RemoteSessionActionResult.self)
    }

    public func sessionRemovalImpact(_ sessionID: String) async throws(StationRefusal) -> RemoteImpact {
        try await call(.sessionRemovalImpact(sessionID: sessionID), as: RemoteImpact.self)
    }

    public func addProject(path: String) async throws(StationRefusal) -> String {
        try await call(.addProject(path: path), as: String.self)
    }

    public func changeProject(_ projectID: String, _ change: ProjectChange) async throws(StationRefusal) {
        _ = try await call(.changeProject(projectID: projectID, change: change), as: StationWire.Nothing.self)
    }

    public func readRemoval(_ removal: ProjectRemovalKind, of projectID: String) async throws(StationRefusal) -> RemoteImpact {
        try await call(.readRemoval(removal: removal, projectID: projectID), as: RemoteImpact.self)
    }

    public func remove(_ removal: ProjectRemovalKind, of projectID: String) async throws(StationRefusal) {
        _ = try await call(.remove(removal: removal, projectID: projectID), as: StationWire.Nothing.self)
    }

    public func createTask(_ request: RemoteNewTask) async throws(StationRefusal) -> String {
        try await call(.createTask(request), as: String.self)
    }

    public func readTask(_ taskID: String) async throws(StationRefusal) -> RemoteTask {
        try await call(.readTask(taskID: taskID), as: RemoteTask.self)
    }

    public func changeTask(_ taskID: String, _ change: TaskChange) async throws(StationRefusal) {
        _ = try await call(.changeTask(taskID: taskID, change: change), as: StationWire.Nothing.self)
    }

    public func runTask(_ taskID: String, values: [String: String], note: String) async throws(StationRefusal) -> String {
        try await call(.runTask(taskID: taskID, values: values, note: note), as: String.self)
    }

    public func compactContext(_ sessionID: String) async throws(StationRefusal) {
        _ = try await call(.compactContext(sessionID: sessionID), as: StationWire.Nothing.self)
    }

    public func clearContext(_ sessionID: String) async throws(StationRefusal) {
        _ = try await call(.clearContext(sessionID: sessionID), as: StationWire.Nothing.self)
    }

    public func readContainerStatus(_ containerID: String) async throws(StationRefusal) -> RemoteContainerStatus {
        try await call(.readContainerStatus(containerID: containerID), as: RemoteContainerStatus.self)
    }

    public func createWorkspace(name: String, projectIDs: [String],
                                leadProjectID: String) async throws(StationRefusal) -> String {
        try await call(.createWorkspace(name: name, projectIDs: projectIDs, leadProjectID: leadProjectID),
                       as: String.self)
    }

    public func changeWorkspace(_ workspaceID: String, _ change: WorkspaceChange) async throws(StationRefusal) {
        _ = try await call(.changeWorkspace(workspaceID: workspaceID, change: change), as: StationWire.Nothing.self)
    }

    public func readRebuild(_ sessionID: String) async throws(StationRefusal) -> RemoteImpact {
        try await call(.readRebuild(sessionID: sessionID), as: RemoteImpact.self)
    }

    public func rebuild(_ sessionID: String) async throws(StationRefusal) {
        _ = try await call(.rebuild(sessionID: sessionID), as: StationWire.Nothing.self)
    }

    public func readOrphanedWorktrees() async throws(StationRefusal) -> [RemoteOrphanedWorktree] {
        try await call(.readOrphanedWorktrees, as: [RemoteOrphanedWorktree].self)
    }

    public func pruneOrphanedWorktrees(paths: [String]) async throws(StationRefusal) {
        _ = try await call(.pruneOrphanedWorktrees(paths: paths), as: StationWire.Nothing.self)
    }

    public func readOldSessions() async throws(StationRefusal) -> RemoteOldSessions {
        try await call(.readOldSessions, as: RemoteOldSessions.self)
    }

    public func deleteOldSessions(_ sessionIDs: [String]) async throws(StationRefusal) {
        _ = try await call(.deleteOldSessions(sessionIDs: sessionIDs), as: StationWire.Nothing.self)
    }

    public func readWorkspaceRemoval(_ workspaceID: String) async throws(StationRefusal) -> RemoteImpact {
        try await call(.readWorkspaceRemoval(workspaceID: workspaceID), as: RemoteImpact.self)
    }

    public func removeWorkspace(_ workspaceID: String) async throws(StationRefusal) {
        _ = try await call(.removeWorkspace(workspaceID: workspaceID), as: StationWire.Nothing.self)
    }

    public func createWorkspaceSession(_ request: RemoteNewWorkspaceSession) async throws(StationRefusal) -> String {
        try await call(.createWorkspaceSession(request), as: String.self)
    }

    public func readWorkspaceChanges(_ workspaceID: String) async throws(StationRefusal) -> [RemoteCheckout] {
        try await call(.readWorkspaceChanges(workspaceID: workspaceID), as: [RemoteCheckout].self)
    }

    public func readFolder(_ sessionID: String, path: String) async throws(StationRefusal) -> RemoteFolder {
        try await call(.readFolder(sessionID: sessionID, path: path), as: RemoteFolder.self)
    }

    public func searchFileNames(_ sessionID: String, query: String) async throws(StationRefusal) -> [RemoteFileEntry] {
        try await call(.searchFileNames(sessionID: sessionID, query: query), as: [RemoteFileEntry].self)
    }

    public func findInFiles(_ sessionID: String, query: String) async throws(StationRefusal) -> RemoteFindInFiles {
        try await call(.findInFiles(sessionID: sessionID, query: query), as: RemoteFindInFiles.self)
    }

    public func createFile(_ sessionID: String, in folder: String, name: String,
                           isFolder: Bool) async throws(StationRefusal) -> RemoteFileEntry {
        try await call(.createFile(sessionID: sessionID, folder: folder, name: name, isFolder: isFolder),
                       as: RemoteFileEntry.self)
    }

    public func renameFile(_ sessionID: String, path: String, to name: String) async throws(StationRefusal) -> RemoteFileEntry {
        try await call(.renameFile(sessionID: sessionID, path: path, name: name), as: RemoteFileEntry.self)
    }

    public func trashFile(_ sessionID: String, path: String) async throws(StationRefusal) {
        _ = try await call(.trashFile(sessionID: sessionID, path: path), as: StationWire.Nothing.self)
    }

    public func handOver(to successor: String) async throws(StationRefusal) -> StationHandoverStatus {
        try await call(.handOver(successor: successor), as: StationHandoverStatus.self)
    }

    public func releaseStation() async throws(StationRefusal) {
        _ = try await call(.releaseStation, as: StationWire.Nothing.self)
    }

    // Tells the host first, so everything this client had open is let go before the
    // call returns, then closes the socket.
    public func disconnect() async {
        if case .connected = state {
            _ = try? await call(.disconnect, as: StationWire.Nothing.self)
        }
        close()
    }

    // MARK: - Requests

    func call<Value: Decodable & Sendable>(_ request: StationRequest,
                                                   as type: Value.Type) async throws(StationRefusal) -> Value {
        try await ready()
        return try await self.request(request, as: type) { _, value in value }
    }

    // Sends one request and waits for its answer. `then` runs as the answer is read,
    // before the next line from the host, so a stream it registers misses no push.
    private func request<Value: Decodable, Answer: Sendable>(
        _ request: StationRequest, as type: Value.Type,
        then: @escaping @MainActor (Int, Value) -> Answer
    ) async throws(StationRefusal) -> Answer {
        guard case .connected = state, let link else { throw .hostGone }
        let id = nextID
        nextID += 1
        guard let data = StationWire.encode(StationWire.RequestFrame(id: id, request: request)) else {
            throw .garbled
        }
        let outcome: Result<Answer, StationRefusal> = await withCheckedContinuation { continuation in
            pending[id] = { line in
                guard let line else { return continuation.resume(returning: .failure(.hostGone)) }
                if let refusal = StationWire.decode(StationWire.Incoming.self, from: line)?.refusal {
                    return continuation.resume(returning: .failure(refusal))
                }
                guard let reply = StationWire.decode(StationWire.Reply<Value>.self, from: line) else {
                    return continuation.resume(returning: .failure(.garbled))
                }
                continuation.resume(returning: .success(then(id, reply.value)))
            }
            link.send(data)
        }
        return try outcome.get()
    }

    private func failPending() {
        let waiting = pending
        pending = [:]
        for answer in waiting.values { answer(nil) }
    }

    // MARK: - Connecting

    private func ready() async throws(StationRefusal) {
        switch state {
        case .connected: return
        case .refused(let refusal): throw refusal
        case .closed: throw .disconnected
        case .reconnecting: throw silentSince == nil ? .hostGone : .notAnswering
        case .idle: break
        }
        let attempt = connecting ?? Task { await self.attach() }
        connecting = attempt
        let failure = await attempt.value
        if connecting == attempt { connecting = nil }
        if let failure { throw failure }
    }

    // One attempt at reaching the host and getting past the handshake. Nil when it
    // worked; otherwise why not.
    private func attach() async -> StationRefusal? {
        guard let path = endpoint(), let fd = UnixSocket.connect(to: path) else { return .unreachable }
        let link = LineSocket(fd: fd)
        self.link = link
        // A host that never answers gives up its place to the next attempt.
        let silence = Task { [weak self, weak link, patience] in
            try? await Task.sleep(for: patience.handshake, clock: .suspending)
            guard !Task.isCancelled, let self, let link, self.link === link,
                  let waiting = self.greeting else { return }
            self.greeting = nil
            self.link = nil
            link.close()
            waiting.resume(returning: nil)
            self.hostIsSilent()
        }
        defer { silence.cancel() }
        let greeting: StationWire.Greeting? = await withCheckedContinuation { continuation in
            self.greeting = continuation
            link.start(onLine: { [weak self, weak link] line in
                guard let self, let link else { return }
                self.receive(line, on: link)
            }, onClose: { [weak self, weak link] in
                guard let self, let link else { return }
                self.lost(link)
            })
            link.send(StationWire.encode(StationWire.Hello(hello: version)) ?? Data())
        }
        if isClosed {
            link.close()
            return .disconnected
        }
        // A refusal is read before the host closes the socket, which may already have
        // been seen.
        if let refused = greeting?.refused {
            if self.link === link { self.link = nil }
            link.close()
            state = .refused(refused)
            // Final, so nothing will feed the streams handed out again: they end, and a
            // front end that asks learns why.
            for feed in feeds.values { feed.finish() }
            feeds = [:]
            bySubscription = [:]
            return refused
        }
        guard greeting?.welcome != nil, self.link === link else {
            if self.link === link { self.link = nil }
            link.close()
            return silentSince == nil ? .unreachable : .notAnswering
        }
        state = .connected
        silentSince = nil
        setLink(.answering)
        Task { await self.resume() }
        return nil
    }

    // The host took the connection and did not answer in time. The client says so, then
    // keeps trying, so it attaches to the next host that advertises an endpoint.
    private func hostIsSilent() {
        if silentSince == nil { silentSince = .now }
        noteSilence()
        if case .idle = state {
            state = .reconnecting
            Task { [weak self] in await self?.reconnect() }
        }
    }

    // Past the longer limit, the person is told who holds the station and how to stop it.
    private func noteSilence() {
        guard let silentSince else { return }
        let named = SuspendingClock.now - silentSince >= patience.namingHolder ? holder() : nil
        setLink(.notAnswering(holder: named))
    }

    private func receive(_ line: Data, on link: LineSocket) {
        guard link === self.link else { return }
        if let waiting = greeting {
            greeting = nil
            waiting.resume(returning: StationWire.decode(StationWire.Greeting.self, from: line))
            return
        }
        guard let incoming = StationWire.decode(StationWire.Incoming.self, from: line) else { return }
        if let subscription = incoming.subscription, let push = incoming.push {
            deliver(push, to: subscription)
        } else if let id = incoming.id {
            pending.removeValue(forKey: id)?(line)
        }
    }

    private func lost(_ link: LineSocket) {
        guard link === self.link else { return }
        self.link = nil
        if let waiting = greeting {
            greeting = nil
            waiting.resume(returning: nil)
        }
        failPending()
        guard case .connected = state else { return }
        state = .reconnecting
        bySubscription = [:]
        for feed in feeds.values { feed.subscription = nil }
        Task { [weak self] in await self?.reconnect() }
    }

    // Keeps trying until a host answers, then picks up where the client left off.
    private func reconnect() async {
        while case .reconnecting = state {
            try? await Task.sleep(for: retryInterval)
            guard case .reconnecting = state else { return }
            if await attach() == nil { break }
            // A silent host's listen backlog may be full by now, so attempts that cannot
            // connect at all keep the person's notice current too.
            noteSilence()
        }
    }

    // Once connected: every stream handed out is fed again, and the host hears again
    // what this client shows.
    private func resume() async {
        for feed in feeds.values {
            await subscribe(feed)
        }
        if let shown {
            _ = try? await call(.show(sessionID: shown), as: StationWire.Nothing.self)
        }
    }

    // MARK: - Subscriptions

    private func subscribe(_ feed: Feed) async {
        guard feeds[ObjectIdentifier(feed)] != nil, feed.subscription == nil, !feed.subscribing else { return }
        feed.subscribing = true
        defer { feed.subscribing = false }
        switch feed.kind {
        case .directory, .hostEvents, .changes:
            guard (try? await ready()) != nil else { return }
            let subscribing: StationRequest = switch feed.kind {
            case .directory: .subscribeDirectory
            case .changes(let sessionID, _): .subscribeChanges(sessionID: sessionID)
            default: .subscribeHostEvents
            }
            _ = try? await request(subscribing, as: StationWire.Nothing.self) { id, _ in
                // The reader may have stopped while the request was on its way.
                guard self.feeds[ObjectIdentifier(feed)] != nil else {
                    Task { _ = try? await self.call(.unsubscribe(subscription: id), as: StationWire.Nothing.self) }
                    return
                }
                self.register(feed, as: id)
            }
        case .session(let requested, let conversation, _, let continuation):
            let reopened = try? await request(.openSession(sessionID: requested, conversation: conversation),
                                              as: RemoteSnapshot?.self) { id, snapshot -> Bool in
                guard let snapshot else { return false }
                self.register(feed, as: id)
                continuation.yield(.snapshot(snapshot))
                return true
            }
            // Gone while the host was away, or the host could not be reached at all.
            if reopened == false {
                drop(feed, tellingHost: false)
                feed.finish()
            }
        }
    }

    private func register(_ feed: Feed, as subscription: Int) {
        guard !isClosed else { return }
        feeds[ObjectIdentifier(feed)] = feed
        feed.subscription = subscription
        bySubscription[subscription] = feed
    }

    private func deliver(_ push: StationPush, to subscription: Int) {
        guard let feed = bySubscription[subscription] else { return }
        switch (push, feed.kind) {
        case (.directory(let listing), .directory(let continuation)):
            continuation.yield(listing)
        case (.session(let event), .session(_, _, _, let continuation)):
            continuation.yield(event)
        case (.host(let event), .hostEvents(let continuation)):
            continuation.yield(event)
        case (.changes(let changes), .changes(_, let continuation)):
            continuation.yield(changes)
        case (.ended, _):
            drop(feed, tellingHost: false)
            feed.finish()
        default:
            break
        }
    }

    // The reader stopped reading. A live list is unsubscribed on the host; an open
    // session stays open there until it is closed, as it does in process.
    private func drop(_ feed: Feed, tellingHost: Bool = true) {
        guard feeds.removeValue(forKey: ObjectIdentifier(feed)) != nil else { return }
        guard let subscription = feed.subscription else { return }
        bySubscription[subscription] = nil
        guard tellingHost, case .connected = state else { return }
        Task { _ = try? await self.call(.unsubscribe(subscription: subscription), as: StationWire.Nothing.self) }
    }
}

extension StationRefusal {
    public static let hostGone = StationRefusal("The station host went away. Reconnecting…")
    public static let unreachable = StationRefusal("The station host is not running.")
    public static let notAnswering = StationRefusal(StationLink.notAnswering(holder: nil).message ?? "")
    static let disconnected = StationRefusal("This client has disconnected from the station.")
    static let garbled = StationRefusal("The station host sent something this client cannot read.")
}

// MARK: - Command shortcuts

extension StationSocketClient {
    public func listShortcuts(in scope: String?) async throws(StationRefusal) -> RemoteShortcuts {
        try await call(.listShortcuts(scope: scope), as: RemoteShortcuts.self)
    }

    public func runShortcut(_ shortcutID: String, in scope: String?) async throws(StationRefusal) -> RemoteShortcutOutput {
        try await call(.runShortcut(shortcutID: shortcutID, scope: scope), as: RemoteShortcutOutput.self)
    }

    public func stopShortcut(_ shortcutID: String, in scope: String?) async throws(StationRefusal) -> RemoteShortcutOutput {
        try await call(.stopShortcut(shortcutID: shortcutID, scope: scope), as: RemoteShortcutOutput.self)
    }

    public func readShortcutOutput(_ shortcutID: String, in scope: String?) async throws(StationRefusal) -> RemoteShortcutOutput {
        try await call(.readShortcutOutput(shortcutID: shortcutID, scope: scope), as: RemoteShortcutOutput.self)
    }

    public func saveShortcut(_ draft: RemoteShortcutDraft) async throws(StationRefusal) -> String {
        try await call(.saveShortcut(draft), as: String.self)
    }

    public func removeShortcut(_ shortcutID: String) async throws(StationRefusal) {
        _ = try await call(.removeShortcut(shortcutID: shortcutID), as: StationWire.Nothing.self)
    }
}

// How a client's host answers it, for a front end to say. A host that takes connections
// but does not answer them may be handing the station over, so the client keeps trying;
// past a longer limit it names who holds the station.
public enum StationLink: Equatable, Sendable {
    case answering
    case notAnswering(holder: StationLock.Holder?)

    // What a front end shows the person, or nil while the host answers.
    public var message: String? {
        switch self {
        case .answering:
            return nil
        case .notAnswering(nil):
            return "The station isn't answering. It may be handing over… retrying"
        case .notAnswering(let holder?):
            return "The station still isn't answering. \(holder.name.prefix(1).uppercased() + holder.name.dropFirst()) "
                + "holds it. To stop it, run kill \(holder.pid). Retrying…"
        }
    }
}
