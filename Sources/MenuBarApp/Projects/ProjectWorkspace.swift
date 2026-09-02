import Foundation

// A workspace is a reusable group of projects. The lead project supplies the working
// directory for every session, while the other projects are attached to the agent.
// Membership is stored here, but each session takes its own snapshot so changing a
// workspace never changes where an existing conversation runs.
struct ProjectWorkspace: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var projectIDs: [UUID]
    var leadProjectID: UUID
    var isPinned: Bool
    var sidebarAvatarIndex: Int?
    // Each session can still override its checkout mode. These are only the choices
    // preselected when a session starts, which keeps repeated workspace setup quick.
    var worktreeProjectIDs: [UUID]

    init(id: UUID = UUID(), name: String, projectIDs: [UUID], leadProjectID: UUID,
         isPinned: Bool = false, sidebarAvatarIndex: Int? = nil,
         worktreeProjectIDs: [UUID]? = nil) {
        self.id = id
        self.name = name
        self.projectIDs = projectIDs
        self.leadProjectID = leadProjectID
        self.isPinned = isPinned
        self.sidebarAvatarIndex = sidebarAvatarIndex
        self.worktreeProjectIDs = worktreeProjectIDs ?? projectIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, projectIDs, leadProjectID, isPinned, sidebarAvatarIndex
        case worktreeProjectIDs
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        projectIDs = try container.decode([UUID].self, forKey: .projectIDs)
        leadProjectID = try container.decode(UUID.self, forKey: .leadProjectID)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        sidebarAvatarIndex = try container.decodeIfPresent(Int.self,
                                                            forKey: .sidebarAvatarIndex)
        // Workspaces written before checkout defaults existed already opened every Git
        // repository as a worktree, so selecting every member preserves that behavior.
        worktreeProjectIDs = try container.decodeIfPresent([UUID].self,
                                                            forKey: .worktreeProjectIDs)
            ?? projectIDs
    }
}

// One project as it was opened for a workspace session. A nil worktree path means the
// project folder itself, which keeps plain folders useful without pretending they can
// be isolated. The first item is always the lead project.
struct SessionProject: Identifiable, Codable, Equatable, Sendable {
    var projectID: UUID
    var worktreePath: String?
    var worktreeBranch: String?

    var id: UUID { projectID }
}
