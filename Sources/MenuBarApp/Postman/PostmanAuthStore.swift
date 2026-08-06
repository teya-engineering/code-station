import AppKit
import Foundation
import Observation

// The collection's OAuth setup and whatever token it currently holds. Requests borrow the
// token from here rather than each keeping their own copy of it.
@MainActor
@Observable
final class PostmanAuthStore {
    var config: OAuthConfig { didSet { if config != oldValue { scheduleSave() } } }
    private(set) var token: OAuthToken?
    private(set) var busy = false
    private(set) var failure: String?
    // The browser is out with a sign-in whose answer has to be pasted back.
    private(set) var awaitingPaste = false
    private var attempt: Task<Void, Never>?
    private var pending: Pending?

    let storeURL: URL

    private struct Persisted: Codable {
        var config: OAuthConfig
        // Written by an earlier version, which kept the token in this file. Read so it
        // can be moved into the Keychain, never written back.
        var token: OAuthToken?
    }

    init() {
        storeURL = ProcessInfo.processInfo.environment["CONDUCTOR_POSTMAN_AUTH"]
            .map { URL(fileURLWithPath: $0) }
            ?? AppPaths.supportFile("postman-auth.json",
                                    movedFrom: AppPaths.legacy("postman-auth.json"))
        let saved = try? JSONDecoder.oauth.decode(
            Persisted.self, from: (try? Data(contentsOf: storeURL)) ?? Data())

        config = saved?.config ?? .teya
        token = saved?.token
        let fromFile = !config.clientSecret.isEmpty || token != nil

        // The Keychain is the truth for both; the file only ever holds them on the way
        // over from a version that did not know better.
        storedSecret = Keychain.string(.oauthClientSecret)
        if let storedSecret { config.clientSecret = storedSecret }
        storedTokenJSON = Keychain.string(.oauthToken)
        if let storedTokenJSON,
           let token = try? JSONDecoder.oauth.decode(OAuthToken.self, from: Data(storedTokenJSON.utf8)) {
            self.token = token
        }
        if fromFile { save() }
    }

    var isAuthenticated: Bool {
        guard let token else { return false }
        return !token.isExpired && token.matches(config)
    }

    // The token on hand was issued for a different client or provider than the one set up
    // now. It is kept rather than dropped, since a keystroke in a field should not throw a
    // sign-in away, but it is not sent anywhere and it does not count as being signed in.
    var tokenIsForOtherSettings: Bool {
        guard let token else { return false }
        return !token.matches(config)
    }

    // One line on where the token stands, so every place that shows it says the same thing.
    var tokenStatus: String {
        guard let token else { return "Not signed in" }
        if tokenIsForOtherSettings { return "Token is for other settings" }
        return token.isExpired ? "Token expired" : token.expiryText
    }

    // MARK: - Getting a token

    // Started rather than awaited, so the attempt is a thing that can be called off. A
    // sign-in that goes wrong usually does so in the browser, where nothing comes back to
    // say so and waiting for the timeout is the only other way out.
    func authenticate() {
        guard !busy else { return }
        let gaps = config.missing
        guard gaps.isEmpty else {
            failure = "Fill in \(gaps.joined(separator: ", ")) first."
            return
        }

        busy = true
        failure = nil
        awaitingPaste = false
        pending = nil
        attempt = Task { [weak self] in
            guard let self else { return }
            defer {
                self.busy = false
                self.attempt = nil
            }
            do {
                switch self.config.grant {
                case .authorizationCodePKCE: self.token = try await self.authorizationCode()
                case .clientCredentials: self.token = try await self.clientCredentials()
                }
                self.save()
            } catch is PausedForPaste {
                // The browser has the sign-in now; it finishes in submitRedirect.
            } catch is CancellationError {
                self.failure = "Sign-in was cancelled."
            } catch {
                self.failure = error.localizedDescription
            }
        }
    }

