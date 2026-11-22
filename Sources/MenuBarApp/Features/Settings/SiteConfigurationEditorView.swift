import SwiftUI

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

struct SiteConfigurationEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let aspect: SiteConfigurationAspect
    let onSave: (SiteDefaults) -> Void

    @State private var draft: SiteDefaults
    @State private var saved: SiteDefaults
    @State private var failure: String?
    @State private var showsWhy = false

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
            SheetTitle(name: editorTitle, icon: aspect.icon) {
                WhyButton(label: "What this sets", isOpen: $showsWhy) {
                    Text(editorNote)
                        .font(Typography.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Space.pane)
            .headerBand()
            .zIndex(1)

            ScrollView {
                editor
                    .padding(Space.pane)
            }
            .frame(maxHeight: 560)

            SheetFooter(primary: SheetAction(title: "Save", enabled: draft != saved,
                                             shortcut: KeyboardShortcut("s", modifiers: .command),
                                             action: save),
                        dismiss: closeOrDismiss) {
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

    // Escape puts the explanation away before it closes the sheet.
    private func closeOrDismiss() {
        if showsWhy {
            showsWhy = false
        } else {
            dismiss()
        }
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
