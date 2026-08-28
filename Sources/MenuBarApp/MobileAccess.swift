import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Darwin
import Foundation
import Observation
import Security

// What a QR code opens on the phone: one session, one project, or the whole app. The
// reach is fixed when the code is made, so a phone can never work its way past what was
// shared with it.
enum MobileScope: Hashable {
    case session(UUID)
    case project(UUID)
    case everything

    // A session code lands on its session and stays there. The other two open on a list,
    // which is also what makes starting a session from the phone possible.
    var canBrowse: Bool {
        if case .session = self { return false }
        return true
    }

    var canCreate: Bool { canBrowse }

    func allows(_ session: ChatSession) -> Bool {
        switch self {
        case .session(let id): session.id == id
        case .project(let id): session.projectID == id
        case .everything: true
        }
    }

    func allows(project id: UUID) -> Bool {
        switch self {
        case .session: false
        case .project(let allowed): allowed == id
        case .everything: true
        }
    }
}

struct MobileShare: Identifiable, Equatable {
    let id: UUID
    let scope: MobileScope
    let url: URL
    let createdAt: Date
    var connectionID: UUID?

    var isConnected: Bool { connectionID != nil }
}

// One code that is out there, named and told apart from the others. The codes are made in
// three different corners of the app, so the header needs them gathered and described in
// one place to be able to list them and take any of them back.
struct MobileShareSummary: Identifiable {
    let id: UUID
    let scope: MobileScope
    let name: String
    let isConnected: Bool

    var reach: String {
        switch scope {
        case .session: "This session only"
        case .project: "Any session in this project"
        case .everything: "Every project"
        }
    }

    var state: String { isConnected ? "Phone connected" : "Waiting for a phone" }
}

struct LANInterfaceAddress: Equatable {
    let name: String
    let address: String
    let isUp: Bool
    let isRunning: Bool
}

enum LANAddress {
    static func preferredIPv4(from candidates: [LANInterfaceAddress]) -> String? {
        candidates
            .filter { $0.isUp && $0.isRunning && isUsableIPv4($0.address) }
            .sorted { rank($0) < rank($1) }
            .first?.address
    }

    static func currentIPv4() -> String? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return nil }
        defer { freeifaddrs(first) }

        var candidates: [LANInterfaceAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = cursor?.pointee {
            defer { cursor = interface.ifa_next }
            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(address, socklen_t(address.pointee.sa_len),
                                     &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            guard result == 0 else { continue }
            let flags = Int32(interface.ifa_flags)
            let numericAddress = String(
                decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            candidates.append(LANInterfaceAddress(
                name: String(cString: interface.ifa_name),
                address: numericAddress,
                isUp: flags & IFF_UP != 0,
                isRunning: flags & IFF_RUNNING != 0))
        }
        return preferredIPv4(from: candidates)
    }

    private static func rank(_ candidate: LANInterfaceAddress) -> Int {
        let privateAddress = isPrivate(candidate.address)
        if candidate.name == "en0", privateAddress { return 0 }
        if candidate.name.hasPrefix("en"), privateAddress { return 1 }
        if privateAddress { return 2 }
        if candidate.name == "en0" { return 3 }
        if candidate.name.hasPrefix("en") { return 4 }
        return 5
    }

    private static func isUsableIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ 0...255 ~= $0 }) else { return false }
        return parts[0] != 0 && parts[0] != 127 && !(parts[0] == 169 && parts[1] == 254)
    }

    private static func isPrivate(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10
            || (parts[0] == 172 && 16...31 ~= parts[1])
            || (parts[0] == 192 && parts[1] == 168)
    }
}

enum MobilePairingQRCode {
    static func image(for url: URL) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        else { return nil }
        // Keeping the Core Image representation avoids depending on a Metal renderer for
        // a bitmap that AppKit can draw directly, including on headless test machines.
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

private enum MobilePage {
    static var data: Data {
        guard let url = Bundle.module.url(forResource: "mobile-session", withExtension: "html"),
              let data = try? Data(contentsOf: url) else {
            return Data("Mobile session page is missing.".utf8)
        }
        return data
    }
}

@MainActor
@Observable
final class MobileAccessController {
    private struct Pairing {
        var share: MobileShare
        let secret: String
        // Where the phone had got to when it last dropped, so a reconnect lands back on
        // the session it was reading rather than at the top of the list.
        var openSession: UUID?
    }

