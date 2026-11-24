import Foundation

// Where a session's Design lives and how its conversations are tied together. These only
// read; whatever changes a Design is in the store itself, beside the saving it relies on.
extension ProjectStore {
    // MARK: - Conversations

    func designSession(for sourceSessionID: UUID) -> ChatSession? {
        sessions.first { $0.designSourceSessionID == sourceSessionID }
    }

    func designConversation(for sessionID: UUID) -> ChatSession? {
        guard let session = session(sessionID) else { return nil }
        if session.isActivelyDesigning { return session }
        return designSession(for: sessionID)
    }

    func isDesignMode(_ session: ChatSession) -> Bool {
        session.sourceDesignSessionID != nil || designOwner(for: session) != nil
    }

    func designOwner(for session: ChatSession) -> ChatSession? {
        if session.ownsDesign { return session }
        if let source = session.sourceDesignSessionID { return self.session(source) }
        return designSession(for: session.id)
    }

    func implementationSessions(for designSessionID: UUID) -> [ChatSession] {
        userSessions.filter { $0.sourceDesignSessionID == designSessionID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func sessionsShareDesignWorkflow(_ firstSessionID: UUID, _ secondSessionID: UUID) -> Bool {
        guard let first = session(firstSessionID), let second = session(secondSessionID) else {
            return false
        }
        return first.sourceDesignSessionID == second.id
            || second.sourceDesignSessionID == first.id
            || first.designSourceSessionID == second.id
            || second.designSourceSessionID == first.id
    }

    func approvedDesignRevision(for session: ChatSession) -> DesignRevision? {
        guard let owner = designOwner(for: session),
              let approved = owner.approvedDesignRevisionID else { return nil }
        return owner.designRevisions.first { $0.id == approved }
    }

    func designHasUpdated(for implementation: ChatSession) -> Bool {
        guard let sourceID = implementation.sourceDesignSessionID,
              let source = session(sourceID),
              let approved = source.approvedDesignRevisionID else { return false }
        return approved != implementation.handedOffDesignRevisionID
    }

    // Design conversations live behind the session that opened them. Anything that
    // navigates or asks for attention must point at that visible session, since the
    // companion itself does not have a row in the app.
    func userFacingSessionID(for sessionID: UUID) -> UUID {
        session(sessionID)?.designSourceSessionID ?? sessionID
    }

    // MARK: - Files

    func designDirectory(for session: ChatSession) -> URL {
        designsURL.appendingPathComponent(session.id.uuidString, isDirectory: true)
    }

    func designArtifactURL(for session: ChatSession) -> URL? {
        guard session.ownsDesign || session.isDesignSession else { return nil }
        return designDirectory(for: session).appendingPathComponent("index.html")
    }

    func designReferenceDirectory(for session: ChatSession) -> URL? {
        guard session.sourceDesignSessionID != nil else { return nil }
        return designDirectory(for: session).appendingPathComponent("reference", isDirectory: true)
    }

    func implementationDesignDirectory(for session: ChatSession) -> URL? {
        if session.ownsDesign,
           let revision = approvedDesignRevision(for: session) {
            return DesignArtifacts.materialsDirectory(
                revision, designDirectory: designDirectory(for: session))
        }
        return designReferenceDirectory(for: session)
    }

    func designFilesURL(for session: ChatSession) -> URL? {
        if let design = designSession(for: session.id) {
            return designArtifactURL(for: design)?.deletingLastPathComponent()
        }
        if let reference = designReferenceDirectory(for: session) { return reference }
        guard session.ownsDesign else { return nil }
        return designArtifactURL(for: session)?.deletingLastPathComponent()
    }

    // Reads the disk on every call.
    func hasDesignArtifacts(for session: ChatSession) -> Bool {
        guard let directory = designFilesURL(for: session) else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path,
                                             isDirectory: &isDirectory) else { return false }
        guard isDirectory.boolValue else { return true }
        // An existing directory that cannot be read is not safe to call empty.
        guard let entries = try? FileManager.default.contentsOfDirectory(
            atPath: directory.path) else {
            return true
        }
        return !entries.isEmpty
    }

    // What the session's design files are worth once the session goes. A session that took
    // the handoff has already turned the approved design into code, so its copy of the
    // design is a record rather than the work itself.
    func designCost(for session: ChatSession) -> DesignCost {
        guard hasDesignArtifacts(for: session) else { return .absent }
        return session.isImplementingDesign ? .implemented : .unimplemented
    }

    func implementationReferenceAttachments(for session: ChatSession) -> [Attachment] {
        guard let directory = implementationDesignDirectory(for: session) else { return [] }
        return ["index.html", "handoff.md", "preview.png"].compactMap { name in
            let url = directory.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path) ? Attachment(url: url) : nil
        }
    }

    func fallbackHandoff(for session: ChatSession,
                                 revision: DesignRevision) -> String {
        let request = transcript(of: session.id).last(where: { $0.role == .user })?.text.trimmed
        let goal = request.flatMap { $0.isEmpty ? nil : $0 } ?? session.title
        return """
        # \(revision.title) implementation handoff

        ## Goal

        \(goal)

        ## Reference

        Open `index.html` and `design.json` in this folder. Treat the HTML as a visual and \
        interaction reference. Reuse the production project's existing components, tokens, \
        patterns, and architecture.

        Treat this Design as a scoped change to the existing product unless the goal clearly \
        requires a new or replacement experience. Inspect the current implementation and close \
        only the gap represented by the goal and Design. Preserve behavior, structure, screens, \
        and content outside that gap. Anything omitted from the Design remains unchanged.

        ## Acceptance

        - Match the approved visual hierarchy and content.
        - Implement the interactions represented in the Design.
        - Cover responsive and accessible behavior appropriate to the product.
        - Run the project's relevant tests before finishing.
        """
    }
}
