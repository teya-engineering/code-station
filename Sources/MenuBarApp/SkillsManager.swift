import Foundation
import Observation

struct SkillMarketplace: Decodable, Equatable, Sendable {
    struct Plugin: Decodable, Equatable, Identifiable, Sendable {
        let name: String
        let description: String
        let version: String?
        let category: String?

        var id: String { name }
    }

    let name: String
    let description: String?
    let plugins: [Plugin]
}

struct SkillMarketplaceConfiguration: Codable, Equatable, Sendable {
    enum SourceKind: String, Codable, Equatable, Sendable {
        case gitRepository
        case localFile
    }

    let source: String
    let sourceKind: SourceKind
    let marketplace: String
    let label: String

    var isLocalFile: Bool { sourceKind == .localFile }
    var isValid: Bool {
        !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !marketplace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func siteDefault(_ skills: SiteDefaults.Skills) -> Self {
        Self(source: skills.repository,
             sourceKind: skills.sourceKind ?? .gitRepository,
             marketplace: skills.marketplace,
             label: skills.name)
    }
}

enum SkillHost: String, CaseIterable, Identifiable, Sendable {
    case claude
    case codex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    var command: String { rawValue }

    var listArguments: [String] { ["plugin", "list", "--json"] }

    var marketplaceListArguments: [String] {
        ["plugin", "marketplace", "list", "--json"]
    }

    func marketplaceAddArguments(source: String) -> [String] {
        return switch self {
        case .claude: ["plugin", "marketplace", "add", source]
        case .codex: ["plugin", "marketplace", "add", source, "--json"]
        }
    }

    func marketplaceRefreshArguments(name: String) -> [String] {
        return switch self {
        case .claude: ["plugin", "marketplace", "update", name]
        case .codex: ["plugin", "marketplace", "upgrade", name, "--json"]
        }
    }

    func installArguments(plugin: String, marketplace: String) -> [String] {
        let selector = "\(plugin)@\(marketplace)"
        return switch self {
        case .claude: ["plugin", "install", selector, "--scope", "user"]
        case .codex: ["plugin", "add", selector, "--json"]
        }
    }

    func removeArguments(plugin: String, marketplace: String) -> [String] {
        let selector = "\(plugin)@\(marketplace)"
        return switch self {
        case .claude: ["plugin", "uninstall", selector, "--scope", "user"]
        case .codex: ["plugin", "remove", selector, "--json"]
        }
    }

    func updateArguments(plugin: String, marketplace: String) -> [String] {
        let selector = "\(plugin)@\(marketplace)"
        return switch self {
        case .claude: ["plugin", "update", selector, "--scope", "user"]
        // Adding an installed Codex plugin reconciles its cached version with the
        // refreshed marketplace snapshot.
        case .codex: ["plugin", "add", selector, "--json"]
        }
    }
}

struct SkillInstallation: Equatable, Sendable {
    let version: String
    let enabled: Bool
}

enum SkillsRefreshInterval: Int, CaseIterable, Identifiable, Sendable {
    case never = 0
    case oneDay = 1
    case fiveDays = 5
    case thirtyDays = 30

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .never: "Never"
        case .oneDay: "Every 1 day"
        case .fiveDays: "Every 5 days"
        case .thirtyDays: "Every 30 days"
        }
    }

    nonisolated func shouldRefresh(lastRefresh: Date?, now: Date = Date()) -> Bool {
        guard self != .never else { return false }
        guard let lastRefresh else { return true }
        return now.timeIntervalSince(lastRefresh) >= TimeInterval(rawValue * 86_400)
    }
}

enum SkillActionProgress: String, Equatable, Sendable {
    case checkingMarketplace = "Checking marketplace…"
    case addingMarketplace = "Adding marketplace…"
    case refreshingMarketplace = "Refreshing marketplace…"
    case installing = "Installing skill…"
    case uninstalling = "Uninstalling skill…"
    case updating = "Updating skill…"
    case checkingInstallation = "Checking installation…"
}