    // One connected phone: the code it came in on, what that code lets it reach, and the
    // session it is reading, if any. A phone on the list is reading nothing.
    private struct Reader {
        let pairingID: UUID
        let scope: MobileScope
        var openSession: UUID?
    }

    private struct Marker: Equatable {
        let transcript: Int
        let session: String
        let project: String
        let agent: String
        let branch: String
        let state: String
        let failure: String
        let added: Int
        let removed: Int
        let context: Double
        let question: String?
        let queued: [UUID]
    }

    // What the status strip says about the working tree: the branch it is on and the
    // lines it has gained and lost. Read from the same cache the desktop strip reads, so
    // both surfaces answer "what has this session done" with one number.
    private struct WorkingTree {
        let branch: String?
        let added: Int
        let removed: Int
    }

    // What one phone has already drawn. Holding digests rather than a copy of the transcript
    // keeps the cost of a connected phone flat as the session grows.
    private struct RemoteView {
        var marker: Marker
        var header: RemoteHeader
        var order: [String]
        var messages: [String: RemoteMessageDigest]
        var queued: [RemoteQueuedPrompt]
        var permissionID: String?
    }

    private struct RemoteState {
        let header: RemoteHeader
        let order: [String]
        let messages: [RemoteMessage]
        let digests: [String: RemoteMessageDigest]
        let queued: [RemoteQueuedPrompt]
        let permission: RemotePermission?
    }

    private let store: ProjectStore
    private let runner: SessionRunner
    private let gitStats: GitStatsCache
    private var server: LANWebSocketServer?
    private var port: UInt16?
    private var pairings: [UUID: Pairing] = [:]
    private var pendingConnections: [UUID: UUID] = [:]
    private var readers: [UUID: Reader] = [:]
    private var views: [UUID: RemoteView] = [:]
    private var lists: [UUID: RemoteDirectory] = [:]
    // Making a session can take a while when git has to lay down a worktree, and the phone
    // has no way to see that its tap landed, so a second one is refused rather than run.
    private var creating: Set<UUID> = []
    private var expiryTasks: [UUID: Task<Void, Never>] = [:]
    private var streamTask: Task<Void, Never>?
    private(set) var enabled = false

    init(store: ProjectStore, runner: SessionRunner, gitStats: GitStatsCache) {
        self.store = store
        self.runner = runner
        self.gitStats = gitStats
    }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        if !enabled { stop() }
    }

    // One code per scope: asking for a scope that is already out hands back its code.
    func share(for scope: MobileScope) -> MobileShare? {
        pairings.values.first { $0.share.scope == scope }?.share
    }

    // Everything a phone can reach right now, newest first. A code that no phone has
    // scanned yet still counts, since it is access that has been given away.
    var activeShares: [MobileShareSummary] {
        pairings.values.map(\.share)
            .sorted { $0.createdAt > $1.createdAt }
            .map {
                MobileShareSummary(id: $0.id, scope: $0.scope,
                                   name: title(for: $0.scope), isConnected: isLive($0.scope))
            }
    }

    // A phone counts as being on a session whether it scanned that session's own code or
    // walked into it from a project or from the whole app.
    func isConnected(session sessionID: UUID) -> Bool {
        readers.values.contains { $0.openSession == sessionID }
    }

    // Whether a phone is on the other end of this code right now, including one that has
    // wandered off into another session of the same project.
    func isLive(_ scope: MobileScope) -> Bool {
        if case .session(let id) = scope, isConnected(session: id) { return true }
        return share(for: scope)?.isConnected == true
    }

