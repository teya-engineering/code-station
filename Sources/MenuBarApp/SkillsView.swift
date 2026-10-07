import SwiftUI

enum RepertoireFilter: CaseIterable, Identifiable {
    case all
    case installed
    case outdated

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .installed: "Installed"
        case .outdated: "Updates"
        }
    }
    func matches(_ plugin: SkillMarketplace.Plugin, query: String, source: String?, installed: Bool, outdated: Bool) -> Bool {
        guard source == nil || plugin.marketplace == source else { return false }
        guard self != .installed || installed, self != .outdated || outdated else { return false }
        let term = query.trimmed
        return term.isEmpty || [plugin.name, plugin.description, plugin.marketplace, plugin.category ?? ""]
            .contains { $0.localizedCaseInsensitiveContains(term) }
    }

}

struct SkillsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DialogPresenter.self) private var dialogs
    @State private var manager: SkillsManager
    @State private var query = ""
    @State private var filter = RepertoireFilter.all
    @State private var showingMarketplaces = false
    @State private var sourceFilter: String?
    @State private var hoveredControl: String?
    @FocusState private var focusedUninstall: String?
    @FocusState private var focusedDescription: String?

    init(manager: SkillsManager) {
        _manager = State(initialValue: manager)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 12) {
                ChoicePill(title: "Skills \(manager.plugins.count)", selected: !showingMarketplaces) { showingMarketplaces = false }
                ChoicePill(title: "Marketplaces \(manager.marketplaceConfigurations.count)", selected: showingMarketplaces) { showingMarketplaces = true }
                Spacer()
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(marketplaceStatus(at: context.date)).font(.mono(10.5)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            Divider().overlay(Theme.border)
            if showingMarketplaces {
                MarketplaceManagementView(manager: manager, add: addMarketplace) { source in
                    sourceFilter = source.marketplace
                    query = ""
                    filter = .all
                    showingMarketplaces = false
                }
            } else {
                content
            }
            SheetFooter(dismiss: { dismiss() }) {
                Text("Installs apply to your user account across projects. Agents are managed separately.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: min(1080, (NSScreen.main?.visibleFrame.width ?? 1200) - 80),
               height: min(720, (NSScreen.main?.visibleFrame.height ?? 860) - 80))
        .background(Theme.background)
        .task { await manager.refresh() }
        .onChange(of: manager.marketplaceConfigurations) { _, sources in
            if let sourceFilter, !sources.contains(where: { $0.marketplace == sourceFilter }) {
                self.sourceFilter = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Repertoire")
                    .scaledSerif(28)
                Text("Find skills for your agents. Keep them up to date.")
                    .scaledText(13).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if showingMarketplaces {
                ActionButton(title: "Add marketplace", tone: .dark, icon: "plus", action: addMarketplace)
                    .disabled(manager.isBusy)
            }
            if manager.isConfigured {
                ActionButton(title: manager.isRefreshing ? "Refreshing…" : "Refresh",
                             tone: .sunken,
                             height: 30,
                             size: 11.5,
                             icon: "arrow.clockwise") {
                    Task { await manager.refresh() }
                }
                .disabled(manager.isBusy)
                .appTooltip("Refresh all marketplaces and installed versions")
            }
        }
        .padding(.horizontal, 20)
        .headerBand(Theme.background, height: 100)
    }

    @ViewBuilder private var content: some View {
        if (!manager.hasLoaded || manager.isRefreshing) && manager.plugins.isEmpty {
            PaneMessage(icon: "shippingbox",
                        title: "Fetching repertoire",
                        detail: "Reading the marketplace and each agent's installations.")
        } else if manager.plugins.isEmpty {
            marketplaceSetup
        } else {
            VStack(spacing: 0) {
                if let notice = manager.catalogueNotice {
                    WarningStrip(notice)
                }
                ForEach(SkillHost.allCases) { host in
                    if let failure = manager.hostFailure(host) {
                        WarningStrip("\(host.title) plugin status could not be read. \(failure)")
                    }
                }
                filterBar
                if manager.updateCount > 0 {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(outdatedPluginCount) packages have updates").font(.system(size: 13, weight: .semibold))
                            Text("Update installed copies across your agents.").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        ActionButton(title: manager.isUpdatingAll ? "Updating…" : "Update all", tone: .outlined) {
                            Task { await manager.updateAll() }
                        }.disabled(manager.isBusy)
                    }
                    .padding(14)
                    .surface(Theme.secret.opacity(0.09), cornerRadius: 10, border: Theme.secret.opacity(0.4))
                    .padding(.horizontal, 20).padding(.bottom, 16)
                }
                columnHeadings
                ScrollView {
                    if filteredPlugins.isEmpty {
                        emptyResults
                    } else {
                        LazyVStack(spacing: 6) {
                            ForEach(filteredPlugins) { plugin in
                                skillRow(plugin)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                    }
                }
            }
        }
    }

    private var marketplaceSetup: some View {
        PaneMessage(icon: "shippingbox", title: manager.isConfigured ? "No packages available" : "Your repertoire starts here",
                    detail: manager.catalogueNotice ?? "Add a marketplace to browse and install skill packages.") {
            ActionButton(title: "Add marketplace", tone: .dark, action: addMarketplace)
        }
    }

    private func addMarketplace() {
        dialogs.show(Dialog(title: "Add marketplace",
                            message: "Connect a source, then choose which packages to install.",
                            content: AnyView(AddMarketplaceView(manager: manager)),
                            actions: [.init(label: "Cancel", kind: .cancel)], width: 620, isModal: true))
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Filter packages", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverLift(amount: Motion.smallLift)
                    .appTooltip("Clear filter")
                }
            }
            .padding(.horizontal, 10)
            .frame(width: 270, height: 32)
            .fieldSurface()

            HStack(spacing: 6) {
                ForEach(RepertoireFilter.allCases) { option in
                    ChoicePill(title: filterTitle(option),
                               selected: filter == option) {
                        filter = option
                    }
                }
            }

            Spacer(minLength: 12)
            OptionMenu(value: manager.marketplaceConfigurations.first { $0.marketplace == sourceFilter }?.label ?? "All marketplaces") {
                [.item("All marketplaces", checked: sourceFilter == nil) { sourceFilter = nil }]
                + manager.marketplaceConfigurations.map { source in
                    .item(source.label, checked: sourceFilter == source.marketplace) { sourceFilter = source.marketplace }
                }
            }
            .frame(maxWidth: 230)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
    }

    private var columnHeadings: some View {
        HStack(spacing: 12) {
            Text("PACKAGE")
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(SkillHost.allCases) { host in
                HStack(spacing: 5) {
                    Circle()
                        .fill(hostColour(host))
                        .frame(width: 6, height: 6)
                    Text(hostHeading(host))
                }
                .frame(width: 190, alignment: .leading)
            }
        }
        .font(.mono(9.5, .semibold))
        .kerning(0.55)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func skillRow(_ plugin: SkillMarketplace.Plugin) -> some View {
        let outdated = SkillHost.allCases.contains { manager.isOutdated(plugin, on: $0) }
        let failures = SkillHost.allCases.compactMap { host in
            manager.actionFailure(plugin, on: host).map { "\(host.title): \($0)" }
        }

        return VStack(alignment: .leading, spacing: failures.isEmpty ? 0 : 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Button { showDetails(plugin) } label: {
                            Text(plugin.name).scaledText(13.5, .semibold)
                                .foregroundStyle(Theme.accent).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Details for \(plugin.name)")
                        .accessibilityValue(plugin.description)
                        .focused($focusedDescription, equals: plugin.id + "-name")
                        .appTooltip(plugin.description,
                                    isFocused: focusedDescription == plugin.id + "-name",
                                    persistsOnHover: true)
                        SkillDescriptionButton(plugin: plugin)
                        if let version = plugin.version {
                            Text(version)
                                .font(.mono(10))
                                .foregroundStyle(.secondary)
                        }
                        if let category = plugin.category {
                            Text(category.uppercased())
                                .font(.mono(8, .semibold))
                                .kerning(0.45)
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    Text(plugin.marketplace)
                        .font(.mono(9.5))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(SkillHost.allCases) { host in
                    hostControl(plugin, host: host)
                        .frame(width: 190)
                }
            }

            if !failures.isEmpty {
                Text(failures.joined(separator: "\n"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.deletion)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .stroke(outdated ? Theme.secret.opacity(0.52) : Theme.border,
                    lineWidth: outdated ? 1.2 : 1))
    }

    private func hostControl(_ plugin: SkillMarketplace.Plugin,
                             host: SkillHost) -> some View {
        let installation = manager.installation(of: plugin, on: host)
        let outdated = manager.isOutdated(plugin, on: host)
        let progress = manager.progress(of: plugin, on: host)
        let working = progress != nil
        let manageable = manager.canManage(host)
        let controlID = "\(plugin.id)-\(host.id)"

        return HStack(spacing: 7) {
            hostStatus(installation, latestVersion: plugin.version,
                       outdated: outdated, progress: progress)
                .frame(maxWidth: .infinity, alignment: .leading)
            if installation == nil, !working {
                ActionButton(title: "Install", tone: .outlined, height: 26, size: 10.5) {
                    Task { await manager.setInstalled(true, plugin: plugin, on: host) }
                }
                .disabled(!manageable || manager.isUpdatingAll || manager.isRefreshing)
                .accessibilityLabel("Install \(plugin.name) in \(host.title)")
            }
            if installation != nil, !working, !outdated {
                Button { confirmUninstall(plugin, host: host) } label: {
                    Image(systemName: "minus.circle").foregroundStyle(Theme.deletion)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!manageable || manager.isUpdatingAll || manager.isRefreshing)
                .accessibilityLabel("Uninstall \(plugin.name) from \(host.title)")
                .appTooltip("Uninstall from \(host.title)")
                .focused($focusedUninstall, equals: controlID)
                .opacity(hoveredControl == controlID || focusedUninstall == controlID ? 1 : 0)
            }

            if outdated, progress == nil, let latest = plugin.version {
                Button {
                    Task { await manager.update(plugin, on: host) }
                } label: {
                    Text("Update")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .frame(height: 25)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.secret))
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                        .appTooltip("Update to \(latest)")
                }
                .buttonStyle(.plain)
                .hoverLift()
                .disabled(!manageable || manager.isUpdatingAll || manager.isRefreshing)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(installation == nil ? Color.clear : Theme.field))
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                hoveredControl = controlID
            } else if hoveredControl == controlID {
                hoveredControl = nil
            }
        }
        .opacity(!manageable && installation == nil ? 0.58 : 1)
    }

    @ViewBuilder private func hostStatus(_ installation: SkillInstallation?,
                                         latestVersion: String?,
                                         outdated: Bool,
                                         progress: SkillActionProgress?) -> some View {
        if let progress {
            Text(progress.rawValue)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
        } else if let installation {
            HStack(spacing: 6) {
                if outdated, let latestVersion {
                    Text(versionText(installation.version))
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.attentionText)
                    Text(versionText(latestVersion))
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.attentionText)
                } else {
                    Text(installation.enabled ? "Installed" : "Disabled")
                    Spacer(minLength: 4)
                    if installation.version != "unknown" {
                        Text(installation.version)
                            .font(.mono(9.5))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.system(size: 10.5, weight: .medium))
            .lineLimit(1)
        } else {
            Text("Not installed")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func showDetails(_ plugin: SkillMarketplace.Plugin) {
        dialogs.show(Dialog(title: plugin.name, message: "\(plugin.marketplace) · Skill package",
            content: AnyView(SkillPackageDetails(manager: manager, plugin: plugin)),
            actions: [.init(label: "Done", kind: .cancel)], width: 620, isModal: true))
    }

    private func confirmUninstall(_ plugin: SkillMarketplace.Plugin, host: SkillHost) {
        dialogs.show(uninstallDialog(manager: manager, plugin: plugin, host: host))
    }

    private var emptyResults: some View {
        VStack(spacing: 7) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.secondary)
            Text("No matching packages")
                .font(.serif(15, .semibold))
            ActionButton(title: "Clear filters", tone: .outlined) {
                query = ""
                filter = .all
                sourceFilter = nil
            }
            Text("Try another search or filter.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }

    private var filteredPlugins: [SkillMarketplace.Plugin] {
        manager.plugins.filter { plugin in
            filter.matches(plugin, query: query, source: sourceFilter,
                           installed: SkillHost.allCases.contains { manager.installation(of: plugin, on: $0) != nil },
                           outdated: SkillHost.allCases.contains { manager.isOutdated(plugin, on: $0) })
        }
    }

    private var outdatedPluginCount: Int {
        manager.plugins.count { plugin in
            SkillHost.allCases.contains { manager.isOutdated(plugin, on: $0) }
        }
    }

    private func filterTitle(_ option: RepertoireFilter) -> String {
        let count = switch option {
        case .all: manager.plugins.count
        case .installed: manager.installedPluginCount
        case .outdated: outdatedPluginCount
        }
        return "\(option.title) \(count)"
    }

    private func hostHeading(_ host: SkillHost) -> String {
        if !manager.isAvailable(host) {
            return "\(host.title.uppercased()) · NOT FOUND"
        }
        if manager.hostFailure(host) != nil {
            return "\(host.title.uppercased()) · ERROR"
        }
        return host.title.uppercased()
    }

    private func hostColour(_ host: SkillHost) -> Color {
        if manager.hostFailure(host) != nil { return Theme.deletion }
        return manager.isAvailable(host) ? Theme.dotOn : Theme.dotOff
    }

    private func marketplaceStatus(at date: Date) -> String {
        guard let lastRefresh = manager.lastRefresh else {
            return "\(manager.marketplaceLabel) · not yet refreshed"
        }
        let age = RelativeTime.short(lastRefresh)
        let freshness = age == "now" ? "refreshed now" : "refreshed \(age) ago"
        return "\(manager.marketplaceLabel) · \(freshness)"
    }

    private func versionText(_ version: String) -> String {
        version == "unknown" ? "Installed" : version
    }
}

private struct SkillDescriptionButton: View {
    let plugin: SkillMarketplace.Plugin
    @FocusState private var isFocused: Bool
    @State private var activation = 0

    var body: some View {
        Button { activation += 1 } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Description for \(plugin.name)")
        .accessibilityValue(plugin.description)
        .focused($isFocused)
        .appTooltip(plugin.description, isFocused: isFocused,
                    persistsOnHover: true, activation: activation)
    }
}
