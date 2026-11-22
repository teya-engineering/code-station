import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SiteConfigurationSection: View {
    @Environment(DispatchStore.self) private var dispatch
    @Environment(DispatchAuthStore.self) private var dispatchAuth
    @Environment(ShortcutStore.self) private var shortcuts
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(\.settingsNote) private var settingsNote

    let skills: SkillsManager

    @State private var loaded = SiteDefaults.current
    @State private var loader = SiteConfigurationLoader()
    @State private var chosen: Set<SiteConfigurationAspect> = []
    @State private var editor: SiteConfigurationAspect?
    @State private var showingDispatch = false
    @State private var showingEnvironmentAccess = false
    @State private var showingSkills = false
    @State private var showingShortcuts = false
    @State private var showingJSON = false
    @State private var backup: AppBackup?
    @State private var backupChosen: Set<AppBackup.Part> = []
    @State private var backupFailure: String?
    @State private var exportFailure: String?
    @State private var pendingBackup: AppBackup?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            configuration.id(SettingsSearchTarget.advancedConfiguration.id)
            importing.id(SettingsSearchTarget.advancedImport.id)
        }
        .sheet(item: $editor) { aspect in
            Group {
                if aspect == .mcp {
                    MCPPresetsEditorView(defaults: loaded) { defaults in
                        apply(defaults, changed: [aspect])
                    }
                } else {
                    SiteConfigurationEditorView(aspect: aspect, defaults: loaded) { defaults in
                        apply(defaults, changed: [aspect])
                    }
                }
            }
            .appOverlays()
        }
        .sheet(isPresented: $showingDispatch, onDismiss: refreshConfiguration) {
            DispatchView().appOverlays()
        }
        .sheet(isPresented: $showingEnvironmentAccess) {
            EnvironmentsView().appOverlays()
        }
        .sheet(isPresented: $showingSkills, onDismiss: refreshConfiguration) {
            SkillsView(manager: skills).appOverlays()
        }
        .sheet(isPresented: $showingShortcuts, onDismiss: refreshConfiguration) {
            ShortcutsView().appOverlays()
        }
        .sheet(isPresented: $showingJSON) {
            SiteConfigurationJSONView(defaults: loaded).appOverlays()
        }
        .onAppear {
            refreshConfiguration()
            pendingBackup = AppBackup.pending()
        }
        // A freshly loaded file offers everything it holds; unticking is the user's move.
        .onChange(of: loader.selection) { _, selection in
            chosen = selection?.plan.everything ?? []
        }
    }

    private var configuration: some View {
        ChoiceBlock("CONFIGURATION",
                    note: "These values are saved to one current configuration file. The JSON view is read-only and always generated from the settings shown here. A backup also carries your preferences, bots, shortcuts, requests and project list to another Mac.") {
            SettingsCard {
                VStack(alignment: .leading, spacing: Space.md) {
                    HStack(alignment: .top, spacing: Space.lg) {
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            Text("Current configuration")
                                .font(Typography.body.weight(.semibold))
                            Text(loaded.summary)
                                .font(Typography.detail)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(SiteConfigurationImporter.destination.path.abbreviatedPath)
                                .font(Typography.data)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        ActionButton(title: "JSON", tone: .outlined, icon: "curlybraces") {
                            showingJSON = true
                        }
                        ActionButton(title: "Export backup…", tone: .outlined,
                                     icon: "square.and.arrow.up", action: exportBackup)
                    }
                    if let exportFailure { SourceFailure(exportFailure).transition(.fadeIn) }
                }
                .padding(Space.lg)
                .smoothlyResizes(when: [exportFailure])

                SettingsRowDivider()

                ForEach(SiteConfigurationAspect.allCases) { aspect in
                    configurationRow(aspect)
                    if aspect != SiteConfigurationAspect.allCases.last {
                        SettingsRowDivider()
                    }
                }
            }
        }
    }

    private func configurationRow(_ aspect: SiteConfigurationAspect) -> some View {
        HStack(spacing: Space.lg) {
            Image(systemName: aspect.icon)
                .font(Typography.body.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 27, height: 27)
                .background(Circle().fill(Theme.accent.opacity(0.09)))
            VStack(alignment: .leading, spacing: 1) {
                Text(aspect.title)
                    .font(Typography.body.weight(.semibold))
                Text(currentDetail(for: aspect))
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            configurationActions(for: aspect)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .contentShape(Rectangle())
    }

    @ViewBuilder private func configurationActions(for aspect: SiteConfigurationAspect) -> some View {
        if aspect == .apiAccess {
            HStack(spacing: Space.sm) {
                ActionButton(title: "Shared defaults",
                             tone: .sunken,
                             height: ControlHeight.md,
                             size: Typography.Size.detail) {
                    editor = .apiAccess
                }
                ActionButton(title: "Environment credentials",
                             tone: .sunken,
                             height: ControlHeight.md,
                             size: Typography.Size.detail) {
                    showingEnvironmentAccess = true
                }
            }
        } else {
            ActionButton(title: actionTitle(for: aspect),
                         tone: .sunken,
                         height: ControlHeight.md,
                         size: Typography.Size.detail) {
                open(aspect)
            }
        }
    }

    private func actionTitle(for aspect: SiteConfigurationAspect) -> String {
        switch aspect {
        case .requests, .skills, .shortcuts: "Open"
        default: "Configure"
        }
    }

    private func open(_ aspect: SiteConfigurationAspect) {
        switch aspect {
        case .requests:
            showingDispatch = true
        case .skills:
            showingSkills = true
        case .shortcuts:
            showingShortcuts = true
        default:
            editor = aspect
        }
    }

    private func refreshConfiguration() {
        loaded = currentConfiguration()
    }

    private func currentDetail(for aspect: SiteConfigurationAspect) -> String {
        switch aspect {
        case .environments: counted(loaded.deployEnvironments.count, "environment")
        case .skills: loaded.skills?.name ?? "Not configured"
        default: aspect.detail(in: loaded)
        }
    }

    private func backupPreview(_ backup: AppBackup) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Divider().overlay(Theme.border)
            HStack(alignment: .top, spacing: Space.md) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("Backup from \(backup.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(Typography.body.weight(.semibold))
                    Text("\(backupChosen.count) of \(backup.parts.count) parts will be imported.")
                        .font(Typography.detail)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                ActionButton(title: "Import and restart", action: { confirmImport(backup) })
                    .disabled(backupChosen.isEmpty)
            }

            ForEach(backup.parts) { part in
                Toggle(isOn: binding(for: part)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(part.title).font(Typography.detail.weight(.medium))
                        Text(backup.detail(for: part))
                            .font(Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.appCheckbox)
            }
        }
        .sourceResult(Theme.addition)
    }

    private func pendingImport(_ pending: AppBackup) -> some View {
        HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(Theme.addition)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Import waiting for a restart")
                    .font(Typography.body.weight(.semibold))
                Text("\(pending.parts.map(\.title).joined(separator: ", ")) will be applied the next time Code Station opens.")
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            ActionButton(title: "Cancel import", tone: .sunken, height: ControlHeight.md, size: Typography.Size.detail) {
                AppBackup.cancelPending()
                pendingBackup = nil
            }
            ActionButton(title: "Restart now", height: ControlHeight.md, size: Typography.Size.detail, action: restart)
        }
        .sourceResult(Theme.addition)
    }

    private func binding(for part: AppBackup.Part) -> Binding<Bool> {
        Binding(get: { backupChosen.contains(part) },
                set: { selected in
                    if selected { backupChosen.insert(part) } else { backupChosen.remove(part) }
                })
    }

    private func exportBackup() {
        guard let url = FilePicker.saveFile(
            suggestedName: "Code Station backup \(Date.now.formatted(.iso8601.year().month().day())).json",
            prompt: "Export",
            message: "Save a backup to import on another Mac.",
            types: [.json]) else { return }
        do {
            let configuration = try SiteConfigurationImporter.configurationData(for: currentConfiguration())
            try AppBackup.make(configuration: configuration).encoded().write(to: url, options: .atomic)
            exportFailure = nil
            settingsNote("Backup saved", "checkmark")
        } catch {
            exportFailure = "The backup could not be saved: \(error.localizedDescription)"
        }
    }

    private func chooseImport() {
        guard !loader.isLoading,
              let url = FilePicker.chooseFile(prompt: "Load",
                                              message: "Choose a team configuration or a Code Station backup.",
                                              types: [.json]) else { return }
        guard AppBackup.isBackup(url) else {
            backup = nil
            backupFailure = nil
            loader.loadFile(url)
            return
        }
        loader.clear()
        do {
            let loaded = try AppBackup.read(url)
            backup = loaded
            backupChosen = Set(loaded.parts)
            backupFailure = nil
        } catch {
            backup = nil
            backupFailure = error.localizedDescription
        }
    }

    private func loadRepository() {
        guard loader.canLoadRepository else { return }
        backup = nil
        backupFailure = nil
        loader.loadRepository()
    }

    private func confirmImport(_ backup: AppBackup) {
        let chosen = backup.parts.filter(backupChosen.contains)
        var rows = chosen.map { part in
            Dialog.Impact.Row(title: part.title,
                              detail: part.replaces
                                ? "What is on this Mac is replaced by the backup."
                                : "Added beside the ones already here.",
                              kept: !part.replaces)
        }
        rows.append(.init(title: "Sessions, history and secrets",
                          detail: "Not touched.", kept: true))
        dialogs.show(.impact("Import this backup?",
                             message: "Code Station restarts to finish the import.",
                             rows: rows,
                             warning: chosen.contains(where: \.replaces)
                                ? "Replaced settings cannot be restored." : nil,
                             action: "Import and restart") {
            do {
                try AppBackup.stage(backup.keeping(Set(chosen)))
                self.backup = nil
                restart()
            } catch {
                backupFailure = "The import could not be prepared: \(error.localizedDescription)"
            }
        })
    }

    // Quitting can still be turned down, for example while sessions are running. The
    // import then stays set aside and is applied whenever the app next opens.
    private func restart() {
        pendingBackup = AppBackup.pending()
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            try? AppUpdateInstall.relaunchAfterExit(bundle)
        }
        NSApp.terminate(nil)
    }

    // A team configuration and a backup load through the same row. What comes back decides
    // the preview: a configuration resets the aspects you tick at once, while a backup
    // replaces files the running app holds open, so it waits for a restart.
    private var importing: some View {
        ChoiceBlock("IMPORT",
                    note: "Load a team configuration from a repository or a file, or choose a backup made on another Mac. Nothing changes until you choose what to bring in. Sessions, history and secrets never travel in a backup, so sign in again after a move.") {
            SettingsCard {
                VStack(alignment: .leading, spacing: Space.md) {
                    sources
                    if let pendingBackup {
                        pendingImport(pendingBackup).transition(.fadeIn)
                    } else if let backup {
                        backupPreview(backup).transition(.fadeIn)
                    }
                    if let selection = loader.selection { preview(selection).transition(.fadeIn) }
                    if let failure = loader.failure ?? backupFailure {
                        SourceFailure(failure).transition(.fadeIn)
                    }
                    if let loadFailure = loaded.loadFailure { SourceFailure(loadFailure).transition(.fadeIn) }
                }
                .padding(Space.lg)
                .smoothlyResizes(when: [loader.selection?.sourceName, loader.failure, loaded.loadFailure,
                                        backup?.createdAt.description,
                                        pendingBackup?.createdAt.description, backupFailure])
            }
        }
    }

    private var sources: some View {
        @Bindable var loader = loader
        return HStack(spacing: Space.md) {
            TextField("https://github.com/org/settings", text: $loader.repositoryURL)
                .textFieldStyle(.plain)
                .font(Typography.code)
                .padding(.horizontal, Space.md)
                .frame(height: 32)
                .fieldSurface()
                .onSubmit(loadRepository)
            ActionButton(title: loader.isLoading ? "Loading…" : "Load",
                         tone: .outlined,
                         action: loadRepository)
                .disabled(!loader.canLoadRepository)
            ActionButton(title: "Choose file…", tone: .outlined, icon: "folder",
                         action: chooseImport)
                .disabled(loader.isLoading)
        }
    }

    // Loading is only a preview. The current file is not touched until Reset selected is
    // pressed, which makes it safe to inspect an unfamiliar team configuration.
    private func preview(_ selection: SiteConfigurationSelection) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Divider().overlay(Theme.border)
            HStack(alignment: .top, spacing: Space.md) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(selection.sourceName)
                        .font(Typography.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(chosenText(selection.plan))
                        .font(Typography.detail)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                ActionButton(title: "Reset selected", action: { install(selection) })
                    .disabled(chosen.isEmpty)
            }

            ForEach(selection.plan.aspects) { aspect in
                Toggle(isOn: binding(for: aspect)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(aspect.title).font(Typography.detail.weight(.medium))
                        Text(aspect.detail(in: selection.defaults))
                            .font(Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.appCheckbox)
            }
        }
        .sourceResult(Theme.addition)
    }

    private func chosenText(_ plan: SiteConfigurationPlan) -> String {
        if chosen.count == plan.aspects.count {
            return "All \(chosen.count) aspects will be reset."
        }
        return "\(chosen.count) of \(plan.aspects.count) aspects will be reset."
    }

    private func binding(for aspect: SiteConfigurationAspect) -> Binding<Bool> {
        Binding(get: { chosen.contains(aspect) },
                set: { selected in
                    if selected { chosen.insert(aspect) } else { chosen.remove(aspect) }
                })
    }

    private func install(_ selection: SiteConfigurationSelection) {
        do {
            let defaults = try SiteConfigurationImporter.reset(selection,
                                                               aspects: chosen,
                                                               current: loaded)
            apply(defaults, changed: chosen)
            loader.clear()
        } catch {
            loader.failure = error.localizedDescription
        }
    }

    private func apply(_ defaults: SiteDefaults, changed: Set<SiteConfigurationAspect>) {
        if changed.contains(.requests) { dispatch.resetSiteRequests(to: defaults) }
        if changed.contains(.apiAccess) {
            dispatchAuth.resetSiteAccess(to: defaults)
        } else if changed.contains(.environments) {
            dispatchAuth.applyEnvironments(from: defaults)
        }
        if changed.contains(.shortcuts) { shortcuts.resetSiteShortcuts(to: defaults) }
        if changed.contains(.skills) { Preferences.setSkillsMarketplace(nil) }
        loaded = defaults
    }

    // Requests and shortcuts can be edited in their main tools, while a marketplace can
    // be changed from Repertoire. Pulling those site-owned values back in keeps the JSON
    // view and later edits based on what the app is using now, not the file that seeded it.
    private func currentConfiguration() -> SiteDefaults {
        var current = SiteDefaults.current
        current.environments = current.deployEnvironments
        var dispatchConfiguration = current.dispatch ?? SiteDefaults.DispatchConfig()
        dispatchConfiguration.requests = dispatch.siteConfigurationRequests
        current.dispatch = dispatchConfiguration
        current.shortcuts = shortcuts.siteConfigurationShortcuts

        if let marketplace = Preferences.skillsMarketplace(), marketplace.isValid {
            current.skills = SiteDefaults.Skills(name: marketplace.label,
                                                 marketplace: marketplace.marketplace,
                                                 repository: marketplace.source,
                                                 sourceKind: marketplace.sourceKind)
        }
        return current
    }
}
