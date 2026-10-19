import Foundation

// A session's Design conversation, as the GUI's Design tab drives it, for a client that
// cannot draw the canvas: whether there is a Design and where it stands, the screens it
// drew (as files on the host, to open in a browser), its versions, and the Build it was
// handed to. The conversation itself opens with `openSession(id, conversation: .design)`
// and is sent prompts like any session (by the conversation's own id); its ambition is a
// run setting of that conversation (`changeRunSetting(conversationID, "designAmbition")`).
//
// Commands:
// - read design: the state above.
// - start design: opens a Design conversation behind the session, as the Design tab does
//   when there is none.
// - approve design: saves the canvas as it is now as an approved version (or approves
//   again the saved version that matches it).
// - implement design: approves, then hands the version to the Build: a new
//   implementation, or the Build that already has an earlier version.

public struct RemoteDesignState: Codable, Equatable, Sendable {
    public enum Stage: String, Codable, Sendable {
        // No Design yet: starting one is on offer.
        case none
        // A Design conversation draws for the session.
        case designing
        // The session builds from a Design it was handed, with no conversation here.
        case reference
    }

    public var sessionID: String
    public var stage: Stage
    // The Design conversation's own id, to send prompts and change its ambition with.
    public var conversationID: String?
    // The session is itself the Design conversation, so its Chat already shows it.
    public var conversationIsSession: Bool
    public var isBusy: Bool
    // How far the next turn pushes the look, by its title.
    public var ambition: String?
    // What the canvas holds now (or the approved reference, for a Build), each a file on
    // the host. Empty until the agent has drawn something.
    public var screens: [RemoteDesignScreen]
    // Newest first.
    public var revisions: [RemoteDesignRevision]
    // The Build session the Design was handed to, if any.
    public var buildID: String?
    // The Build has the canvas as it is now.
    public var buildIsCurrent: Bool

    public init(sessionID: String, stage: Stage, conversationID: String? = nil,
                conversationIsSession: Bool = false, isBusy: Bool = false, ambition: String? = nil,
                screens: [RemoteDesignScreen] = [], revisions: [RemoteDesignRevision] = [],
                buildID: String? = nil, buildIsCurrent: Bool = false) {
        self.sessionID = sessionID
        self.stage = stage
        self.conversationID = conversationID
        self.conversationIsSession = conversationIsSession
        self.isBusy = isBusy
        self.ambition = ambition
        self.screens = screens
        self.revisions = revisions
        self.buildID = buildID
        self.buildIsCurrent = buildIsCurrent
    }

    // Approving and implementing need something on the canvas and no turn drawing it.
    public var canImplement: Bool { stage == .designing && !screens.isEmpty && !isBusy }
}

public struct RemoteDesignScreen: Codable, Equatable, Sendable {
    public var title: String
    // Relative to the design's folder, as the manifest names it.
    public var path: String
    // A file URL on the host, for a browser there.
    public var url: String

    public init(title: String, path: String, url: String) {
        self.title = title
        self.path = path
        self.url = url
    }
}

public struct RemoteDesignRevision: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var approved: Bool
    // Handed to the Build as its reference.
    public var handedOff: Bool

    public init(id: String, title: String, approved: Bool, handedOff: Bool) {
        self.id = id
        self.title = title
        self.approved = approved
        self.handedOff = handedOff
    }
}

extension StationCommands {
    public func readDesign(_ sessionID: String) throws(StationRefusal) -> RemoteDesignState {
        let session = try designSession(sessionID)
        return design(of: session)
    }

    public func startDesign(_ sessionID: String) throws(StationRefusal) -> RemoteDesignState {
        let session = try designSession(sessionID)
        if case .failure(let failure) = store.startDesign(for: session.id) {
            throw StationRefusal(failure.message)
        }
        return design(of: store.session(session.id) ?? session)
    }

    public func approveDesign(_ sessionID: String) async throws(StationRefusal) -> RemoteDesignState {
        let (session, conversation) = try implementable(sessionID)
        if case .failure(let failure) = await DesignHandoff.approveLive(conversation.id, store: store) {
            throw StationRefusal(failure.message)
        }
        return design(of: store.session(session.id) ?? session)
    }

    // Answers with the Build session's id.
    public func implementDesign(_ sessionID: String,
                                additionalContext: String?) async throws(StationRefusal) -> String {
        let (_, conversation) = try implementable(sessionID)
        try admitTurn()
        let revision: DesignRevision
        switch await DesignHandoff.approveLive(conversation.id, store: store) {
        case .success(let approved): revision = approved
        case .failure(let failure): throw StationRefusal(failure.message)
        }
        switch DesignHandoff.handOver(conversation.id, revision: revision,
                                      additionalContext: additionalContext, store: store, runner: runner) {
        case .success(let buildID): return buildID.uuidString
        case .failure(let failure): throw StationRefusal(failure.message)
        }
    }

