import AppKit
import Foundation
import Observation

// The configured environments' OAuth setups and whatever token each currently holds,
// plus the password of every request that signs in with basic auth. A send borrows the
// active environment's token from here; switching environments never touches another
// environment's token. Every secret in the app is written from here, which is what keeps
// one Keychain item from being written twice.
@MainActor
@Observable
final class DispatchAuthStore {
    var active: ApiEnvironment { didSet { if active != oldValue { saver.schedule() } } }
    private(set) var environments: [ApiEnvironment]
    private var configurations: [ApiEnvironment: OAuthConfig]
    private var siteOAuth: OAuthConfig

    private(set) var tokens: [ApiEnvironment: OAuthToken] = [:]
    private(set) var basicPasswords: [UUID: String] = [:]
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

    // Editing a settings field lands here once per keystroke, so those are coalesced
    // into one write the way the request store does it.
    @ObservationIgnored private lazy var saver = DebouncedSaver { [weak self] in self?.save() }
    // What the Keychain holds right now, so a save can tell when writing it again would
    // only store the same value.
    private var storedKeychainValues: [Keychain.Account: String] = [:]

    private struct Persisted: Codable {
        var active: String
        var configurations: [String: OAuthConfig]
    }

    private struct LegacyPersisted: Codable {
        var active: String
        var staging: OAuthConfig
        var production: OAuthConfig
    }

    init(storeURL: URL? = nil, keychain: KeychainClient = .live,
         siteDefaults: SiteDefaults = .current) {
        self.storeURL = storeURL ?? Self.defaultStoreURL()
        self.keychain = keychain

        var loadFailures: [String] = []
        var saved: Persisted?
        var legacySaved: LegacyPersisted?
        do {
            saved = try PersistentFile.loadJSON(Persisted.self, from: self.storeURL, decoder: .oauth)
        } catch is DecodingError {
            // A file from when the environments were a fixed pair names the two outright.
            do {
                legacySaved = try PersistentFile.loadJSON(LegacyPersisted.self, from: self.storeURL,
                                                         decoder: .oauth)
            } catch {
                loadFailures.append(PersistentFile.decodeMessage(for: self.storeURL, error: error))
            }
        } catch {
            loadFailures.append(PersistentFile.loadMessage(for: self.storeURL, error: error))
        }

        let environments = siteDefaults.deployEnvironments.map(ApiEnvironment.init)
        let legacyNames = siteDefaults.dispatchEnvValues
        let legacyStagingEnvironment = environments.first { $0.name == legacyNames.staging }
            ?? environments.first { !$0.isDangerous }
            ?? environments[0]
        let legacyProductionEnvironment = environments.first { $0.name == legacyNames.production }
            ?? environments.first { $0.isDangerous }
            ?? environments.last!
        var configurations: [ApiEnvironment: OAuthConfig] =
            (saved?.configurations ?? [:]).reduce(into: [:]) { result, entry in
            let environment = environments.first { $0.name == entry.key }
                ?? ApiEnvironment(name: entry.key)
            result[environment] = entry.value
        }
        if let legacySaved {
            configurations[legacyStagingEnvironment] = legacySaved.staging
            configurations[legacyProductionEnvironment] = legacySaved.production
        }
        for environment in environments where configurations[environment] == nil {
            configurations[environment] = siteDefaults.dispatchOAuth
        }

        var tokens: [ApiEnvironment: OAuthToken] = [:]
        var keychainValues: [Keychain.Account: String] = [:]

        // The Keychain is the truth for the secrets and the tokens; the file never holds
        // either.
        do {
            keychainValues = try keychain.read()
        } catch {
            loadFailures.append(error.localizedDescription)
        }
        for env in environments {
            let legacySecret = env == legacyStagingEnvironment
                ? keychainValues[.stagingClientSecret]
                : env == legacyProductionEnvironment
                    ? keychainValues[.productionClientSecret]
                    : nil
            if let secret = keychainValues[env.secretAccount] ?? legacySecret {
                configurations[env]?.clientSecret = secret
            }

            let legacyToken = env == legacyStagingEnvironment
                ? keychainValues[.stagingToken]
                : env == legacyProductionEnvironment
                    ? keychainValues[.productionToken]
                    : nil
            if let json = keychainValues[env.tokenAccount] ?? legacyToken {
                do {
                    let token = try JSONDecoder.oauth.decode(OAuthToken.self,
                                                              from: Data(json.utf8))
                    tokens[env] = token
                } catch {
                    loadFailures.append(error.localizedDescription)
                }
            }
        }

        let activeName: String?
        if let saved {
            activeName = saved.active
        } else if let legacySaved {
            activeName = legacySaved.active == "production"
                ? legacyProductionEnvironment.name : legacyStagingEnvironment.name
        } else {
            activeName = nil
        }
        active = environments.first { $0.name == activeName } ?? environments[0]
        self.environments = environments
        self.configurations = configurations
        siteOAuth = siteDefaults.dispatchOAuth
        self.tokens = tokens
        basicPasswords = keychainValues.reduce(into: [:]) { passwords, entry in
            if let requestID = entry.key.basicPasswordRequestID {
                passwords[requestID] = entry.value
            }
        }
        storedKeychainValues = keychainValues
        loadError = loadFailures.isEmpty ? nil : loadFailures.joined(separator: "\n")
    }

