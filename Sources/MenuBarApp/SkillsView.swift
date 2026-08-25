import SwiftUI
import UniformTypeIdentifiers

private enum RepertoireFilter: CaseIterable, Identifiable {
    case all
    case installed
    case outdated

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .installed: "Installed"
        case .outdated: "Outdated"
        }
    }
}

struct SkillsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var manager: SkillsManager
    @State private var query = ""
    @State private var filter = RepertoireFilter.all
    @State private var repositorySource = ""
    @State private var setupFailure: String?
    @State private var configuringMarketplace = false

    init(manager: SkillsManager) {
        _manager = State(initialValue: manager)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            SheetFooter(done: { dismiss() }) {
                Text("Versions are compared with the marketplace manifest on every refresh.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 960, height: 660)
        .background(Theme.background)
        .task { await manager.refresh() }
        .sheet(isPresented: $configuringMarketplace) {
            marketplaceConfiguration.appOverlays()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Repertoire")
                    .font(.serif(18, .semibold))
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(marketplaceStatus(at: context.date))
                        .font(.mono(10.5))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            if manager.updateCount > 0 {
                Button {
                    Task { await manager.updateAll() }
                } label: {
                    Text(manager.isUpdatingAll
                         ? "Updating…"
                         : "Update all \(manager.updateCount)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.attentionText)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(Theme.secret.opacity(0.09)))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.secret.opacity(0.48)))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(manager.isUpdatingAll || manager.isRefreshing)
            }
            ActionButton(title: "Configure",
                         tone: .outlined,
                         height: 30,
                         size: 11.5,
                         icon: "gearshape") {
                let configuration = manager.marketplaceConfiguration
                repositorySource = configuration?.sourceKind == .gitRepository
                    ? configuration?.source ?? ""
                    : ""
                setupFailure = nil
                configuringMarketplace = true
            }
            .disabled(manager.isRefreshing || manager.isUpdatingAll)
            .appTooltip("Configure marketplace location")
            if manager.isConfigured {
                Button {
                    Task { await manager.refresh() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10.5, weight: .semibold))
                            .rotationEffect(manager.isRefreshing ? .degrees(360) : .zero)
                            .animation(manager.isRefreshing
                                       ? .linear(duration: 0.9)
                                           .repeatForever(autoreverses: false)
                                       : .default,
                                       value: manager.isRefreshing)
                        Text(manager.isRefreshing ? "Refreshing…" : "Refresh")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(manager.isRefreshing || manager.isUpdatingAll)
                .appTooltip("Refresh marketplace and installed versions")
            }
        }
        .padding(.horizontal, 20)
        .headerBand()
    }

    @ViewBuilder private var content: some View {
        if !manager.hasLoaded && manager.plugins.isEmpty {
            PaneMessage(icon: "shippingbox",
                        title: "Fetching repertoire",
                        detail: "Reading the marketplace and both agent installations.")
        } else if manager.plugins.isEmpty {
            marketplaceSetup
        } else {
            VStack(spacing: 0) {
                if let notice = manager.catalogueNotice {
                    noticeBanner(notice)
                }
                ForEach(SkillHost.allCases) { host in
                    if let failure = manager.hostFailure(host) {
                        noticeBanner("\(host.title) plugin status could not be read. \(failure)")
                    }
                }
                filterBar
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
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Image(systemName: manager.isConfigured
                      ? "exclamationmark.triangle"
                      : "shippingbox")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.secondary)
                Text(manager.isConfigured
                     ? "Repertoire could not be loaded"
                     : "Add a skills marketplace")
                    .font(.serif(17, .semibold))
                Text(setupFailure
                     ?? manager.catalogueNotice
                     ?? (manager.isConfigured
                         ? "The marketplace returned no packages."
                         : "Load a marketplace from a Git repository or a local manifest file."))
                    .font(.system(size: 13))
                    .foregroundStyle(setupFailure == nil ? Color.secondary : Theme.deletion)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 560)
            }

            marketplaceChoices

            Text("Repository sources must contain .claude-plugin/marketplace.json.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var marketplaceConfiguration: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Marketplace location").font(.serif(16))
                Text("Choose where Repertoire loads its skills marketplace.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .headerBand()

            VStack(alignment: .leading, spacing: 18) {
                currentMarketplaceLocation
                marketplaceChoices
                if let setupFailure {
                    Text(setupFailure)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.deletion)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Git repositories must contain .claude-plugin/marketplace.json. Local sources must be marketplace JSON files.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            SheetFooter { configuringMarketplace = false }
        }
        .frame(width: 720)
        .background(Theme.background)
    }

    private var currentMarketplaceLocation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Caption(text: "CURRENT LOCATION")
            if let configuration = manager.marketplaceConfiguration {
                HStack(spacing: 8) {
                    Image(systemName: configuration.isLocalFile
                          ? "doc.text" : "arrow.triangle.branch")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text(configuration.source)
                        .font(.mono(11.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            } else {
                Text("No marketplace is configured.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
    }

    private var marketplaceChoices: some View {
        HStack(alignment: .top, spacing: 12) {
            setupCard(icon: "arrow.triangle.branch",
                      title: "Git repository",
                      detail: "Clone a repository and refresh it with Git.") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("https://github.com/org/marketplace.git",
                              text: $repositorySource)
                        .textFieldStyle(.plain)
                        .font(.mono(11.5))
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                        .onSubmit(loadRepository)
                    ActionButton(title: manager.isRefreshing ? "Loading…" : "Load repository",
                                 tone: .outlined,
                                 icon: manager.isRefreshing ? nil : "arrow.down.circle",
                                 action: loadRepository)
                        .disabled(manager.isRefreshing || trimmedRepository.isEmpty)
                        .opacity(manager.isRefreshing ? 0.6 : 1)
                }
            }

            setupCard(icon: "doc.badge.plus",
                      title: "Local file",
                      detail: "Read a marketplace JSON file already on this Mac.") {
                ActionButton(title: "Choose marketplace file",
                             tone: .outlined,
                             icon: "folder",
                             action: chooseMarketplaceFile)
                    .disabled(manager.isRefreshing)
                    .opacity(manager.isRefreshing ? 0.6 : 1)
            }
        }
        .frame(maxWidth: 680)
    }

    private func setupCard<Content: View>(
        icon: String,
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Theme.accent.opacity(0.09)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.serif(15))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 2)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.border))
    }

    private var trimmedRepository: String {
        repositorySource.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadRepository() {
        let repository = trimmedRepository
        guard !manager.isRefreshing, !repository.isEmpty else { return }
        setupFailure = nil
        Task {
            do {
                try await manager.configure(gitRepository: repository)
                configuringMarketplace = false
            } catch {
                setupFailure = error.localizedDescription
            }
        }
    }

    private func chooseMarketplaceFile() {
        guard !manager.isRefreshing else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "Load"
        panel.message = "Choose a marketplace JSON file."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        setupFailure = nil
        Task {
            do {
                try await manager.configure(localFile: url)
                configuringMarketplace = false
            } catch {
                setupFailure = error.localizedDescription
            }
        }
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
                    .appTooltip("Clear filter")
                }
            }
            .padding(.horizontal, 10)
            .frame(width: 270, height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))

            HStack(spacing: 6) {
                ForEach(RepertoireFilter.allCases) { option in
                    ChoicePill(title: filterTitle(option),
                               selected: filter == option) {
                        filter = option
                    }
                }
            }

            Spacer(minLength: 12)
            Text("User-scoped installs")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
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
                        Text(plugin.name)
                            .font(.system(size: 13.5, weight: .semibold))
                            .textSelection(.enabled)
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
                    Text(plugin.description)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
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
        .padding(.vertical, 9)
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

        return HStack(spacing: 7) {
            Toggle(isOn: Binding(
                get: { installation != nil },
                set: { selected in
                    Task { await manager.setInstalled(selected, plugin: plugin, on: host) }
                })) {
                    hostStatus(installation, latestVersion: plugin.version,
                               outdated: outdated, progress: progress)
                }
                .toggleStyle(.appCheckbox)
                .disabled(!manageable || working || manager.isUpdatingAll)
                .frame(maxWidth: .infinity, alignment: .leading)

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
                .disabled(!manageable || manager.isUpdatingAll)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(installation == nil ? Color.clear : Theme.field))
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

    private var emptyResults: some View {
        VStack(spacing: 7) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.secondary)
            Text("No matching packages")
                .font(.serif(15, .semibold))
            Text("Try another search or filter.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }

    private var filteredPlugins: [SkillMarketplace.Plugin] {
        manager.plugins.filter { plugin in
            let matchesFilter = switch filter {
            case .all: true
            case .installed:
                SkillHost.allCases.contains { manager.installation(of: plugin, on: $0) != nil }
            case .outdated:
                SkillHost.allCases.contains { manager.isOutdated(plugin, on: $0) }
            }
            guard matchesFilter else { return false }
            let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { return true }
            return plugin.name.localizedCaseInsensitiveContains(term)
                || plugin.description.localizedCaseInsensitiveContains(term)
                || plugin.category?.localizedCaseInsensitiveContains(term) == true
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

    private func noticeBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(Theme.warningText)
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(Theme.warningBackground)
    }
}
