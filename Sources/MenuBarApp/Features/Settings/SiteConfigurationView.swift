import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The editors address rows by index through one writable path per list. The lists that
// sit inside an optional group get a path of their own, since a key path cannot write
// through an optional.
private extension SiteDefaults {
    var requestList: [DispatchConfig.Request]? {
        get { dispatch?.requests }
        set { dispatch?.requests = newValue }
    }

    var presetList: [MCP.Preset]? {
        get { mcp?.presets }
        set { mcp?.presets = newValue }
    }
}

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

private struct SiteConfigurationEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let aspect: SiteConfigurationAspect
    let onSave: (SiteDefaults) -> Void

    @State private var draft: SiteDefaults
    @State private var saved: SiteDefaults
    @State private var failure: String?

    init(aspect: SiteConfigurationAspect,
         defaults: SiteDefaults,
         onSave: @escaping (SiteDefaults) -> Void) {
        self.aspect = aspect
        self.onSave = onSave
        let prepared = Self.prepared(defaults, for: aspect)
        _draft = State(initialValue: prepared)
        _saved = State(initialValue: prepared)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(editorTitle).font(Typography.title)
                Text(editorNote)
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Space.xxl)
            .headerBand()

            ScrollView {
                editor
                    .padding(Space.xxl)
            }
            .frame(maxHeight: 560)

            SheetFooter(primary: SheetAction(title: "Save", enabled: draft != saved,
                                             shortcut: KeyboardShortcut("s", modifiers: .command),
                                             action: save),
                        dismiss: { dismiss() }) {
                if let failure {
                    Text(failure)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.deletion)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(draft == saved
                         ? "Changes are written to the current configuration file."
                         : "Unsaved changes. Cancel leaves without keeping them.")
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 660)
        .background(Theme.background)
    }

    private var editorTitle: String {
        aspect == .apiAccess ? "Configure shared API defaults" : "Configure \(aspect.title)"
    }

    private var editorNote: String {
        switch aspect {
        case .environments:
            "Name the deployments used by Dispatch, server tags, and troubleshooting. The name is what {{env}} resolves to."
        case .apiAccess:
            "Set the sign-in provider used as the starting point for every environment. Secrets stay in the Keychain."
        case .requests:
            "Keep the small set of API requests that a configured install should start with."
        case .mcp:
            "Define reusable MCP server configurations. The server type names its add action. Empty environment and header values are filled in when a preset is added."
        case .skills:
            "Choose the skills marketplace used by both supported agents."
        case .shortcuts:
            "Keep the shared commands that should appear in the shortcuts list."
        }
    }

    @ViewBuilder private var editor: some View {
        switch aspect {
        case .environments: environmentsEditor
        case .apiAccess: apiAccessEditor
        case .requests: requestsEditor
        // The presets open in a sheet of their own, MCPPresetsEditorView.
        case .mcp: EmptyView()
        case .skills: skillsEditor
        case .shortcuts: shortcutsEditor
        }
    }

    private var environmentsEditor: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            ForEach(Array((draft.environments ?? []).indices), id: \.self) { index in
                let environment = binding(\.environments, at: index,
                                          or: SiteDefaults.Environment(name: ""))
                editorCard {
                    HStack(alignment: .top, spacing: Space.md) {
                        SiteConfigurationField(caption: "NAME / {{env}}",
                                               placeholder: "production",
                                               text: environment.name)
                        SiteConfigurationField(caption: "LABEL",
                                               placeholder: "Production",
                                               text: optional(environment.title))
                        removeButton { draft.environments?.remove(at: index) }
                    }
                    Toggle("Treat as a live environment",
                           isOn: optionalBool(environment.danger))
                        .toggleStyle(.appCheckbox)
                        .font(Typography.detail)
                }
                .transition(.fold)
            }
            addButton("Add environment") {
                draft.environments?.append(SiteDefaults.Environment(name: "", title: ""))
            }
        }
        .smoothlyResizes(when: draft.environments?.count)
    }

    private var apiAccessEditor: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            editorCard {
                Toggle("Configure a shared sign-in provider", isOn: oauthEnabled)
                    .toggleStyle(.appSwitch)
                    .font(Typography.body.weight(.semibold))
                if oauthEnabled.wrappedValue {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        OptionMenu(caption: "GRANT TYPE",
                                   value: oauthGrant.wrappedValue.label,
                                   options: GrantType.allCases.map { grant in
                                       (grant.label, grant == oauthGrant.wrappedValue,
                                        { oauthGrant.wrappedValue = grant })
                                   })
                        if oauthGrant.wrappedValue.usesBrowser {
                            SiteConfigurationField(caption: "AUTH URL",
                                                   placeholder: "https://id.example/oauth/authorize",
                                                   text: oauthText(\.authURL))
                                .transition(.fadeIn)
                        }
                        SiteConfigurationField(caption: "ACCESS TOKEN URL",
                                               placeholder: "https://id.example/oauth/token",
                                               text: oauthText(\.tokenURL))
                        SiteConfigurationField(caption: "CLIENT ID",
                                               placeholder: "client id",
                                               text: oauthText(\.clientID))
                        SiteConfigurationField(caption: "SCOPE",
                                               placeholder: "openid",
                                               text: oauthText(\.scope))
                        if oauthGrant.wrappedValue.usesBrowser {
                            SiteConfigurationField(caption: "CALLBACK URL",
                                                   placeholder: "http://localhost:8234/callback",
                                                   text: oauthText(\.callbackURL))
                                .transition(.fadeIn)
                        }
                    }
                    .transition(.fadeIn)
                }
            }
            .smoothlyResizes(when: [oauthEnabled.wrappedValue, oauthGrant.wrappedValue.usesBrowser])

        }
    }

    private var requestsEditor: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            ForEach(Array((draft.requestList ?? []).indices), id: \.self) { index in
                let request = binding(\.requestList, at: index,
                                      or: SiteDefaults.DispatchConfig.Request(name: "", url: ""))
                editorCard {
                    HStack(alignment: .top, spacing: Space.md) {
                        SiteConfigurationField(caption: "NAME",
                                               placeholder: "List orders",
                                               text: request.name)
                        methodMenu(request.method)
                        removeButton { draft.dispatch?.requests?.remove(at: index) }
                    }
                    SiteConfigurationField(caption: "URL",
                                           placeholder: "https://api.{{env}}.example/orders",
                                           text: request.url)
                }
                .transition(.fold)
            }
            addButton("Add starter request") {
                var dispatch = draft.dispatch ?? SiteDefaults.DispatchConfig()
                dispatch.requests = (dispatch.requests ?? [])
                    + [SiteDefaults.DispatchConfig.Request(name: "", method: .get, url: "")]
                draft.dispatch = dispatch
            }
        }
        .smoothlyResizes(when: draft.requestList?.count)
    }

    private var skillsEditor: some View {
        editorCard {
            Toggle("Configure a skills marketplace", isOn: skillsEnabled)
                .toggleStyle(.appSwitch)
                .font(Typography.body.weight(.semibold))
            if skillsEnabled.wrappedValue {
                VStack(alignment: .leading, spacing: Space.lg) {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        SectionLabel("SOURCE", style: .field)
                        HStack(spacing: Space.sm) {
                            ChoicePill(title: "Git repository",
                                       selected: skillsSourceKind.wrappedValue == .gitRepository) {
                                skillsSourceKind.wrappedValue = .gitRepository
                            }
                            ChoicePill(title: "Local file",
                                       selected: skillsSourceKind.wrappedValue == .localFile) {
                                skillsSourceKind.wrappedValue = .localFile
                            }
                            Spacer()
                        }
                    }
                    SiteConfigurationField(caption: "DISPLAY NAME",
                                           placeholder: "Example Engineering",
                                           text: skillsText(\.name))
                    SiteConfigurationField(caption: "MARKETPLACE NAME",
                                           placeholder: "example-engineering",
                                           text: skillsText(\.marketplace))
                    HStack(alignment: .bottom, spacing: Space.md) {
                        SiteConfigurationField(
                            caption: skillsSourceKind.wrappedValue == .localFile
                                ? "MARKETPLACE FILE" : "GIT REPOSITORY",
                            placeholder: skillsSourceKind.wrappedValue == .localFile
                                ? "/path/to/marketplace.json"
                                : "https://github.com/example/plugins",
                            text: skillsText(\.repository))
                        if skillsSourceKind.wrappedValue == .localFile {
                            ActionButton(title: "Choose file…",
                                         tone: .outlined,
                                         height: ControlHeight.lg,
                                         icon: "folder",
                                         action: chooseSkillsFile)
                                .transition(.fadeIn)
                        }
                    }
                }
                .transition(.fadeIn)
            }
        }
        .smoothlyResizes(when: [skillsEnabled.wrappedValue, skillsSourceKind.wrappedValue == .localFile])
    }

    private var shortcutsEditor: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            ForEach(Array((draft.shortcuts ?? []).indices), id: \.self) { index in
                let shortcut = binding(\.shortcuts, at: index,
                                       or: SiteDefaults.ShortcutEntry(name: "", command: ""))
                editorCard {
                    HStack(alignment: .top, spacing: Space.md) {
                        SiteConfigurationField(caption: "NAME",
                                               placeholder: "Run service",
                                               text: shortcut.name)
                        removeButton { draft.shortcuts?.remove(at: index) }
                    }
                    SiteConfigurationField(caption: "COMMAND",
                                           placeholder: "./gradlew bootRun",
                                           text: shortcut.command)
                    VStack(alignment: .leading, spacing: Space.sm) {
                        SectionLabel("ICON", style: .field)
                        ShortcutIconPicker(symbol: shortcut.icon)
                    }
                }
                .transition(.fold)
            }
            addButton("Add shortcut") {
                draft.shortcuts?.append(SiteDefaults.ShortcutEntry(name: "", command: ""))
            }
        }
        .smoothlyResizes(when: draft.shortcuts?.count)
    }

    private func editorCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.lg) { content() }
            .padding(Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
    }

    private func addButton(_ title: String, action: @escaping () -> Void) -> some View {
        ActionButton(title: title, tone: .outlined, icon: "plus", action: action)
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(Typography.label)
                .foregroundStyle(Theme.deletion)
                .frame(width: 32, height: 32)
                .surface(Theme.deletion.opacity(0.07), cornerRadius: Radius.control,
                         border: Theme.deletion.opacity(0.2))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverLift(amount: Motion.smallLift)
        .padding(.top, Space.xl)
    }

    private func methodMenu(_ method: Binding<HTTPMethod?>) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionLabel("METHOD", style: .field)
            ActionButton(title: (method.wrappedValue ?? .get).rawValue,
                         tone: .sunken,
                         height: ControlHeight.lg,
                         disclosure: true)
                .appMenu {
                    HTTPMethod.allCases.map { choice in
                        .item(choice.rawValue,
                              checked: method.wrappedValue == choice,
                              action: { method.wrappedValue = choice })
                    }
                }
        }
    }

    private var oauthEnabled: Binding<Bool> {
        Binding(get: { draft.dispatch?.oauth != nil }, set: { enabled in
            var dispatch = draft.dispatch ?? SiteDefaults.DispatchConfig()
            dispatch.oauth = enabled ? (dispatch.oauth ?? SiteDefaults.DispatchConfig.OAuth(
                grant: .authorizationCodePKCE,
                callbackURL: "http://localhost:8234/callback")) : nil
            draft.dispatch = dispatch
        })
    }

    private var oauthGrant: Binding<GrantType> {
        Binding(get: { draft.dispatch?.oauth?.grant ?? .authorizationCodePKCE }, set: { grant in
            var dispatch = draft.dispatch ?? SiteDefaults.DispatchConfig()
            var oauth = dispatch.oauth ?? SiteDefaults.DispatchConfig.OAuth()
            oauth.grant = grant
            dispatch.oauth = oauth
            draft.dispatch = dispatch
        })
    }

    private func oauthText(_ keyPath: WritableKeyPath<SiteDefaults.DispatchConfig.OAuth, String?>)
        -> Binding<String> {
        Binding(get: { draft.dispatch?.oauth?[keyPath: keyPath] ?? "" }, set: { value in
            var dispatch = draft.dispatch ?? SiteDefaults.DispatchConfig()
            var oauth = dispatch.oauth ?? SiteDefaults.DispatchConfig.OAuth()
            oauth[keyPath: keyPath] = value
            dispatch.oauth = oauth
            draft.dispatch = dispatch
        })
    }

    private var skillsEnabled: Binding<Bool> {
        Binding(get: { draft.skills != nil }, set: { enabled in
            draft.skills = enabled
                ? (draft.skills ?? SiteDefaults.Skills(name: "", marketplace: "", repository: ""))
                : nil
        })
    }

    private func skillsText(_ keyPath: WritableKeyPath<SiteDefaults.Skills, String>)
        -> Binding<String> {
        Binding(get: { draft.skills?[keyPath: keyPath] ?? "" }, set: { value in
            var skills = draft.skills
                ?? SiteDefaults.Skills(name: "", marketplace: "", repository: "")
            skills[keyPath: keyPath] = value
            draft.skills = skills
        })
    }

    private var skillsSourceKind: Binding<SkillMarketplaceConfiguration.SourceKind> {
        Binding(get: { draft.skills?.sourceKind ?? .gitRepository }, set: { sourceKind in
            var skills = draft.skills
                ?? SiteDefaults.Skills(name: "", marketplace: "", repository: "")
            guard (skills.sourceKind ?? .gitRepository) != sourceKind else { return }
            skills.sourceKind = sourceKind
            skills.repository = ""
            draft.skills = skills
        })
    }

    private func chooseSkillsFile() {
        guard let url = FilePicker.chooseFile(prompt: "Choose",
                                              message: "Choose the skills marketplace JSON file.",
                                              types: [.json]) else { return }
        var skills = draft.skills
            ?? SiteDefaults.Skills(name: "", marketplace: "", repository: "")
        skills.sourceKind = .localFile
        skills.repository = url.path
        draft.skills = skills
    }

    // One row of a list on the draft. The fallback only covers the list being absent;
    // the editors create it before they draw rows.
    private func binding<Value>(_ list: WritableKeyPath<SiteDefaults, [Value]?>,
                                at index: Int, or fallback: Value) -> Binding<Value> {
        Binding(get: { draft[keyPath: list]?[index] ?? fallback },
                set: { draft[keyPath: list]?[index] = $0 })
    }

    private func optional(_ value: Binding<String?>) -> Binding<String> {
        Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0 })
    }

    private func optionalBool(_ value: Binding<Bool?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue ?? false }, set: { value.wrappedValue = $0 })
    }

    private func save() {
        do {
            let cleaned = try SiteConfigurationForm.cleaned(draft, aspect: aspect)
            let defaults = try SiteConfigurationImporter.install(cleaned)
            draft = defaults
            saved = defaults
            failure = nil
            onSave(defaults)
        } catch {
            failure = error.localizedDescription
        }
    }

    private static func prepared(_ defaults: SiteDefaults,
                                 for aspect: SiteConfigurationAspect) -> SiteDefaults {
        var draft = defaults
        switch aspect {
        case .environments:
            if draft.environments == nil { draft.environments = defaults.deployEnvironments }
        case .apiAccess:
            break
        case .requests:
            var dispatch = draft.dispatch ?? SiteDefaults.DispatchConfig()
            if dispatch.requests == nil { dispatch.requests = [] }
            draft.dispatch = dispatch
        case .mcp:
            if draft.mcp == nil { draft.mcp = SiteDefaults.MCP(presets: []) }
        case .skills:
            break
        case .shortcuts:
            if draft.shortcuts == nil { draft.shortcuts = [] }
        }
        return draft
    }
}