    func startSharing(_ scope: MobileScope) async throws -> MobileShare {
        guard enabled else {
            throw LANServerFailure(message: "Turn on Mobile access in Settings first.")
        }
        try verify(scope)
        if let existing = share(for: scope) { return existing }

        let port = try await ensureServer()
        guard let address = LANAddress.currentIPv4() else {
            if pairings.isEmpty { stopServer() }
            throw LANServerFailure(
                message: "No local network address was found. Connect this Mac to the same Wi-Fi as the phone.")
        }

        let pairingID = UUID()
        let secret = try Self.makeSecret()
        var components = URLComponents()
        components.scheme = "http"
        components.host = address
        components.port = Int(port)
        components.path = "/mobile/\(pairingID.uuidString)"
        components.fragment = "secret=\(secret)"
        guard let url = components.url else {
            throw LANServerFailure(message: "The mobile access address could not be created.")
        }

        let share = MobileShare(id: pairingID, scope: scope, url: url,
                                createdAt: Date(), connectionID: nil)
        pairings[pairingID] = Pairing(share: share, secret: secret, openSession: nil)
        scheduleExpiry(for: pairingID)
        return share
    }

    private func verify(_ scope: MobileScope) throws {
        switch scope {
        case .session(let id) where store.session(id) == nil:
            throw LANServerFailure(message: "This session is no longer available.")
        case .project(let id) where store.project(id) == nil:
            throw LANServerFailure(message: "This project is no longer available.")
        default:
            break
        }
    }

    func revoke(_ scope: MobileScope) {
        guard let share = share(for: scope) else { return }
        expiryTasks.removeValue(forKey: share.id)?.cancel()
        pairings[share.id] = nil
        pendingConnections = pendingConnections.filter { $0.value != share.id }
        for (connectionID, reader) in readers where reader.pairingID == share.id {
            drop(connectionID)
        }
        if pairings.isEmpty { stopServer() }
        stopStreamIfIdle()
    }

    func stop() {
        for connectionID in Array(readers.keys) { drop(connectionID) }
        pendingConnections.removeAll()
        pairings.removeAll()
        expiryTasks.values.forEach { $0.cancel() }
        expiryTasks.removeAll()
        stopServer()
        streamTask?.cancel()
        streamTask = nil
    }

    // Forgets a phone and lets go of whatever it was holding. The socket closing comes
    // back as `closed`, which finds nothing left to do.
    private func drop(_ connectionID: UUID) {
        guard forget(connectionID) != nil else { return }
        server?.close(connectionID)
    }

    // Lets go of everything kept for one phone, and says which phone it was so the caller
    // can act on the code it came in on. Nil for a phone that was not being read.
    private func forget(_ connectionID: UUID) -> Reader? {
        guard let reader = readers.removeValue(forKey: connectionID) else { return nil }
        views[connectionID] = nil
        lists[connectionID] = nil
        creating.remove(connectionID)
        if let open = reader.openSession { store.release(open, for: .remote) }
        return reader
    }

    private func ensureServer() async throws -> UInt16 {
        if let port { return port }
        let created = LANWebSocketServer(
            page: MobilePage.data,
            onOpen: { [weak self] connectionID, pairingID in
                Task { @MainActor in self?.opened(connectionID, pairingID: pairingID) }
            },
            onMessage: { [weak self] connectionID, message in
                Task { @MainActor in self?.received(message, from: connectionID) }
            },
            onClose: { [weak self] connectionID in
                Task { @MainActor in self?.closed(connectionID) }
            })
        let port = try await created.start()
        server = created
        self.port = port
        return port
    }

    private func stopServer() {
        server?.stop()
        server = nil
        port = nil
    }

    private func opened(_ connectionID: UUID, pairingID: String) {
        guard let id = UUID(uuidString: pairingID), pairings[id] != nil else {
            server?.send(Self.error("This QR code is no longer valid."), to: connectionID)
            server?.close(connectionID)
            return
        }
        pendingConnections[connectionID] = id
    }