    // The session a client names, which is the one its sidebar shows: a Design
    // conversation behind a session is reached through that session.
    private func designSession(_ sessionID: String) throws(StationRefusal) -> ChatSession {
        guard let id = UUID(uuidString: sessionID), var session = store.session(id) else { throw .noSession }
        if let source = session.designSourceSessionID, let owner = store.session(source) { session = owner }
        return session
    }

    private func implementable(_ sessionID: String) throws(StationRefusal) -> (ChatSession, ChatSession) {
        let session = try designSession(sessionID)
        guard let conversation = store.designConversation(for: session.id) else {
            throw StationRefusal("This session has no Design to approve.")
        }
        let state = design(of: session)
        guard !state.isBusy else { throw StationRefusal("Wait for the Design turn to finish.") }
        guard !state.screens.isEmpty else { throw StationRefusal("There is no design on the canvas yet.") }
        return (session, conversation)
    }

    private func design(of session: ChatSession) -> RemoteDesignState {
        let id = session.id.uuidString
        if let conversation = store.designConversation(for: session.id) {
            let directory = store.designDirectory(for: conversation)
            let build = store.implementationSessions(for: conversation.id).last
            let ambition = conversation.settings?.designAmbition
                ?? Preferences.designAmbition(in: preferences)
            return RemoteDesignState(
                sessionID: id, stage: .designing,
                conversationID: conversation.id.uuidString,
                conversationIsSession: conversation.id == session.id,
                isBusy: runner.state(conversation.id).isBusy,
                ambition: ambition.title,
                screens: Self.screens(in: directory),
                revisions: conversation.designRevisions.sorted { $0.number > $1.number }.map {
                    RemoteDesignRevision(id: $0.id.uuidString, title: $0.title,
                                         approved: $0.id == conversation.approvedDesignRevisionID,
                                         handedOff: $0.id == build?.handedOffDesignRevisionID)
                },
                buildID: build?.id.uuidString,
                buildIsCurrent: build.map { !DesignHandoff.buildNeedsUpdate(conversation, implementation: $0, store: store) }
                    ?? false)
        }
        if session.sourceDesignSessionID != nil {
            let screens = store.implementationDesignDirectory(for: session).map(Self.screens(in:)) ?? []
            return RemoteDesignState(sessionID: id, stage: .reference,
                                conversationID: session.sourceDesignSessionID.flatMap { store.session($0) }?.id.uuidString,
                                screens: screens, buildID: id, buildIsCurrent: !store.designHasUpdated(for: session))
        }
        return RemoteDesignState(sessionID: id, stage: .none)
    }

    // The screens a design folder holds, each only once its file is there.
    static func screens(in directory: URL) -> [RemoteDesignScreen] {
        guard DesignArtifactRevision.read(directory) != nil else { return [] }
        return DesignManifest.read(from: directory).screens.compactMap { screen in
            guard let url = DesignManifest.safeURL(for: screen, in: directory),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return RemoteDesignScreen(title: screen.title, path: screen.path, url: url.absoluteString)
        }
    }
}

// MARK: - The in-process client

extension StationConnection {
    public func readDesign(_ sessionID: String) throws(StationRefusal) -> RemoteDesignState {
        try host.readDesign(sessionID)
    }

    public func startDesign(_ sessionID: String) throws(StationRefusal) -> RemoteDesignState {
        try host.startDesign(sessionID)
    }

    public func approveDesign(_ sessionID: String) async throws(StationRefusal) -> RemoteDesignState {
        try await host.approveDesign(sessionID)
    }

    public func implementDesign(_ sessionID: String, additionalContext: String?) async throws(StationRefusal) -> String {
        try await host.implementDesign(sessionID, additionalContext: additionalContext)
    }
}

// MARK: - The socket client

extension StationSocketClient {
    public func readDesign(_ sessionID: String) async throws(StationRefusal) -> RemoteDesignState {
        try await call(.readDesign(sessionID: sessionID), as: RemoteDesignState.self)
    }

    public func startDesign(_ sessionID: String) async throws(StationRefusal) -> RemoteDesignState {
        try await call(.startDesign(sessionID: sessionID), as: RemoteDesignState.self)
    }

    public func approveDesign(_ sessionID: String) async throws(StationRefusal) -> RemoteDesignState {
        try await call(.approveDesign(sessionID: sessionID), as: RemoteDesignState.self)
    }

    public func implementDesign(_ sessionID: String, additionalContext: String?) async throws(StationRefusal) -> String {
        try await call(.implementDesign(sessionID: sessionID, additionalContext: additionalContext), as: String.self)
    }
}