enum SiteConfigurationForm {
    static func cleaned(_ defaults: SiteDefaults,
                        aspect: SiteConfigurationAspect) throws -> SiteDefaults {
        var result = defaults
        result.loadFailure = nil
        result.sourceURL = nil

        switch aspect {
        case .environments:
            result.environments = (result.environments ?? []).map {
                SiteDefaults.Environment(name: $0.name.trimmed,
                                         title: optional($0.title),
                                         danger: $0.isDangerous ? true : nil)
            }
            guard result.environments?.allSatisfy({ !$0.name.isEmpty }) == true else {
                throw ImportError("Every environment needs a name.")
            }
            let names = result.environments?.map(\.name) ?? []
            guard !names.isEmpty else {
                throw ImportError("Add at least one environment.")
            }
            guard Set(names).count == names.count else {
                throw ImportError("Environment names must be unique.")
            }

        case .apiAccess:
            if var oauth = result.dispatch?.oauth {
                oauth.authURL = optional(oauth.authURL)
                oauth.tokenURL = optional(oauth.tokenURL)
                oauth.clientID = optional(oauth.clientID)
                oauth.scope = optional(oauth.scope)
                oauth.callbackURL = optional(oauth.callbackURL)
                result.dispatch?.oauth = oauth

                let config = result.dispatchOAuth
                guard config.missing.isEmpty else {
                    throw ImportError("Fill in \(config.missing.joined(separator: ", ")).")
                }
            }
            removeEmptyDispatch(from: &result)

        case .requests:
            let requests = (result.dispatch?.requests ?? []).map {
                SiteDefaults.DispatchConfig.Request(name: $0.name.trimmed,
                                                    method: $0.method ?? .get,
                                                    url: $0.url.trimmed)
            }
            guard requests.allSatisfy({ !$0.name.isEmpty && !$0.url.isEmpty }) else {
                throw ImportError("Every starter request needs a name and URL.")
            }
            var dispatch = result.dispatch ?? SiteDefaults.DispatchConfig()
            dispatch.requests = requests
            result.dispatch = dispatch

        case .mcp:
            let presets = (result.mcp?.presets ?? []).map(cleanedPreset)
            guard presets.allSatisfy({ !$0.name.isEmpty && $0.hasConnection }) else {
                throw ImportError("Every MCP preset needs a name and either a command or URL.")
            }
            let names = presets.map(\.name)
            guard Set(names).count == names.count else {
                throw ImportError("MCP preset names must be unique.")
            }
            for preset in presets {
                try validateValues(preset.env, in: preset.name)
                try validateValues(preset.headers, in: preset.name)
            }
            result.mcp = SiteDefaults.MCP(presets: presets)

        case .skills:
            if let skills = result.skills {
                let cleaned = SiteDefaults.Skills(name: skills.name.trimmed,
                                                  marketplace: skills.marketplace.trimmed,
                                                  repository: skills.repository.trimmed,
                                                  sourceKind: skills.sourceKind)
                guard !cleaned.name.isEmpty,
                      !cleaned.marketplace.isEmpty,
                      !cleaned.repository.isEmpty else {
                    throw ImportError("The marketplace needs a display name, marketplace name, and repository.")
                }
                result.skills = cleaned
            }

        case .shortcuts:
            let shortcuts = (result.shortcuts ?? []).map {
                SiteDefaults.ShortcutEntry(name: $0.name.trimmed, command: $0.command.trimmed,
                                           icon: ShortcutIcon.resolve($0.icon))
            }
            guard shortcuts.allSatisfy({ !$0.name.isEmpty && !$0.command.isEmpty }) else {
                throw ImportError("Every shortcut needs a name and a command.")
            }
            result.shortcuts = shortcuts
        }

        return result
    }

