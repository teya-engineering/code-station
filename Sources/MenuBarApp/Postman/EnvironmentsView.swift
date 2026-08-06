import SwiftUI

// The OAuth setup that differs between the two environments. The requests are shared;
// this sheet holds what a send in each environment signs in with.
struct EnvironmentsView: View {
    @Environment(PostmanAuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    // Nil until a tab is clicked, so the sheet opens on whichever environment the
    // Postman sheet behind it is using.
    @State private var selected: ApiEnvironment?
    private var shown: ApiEnvironment { selected ?? auth.active }

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
                        CaptionedField(caption: "AUTH URL",
                                       placeholder: "https://id.example/oauth/authorize",
                                       text: config.authURL)
                        CaptionedField(caption: "CALLBACK URL",
                                       placeholder: "http://127.0.0.1:8234/callback",
                                       text: config.callbackURL)
                        Text(config.wrappedValue.usesLoopback
                             ? "The browser is sent back here when you sign in, so the identity provider has to allow this exact URL for the client. If it refuses, put the callback it does allow here instead and paste the code back by hand."
                             : "This callback is not on your machine, so the browser cannot hand the code back on its own. Sign in, then paste the address the browser ends on.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    CaptionedField(caption: "ACCESS TOKEN URL",
                                   placeholder: "https://id.example/oauth/token",
                                   text: config.tokenURL)
                    CaptionedField(caption: "CLIENT ID",
                                   placeholder: "client id",
                                   text: config.clientID)
                    CaptionedField(caption: "CLIENT SECRET",
                                   placeholder: "kept in the Keychain, empty for a public client",
                                   text: config.clientSecret,
                                   accent: shown.accent,
                                   secret: true)
                    CaptionedField(caption: "SCOPE",
                                   placeholder: "space separated",
                                   text: config.scope)
                    if config.wrappedValue.grant.usesBrowser {
                        CaptionedField(caption: "STATE",
                                       placeholder: "generated when left blank",
                                       text: config.state)
                    }

                    CaptionedField(caption: "HEADER PREFIX",
                                   placeholder: "Bearer",
                                   text: config.headerPrefix)
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

                    EnvironmentTokenControls(env: shown)

                    Text("Both environments hold the same fields; only the values differ. Switching re-authenticates against that environment's setup and re-resolves every {{env}} in the request list.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }

            SheetFooter(done: { dismiss() }) {
                Text("Secrets are stored in the Keychain, never in the request file.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 560, height: 640)
        .background(Theme.background)
    }

    private var config: Binding<OAuthConfig> {
        let env = shown
        return Binding(
            get: { auth.config(for: env) },
            set: { auth.setConfig($0, for: env) })
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Environments").font(.serif(16))
            Text("Two sets of credentials, one set of requests. The switch at the top of Postman picks which one a send uses.")
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
        HStack(spacing: 6) {
            ForEach(ApiEnvironment.allCases) { env in
                Button {
                    selected = env
                } label: {
                    HStack(spacing: 6) {
                        Text(env.label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(env == shown ? Color.white : Color.primary)
                        Text(env.envValue)
                            .font(.mono(10, .medium))
                            .foregroundStyle(env == shown ? Color.white.opacity(0.72) : Color.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 9)
                        .fill(env == shown ? env.accent : Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 9)
                        .stroke(env == shown ? .clear : Theme.border))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
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
            Text(shown.envValue)
                .font(.mono(12, .bold))
                .foregroundStyle(shown.accent)
            Spacer()
            Text("use it anywhere in a URL")
                .font(.system(size: 12))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 9).fill(shown.brightAccent.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(shown.accent.opacity(0.22)))
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

// A caption over a one-of-a-set choice, opened as the app's own menu.
private struct OptionMenu: View {
    let caption: String
    let value: String
    let options: [(label: String, checked: Bool, choose: () -> Void)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Caption(text: caption)
            HStack(spacing: 8) {
                Text(value)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
            .contentShape(Rectangle())
            .appMenu {
                options.map { option in
                    .item(option.label, checked: option.checked, action: option.choose)
                }
            }
        }
    }
}

// The token an environment currently holds, with everything needed to get a new one:
// the sign-in button, cancelling, and the paste-back for a callback that is not ours.
// Shown in the Environments sheet and on a request's Auth tab, so both say the same thing.
struct EnvironmentTokenControls: View {
    let env: ApiEnvironment

    @Environment(PostmanAuthStore.self) private var auth

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
                Button("Clear") { auth.clearToken(for: env) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if auth.busy.contains(env) || auth.awaitingPaste.contains(env) {
                // Nothing tells the app that the browser tab was closed or that the
                // provider showed an error page, so calling it off has to be a button.
                Button("Cancel") { auth.cancelAuthentication(env) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.deletion)
            } else {
                Button {
                    auth.authenticate(env)
                } label: {
                    Text(buttonLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(env.accent))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
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
                    .textFieldStyle(.plain)
                    .font(.mono(11))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                    .onSubmit(finish)

                Button(action: finish) {
                    Text("Finish")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(env.accent))
                }
                .buttonStyle(.plain)
                .disabled(pasted.isEmpty || auth.busy.contains(env))
            }
        }
    }

    private func finish() {
        auth.submitRedirect(pasted, for: env)
        pasted = ""
    }
}

private struct Caption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.mono(10, .medium))
            .kerning(0.9)
            .foregroundStyle(.secondary)
    }
}

private struct CaptionedField: View {
    let caption: String
    let placeholder: String
    @Binding var text: String
    var accent: Color = Theme.accent
    var secret = false

    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Caption(text: caption)

            HStack(spacing: 8) {
                Group {
                    if secret && !revealed {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                    }
                }
                .textFieldStyle(.plain)
                .font(.mono(11))
                .lineLimit(1)

                if secret {
                    Button(revealed ? "Hide" : "Reveal") { revealed.toggle() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
        }
    }
}
