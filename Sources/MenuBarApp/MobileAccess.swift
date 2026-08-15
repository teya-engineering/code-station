import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Darwin
import Foundation
import Observation
import Security
import SwiftUI

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

struct RemoteCommand: Decodable, Equatable {
    let type: String
    var version: Int?
    var secret: String?
    var prompt: String?
    var requestID: String?
    var answer: String?
    var answers: [String: String]?
    var sessionID: String?
    var projectID: String?
    var worktree: Bool?
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
        let queued: Int
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
        var permissionID: String?
    }

    private struct RemoteState {
        let header: RemoteHeader
        let order: [String]
        let messages: [RemoteMessage]
        let digests: [String: RemoteMessageDigest]
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
    private(set) var shares: [MobileScope: MobileShare] = [:]

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

    func share(for scope: MobileScope) -> MobileShare? {
        shares[scope]
    }

    // Everything a phone can reach right now, newest first. A code that no phone has
    // scanned yet still counts, since it is access that has been given away.
    var activeShares: [MobileShareSummary] {
        shares.values
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
        return shares[scope]?.isConnected == true
    }

    func startSharing(_ scope: MobileScope) async throws -> MobileShare {
        guard enabled else {
            throw LANServerFailure(message: "Turn on Mobile access in Settings first.")
        }
        try verify(scope)
        if let existing = shares[scope] { return existing }

        let port = try await ensureServer()
        guard let address = LANAddress.currentIPv4() else {
            if shares.isEmpty { stopServer() }
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
        shares[scope] = share
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
        guard let share = shares.removeValue(forKey: scope) else { return }
        expiryTasks.removeValue(forKey: share.id)?.cancel()
        pairings[share.id] = nil
        pendingConnections = pendingConnections.filter { $0.value != share.id }
        for (connectionID, reader) in readers where reader.pairingID == share.id {
            drop(connectionID)
        }
        if shares.isEmpty { stopServer() }
        stopStreamIfIdle()
    }

    func stop() {
        for connectionID in Array(readers.keys) { drop(connectionID) }
        pendingConnections.removeAll()
        pairings.removeAll()
        shares.removeAll()
        expiryTasks.values.forEach { $0.cancel() }
        expiryTasks.removeAll()
        stopServer()
        streamTask?.cancel()
        streamTask = nil
    }

    // Forgets a phone and lets go of whatever it was holding. The socket closing comes
    // back as `closed`, which finds nothing left to do.
    private func drop(_ connectionID: UUID) {
        guard let reader = readers.removeValue(forKey: connectionID) else { return }
        views[connectionID] = nil
        lists[connectionID] = nil
        creating.remove(connectionID)
        if let open = reader.openSession { store.release(open, for: .remote) }
        server?.close(connectionID)
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
            server?.send(Self.error("The phone sent a message Conductor could not read."),
                         to: connectionID)
            return
        }

        guard let reader = readers[connectionID] else {
            authenticate(command, connectionID: connectionID)
            return
        }

        switch command.type {
        case "openSession":
            open(command.sessionID, for: connectionID)
        case "closeSession":
            leaveSession(connectionID)
        case "createSession":
            create(command, for: connectionID)
        case "resync":
            if let open = reader.openSession {
                sendSnapshot(to: connectionID, sessionID: open)
            } else {
                sendDirectory(to: connectionID, force: true)
            }
        default:
            act(command, for: connectionID)
        }
    }

    // Everything that speaks to the session the phone is reading. Nothing here can run
    // from the list, since there is no session for it to land in.
    private func act(_ command: RemoteCommand, for connectionID: UUID) {
        guard let sessionID = readers[connectionID]?.openSession else {
            server?.send(Self.error("Open a session first."), to: connectionID)
            return
        }
        guard store.session(sessionID) != nil else {
            sessionVanished(connectionID)
            return
        }

        switch command.type {
        case "sendPrompt":
            let prompt = command.prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !prompt.isEmpty, prompt.count <= 100_000 else {
                server?.send(Self.error(prompt.isEmpty ? "Write a prompt first."
                                                       : "That prompt is too long."),
                             to: connectionID)
                return
            }
            runner.send(prompt, sessionID: sessionID, store: store)
        case "stopTurn":
            runner.stop(sessionID, store: store)
        case "answerPermission":
            answer(command, sessionID: sessionID, connectionID: connectionID)
        default:
            server?.send(Self.error("That mobile command is not supported."), to: connectionID)
        }
    }

    private func authenticate(_ command: RemoteCommand, connectionID: UUID) {
        guard command.type == "authenticate",
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
        shares[scope] = pairing.share
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
        case "allowOnce" where !request.isQuestion:
            answer = .allowOnce
        case "allowAlways" where !request.isQuestion && request.alwaysTitle != nil:
            answer = .allowAlways
        case "deny" where !request.isQuestion:
            answer = .deny
        case "answers" where request.isQuestion:
            let given = command.answers ?? [:]
            answer = request.questions.allSatisfy {
                given[$0.text]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            } ? .answers(given) : nil
        default:
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
        let reason = command.prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if answer == .deny, !reason.isEmpty, reason.count <= 100_000 {
            runner.send(reason, sessionID: sessionID, store: store)
        }
    }

    private func closed(_ connectionID: UUID) {
        pendingConnections[connectionID] = nil
        guard let reader = readers.removeValue(forKey: connectionID) else { return }
        views[connectionID] = nil
        lists[connectionID] = nil
        creating.remove(connectionID)
        if let open = reader.openSession { store.release(open, for: .remote) }
        if var pairing = pairings[reader.pairingID], pairing.share.connectionID == connectionID {
            pairing.share.connectionID = nil
            pairing.openSession = reader.openSession
            pairings[reader.pairingID] = pairing
            shares[pairing.share.scope] = pairing.share
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
        let prompt = command.prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard prompt.count <= 100_000 else {
            server?.send(Self.error("That prompt is too long."), to: connectionID)
            return
        }
        guard creating.insert(connectionID).inserted else { return }

        // The phone has no room for the choices the desktop sheet offers, so a session
        // made there starts on the app's own defaults.
        let agent = runner.agent
        let model = runner.defaults(for: agent).model
        let avatar = Preferences.defaultAgentAvatarName(in: .standard)
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
                switch store.insertSession(in: project.id, agent: agent, model: model,
                                           agentAvatarName: avatar) {
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
                      queued: runner.queued(sessionID).count)
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
                queuedPrompts: runner.queued(sessionID).count,
                hasEarlierMessages: allMessages.count > visibleMessages.count),
            order: visibleMessages.map(\.id),
            messages: visibleMessages,
            digests: Dictionary(visibleMessages.map { ($0.id, RemoteTranscriptDiff.digest(of: $0)) },
                                uniquingKeysWith: { first, _ in first }),
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
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
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

// MARK: - What the phone is sent

// The list a browsing code opens on. It is compared with the last one sent before it goes
// out, so a phone sitting on the list costs nothing until something in it moves.
struct RemoteDirectory: Encodable, Equatable {
    let type = "directory"
    let version = 1
    let title: String
    let canCreate: Bool
    let projects: [RemoteProject]
}

struct RemoteProject: Encodable, Equatable {
    let id: String
    let name: String
    let path: String
    // Whether a session here can have a checkout of its own, which is the one choice the
    // phone offers when starting one.
    let isGit: Bool
    let isMissing: Bool
    let sessions: [RemoteSessionRow]
}

struct RemoteSessionRow: Encodable, Equatable {
    let id: String
    let title: String
    let agent: String
    let workspace: String?
    let branch: String?
    let state: String
    let lastActivity: Date
    let added: Int
    let removed: Int
}

struct RemoteHeader: Encodable, Equatable {
    let title: String
    let project: String
    let agent: String
    let branch: String?
    let state: String
    // What the elapsed time on the strip counts from: the start of the turn while one is
    // running, and the last thing that happened otherwise.
    let since: Date
    let failure: String?
    let isBusy: Bool
    let added: Int
    let removed: Int
    let context: Double?
    let queuedPrompts: Int
    let hasEarlierMessages: Bool
}

struct RemoteSnapshot: Encodable {
    let type = "snapshot"
    let version = 1
    let sessionID: String
    // Whether there is a list to go back to, which is what puts the back arrow on the
    // header of a session opened from a project or from the whole app.
    let canBrowse: Bool
    let header: RemoteHeader
    let messages: [RemoteMessage]
    let permission: RemotePermission?
}

// Only the parts that moved. An absent field means the phone should keep what it has, which
// is why a cleared permission needs a flag of its own rather than a missing one.
struct RemoteUpdate: Encodable {
    let type = "update"
    let version = 1
    var header: RemoteHeader?
    var order: [String]?
    var changed: [RemoteChange]?
    var permission: RemotePermission?
    var permissionCleared: Bool?

    var isEmpty: Bool {
        header == nil && order == nil && changed == nil
            && permission == nil && permissionCleared == nil
    }
}

// A "full" change replaces the message outright. A "patch" carries only the fields it names:
// text to add to the end, and the tools whose contents moved.
struct RemoteChange: Encodable, Equatable {
    let kind: String
    let id: String
    var role: String?
    var date: Date?
    var text: String?
    var textAppend: String?
    var attachments: [String]?
    var blocks: [RemoteBlock]?
    var tools: [RemoteTool]?

    static func full(_ message: RemoteMessage) -> RemoteChange {
        RemoteChange(kind: "full", id: message.id, role: message.role, date: message.date,
                     text: message.text, attachments: message.attachments,
                     blocks: message.blocks)
    }

    static func patch(id: String, textAppend: String?, tools: [RemoteTool]?) -> RemoteChange {
        RemoteChange(kind: "patch", id: id, textAppend: textAppend, tools: tools)
    }
}

struct RemoteMessageDigest: Equatable {
    let role: String
    let date: Date
    let textCount: Int
    let textHash: Int
    let structure: Int
    let attachments: Int
    let toolOrder: [String]
    let tools: [String: Int]
}

enum RemoteTranscriptDiff {
    static func digest(of message: RemoteMessage) -> RemoteMessageDigest {
        RemoteMessageDigest(
            role: message.role,
            date: message.date,
            textCount: message.text.count,
            textHash: message.text.hashValue,
            structure: message.structureDigest,
            attachments: message.attachments.hashValue,
            toolOrder: message.tools.map(\.id),
            tools: Dictionary(message.tools.map { ($0.id, $0.digest) },
                              uniquingKeysWith: { first, _ in first }))
    }

    // A live answer grows one chunk at a time, so the usual change is a longer text with
    // everything else untouched. Anything that rewrites what the phone already drew falls
    // back to the whole message, since patching it would need the old text to undo.
    static func change(from previous: RemoteMessageDigest, to current: RemoteMessageDigest,
                       message: RemoteMessage) -> RemoteChange {
        guard previous.role == current.role,
              previous.date == current.date,
              previous.structure == current.structure,
              previous.attachments == current.attachments,
              previous.toolOrder == current.toolOrder,
              current.textCount >= previous.textCount else { return .full(message) }

        var appended: String?
        if previous.textHash != current.textHash {
            let kept = String(message.text.prefix(previous.textCount))
            guard kept.hashValue == previous.textHash else { return .full(message) }
            appended = String(message.text.dropFirst(previous.textCount))
        }

        let tools = message.tools.filter { previous.tools[$0.id] != current.tools[$0.id] }
        return .patch(id: message.id, textAppend: appended, tools: tools.isEmpty ? nil : tools)
    }
}

struct RemoteMessage: Encodable {
    let id: String
    let role: String
    let text: String
    let date: Date
    let attachments: [String]
    let blocks: [RemoteBlock]

    var tools: [RemoteTool] { blocks.flatMap { $0.tools ?? [] } }

    // Prose is already covered by the text digest. This only records the layout around
    // it, so an answer can still stream as small append patches while its last prose block
    // grows.
    var structureDigest: Int {
        var hasher = Hasher()
        for block in blocks {
            hasher.combine(block.kind)
            if block.kind == "thinking" { hasher.combine(block.text) }
            if block.kind == "tools" { block.tools?.forEach { hasher.combine($0.id) } }
        }
        return hasher.finalize()
    }

    init(_ message: ChatMessage, projectPath: String = "") {
        id = message.id.uuidString
        role = message.role.rawValue
        text = message.text
        date = message.date
        attachments = (message.attachments ?? []).map { URL(fileURLWithPath: $0).lastPathComponent }
        blocks = message.blocks.map { RemoteBlock($0, projectPath: projectPath) }
    }
}

// The Mac has already rebuilt the separate text, thought and tool streams in their true
// order. Sending that result keeps the phone on the same ordering rules, including Unicode
// text offsets and calls made by child agents.
struct RemoteBlock: Encodable, Equatable {
    let kind: String
    let text: String?
    let tools: [RemoteTool]?

    init(_ block: MessageBlock, projectPath: String) {
        switch block {
        case .prose(_, let text):
            kind = "prose"
            self.text = text
            tools = nil
        case .thinking(_, let text):
            kind = "thinking"
            self.text = text
            tools = nil
        case .tools(_, let nodes):
            kind = "tools"
            text = nil
            tools = nodes
                .flatMap(Self.flatten)
                .sorted { $0.order < $1.order }
                .map { RemoteTool($0.tool, projectPath: projectPath) }
        }
    }

    private static func flatten(_ node: ToolNode) -> [ToolNode] {
        [node] + node.children.flatMap(flatten)
    }
}

struct RemoteTool: Encodable, Equatable {
    let id: String
    let name: String
    // The one argument the row is about, read the way the desktop spine reads it, so a
    // call names itself the same on both screens.
    let argument: String
    let added: Int?
    let input: String
    let result: String?
    let isError: Bool
    let isRunning: Bool

    var digest: Int {
        var hasher = Hasher()
        hasher.combine(name)
        hasher.combine(input)
        hasher.combine(result)
        hasher.combine(isError)
        hasher.combine(isRunning)
        return hasher.finalize()
    }

    init(_ tool: ToolUse, projectPath: String = "") {
        let presentation = ToolPresentation(tool: tool, projectPath: projectPath)
        id = tool.id
        name = tool.name
        argument = presentation.argument
        added = presentation.added
        input = tool.input
        result = tool.result
        isError = tool.isError
        isRunning = tool.isRunning
    }
}

struct RemotePermission: Encodable {
    struct Question: Encodable {
        struct Option: Encodable {
            let label: String
            let description: String
        }

        let header: String
        let text: String
        let multiSelect: Bool
        let options: [Option]
    }

    let id: String
    // Which of the two asks this is, since the sheet names itself after it.
    let kind: String
    let toolName: String
    let title: String
    let lead: String
    let subject: String
    let detail: String
    // The branch the call would run on, or the project when the session has no worktree.
    let runsIn: String
    let alwaysTitle: String?
    let questions: [Question]

    init(_ request: PermissionRequest, runsIn: String) {
        id = request.id
        kind = request.isQuestion ? "question" : "permission"
        toolName = request.toolName
        title = request.title
        lead = request.toolName == "Bash"
            ? "The agent wants to run:"
            : "The agent wants to use \(request.title):"
        subject = request.subject
        detail = request.detail
        self.runsIn = runsIn
        alwaysTitle = request.alwaysTitle
        questions = request.questions.map {
            Question(header: $0.header, text: $0.text, multiSelect: $0.multiSelect,
                     options: $0.options.map {
                         Question.Option(label: $0.label, description: $0.description)
                     })
        }
    }
}

private struct RemoteError: Encodable {
    let type = "error"
    let message: String
}

// MARK: - The desktop side

// The QR button as a header wears it. The same control sits on a session, on a project and
// on Home; what changes is how far the code it makes can reach.
struct MobileAccessButton: View {
    let scope: MobileScope

    @Environment(MobileAccessController.self) private var mobileAccess
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(ProjectStore.self) private var store

    var body: some View {
        let share = mobileAccess.share(for: scope)
        let connected = mobileAccess.isLive(scope)
        let tint = if connected {
            Theme.addition
        } else if share != nil {
            Theme.accent
        } else {
            Color.secondary
        }
        return Button { open() } label: {
            Image(systemName: "qrcode")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .appTooltip(tooltip(shared: share != nil, connected: connected))
        .accessibilityLabel(tooltip(shared: share != nil, connected: connected))
    }

    private func tooltip(shared: Bool, connected: Bool) -> String {
        if connected { return "Phone connected" }
        if shared { return "Shared with a phone" }
        return switch scope {
        case .session: "Open this session on a phone"
        case .project: "Open this project on a phone"
        case .everything: "Open Conductor on a phone"
        }
    }

    private func open() {
        dialogs.show(Dialog(
            title: title,
            message: """
            \(reach)

            No phone can connect until you start sharing below. Sharing continues after this dialog closes. Reopen it to cancel or stop sharing.
            """,
            content: AnyView(MobilePairingView(scope: scope)),
            actions: [.init(label: "Done", kind: .primary)],
            width: 390))
    }

    private var title: String {
        switch scope {
        case .session: "Open this session on your phone"
        case .project(let id): "Open \(store.project(id)?.name ?? "this project") on your phone"
        case .everything: "Open Conductor on your phone"
        }
    }

    // What the code lets the phone do, said plainly, because it is the whole difference
    // between the three codes.
    private var reach: String {
        switch scope {
        case .session:
            "A phone on the same trusted Wi-Fi can read this one session, send prompts, stop turns and answer requests. It can reach nothing else."
        case .project(let id):
            "A phone on the same trusted Wi-Fi can read any session in \(store.project(id)?.name ?? "this project"), start new ones there, send prompts, stop turns and answer requests."
        case .everything:
            "A phone on the same trusted Wi-Fi can read any session in any project, start new ones anywhere, send prompts, stop turns and answer requests."
        }
    }
}

// Every code that is out, wherever it was made. The three buttons that hand out access sit
// on the session, the project and Home, so without this there is no one place that says
// what a phone can reach or takes it back.
struct MobileAccessBadge: View {
    @Environment(MobileAccessController.self) private var mobileAccess

    var body: some View {
        let shares = mobileAccess.activeShares
        if !shares.isEmpty {
            let connected = shares.filter(\.isConnected).count
            let tint = connected > 0 ? Theme.addition : Theme.accent
            HStack(spacing: 5) {
                Image(systemName: connected > 0
                        ? "iphone.radiowaves.left.and.right" : "iphone")
                    .font(.system(size: 10, weight: .semibold))
                Text("\(shares.count)")
                    .font(.mono(9.5, .semibold))
                    .kerning(0.7)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.1)))
            .appMenu { menu(shares) }
            .appTooltip(connected > 0
                        ? "\(connected) of \(shares.count) shared with a connected phone"
                        : "Shared with a phone")
            .accessibilityLabel("Mobile access")
        }
    }

    private func menu(_ shares: [MobileShareSummary]) -> [MenuEntry] {
        var entries: [MenuEntry] = shares.map { share in
            .item(share.name,
                  icon: share.isConnected
                      ? "iphone.radiowaves.left.and.right" : "iphone",
                  subtitle: "\(share.state) · \(share.reach)",
                  detail: "Revoke",
                  detailColour: Theme.deletion) {
                mobileAccess.revoke(share.scope)
            }
        }
        if shares.count > 1 {
            entries.append(.separator)
            entries.append(.item("Revoke all", kind: .destructive, icon: "xmark.circle") {
                mobileAccess.stop()
            })
        }
        return entries
    }
}

struct MobilePairingView: View {
    @Environment(MobileAccessController.self) private var mobileAccess
    let scope: MobileScope

    @State private var starting = false
    @State private var confirming = false
    @State private var failure: String?

    var body: some View {
        if let share = mobileAccess.share(for: scope) {
            VStack(spacing: 14) {
                if let image = MobilePairingQRCode.image(for: share.url) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 214, height: 214)
                        .padding(18)
                        .background(RoundedRectangle(cornerRadius: 12).fill(.white))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
                }

                HStack(spacing: 7) {
                    Circle()
                        .fill(mobileAccess.isLive(scope) ? Theme.addition : Color.secondary)
                        .frame(width: 7, height: 7)
                    Text(mobileAccess.isLive(scope) ? "Phone connected" : "Waiting for the phone")
                        .font(.system(size: 12, weight: .semibold))
                }

                Text(share.url.absoluteString)
                    .font(.mono(9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)

                ActionButton(title: share.isConnected ? "Stop sharing" : "Cancel sharing",
                             tone: .danger, height: 38, size: 13, fills: true) {
                    mobileAccess.revoke(scope)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
        } else if confirming {
            confirmation
        } else {
            idle
        }
    }

    private var idle: some View {
        VStack(spacing: 14) {
            Image(systemName: "iphone.slash")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text("Sharing is off")
                    .font(.system(size: 13, weight: .semibold))
                Text("Start sharing to create a temporary QR code and allow one phone to connect.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let failure {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.deletion)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ActionButton(title: starting ? "Starting…" : "Start sharing",
                         tone: .green, height: 38, size: 13, fills: true,
                         action: startSharing)
                .disabled(starting)
                .opacity(starting ? 0.5 : 1)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    // A code that can browse hands over more than the screen the button was pressed on, so
    // that reach is spelled out once more and has to be agreed to before the code exists.
    private var confirmation: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(Theme.accent)

            VStack(spacing: 4) {
                Text("This code opens more than one session")
                    .font(.system(size: 13, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(warning)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                ActionButton(title: "Back", tone: .outlined, height: 38, size: 13, fills: true) {
                    confirming = false
                }
                ActionButton(title: "Confirm", tone: .green, height: 38, size: 13, fills: true,
                             action: begin)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    private var warning: String {
        switch scope {
        case .project:
            "Whoever scans it can browse every session in this project, read what they say and start new ones that run on this Mac. Only scan it on a phone you trust."
        default:
            "Whoever scans it can browse every project, read any session and start new ones anywhere, all running on this Mac. Only scan it on a phone you trust."
        }
    }

    private func startSharing() {
        guard !starting else { return }
        guard !scope.canBrowse else {
            failure = nil
            confirming = true
            return
        }
        begin()
    }

    private func begin() {
        guard !starting else { return }
        starting = true
        confirming = false
        failure = nil
        Task { @MainActor in
            defer { starting = false }
            do {
                _ = try await mobileAccess.startSharing(scope)
            } catch let error as LANServerFailure {
                failure = error.message
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
