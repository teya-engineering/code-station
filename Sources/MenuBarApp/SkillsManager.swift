import CryptoKit
import Foundation
import Observation

struct SkillMarketplace: Decodable, Equatable, Sendable {
    struct Plugin: Decodable, Equatable, Identifiable, Sendable {
        let name: String
        let description: String
        let version: String?
        let category: String?

        var marketplace = ""

        enum CodingKeys: String, CodingKey {
            case name, description, version, category
        }

        var id: String { marketplace.isEmpty ? name : "\(name)@\(marketplace)" }
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
    var isValid: Bool { !source.isBlank && !marketplace.isBlank }

    static func siteDefault(_ skills: SiteDefaults.Skills) -> Self {
        Self(source: skills.repository,
             sourceKind: skills.sourceKind ?? .gitRepository,
             marketplace: skills.marketplace,
             label: skills.name)
    }
}

// The CLIs that install plugins from the marketplace. All three read the same
// marketplace format, so one catalogue serves every host; only the commands differ.
enum SkillHost: String, CaseIterable, Identifiable, Sendable {
    case claude
    case codex
    case copilot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .copilot: "Copilot"
        }
    }

    var command: String { rawValue }

    // Copilot's `plugin list` has no JSON form; its `plugins` command lists everything it
    // has configured, plugins included, and does.
    var listArguments: [String] {
        switch self {
        case .claude, .codex: ["plugin", "list", "--json"]
        case .copilot: ["plugins", "list", "--json"]
        }
    }

    var marketplaceListArguments: [String] {
        switch self {
        case .claude, .codex: ["plugin", "marketplace", "list", "--json"]
        case .copilot: ["plugin", "marketplace", "list"]
        }
    }

    func marketplaceAddArguments(source: String) -> [String] {
        return switch self {
        case .claude, .copilot: ["plugin", "marketplace", "add", source]
        case .codex: ["plugin", "marketplace", "add", source, "--json"]
        }
    }

    func marketplaceRefreshArguments(name: String) -> [String] {
        return switch self {
        case .claude, .copilot: ["plugin", "marketplace", "update", name]
        case .codex: ["plugin", "marketplace", "upgrade", name, "--json"]
        }
    }

    func installArguments(plugin: String, marketplace: String) -> [String] {
        let selector = "\(plugin)@\(marketplace)"
        return switch self {
        case .claude: ["plugin", "install", selector, "--scope", "user"]
        case .codex: ["plugin", "add", selector, "--json"]
        case .copilot: ["plugin", "install", selector]
        }
    }

    func removeArguments(plugin: String, marketplace: String) -> [String] {
        let selector = "\(plugin)@\(marketplace)"
        return switch self {
        case .claude: ["plugin", "uninstall", selector, "--scope", "user"]
        case .codex: ["plugin", "remove", selector, "--json"]
        case .copilot: ["plugin", "uninstall", selector]
        }
    }

    func updateArguments(plugin: String, marketplace: String) -> [String] {
        let selector = "\(plugin)@\(marketplace)"
        return switch self {
        case .claude: ["plugin", "update", selector, "--scope", "user"]
        // Adding an installed Codex plugin reconciles its cached version with the
        // refreshed marketplace snapshot.
        case .codex: ["plugin", "add", selector, "--json"]
        case .copilot: ["plugin", "update", selector]
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

    private var configurationRevision = 0

    var marketplaceConfigurations: [SkillMarketplaceConfiguration] {
        _ = configurationRevision
        var saved = Preferences.skillsMarketplaces(in: preferences).filter(\.isValid)
        if let selected = Preferences.skillsMarketplace(in: preferences), selected.isValid,
           !saved.contains(where: { $0.marketplace == selected.marketplace }) {
            saved.append(selected)
        }
        if let skills = SiteDefaults.current.skills {
            let site = SkillMarketplaceConfiguration.siteDefault(skills)
            if site.isValid, !saved.contains(where: { $0.marketplace == site.marketplace }) {
                saved.insert(site, at: 0)
            }
        }
        return saved
    }

    var isBusy: Bool { isRefreshing || isUpdatingAll || !actionProgress.isEmpty }

    var marketplaceLabel: String {
        let configurations = marketplaceConfigurations
        return configurations.count == 1 ? configurations[0].label : "\(configurations.count) marketplaces"
    }

    var isConfigured: Bool { !marketplaceConfigurations.isEmpty }

    func cacheURL(source: String) -> URL {
        let key = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        return (cacheURLOverride ?? AppPaths.directory("marketplaces", backedUp: false))
            .appendingPathComponent(key, isDirectory: true)
    }

    func saveMarketplace(_ configuration: SkillMarketplaceConfiguration) throws {
        guard configuration.isValid else { throw ImportError("The marketplace must have a name and source.") }
        var saved = marketplaceConfigurations
        if let existing = saved.first(where: { $0.marketplace == configuration.marketplace }),
           existing.source != configuration.source || existing.sourceKind != configuration.sourceKind {
            throw ImportError("A marketplace named \(configuration.marketplace) is already added from another source.")
        }
        if !saved.contains(where: { $0.marketplace == configuration.marketplace }) {
            saved.append(configuration)
        }
        Preferences.setSkillsMarketplaces(saved, in: preferences)
        configurationRevision += 1
        actionFailures = [:]
    }

    struct Action: Hashable, Sendable {
        let host: SkillHost
        let plugin: String
    }

    init(cacheURL: URL? = nil, preferences: UserDefaults = .standard) {
        cacheURLOverride = cacheURL
        self.preferences = preferences
    }

    func applyCatalogues(_ loads: [String: CatalogueLoad],
                         configurations: [SkillMarketplaceConfiguration]) {
        var combined: [SkillMarketplace.Plugin] = []
        var notices: [String] = []
        for configuration in configurations {
            guard let load = loads[configuration.marketplace] else { continue }
            if let notice = load.notice { notices.append("\(configuration.label): \(notice)") }
            guard let catalogue = load.marketplace else { continue }
            guard catalogue.name == configuration.marketplace else {
                notices.append("\(configuration.label): The manifest names a different marketplace (\(catalogue.name)).")
                continue
            }
            combined += catalogue.plugins.map { plugin in
                var plugin = plugin
                plugin.marketplace = configuration.marketplace
                return plugin
            }
            if load.didRefresh {
                preferences.set(Date(), forKey: "skillsLastRefresh.\(configuration.marketplace)")
            }
        }
        plugins = combined.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.marketplace < $1.marketplace : order == .orderedAscending
        }
        catalogueNotice = notices.isEmpty ? nil : notices.joined(separator: "\n")
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

    var lastRefresh: Date? {
        let configurations = marketplaceConfigurations
        let dates = configurations.compactMap {
            preferences.object(forKey: "skillsLastRefresh.\($0.marketplace)") as? Date
        }
        return dates.count == configurations.count ? dates.min() : nil
    }

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
        installations[host]?[plugin.id]
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
        actionProgress[Action(host: host, plugin: plugin.id)]
    }

    func actionFailure(_ plugin: SkillMarketplace.Plugin, on host: SkillHost) -> String? {
        actionFailures[Action(host: host, plugin: plugin.id)]
    }

    func configure(localFile url: URL) async throws {
        guard !isBusy else { return }
        let (configuration, catalogue) = try Self.localConfiguration(at: url)

        try saveMarketplace(configuration)
        isRefreshing = true
        catalogueNotice = nil
        hostFailures = [:]
        await finishLoad(preloaded: [configuration.marketplace:
            CatalogueLoad(marketplace: catalogue, notice: nil, didRefresh: true)])
    }

    func configure(gitRepository source: String) async throws {
        guard !isBusy else { return }
        let source = source.trimmed
        guard !source.isEmpty else { throw ImportError("Enter a Git repository.") }

        isRefreshing = true
        catalogueNotice = nil
        hostFailures = [:]
        defer { isRefreshing = false }

        // The repository is read before anything is saved: its manifest names the
        // marketplace, and that name is what the installation lookups are keyed by.
        let load = await Self.loadGitCatalogue(source: source, at: cacheURL(source: source),
                                               forceClone: true)
        guard let catalogue = load.marketplace else {
            throw ImportError(load.notice ?? "The marketplace could not be loaded.")
        }
        let configuration = SkillMarketplaceConfiguration(
            source: source,
            sourceKind: .gitRepository,
            marketplace: catalogue.name,
            label: catalogue.name)
        try saveMarketplace(configuration)
        await finishLoad(preloaded: [configuration.marketplace: load])
    }

    func refresh() async {
        guard !isBusy else { return }
        isRefreshing = true
        catalogueNotice = nil
        hostFailures = [:]

        await finishLoad()
    }

    private func finishLoad(cachedOnly: Bool = false,
                            preloaded: [String: CatalogueLoad] = [:]) async {
        let configurations = marketplaceConfigurations
        let names = Set(configurations.map(\.marketplace))
        async let hostLoads = Self.loadInstallations(marketplaces: names)
        let loads = await withTaskGroup(of: (String, CatalogueLoad).self) { group in
            for configuration in configurations {
                let cache = cacheURL(source: configuration.source)
                group.addTask {
                    let load: CatalogueLoad
                    if let existing = preloaded[configuration.marketplace] {
                        load = existing
                    } else if cachedOnly {
                        load = Self.loadCachedCatalogue(configuration: configuration, at: cache)
                    } else {
                        load = await Self.loadCatalogue(configuration: configuration, at: cache)
                    }
                    return (configuration.marketplace, load)
                }
            }
            var result: [String: CatalogueLoad] = [:]
            for await (name, load) in group { result[name] = load }
            return result
        }
        applyCatalogues(loads, configurations: configurations)
        for (host, load) in await hostLoads { apply(load, to: host) }
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
        let action = Action(host: host, plugin: plugin.id)
        guard !isRefreshing, actionProgress[action] == nil, canManage(host) else { return }
        actionProgress[action] = installed ? .checkingMarketplace : .uninstalling
        actionFailures[action] = nil
        defer { actionProgress[action] = nil }

        let result: CommandResult
        if installed {
            let ready = await prepareMarketplace(for: host, plugin: plugin, action: action)
            if ready.ok {
                actionProgress[action] = .installing
                result = await Self.run(host.command,
                                        host.installArguments(plugin: plugin.name,
                                                              marketplace: plugin.marketplace))
            } else {
                result = ready
            }
        } else {
            result = await Self.run(host.command,
                                    host.removeArguments(plugin: plugin.name,
                                                         marketplace: plugin.marketplace))
        }

        if result.ok {
            actionProgress[action] = .checkingInstallation
            await refreshInstallations(for: host)
        } else {
            actionFailures[action] = result.failureMessage
        }
    }

    func update(_ plugin: SkillMarketplace.Plugin, on host: SkillHost) async {
        let action = Action(host: host, plugin: plugin.id)
        guard !isRefreshing, actionProgress[action] == nil, canManage(host) else { return }
        actionProgress[action] = .checkingMarketplace
        actionFailures[action] = nil
        defer { actionProgress[action] = nil }

        let ready = await prepareMarketplace(for: host, plugin: plugin, action: action)
        let result: CommandResult
        if ready.ok {
            actionProgress[action] = .updating
            result = await Self.run(host.command,
                                    host.updateArguments(plugin: plugin.name,
                                                         marketplace: plugin.marketplace))
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
        apply(await Self.loadInstallations(for: host, marketplaces: Set(marketplaceConfigurations.map(\.marketplace))), to: host)
    }

    func apply(_ load: InstallationLoad, to host: SkillHost) {
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
        guard !marketplace.name.isBlank else {
            throw ImportError("The marketplace file must contain a name.")
        }
        return (SkillMarketplaceConfiguration(source: url.path,
                                               sourceKind: .localFile,
                                               marketplace: marketplace.name,
                                               label: marketplace.name),
                marketplace)
    }

    private func loadCachedState() async {
        guard !hasLoaded, !isBusy else { return }
        isRefreshing = true

        await finishLoad(cachedOnly: true)
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
        let installations = installedPlugins(from: output, for: host, marketplaces: [marketplace])
        let suffix = "@\(marketplace)"
        return Dictionary(uniqueKeysWithValues: installations.map {
            (String($0.key.dropLast(suffix.count)), $0.value)
        })
    }

    nonisolated static func installedPlugins(from output: String, for host: SkillHost,
                                             marketplaces: Set<String>) -> [String: SkillInstallation] {
        guard let root = jsonObject(from: output) else { return [:] }
        let rows: [[String: Any]]
        if let array = root as? [[String: Any]] {
            rows = array
        } else if let object = root as? [String: Any],
                  let installed = object["installed"] as? [[String: Any]] {
            rows = installed
        } else if let object = root as? [String: Any],
                  let configured = object["plugins"] as? [[String: Any]] {
            rows = configured
        } else {
            return [:]
        }

        var result: [String: SkillInstallation] = [:]
        for row in rows {
            // Copilot lists every kind of thing it has configured in one array; only the
            // plugins are the marketplace's, and each names its marketplace as a source.
            if host == .copilot, row["kind"] as? String != "plugin" { continue }
            let identifier = row["pluginId"] as? String ?? row["id"] as? String ?? ""
            let pieces = identifier.split(separator: "@", maxSplits: 1).map(String.init)
            let name = row["name"] as? String ?? pieces.first ?? ""
            let marketplaceName = row["marketplaceName"] as? String
                ?? (row["source"] as? String).flatMap { source in
                    source.hasPrefix("marketplace:") ? String(source.dropFirst("marketplace:".count)) : nil
                }
                ?? (pieces.count == 2 ? pieces[1] : "")
            guard !name.isEmpty, marketplaces.contains(marketplaceName) else { continue }
            if host == .claude, let scope = row["scope"] as? String, scope != "user" { continue }
            if let installed = row["installed"] as? Bool, !installed { continue }

            result["\(name)@\(marketplaceName)"] = SkillInstallation(
                version: row["version"] as? String ?? "unknown",
                enabled: row["enabled"] as? Bool ?? true)
        }
        return result
    }

    // Copilot prints its marketplaces as a bulleted list rather than as JSON, one per
    // line with the name before the source in brackets.
    nonisolated static func marketplaceNames(from output: String) -> Set<String> {
        guard let root = jsonObject(from: output) else {
            let names = output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let first = trimmed.first, "•◆*-".contains(first) else { return nil }
                let rest = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                guard let open = rest.firstIndex(of: "(") else { return nil }
                let name = rest[..<open].trimmingCharacters(in: .whitespaces)
                return name.isEmpty ? nil : name
            }
            return Set(names)
        }
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

    private nonisolated static func loadInstallations(marketplaces: Set<String>) async
        -> [SkillHost: InstallationLoad] {
        await withTaskGroup(of: (SkillHost, InstallationLoad).self) { group in
            for host in SkillHost.allCases {
                group.addTask { (host, await loadInstallations(for: host, marketplaces: marketplaces)) }
            }
            var loads: [SkillHost: InstallationLoad] = [:]
            for await (host, load) in group { loads[host] = load }
            return loads
        }
    }

    private nonisolated static func loadInstallations(for host: SkillHost,
                                                      marketplaces: Set<String>) async
        -> InstallationLoad {
        guard !marketplaces.isEmpty, ProcessManager.resolve(host.command) != nil else {
            return InstallationLoad(installations: [:], failure: nil)
        }
        let result = await run(host.command, host.listArguments)
        guard result.ok else {
            return InstallationLoad(installations: [:], failure: result.failureMessage)
        }
        return InstallationLoad(installations: installedPlugins(from: result.output,
                                                                for: host,
                                                                marketplaces: marketplaces),
                                failure: nil)
    }

    private func prepareMarketplace(for host: SkillHost, plugin: SkillMarketplace.Plugin,
                                    action: Action) async -> CommandResult {
        guard let configuration = marketplaceConfigurations.first(where: { $0.marketplace == plugin.marketplace }) else {
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
            let text = errorText.isBlank ? output.trimmed : errorText.trimmed
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
