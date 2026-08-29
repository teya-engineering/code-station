import Foundation

@MainActor
enum DesignHandoffLifecycle {
    struct Failure: Error, Equatable {
        let title: String
        let message: String
    }

    static func sourceRevisions(for session: ChatSession,
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

    static func startImplementation(_ designSessionID: UUID, revision: DesignRevision,
                                    additionalContext: String? = nil,
                                    store: ProjectStore, runner: SessionRunner)
        -> Result<Void, Failure> {
        let title = "Could not start implementation"
        if case .failure(let failure) = store.beginImplementation(designSessionID,
                                                                  revisionID: revision.id) {
            return .failure(Failure(title: title, message: failure.message))
        }
        // The session keeps its id through the handoff and becomes the implementation.
        guard let implementation = store.session(designSessionID) else {
            return .failure(Failure(title: title,
                                    message: "The implementation session is no longer available."))
        }
        let context = additionalContext?.trimmed
        var notice = "Implementation started from \(revision.title). Return to the Design tab to refine it and send updates."
        if let context, !context.isEmpty {
            notice += "\n\nAdditional context:\n\(context)"
        }
        store.append(ChatMessage(role: .system, text: notice), to: designSessionID)
        runner.sendAppCommand(
            implementationPrompt(revision, additionalContext: context),
            attachments: store.implementationReferenceAttachments(for: implementation),
            sessionID: designSessionID,
            store: store)
        store.selectSession(designSessionID)
        return .success(())
    }

    static func sendLatestDesign(to implementationID: UUID,
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

    static func implementationPrompt(_ revision: DesignRevision,
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

enum GitRevision {
    static func head(at path: String) async -> String? {
        guard let tool = await GitInspector.tool() else { return nil }
        return await GitInspector.offMain {
            let result = GitInspector.run(
                tool, ["rev-parse", "--verify", "HEAD"], in: URL(fileURLWithPath: path))
            guard result.ok, !result.text.isBlank else { return nil }
            return result.text.trimmed
        }
    }
}