    private static func optional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmed
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func cleanedPreset(_ preset: SiteDefaults.MCP.Preset)
        -> SiteDefaults.MCP.Preset {
        SiteDefaults.MCP.Preset(
            name: preset.name.trimmed,
            title: optional(preset.title),
            serverType: optional(preset.serverType),
            environment: optional(preset.environment),
            command: optional(preset.command),
            args: preset.args?.map(\.trimmed).filter { !$0.isEmpty },
            url: optional(preset.url),
            type: optional(preset.type),
            env: cleanedValues(preset.env),
            headers: cleanedValues(preset.headers))
    }

    private static func cleanedValues(_ values: [SiteDefaults.MCP.Value]?)
        -> [SiteDefaults.MCP.Value]? {
        values?.map { .init(key: $0.key.trimmed, value: $0.value.trimmed) }
    }

    private static func validateValues(_ values: [SiteDefaults.MCP.Value]?,
                                       in preset: String) throws {
        let values = values ?? []
        guard values.allSatisfy({ !$0.key.isEmpty }) else {
            throw ImportError("Every environment variable and header in \(preset) needs a key.")
        }
        guard Set(values.map(\.key)).count == values.count else {
            throw ImportError("Environment variable and header keys must be unique within \(preset).")
        }
    }

    private static func removeEmptyDispatch(from defaults: inout SiteDefaults) {
        guard let dispatch = defaults.dispatch else { return }
        if dispatch.oauth == nil && dispatch.requests == nil {
            defaults.dispatch = nil
        }
    }
}

