import Foundation

// What the top bar over a session shows beyond its identity row, as values for the
// session header: the tabs of the GUI's destination deck, and the warnings of its strip
// under the decks. Worked out here, from the session, so every front end shows the same
// tabs and says the same thing about a broken session.

// One tab of the deck, in the order ⌘1…⌘5 reach them in the GUI. A front end numbers them
// by position, so a session without the Design tab has no gap in the row.
public struct RemoteSessionTab: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case chat, design, troubleshoot, changes, explorer
    }

    public let kind: Kind
    // What the tab reads: the conversation's tab is "Chat", or "Design" while the session
    // designs and "Build" while it implements a design.
    public let title: String
    // The Design tab's dot: there are design files to look at.
    public var hasContent: Bool?

    public init(kind: Kind, title: String, hasContent: Bool? = nil) {
        self.kind = kind
        self.title = title
        self.hasContent = hasContent
    }

    // The GUI's deck for this session (`SessionView.headerTabs`): first what the agent is
    // set to do, then what it did to the working tree. A session that is itself designing
    // has its conversation read "Design" and no separate Design tab.
    @MainActor
    static func tabs(for session: ChatSession, store: ProjectStore) -> [RemoteSessionTab] {
        let hasDesign = store.hasDesignArtifacts(for: session)
        var tabs: [RemoteSessionTab]
        if session.isActivelyDesigning {
            tabs = [RemoteSessionTab(kind: .chat, title: "Design", hasContent: hasDesign)]
        } else {
            tabs = [RemoteSessionTab(kind: .chat, title: session.isImplementingDesign ? "Build" : "Chat"),
                    RemoteSessionTab(kind: .design, title: "Design", hasContent: hasDesign)]
        }
        tabs.append(RemoteSessionTab(kind: .troubleshoot, title: "Troubleshoot"))
        tabs.append(RemoteSessionTab(kind: .changes, title: "Changes"))
        tabs.append(RemoteSessionTab(kind: .explorer, title: "Explorer"))
        return tabs
    }
}

// One line of the GUI's warning strip: why the session cannot work as it is, and what
// can be done about it.
public struct RemoteWarning: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        // The project's own folder is gone.
        case missingFolder
        // A worktree or workspace folder the session works in is gone.
        case missingCheckout
        // The session's agent is not installed.
        case agentMissing
    }

    public let kind: Kind
    public let message: String
    // Whether a rebuild could put the lost checkout back.
    public let canRebuild: Bool

    public init(kind: Kind, message: String, canRebuild: Bool = false) {
        self.kind = kind
        self.message = message
        self.canRebuild = canRebuild
    }

    // What the GUI's strip says (`SessionView.warningStrip`): one warning, the most
    // pressing. A handful of stat calls, cheap enough for every look at the session.
    @MainActor
    static func warnings(for session: ChatSession, project: Project, store: ProjectStore,
                         runner: SessionRunner) -> [RemoteWarning] {
        if store.isMissing(project) {
            return [RemoteWarning(kind: .missingFolder,
                                  message: "Folder not found at \(project.collapsedPath). Move it back or remove the project.")]
        }
        if let missing = SessionLifecycle.missingDirectories(of: session, in: store).first {
            // A workspace folder and a worktree both turn up among the working folders;
            // only the session says which it has.
            let name = session.sessionProjects == nil ? "Worktree" : "Workspace folder"
            if let rebuildable = SessionLifecycle.rebuildableCheckouts(of: session, in: store).first {
                return [RemoteWarning(kind: .missingCheckout,
                                      message: "\(name) not found at \(rebuildable.path.abbreviatedPath). It was removed outside the app.",
                                      canRebuild: true)]
            }
            return [RemoteWarning(kind: .missingCheckout,
                                  message: "\(name) not found at \(missing.abbreviatedPath). Move it back, or delete this session.")]
        }
        if !runner.isAvailable(session.agent) {
            return [RemoteWarning(kind: .agentMissing,
                                  message: "\(session.agent.title) CLI not found on PATH. Sessions cannot run until it is installed.")]
        }
        return []
    }
}
