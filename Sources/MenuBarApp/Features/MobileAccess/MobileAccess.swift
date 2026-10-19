import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Darwin
import Foundation
import Observation
import Security
import CodeStationCore

// The one code that is out. It always reaches every project, so a phone either has the
// whole app or nothing.
struct MobileShare: Equatable {
    let id: UUID
    let url: URL
    var connectionID: UUID?

    var isConnected: Bool { connectionID != nil }
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

@MainActor
@Observable
final class MobileAccessController {
    private struct Pairing {
        var share: MobileShare
        let secret: String
        // Where the phone had got to when it last dropped, so a reconnect lands back on
        // the session it was reading rather than at the top of the list.
        var openSession: UUID?
        var conversation: RemoteCommand.Conversation = .main
    }

    // One connected phone and the session it is reading, if any. A phone on the list is
    // reading nothing.
    private struct Reader {
        var openSession: UUID?
        var conversation: RemoteCommand.Conversation = .main
        var conversationID: UUID?
        let designToken = UUID().uuidString
    }

    private let store: ProjectStore
    private let runner: SessionRunner
    private let gitStats: GitStatsCache
    private var server: LANWebSocketServer?
    private var port: UInt16?
    private var pairing: Pairing?
    // Sockets that opened on the current code and have not yet sent its secret.
    private var pendingConnections: Set<UUID> = []
    private var readers: [UUID: Reader] = [:]
    private var views: [UUID: RemoteSessionBaseline] = [:]
    private var designs: [UUID: RemoteDesign] = [:]
    private var lastDesignCheck = Date.distantPast
    private var lists: [UUID: RemoteDirectory] = [:]
    // Making a session can take a while when git has to lay down a worktree, and the phone
    // has no way to see that its tap landed, so a second one is refused rather than run.
    private var creating: Set<UUID> = []
    private var expiryTask: Task<Void, Never>?
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

    var share: MobileShare? { pairing?.share }

    // The session the phone is reading. Nil while it is on the list, and while no phone is
    // connected.
    var openSession: UUID? { readers.values.first?.openSession }

    func isConnected(session sessionID: UUID) -> Bool {
        readers.values.contains { $0.openSession == sessionID }
    }

