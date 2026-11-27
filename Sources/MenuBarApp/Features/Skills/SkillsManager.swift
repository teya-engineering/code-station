import CryptoKit
import Foundation
import Observation

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
    private let kiroShelf: KiroSkillShelf
    @ObservationIgnored private let preferences: UserDefaults

    private var configurationRevision = 0
    private let siteSkills: () -> SiteDefaults.Skills?
    private let persistExclusions: ([String]) throws -> Void

    // Exclusions also cover legacy and site-provided sources, which can return on relaunch.
    private var excludedMarketplaces: Set<String> {
        Set(preferences.stringArray(forKey: "skillsExcludedMarketplaces") ?? [])
    }

    var marketplaceConfigurations: [SkillMarketplaceConfiguration] {
        _ = configurationRevision
        var saved = Preferences.skillsMarketplaces(in: preferences).filter(\.isValid)
        if let selected = Preferences.skillsMarketplace(in: preferences), selected.isValid,
           !saved.contains(where: { $0.marketplace == selected.marketplace }) {
            saved.append(selected)
        }
        if let skills = siteSkills() {
            let site = SkillMarketplaceConfiguration.siteDefault(skills)
            if site.isValid, !saved.contains(where: { $0.marketplace == site.marketplace }) {
                saved.insert(site, at: 0)
            }
        }
        return saved.filter { !excludedMarketplaces.contains($0.marketplace) }
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
        if excludedMarketplaces.contains(configuration.marketplace) {
            try persistExclusions(Array(excludedMarketplaces.subtracting([configuration.marketplace])))
        }
        Preferences.setSkillsMarketplaces(saved, in: preferences)
        configurationRevision += 1
        actionFailures = [:]
    }

    struct Action: Hashable, Sendable {
        let host: SkillHost
        let plugin: String
    }

    init(cacheURL: URL? = nil, preferences: UserDefaults = .standard,
         kiroShelf: KiroSkillShelf = .standard,
         persistExclusions: (([String]) throws -> Void)? = nil,
         siteSkills: @escaping () -> SiteDefaults.Skills? = { SiteDefaults.current.skills }) {
        cacheURLOverride = cacheURL
        self.kiroShelf = kiroShelf
        self.preferences = preferences
        self.siteSkills = siteSkills
        self.persistExclusions = persistExclusions ?? { names in
            let key = "skillsExcludedMarketplaces"
            let previous = preferences.object(forKey: key)
            preferences.set(names, forKey: key)
            guard preferences.synchronize() else {
                preferences.set(previous, forKey: key)
                throw ImportError("The marketplace change could not be saved. Please try again.")
            }
        }
    }

    func removeMarketplace(_ configuration: SkillMarketplaceConfiguration) throws {
        guard !isBusy else { throw ImportError("Wait for the current marketplace operation to finish, then try again.") }
        try persistExclusions(Array(excludedMarketplaces.union([configuration.marketplace])))
        configurationRevision += 1
        plugins.removeAll { $0.marketplace == configuration.marketplace }
        actionFailures = actionFailures.filter { !$0.key.plugin.hasSuffix("@\(configuration.marketplace)") }
        if let notice = catalogueNotice {
            let remaining = notice.components(separatedBy: "\n")
                .filter { !$0.hasPrefix("\(configuration.label):") }.joined(separator: "\n")
            catalogueNotice = remaining.isEmpty ? nil : remaining
        }
    }

    func installedPackageCount(for marketplace: String) -> Int? {
        guard SkillHost.allCases.allSatisfy({ installations[$0] != nil && hostFailures[$0] == nil }) else {
            return nil
        }
        return Set(installations.values.flatMap { $0.keys }
            .filter { $0.hasSuffix("@\(marketplace)") }).count
    }

    func checkInstallationsForRemoval() async {
        guard !isBusy else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let names = Set(marketplaceConfigurations.map(\.marketplace))
        for (host, load) in await Self.loadInstallations(marketplaces: names, kiroShelf: kiroShelf) {
            apply(load, to: host)
        }
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

    func previewMarketplace(gitRepository source: String) async throws -> (SkillMarketplaceConfiguration, SkillMarketplace) {
        guard !isBusy else { throw ImportError("Wait for the current operation to finish.") }
        let source = source.trimmed
        guard !source.isEmpty else { throw ImportError("Enter a Git repository.") }
        guard !marketplaceConfigurations.contains(where: { $0.source == source }) else {
            throw ImportError("This marketplace is already connected. Find it in Marketplaces.")
        }
        isRefreshing = true
        defer { isRefreshing = false }
        let load = await Self.loadGitCatalogue(source: source, at: cacheURL(source: source), forceClone: true)
        if let signIn = load.signIn { throw signIn }
        guard let catalogue = load.marketplace, !catalogue.name.isBlank else {
            throw ImportError(load.notice ?? "The marketplace must contain a name and packages.")
        }
        return (.init(source: source, sourceKind: .gitRepository,
                      marketplace: catalogue.name, label: catalogue.name), catalogue)
    }

    func addPreviewedMarketplace(_ source: SkillMarketplaceConfiguration, catalogue: SkillMarketplace) async throws {
        guard !isBusy else { throw ImportError("Wait for the current operation to finish.") }
        guard !marketplaceConfigurations.contains(where: { $0.marketplace == source.marketplace || $0.source == source.source }) else {
            throw ImportError("This marketplace is already connected. Find it in Marketplaces.")
        }
        try saveMarketplace(source)
        isRefreshing = true
        await finishLoad(preloaded: [source.marketplace: .init(marketplace: catalogue, notice: nil, didRefresh: true)])
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
        async let hostLoads = Self.loadInstallations(marketplaces: names, kiroShelf: kiroShelf)
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
        if host.copiesSkills {
            actionProgress[action] = installed ? .installing : .uninstalling
            result = await shelve(plugin, installed: installed)
        } else if installed {
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

        let ready = host.copiesSkills ? CommandResult(status: 0)
            : await prepareMarketplace(for: host, plugin: plugin, action: action)
        let result: CommandResult
        if host.copiesSkills {
            actionProgress[action] = .updating
            result = await shelve(plugin, installed: true)
        } else if ready.ok {
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

    // Kiro's copies come from the app's own copy of the marketplace, which the catalogue
    // refresh keeps current, so the version installed is the one the list shows.
    private func shelve(_ plugin: SkillMarketplace.Plugin, installed: Bool) async -> CommandResult {
        let shelf = kiroShelf
        guard installed else {
            return Self.shelfResult { try shelf.remove(package: plugin.name, marketplace: plugin.marketplace) }
        }
        guard let configuration = marketplaceConfigurations.first(where: { $0.marketplace == plugin.marketplace }) else {
            return CommandResult(errorText: "No skills marketplace is set up.", status: 1)
        }
        let root = Self.marketplaceRoot(configuration, cache: cacheURL(source: configuration.source))
        return await Task.detached {
            Self.shelfResult {
                let folder = try KiroSkillShelf.packageFolder(source: plugin.source, marketplaceRoot: root)
                try shelf.install(package: plugin.name, marketplace: plugin.marketplace,
                                  version: plugin.version, from: folder)
            }
        }.value
    }

    // A package's source is relative to the marketplace's root: the repository for a
    // cloned one, and the folder holding `.claude-plugin/` for a local file.
    nonisolated static func marketplaceRoot(_ configuration: SkillMarketplaceConfiguration, cache: URL) -> URL {
        guard configuration.isLocalFile else { return cache }
        let folder = URL(fileURLWithPath: configuration.source).deletingLastPathComponent()
        return folder.lastPathComponent == ".claude-plugin" ? folder.deletingLastPathComponent() : folder
    }

    private nonisolated static func shelfResult(_ work: () throws -> Void) -> CommandResult {
        do {
            try work()
            return CommandResult(status: 0)
        } catch {
            return CommandResult(errorText: error.localizedDescription, status: 1)
        }
    }

    private func refreshInstallations(for host: SkillHost) async {
        apply(await Self.loadInstallations(for: host, marketplaces: Set(marketplaceConfigurations.map(\.marketplace)),
                                           kiroShelf: kiroShelf), to: host)
    }

    func apply(_ load: InstallationLoad, to host: SkillHost) {
        installations[host] = load.installations
        hostFailures[host] = load.failure
    }

    private func loadCachedState() async {
        guard !hasLoaded, !isBusy else { return }
        isRefreshing = true

        await finishLoad(cachedOnly: true)
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
}
