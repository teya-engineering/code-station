import SwiftUI

// Requests stay shared while each environment keeps its own values and credentials.
struct EnvironmentsView: View {
    @Environment(DispatchAuthStore.self) private var auth
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(\.dismiss) private var dismiss

    // Nil until an environment is chosen, so the sheet opens on whichever environment the
    // Dispatch sheet behind it is using.
    @State private var parentSize: CGSize? = NSApp.keyWindow?.contentLayoutRect.size
    @State private var selected: ApiEnvironment?
    private var shown: ApiEnvironment { selected ?? auth.active }

    // Edits land in a draft per environment and only reach the store on Save, so a
    // half-typed credential is never what a send signs in with. Switching environments keeps
    // every draft.
    @State private var propertiesSelected = true
    @State private var previewExpanded = true
    @FocusState private var focusedTab: Bool?
    @State private var hoveredTab: Bool?
    @FocusState private var focusedEnvironment: String?
    @State private var hoveredEnvironment: String?
    @FocusState private var previewFocused: Bool
    @FocusState private var focusedProperty: UUID?
    @Namespace private var tabPanels
    @State private var propertyDrafts: [ApiEnvironment: [EnvironmentProperty]] = [:]
    var previewRequest: SavedRequest? = nil
    @State private var drafts: [ApiEnvironment: OAuthConfig] = [:]

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(shown.brightAccent).frame(height: 5)
            header
            Divider().overlay(Theme.hairline)