@MainActor
@Observable
final class SkillsManager {
    private(set) var marketplace: SkillMarketplace?
    // Sorted when the catalogue arrives rather than on every read: the sidebar and the
    // tools menu both reach for this while they draw, and the compare is not free.
    private(set) var plugins: [SkillMarketplace.Plugin] = []
    private(set) var installations: [SkillHost: [String: SkillInstallation]] = [:]
    private(set) var hostFailures: [SkillHost: String] = [:]
    private(set) var actionFailures: [Action: String] = [:]
    private var actionProgress: [Action: SkillActionProgress] = [:]
    private(set) var isRefreshing = false
    private(set) var isUpdatingAll = false
    private(set) var hasLoaded = false
    private(set) var catalogueNotice: String?

    private let cacheURLOverride: URL?
    @ObservationIgnored private let preferences: UserDefaults

    private var configuration: SkillMarketplaceConfiguration? {
        if let selected = Preferences.skillsMarketplace(in: preferences), selected.isValid {
            return selected
        }
        guard let skills = SiteDefaults.current.skills else { return nil }
        let siteDefault = SkillMarketplaceConfiguration.siteDefault(skills)
        return siteDefault.isValid ? siteDefault : nil
    }

    var marketplaceName: String { configuration?.marketplace ?? "" }

    var marketplaceConfiguration: SkillMarketplaceConfiguration? { configuration }

    // What the marketplace is called on screen. A build with no marketplace still has to
    // put something under the Skills heading.
    var marketplaceLabel: String { configuration?.label ?? "No marketplace" }

    var isConfigured: Bool { configuration != nil }

    private var cacheURL: URL {
        if let cacheURLOverride { return cacheURLOverride }
        let name = Preferences.skillsMarketplace(in: preferences) == nil
            ? marketplaceName
            : "custom"
        return AppPaths.directory("marketplaces", backedUp: false)
            .appendingPathComponent(name, isDirectory: true)
    }

    struct Action: Hashable, Sendable {
        let host: SkillHost
        let plugin: String
    }

    init(cacheURL: URL? = nil, preferences: UserDefaults = .standard) {
        cacheURLOverride = cacheURL
        self.preferences = preferences
    }