    private func received(_ message: String, from connectionID: UUID) {
        guard let data = message.data(using: .utf8),
              let command = try? JSONDecoder().decode(RemoteCommand.self, from: data) else {
            server?.send(Self.error("The phone sent a message Code Station could not read."),
                         to: connectionID)
            return
        }

        guard let reader = readers[connectionID] else {
            authenticate(command, connectionID: connectionID)
            return
        }

        switch command.type {
        case .authenticate:
            server?.send(Self.error("That mobile command is not supported."), to: connectionID)
        case .openSession:
            open(command.sessionID, for: connectionID)
        case .closeSession:
            leaveSession(connectionID)
        case .createSession:
            create(command, for: connectionID)
        case .resync:
            if let open = reader.openSession {
                sendSnapshot(to: connectionID, sessionID: open)
            } else {
                sendDirectory(to: connectionID, force: true)
            }
        case .sendPrompt:
            guard let sessionID = openSession(of: connectionID) else { return }
            let prompt = command.prompt?.trimmed ?? ""
            guard !prompt.isEmpty, prompt.count <= 100_000 else {
                server?.send(Self.error(prompt.isEmpty ? "Write a prompt first."
                                                       : "That prompt is too long."),
                             to: connectionID)
                return
            }
            runner.send(prompt, sessionID: sessionID, store: store)
        case .stopTurn:
            guard let sessionID = openSession(of: connectionID) else { return }
            runner.stop(sessionID)
        case .answerPermission:
            guard let sessionID = openSession(of: connectionID) else { return }
            answer(command, sessionID: sessionID, connectionID: connectionID)
        }
    }

    // The session a command that speaks to a session lands in. Nothing of the kind can
    // run from the list, so a phone on the list is told so, and one whose session has
    // gone is moved off it.
    private func openSession(of connectionID: UUID) -> UUID? {
        guard let sessionID = readers[connectionID]?.openSession else {
            server?.send(Self.error("Open a session first."), to: connectionID)
            return nil
        }
        guard store.session(sessionID) != nil else {
            sessionVanished(connectionID)
            return nil
        }
        return sessionID
    }

    private func authenticate(_ command: RemoteCommand, connectionID: UUID) {
        guard command.type == .authenticate,
              command.version == 1,
              let pairingID = pendingConnections[connectionID],
              var pairing = pairings[pairingID],
              let secret = command.secret,
              Self.securelyEqual(secret, pairing.secret) else {
            server?.send(Self.error("This QR code is not valid."), to: connectionID)
            server?.close(connectionID)
            return
        }

        let scope = pairing.share.scope
        if let gone = missing(scope) {
            server?.send(Self.error(gone), to: connectionID)
            server?.close(connectionID)
            revoke(scope)
            return
        }

        // One code, one phone: a second scan takes the code over rather than doubling it.
        if let previous = pairing.share.connectionID, previous != connectionID {
            drop(previous)
        }
        pendingConnections[connectionID] = nil
        readers[connectionID] = Reader(pairingID: pairingID, scope: scope, openSession: nil)
        pairing.share.connectionID = connectionID
        pairings[pairingID] = pairing
        expiryTasks.removeValue(forKey: pairingID)?.cancel()

        // A session code has only one place to be. A phone that dropped while reading is
        // put back where it was rather than at the top of the list.
        let resume: UUID? = if case .session(let id) = scope { id } else { pairing.openSession }
        if let resume, let session = store.session(resume), scope.allows(session) {
            open(resume.uuidString, for: connectionID)
        } else {
            sendDirectory(to: connectionID, force: true)
        }
        startStream()
    }

    private func missing(_ scope: MobileScope) -> String? {
        switch scope {
        case .session(let id):
            store.session(id) == nil ? "This session is no longer available." : nil
        case .project(let id):
            store.project(id) == nil ? "This project is no longer available." : nil
        case .everything:
            nil
        }
    }

