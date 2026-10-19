import Foundation
import Observation
import CodeStationCore

@MainActor
@Observable
final class FirstRunSetup {
    enum Step: Int, CaseIterable {
        case agent, configuration, project

        var title: String {
            switch self {
            case .agent: "Connect an agent"
            case .configuration: "Team setup"
            case .project: "Open a project"
            }
        }
    }

    var step = Step.agent
    var selectedAgent: AgentKind
    var usesTeamSettings = false
    var projectURL: URL?
    var projectFailure: String?
    private(set) var agentWasDeferred = false
    private(set) var appliedConfiguration: SiteConfigurationSelection?
    let loader: SiteConfigurationLoader

    init(initialAgent: AgentKind, loader: SiteConfigurationLoader = SiteConfigurationLoader()) {
        selectedAgent = initialAgent
        self.loader = loader
    }

    func continueFromAgent(readiness: AgentReadiness, deferSetup: Bool = false) {
        guard readiness == .connected || deferSetup else { return }
        agentWasDeferred = deferSetup
        step = .configuration
    }

    var canContinueConfiguration: Bool {
        !loader.isLoading && (!usesTeamSettings || loader.selection != nil)
    }

    func continueFromConfiguration(
        install: (SiteConfigurationSelection) throws -> Void = {
            try SiteConfigurationImporter.install($0)
        },
        didInstall: () -> Void
    ) {
        guard canContinueConfiguration else { return }
        if usesTeamSettings, let selection = loader.selection,
           selection != appliedConfiguration {
            do {
                try install(selection)
            } catch {
                loader.failure = error.localizedDescription
                return
            }
            appliedConfiguration = selection
            loader.failure = nil
            didInstall()
        }
        step = .project
    }

    @discardableResult
    func finish(in store: ProjectStore, openProject: Bool) -> Bool {
        projectFailure = nil
        guard openProject else {
            store.selectHome()
            return true
        }
        guard let url = projectURL,
              (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            projectFailure = "The project folder is no longer available. Choose a folder to continue."
            return false
        }

        let added = store.addProject(at: url)
        guard let id = added?.id ?? store.selectedProjectID, store.save() else {
            projectFailure = store.saveError ?? "The project could not be saved. Try again."
            return false
        }
        store.selectProject(id, revealingInSidebar: true)
        return true
    }
}
