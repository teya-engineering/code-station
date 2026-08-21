import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SiteConfigurationSection: View {
    @Environment(DispatchStore.self) private var dispatch
    @Environment(DispatchAuthStore.self) private var dispatchAuth
    @Environment(ShortcutStore.self) private var shortcuts

    @State private var loaded = SiteDefaults.current
    @State private var pending: SiteConfigurationSelection?
    @State private var chosen: Set<SiteConfigurationAspect> = []
    @State private var repositoryURL = ""
    @State private var loading = false
    @State private var failure: String?
    @State private var editor: SiteConfigurationAspect?
    @State private var showingJSON = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            configuration
            reset
        }
        .sheet(item: $editor) { aspect in
            SiteConfigurationEditorView(aspect: aspect, defaults: loaded) { defaults in
                apply(defaults, changed: [aspect])
            }
            .appOverlays()
        }
        .sheet(isPresented: $showingJSON) {
            SiteConfigurationJSONView(defaults: loaded).appOverlays()
        }
        .onAppear { loaded = currentConfiguration() }
    }

    private var configuration: some View {
        ChoiceBlock("CONFIGURATION",
                    note: "These values are saved to one current configuration file. The JSON view is read-only and always generated from the settings shown here.") {
            VStack(spacing: 0) {
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
                .padding(12)

                Divider().overlay(Theme.border)

                ForEach(SiteConfigurationAspect.allCases) { aspect in
                    configurationRow(aspect)
                    if aspect != SiteConfigurationAspect.allCases.last {
                        Divider().overlay(Theme.border).padding(.leading, 48)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
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
            ActionButton(title: "Configure", tone: .sunken, height: 28, size: 11.5) {
                editor = aspect
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private func currentDetail(for aspect: SiteConfigurationAspect) -> String {
        switch aspect {
        case .environments:
            let count = loaded.deployEnvironments.count
            return count == 1 ? "1 environment" : "\(count) environments"
        case .apiAccess:
            guard loaded.dispatch?.oauth != nil || loaded.dispatch?.environments != nil else {
                return "Not configured"
            }
            return aspect.detail(in: loaded)
        case .requests:
            return aspect.detail(in: loaded)
        case .grafana:
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
            VStack(alignment: .leading, spacing: 10) {
                sources
                if let pending { preview(pending) }
                if let failure { warning(failure) }
                if let loadFailure = loaded.loadFailure { warning(loadFailure) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
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
                    .opacity(chosen.isEmpty ? 0.5 : 1)
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
        if changed.contains(.apiAccess) { dispatchAuth.resetSiteAccess(to: defaults) }
        if changed.contains(.shortcuts) { shortcuts.resetSiteShortcuts(to: defaults) }
        if changed.contains(.skills) { Preferences.skillsMarketplace = nil }
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

        if let marketplace = Preferences.skillsMarketplace, marketplace.isValid {
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

            SheetFooter(save: SheetSave(enabled: draft != saved, action: save),
                        done: { dismiss() }) {
                if let failure {
                    Text(failure)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.deletion)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(draft == saved
                         ? "Changes are written to the current configuration file."
                         : "Unsaved changes. Done leaves without keeping them.")
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
            "Name the deployments used to tag servers and scope troubleshooting."
        case .apiAccess:
            "Set the shared sign-in provider and the values used for {{env}}. Secrets stay in the Keychain."
        case .requests:
            "Keep the small set of API requests that a configured install should start with."
        case .grafana:
            "Define the Grafana instances that can be added as MCP servers."
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
        case .grafana: grafanaEditor
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
                        SiteConfigurationField(caption: "NAME",
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

            editorCard {
                Toggle("Configure API environment names", isOn: dispatchEnvironmentsEnabled)
                    .toggleStyle(.appSwitch)
                    .font(.system(size: 12.5, weight: .semibold))
                if dispatchEnvironmentsEnabled.wrappedValue {
                    HStack(alignment: .top, spacing: 10) {
                        SiteConfigurationField(caption: "STAGING {{env}}",
                                               placeholder: "dev",
                                               text: dispatchEnvironmentText(\.staging))
                        SiteConfigurationField(caption: "PRODUCTION {{env}}",
                                               placeholder: "prd",
                                               text: dispatchEnvironmentText(\.production))
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

    private var grafanaEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array((draft.grafana?.presets ?? []).indices), id: \.self) { index in
                let preset = presetBinding(at: index)
                editorCard {
                    HStack(alignment: .top, spacing: 10) {
                        SiteConfigurationField(caption: "SCOPE",
                                               placeholder: "platform",
                                               text: preset.scope)
                        SiteConfigurationField(caption: "ENVIRONMENT",
                                               placeholder: "production",
                                               text: preset.environment)
                        removeButton { draft.grafana?.presets?.remove(at: index) }
                    }
                    SiteConfigurationField(caption: "URL",
                                           placeholder: "https://grafana.example",
                                           text: preset.url)
                }
            }
            addButton("Add Grafana preset") {
                let environment = draft.deployEnvironments.first?.name ?? ""
                var grafana = draft.grafana ?? SiteDefaults.Grafana()
                grafana.presets = (grafana.presets ?? [])
                    + [SiteDefaults.Grafana.Preset(scope: "",
                                                   environment: environment,
                                                   url: "")]
                draft.grafana = grafana
            }
        }
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

    private var dispatchEnvironmentsEnabled: Binding<Bool> {
        Binding(get: { draft.dispatch?.environments != nil }, set: { enabled in
            var dispatch = draft.dispatch ?? SiteDefaults.DispatchConfig()
            dispatch.environments = enabled
                ? (dispatch.environments ?? SiteDefaults.DispatchConfig.Environments(
                    staging: "dev", production: "prd")) : nil
            draft.dispatch = dispatch
        })
    }

    private func dispatchEnvironmentText(
        _ keyPath: WritableKeyPath<SiteDefaults.DispatchConfig.Environments, String?>
    ) -> Binding<String> {
        Binding(get: { draft.dispatch?.environments?[keyPath: keyPath] ?? "" }, set: { value in
            var dispatch = draft.dispatch ?? SiteDefaults.DispatchConfig()
            var environments = dispatch.environments
                ?? SiteDefaults.DispatchConfig.Environments()
            environments[keyPath: keyPath] = value
            dispatch.environments = environments
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

    private func presetBinding(at index: Int) -> Binding<SiteDefaults.Grafana.Preset> {
        Binding(get: {
            draft.grafana?.presets?[index]
                ?? SiteDefaults.Grafana.Preset(scope: "", environment: "", url: "")
        }, set: { draft.grafana?.presets?[index] = $0 })
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
        case .grafana:
            if draft.grafana == nil { draft.grafana = SiteDefaults.Grafana(presets: []) }
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
            if var environments = result.dispatch?.environments {
                environments.staging = optional(environments.staging)
                environments.production = optional(environments.production)
                guard environments.staging != nil, environments.production != nil else {
                    throw ImportError("Both API environment names are required.")
                }
                result.dispatch?.environments = environments
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

        case .grafana:
            let presets = (result.grafana?.presets ?? []).map {
                SiteDefaults.Grafana.Preset(scope: $0.scope.trimmed,
                                            environment: $0.environment.trimmed,
                                            url: $0.url.trimmed)
            }
            guard presets.allSatisfy({
                !$0.scope.isEmpty && !$0.environment.isEmpty && !$0.url.isEmpty
            }) else {
                throw ImportError("Every Grafana preset needs a scope, environment, and URL.")
            }
            let names = presets.map(\.name)
            guard Set(names).count == names.count else {
                throw ImportError("Each Grafana scope and environment pair must be unique.")
            }
            result.grafana = SiteDefaults.Grafana(presets: presets)

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

    private static func removeEmptyDispatch(from defaults: inout SiteDefaults) {
        guard let dispatch = defaults.dispatch else { return }
        if dispatch.oauth == nil && dispatch.environments == nil && dispatch.requests == nil {
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

            SheetFooter(done: { dismiss() }) {
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
