import Foundation

// Handing an approved Design to the session that builds it, the same for every front end:
// the GUI's Implement button and a client's implement command both come through here.
// Which session a front end then puts on screen is its own business, so nothing here
// changes the selection.
@MainActor
public enum DesignHandoff {
    public struct Failure: Error, Equatable, Sendable {
        public let title: String
        public let message: String

        public init(title: String, message: String) {
            self.title = title
            self.message = message
        }
    }

    // The commit each of the session's checkouts is on, by project id, kept on the
    // revision so a later look can tell what the Design was drawn against.
    public static func sourceRevisions(for session: ChatSession,
                                       store: ProjectStore) async -> [String: String] {
        var revisions: [String: String] = [:]
        for checkout in store.checkoutProjects(for: session) {
            guard let project = store.project(checkout.projectID) else { continue }
            let path = checkout.worktreePath ?? project.path
            if let revision = await GitRevision.head(at: path) {
                revisions[project.id.uuidString] = revision
            }
        }
        return revisions
    }

    // Approves the canvas as it is now. If an earlier handoff already saved these exact
    // files, that copy is approved again rather than saved a second time. `screenshot` is
    // the GUI's picture of the canvas; a front end that cannot draw one sends nil.
    public static func approveLive(_ designSessionID: UUID, screenshot: Data? = nil,
                                   store: ProjectStore) async -> Result<DesignRevision, Failure> {
        let title = "Could not prepare the Design"
        guard let session = store.session(designSessionID), session.ownsDesign else {
            return .failure(Failure(title: title, message: "The Design session is no longer available."))
        }
        let directory = store.designDirectory(for: session)
        if let saved = session.designRevisions
            .sorted(by: { $0.number > $1.number })
            .first(where: { DesignArtifacts.matchesLive($0, designDirectory: directory) }) {
            return store.approveDesignRevision(saved.id, for: designSessionID)
                .mapError { Failure(title: title, message: $0.message) }
        }
        let revisions = await sourceRevisions(for: session, store: store)
        let promptID = store.session(designSessionID)?.messages.last(where: { $0.role == .user })?.id
        return store.approveDesign(designSessionID, screenshot: screenshot,
                                   sourceRevisions: revisions, promptID: promptID)
            .mapError { Failure(title: title, message: $0.message) }
    }

    // Hands an approved revision over: to the Build that already has an earlier one, or
    // to a new implementation. Answers with the Build session's id.
    public static func handOver(_ designSessionID: UUID, revision: DesignRevision,
                                additionalContext: String? = nil,
                                store: ProjectStore, runner: SessionRunner) -> Result<UUID, Failure> {
        if let implementation = store.implementationSessions(for: designSessionID).last {
            switch sendLatestDesign(to: implementation.id, store: store, runner: runner) {
            case .success:
                store.append(ChatMessage(role: .system, text: "Sent the design to Build."), to: designSessionID)
                return .success(implementation.id)
            case .failure(let failure):
                return .failure(failure)
            }
        }
        return startImplementation(designSessionID, revision: revision,
                                   additionalContext: additionalContext, store: store, runner: runner)
    }

    public static func startImplementation(_ designSessionID: UUID, revision: DesignRevision,
                                           additionalContext: String? = nil,
                                           store: ProjectStore, runner: SessionRunner)
        -> Result<UUID, Failure> {
        let title = "Could not start implementation"
        let implementationID: UUID
        switch store.beginImplementation(designSessionID, revisionID: revision.id) {
        case .success(let sessionID):
            implementationID = sessionID
        case .failure(let failure):
            return .failure(Failure(title: title, message: failure.message))
        }
        guard let implementation = store.session(implementationID) else {
            return .failure(Failure(title: title,
                                    message: "The implementation session is no longer available."))
        }
        let context = additionalContext?.trimmed
        var notice = "Implementation started from \(revision.title). Return to the Design tab to refine it and send updates."
        if let context, !context.isEmpty {
            notice += "\n\nAdditional context:\n\(context)"
        }
        store.append(ChatMessage(role: .system, text: notice), to: implementationID)
        runner.sendAppCommand(
            implementationPrompt(revision, additionalContext: context),
            attachments: store.implementationReferenceAttachments(for: implementation),
            sessionID: implementationID,
            store: store)
        return .success(implementationID)
    }

    public static func sendLatestDesign(to implementationID: UUID,
                                        store: ProjectStore, runner: SessionRunner)
        -> Result<DesignRevision, Failure> {
        switch store.syncDesignReference(for: implementationID) {
        case .failure(let failure):
            return .failure(Failure(title: "Could not update the Design reference",
                                    message: failure.message))
        case .success(let revision):
            guard let implementation = store.session(implementationID) else {
                return .failure(Failure(title: "Could not update the Design reference",
                                        message: "The coding session is no longer available."))
            }
            store.append(ChatMessage(
                role: .system,
                text: "The implementation reference was updated to \(revision.title)."),
                to: implementationID)
            runner.sendAppCommand(
                """
                Review the updated \(revision.title) reference. Reconcile only its changed \
                visual and interaction requirements with the current implementation, preserve \
                behavior outside that gap, then run the relevant tests.
                """,
                attachments: store.implementationReferenceAttachments(for: implementation),
                sessionID: implementationID,
                store: store)
            return .success(revision)
        }
    }

    // Whether the Build is behind the canvas: a newer approved revision, or live files
    // that differ from the ones it was handed (its handoff note aside).
    public static func buildNeedsUpdate(_ design: ChatSession, implementation: ChatSession,
                                        store: ProjectStore) -> Bool {
        if store.designHasUpdated(for: implementation) { return true }
        guard let revisionID = implementation.handedOffDesignRevisionID,
              let revision = design.designRevisions.first(where: { $0.id == revisionID }) else {
            return true
        }
        return !DesignArtifacts.matchesLive(revision, designDirectory: store.designDirectory(for: design))
    }

    public static func implementationPrompt(_ revision: DesignRevision,
                                            additionalContext: String? = nil) -> String {
        let base = """
        Implement the scoped change represented by the approved \(revision.title) in the \
        production application. Inspect the current implementation, then read the attached \
        handoff and Design materials. Treat the Design as the gap to close, not a complete \
        specification of the application. Preserve behavior, structure, screens, and content \
        outside that gap. Anything omitted from the Design remains unchanged. Do not rebuild \
        or replace an existing application, page, or feature unless the user or handoff \
        explicitly asks for that scope.

        Treat the HTML as a visual and interaction reference, not production code. Reuse the \
        project's existing components, tokens, patterns, and architecture. Resolve \
        implementation details from the real code, cover the important states and \
        accessibility behavior, and run the relevant tests.
        """
        guard let context = additionalContext?.trimmed, !context.isEmpty else { return base }
        return """
        \(base)

        Additional implementation context from the user:

        \(context)
        """
    }
}

public enum GitRevision {
    public static func head(at path: String) async -> String? {
        guard let tool = await GitInspector.tool() else { return nil }
        return await GitInspector.offMain {
            let result = GitInspector.run(
                tool, ["rev-parse", "--verify", "HEAD"], in: URL(fileURLWithPath: path))
            guard result.ok, !result.text.isBlank else { return nil }
            return result.text.trimmed
        }
    }
}
