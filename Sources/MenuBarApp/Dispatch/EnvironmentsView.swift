import SwiftUI

// Requests stay shared while each environment keeps its own values and credentials.
struct EnvironmentsView: View {
    @Environment(DispatchAuthStore.self) private var auth
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(\.dismiss) private var dismiss

    // Nil until a tab is clicked, so the sheet opens on whichever environment the
    // Dispatch sheet behind it is using.
    @State private var parentSize: CGSize? = NSApp.keyWindow?.contentLayoutRect.size
    @State private var selected: ApiEnvironment?
    private var shown: ApiEnvironment { selected ?? auth.active }

    // Edits land in a draft per environment and only reach the store on Save, so a
    // half-typed credential is never what a send signs in with. Switching tabs keeps
    // every draft.
    @State private var propertiesSelected = true
    @State private var propertyDrafts: [ApiEnvironment: [EnvironmentProperty]] = [:]
    var previewRequest: SavedRequest? = nil
    @State private var drafts: [ApiEnvironment: OAuthConfig] = [:]

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(shown.brightAccent).frame(height: 5)
            header
            Divider().overlay(Theme.hairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    tabs
                    Text("Editing settings does not change the send environment.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack {
                        ChoicePill(title: "Properties", selected: propertiesSelected) { propertiesSelected = true }
                            .accessibilityAddTraits(propertiesSelected ? [.isSelected] : [])
                        ChoicePill(title: "Authentication", selected: !propertiesSelected) { propertiesSelected = false }
                            .accessibilityAddTraits(propertiesSelected ? [] : [.isSelected])
                    }
                    if propertiesSelected {
                        if sheetSize.width >= 980 {
                            HStack(alignment: .top, spacing: 20) {
                                VStack(alignment: .leading, spacing: 16) {
                                    propertiesEditor
                                    envRow
                                }
                                    .frame(maxWidth: .infinity)
                                requestPreview.frame(width: 320)
                            }
                        } else {
                            propertiesEditor
                            envRow
                            requestPreview
                        }
                    } else {
                        grantRow

                        if config.wrappedValue.grant.usesBrowser {
                            field("AUTH URL", "https://id.example/oauth/authorize", config.authURL)
                            field("CALLBACK URL", "http://127.0.0.1:8234/callback", config.callbackURL)
                            Text(config.wrappedValue.usesLoopback
                                 ? "The browser is sent back here when you sign in, so the identity provider has to allow this exact URL for the client. If it refuses, put the callback it does allow here instead and paste the code back by hand."
                                 : "This callback is not on your machine, so the browser cannot hand the code back on its own. Sign in, then paste the address the browser ends on.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        field("ACCESS TOKEN URL", "https://id.example/oauth/token", config.tokenURL)
                        field("CLIENT ID", "client id", config.clientID)
                        LabeledField("CLIENT SECRET") {
                            SecretField(placeholder: "kept in the Keychain, empty for a public client",
                                        text: config.clientSecret,
                                        accent: shown.accent)
                        }
                        field("SCOPE", "space separated", config.scope)
                        if config.wrappedValue.grant.usesBrowser {
                            field("STATE", "generated when left blank", config.state)
                        }

                        field("HEADER PREFIX", "Bearer", config.headerPrefix)
                            .frame(width: 220)

                        OptionMenu(caption: "CLIENT AUTHENTICATION",
                                   value: config.wrappedValue.clientAuth.label,
                                   options: ClientAuthentication.allCases.map { choice in
                                       (choice.label, choice == config.wrappedValue.clientAuth,
                                        { config.wrappedValue.clientAuth = choice })
                                   })
                        Text("How the app proves which OAuth client it is on the token call. This is not about your requests; they always send the token with the prefix above.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        // Signing in reads the stored config, so unsaved edits are saved
                        // first rather than silently signing in with the old values.
                        EnvironmentTokenControls(env: shown, beforeAuthenticate: {
                            guard removedProperties.isEmpty else { save(); return false }
                            return performSave()
                        })

                        Text("Every environment holds the same fields; only the values differ. Choose the send environment in Dispatch to use its saved setup and property values.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }

            SheetFooter(primary: SheetAction(title: "Save", enabled: hasChanges && validation == nil,
                                             shortcut: KeyboardShortcut("s", modifiers: .command),
                                             action: save),
                        dismiss: { dismiss() }) {
                VStack(alignment: .leading, spacing: 5) {
                    if let validation { Text(validation).foregroundStyle(Theme.deletion) }
                    if let error = auth.saveError { Text(error).foregroundStyle(Theme.deletion) }
                    InlineLink(title: "Discard changes", size: 11) { drafts = [:]; propertyDrafts = [:] }
                    Text(hasChanges
                         ? "Unsaved changes. Cancel leaves without keeping them."
                         : "Secrets are stored in the Keychain, never in the request file.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }.font(.system(size: 11))
            }
        }
        .frame(width: sheetSize.width, height: sheetSize.height)
        .background(Theme.background)
        .background(ParentWindowSize(size: $parentSize))
    }

    private func field(_ label: String, _ placeholder: String,
                       _ text: Binding<String>) -> some View {
        LabeledField(label) {
            TextField(placeholder, text: text)
                .appTextField(size: 11)
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
        VStack(alignment: .leading, spacing: 4) {
            Text("Environments").font(.serif(16))
            Text("One set of requests, with separate properties and credentials for every configured environment. The switch at the top of Dispatch picks which one a send uses.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Theme.card)
    }

    private var tabs: some View {
        EnvironmentPills(environments: auth.environments, selected: shown, wraps: true) {
            selected = $0
        }
    }

    private var envRow: some View {
        HStack(spacing: 6) {
            Text("{{env}}")
                .font(.mono(12, .bold))
                .foregroundStyle(shown.accent)
            Text("resolves to")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(shown.name)
                .font(.mono(12, .bold))
                .foregroundStyle(shown.accent)
            Spacer()
            Text("Built-in · read only")
                .font(.system(size: 12))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .surface(shown.brightAccent.opacity(0.10), cornerRadius: 9, border: shown.accent.opacity(0.22))
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Environment properties").font(.serif(18))
                    Text("Use a property as {{property_name}}.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                InlineLink(title: "+ Add property") { rows.wrappedValue.append(EnvironmentProperty()) }
            }
            if rows.wrappedValue.isEmpty {
                Text("No properties yet. Add a value for this environment to reuse in your requests.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                HStack(alignment: .top, spacing: 10) {
                    LabeledField("NAME") {
                        TextField("property_name", text: row.name).appTextField(size: 11)
                            .accessibilityLabel("Property name")
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
                        .padding(.top, 23)
                    InlineLink(title: "×", tint: Theme.deletion) {
                        rows.wrappedValue.removeAll { $0.id == row.wrappedValue.id }
                    }
                    .accessibilityLabel("Remove \(row.wrappedValue.name)")
                    .padding(.top, 23)
                }
            }
            Text("Values stay on this Mac; secrets use the Keychain. Empty values are missing, with no fallback to another environment.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var requestPreview: some View {
        let request = previewRequest ?? SavedRequest(name: "Example", url: "{{base_url}}/merchants/{{merchant_id}}")
        let resolved = DispatchRunner.resolve(request, environment: shown, authorization: nil,
                                              properties: rows.wrappedValue, masked: true)
        return VStack(alignment: .leading, spacing: 10) {
            Text("See it in a request").font(.serif(18))
            Text("Preview uses your draft values. Nothing is sent.").font(.system(size: 11)).foregroundStyle(.secondary)
            Text("\(request.method.rawValue) \(request.name)").font(.mono(11, .bold))
            Text(request.url).font(.mono(11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10).fieldSurface(cornerRadius: 8)
            Text("RESOLVED URL").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(resolved.url).font(.mono(11)).textSelection(.enabled)
            ForEach(resolved.headers) { header in
                Text("\(header.key): \(header.value)").font(.mono(11))
            }
            if let body = resolved.body { Text(body).font(.mono(11)).textSelection(.enabled) }
            Text(resolved.problems.isEmpty ? "All properties resolve in \(shown.label)." : resolved.problems.joined(separator: "\n"))
                .font(.system(size: 12))
                .foregroundStyle(resolved.problems.isEmpty ? shown.accent : Theme.deletion)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16).cardSurface(cornerRadius: 12)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            tokenRow
            if auth.awaitingPaste.contains(env) { paste }
            if let failure = auth.failures[env] {
                Text(failure)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.deletion)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var tokenRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(auth.isAuthenticated(for: env) ? env.brightAccent : Theme.dotOff)
                .frame(width: 7, height: 7)
            Text(auth.tokenStatus(for: env))
                .font(.system(size: 12, weight: .medium))

            if auth.tokens[env] != nil, !auth.busy.contains(env) {
                InlineLink(title: "Clear", size: 11, tint: .secondary) { auth.clearToken(for: env) }
            }

            Spacer()

            if auth.busy.contains(env) || auth.awaitingPaste.contains(env) {
                // Nothing tells the app that the browser tab was closed or that the
                // provider showed an error page, so calling it off has to be a button.
                InlineLink(title: "Cancel", size: 11, tint: Theme.deletion) {
                    auth.cancelAuthentication(env)
                }
            } else {
                ActionButton(title: buttonLabel, tone: env.buttonTone, height: 28, size: 11) {
                    guard beforeAuthenticate?() ?? true else { return }
                    auth.authenticate(env)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .cardSurface(cornerRadius: 9)
    }

    private var buttonLabel: String {
        if auth.config(for: env).grant.usesBrowser {
            return auth.tokens[env] == nil ? "Sign in" : "Sign in again"
        }
        return "Fetch token"
    }

    private var paste: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sign in in the browser, then paste the address it ends on. The code is in that URL, and the page itself can look like an error.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("https://…/callback?code=…", text: $pasted)
                    .lineLimit(1)
                    .appTextField(size: 11)
                    .onSubmit(finish)

                ActionButton(title: "Finish", tone: env.buttonTone, height: 30, size: 12, action: finish)
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
        HStack(spacing: 8) {
            Group {
                if revealed {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .lineLimit(1)

            InlineLink(title: revealed ? "Hide" : "Reveal", size: 11, tint: accent) {
                revealed.toggle()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .fieldSurface(cornerRadius: 8)
    }
}
