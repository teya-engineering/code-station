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

    static func continueHere(_ designSessionID: UUID, revision: DesignRevision,
                             store: ProjectStore, runner: SessionRunner)
        -> Result<Void, Failure> {
        guard let session = store.session(designSessionID) else {
            return .failure(Failure(title: "Could not start implementation",
                                    message: "The Design session is no longer available."))
        }
        switch store.beginImplementation(designSessionID, revisionID: revision.id) {
        case .failure(let failure):
            return .failure(Failure(title: "Could not start implementation",
                                    message: failure.message))
        case .success:
            break
        }

        _ = runner.clearContext(designSessionID, store: store)
        store.append(ChatMessage(
            role: .system,
            text: "Implementation started from \(revision.title). The approved Design remains available in the Design tab."),
            to: designSessionID)
        runner.sendAppCommand(
            implementationPrompt(revision),
            attachments: store.implementationReferenceAttachments(for: session),
            sessionID: designSessionID,
            store: store)
        store.selectSession(designSessionID)
        return .success(())
    }

    static func startFresh(from designSessionID: UUID, revision: DesignRevision,
                           store: ProjectStore, runner: SessionRunner,
                           worktrees: WorktreeOperations = .live) async
        -> Result<ChatSession, Failure> {
        guard let design = store.session(designSessionID), design.ownsDesign,
              let project = store.project(design.projectID) else {
            return .failure(Failure(title: "Could not create the coding session",
                                    message: "The Design session is no longer available."))
        }

        let created: Result<ChatSession, Failure>
        if let workspaceID = design.workspaceID,
           let workspace = store.workspace(workspaceID) {
            let sessionID = UUID()
            var choices: [WorkspaceProjectChoice] = []
            for checkout in store.checkoutProjects(for: design) {
                guard let member = store.project(checkout.projectID) else { continue }
                let path = checkout.worktreePath ?? member.path
                choices.append(WorkspaceProjectChoice(
                    projectID: member.id,
                    useWorktree: checkout.worktreePath != nil,
                    base: checkout.worktreePath == nil ? nil : await GitRevision.head(at: path)))
            }
            let choice = WorkspaceSessionChoice(
                sessionID: sessionID,
                projects: choices,
                agent: design.agent,
                model: design.settings?.model,
                agentAvatarName: design.agentAvatarName,
                mode: .chat)
            created = switch await SessionLifecycle.createWorkspaceSession(
                choice, in: workspace, store: store, worktrees: worktrees) {
            case .success(let session): .success(session)
            case .failure(let failure): .failure(Failure(
                title: failure.title, message: failure.message))
            }
        } else if design.worktreePath != nil, project.isGitRepository {
            let sessionID = UUID()
            let base: String?
            if let directory = store.workingDirectory(for: design) {
                base = await GitRevision.head(at: directory)
            } else {
                base = nil
            }
            created = switch await SessionLifecycle.createWorktreeSession(
                in: project,
                id: sessionID,
                base: base,
                agent: design.agent,
                model: design.settings?.model,
                agentAvatarName: design.agentAvatarName,
                mode: .chat,
                store: store,
                worktrees: worktrees) {
            case .success(let session): .success(session)
            case .failure(let failure): .failure(Failure(
                title: failure.title, message: failure.message))
            }
        } else {
            created = store.insertSession(
                in: project.id,
                agent: design.agent,
                model: design.settings?.model,
                agentAvatarName: design.agentAvatarName,
                mode: .chat)
                .mapError { Failure(title: "Could not create the coding session",
                                    message: $0.message) }
        }

        guard case .success(let implementation) = created else { return created }
        switch store.linkImplementation(implementation.id, to: design.id,
                                        revisionID: revision.id) {
        case .failure(let failure):
            let cleanup = await SessionLifecycle.remove(
                implementation, from: store, runner: runner, worktrees: worktrees)
            let cleanupMessage = switch cleanup {
            case .success: ""
            case .failure(let cleanupFailure):
                " The incomplete session also could not be removed: \(cleanupFailure.message)"
            }
            return .failure(Failure(
                title: "Could not create the coding session",
                message: failure.message + cleanupMessage))
        case .success:
            break
        }

        let title = design.title == "New session"
            ? "Implement Design" : "Implement \(design.title)"
        store.renameSession(implementation.id, to: title)
        if let linked = store.session(implementation.id) {
            store.append(ChatMessage(
                role: .system,
                text: "This coding session was created from \(revision.title) in \"\(design.title)\"."),
                to: linked.id)
            runner.sendAppCommand(
                implementationPrompt(revision),
                attachments: store.implementationReferenceAttachments(for: linked),
                sessionID: linked.id,
                store: store)
        }
        store.selectSession(implementation.id)
        return .success(store.session(implementation.id) ?? implementation)
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
                "Review the updated \(revision.title) reference. Reconcile the current implementation with its changed visual and interaction requirements, then run the relevant tests.",
                attachments: store.implementationReferenceAttachments(for: implementation),
                sessionID: implementationID,
                store: store)
            return .success(revision)
        }
    }

    private static func implementationPrompt(_ revision: DesignRevision) -> String {
        """
        Implement the approved \(revision.title) in the production application. Read the \
        attached handoff and Design materials first. Treat the HTML as a visual and \
        interaction reference, not production code. Reuse the project's existing components, \
        tokens, patterns, and architecture. Resolve implementation details from the real code, \
        cover the important states and accessibility behavior, and run the relevant tests.
        """
    }
}

enum GitRevision {
    static func head(at path: String) async -> String? {
        guard let tool = await GitInspector.tool() else { return nil }
        return await GitInspector.offMain {
            let result = GitInspector.run(
                tool, ["rev-parse", "--verify", "HEAD"], in: URL(fileURLWithPath: path))
            guard result.ok else { return nil }
            let revision = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return revision.isEmpty ? nil : revision
        }
    }
}