    private static func defaultStoreURL() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["CODE_STATION_DISPATCH_AUTH"]
            ?? environment["CONDUCTOR_DISPATCH_AUTH"]
            ?? environment["CONDUCTOR_POSTMAN_AUTH"] {
            return URL(fileURLWithPath: path)
        }
        return AppPaths.supportFile("dispatch-auth.json", moving: [
            AppPaths.support.appendingPathComponent("postman-auth.json"),
            AppPaths.legacy("dispatch-auth.json"),
            AppPaths.legacy("postman-auth.json")
        ])
    }

    func applySiteDefaults(_ defaults: SiteDefaults) {
        updateEnvironments(from: defaults)
        guard defaults.dispatch?.oauth != nil else {
            save()
            return
        }
        resetSiteAccess(to: defaults, updatingEnvironments: false)
    }

    func applyEnvironments(from defaults: SiteDefaults) {
        updateEnvironments(from: defaults)
        save()
    }

    // Unlike startup seeding, an explicit reset is allowed to clear shared provider
    // fields. Secrets and the few personal transport choices never belong to the shared
    // configuration and remain untouched.
    func resetSiteAccess(to defaults: SiteDefaults) {
        resetSiteAccess(to: defaults, updatingEnvironments: true)
    }

    private func resetSiteAccess(to defaults: SiteDefaults, updatingEnvironments: Bool) {
        if updatingEnvironments { updateEnvironments(from: defaults) }
        let oauth = defaults.dispatchOAuth
        siteOAuth = oauth
        // These fields are personal or are not represented by the site file. Importing
        // shared provider settings must not silently reset them.
        for environment in environments {
            let current = config(for: environment)
            var reset = oauth
            reset.clientSecret = current.clientSecret
            reset.state = current.state
            reset.headerPrefix = current.headerPrefix
            reset.clientAuth = current.clientAuth
            configurations[environment] = reset
        }
        save()
    }

    func config(for env: ApiEnvironment) -> OAuthConfig {
        configurations[env] ?? siteOAuth
    }

    func setConfig(_ config: OAuthConfig, for env: ApiEnvironment) {
        guard configurations[env] != config else { return }
        configurations[env] = config
        saver.schedule()
    }

    private func updateEnvironments(from defaults: SiteDefaults) {
        let updated = defaults.deployEnvironments.map(ApiEnvironment.init)
        let removed = Set(environments).subtracting(updated)
        for environment in removed { cancelAuthentication(environment) }
        for environment in updated where configurations[environment] == nil {
            configurations[environment] = defaults.dispatchOAuth
        }
        active = updated.first { $0.name == active.name } ?? updated[0]
        environments = updated
        siteOAuth = defaults.dispatchOAuth
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

    // MARK: - Basic auth

    func basicPassword(for requestID: UUID) -> String {
        basicPasswords[requestID] ?? ""
    }

    func setBasicPassword(_ password: String, for requestID: UUID) {
        guard basicPassword(for: requestID) != password else { return }
        basicPasswords[requestID] = password.isEmpty ? nil : password
        saver.schedule()
    }

    // Called when the request itself goes, so a password does not outlive what it was for.
    func forgetBasicPassword(for requestID: UUID) {
        guard basicPasswords.removeValue(forKey: requestID) != nil else { return }
        save()
    }

    func copyBasicPassword(from requestID: UUID, to copyID: UUID) {
        guard let password = basicPasswords[requestID] else { return }
        basicPasswords[copyID] = password
        save()
    }

    // What a request signing in with a username and password sends. Base64 is an
    // encoding, not a cipher, so the pair is readable to anything on the way: it is only
    // safe over https, which is the same deal every basic auth service makes.
    func basicHeader(username: String, requestID: UUID) -> String? {
        let username = username.trimmed
        // The password is sent as typed. Trimming it would quietly change a secret, and
        // a password is allowed to end in a space.
        let password = basicPassword(for: requestID)
        guard !username.isEmpty || !password.isEmpty else { return nil }
        return "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }

    // MARK: - Getting a token

    // Every way of getting a token runs through here, so busy, the failure line, the
    // token and the save behave the same whichever grant or step it is. The work is a
    // task of its own so the token card can call it off; a caller that needs the answer
    // right away waits on it. Work that hands the sign-in to the browser answers nil,
    // since a paste finishes it later.
    @discardableResult
    private func attempt(_ env: ApiEnvironment,
                         _ work: @escaping @MainActor () async throws -> OAuthToken?) -> Task<Void, Never> {
        busy.insert(env)
        failures[env] = nil
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.busy.remove(env)
                self.attempts[env] = nil
            }
            do {
                guard let token = try await work() else { return }
                self.tokens[env] = token
                self.pending[env] = nil
                self.awaitingPaste.remove(env)
                self.save()
            } catch is CancellationError {
                self.failures[env] = "Sign-in was cancelled."
            } catch {
                self.failures[env] = error.localizedDescription
            }
        }
        attempts[env] = task
        return task
    }

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

        awaitingPaste.remove(env)
        pending[env] = nil
        attempt(env) {
            switch config.grant {
            case .authorizationCodePKCE:
                try await self.authorizationCode(env, config: config)
            case .clientCredentials:
                try await self.clientCredentials(config)
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
        await attempt(env) {
            try await self.exchange(["grant_type": "refresh_token",
                                     "refresh_token": refreshToken],
                                    config: config,
                                    keepingRefresh: refreshToken)
        }.value
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
            await attempt(env) { try await self.clientCredentials(config) }.value
        }
        guard let token = tokens[env], token.matches(config), !token.isExpired else { return nil }
        let prefix = config.headerPrefix
        return prefix.isEmpty ? token.accessToken : "\(prefix) \(token.accessToken)"
    }

    // MARK: - The grants

    private func authorizationCode(_ env: ApiEnvironment, config: OAuthConfig) async throws -> OAuthToken? {
        let verifier = PKCE.verifier()
        let state = config.state.isEmpty ? UUID().uuidString : config.state
        let authorizeURL = try authorizeURL(config: config, verifier: verifier, state: state)

        // A callback that belongs to someone else lands in their page, out of reach, so
        // the browser is opened and the code is taken from what the user pastes back.
        guard config.usesLoopback else {
            pending[env] = Pending(verifier: verifier, state: state)
            awaitingPaste.insert(env)
            NSWorkspace.shared.open(authorizeURL)
            return nil
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
            attempt(env) {
                try await self.redeem(code: code, verifier: pending.verifier, config: config)
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

    // The secrets and the tokens go to the Keychain; the file keeps the rest, which is
    // just the addresses and the client ids. Keychain writes are slow and synchronous,
    // so they are skipped when the value there already matches.
    @discardableResult
    func save() -> Bool {
        saver.cancel()
        guard loadError == nil else {
            saveError = "Changes were not saved because the existing OAuth settings could not be loaded."
            return false
        }

        let encoder = PersistentFile.makeEncoder()

        // The passwords are rebuilt rather than edited in place, so one that has been
        // cleared is dropped from the Keychain instead of lingering under its old name.
        var keychainValues = storedKeychainValues.filter { $0.key.basicPasswordRequestID == nil }
        for (requestID, password) in basicPasswords where !password.isEmpty {
            keychainValues[.basicPassword(for: requestID)] = password
        }

        var encodingFailures: [String] = []
        for env in environments {
            let secret = config(for: env).clientSecret
            keychainValues[env.secretAccount] = secret.isEmpty ? nil : secret

            let tokenJSON: String?
            do {
                tokenJSON = try tokens[env].map { token in
                    String(decoding: try encoder.encode(token), as: UTF8.self)
                }
            } catch {
                encodingFailures.append(
                    "The \(env.name) token could not be encoded: \(error.localizedDescription)")
                continue
            }
            keychainValues[env.tokenAccount] = tokenJSON
        }
        guard encodingFailures.isEmpty else {
            saveError = encodingFailures.joined(separator: "\n")
            return false
        }
        if keychainValues != storedKeychainValues {
            do {
                try keychain.write(keychainValues)
                storedKeychainValues = keychainValues
            } catch {
                saveError = error.localizedDescription
                return false
            }
        }

        let cleanConfigurations = configurations.reduce(into: [String: OAuthConfig]()) {
            result, entry in
            var config = entry.value
            config.clientSecret = ""
            result[entry.key.name] = config
        }
        let onDisk = Persisted(active: active.name, configurations: cleanConfigurations)
        do {
            try PersistentFile.saveJSON(onDisk, to: storeURL, encoder: encoder)
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
        .dispatchClientSecret(for: name)
    }
    var tokenAccount: Keychain.Account {
        .dispatchToken(for: name)
    }
}

private extension JSONDecoder {
    // Token endpoints answer in snake_case, and so do the files we write from them.
    static var oauth: JSONDecoder {
        let decoder = PersistentFile.makeDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
