import SwiftUI

// The collection's OAuth setup: what to sign in against, and the token that came back.
// Every request sends that token unless it opts out.
struct AuthorizationView: View {
    @Environment(PostmanAuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var revealed = false

    var body: some View {
        @Bindable var auth = auth

        VStack(spacing: 0) {
            HStack {
                Text("Authorization").font(.serif(16))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Theme.card)

            Divider().overlay(Theme.hairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    currentToken
                    Divider().overlay(Theme.hairline)
                    settings
                }
                .padding(20)
            }

            SheetFooter { dismiss() }
        }
        .frame(width: 620, height: 600)
        .background(Theme.background)
    }

    // MARK: - Token

    @ViewBuilder private var currentToken: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "CURRENT TOKEN")

            if let token = auth.token {
                HStack(spacing: 10) {
                    Text(revealed ? token.accessToken : String(repeating: "•", count: 28))
                        .font(.mono(11))
                        .lineLimit(revealed ? nil : 1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(revealed ? "Hide" : "Reveal") { revealed.toggle() }
                        .controlSize(.small)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(token.accessToken, forType: .string)
                    }
                    .controlSize(.small)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))

                HStack(spacing: 8) {
                    Text(token.isExpired ? "Expired" : token.expiryText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(expiryColour(token))
                    if let scope = token.scope, !scope.isEmpty {
                        Text("· \(scope)").font(.mono(11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if token.refreshToken != nil {
                        Button("Refresh") { Task { await auth.refresh() } }
                            .controlSize(.small)
                            .disabled(auth.busy || auth.tokenIsForOtherSettings)
                    }
                    Button("Clear") { auth.clearToken() }
                        .controlSize(.small)
                        .disabled(auth.busy)
                }

                // A token kept in the Keychain outlives the session that fetched it, so
                // one that turned up on its own has an answer for where it came from.
                Text(token.signedInText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                if auth.tokenIsForOtherSettings {
                    Text("This token was issued for different settings than the ones below, so it is not being sent. Authenticate again to replace it, or clear it.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.deletion)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Not signed in.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if let failure = auth.failure {
                Text(failure)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.deletion)
                    .fixedSize(horizontal: false, vertical: true)
            }

            AuthenticateButton()
        }
    }

    // Green is a claim that the token is good to send, which a token for other settings is
    // not, however long it has left.
    private func expiryColour(_ token: OAuthToken) -> Color {
        if token.isExpired { return Theme.deletion }
        return auth.tokenIsForOtherSettings ? .secondary : Theme.addition
    }

    // MARK: - Settings

    private var settings: some View {
        @Bindable var auth = auth

        return VStack(alignment: .leading, spacing: 14) {
            SectionLabel(text: "CONFIGURE NEW TOKEN")

            LabelledControl(title: "Grant type") {
                Picker("", selection: $auth.config.grant) {
                    ForEach(GrantType.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }

            if auth.config.grant.usesBrowser {
                Field(title: "Auth URL", placeholder: "https://id.example/oauth/authorize",
                      text: $auth.config.authURL)
                Field(title: "Callback URL", placeholder: "http://127.0.0.1:8234/callback",
                      text: $auth.config.callbackURL)
                Text(auth.config.usesLoopback
                     ? "The browser is sent back here when you sign in, so the identity provider has to allow this exact URL for the client. If it refuses, put the callback it does allow here instead and paste the code back by hand."
                     : "This callback is not on your machine, so the browser cannot hand the code back on its own. Sign in, then paste the address the browser ends on.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Field(title: "Access token URL", placeholder: "https://id.example/oauth/token",
                  text: $auth.config.tokenURL)
            Field(title: "Client ID", placeholder: "", text: $auth.config.clientID)
            Field(title: "Client secret", placeholder: "Leave empty for a public client",
                  text: $auth.config.clientSecret, secret: true)
            Field(title: "Scope", placeholder: "space separated", text: $auth.config.scope)
            if auth.config.grant.usesBrowser {
                Field(title: "State", placeholder: "Generated when left blank",
                      text: $auth.config.state)
            }
            Field(title: "Header prefix", placeholder: "Bearer", text: $auth.config.headerPrefix)

            LabelledControl(title: "Client authentication") {
                Picker("", selection: $auth.config.clientAuth) {
                    ForEach(ClientAuthentication.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }

            if auth.config.grant.usesBrowser {
                Text("PKCE is always on, with SHA-256.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// The button that starts the whole dance, shown wherever signing in makes sense. When the
// callback belongs to someone else, it also collects the answer the browser ended on.
struct AuthenticateButton: View {
    @Environment(PostmanAuthStore.self) private var auth

    @State private var pasted = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            buttons
            if auth.awaitingPaste { paste }
        }
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

                Button("Finish", action: finish)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.88)))
                    .disabled(pasted.isEmpty || auth.busy)
            }
        }
    }

    private func finish() {
        auth.submitRedirect(pasted)
        pasted = ""
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button {
                auth.authenticate()
            } label: {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 9)
                        .fill(auth.busy ? Color.black.opacity(0.4) : Color.black.opacity(0.88)))
            }
            .buttonStyle(.plain)
            .disabled(auth.busy)

            // Nothing tells the app that the browser tab was closed or that the provider
            // showed an error page, so calling it off has to be a button.
            if auth.busy || auth.awaitingPaste {
                Button("Cancel") { auth.cancelAuthentication() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.deletion)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
            }
        }
    }

    private var label: String {
        if auth.busy { return auth.config.grant.usesBrowser ? "Waiting for the browser…" : "Signing in…" }
        if auth.awaitingPaste { return "Waiting for the code" }
        return auth.token == nil ? "Authenticate" : "Authenticate again"
    }
}

private struct LabelledControl<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            content
            Spacer(minLength: 0)
        }
    }
}

private struct Field: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var secret = false

    @State private var revealed = false

    var body: some View {
        LabelledControl(title: title) {
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
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            .frame(maxWidth: .infinity)

            if secret {
                Button(revealed ? "Hide" : "Show") { revealed.toggle() }
                    .controlSize(.small)
            }
        }
    }
}
