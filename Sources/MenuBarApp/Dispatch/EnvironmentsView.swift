import SwiftUI

// The OAuth setup that can differ between configured environments. The requests are
// shared; this sheet holds what a send in each environment signs in with.
struct EnvironmentsView: View {
    @Environment(DispatchAuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    // Nil until a tab is clicked, so the sheet opens on whichever environment the
    // Dispatch sheet behind it is using.
    @State private var selected: ApiEnvironment?
    private var shown: ApiEnvironment { selected ?? auth.active }

    // Edits land in a draft per environment and only reach the store on Save, so a
    // half-typed credential is never what a send signs in with. Switching tabs keeps
    // every draft.
    @State private var drafts: [ApiEnvironment: OAuthConfig] = [:]

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(shown.brightAccent).frame(height: 5)
            header
            Divider().overlay(Theme.hairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    tabs
                    envRow

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
                    EnvironmentTokenControls(env: shown, beforeAuthenticate: save)

                    Text("Every environment holds the same fields; only the values differ. Switching re-authenticates against that environment's setup and re-resolves every {{env}} in the request list.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }

            SheetFooter(primary: SheetAction(title: "Save", enabled: hasChanges,
                                             shortcut: KeyboardShortcut("s", modifiers: .command),
                                             action: save),
                        dismiss: { dismiss() }) {
                Text(hasChanges
                     ? "Unsaved changes. Cancel leaves without keeping them."
                     : "Secrets are stored in the Keychain, never in the request file.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 560, height: 640)
        .background(Theme.background)
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
            drafts[env].map { $0 != auth.config(for: env) } ?? false
        }
    }

    private func save() {
        for env in auth.environments {
            if let draft = drafts[env], draft != auth.config(for: env) {
                auth.setConfig(draft, for: env)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Environments").font(.serif(16))
            Text("One set of requests, with separate credentials for every configured environment. The switch at the top of Dispatch picks which one a send uses.")
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
        EnvironmentPills(environments: auth.environments, selected: shown, showsNames: true) {
            selected = $0
        }
        .fixedSize(horizontal: true, vertical: false)
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
            Text("use it anywhere in a URL")
                .font(.system(size: 12))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .surface(shown.brightAccent.opacity(0.10), cornerRadius: 9, border: shown.accent.opacity(0.22))
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
    var beforeAuthenticate: (() -> Void)?

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
                    beforeAuthenticate?()
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