    func cancelAuthentication() {
        attempt?.cancel()
        awaitingPaste = false
        pending = nil
    }

    // Refreshing goes to the token endpoint as the client that is set up now, which is not
    // the one that issued a token from other settings.
    func refresh() async {
        guard !busy, let current = token, current.matches(config),
              let refreshToken = current.refreshToken else { return }
        busy = true
        failure = nil
        defer { busy = false }
        do {
            token = try await exchange(["grant_type": "refresh_token",
                                        "refresh_token": refreshToken])
            save()
        } catch {
            failure = error.localizedDescription
        }
    }

    func clearToken() {
        token = nil
        failure = nil
        save()
    }

    // The value a request should send. An expired token is refreshed first when the
    // provider gave us the means to, so a send does not fail on staleness alone.
    func authorizationHeader() async -> String? {
        guard token?.matches(config) == true else { return nil }
        if token?.isExpired == true, token?.refreshToken != nil { await refresh() }
        guard let token, !token.isExpired else { return nil }
        let prefix = config.headerPrefix.trimmingCharacters(in: .whitespaces)
        return prefix.isEmpty ? token.accessToken : "\(prefix) \(token.accessToken)"
    }

    // MARK: - The grants

    private func authorizationCode() async throws -> OAuthToken {
        let verifier = PKCE.verifier()
        let state = config.state.isEmpty ? UUID().uuidString : config.state
        let authorizeURL = try authorizeURL(verifier: verifier, state: state)

        // A callback that belongs to someone else lands in their page, out of reach, so
        // the browser is opened and the code is taken from what the user pastes back.
        guard config.usesLoopback else {
            pending = Pending(verifier: verifier, state: state)
            awaitingPaste = true
            NSWorkspace.shared.open(authorizeURL)
            throw PausedForPaste()
        }

        guard let port = config.callbackPort else {
            throw OAuthError("The callback URL needs a port, such as http://127.0.0.1:8234/callback.")
        }

        let server = LoopbackServer()
        // The port has to be listening before the browser is sent anywhere, or the
        // redirect can arrive at nothing.
        try await server.start(port: port)
        defer { server.stop() }

        NSWorkspace.shared.open(authorizeURL)
        let answer = try await server.waitForRedirect()
        if let error = answer["error"] {
            throw OAuthError([error, answer["error_description"]].compactMap { $0 }.joined(separator: ": "))
        }
        guard let code = answer["code"] else {
            throw OAuthError("The browser came back without an authorization code.")
        }
        guard answer["state"] == state else {
            throw OAuthError("The state did not match, so the answer was ignored.")
        }

        return try await redeem(code: code, verifier: verifier)
    }