private struct SiteConfigurationField: View {
    let caption: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionLabel(caption, style: .field)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Typography.data)
                .padding(.horizontal, Space.lg)
                .frame(height: ControlHeight.lg)
                .fieldSurface(cornerRadius: Radius.card)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SiteConfigurationTextArea: View {
    let caption: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionLabel(caption, style: .field)
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(Typography.data)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, Space.sm)
                        .padding(.vertical, Space.md)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(Typography.data)
                    .scrollContentBackground(.hidden)
                    .padding(Space.xxs)
            }
            .frame(height: 64)
            .fieldSurface(cornerRadius: Radius.card)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SiteConfigurationJSONView: View {
    @Environment(\.dismiss) private var dismiss
    let defaults: SiteDefaults

    @State private var failure: String?

    private var data: Data? { try? SiteConfigurationImporter.configurationData(for: defaults) }
    private var text: String { data.map { String(decoding: $0, as: UTF8.self) } ?? "{}\n" }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Current configuration JSON").font(Typography.title)
                Text("This read-only view is generated from the current settings and is safe to export as a reset file.")
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Space.xxl)
            .headerBand()

            VStack(alignment: .leading, spacing: Space.md) {
                ScrollView {
                    Text(text)
                        .font(Typography.code)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.lg)
                }
                .frame(height: 440)
                .fieldSurface(cornerRadius: Radius.card)

                if let failure {
                    Text(failure)
                        .font(Typography.detail)
                        .foregroundStyle(Theme.deletion)
                        .transition(.fadeIn)
                }
            }
            .padding(Space.xxl)
            .smoothlyResizes(when: failure)

            SheetFooter(dismiss: { dismiss() }) {
                HStack(spacing: Space.lg) {
                    CopyButton("Copy JSON", size: Typography.Size.detail) { text }
                    InlineLink(title: "Export…", action: export)
                }
            }
        }
        .frame(width: 700)
        .background(Theme.background)
    }

    private func export() {
        guard let data else {
            failure = "The current configuration could not be encoded."
            return
        }
        guard let url = FilePicker.saveFile(suggestedName: "site-configuration.json",
                                            prompt: "Export",
                                            message: "Export the current Code Station configuration.",
                                            types: [.json]) else { return }
        do {
            try data.write(to: url, options: .atomic)
            failure = nil
        } catch {
            failure = "The configuration could not be exported: \(error.localizedDescription)"
        }
    }
}
