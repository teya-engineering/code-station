import AppKit
import Foundation
import Observation

// The two environments' OAuth setups and whatever token each currently holds. A send
// borrows the active environment's token from here; switching environments never touches
// the other side's token, so flipping back does not mean signing in again.
@MainActor
@Observable
final class PostmanAuthStore {
    var active: ApiEnvironment { didSet { if active != oldValue { scheduleSave() } } }
    var staging: OAuthConfig { didSet { if staging != oldValue { scheduleSave() } } }
    var production: OAuthConfig { didSet { if production != oldValue { scheduleSave() } } }

    private(set) var tokens: [ApiEnvironment: OAuthToken] = [:]
    private(set) var busy: Set<ApiEnvironment> = []
    // The browser is out with a sign-in whose answer has to be pasted back.
    private(set) var awaitingPaste: Set<ApiEnvironment> = []
    private(set) var failures: [ApiEnvironment: String] = [:]
    private var attempts: [ApiEnvironment: Task<Void, Never>] = [:]
    private var pending: [ApiEnvironment: Pending] = [:]

    let storeURL: URL
    private let keychain: KeychainClient
    private(set) var loadError: String?
    private(set) var saveError: String?

    private struct Persisted: Codable {
        var active: ApiEnvironment
        var staging: OAuthConfig
        var production: OAuthConfig
    }

    init(storeURL: URL? = nil, keychain: KeychainClient = .live) {
        self.storeURL = storeURL
            ?? ProcessInfo.processInfo.environment["CONDUCTOR_POSTMAN_AUTH"]
                .map { URL(fileURLWithPath: $0) }
            ?? AppPaths.supportFile("postman-auth.json",
                                    movedFrom: AppPaths.legacy("postman-auth.json"))
        self.keychain = keychain

        var loadFailures: [String] = []
        var saved: Persisted?
        do {
            if let data = try PersistentFile.readIfPresent(self.storeURL) {
                saved = try JSONDecoder.oauth.decode(Persisted.self, from: data)
            }
        } catch let error as DecodingError {
            loadFailures.append(PersistentFile.decodeMessage(for: self.storeURL, error: error))
        } catch {
            loadFailures.append(PersistentFile.loadMessage(for: self.storeURL, error: error))
        }

        // An environment left empty starts from the defaults rather than from nothing.
        func carried(_ config: OAuthConfig?) -> OAuthConfig {
            if let config, !(config.tokenURL.isEmpty && config.clientID.isEmpty) { return config }
            return .teya
        }
        var staging = carried(saved?.staging)
        var production = carried(saved?.production)
        var tokens: [ApiEnvironment: OAuthToken] = [:]
        var secrets: [ApiEnvironment: String] = [:]
        var tokenJSON: [ApiEnvironment: String] = [:]

        // The Keychain is the truth for the secrets and the tokens; the file never holds
        // either.
        for env in ApiEnvironment.allCases {
            do {
                if let secret = try keychain.string(env.secretAccount) {
                    secrets[env] = secret
                    if env == .staging { staging.clientSecret = secret }
                    else { production.clientSecret = secret }
                }
            } catch {
                loadFailures.append(error.localizedDescription)
            }

            do {
                if let json = try keychain.string(env.tokenAccount) {
                    let token = try JSONDecoder.oauth.decode(OAuthToken.self,
                                                              from: Data(json.utf8))
                    tokenJSON[env] = json
                    tokens[env] = token
                }
            } catch {
                loadFailures.append(error.localizedDescription)
            }
        }

        active = saved?.active ?? .staging
        self.staging = staging
        self.production = production
        self.tokens = tokens
        storedSecrets = secrets
        storedTokenJSON = tokenJSON
        loadError = loadFailures.isEmpty ? nil : loadFailures.joined(separator: "\n")
    }

    func config(for env: ApiEnvironment) -> OAuthConfig {
        env == .staging ? staging : production
    }

    func setConfig(_ config: OAuthConfig, for env: ApiEnvironment) {
        if env == .staging { staging = config } else { production = config }
    }

    func isAuthenticated(for env: ApiEnvironment) -> Bool {
        guard let token = tokens[env] else { return false }
        return !token.isExpired && token.matches(config(for: env))
    }

    // The token on hand was issued for a different client or provider than the one set up
    // now. It is kept rather than dropped, since a keystroke in a field should not throw a
    // sign-in away, but it is not sent anywhere and it does not count as being signed in.
    func tokenIsForOtherSettings(_ env: ApiEnvironment) -> Bool {
        guard let token = tokens[env] else { return false }
        return !token.matches(config(for: env))
    }

