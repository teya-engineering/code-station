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
        let state: String
        let question: String?
        let queued: Int
    }

    private let store: ProjectStore
    private let runner: SessionRunner
    private var server: LANWebSocketServer?
    private var port: UInt16?
    private var pairings: [UUID: Pairing] = [:]
    private var pendingConnections: [UUID: UUID] = [:]
    private var connections: [UUID: UUID] = [:]
    private var markers: [UUID: Marker] = [:]
    private var expiryTasks: [UUID: Task<Void, Never>] = [:]
    private var streamTask: Task<Void, Never>?
    private(set) var enabled = false
    private(set) var shares: [UUID: MobileShare] = [:]

    init(store: ProjectStore, runner: SessionRunner) {
        self.store = store
        self.runner = runner
    }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        if !enabled { stop() }
    }

    func share(for sessionID: UUID) -> MobileShare? {
        shares[sessionID]
    }

    func prepareShare(for sessionID: UUID) async throws -> MobileShare {
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
            markers[connectionID] = nil
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
        markers.removeAll()
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
            markers[previous] = nil
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
    }

    private func closed(_ connectionID: UUID) {
        pendingConnections[connectionID] = nil
        markers[connectionID] = nil
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
            let marker = marker(for: sessionID)
            guard markers[connectionID] != marker else { continue }
            sendSnapshot(to: connectionID, sessionID: sessionID)
        }
    }

    private func marker(for sessionID: UUID) -> Marker {
        let session = store.session(sessionID)
        return Marker(transcript: store.transcriptRevision(sessionID),
                      session: session?.title ?? "",
                      project: session.flatMap { store.project($0.projectID)?.name } ?? "",
                      agent: session?.agent.title ?? "",
                      state: Self.stateLabel(runner.state(sessionID)),
                      question: runner.question(sessionID)?.id,
                      queued: runner.queued(sessionID).count)
    }

    private func sendSnapshot(to connectionID: UUID, sessionID: UUID) {
        guard let session = store.session(sessionID),
              let project = store.project(session.projectID) else { return }
        let allMessages = store.transcript(of: sessionID)
        let visibleMessages = allMessages.suffix(200).map(RemoteMessage.init)
        let state = runner.state(sessionID)
        let snapshot = RemoteSnapshot(
            sessionID: sessionID.uuidString,
            title: session.title,
            project: project.name,
            agent: session.agent.title,
            state: Self.stateLabel(state),
            isBusy: state.isBusy,
            queuedPrompts: runner.queued(sessionID).count,
            hasEarlierMessages: allMessages.count > visibleMessages.count,
            messages: visibleMessages,
            permission: runner.question(sessionID).map(RemotePermission.init))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let data = try? encoder.encode(snapshot),
              let text = String(data: data, encoding: .utf8) else { return }
        markers[connectionID] = marker(for: sessionID)
        server?.send(text, to: connectionID)
    }

    private static func stateLabel(_ state: SessionState) -> String {
        switch state {
        case .idle: "Idle"
        case .starting: "Starting"
        case .streaming: "Running"
        case .stopping: "Stopping"
        case .waiting: "Waiting for background work"
        case .failed(let message): message
        }
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

private struct RemoteSnapshot: Encodable {
    let type = "snapshot"
    let version = 1
    let sessionID: String
    let title: String
    let project: String
    let agent: String
    let state: String
    let isBusy: Bool
    let queuedPrompts: Int
    let hasEarlierMessages: Bool
    let messages: [RemoteMessage]
    let permission: RemotePermission?
}

private struct RemoteMessage: Encodable {
    let id: String
    let role: String
    let text: String
    let date: Date
    let attachments: [String]
    let thinking: [String]
    let tools: [RemoteTool]

    init(_ message: ChatMessage) {
        id = message.id.uuidString
        role = message.role.rawValue
        text = message.text
        date = message.date
        attachments = (message.attachments ?? []).map { URL(fileURLWithPath: $0).lastPathComponent }
        thinking = (message.thinking ?? []).map(\.text)
        tools = message.tools.map(RemoteTool.init)
    }
}

private struct RemoteTool: Encodable {
    let id: String
    let name: String
    let input: String
    let result: String?
    let isError: Bool
    let isRunning: Bool

    init(_ tool: ToolUse) {
        id = tool.id
        name = tool.name
        input = tool.input
        result = tool.result
        isError = tool.isError
        isRunning = tool.isRunning
    }
}

private struct RemotePermission: Encodable {
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
    let title: String
    let subject: String
    let detail: String
    let alwaysTitle: String?
    let questions: [Question]

    init(_ request: PermissionRequest) {
        id = request.id
        title = request.title
        subject = request.subject
        detail = request.detail
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
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
        } else {
            Text("Sharing has stopped.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
        }
    }
}
