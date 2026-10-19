import Foundation
import Observation

@MainActor
@Observable
public final class AgentCatalog {
    public var agent: AgentKind {
        didSet { if !adoptingDefaults { Preferences.setAgent(agent, in: preferences) } }
    }
    // Set while the defaults are taken from preferences, so they are not written back.
    @ObservationIgnored private var adoptingDefaults = false
    private var defaultsByAgent: [AgentKind: SessionSettings]
    public private(set) var discoveredModels: [AgentKind: [ModelChoice.Option]]
    private var paths: [AgentKind: String]
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private let discoversPaths: Bool
    @ObservationIgnored private var modelRefreshIDs: [AgentKind: UUID] = [:]
    @ObservationIgnored private var catalogsAsked: Set<AgentKind> = []

    public init(paths: [AgentKind: String]? = nil,
         discoveredModels: [AgentKind: [ModelChoice.Option]] = [:],
         preferences: UserDefaults = Preferences.defaults) {
        self.preferences = preferences
        agent = Preferences.agent(in: preferences)
        self.discoveredModels = discoveredModels
        defaultsByAgent = Dictionary(uniqueKeysWithValues: AgentKind.allCases.map {
            ($0, Preferences.sessionDefaults(for: $0, in: preferences))
        })
        discoversPaths = paths == nil
        self.paths = paths ?? [:]
        refreshAvailableAgents()
    }

    public var designAmbition: DesignAmbition { Preferences.designAmbition(in: preferences) }

    public var defaults: SessionSettings {
        get { defaults(for: agent) }
        set { setDefaults(newValue, for: agent) }
    }

    public func executable(for agent: AgentKind) -> String? { paths[agent] }

    public func defaults(for agent: AgentKind) -> SessionSettings {
        defaultsByAgent[agent] ?? SessionSettings()
    }

    public func setDefaults(_ defaults: SessionSettings, for agent: AgentKind) {
        defaultsByAgent[agent] = defaults
        Preferences.setSessionDefaults(defaults, for: agent, in: preferences)
    }

    // Takes the agent and the defaults new sessions start with from the preferences
    // given, without writing them back: someone changed them elsewhere (a client's
    // settings screen), and new sessions follow from now on.
    public func adoptDefaults(from store: UserDefaults) {
        adoptingDefaults = true
        defer { adoptingDefaults = false }
        // Only what changed, so reading the same defaults again redraws nothing.
        let chosen = Preferences.agent(in: store)
        if agent != chosen { agent = chosen }
        for kind in AgentKind.allCases {
            let defaults = Preferences.sessionDefaults(for: kind, in: store)
            if defaultsByAgent[kind] != defaults { defaultsByAgent[kind] = defaults }
        }
    }

    public func isAvailable(_ agent: AgentKind) -> Bool { paths[agent] != nil }

    public func refreshAvailableAgents() {
        guard discoversPaths else { return }
        for kind in AgentKind.allCases {
            paths[kind] = ExecutableSearch.resolve(kind.command)
        }
    }

    // Reads the catalog the first time a picker for this agent is shown, and does nothing
    // on every later showing. Reading starts the agent's CLI, and that CLI may stop on a
    // system prompt for the sign-in it has stored, so the ask waits until a picker is on
    // screen and the person is already looking at that agent.
    public func discoverModels(for agent: AgentKind) async {
        guard catalogsAsked.insert(agent).inserted else { return }
        await readModels(for: [agent])
    }

    // Asks every installed CLI that publishes a catalog for its models again, for the
    // refresh button on the Agents settings pane.
    public func refreshDiscoveredModels() async {
        catalogsAsked.formUnion(AgentKind.allCases)
        await readModels(for: AgentKind.allCases)
    }

    // A read started while another is still asking wins: the older answer is dropped when
    // it arrives.
    private func readModels(for agents: [AgentKind]) async {
        await withTaskGroup(of: (AgentKind, [ModelChoice.Option]?, UUID).self) { group in
            for agent in agents {
                guard let path = paths[agent] else { continue }
                let id = UUID()
                modelRefreshIDs[agent] = id
                let searchPath = ExecutableSearch.searchPath
                group.addTask {
                    let models: [ModelChoice.Option]? = switch agent {
                    case .codex: await CodexModelReader.read(at: path, searchPath: searchPath)
                    case .copilot: await CopilotServer.models(at: path, searchPath: searchPath)
                    case .claudeCode: nil
                    }
                    return (agent, models, id)
                }
            }
            for await (agent, models, id) in group {
                guard modelRefreshIDs[agent] == id, let models else { continue }
                discoveredModels[agent] = models
            }
        }
    }

    public func modelOptions(for agent: AgentKind) -> [ModelChoice.Option] {
        ModelChoice.options(for: agent, discovered: discoveredModels[agent])
    }

    public func validModel(_ id: String?, for agent: AgentKind) -> String? {
        ModelChoice.valid(id, for: agent, discovered: discoveredModels[agent])
    }

    public func modelTitle(_ id: String?) -> String {
        ModelChoice.title(of: id, discovered: discoveredModels.values.flatMap { $0 })
    }

    public func effortOptions(for agent: AgentKind, model: String?) -> [EffortChoice.Option] {
        EffortChoice.all(for: agent, model: model, discovered: discoveredModels[agent])
    }

    public func validEffort(_ id: String?, for agent: AgentKind, model: String?) -> String? {
        EffortChoice.valid(id, for: agent, model: model, discovered: discoveredModels[agent])
    }

    public func effortTitle(_ id: String?, for agent: AgentKind, model: String?) -> String {
        EffortChoice.summary(of: id, agent: agent, model: model,
                             discovered: discoveredModels[agent])
    }

    public var availableAgents: [AgentKind] {
        AgentKind.allCases.filter(isAvailable)
    }

    public func agentForNewSession(selected: AgentKind?) -> AgentKind? {
        if let selected, isAvailable(selected) { return selected }
        if isAvailable(agent) { return agent }
        return availableAgents.first
    }

    public var available: Bool { isAvailable(agent) }

}