    // One line on where the token stands, so every place that shows it says the same thing.
    func tokenStatus(for env: ApiEnvironment) -> String {
        if busy.contains(env) { return "Signing in…" }
        if awaitingPaste.contains(env) { return "Waiting for the code" }
        guard let token = tokens[env] else { return "Not signed in" }
        if tokenIsForOtherSettings(env) { return "Token is for other settings" }
        return token.validityText
    }

    // MARK: - Getting a token

    // Started rather than awaited, so the attempt is a thing that can be called off. A
    // sign-in that goes wrong usually does so in the browser, where nothing comes back to
    // say so and waiting for the timeout is the only other way out.
    func authenticate(_ env: ApiEnvironment) {
        guard !busy.contains(env) else { return }
        let config = config(for: env).cleaned()
        let gaps = config.missing
        guard gaps.isEmpty else {
            failures[env] = "Fill in \(gaps.joined(separator: ", ")) first."
            return
        }

        busy.insert(env)
        failures[env] = nil
        awaitingPaste.remove(env)
        pending[env] = nil
        attempts[env] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.busy.remove(env)
                self.attempts[env] = nil
            }
            do {
                switch config.grant {
                case .authorizationCodePKCE:
                    self.tokens[env] = try await self.authorizationCode(env, config: config)
                case .clientCredentials:
                    self.tokens[env] = try await self.clientCredentials(config)
                }
                self.save()
            } catch is PausedForPaste {
                // The browser has the sign-in now; it finishes in submitRedirect.
            } catch is CancellationError {
                self.failures[env] = "Sign-in was cancelled."
            } catch {
                self.failures[env] = error.localizedDescription
            }
        }
    }

    func cancelAuthentication(_ env: ApiEnvironment) {
        attempts[env]?.cancel()
        awaitingPaste.remove(env)
        pending[env] = nil
    }

    // Refreshing goes to the token endpoint as the client that is set up now, which is not
    // the one that issued a token from other settings.
    func refresh(_ env: ApiEnvironment) async {
        let config = config(for: env).cleaned()
        guard !busy.contains(env), let current = tokens[env], current.matches(config),
              let refreshToken = current.refreshToken else { return }
        busy.insert(env)
        failures[env] = nil
        defer { busy.remove(env) }
        do {
            tokens[env] = try await exchange(["grant_type": "refresh_token",
                                              "refresh_token": refreshToken],
                                             config: config,
                                             keepingRefresh: refreshToken)
            save()
        } catch {
            failures[env] = error.localizedDescription
        }
    }

    func clearToken(for env: ApiEnvironment) {
        tokens[env] = nil
        failures[env] = nil
        save()
    }

    // The value a request should send. An expired token is brought back quietly when the
    // grant allows it - a refresh token, or client credentials asked for again - so a send
    // does not fail on staleness alone.
    func authorizationHeader(for env: ApiEnvironment) async -> String? {
        let config = config(for: env).cleaned()
        if let token = tokens[env], token.matches(config), token.isExpired,
           token.refreshToken != nil {
            await refresh(env)
        }
        if !isAuthenticated(for: env), config.grant == .clientCredentials,
           config.missing.isEmpty, !busy.contains(env) {
            busy.insert(env)
            defer { busy.remove(env) }
            if let token = try? await clientCredentials(config) {
                tokens[env] = token
                save()
            }
        }
        guard let token = tokens[env], token.matches(config), !token.isExpired else { return nil }
        let prefix = config.headerPrefix.trimmingCharacters(in: .whitespaces)
        return prefix.isEmpty ? token.accessToken : "\(prefix) \(token.accessToken)"
    }

    // MARK: - The grants

    private func authorizationCode(_ env: ApiEnvironment, config: OAuthConfig) async throws -> OAuthToken {
        let verifier = PKCE.verifier()
        let state = config.state.isEmpty ? UUID().uuidString : config.state
        let authorizeURL = try authorizeURL(config: config, verifier: verifier, state: state)

        // A callback that belongs to someone else lands in their page, out of reach, so
        // the browser is opened and the code is taken from what the user pastes back.
        guard config.usesLoopback else {
            pending[env] = Pending(verifier: verifier, state: state)
            awaitingPaste.insert(env)
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

        return try await redeem(code: code, verifier: verifier, config: config)
    }

    private func authorizeURL(config: OAuthConfig, verifier: String, state: String) throws -> URL {
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

    private func redeem(code: String, verifier: String, config: OAuthConfig) async throws -> OAuthToken {
        try await exchange(["grant_type": "authorization_code",
                            "code": code,
                            "redirect_uri": config.callbackURL,
                            "code_verifier": verifier],
                           config: config,
                           keepingRefresh: nil)
    }

    private func clientCredentials(_ config: OAuthConfig) async throws -> OAuthToken {
        var fields = ["grant_type": "client_credentials"]
        if !config.scope.isEmpty { fields["scope"] = config.scope }
        return try await exchange(fields, config: config, keepingRefresh: nil)
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

    func submitRedirect(_ text: String, for env: ApiEnvironment) {
        guard !busy.contains(env), let pending = pending[env] else { return }
        let config = config(for: env).cleaned()

        switch RedirectAnswer.parse(text) {
        case .unreadable:
            failures[env] = "That does not look like the redirect URL or a code."
        case .refused(let message):
            failures[env] = message
        case .code(let code, let state):
            // Providers echo the state back, but not all of them, and the paste is only
            // as good as what the browser was given.
            guard state == nil || state == pending.state else {
                failures[env] = "The state did not match, so the answer was ignored."
                return
            }
            busy.insert(env)
            failures[env] = nil
            attempts[env] = Task { [weak self] in
                guard let self else { return }
                defer {
                    self.busy.remove(env)
                    self.attempts[env] = nil
                }
                do {
                    self.tokens[env] = try await self.redeem(code: code,
                                                             verifier: pending.verifier,
                                                             config: config)
                    self.pending[env] = nil
                    self.awaitingPaste.remove(env)
                    self.save()
                } catch is CancellationError {
                    self.failures[env] = "Sign-in was cancelled."
                } catch {
                    self.failures[env] = error.localizedDescription
                }
            }
        }
    }

    // MARK: - The token call

    private func exchange(_ fields: [String: String], config: OAuthConfig,
                          keepingRefresh: String?) async throws -> OAuthToken {
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

        guard let token = parsed?.token(keepingRefresh: keepingRefresh,
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
    private var storedSecrets: [ApiEnvironment: String] = [:]
    private var storedTokenJSON: [ApiEnvironment: String] = [:]

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

    // The secrets and the tokens go to the Keychain; the file keeps the rest, which is
    // just the addresses and the client ids. Keychain writes are slow and synchronous,
    // so they are skipped when the value there already matches.
    @discardableResult
    func save() -> Bool {
        saveTask?.cancel()
        saveTask = nil
        guard loadError == nil else {
            saveError = "Changes were not saved because the existing OAuth settings could not be loaded."
            return false
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601

        var failures: [String] = []
        for env in ApiEnvironment.allCases {
            let secret = config(for: env).clientSecret
            let value = secret.isEmpty ? nil : secret
            if value != storedSecrets[env] {
                do {
                    try keychain.set(value, env.secretAccount)
                    storedSecrets[env] = value
                } catch {
                    failures.append(error.localizedDescription)
                }
            }

            let tokenJSON: String?
            do {
                tokenJSON = try tokens[env].map { token in
                    String(decoding: try encoder.encode(token), as: UTF8.self)
                }
            } catch {
                failures.append("The \(env.rawValue) token could not be encoded: \(error.localizedDescription)")
                continue
            }
            if tokenJSON != storedTokenJSON[env] {
                do {
                    try keychain.set(tokenJSON, env.tokenAccount)
                    storedTokenJSON[env] = tokenJSON
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
        }
        guard failures.isEmpty else {
            saveError = failures.joined(separator: "\n")
            return false
        }

        var onDisk = Persisted(active: active, staging: staging, production: production)
        onDisk.staging.clientSecret = ""
        onDisk.production.clientSecret = ""
        do {
            try PersistentFile.write(encoder.encode(onDisk), to: storeURL)
            saveError = nil
            return true
        } catch {
            saveError = PersistentFile.saveMessage(for: storeURL, error: error)
            return false
        }
    }
}

private extension ApiEnvironment {
    var secretAccount: Keychain.Account {
        self == .staging ? .stagingClientSecret : .productionClientSecret
    }
    var tokenAccount: Keychain.Account {
        self == .staging ? .stagingToken : .productionToken
    }
}

private extension JSONDecoder {
    // Token endpoints answer in snake_case, and so do the files we write from them.
    static var oauth: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension OAuthConfig {
    // The orders collection's identity provider, so both environments have
    // somewhere to sign in against without being typed out first.
    static var teya: OAuthConfig {
        OAuthConfig(grant: .authorizationCodePKCE,
                    authURL: "https://id.example.com/oauth/v2/authorize",
                    tokenURL: "https://id.example.com/oauth/v2/token",
                    clientID: "00000000-0000-0000-0000-000000000000",
                    scope: "okta")
    }
}
