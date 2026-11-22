import Foundation

extension AppSettings {
    // The same colour the session's project or workspace wears in the sidebar, so a
    // bubble and the icon it belongs to always agree.
    @MainActor
    func userMessageStyle(for session: ChatSession, in store: ProjectStore) -> UserMessageStyle {
        guard messageColour == .projectIcon else { return messageColour.style(projectTint: nil) }
        let tint: Theme.ProjectTint? =
            if let workspace = session.workspaceID.flatMap(store.workspace) {
                workspace.sidebarAvatar.identityTint(
                    iconSet: sidebarIconSet, style: diceBearAvatarStyle,
                    name: workspace.name, monogramTint: Theme.workspaceTint)
            } else if let project = store.project(session.projectID) {
                project.sidebarAvatar.identityTint(
                    iconSet: sidebarIconSet, style: diceBearAvatarStyle,
                    name: project.name, monogramTint: Theme.projectTint(for: project.name))
            } else {
                nil
            }
        return messageColour.style(projectTint: tint)
    }
}