    private func setMarketplace(_ catalogue: SkillMarketplace?) {
        marketplace = catalogue
        plugins = catalogue?.plugins.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        } ?? []
    }

    var updateCount: Int {
        plugins.reduce(into: 0) { count, plugin in
            for host in SkillHost.allCases where isOutdated(plugin, on: host) { count += 1 }
        }
    }

    var installedPluginCount: Int {
        plugins.count { plugin in
            SkillHost.allCases.contains { installation(of: plugin, on: $0) != nil }
        }
    }

    var lastRefresh: Date? { Preferences.skillsLastRefresh(in: preferences) }

    func isAvailable(_ host: SkillHost) -> Bool {
        ProcessManager.resolve(host.command) != nil
    }

    func hostFailure(_ host: SkillHost) -> String? {
        hostFailures[host]
    }

    func canManage(_ host: SkillHost) -> Bool {
        isAvailable(host) && hostFailures[host] == nil
    }

    func installation(of plugin: SkillMarketplace.Plugin,
                      on host: SkillHost) -> SkillInstallation? {
        installation(named: plugin.name, on: host)
    }

    func installation(named plugin: String, on host: SkillHost) -> SkillInstallation? {
        installations[host]?[plugin]
    }

    func isOutdated(_ plugin: SkillMarketplace.Plugin, on host: SkillHost) -> Bool {
        Self.isOutdated(installedVersion: installation(of: plugin, on: host)?.version,
                        latestVersion: plugin.version)
    }

    nonisolated static func isOutdated(installedVersion: String?, latestVersion: String?) -> Bool {
        guard let installedVersion, installedVersion != "unknown",
              let latestVersion, latestVersion != "unknown" else { return false }
        return installedVersion != latestVersion
    }

    func progress(of plugin: SkillMarketplace.Plugin,
                  on host: SkillHost) -> SkillActionProgress? {
        actionProgress[Action(host: host, plugin: plugin.name)]
    }

    func actionFailure(_ plugin: SkillMarketplace.Plugin, on host: SkillHost) -> String? {
        actionFailures[Action(host: host, plugin: plugin.name)]
    }

    func configure(localFile url: URL) async throws {
        guard !isRefreshing else { return }
        let (configuration, catalogue) = try Self.localConfiguration(at: url)

        isRefreshing = true
        catalogueNotice = nil
        hostFailures = [:]
        Preferences.setSkillsMarketplace(configuration, in: preferences)
        Preferences.setSkillsLastRefresh(Date(), in: preferences)

        async let claudeLoad = Self.loadInstallations(for: .claude,
                                                       marketplace: configuration.marketplace)
        async let codexLoad = Self.loadInstallations(for: .codex,
                                                      marketplace: configuration.marketplace)
        let (claude, codex) = await (claudeLoad, codexLoad)

        setMarketplace(catalogue)
        apply(claude, to: .claude)
        apply(codex, to: .codex)
        isRefreshing = false
        hasLoaded = true
    }

    func configure(gitRepository source: String) async throws {
        guard !isRefreshing else { return }
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { throw ImportError("Enter a Git repository.") }

        isRefreshing = true
        catalogueNotice = nil
        hostFailures = [:]
        defer { isRefreshing = false }

        let load = await Self.loadGitCatalogue(source: source,
                                               at: cacheURLOverride
                                                   ?? AppPaths.directory("marketplaces",
                                                                         backedUp: false)
                                                       .appendingPathComponent("custom",
                                                                               isDirectory: true),
                                               forceClone: true)
        guard let catalogue = load.marketplace else {
            throw ImportError(load.notice ?? "The marketplace could not be loaded.")
        }
        let configuration = SkillMarketplaceConfiguration(
            source: source,
            sourceKind: .gitRepository,
            marketplace: catalogue.name,
            label: catalogue.name)
        Preferences.setSkillsMarketplace(configuration, in: preferences)
        Preferences.setSkillsLastRefresh(Date(), in: preferences)

        async let claudeLoad = Self.loadInstallations(for: .claude,
                                                       marketplace: configuration.marketplace)
        async let codexLoad = Self.loadInstallations(for: .codex,
                                                      marketplace: configuration.marketplace)
        let (claude, codex) = await (claudeLoad, codexLoad)

        setMarketplace(catalogue)
        apply(claude, to: .claude)
        apply(codex, to: .codex)
        hasLoaded = true
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        catalogueNotice = nil
        hostFailures = [:]

        let selectedConfiguration = configuration
        let marketplaceName = selectedConfiguration?.marketplace ?? ""

        async let catalogueLoad = Self.loadCatalogue(configuration: selectedConfiguration,
                                                      at: cacheURL)
        async let claudeLoad = Self.loadInstallations(for: .claude,
                                                       marketplace: marketplaceName)
        async let codexLoad = Self.loadInstallations(for: .codex,
                                                      marketplace: marketplaceName)

        let (catalogue, claude, codex) = await (catalogueLoad, claudeLoad, codexLoad)

        setMarketplace(catalogue.marketplace)
        catalogueNotice = catalogue.notice
        if catalogue.didRefresh {
            Preferences.setSkillsLastRefresh(Date(), in: preferences)
        }
        apply(claude, to: .claude)
        apply(codex, to: .codex)
        isRefreshing = false
        hasLoaded = true
    }

    func refreshIfNeeded(every interval: SkillsRefreshInterval, now: Date = Date()) async {
        guard interval.shouldRefresh(lastRefresh: lastRefresh, now: now) else {
            return
        }
        await refresh()
    }

    func loadForNotifications(every interval: SkillsRefreshInterval,
                              now: Date = Date()) async {
        if interval.shouldRefresh(lastRefresh: lastRefresh, now: now) {
            await refresh()
        } else {
            await loadCachedState()
        }
    }

    func setInstalled(_ installed: Bool, plugin: SkillMarketplace.Plugin,
                      on host: SkillHost) async {
        let action = Action(host: host, plugin: plugin.name)
        guard actionProgress[action] == nil, canManage(host) else { return }
        actionProgress[action] = installed ? .checkingMarketplace : .uninstalling
        actionFailures[action] = nil
        defer { actionProgress[action] = nil }

        let result: CommandResult
        if installed {
            let ready = await prepareMarketplace(for: host, action: action)
            if ready.ok {
                actionProgress[action] = .installing
                result = await Self.run(host.command,
                                        host.installArguments(plugin: plugin.name,
                                                              marketplace: marketplaceName))
            } else {
                result = ready
            }
        } else {
            result = await Self.run(host.command,
                                    host.removeArguments(plugin: plugin.name,
                                                         marketplace: marketplaceName))
        }

        if result.ok {
            actionProgress[action] = .checkingInstallation
            await refreshInstallations(for: host)
        } else {
            actionFailures[action] = result.failureMessage
        }
    }

    func update(_ plugin: SkillMarketplace.Plugin, on host: SkillHost) async {
        let action = Action(host: host, plugin: plugin.name)
        guard actionProgress[action] == nil, canManage(host) else { return }
        actionProgress[action] = .checkingMarketplace
        actionFailures[action] = nil
        defer { actionProgress[action] = nil }

        let ready = await prepareMarketplace(for: host, action: action)
        let result: CommandResult
        if ready.ok {
            actionProgress[action] = .updating
            result = await Self.run(host.command,
                                    host.updateArguments(plugin: plugin.name,
                                                         marketplace: marketplaceName))
        } else {
            result = ready
        }
        if result.ok {
            actionProgress[action] = .checkingInstallation
            await refreshInstallations(for: host)
        } else {
            actionFailures[action] = result.failureMessage
        }
    }

    func updateAll() async {
        guard !isUpdatingAll, !isRefreshing else { return }
        let updates = SkillHost.allCases.flatMap { host in
            plugins.filter { isOutdated($0, on: host) }.map { ($0, host) }
        }
        guard !updates.isEmpty else { return }

        isUpdatingAll = true
        defer { isUpdatingAll = false }

        for (plugin, host) in updates {
            await update(plugin, on: host)
        }
    }

    private func refreshInstallations(for host: SkillHost) async {
        apply(await Self.loadInstallations(for: host, marketplace: marketplaceName), to: host)
    }

    private func apply(_ load: InstallationLoad, to host: SkillHost) {
        installations[host] = load.installations
        hostFailures[host] = load.failure
    }

    // MARK: - Marketplace catalogue

    struct CatalogueLoad: Sendable {
        let marketplace: SkillMarketplace?
        let notice: String?
        let didRefresh: Bool
    }

    nonisolated static func decodeMarketplace(_ data: Data) throws -> SkillMarketplace {
        try JSONDecoder().decode(SkillMarketplace.self, from: data)
    }

    nonisolated static func localConfiguration(at url: URL) throws
        -> (SkillMarketplaceConfiguration, SkillMarketplace) {
        let url = url.standardizedFileURL
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ImportError("The marketplace file could not be read: \(error.localizedDescription)")
        }

        let marketplace: SkillMarketplace
        do {
            marketplace = try decodeMarketplace(data)
        } catch {
            throw ImportError("The marketplace file is not valid: \(error.localizedDescription)")
        }
        guard !marketplace.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError("The marketplace file must contain a name.")
        }
        return (SkillMarketplaceConfiguration(source: url.path,
                                               sourceKind: .localFile,
                                               marketplace: marketplace.name,
                                               label: marketplace.name),
                marketplace)
    }

    private func loadCachedState() async {
        guard !hasLoaded, !isRefreshing else { return }
        isRefreshing = true

        let selectedConfiguration = configuration
        let marketplaceName = selectedConfiguration?.marketplace ?? ""
        let catalogue = Self.loadCachedCatalogue(configuration: selectedConfiguration,
                                                  at: cacheURL)
        async let claudeLoad = Self.loadInstallations(for: .claude,
                                                       marketplace: marketplaceName)
        async let codexLoad = Self.loadInstallations(for: .codex,
                                                      marketplace: marketplaceName)
        let (claude, codex) = await (claudeLoad, codexLoad)

        setMarketplace(catalogue.marketplace)
        catalogueNotice = catalogue.notice
        apply(claude, to: .claude)
        apply(codex, to: .codex)
        isRefreshing = false
        hasLoaded = true
    }

    private nonisolated static func loadCachedCatalogue(
        configuration: SkillMarketplaceConfiguration?,
        at cacheURL: URL
    ) -> CatalogueLoad {
        guard let configuration else {
            return CatalogueLoad(marketplace: nil, notice: nil, didRefresh: false)
        }
        let manifest = configuration.isLocalFile
            ? URL(fileURLWithPath: configuration.source)
            : cacheURL.appendingPathComponent(".claude-plugin/marketplace.json")
        guard let data = try? Data(contentsOf: manifest),
              let marketplace = try? decodeMarketplace(data) else {
            return CatalogueLoad(marketplace: nil, notice: nil, didRefresh: false)
        }
        return CatalogueLoad(marketplace: marketplace, notice: nil, didRefresh: false)
    }

    private nonisolated static func loadCatalogue(
        configuration: SkillMarketplaceConfiguration?,
        at cacheURL: URL
    ) async -> CatalogueLoad {
        guard let configuration else {
            return CatalogueLoad(marketplace: nil,
                                 notice: "No skills marketplace is set up.",
                                 didRefresh: false)
        }

        if configuration.isLocalFile {
            let url = URL(fileURLWithPath: configuration.source)
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                return CatalogueLoad(
                    marketplace: nil,
                    notice: "The marketplace file could not be read: \(error.localizedDescription)",
                    didRefresh: false)
            }
            do {
                return CatalogueLoad(marketplace: try decodeMarketplace(data),
                                     notice: nil,
                                     didRefresh: true)
            } catch {
                return CatalogueLoad(
                    marketplace: nil,
                    notice: "The marketplace file is not valid: \(error.localizedDescription)",
                    didRefresh: false)
            }
        }

        return await loadGitCatalogue(source: configuration.source, at: cacheURL)
    }

    nonisolated static func loadGitCatalogue(source: String,
                                             at cacheURL: URL,
                                             forceClone: Bool = false) async
        -> CatalogueLoad {
        let files = FileManager.default
        let manifest = cacheURL.appendingPathComponent(".claude-plugin/marketplace.json")
        let gitFolder = cacheURL.appendingPathComponent(".git")

        if !forceClone, files.fileExists(atPath: gitFolder.path) {
            let pulled = await run("git", ["-C", cacheURL.path, "pull", "--ff-only"])
            guard let data = try? Data(contentsOf: manifest),
                  let marketplace = try? decodeMarketplace(data) else {
                let detail = pulled.ok
                    ? "The repository did not contain a readable .claude-plugin/marketplace.json file."
                    : pulled.failureMessage
                return CatalogueLoad(marketplace: nil, notice: detail, didRefresh: false)
            }
            return CatalogueLoad(
                marketplace: marketplace,
                notice: pulled.ok ? nil
                    : "Could not refresh the marketplace. Showing the cached list. \(pulled.failureMessage)",
                didRefresh: pulled.ok)
        }

        let parent = cacheURL.deletingLastPathComponent()
        let candidate = parent.appendingPathComponent(
            ".marketplace-\(UUID().uuidString)", isDirectory: true)
        do {
            try files.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            return CatalogueLoad(marketplace: nil,
                                 notice: error.localizedDescription,
                                 didRefresh: false)
        }

        let cloned = await run("git", ["clone", "--depth", "1", "--", source,
                                       candidate.path])
        guard cloned.ok else {
            try? files.removeItem(at: candidate)
            return CatalogueLoad(marketplace: nil,
                                 notice: cloned.failureMessage,
                                 didRefresh: false)
        }

        let candidateManifest = candidate
            .appendingPathComponent(".claude-plugin/marketplace.json")
        guard let data = try? Data(contentsOf: candidateManifest),
              let marketplace = try? decodeMarketplace(data) else {
            try? files.removeItem(at: candidate)
            return CatalogueLoad(
                marketplace: nil,
                notice: "The repository did not contain a readable .claude-plugin/marketplace.json file.",
                didRefresh: false)
        }

        do {
            if files.fileExists(atPath: cacheURL.path) {
                try files.removeItem(at: cacheURL)
            }
            try files.moveItem(at: candidate, to: cacheURL)
            return CatalogueLoad(marketplace: marketplace, notice: nil, didRefresh: true)
        } catch {
            try? files.removeItem(at: candidate)
            return CatalogueLoad(marketplace: nil,
                                 notice: error.localizedDescription,
                                 didRefresh: false)
        }
    }

    // MARK: - Installed plugins

    struct InstallationLoad: Sendable {
        let installations: [String: SkillInstallation]
        let failure: String?
    }

    nonisolated static func installedPlugins(from output: String, for host: SkillHost,
                                             marketplace: String)
        -> [String: SkillInstallation] {
        guard let root = jsonObject(from: output) else { return [:] }
        let rows: [[String: Any]]
        if let array = root as? [[String: Any]] {
            rows = array
        } else if let object = root as? [String: Any],
                  let installed = object["installed"] as? [[String: Any]] {
            rows = installed
        } else {
            return [:]
        }

        var result: [String: SkillInstallation] = [:]
        for row in rows {
            let identifier = row["pluginId"] as? String ?? row["id"] as? String ?? ""
            let pieces = identifier.split(separator: "@", maxSplits: 1).map(String.init)
            let name = row["name"] as? String ?? pieces.first ?? ""
            let marketplaceName = row["marketplaceName"] as? String
                ?? (pieces.count == 2 ? pieces[1] : "")
            guard !name.isEmpty, marketplaceName == marketplace else { continue }
            if host == .claude, let scope = row["scope"] as? String, scope != "user" { continue }
            if let installed = row["installed"] as? Bool, !installed { continue }

            result[name] = SkillInstallation(
                version: row["version"] as? String ?? "unknown",
                enabled: row["enabled"] as? Bool ?? true)
        }
        return result
    }

    nonisolated static func marketplaceNames(from output: String) -> Set<String> {
        guard let root = jsonObject(from: output) else { return [] }
        let rows: [[String: Any]]
        if let array = root as? [[String: Any]] {
            rows = array
        } else if let object = root as? [String: Any],
                  let marketplaces = object["marketplaces"] as? [[String: Any]] {
            rows = marketplaces
        } else {
            return []
        }
        return Set(rows.compactMap { $0["name"] as? String })
    }

    private nonisolated static func loadInstallations(for host: SkillHost,
                                                      marketplace: String) async
        -> InstallationLoad {
        guard !marketplace.isEmpty, ProcessManager.resolve(host.command) != nil else {
            return InstallationLoad(installations: [:], failure: nil)
        }
        let result = await run(host.command, host.listArguments)
        guard result.ok else {
            return InstallationLoad(installations: [:], failure: result.failureMessage)
        }
        return InstallationLoad(installations: installedPlugins(from: result.output,
                                                                for: host,
                                                                marketplace: marketplace),
                                failure: nil)
    }

    private func prepareMarketplace(for host: SkillHost, action: Action) async -> CommandResult {
        guard let configuration else {
            return CommandResult(errorText: "No skills marketplace is set up.",
                                 status: 1)
        }
        actionProgress[action] = .checkingMarketplace
        let listed = await Self.run(host.command, host.marketplaceListArguments)
        guard listed.ok else { return listed }

        if !Self.marketplaceNames(from: listed.output).contains(configuration.marketplace) {
            actionProgress[action] = .addingMarketplace
            let added = await Self.run(host.command,
                                       host.marketplaceAddArguments(source: configuration.source))
            guard added.ok else { return added }
        }
        guard !configuration.isLocalFile || host == .claude else {
            return CommandResult(status: 0)
        }
        actionProgress[action] = .refreshingMarketplace
        return await Self.run(host.command,
                              host.marketplaceRefreshArguments(name: configuration.marketplace))
    }

    // MARK: - Commands

    struct CommandResult: Sendable {
        var output = ""
        var errorText = ""
        var status: Int32 = -1

        var ok: Bool { status == 0 }

        var failureMessage: String {
            let error = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            let standard = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = error.isEmpty ? standard : error
            return text.isEmpty ? "Command failed with exit code \(status)."
                : String(text.prefix(4_000))
        }
    }

    private nonisolated static func jsonObject(from output: String) -> Any? {
        let starts = [output.firstIndex(of: "{"), output.firstIndex(of: "[")].compactMap { $0 }
        guard let start = starts.min() else { return nil }
        let closing: Character = output[start] == "{" ? "}" : "]"
        guard let end = output.lastIndex(of: closing), start <= end,
              let data = String(output[start...end]).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private nonisolated static func run(_ command: String, _ arguments: [String]) async
        -> CommandResult {
        guard let path = ProcessManager.resolve(command) else {
            return CommandResult(errorText: "\(command) was not found on PATH.")
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ProcessManager.searchPath

        do {
            let output = try await CommandRunner.run(
                executable: path,
                arguments: arguments,
                environment: environment,
                timeout: .seconds(180)
            )
            return CommandResult(output: output.output,
                                 errorText: output.errorOutput,
                                 status: output.status)
        } catch {
            return CommandResult(errorText: error.localizedDescription)
        }
    }
}