            HStack(spacing: 0) {
                if !compact {
                    environmentSidebar
                    Divider().overlay(Theme.hairline)
                }
                VStack(alignment: .leading, spacing: 0) {
                    if compact {
                        OptionMenu(caption: "EDIT ENVIRONMENT", value: shown.label,
                                   options: auth.environments.map { env in
                                       (env.label, env == shown, { selected = env })
                                   })
                            .padding(.bottom, Space.lg)
                        sendEnvironmentNote.padding(.bottom, Space.xl)
                    }
                    if !compact {
                        contentHeading
                        sectionTabs.padding(.top, Space.xxl)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if compact {
                                contentHeading
                                sectionTabs.padding(.top, Space.xxl)
                            }
                            settingsPanel
                        }
                    }
                }
                .padding(.horizontal, compact ? 20 : 28)
                .padding(.top, Space.xxxl)
            }

            SheetFooter(primary: SheetAction(title: "Save changes", enabled: hasChanges && validation == nil,
                                             shortcut: KeyboardShortcut("s", modifiers: .command),
                                             action: save),
                        dismissTitle: hasChanges ? "Cancel" : "Close",
                        dismiss: { dismiss() }) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    if let validation { Text(validation).foregroundStyle(Theme.deletion) }
                    if let error = auth.saveError { Text(error).foregroundStyle(Theme.deletion) }
                    if hasChanges {
                        InlineLink(title: "Discard changes", size: Typography.Size.caption) { drafts = [:]; propertyDrafts = [:] }
                    }
                    Text(hasChanges
                         ? "Unsaved changes. Cancel leaves without keeping them."
                         : "Secrets are stored in the Keychain, never in the request file.")
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                }.font(Typography.caption)
            }
            .motion(Motion.control, value: hasChanges)
        }
        .frame(width: sheetSize.width, height: sheetSize.height)
        .background(Theme.background)
        .background(ParentWindowSize(size: $parentSize))
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            if propertiesSelected {
                Group {
                    propertiesEditor
                    envRow
                    previewSection
                }
                .transition(AnyTransition.fadeIn.animation(Motion.reveal))
            } else {
                authenticationEditor
                    .transition(AnyTransition.fadeIn.animation(Motion.reveal))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Space.xxl)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(shown.label) \(propertiesSelected ? "Properties" : "Authentication")")
        .accessibilityLabeledPair(role: .content, id: propertiesSelected, in: tabPanels)
    }

    private func field(_ label: String, _ placeholder: String,
                       _ text: Binding<String>) -> some View {
        LabeledField(label) {
            TextField(placeholder, text: text)
                .appTextField(size: 11)
                .accessibilityLabel(label)
        }
    }

    private var config: Binding<OAuthConfig> {
        let env = shown
        return Binding(
            get: { drafts[env] ?? auth.config(for: env) },
            set: { drafts[env] = $0 })
    }

    private var hasChanges: Bool {
        auth.environments.contains { env in
            (drafts[env].map { $0 != auth.config(for: env) } ?? false)
                || (propertyDrafts[env].map { $0 != auth.properties(for: env) } ?? false)
        }
    }

    private var sheetSize: CGSize {
        CGSize(width: min(1100, max(480, (parentSize?.width ?? 808) - 48)),
               height: min(760, max(420, (parentSize?.height ?? 756) - 36)))
    }

    private var removedProperties: [Dialog.Impact.Row] {
        auth.environments.flatMap { env in
            guard let draft = propertyDrafts[env] else { return [Dialog.Impact.Row]() }
            return auth.properties(for: env).filter { saved in !draft.contains { $0.id == saved.id } }.map {
                Dialog.Impact.Row(title: "\($0.name) in \(env.label)", detail: "Property and its stored value")
            }
        }
    }

    private func save() {
        guard validation == nil else { return }
        guard removedProperties.isEmpty else {
            dialogs.show(.impact("Remove saved properties?",
                                 rows: removedProperties + [
                                    .init(title: "Requests and remaining settings", detail: "Kept in every environment", kept: true)
                                 ],
                                 warning: "Removed values cannot be restored after saving. Requests using them will need another value.",
                                 action: "Save changes") { _ = performSave() })
            return
        }
        _ = performSave()
    }

    private func performSave() -> Bool {
        guard validation == nil else { return false }
        guard auth.setProperties(propertyDrafts, configurations: drafts) else { return false }
        drafts = [:]
        propertyDrafts = [:]
        return true
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Environments").font(Typography.title)
            Text("Manage properties and credentials for your requests.")
                .font(Typography.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.xxl)
        .padding(.vertical, Space.lg)
        .background(Theme.card)
    }

    private var compact: Bool { sheetSize.width < 700 }

    private var environmentSidebar: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            Text("Environments").font(Typography.detail).foregroundStyle(.secondary)
                .padding(.horizontal, Space.lg)
            ScrollView {
                VStack(spacing: Space.xxs) {
                    ForEach(auth.environments) { env in
                        Button { selected = env } label: {
                            HStack(spacing: Space.md) {
                                Circle().fill(env.brightAccent).frame(width: 6, height: 6)
                                Text(env.label)
                                    .font(Typography.body.weight(env == shown ? .semibold : .medium))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(env == shown ? env.accent : Color.primary)
                            .padding(.horizontal, Space.lg)
                            .frame(height: 34)
                            .background(env == shown ? env.accent.opacity(0.09)
                                        : hoveredEnvironment == env.name ? Theme.field : .clear,
                                        in: RoundedRectangle(cornerRadius: Radius.inset))
                            .contentShape(Rectangle())
                            .motion(Motion.hover, value: hoveredEnvironment == env.name)
                            .motion(Motion.control, value: env == shown)
                        }
                        .buttonStyle(.plain)
                        .focusable()
                        .focused($focusedEnvironment, equals: env.name)
                        .focusEffectDisabled()
                        .overlay(RoundedRectangle(cornerRadius: Radius.inset)
                            .stroke(focusedEnvironment == env.name ? Theme.accent : .clear, lineWidth: 2))
                        .onKeyPress(keys: [.space, .return]) { _ in selected = env; return .handled }
                        .accessibilityAddTraits(env == shown ? [.isSelected] : [])
                        .accessibilityLabel(env.label + (env.isDangerous ? ", live environment" : ""))
                        .onPointerHover { hoveredEnvironment = $0 ? env.name : nil }
                        .help(env.label)
                    }
                }.padding(Space.xxs)
            }
            Divider().overlay(Theme.hairline)
            sendEnvironmentNote.padding(.horizontal, Space.lg)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.xxxl)
        .frame(width: sheetSize.width < 850 ? 150 : 190)
        .background(Theme.sidebar)
    }

    private var sendEnvironmentNote: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Dispatch sends to \(auth.active.label)")
                .font(Typography.detail.weight(.medium))
            Text("Choosing an environment here only changes what you edit.")
                .font(Typography.detail).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var contentHeading: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.lg) {
                Text(shown.label).font(Typography.display)
                Text(shown.name).font(Typography.code).foregroundStyle(.secondary)
                    .padding(.horizontal, Space.md).padding(.vertical, Space.xs)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: Radius.inset))
            }
            Text("Properties and credentials used by requests sent to \(shown.label).")
                .font(Typography.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // Each label's side padding hangs into the gutter, so the first label still lines up
    // with the heading above it.
    private var sectionTabs: some View {
        HStack(spacing: Space.sm) {
            sectionTab("Properties", properties: true)
            sectionTab("Authentication", properties: false)
            Spacer(minLength: 0)
        }
        .background(alignment: .bottom) { Theme.border.frame(height: 1).padding(.leading, Space.md) }
        .padding(.leading, -10)
        .motion(Motion.control, value: propertiesSelected)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Environment settings tabs")
    }

    private func sectionTab(_ title: String, properties: Bool) -> some View {
        let selected = propertiesSelected == properties
        return Button { propertiesSelected = properties } label: {
            Text(title)
                .font(Typography.body.weight(.semibold))
                .foregroundStyle(selected ? Theme.accent : hoveredTab == properties ? Color.primary : Color.secondary)
                .frame(height: 46)
                .overlay(alignment: .bottom) {
                    if selected {
                        UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2)
                            .fill(Theme.accent)
                            .frame(height: 2)
                            .matchedGeometryEffect(id: "underline", in: tabPanels)
                    }
                }
                .padding(.horizontal, Space.md)
                .contentShape(Rectangle())
        }
        .buttonStyle(SectionTabStyle(selected: selected, hovered: hoveredTab == properties,
                                     showsFocus: focusedTab == properties
                                         && KeyboardFocusVisibility.shared.isVisible))
        .focusable()
        .focused($focusedTab, equals: properties)
        .focusEffectDisabled()
        .onPointerHover { hoveredTab = $0 ? properties : hoveredTab == properties ? nil : hoveredTab }
        .motion(Motion.hover, value: hoveredTab == properties)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .home, .end]) { press in
            propertiesSelected = press.key == .home ? true : press.key == .end ? false : !properties
            focusedTab = propertiesSelected
            return .handled
        }
        .onKeyPress(keys: [.space, .return]) { _ in propertiesSelected = properties; return .handled }
        .accessibilityLabel("\(title) tab")
        .accessibilityAddTraits(propertiesSelected == properties ? [.isSelected] : [])
        .accessibilityLabeledPair(role: .label, id: properties, in: tabPanels)
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Divider().overlay(Theme.hairline)
            Button { previewExpanded.toggle() } label: {
                HStack {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(previewExpanded ? 90 : 0))
                        .motion(Motion.control, value: previewExpanded)
                    Text("Preview in a request").fontWeight(.semibold)
                    Spacer()
                    Text("Nothing is sent").foregroundStyle(.secondary)
                }
                .font(Typography.detail)
                .padding(.vertical, Space.md)
                .contentShape(Rectangle())
                .hoverFill(cornerRadius: Radius.tag)
            }
            .buttonStyle(.plain)
            .focusable()
            .focused($previewFocused)
            .focusEffectDisabled()
            .overlay(RoundedRectangle(cornerRadius: Radius.tag)
                .stroke(previewFocused ? Theme.accent : .clear, lineWidth: 2))
            .onKeyPress(keys: [.space, .return]) { _ in previewExpanded.toggle(); return .handled }
            .accessibilityValue(previewExpanded ? "Expanded" : "Collapsed")
            if previewExpanded {
                requestPreview
                    .transition(.fold)
            }
        }
        .motion(Motion.reveal, value: previewExpanded)
    }

    private var authenticationEditor: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            grantRow

            if config.wrappedValue.grant.usesBrowser {
                field("AUTH URL", "https://id.example/oauth/authorize", config.authURL)
                field("CALLBACK URL", "http://localhost:8234/callback", config.callbackURL)
                Text(config.wrappedValue.usesLoopback
                     ? "The browser is sent back here when you sign in, so the identity provider has to allow this exact URL for the client. If it refuses, put the callback it does allow here instead and paste the code back by hand."
                     : "This callback is not on your machine, so the browser cannot hand the code back on its own. Sign in, then paste the address the browser ends on.")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            field("ACCESS TOKEN URL", "https://id.example/oauth/token", config.tokenURL)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.xl),
                                     count: sheetSize.width >= 850 ? 2 : 1),
                      alignment: .leading, spacing: Space.xl) {
                field("CLIENT ID", "client id", config.clientID)
                LabeledField("CLIENT SECRET") {
                    SecretField(placeholder: "kept in the Keychain, empty for a public client",
                                text: config.clientSecret,
                                accent: shown.accent)
                        .accessibilityLabel("Client secret")
                }
                field("SCOPE", "space separated", config.scope)
                field("HEADER PREFIX", "Bearer", config.headerPrefix)
            }
            if config.wrappedValue.grant.usesBrowser {
                field("STATE", "generated when left blank", config.state)
            }

            OptionMenu(caption: "CLIENT AUTHENTICATION",
                       value: config.wrappedValue.clientAuth.label,
                       options: ClientAuthentication.allCases.map { choice in
                           (choice.label, choice == config.wrappedValue.clientAuth,
                            { config.wrappedValue.clientAuth = choice })
                       })
            Text("How the app proves which OAuth client it is on the token call. This is not about your requests; they always send the token with the prefix above.")
                .font(Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Signing in reads the stored config, so unsaved edits are saved
            // first rather than silently signing in with the old values.
            EnvironmentTokenControls(env: shown, beforeAuthenticate: {
                guard removedProperties.isEmpty else { save(); return false }
                return performSave()
            })

            Text("Every environment holds the same fields; only the values differ. Choose the send environment in Dispatch to use its saved setup and property values.")
                .font(Typography.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var envRow: some View {
        HStack(spacing: Space.sm) {
            Text("{{env}}")
                .font(Typography.code.weight(.semibold))
                .foregroundStyle(shown.accent)
            Text("resolves to")
                .font(Typography.detail)
                .foregroundStyle(.secondary)
            Text(shown.name)
                .font(Typography.code.weight(.semibold))
                .foregroundStyle(shown.accent)
            Spacer()
            Text("Built-in · read only")
                .font(Typography.detail)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .surface(shown.brightAccent.opacity(0.10), cornerRadius: Radius.card, border: shown.accent.opacity(0.22))
    }

    private var rows: Binding<[EnvironmentProperty]> {
        let env = shown
        return Binding(get: { propertyDrafts[env] ?? auth.properties(for: env) },
                       set: { propertyDrafts[env] = $0 })
    }

    private var validation: String? {
        for env in auth.environments {
            if let problem = EnvironmentProperty.validation(propertyDrafts[env] ?? auth.properties(for: env)) {
                return "\(env.label): \(problem)"
            }
        }
        return nil
    }

    private var propertiesEditor: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack {
                Text("Use a property as {{property_name}}.")
                    .font(Typography.detail).foregroundStyle(.secondary)
                Spacer()
                InlineLink(title: "+ Add property") {
                    let property = EnvironmentProperty()
                    rows.wrappedValue.append(property)
                    focusedProperty = property.id
                }
            }
            if rows.wrappedValue.isEmpty {
                Text("No properties yet. Add a value for this environment to reuse in your requests.")
                    .font(Typography.detail).foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                HStack(alignment: .top, spacing: Space.md) {
                    LabeledField("NAME") {
                        TextField("property_name", text: row.name).appTextField(size: 11)
                            .accessibilityLabel("Property name")
                            .focused($focusedProperty, equals: row.wrappedValue.id)
                    }.frame(width: min(170, sheetSize.width * 0.24))
                    LabeledField("VALUE") {
                        if row.wrappedValue.isSecret {
                            SecretField(placeholder: "Set a value", text: row.value)
                                .accessibilityLabel("Value for \(row.wrappedValue.name)")
                        } else {
                            TextField("Set a value", text: row.value).appTextField(size: 11)
                                .accessibilityLabel("Value for \(row.wrappedValue.name)")
                        }
                    }
                    Toggle("Secret", isOn: row.isSecret).toggleStyle(.appCheckbox)
                        .accessibilityLabel("Secret storage for \(row.wrappedValue.name)")
                        .padding(.top, Space.xxxl)
                    InlineLink(title: "×", tint: Theme.deletion) {
                        rows.wrappedValue.removeAll { $0.id == row.wrappedValue.id }
                    }
                    .accessibilityLabel("Remove \(row.wrappedValue.name)")
                    .padding(.top, Space.xxxl)
                }
            }
            Text("Values stay on this Mac; secrets use the Keychain. Empty values are missing, with no fallback to another environment.")
                .font(Typography.caption).foregroundStyle(.secondary)
        }
    }

    private var requestPreview: some View {
        let request = previewRequest ?? SavedRequest(name: "Example", url: "{{base_url}}/merchants/{{merchant_id}}")
        let resolved = DispatchRunner.resolve(request, environment: shown, authorization: nil,
                                              properties: rows.wrappedValue, masked: true)
        return VStack(alignment: .leading, spacing: Space.md) {
            Text("Preview uses your draft values. Nothing is sent.").font(Typography.caption).foregroundStyle(.secondary)
            Text("\(request.method.rawValue) \(request.name)").font(Typography.data.weight(.semibold))
            Text(request.url).font(Typography.data).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.md).fieldSurface(cornerRadius: Radius.control)
            Text("RESOLVED URL").font(Typography.micro).foregroundStyle(.secondary)
            Text(resolved.url).font(Typography.data).textSelection(.enabled)
            ForEach(resolved.headers) { header in
                Text("\(header.key): \(header.value)").font(Typography.data)
            }
            if let body = resolved.body { Text(body).font(Typography.data).textSelection(.enabled) }
            Text(resolved.problems.isEmpty ? "All properties resolve in \(shown.label)." : resolved.problems.joined(separator: "\n"))
                .font(Typography.detail)
                .foregroundStyle(resolved.problems.isEmpty ? shown.accent : Theme.deletion)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.xl).cardSurface(cornerRadius: Radius.floating)
    }

    private var grantRow: some View {
        OptionMenu(caption: "GRANT TYPE",
                   value: config.wrappedValue.grant.label,
                   options: GrantType.allCases.map { grant in
                       (grant.label, grant == config.wrappedValue.grant,
                        { config.wrappedValue.grant = grant })
                   })
    }
}