    private func answer(_ command: RemoteCommand, sessionID: UUID, connectionID: UUID) {
        guard let request = runner.question(sessionID), request.id == command.requestID else {
            server?.send(Self.error("That question is no longer waiting for an answer."),
                         to: connectionID)
            return
        }
        let answer: PermissionAnswer?
        switch command.answer {
        case .allowOnce? where !request.isQuestion:
            answer = .allowOnce
        case .allowAlways? where !request.isQuestion && request.alwaysTitle != nil:
            answer = .allowAlways
        case .deny? where !request.isQuestion:
            answer = .deny
        case .answers? where request.isQuestion:
            let given = command.answers ?? [:]
            answer = request.questions.allSatisfy { given[$0.text]?.isBlank == false }
                ? .answers(given) : nil
        case .allowOnce?, .allowAlways?, .deny?, .answers?, nil:
            answer = nil
        }
        guard let answer else {
            server?.send(Self.error("That answer is not valid for this question."),
                         to: connectionID)
            return
        }
        runner.answer(request, with: answer, sessionID: sessionID, store: store)

        // Saying no is rarely the whole answer: the reason typed with it goes on as a
        // prompt, so the agent hears why rather than only that it was refused.
        let reason = command.prompt?.trimmed ?? ""
        if answer == .deny, !reason.isEmpty, reason.count <= 100_000 {
            runner.send(reason, sessionID: sessionID, store: store)
        }
    }

    private func closed(_ connectionID: UUID) {
        pendingConnections[connectionID] = nil
        guard let reader = forget(connectionID) else { return }
        if var pairing = pairings[reader.pairingID], pairing.share.connectionID == connectionID {
            pairing.share.connectionID = nil
            pairing.openSession = reader.openSession
            pairings[reader.pairingID] = pairing
            scheduleExpiry(for: reader.pairingID)
        }
        stopStreamIfIdle()
    }

    // MARK: - Moving between sessions

    private func open(_ sessionID: String?, for connectionID: UUID) {
        guard var reader = readers[connectionID] else { return }
        guard let id = sessionID.flatMap(UUID.init(uuidString:)),
              let session = store.session(id),
              reader.scope.allows(session) else {
            server?.send(Self.error("That session cannot be opened from this code."),
                         to: connectionID)
            return
        }
        guard reader.openSession != id else {
            sendSnapshot(to: connectionID, sessionID: id)
            return
        }

        // The transcript is only kept in memory while something is reading it, so the hold
        // moves with the phone rather than piling up one session at a time.
        if let previous = reader.openSession { store.release(previous, for: .remote) }
        store.hold(id, for: .remote)
        reader.openSession = id
        readers[connectionID] = reader
        pairings[reader.pairingID]?.openSession = id
        views[connectionID] = nil
        lists[connectionID] = nil
        sendSnapshot(to: connectionID, sessionID: id)
    }

    private func leaveSession(_ connectionID: UUID, because message: String? = nil) {
        guard var reader = readers[connectionID], reader.scope.canBrowse else { return }
        if let message { server?.send(Self.error(message), to: connectionID) }
        if let open = reader.openSession { store.release(open, for: .remote) }
        reader.openSession = nil
        readers[connectionID] = reader
        pairings[reader.pairingID]?.openSession = nil
        views[connectionID] = nil
        sendDirectory(to: connectionID, force: true)
    }

    // The session went away under the phone. A code that can browse falls back to its
    // list; a code for that one session has nothing left to show.
    private func sessionVanished(_ connectionID: UUID) {
        guard let reader = readers[connectionID] else { return }
        if reader.scope.canBrowse {
            leaveSession(connectionID, because: "This session is no longer available.")
        } else {
            server?.send(Self.error("This session is no longer available."), to: connectionID)
            revoke(reader.scope)
        }
    }