    private func authorizeURL(verifier: String, state: String) throws -> URL {
        guard var components = URLComponents(string: config.authURL) else {
            throw OAuthError("The auth URL is not valid.")
        }
        var query = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.callbackURL),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        if !config.scope.isEmpty { query.append(URLQueryItem(name: "scope", value: config.scope)) }
        components.queryItems = (components.queryItems ?? []) + query
        guard let url = components.url else { throw OAuthError("The auth URL is not valid.") }
        return url
    }

    private func redeem(code: String, verifier: String) async throws -> OAuthToken {
        try await exchange(["grant_type": "authorization_code",
                            "code": code,
                            "redirect_uri": config.callbackURL,
                            "code_verifier": verifier])
    }

    // MARK: - Finishing a pasted sign-in

    // What the browser was sent out with, kept until the answer is carried back.
    private struct Pending {
        let verifier: String
        let state: String
    }

    // Not a failure: the attempt is paused rather than over, so the button stops spinning
    // without an error being shown.
    private struct PausedForPaste: Error {}

    func submitRedirect(_ text: String) {
        guard !busy, let pending else { return }

        switch RedirectAnswer.parse(text) {
        case .unreadable:
            failure = "That does not look like the redirect URL or a code."
        case .refused(let message):
            failure = message
        case .code(let code, let state):
            // Providers echo the state back, but not all of them, and the paste is only
            // as good as what the browser was given.
            guard state == nil || state == pending.state else {
                failure = "The state did not match, so the answer was ignored."
                return
            }
            busy = true
            failure = nil
            attempt = Task { [weak self] in
                guard let self else { return }
                defer {
                    self.busy = false
                    self.attempt = nil
                }
                do {
                    self.token = try await self.redeem(code: code, verifier: pending.verifier)
                    self.pending = nil
                    self.awaitingPaste = false
                    self.save()
                } catch is CancellationError {
                    self.failure = "Sign-in was cancelled."
                } catch {
                    self.failure = error.localizedDescription
                }
            }
        }
    }

    private func clientCredentials() async throws -> OAuthToken {
        var fields = ["grant_type": "client_credentials"]
        if !config.scope.isEmpty { fields["scope"] = config.scope }
        return try await exchange(fields)
    }

    // MARK: - The token call

    private func exchange(_ fields: [String: String]) async throws -> OAuthToken {
        guard let url = URL(string: config.tokenURL) else {
            throw OAuthError("The access token URL is not valid.")
        }

        var fields = fields
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        switch config.clientAuth {
        case .body:
            fields["client_id"] = config.clientID
            if !config.clientSecret.isEmpty { fields["client_secret"] = config.clientSecret }
        case .basicHeader:
            let pair = "\(config.clientID):\(config.clientSecret)"
            request.setValue("Basic \(Data(pair.utf8).base64EncodedString())",
                             forHTTPHeaderField: "Authorization")
            // Providers that read the header still expect the id in the body for PKCE.
            if fields["grant_type"] == "authorization_code" { fields["client_id"] = config.clientID }
        }

        var body = URLComponents()
        body.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((body.percentEncodedQuery ?? "").utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let parsed = try? JSONDecoder.oauth.decode(TokenResponse.self, from: data)
        if let failure = parsed?.failure { throw OAuthError(failure) }

        guard let token = parsed?.token(keepingRefresh: token?.refreshToken,
                                        identity: config.identity) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw OAuthError("The token call answered \(status) with no token. \(text)")
        }
        return token
    }

    // MARK: - Persistence

    private var saveTask: Task<Void, Never>?
    // What the Keychain holds right now, so a save can tell when writing it again would
    // only store the same value.
    private var storedSecret: String?
    private var storedTokenJSON: String?

    // Editing a settings field lands here once per keystroke, so those are coalesced
    // into one write the way the request store does it.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    // The secret and the token go to the Keychain; the file keeps the rest, which is just
    // the addresses and the client id. Keychain writes are slow and synchronous, so they
    // are skipped when the value there already matches.
    func save() {
        saveTask?.cancel()
        saveTask = nil

        let secret = config.clientSecret.isEmpty ? nil : config.clientSecret
        if secret != storedSecret {
            Keychain.set(secret, for: .oauthClientSecret)
            storedSecret = secret
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let tokenJSON = token.flatMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        if tokenJSON != storedTokenJSON {
            Keychain.set(tokenJSON, for: .oauthToken)
            storedTokenJSON = tokenJSON
        }

        var onDisk = config
        onDisk.clientSecret = ""
        guard let data = try? encoder.encode(Persisted(config: onDisk, token: nil)) else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
    }
}

private extension JSONDecoder {
    // Token endpoints answer in snake_case, and so does the file we write from it.
    static var oauth: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension OAuthConfig {
    // The orders collection's identity provider, so the example requests have
    // somewhere to sign in against without being typed out first.
    static var teya: OAuthConfig {
        OAuthConfig(grant: .authorizationCodePKCE,
                    authURL: "https://id.example.com/oauth/v2/authorize",
                    tokenURL: "https://id.example.com/oauth/v2/token",
                    clientID: "00000000-0000-0000-0000-000000000000",
                    scope: "okta")
    }
}