// The token an environment currently holds, with everything needed to get a new one:
// the sign-in button, cancelling, and the paste-back for a callback that is not ours.
// Shown in the Environments sheet and on a request's Auth tab, so both say the same thing.
struct EnvironmentTokenControls: View {
    let env: ApiEnvironment
    // The Environments sheet edits a draft; this runs before a sign-in so the attempt
    // uses what is on screen, not what was last saved.
    var beforeAuthenticate: (() -> Bool)?

    @Environment(DispatchAuthStore.self) private var auth

    @State private var pasted = ""
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            tokenRow
            if revealed, let token = auth.tokens[env] { revealedToken(token.accessToken).transition(.fold) }
            if auth.awaitingPaste.contains(env) { paste }
            if let failure = auth.failures[env] {
                Text(failure)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.deletion)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .smoothlyResizes(when: revealed)
        // A token stays hidden until it is asked for again, so a fresh sign-in or another
        // environment does not put a secret on screen by itself.
        .onChange(of: env) { revealed = false }
        .onChange(of: auth.tokens[env] == nil) { revealed = false }
    }

    private var tokenRow: some View {
        HStack(spacing: Space.md) {
            Circle()
                .fill(auth.isAuthenticated(for: env) ? env.brightAccent : Theme.dotOff)
                .frame(width: 7, height: 7)
            Text(auth.tokenStatus(for: env))
                .font(Typography.detail.weight(.medium))
                .contentTransition(.interpolate)
                .motion(Motion.reveal, value: auth.tokenStatus(for: env))

            if auth.tokens[env] != nil, !auth.busy.contains(env) {
                InlineLink(title: revealed ? "Hide" : "Reveal", size: Typography.Size.caption, tint: env.accent) {
                    revealed.toggle()
                }
                InlineLink(title: "Clear", size: Typography.Size.caption, tint: .secondary) { auth.clearToken(for: env) }
            }

            Spacer()

            if auth.busy.contains(env) || auth.awaitingPaste.contains(env) {
                // Nothing tells the app that the browser tab was closed or that the
                // provider showed an error page, so calling it off has to be a button.
                InlineLink(title: "Cancel", size: Typography.Size.caption, tint: Theme.deletion) {
                    auth.cancelAuthentication(env)
                }
            } else {
                ActionButton(title: buttonLabel, tone: env.buttonTone, height: ControlHeight.md, size: Typography.Size.caption) {
                    guard beforeAuthenticate?() ?? true else { return }
                    auth.authenticate(env)
                }
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .cardSurface(cornerRadius: Radius.card)
    }

    private func revealedToken(_ token: String) -> some View {
        HStack(alignment: .top, spacing: Space.md) {
            Text(token)
                .font(Typography.data)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            CopyButton("Copy") { token }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.md)
        .fieldSurface(cornerRadius: Radius.control)
    }

    private var buttonLabel: String {
        if auth.config(for: env).grant.usesBrowser {
            return auth.tokens[env] == nil ? "Sign in" : "Sign in again"
        }
        return "Fetch token"
    }

    private var paste: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Sign in in the browser, then paste the address it ends on. The code is in that URL, and the page itself can look like an error.")
                .font(Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Space.md) {
                TextField("https://…/callback?code=…", text: $pasted)
                    .lineLimit(1)
                    .appTextField(size: 11)
                    .onSubmit(finish)

                ActionButton(title: "Finish", tone: env.buttonTone, height: ControlHeight.md, size: Typography.Size.detail, action: finish)
                    .disabled(pasted.isEmpty || auth.busy.contains(env))
            }
        }
    }

    private func finish() {
        auth.submitRedirect(pasted, for: env)
        pasted = ""
    }
}

