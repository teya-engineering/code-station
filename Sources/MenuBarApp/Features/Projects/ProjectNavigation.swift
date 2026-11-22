import Foundation
import Observation

@MainActor
@Observable
final class ProjectNavigation {
    @ObservationIgnored private let preferences: UserDefaults

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
    }

    var savedProjectID: UUID? {
        get { savedID("selectedProjectID") }
        set { preferences.set(newValue?.uuidString, forKey: "selectedProjectID") }
    }
    var savedSessionID: UUID? { savedID("selectedSessionID") }
    var savedWorkspaceID: UUID? { savedID("selectedWorkspaceID") }

    private func savedID(_ key: String) -> UUID? {
        preferences.string(forKey: key).flatMap(UUID.init(uuidString:))
    }

    var selection: SidebarSelection?
    var selectedProjectID: UUID?
    var history = NavigationHistory()
    var sessionOpenRequest: SessionOpenRequest?
    var projectToReveal: UUID?
    var sessionToReveal: UUID?
    var sidebarHighlight: UUID?
    // A project added to a workspace somewhere other than the sidebar. The sidebar plays
    // the landing in the workspace's row and shows the receipt, so taking the add back
    // flies the tile home the same way wherever it was added.
    var workspaceAddition: WorkspaceAddition.Added?
    var pointedSidebarItem: UUID?
    @ObservationIgnored var lastSessionTabs: [UUID: SessionDestination] = [:]
    @ObservationIgnored var isWalkingHistory = false

    var currentPlace: NavigationPlace? {
        switch selection {
        case .home: .home
        case .session(let id): .session(id)
        case .workspace(let id): .workspace(id)
        case nil: selectedProjectID.map(NavigationPlace.project)
        }
    }

    func revealProject(_ id: UUID, enabled: Bool) {
        if enabled { projectToReveal = id }
        sidebarHighlight = enabled ? id : nil
        arrived()
    }

    func revealSession(_ id: UUID, destination: SessionDestination, enabled: Bool) {
        sessionOpenRequest = SessionOpenRequest(sessionID: id, destination: destination)
        sessionToReveal = id
        sidebarHighlight = enabled ? id : nil
        arrived()
    }

    func pointSidebarItem(_ id: UUID, hovering: Bool) {
        if hovering { pointedSidebarItem = id }
        else if pointedSidebarItem == id { pointedSidebarItem = nil }
    }

    func walk(_ place: NavigationPlace, open: (NavigationPlace) -> Void) {
        isWalkingHistory = true
        defer { isWalkingHistory = false }
        open(place)
    }

    func arrived() {
        persistSelection()
        recordVisit()
    }

    func recordVisit() {
        guard !isWalkingHistory, let currentPlace else { return }
        history.visit(currentPlace)
    }

    // Navigation is a preference and never needs to rewrite the project index.
    func persistSelection() {
        let sessionID = if case .session(let id) = selection { id } else { nil as UUID? }
        preferences.set(sessionID?.uuidString, forKey: "selectedSessionID")
        let workspaceID = if case .workspace(let id) = selection { id } else { nil as UUID? }
        preferences.set(workspaceID?.uuidString, forKey: "selectedWorkspaceID")
        savedProjectID = selectedProjectID
    }
}
