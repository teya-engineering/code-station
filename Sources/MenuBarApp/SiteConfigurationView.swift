import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SiteConfigurationSection: View {
    @Environment(DispatchStore.self) private var dispatch
    @Environment(DispatchAuthStore.self) private var dispatchAuth
    @Environment(ShortcutStore.self) private var shortcuts

    let skills: SkillsManager

    @State private var loaded = SiteDefaults.current
    @State private var pending: SiteConfigurationSelection?
    @State private var chosen: Set<SiteConfigurationAspect> = []
    @State private var repositoryURL = ""
    @State private var loading = false
    @State private var failure: String?
    @State private var editor: SiteConfigurationAspect?
    @State private var showingDispatch = false
    @State private var showingMCP = false
    @State private var showingSkills = false
    @State private var showingShortcuts = false
    @State private var showingJSON = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            configuration.id(SettingsSearchTarget.advancedConfiguration.id)
            reset.id(SettingsSearchTarget.advancedReset.id)
        }
        .sheet(item: $editor) { aspect in
            SiteConfigurationEditorView(aspect: aspect, defaults: loaded) { defaults in
                apply(defaults, changed: [aspect])
            }
            .appOverlays()
        }
        .sheet(isPresented: $showingDispatch, onDismiss: refreshConfiguration) {
            DispatchView().appOverlays()
        }
        .sheet(isPresented: $showingMCP) {
            ConfigManagerView().appOverlays()
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
        .onAppear(perform: refreshConfiguration)
    }

    private var configuration: some View {
        ChoiceBlock("CONFIGURATION",
                    note: "These values are saved to one current configuration file. The JSON view is read-only and always generated from the settings shown here.") {
            SettingsCard {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Current configuration")
                            .font(.system(size: 13, weight: .semibold))
                        Text(loaded.summary)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(SiteConfigurationImporter.destination.path.abbreviatedPath)
                            .font(.mono(10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    ActionButton(title: "JSON", tone: .outlined, icon: "curlybraces") {
                        showingJSON = true
                    }
                }
                .padding(14)

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
        HStack(spacing: 11) {
            Image(systemName: aspect.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 27, height: 27)
                .background(Circle().fill(Theme.accent.opacity(0.09)))
            VStack(alignment: .leading, spacing: 1) {
                Text(aspect.title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(currentDetail(for: aspect))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            ActionButton(title: actionTitle(for: aspect),
                         tone: .sunken,
                         height: 28,
                         size: 11.5) {
                open(aspect)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func actionTitle(for aspect: SiteConfigurationAspect) -> String {
        switch aspect {
        case .requests, .mcp, .skills, .shortcuts: "Open"
        default: "Configure"
        }
    }

    private func open(_ aspect: SiteConfigurationAspect) {
        switch aspect {
        case .requests:
            showingDispatch = true
        case .mcp:
            showingMCP = true
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
        case .environments:
            let count = loaded.deployEnvironments.count
            return count == 1 ? "1 environment" : "\(count) environments"
        case .apiAccess:
            return aspect.detail(in: loaded)
        case .requests:
            return aspect.detail(in: loaded)
        case .mcp:
            return aspect.detail(in: loaded)
        case .skills:
            return loaded.skills?.name ?? "Not configured"
        case .shortcuts:
            return aspect.detail(in: loaded)
        }
    }

    private var reset: some View {
        ChoiceBlock("RESET FROM FILE",
                    note: "Load a team configuration, choose the aspects to restore, then reset them. Settings you leave unchecked stay exactly as they are.") {
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    sources
                    if let pending { preview(pending) }
                    if let failure { warning(failure) }
                    if let loadFailure = loaded.loadFailure { warning(loadFailure) }
                }
                .padding(14)
            }
        }
    }

    private var sources: some View {
        HStack(spacing: 8) {
            TextField("https://github.com/org/settings", text: $repositoryURL)
                .textFieldStyle(.plain)
                .font(.mono(11.5))
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                .onSubmit(loadRepository)
            ActionButton(title: loading ? "Loading…" : "Load",
                         tone: .outlined,
                         action: loadRepository)
                .disabled(loading || repositoryURL.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(loading ? 0.6 : 1)
            ActionButton(title: "Choose file…",
                         tone: .outlined,
                         icon: "folder",
                         action: chooseFile)
                .disabled(loading)
        }
    }

    // Loading is only a preview. The current file is not touched until Reset selected is
    // pressed, which makes it safe to inspect an unfamiliar team configuration.
    private func preview(_ selection: SiteConfigurationSelection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(Theme.border)
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selection.sourceName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(chosenText(selection.plan))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                ActionButton(title: "Reset selected", action: { install(selection) })
                    .disabled(chosen.isEmpty)
            }

            ForEach(selection.plan.aspects) { aspect in
                Toggle(isOn: binding(for: aspect)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(aspect.title).font(.system(size: 12, weight: .medium))
                        Text(aspect.detail(in: selection.defaults))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.appCheckbox)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.addition.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.addition.opacity(0.28)))
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

    private func warning(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.deletion)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(5)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.deletion.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.deletion.opacity(0.25)))
    }

    private func chooseFile() {
        guard !loading else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "Load"
        panel.message = "Choose a Code Station configuration to use as a reset point."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        record { try SiteConfigurationImporter.load(file: url) }
    }

    private func loadRepository() {
        let repository = repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !loading, !repository.isEmpty else { return }
        loading = true
        failure = nil
        pending = nil
        Task {
            do {
                offer(try await SiteConfigurationImporter.load(gitHubRepository: repository))
            } catch {
                failure = error.localizedDescription
            }
            loading = false
        }
    }

    private func record(_ load: () throws -> SiteConfigurationSelection) {
        do {
            offer(try load())
            failure = nil
        } catch {
            pending = nil
            failure = error.localizedDescription
        }
    }

    private func offer(_ selection: SiteConfigurationSelection) {
        pending = selection
        chosen = selection.plan.everything
    }

    private func install(_ selection: SiteConfigurationSelection) {
        do {
            let defaults = try SiteConfigurationImporter.reset(selection,
                                                               aspects: chosen,
                                                               current: loaded)
            apply(defaults, changed: chosen)
            pending = nil
            chosen = []
            repositoryURL = ""
            failure = nil
        } catch {
            failure = error.localizedDescription
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
            VStack(alignment: .leading, spacing: 3) {
                Text("Configure \(aspect.title)").font(.serif(16))
                Text(editorNote)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .headerBand()

            ScrollView {
                editor
                    .padding(20)
            }
            .frame(maxHeight: 560)

            SheetFooter(primary: SheetAction(title: "Save", enabled: draft != saved,
                                             shortcut: KeyboardShortcut("s", modifiers: .command),
                                             action: save),
                        dismiss: { dismiss() }) {
                if let failure {
                    Text(failure)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.deletion)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(draft == saved
                         ? "Changes are written to the current configuration file."
                         : "Unsaved changes. Cancel leaves without keeping them.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 660)
        .background(Theme.background)
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
        case .mcp: mcpEditor
        case .skills: skillsEditor
        case .shortcuts: shortcutsEditor
        }
    }

    private var environmentsEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array((draft.environments ?? []).indices), id: \.self) { index in
                let environment = environmentBinding(at: index)
                editorCard {
                    HStack(alignment: .top, spacing: 10) {
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
                        .font(.system(size: 12))
                }
            }
            addButton("Add environment") {
                draft.environments?.append(SiteDefaults.Environment(name: "", title: ""))
            }
        }
    }

    private var apiAccessEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            editorCard {
                Toggle("Configure a shared sign-in provider", isOn: oauthEnabled)
                    .toggleStyle(.appSwitch)
                    .font(.system(size: 12.5, weight: .semibold))
                if oauthEnabled.wrappedValue {
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
                                               placeholder: "http://127.0.0.1:8234/callback",
                                               text: oauthText(\.callbackURL))
                    }
                }
            }

        }
    }

    private var requestsEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array((draft.dispatch?.requests ?? []).indices), id: \.self) { index in
                let request = requestBinding(at: index)
                editorCard {
                    HStack(alignment: .top, spacing: 10) {
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
            }
            addButton("Add starter request") {
                var dispatch = draft.dispatch ?? SiteDefaults.DispatchConfig()
                dispatch.requests = (dispatch.requests ?? [])
                    + [SiteDefaults.DispatchConfig.Request(name: "", method: .get, url: "")]
                draft.dispatch = dispatch
            }
        }
    }

    private var mcpEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array((draft.mcp?.presets ?? []).indices), id: \.self) { index in
                let preset = presetBinding(at: index)
                editorCard {
                    HStack(alignment: .top, spacing: 10) {
                        SiteConfigurationField(caption: "NAME",
                                               placeholder: "service-environment",
                                               text: preset.name)
                        SiteConfigurationField(caption: "LABEL",
                                               placeholder: "Service environment",
                                               text: optional(preset.title))
                        removeButton { draft.mcp?.presets?.remove(at: index) }
                    }
                    HStack(alignment: .top, spacing: 10) {
                        SiteConfigurationField(caption: "SERVER TYPE",
                                               placeholder: "Grafana",
                                               text: optional(preset.serverType))
                        SiteConfigurationField(caption: "ENVIRONMENT",
                                               placeholder: "production",
                                               text: optional(preset.environment))
                        VStack(alignment: .leading, spacing: 6) {
                            Caption(text: "TRANSPORT")
                            HStack(spacing: 4) {
                                ChoicePill(title: "stdio", selected: !preset.wrappedValue.isRemote) {
                                    preset.command.wrappedValue = preset.wrappedValue.command ?? ""
                                    preset.url.wrappedValue = nil
                                    preset.type.wrappedValue = nil
                                }
                                ChoicePill(title: "remote", selected: preset.wrappedValue.isRemote) {
                                    preset.command.wrappedValue = nil
                                    preset.args.wrappedValue = nil
                                    preset.url.wrappedValue = preset.wrappedValue.url ?? ""
                                    preset.type.wrappedValue = preset.wrappedValue.type ?? "http"
                                }
                            }
                            .frame(height: 34)
                        }
                    }
                    if preset.wrappedValue.isRemote {
                        HStack(alignment: .top, spacing: 10) {
                            SiteConfigurationField(caption: "URL",
                                                   placeholder: "https://mcp.example/mcp",
                                                   text: optional(preset.url))
                            OptionMenu(caption: "TYPE",
                                       value: preset.wrappedValue.type ?? "http",
                                       options: ["http", "sse"].map { type in
                                           (type, preset.wrappedValue.type == type,
                                            { preset.type.wrappedValue = type })
                                       })
                        }
                    } else {
                        SiteConfigurationField(caption: "COMMAND",
                                               placeholder: "mcp-server",
                                               text: optional(preset.command))
                        SiteConfigurationTextArea(caption: "ARGUMENTS - ONE PER LINE",
                                                  placeholder: "--flag\nvalue",
                                                  text: arguments(preset))
                    }
                    presetValuesEditor("ENVIRONMENT VARIABLES", at: index, keyPath: \.env)
                    presetValuesEditor("HEADERS", at: index, keyPath: \.headers)
                }
            }
            addButton("Add MCP preset") {
                let environment = draft.deployEnvironments.first?.name ?? ""
                var mcp = draft.mcp ?? SiteDefaults.MCP()
                mcp.presets = (mcp.presets ?? [])
                    + [SiteDefaults.MCP.Preset(name: "",
                                               environment: environment,
                                               command: "")]
                draft.mcp = mcp
            }
        }
    }

    @ViewBuilder private func presetValuesEditor(
        _ title: String,
        at presetIndex: Int,
        keyPath: WritableKeyPath<SiteDefaults.MCP.Preset, [SiteDefaults.MCP.Value]?>
    ) -> some View {
        let values = draft.mcp?.presets?[presetIndex][keyPath: keyPath] ?? []
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(title)
                Spacer()
                Button {
                    var preset = draft.mcp?.presets?[presetIndex]
                        ?? SiteDefaults.MCP.Preset(name: "")
                    var entries = preset[keyPath: keyPath] ?? []
                    entries.append(.init(key: "", value: ""))
                    preset[keyPath: keyPath] = entries
                    draft.mcp?.presets?[presetIndex] = preset
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            ForEach(Array(values.indices), id: \.self) { valueIndex in
                let value = presetValueBinding(at: presetIndex,
                                               keyPath: keyPath,
                                               valueIndex: valueIndex)
                HStack(alignment: .top, spacing: 8) {
                    SiteConfigurationField(caption: "KEY",
                                           placeholder: title == "HEADERS"
                                            ? "Authorization" : "SERVICE_TOKEN",
                                           text: value.key)
                    SiteConfigurationField(caption: "VALUE - LEAVE EMPTY TO PROMPT",
                                           placeholder: "Filled in when added",
                                           text: value.value)
                    removeButton {
                        var preset = draft.mcp?.presets?[presetIndex]
                            ?? SiteDefaults.MCP.Preset(name: "")
                        preset[keyPath: keyPath]?.remove(at: valueIndex)
                        draft.mcp?.presets?[presetIndex] = preset
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    private var skillsEditor: some View {
        editorCard {
            Toggle("Configure a skills marketplace", isOn: skillsEnabled)
                .toggleStyle(.appSwitch)
                .font(.system(size: 12.5, weight: .semibold))
            if skillsEnabled.wrappedValue {
                VStack(alignment: .leading, spacing: 6) {
                    Caption(text: "SOURCE")
                    HStack(spacing: 6) {
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
                HStack(alignment: .bottom, spacing: 8) {
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
                                     height: 34,
                                     icon: "folder",
                                     action: chooseSkillsFile)
                    }
                }
            }
        }
    }

    private var shortcutsEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array((draft.shortcuts ?? []).indices), id: \.self) { index in
                let shortcut = shortcutBinding(at: index)
                editorCard {
                    HStack(alignment: .top, spacing: 10) {
                        SiteConfigurationField(caption: "NAME",
                                               placeholder: "Run service",
                                               text: shortcut.name)
                        removeButton { draft.shortcuts?.remove(at: index) }
                    }
                    SiteConfigurationField(caption: "COMMAND",
                                           placeholder: "./gradlew bootRun",
                                           text: shortcut.command)
                }
            }
            addButton("Add shortcut") {
                draft.shortcuts?.append(SiteDefaults.Shortcut(name: "", command: ""))
            }
        }
    }

    private func editorCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
    }

    private func addButton(_ title: String, action: @escaping () -> Void) -> some View {
        ActionButton(title: title, tone: .outlined, icon: "plus", action: action)
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.deletion)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.deletion.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.deletion.opacity(0.2)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 17)
    }

    private func methodMenu(_ method: Binding<HTTPMethod?>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Caption(text: "METHOD")
            ActionButton(title: (method.wrappedValue ?? .get).rawValue,
                         tone: .sunken,
                         height: 34,
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
                callbackURL: "http://127.0.0.1:8234/callback")) : nil
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
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "Choose"
        panel.message = "Choose the skills marketplace JSON file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var skills = draft.skills
            ?? SiteDefaults.Skills(name: "", marketplace: "", repository: "")
        skills.sourceKind = .localFile
        skills.repository = url.path
        draft.skills = skills
    }

    private func environmentBinding(at index: Int) -> Binding<SiteDefaults.Environment> {
        Binding(get: { draft.environments?[index] ?? SiteDefaults.Environment(name: "") },
                set: { draft.environments?[index] = $0 })
    }

    private func requestBinding(at index: Int) -> Binding<SiteDefaults.DispatchConfig.Request> {
        Binding(get: {
            draft.dispatch?.requests?[index]
                ?? SiteDefaults.DispatchConfig.Request(name: "", url: "")
        }, set: { draft.dispatch?.requests?[index] = $0 })
    }

    private func presetBinding(at index: Int) -> Binding<SiteDefaults.MCP.Preset> {
        Binding(get: {
            draft.mcp?.presets?[index] ?? SiteDefaults.MCP.Preset(name: "")
        }, set: { draft.mcp?.presets?[index] = $0 })
    }

    private func presetValueBinding(
        at presetIndex: Int,
        keyPath: WritableKeyPath<SiteDefaults.MCP.Preset, [SiteDefaults.MCP.Value]?>,
        valueIndex: Int
    ) -> Binding<SiteDefaults.MCP.Value> {
        Binding(get: {
            draft.mcp?.presets?[presetIndex][keyPath: keyPath]?[valueIndex]
                ?? SiteDefaults.MCP.Value(key: "", value: "")
        }, set: { value in
            draft.mcp?.presets?[presetIndex][keyPath: keyPath]?[valueIndex] = value
        })
    }

    private func arguments(_ preset: Binding<SiteDefaults.MCP.Preset>) -> Binding<String> {
        Binding(get: { (preset.wrappedValue.args ?? []).joined(separator: "\n") },
                set: { value in
                    preset.args.wrappedValue = value.components(separatedBy: .newlines)
                        .map(\.trimmed)
                        .filter { !$0.isEmpty }
                })
    }

    private func shortcutBinding(at index: Int) -> Binding<SiteDefaults.Shortcut> {
        Binding(get: { draft.shortcuts?[index] ?? SiteDefaults.Shortcut(name: "", command: "") },
                set: { draft.shortcuts?[index] = $0 })
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

private enum SiteConfigurationForm {
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
                SiteDefaults.Shortcut(name: $0.name.trimmed, command: $0.command.trimmed)
            }
            guard shortcuts.allSatisfy({ !$0.name.isEmpty && !$0.command.isEmpty }) else {
                throw ImportError("Every shortcut needs a name and command.")
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
        VStack(alignment: .leading, spacing: 6) {
            Caption(text: caption)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.mono(11))
                .padding(.horizontal, 11)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SiteConfigurationTextArea: View {
    let caption: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Caption(text: caption)
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.mono(11))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(.mono(11))
                    .scrollContentBackground(.hidden)
                    .padding(2)
            }
            .frame(height: 64)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SiteConfigurationJSONView: View {
    @Environment(\.dismiss) private var dismiss
    let defaults: SiteDefaults

    @State private var copied = false
    @State private var failure: String?

    private var data: Data? { try? SiteConfigurationImporter.configurationData(for: defaults) }
    private var text: String { data.map { String(decoding: $0, as: UTF8.self) } ?? "{}\n" }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Current configuration JSON").font(.serif(16))
                Text("This read-only view is generated from the current settings and is safe to export as a reset file.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .headerBand()

            VStack(alignment: .leading, spacing: 10) {
                ScrollView {
                    Text(text)
                        .font(.mono(11.5))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .frame(height: 440)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))

                if let failure {
                    Text(failure)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.deletion)
                }
            }
            .padding(20)

            SheetFooter(dismiss: { dismiss() }) {
                HStack(spacing: 14) {
                    Button(copied ? "Copied" : "Copy JSON") { copy() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Button("Export…") { export() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .frame(width: 700)
        .background(Theme.background)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        failure = nil
    }

    private func export() {
        guard let data else {
            failure = "The current configuration could not be encoded."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "site-configuration.json"
        panel.prompt = "Export"
        panel.message = "Export the current Code Station configuration."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            failure = nil
        } catch {
            failure = "The configuration could not be exported: \(error.localizedDescription)"
        }
    }
}