    private func create(_ command: RemoteCommand, for connectionID: UUID) {
        guard let reader = readers[connectionID], reader.scope.canCreate else {
            server?.send(Self.error("This code cannot start new sessions."), to: connectionID)
            return
        }
        guard let projectID = command.projectID.flatMap(UUID.init(uuidString:)),
              reader.scope.allows(project: projectID),
              let project = store.project(projectID) else {
            server?.send(Self.error("That project cannot be used from this code."),
                         to: connectionID)
            return
        }
        guard !store.isMissing(project) else {
            server?.send(Self.error("\(project.name) is missing from disk."), to: connectionID)
            return
        }
        let prompt = command.prompt?.trimmed ?? ""
        guard prompt.count <= 100_000 else {
            server?.send(Self.error("That prompt is too long."), to: connectionID)
            return
        }
        guard creating.insert(connectionID).inserted else { return }

        // The phone has no room for the choices the desktop sheet offers, so a session
        // made there starts on the app's own defaults.
        let agent = runner.agent
        let model = runner.defaults(for: agent).model
        let avatar = Preferences.defaultAgentAvatarName()
        let worktree = command.worktree == true && project.isGitRepository

        Task { @MainActor in
            defer { creating.remove(connectionID) }
            let created: ChatSession?
            var failure: String?
            if worktree {
                switch await SessionLifecycle.createWorktreeSession(
                    in: project, id: UUID(), base: nil, agent: agent, model: model,
                    agentAvatarName: avatar, store: store) {
                case .success(let session): created = session
                case .failure(let error): created = nil; failure = error.message
                }
            } else {
                switch store.insertSession(
                    in: project.id,
                    seed: .init(agent: agent, model: model, agentAvatarName: avatar)) {
                case .success(let session): created = session
                case .failure(let error): created = nil; failure = error.message
                }
            }
            guard let created else {
                server?.send(Self.error(failure ?? "The session could not be created."),
                             to: connectionID)
                return
            }
            guard readers[connectionID] != nil else { return }
            open(created.id.uuidString, for: connectionID)
            if !prompt.isEmpty { runner.send(prompt, sessionID: created.id, store: store) }
        }
    }

    // MARK: - Streaming