    // Asking again while a code is out hands back that code.
    func startSharing() async throws -> MobileShare {
        guard enabled else {
            throw LANServerFailure(message: "Turn on Mobile access in Settings first.")
        }
        if let share { return share }

        let port = try await ensureServer()
        guard let address = LANAddress.currentIPv4() else {
            if pairing == nil { stopServer() }
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

        let share = MobileShare(id: pairingID, url: url, connectionID: nil)
        pairing = Pairing(share: share, secret: secret, openSession: nil)
        scheduleExpiry()
        return share
    }

    func revoke() {
        guard pairing != nil else { return }
        expiryTask?.cancel()
        expiryTask = nil
        pairing = nil
        pendingConnections.removeAll()
        for connectionID in Array(readers.keys) { drop(connectionID) }
        stopServer()
        stopStreamIfIdle()
    }

    func stop() {
        for connectionID in Array(readers.keys) { drop(connectionID) }
        pendingConnections.removeAll()
        pairing = nil
        expiryTask?.cancel()
        expiryTask = nil
        stopServer()
        streamTask?.cancel()
        streamTask = nil
    }

    // Forgets a phone and lets go of whatever it was holding. The socket closing comes
    // back as `closed`, which finds nothing left to do.
    private func drop(_ connectionID: UUID) {
        guard forget(connectionID) != nil else { return }
        server?.send(Self.error("Sharing ended. Scan a fresh QR code on your Mac.", code: "pairingEnded"), to: connectionID)
        server?.close(connectionID)
    }

    // Lets go of everything kept for one phone, and says which phone it was so the caller
    // can act on the code it came in on. Nil for a phone that was not being read.
    private func forget(_ connectionID: UUID) -> Reader? {
        guard let reader = readers.removeValue(forKey: connectionID) else { return nil }
        views[connectionID] = nil
        designs[connectionID] = nil
        lists[connectionID] = nil
        creating.remove(connectionID)
        if let open = reader.conversationID ?? reader.openSession { store.release(open, for: .remote) }
        return reader
    }

    private func ensureServer() async throws -> UInt16 {
        if let port { return port }
        let created = LANWebSocketServer(
            page: MobilePage.data,
            resource: { [weak self] path in
                await self?.resource(path)
            },
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
        guard let id = UUID(uuidString: pairingID), id == pairing?.share.id else {
            server?.send(Self.error("This QR code has expired or was revoked. Scan a fresh code on your Mac.", code: "pairingEnded"), to: connectionID)
            server?.close(connectionID)
            return
        }
        pendingConnections.insert(connectionID)
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
        case .openConversation:
            changeConversation(command.conversation ?? .main, for: connectionID)
        case .openSession:
            open(command.sessionID, for: connectionID, conversation: command.conversation ?? .main)
        case .closeSession:
            leaveSession(connectionID)
        case .createSession:
            create(command, for: connectionID)
        case .resync:
            if let open = reader.openSession {
                sendSnapshot(to: connectionID, sessionID: reader.conversationID ?? open)
            } else {
                sendDirectory(to: connectionID, force: true)
            }
        case .sendPrompt:
            guard let sessionID = openSession(of: connectionID, command: command) else { return }
            let prompt = command.prompt?.trimmed ?? ""
            let uploads = command.attachments ?? []
            guard !prompt.isEmpty || !uploads.isEmpty, prompt.count <= 100_000 else {
                server?.send(Self.error(prompt.count > 100_000 ? "That prompt is too long."
                                                               : "Write a prompt first."),
                             to: connectionID)
                return
            }
            var attachments: [Attachment] = []
            for upload in uploads {
                guard let data = Data(base64Encoded: upload.data),
                      let attachment = Attachments.fromUpload(name: upload.name, data: data) else {
                    server?.send(Self.error("\(upload.name) could not be saved on the Mac."),
                                 to: connectionID)
                    return
                }
                attachments.append(attachment)
            }
            runner.send(prompt, attachments: attachments, sessionID: sessionID, store: store)
        case .stopTurn:
            guard let sessionID = openSession(of: connectionID, command: command) else { return }
            runner.stop(sessionID)
        case .answerPermission:
            guard let sessionID = openSession(of: connectionID, command: command) else { return }
            answer(command, sessionID: sessionID, connectionID: connectionID)
        }
    }

    // The session a command that speaks to a session lands in. Nothing of the kind can
    // run from the list, so a phone on the list is told so, and one whose session has
    // gone is moved off it.
    private func openSession(of connectionID: UUID, command: RemoteCommand) -> UUID? {
        guard let reader = readers[connectionID], let sessionID = reader.conversationID ?? reader.openSession else {
            server?.send(Self.error("Open a session first."), to: connectionID)
            return nil
        }
        guard command.conversation ?? .main == reader.conversation,
              command.sessionID == nil || command.sessionID == reader.openSession?.uuidString else {
            server?.send(Self.error("The conversation changed. Try again."), to: connectionID)
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
              pendingConnections.contains(connectionID),
              var pairing,
              let secret = command.secret,
              Self.securelyEqual(secret, pairing.secret) else {
            server?.send(Self.error("This QR code is not valid. Scan a fresh code on your Mac.", code: "pairingEnded"), to: connectionID)
            server?.close(connectionID)
            return
        }

        // One code, one phone: a second scan takes the code over rather than doubling it.
        if let previous = pairing.share.connectionID, previous != connectionID {
            drop(previous)
        }
        pendingConnections.remove(connectionID)
        readers[connectionID] = Reader(openSession: nil)
        pairing.share.connectionID = connectionID
        self.pairing = pairing
        expiryTask?.cancel()
        expiryTask = nil

        // A phone that dropped while reading is put back where it was rather than at the
        // top of the list.
        if let resume = pairing.openSession, store.session(resume) != nil {
            let conversation = pairing.conversation == .design && store.designConversation(for: resume) != nil
                ? RemoteCommand.Conversation.design : .main
            open(resume.uuidString, for: connectionID, conversation: conversation)
        } else {
            sendDirectory(to: connectionID, force: true)
        }
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
        case .allowOnce?, .allowAlways?, .deny?, .answers?, .allowAddingDirectory?, nil:
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
        pendingConnections.remove(connectionID)
        guard let reader = forget(connectionID) else { return }
        if var pairing, pairing.share.connectionID == connectionID {
            pairing.share.connectionID = nil
            pairing.openSession = reader.openSession
            pairing.conversation = reader.conversation
            self.pairing = pairing
            scheduleExpiry()
        }
        stopStreamIfIdle()
    }

    // MARK: - Moving between sessions

    private func open(_ sessionID: String?, for connectionID: UUID,
                      conversation: RemoteCommand.Conversation = .main) {
        guard var reader = readers[connectionID] else { return }
        guard let id = sessionID.flatMap(UUID.init(uuidString:)),
              let session = store.session(id) else {
            server?.send(Self.error("That session is no longer available."),
                         to: connectionID)
            return
        }
        let target = conversation == .main ? session : store.designConversation(for: id)
        guard let target else {
            server?.send(Self.error("There is no Design conversation for this session."), to: connectionID)
            return
        }
        guard reader.openSession != id || reader.conversationID != target.id else {
            sendSnapshot(to: connectionID, sessionID: target.id)
            return
        }

        // The transcript is only kept in memory while something is reading it, so the hold
        // moves with the phone rather than piling up one session at a time.
        if let previous = reader.conversationID ?? reader.openSession { store.release(previous, for: .remote) }
        store.hold(target.id, for: .remote)
        reader.openSession = id
        reader.conversation = conversation
        reader.conversationID = target.id
        readers[connectionID] = reader
        pairing?.openSession = id
        pairing?.conversation = conversation
        views[connectionID] = nil
        lists[connectionID] = nil
        sendSnapshot(to: connectionID, sessionID: target.id)
    }

    private func leaveSession(_ connectionID: UUID, because message: String? = nil) {
        guard var reader = readers[connectionID] else { return }
        if let message { server?.send(Self.error(message), to: connectionID) }
        if let open = reader.conversationID ?? reader.openSession { store.release(open, for: .remote) }
        reader.openSession = nil
        reader.conversationID = nil
        reader.conversation = .main
        designs[connectionID] = nil
        readers[connectionID] = reader
        pairing?.openSession = nil
        views[connectionID] = nil
        sendDirectory(to: connectionID, force: true)
    }

    // The session went away under the phone, so it falls back to the list.
    private func sessionVanished(_ connectionID: UUID) {
        leaveSession(connectionID, because: "This session is no longer available.")
    }

    private func create(_ command: RemoteCommand, for connectionID: UUID) {
        guard readers[connectionID] != nil else { return }
        guard let projectID = command.projectID.flatMap(UUID.init(uuidString:)),
              let project = store.project(projectID) else {
            server?.send(Self.error("That project is no longer available."),
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
            switch await SessionLifecycle.createProjectSession(
                in: project, worktree: worktree, agent: agent, model: model,
                agentAvatarName: avatar, store: store) {
            case .success(let session): created = session
            case .failure(let error): created = nil; failure = error.message
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

    private func scheduleExpiry() {
        guard let pairingID = pairing?.share.id else { return }
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(600))
            } catch {
                return
            }
            guard let self, let share = self.share, share.id == pairingID, !share.isConnected else { return }
            self.revoke()
        }
    }

    private func refreshConnections() {
        let checkDesign = Date().timeIntervalSince(lastDesignCheck) >= 1
        if checkDesign { lastDesignCheck = Date() }
        for (connectionID, reader) in readers {
            if checkDesign { sendDesign(to: connectionID) }
            guard let sessionID = reader.conversationID ?? reader.openSession else {
                sendDirectory(to: connectionID, force: false)
                continue
            }
            guard let mainID = reader.openSession, store.session(mainID) != nil,
                  store.session(sessionID) != nil else {
                sessionVanished(connectionID)
                continue
            }
            // The marker is the cheap gate: an idle session must not cost a walk of the
            // transcript on every tick just to learn that nothing moved.
            guard views[connectionID]?.marker != marker(for: sessionID) else { continue }
            sendUpdate(to: connectionID, sessionID: sessionID)
        }
    }

    private func marker(for sessionID: UUID) -> RemoteSessionMarker {
        RemoteSessionMarker.make(sessionID, store: store, runner: runner, gitStats: gitStats)
    }

    // MARK: - The list

    private func sendDirectory(to connectionID: UUID, force: Bool) {
        guard readers[connectionID] != nil else { return }
        let next = directory()
        guard force || lists[connectionID] != next else { return }
        guard let text = Self.encode(next) else { return }
        lists[connectionID] = next
        server?.send(text, to: connectionID)
    }

    // Every project, grouped the way the rail groups it. The core builds the list, so the
    // phone and the terminal read sessions the same way.
    private func directory() -> RemoteDirectory {
        RemoteDirectoryListing.directory(
            store: store, runner: runner,
            title: "All projects", scope: "All projects", canCreate: true,
            tint: { (Self.projectTint($0), Self.projectTint($0, ink: true)) })
    }

    // MARK: - The session

    // The phone keeps the newest 200 messages, which is plenty to read on a small screen.
    private func remoteState(_ sessionID: UUID) -> RemoteSessionState? {
        RemoteSessionState.make(sessionID, store: store, runner: runner, gitStats: gitStats,
                                messageLimit: 200)
    }

    private func sendSnapshot(to connectionID: UUID, sessionID: UUID) {
        guard let reader = readers[connectionID], let state = remoteState(sessionID) else { return }
        let snapshot = RemoteSnapshot(sessionID: (reader.openSession ?? sessionID).uuidString,
                                      conversation: reader.conversation,
                                      header: state.header,
                                      messages: state.messages,
                                      queued: state.queued,
                                      permission: state.permission)
        guard let text = Self.encode(snapshot) else { return }
        remember(state, for: connectionID, sessionID: sessionID)
        server?.send(text, to: connectionID)
        sendDesign(to: connectionID)
    }

    private func sendUpdate(to connectionID: UUID, sessionID: UUID) {
        guard let view = views[connectionID] else {
            sendSnapshot(to: connectionID, sessionID: sessionID)
            return
        }
        guard let state = remoteState(sessionID) else { return }

        let update = view.update(to: state)

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

    private func remember(_ state: RemoteSessionState, for connectionID: UUID, sessionID: UUID) {
        views[connectionID] = RemoteSessionBaseline(state: state, marker: marker(for: sessionID))
    }

    private static func encode(_ value: some Encodable) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
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

    private static func projectTint(_ name: String, ink: Bool = false) -> String {
        let tint = Theme.projectTint(for: name)
        var color = NSColor.gray
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            color = NSColor(ink ? tint.ink : tint.colour).usingColorSpace(.sRGB) ?? .gray
        }
        return String(format: "#%02X%02X%02X", Int(color.redComponent * 255),
                      Int(color.greenComponent * 255), Int(color.blueComponent * 255))
    }

    private func changeConversation(_ conversation: RemoteCommand.Conversation, for connectionID: UUID) {
        guard let mainID = readers[connectionID]?.openSession else { return }
        open(mainID.uuidString, for: connectionID, conversation: conversation)
    }

    private func designDirectory(for reader: Reader) -> URL? {
        guard let id = reader.openSession, let session = store.session(id) else { return nil }
        if let reference = store.implementationDesignDirectory(for: session) { return reference }
        guard let owner = store.designOwner(for: session) else { return nil }
        return store.designDirectory(for: owner)
    }

    private func resource(_ path: String) -> LANResource? {
        if let asset = MobilePage.resource(path) { return asset }
        let parts = path.split(separator: "/", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "design",
              let reader = readers.values.first(where: { $0.designToken == parts[1] }),
              let directory = designDirectory(for: reader) else { return nil }
        return RemoteDesignArtifacts.resource(parts[2], in: directory)
    }

    private func sendDesign(to connectionID: UUID) {
        guard let reader = readers[connectionID], let id = reader.openSession else { return }
        let directory = designDirectory(for: reader)
        let revision = directory.flatMap(DesignArtifactRevision.read)
        let screens = directory.map { directory in
            DesignManifest.read(from: directory).screens.compactMap { screen -> RemoteDesign.Screen? in
                guard DesignManifest.safeURL(for: screen, in: directory) != nil else { return nil }
                var allowed = CharacterSet.urlPathAllowed
                allowed.remove(charactersIn: "?#%")
                guard let path = screen.path.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
                return .init(id: screen.id, title: screen.title,
                             url: "/design/\(reader.designToken)/\(path)")
            }
        } ?? []
        let stamp = revision?.files.map { "\($0.path):\($0.modified.timeIntervalSince1970):\($0.size)" }
            .joined(separator: "|") ?? ""
        let design = RemoteDesign(sessionID: id.uuidString, title: "Design preview",
                                  revision: String(StableHash.fnv1a(stamp), radix: 16),
                                  hasConversation: store.designConversation(for: id) != nil,
                                  screens: screens)
        guard designs[connectionID] != design else { return }
        designs[connectionID] = design
        if let text = Self.encode(design) { server?.send(text, to: connectionID) }
    }

    private static func error(_ message: String, code: String = "commandFailed") -> String {
        let data = try? JSONEncoder().encode(RemoteError(message: message, code: code))
        return data.flatMap { String(data: $0, encoding: .utf8) }
            ?? #"{"type":"error","message":"Mobile access failed."}"#
    }
}