// A field for a secret: hidden until asked for, so a shared screen does not give a
// password away, with the reveal sitting inside the field's own chrome.
struct SecretField: View {
    let placeholder: String
    @Binding var text: String
    var accent: Color = Theme.accent

    @State private var revealed = false

    var body: some View {
        HStack(spacing: Space.md) {
            Group {
                if revealed {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(Typography.caption)
            .lineLimit(1)

            InlineLink(title: revealed ? "Hide" : "Reveal", size: Typography.Size.caption, tint: accent) {
                revealed.toggle()
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.md)
        .fieldSurface(cornerRadius: Radius.control)
    }
}

// The hover, press and focus surface stops short of the row's bottom edge, so it never
// meets the underline of the selected tab.
private struct SectionTabStyle: ButtonStyle {
    let selected: Bool
    let hovered: Bool
    let showsFocus: Bool

    func makeBody(configuration: Configuration) -> some View {
        let surface = RoundedRectangle(cornerRadius: Radius.control)
        configuration.label
            .background {
                ZStack {
                    surface.fill(configuration.isPressed || (hovered && !selected) ? Theme.field : .clear)
                    if configuration.isPressed { surface.fill(Theme.field.opacity(0.7)) }
                    if showsFocus {
                        RoundedRectangle(cornerRadius: Radius.card)
                            .strokeBorder(Color(nsColor: Theme.focusRing), lineWidth: 3)
                            .padding(-3)
                        surface.strokeBorder(Theme.accent, lineWidth: 1)
                    }
                }
                .padding(.top, Space.sm)
                .padding(.bottom, Space.sm)
            }
            .motion(Motion.hover, value: configuration.isPressed)
            .motion(Motion.hover, value: showsFocus)
    }
}