    private func startStream() {
        guard streamTask == nil else { return }
        streamTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshConnections()
                do {
                    try await Task.sleep(for: .milliseconds(150))
                } catch {
                    return
                }
            }
        }
    }

    private func stopStreamIfIdle() {
        guard readers.isEmpty else { return }
        streamTask?.cancel()
        streamTask = nil
    }

    private func scheduleExpiry(for pairingID: UUID) {
        guard let scope = pairings[pairingID]?.share.scope else { return }
        expiryTasks.removeValue(forKey: pairingID)?.cancel()
        expiryTasks[pairingID] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(600))
            } catch {
                return
            }
            guard let self, self.pairings[pairingID]?.share.isConnected == false else { return }
            self.revoke(scope)
        }
    }

    private func refreshConnections() {
        for (connectionID, reader) in readers {
            guard let sessionID = reader.openSession else {
                sendDirectory(to: connectionID, force: false)
                continue
            }
            guard store.session(sessionID) != nil else {
                sessionVanished(connectionID)
                continue
            }
            // The marker is the cheap gate: an idle session must not cost a walk of the
            // transcript on every tick just to learn that nothing moved.
            guard views[connectionID]?.marker != marker(for: sessionID) else { continue }
            sendUpdate(to: connectionID, sessionID: sessionID)
        }
    }

    private func marker(for sessionID: UUID) -> Marker {
        let session = store.session(sessionID)
        let tree = session.map(workingTree) ?? WorkingTree(branch: nil, added: 0, removed: 0)
        return Marker(transcript: store.transcriptRevision(sessionID),
                      session: session?.title ?? "",
                      project: session.flatMap { store.project($0.projectID)?.name } ?? "",
                      agent: session?.agent.title ?? "",
                      branch: tree.branch ?? "",
                      state: SessionTone(sessionID, store: store, runner: runner).word,
                      failure: Self.failure(runner.state(sessionID)) ?? "",
                      added: tree.added,
                      removed: tree.removed,
                      context: session.flatMap { $0.usage?.contextFraction(for: $0.agent) } ?? -1,
                      question: runner.question(sessionID)?.id,
                      queued: runner.queued(sessionID).map(\.id))
    }

    // Mirrors the desktop strip: git's own count of the tree once it has answered, and the
    // transcript's running total until then, so the phone shows a number from the first
    // frame rather than growing one a few seconds in.
    private func workingTree(_ session: ChatSession) -> WorkingTree {
        let snapshots = store.workingDirectories(for: session).compactMap { gitStats.snapshot(at: $0) }
        let branch = snapshots.first?.branch
            ?? session.worktreeBranch
            ?? session.sessionProjects?.compactMap(\.worktreeBranch).first
        guard !snapshots.isEmpty else {
            return WorkingTree(branch: branch,
                               added: session.summary.added,
                               removed: session.summary.removed)
        }
        return WorkingTree(branch: branch,
                           added: snapshots.reduce(0) { $0 + $1.totalAdded },
                           removed: snapshots.reduce(0) { $0 + $1.totalRemoved })
    }

    // MARK: - The list

    private func sendDirectory(to connectionID: UUID, force: Bool) {
        guard let reader = readers[connectionID], reader.scope.canBrowse else { return }
        let next = directory(for: reader.scope)
        guard force || lists[connectionID] != next else { return }
        guard let text = Self.encode(next) else { return }
        lists[connectionID] = next
        server?.send(text, to: connectionID)
    }

    // Everything the code reaches, grouped the way the rail groups it: a project, then the
    // sessions that have run in it, newest first. A session in a workspace is listed under
    // the project that leads it and says which workspace it belongs to.
    private func directory(for scope: MobileScope) -> RemoteDirectory {
        let sessions = store.sidebarSessions.filter(scope.allows)
        var rows: [UUID: [RemoteSessionRow]] = [:]
        for session in sessions.sorted(by: { $0.lastActivity > $1.lastActivity }) {
            rows[session.projectID, default: []].append(row(session))
        }

        let visible = store.projects.filter { scope.allows(project: $0.id) }
        let ordered = visible.sorted { first, second in
            let left = rows[first.id]?.first?.lastActivity ?? .distantPast
            let right = rows[second.id]?.first?.lastActivity ?? .distantPast
            guard left != right else {
                return first.name.localizedCaseInsensitiveCompare(second.name) == .orderedAscending
            }
            return left > right
        }

        return RemoteDirectory(
            title: title(for: scope),
            canCreate: scope.canCreate,
            projects: ordered.map { project in
                RemoteProject(id: project.id.uuidString,
                              name: project.name,
                              path: project.collapsedPath,
                              isGit: project.isGitRepository,
                              isMissing: store.isMissing(project),
                              sessions: rows[project.id] ?? [])
            })
    }

    private func row(_ session: ChatSession) -> RemoteSessionRow {
        RemoteSessionRow(
            id: session.id.uuidString,
            title: session.title,
            agent: session.agent.title,
            workspace: session.workspaceID.flatMap(store.workspace)?.name,
            branch: session.worktreeBranch
                ?? session.sessionProjects?.compactMap(\.worktreeBranch).first,
            state: SessionTone(session.id, store: store, runner: runner).word,
            lastActivity: session.lastActivity,
            added: session.summary.added,
            removed: session.summary.removed)
    }

    private func title(for scope: MobileScope) -> String {
        switch scope {
        case .everything: "All projects"
        case .project(let id): store.project(id)?.name ?? "Project"
        case .session(let id): store.session(id)?.title ?? "Session"
        }
    }

    // MARK: - The session

    private func remoteState(_ sessionID: UUID) -> RemoteState? {
        guard let session = store.session(sessionID),
              let project = store.project(session.projectID) else { return nil }
        let allMessages = store.transcript(of: sessionID)
        let projectPath = store.workingDirectories(for: session).first ?? project.path
        let visibleMessages = allMessages.suffix(200)
            .map { RemoteMessage($0, projectPath: projectPath) }
        let queued = runner.queued(sessionID)
        let state = runner.state(sessionID)
        let tone = SessionTone(sessionID, store: store, runner: runner)
        let tree = workingTree(session)
        return RemoteState(
            header: RemoteHeader(
                title: session.title,
                project: project.name,
                agent: session.agent.title,
                branch: tree.branch,
                state: tone.word,
                // The phone counts the elapsed time itself so a running session does not
                // need a fresh header every minute just to age its own label.
                since: tone == .running
                    ? (allMessages.last { $0.role == .user }?.date ?? session.lastActivity)
                    : session.lastActivity,
                failure: Self.failure(state),
                isBusy: state.isBusy,
                added: tree.added,
                removed: tree.removed,
                context: session.usage?.contextFraction(for: session.agent),
                queuedPrompts: queued.count,
                hasEarlierMessages: allMessages.count > visibleMessages.count),
            order: visibleMessages.map(\.id),
            messages: visibleMessages,
            digests: Dictionary(visibleMessages.map { ($0.id, RemoteTranscriptDiff.digest(of: $0)) },
                                uniquingKeysWith: { first, _ in first }),
            queued: queued.map(RemoteQueuedPrompt.init),
            permission: runner.question(sessionID).map {
                RemotePermission($0, runsIn: tree.branch ?? project.name)
            })
    }

    private func sendSnapshot(to connectionID: UUID, sessionID: UUID) {
        guard let reader = readers[connectionID], let state = remoteState(sessionID) else { return }
        let snapshot = RemoteSnapshot(sessionID: sessionID.uuidString,
                                      canBrowse: reader.scope.canBrowse,
                                      header: state.header,
                                      messages: state.messages,
                                      queued: state.queued,
                                      permission: state.permission)
        guard let text = Self.encode(snapshot) else { return }
        remember(state, for: connectionID, sessionID: sessionID)
        server?.send(text, to: connectionID)
    }

    private func sendUpdate(to connectionID: UUID, sessionID: UUID) {
        guard let view = views[connectionID] else {
            sendSnapshot(to: connectionID, sessionID: sessionID)
            return
        }
        guard let state = remoteState(sessionID) else { return }

        var changed: [RemoteChange] = []
        for message in state.messages {
            guard let current = state.digests[message.id] else { continue }
            guard let previous = view.messages[message.id] else {
                changed.append(.full(message))
                continue
            }
            guard previous != current else { continue }
            changed.append(RemoteTranscriptDiff.change(from: previous, to: current,
                                                       message: message))
        }

        let update = RemoteUpdate(
            header: view.header == state.header ? nil : state.header,
            order: view.order == state.order ? nil : state.order,
            changed: changed.isEmpty ? nil : changed,
            queued: view.queued == state.queued ? nil : state.queued,
            permission: view.permissionID == state.permission?.id ? nil : state.permission,
            permissionCleared: view.permissionID != nil && state.permission == nil ? true : nil)

        // A revision can bump for something the phone never sees, such as a saved token
        // count. Recording the marker without sending keeps that from being rechecked.
        guard !update.isEmpty else {
            views[connectionID]?.marker = marker(for: sessionID)
            return
        }
        guard let text = Self.encode(update) else { return }
        remember(state, for: connectionID, sessionID: sessionID)
        server?.send(text, to: connectionID)
    }

    private func remember(_ state: RemoteState, for connectionID: UUID, sessionID: UUID) {
        views[connectionID] = RemoteView(marker: marker(for: sessionID),
                                         header: state.header,
                                         order: state.order,
                                         messages: state.digests,
                                         queued: state.queued,
                                         permissionID: state.permission?.id)
    }

    private static func encode(_ value: some Encodable) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // The state word is the tone the desktop shows, which has no room for why a turn
    // stopped. A failure travels beside it so the strip can still say what went wrong.
    private static func failure(_ state: SessionState) -> String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    private static func makeSecret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw LANServerFailure(message: "A secure pairing code could not be created.")
        }
        return Data(bytes).base64URLEncoded
    }

    private static func securelyEqual(_ first: String, _ second: String) -> Bool {
        let left = [UInt8](first.utf8)
        let right = [UInt8](second.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func error(_ message: String) -> String {
        let data = try? JSONEncoder().encode(RemoteError(message: message))
        return data.flatMap { String(data: $0, encoding: .utf8) }
            ?? #"{"type":"error","message":"Mobile access failed."}"#
    }
}
