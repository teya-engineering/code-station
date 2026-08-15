import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Darwin
import Foundation
import Observation
import Security
import SwiftUI

struct MobileShare: Identifiable, Equatable {
    let id: UUID
    let sessionID: UUID
    let url: URL
    let createdAt: Date
    var connectionID: UUID?

    var isConnected: Bool { connectionID != nil }
}

struct RemoteCommand: Decodable, Equatable {
    let type: String
    var version: Int?
    var secret: String?
    var prompt: String?
    var requestID: String?
    var answer: String?
    var answers: [String: String]?
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
    private var connections: [UUID: UUID] = [:]
    private var views: [UUID: RemoteView] = [:]
    private var expiryTasks: [UUID: Task<Void, Never>] = [:]
    private var streamTask: Task<Void, Never>?
    private(set) var enabled = false
    private(set) var shares: [UUID: MobileShare] = [:]

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

    func share(for sessionID: UUID) -> MobileShare? {
        shares[sessionID]
    }

    func startSharing(_ sessionID: UUID) async throws -> MobileShare {
        guard enabled else {
            throw LANServerFailure(message: "Turn on Mobile session access in Settings first.")
        }
        guard store.session(sessionID) != nil else {
            throw LANServerFailure(message: "This session is no longer available.")
        }
        if let existing = shares[sessionID] { return existing }

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

        let share = MobileShare(id: pairingID, sessionID: sessionID, url: url,
                                createdAt: Date(), connectionID: nil)
        pairings[pairingID] = Pairing(share: share, secret: secret)
        shares[sessionID] = share
        scheduleExpiry(for: pairingID)
        return share
    }

    func revoke(_ sessionID: UUID) {
        guard let share = shares.removeValue(forKey: sessionID) else { return }
        expiryTasks.removeValue(forKey: share.id)?.cancel()
        pairings[share.id] = nil
        pendingConnections = pendingConnections.filter { $0.value != share.id }
        if let connectionID = share.connectionID {
            connections[connectionID] = nil
            views[connectionID] = nil
            store.release(sessionID, for: .remote)
            server?.close(connectionID)
        }
        if shares.isEmpty { stopServer() }
        stopStreamIfIdle()
    }

    func stop() {
        let heldSessions = Set(connections.values)
        connections.removeAll()
        pendingConnections.removeAll()
        views.removeAll()
        pairings.removeAll()
        shares.removeAll()
        expiryTasks.values.forEach { $0.cancel() }
        expiryTasks.removeAll()
        heldSessions.forEach { store.release($0, for: .remote) }
        stopServer()
        streamTask?.cancel()
        streamTask = nil
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

        if connections[connectionID] == nil {
            authenticate(command, connectionID: connectionID)
            return
        }
        guard let sessionID = connections[connectionID], store.session(sessionID) != nil else {
            server?.send(Self.error("This session is no longer available."), to: connectionID)
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
        case "resync":
            sendSnapshot(to: connectionID, sessionID: sessionID)
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

        let sessionID = pairing.share.sessionID
        guard store.session(sessionID) != nil else {
            server?.send(Self.error("This session is no longer available."), to: connectionID)
            server?.close(connectionID)
            revoke(sessionID)
            return
        }

        if let previous = pairing.share.connectionID, previous != connectionID {
            connections[previous] = nil
            views[previous] = nil
            server?.close(previous)
        } else {
            store.hold(sessionID, for: .remote)
        }
        pendingConnections[connectionID] = nil
        connections[connectionID] = sessionID
        pairing.share.connectionID = connectionID
        pairings[pairingID] = pairing
        shares[sessionID] = pairing.share
        expiryTasks.removeValue(forKey: pairingID)?.cancel()
        sendSnapshot(to: connectionID, sessionID: sessionID)
        startStream()
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
        views[connectionID] = nil
        guard let sessionID = connections.removeValue(forKey: connectionID) else { return }
        if var share = shares[sessionID], share.connectionID == connectionID {
            share.connectionID = nil
            shares[sessionID] = share
            if var pairing = pairings[share.id] {
                pairing.share = share
                pairings[share.id] = pairing
            }
            scheduleExpiry(for: share.id)
        }
        store.release(sessionID, for: .remote)
        stopStreamIfIdle()
    }

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
        guard connections.isEmpty else { return }
        streamTask?.cancel()
        streamTask = nil
    }

    private func scheduleExpiry(for pairingID: UUID) {
        guard let sessionID = pairings[pairingID]?.share.sessionID else { return }
        expiryTasks.removeValue(forKey: pairingID)?.cancel()
        expiryTasks[pairingID] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(600))
            } catch {
                return
            }
            guard let self, self.pairings[pairingID]?.share.isConnected == false else { return }
            self.revoke(sessionID)
        }
    }

    private func refreshConnections() {
        for (connectionID, sessionID) in connections {
            guard store.session(sessionID) != nil else {
                revoke(sessionID)
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
        guard let state = remoteState(sessionID) else { return }
        let snapshot = RemoteSnapshot(sessionID: sessionID.uuidString,
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

struct MobilePairingView: View {
    @Environment(MobileAccessController.self) private var mobileAccess
    let sessionID: UUID

    @State private var starting = false
    @State private var failure: String?

    var body: some View {
        if let share = mobileAccess.share(for: sessionID) {
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
                        .fill(share.isConnected ? Theme.addition : Color.secondary)
                        .frame(width: 7, height: 7)
                    Text(share.isConnected ? "Phone connected" : "Waiting for the phone")
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
                    mobileAccess.revoke(sessionID)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
        } else {
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
            .padding(.vertical, 18)
        }
    }

    private func startSharing() {
        guard !starting else { return }
        starting = true
        failure = nil
        Task { @MainActor in
            defer { starting = false }
            do {
                _ = try await mobileAccess.startSharing(sessionID)
            } catch let error as LANServerFailure {
                failure = error.message
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
