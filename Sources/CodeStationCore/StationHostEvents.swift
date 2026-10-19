import Foundation

// What a station host's runner tells the person, as it travels to clients: a turn that
// ended, a question waiting, a wait gone stale, taking those back, and the session sound
// that comes just before a turn ends. A client hands each one to its own services
// (`deliver(to:)`), so a terminal rings or posts OSC 9 whichever process runs the
// session, while the host still tells its own person as before.
public enum StationHostEvent: Codable, Equatable, Sendable {
    case turnEnded(sessionID: String, sessionTitle: String, failure: String?)
    case needsInput(sessionID: String, sessionTitle: String, request: RemotePermission)
    case waitWentStale(sessionID: String, sessionTitle: String, tasks: [AgentBackgroundTask])
    case cleared(sessionID: String)
    case sessionSound
    // The host is handing the station over to `successor` (ADR-0003). New turns are
    // refused until the next host serves it; the client reconnects on its own.
    case handoverStarting(successor: String)

    // Calls `host` the way the host's runner called its own services.
    @MainActor
    public func deliver(to host: any HostServices) {
        switch self {
        case .turnEnded(let sessionID, let title, let failure):
            guard let id = UUID(uuidString: sessionID) else { return }
            host.turnEnded(sessionID: id, sessionTitle: title, failure: failure)
        case .needsInput(let sessionID, let title, let request):
            guard let id = UUID(uuidString: sessionID) else { return }
            host.needsInput(sessionID: id, sessionTitle: title, request: PermissionRequest(request))
        case .waitWentStale(let sessionID, let title, let tasks):
            guard let id = UUID(uuidString: sessionID) else { return }
            host.waitWentStale(sessionID: id, sessionTitle: title, tasks: tasks)
        case .cleared(let sessionID):
            guard let id = UUID(uuidString: sessionID) else { return }
            host.clear(sessionID: id)
        case .sessionSound:
            host.playSessionSound()
        case .handoverStarting:
            // Nothing to ring or post: a front end shows it as it likes.
            break
        }
    }
}

extension PermissionRequest {
    // A request as a client hears of it, enough to say what it is about. It carries no
    // tool input, so it can be shown but never answered from here: answers go through
    // the station interface.
    init(_ remote: RemotePermission) {
        self.init(id: remote.id, toolName: remote.toolName, title: remote.title,
                  subject: remote.subject, detail: remote.detail, input: Data(), suggestions: nil,
                  alwaysTitle: remote.alwaysTitle,
                  questions: remote.questions.enumerated().map { index, question in
                      AgentQuestion(id: index, header: question.header, text: question.text,
                                    multiSelect: question.multiSelect,
                                    options: question.options.enumerated().map {
                                        AgentQuestion.Option(id: $0.offset, label: $0.element.label,
                                                             description: $0.element.description)
                                    })
                  })
    }
}

// Stands between a session runner and the services it reports to: every call goes on to
// those services unchanged, and what the person would be told is also sent to everyone
// listening, which is how a host's clients hear it. `StationCommands` puts one in front
// of its runner's services.
@MainActor
final class HostEventRelay: HostServices {
    let services: any HostServices
    private var listeners: [UUID: AsyncStream<StationHostEvent>.Continuation] = [:]

    init(forwardingTo services: any HostServices) {
        self.services = services
    }

    var listenerCount: Int { listeners.count }

    // Every event from now on. The stream ends when the reader stops iterating.
    func events() -> AsyncStream<StationHostEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: StationHostEvent.self)
        let key = UUID()
        listeners[key] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.listeners[key] = nil }
        }
        return stream
    }

    // Something the host itself tells its clients, which the host's own services have
    // no call for.
    func announce(_ event: StationHostEvent) {
        send(event)
    }

    private func send(_ event: StationHostEvent) {
        for listener in listeners.values { listener.yield(event) }
    }

    func turnEnded(sessionID: UUID, sessionTitle: String, failure: String?) {
        services.turnEnded(sessionID: sessionID, sessionTitle: sessionTitle, failure: failure)
        send(.turnEnded(sessionID: sessionID.uuidString, sessionTitle: sessionTitle, failure: failure))
    }

    func needsInput(sessionID: UUID, sessionTitle: String, request: PermissionRequest) {
        services.needsInput(sessionID: sessionID, sessionTitle: sessionTitle, request: request)
        send(.needsInput(sessionID: sessionID.uuidString, sessionTitle: sessionTitle,
                         request: RemotePermission(request, runsIn: "")))
    }

    func waitWentStale(sessionID: UUID, sessionTitle: String, tasks: [AgentBackgroundTask]) {
        services.waitWentStale(sessionID: sessionID, sessionTitle: sessionTitle, tasks: tasks)
        send(.waitWentStale(sessionID: sessionID.uuidString, sessionTitle: sessionTitle, tasks: tasks))
    }

    func clear(sessionID: UUID) {
        services.clear(sessionID: sessionID)
        send(.cleared(sessionID: sessionID.uuidString))
    }

    func playSessionSound() {
        services.playSessionSound()
        send(.sessionSound)
    }

    // The rest belongs to the host's own person and is not told to clients.
    func copy(_ content: ClipboardContent) { services.copy(content) }
    func openInApps() -> [OpenInApp] { services.openInApps() }
    func open(_ path: URL, in app: OpenInApp) { services.open(path, in: app) }
    func openLink(_ url: URL) { services.openLink(url) }
    func chooseDirectory(prompt: String, message: String,
                         startingAt directory: URL?) async throws -> URL? {
        try await services.chooseDirectory(prompt: prompt, message: message, startingAt: directory)
    }
}
