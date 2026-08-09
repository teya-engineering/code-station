import Foundation
import Testing
@testable import MenuBarApp

// The parts of the OAuth flow that fail silently when they are wrong: the PKCE proof the
// provider checks, and reading the code back out of the browser's redirect.
struct OAuthTests {

    // The worked example from RFC 7636, so a broken hash or the wrong base64 alphabet
    // shows up here rather than as a rejected token call.
    @Test func buildsThePKCEChallengeTheWayTheSpecDoes() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(PKCE.challenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func makesVerifiersThatAreUnreservedAndLongEnough() {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let verifier = PKCE.verifier()
        #expect(verifier.count >= 43 && verifier.count <= 128)
        #expect(verifier.allSatisfy { allowed.contains($0) })
        #expect(PKCE.verifier() != verifier)
    }

    @Test func readsTheCodeOutOfTheRedirect() {
        let request = "GET /callback?code=abc123&state=xyz HTTP/1.1\r\nHost: 127.0.0.1:8234\r\n\r\n"
        let query = LoopbackServer.query(from: request)
        #expect(query?["code"] == "abc123")
        #expect(query?["state"] == "xyz")
    }

    @Test func readsAProviderRefusal() {
        let request = "GET /callback?error=access_denied&error_description=Nope%20sorry HTTP/1.1\r\n\r\n"
        let query = LoopbackServer.query(from: request)
        #expect(query?["error"] == "access_denied")
        #expect(query?["error_description"] == "Nope sorry")
    }

    @Test func ignoresAnythingThatIsNotTheRedirect() {
        #expect(LoopbackServer.query(from: "") == nil)
        #expect(LoopbackServer.query(from: "POST /callback HTTP/1.1\r\n\r\n") == nil)
        // A browser that follows the redirect without a query is still a valid arrival.
        #expect(LoopbackServer.query(from: "GET /callback HTTP/1.1\r\n\r\n") == [:])
    }

    @Test func escapesProviderTextBeforePuttingItInTheBrowserPage() {
        let page = LoopbackServer.page(title: #"Failed </title><script>bad()</script>"#,
                                       detail: #"Try <again> & say "no""#)

        #expect(!page.contains("<script>bad()</script>"))
        #expect(page.contains("&lt;script&gt;bad()&lt;/script&gt;"))
        #expect(page.contains("Try &lt;again&gt; &amp; say &quot;no&quot;"))
    }

    // The whole point of the listener: a real request on the loopback port hands its
    // query back to the flow that is waiting for it.
    @Test func handsBackTheQueryTheBrowserArrivesWith() async throws {
        let port: UInt16 = 8913
        let server = LoopbackServer()
        try await server.start(port: port, timeout: 10)
        async let redirect = server.waitForRedirect()

        _ = try await URLSession(configuration: .ephemeral)
            .data(from: URL(string: "http://127.0.0.1:\(port)/callback?code=abc&state=xyz")!)

        let query = try await redirect
        #expect(query["code"] == "abc")
        #expect(query["state"] == "xyz")
    }

    // A sign-in that goes wrong in the browser never comes back, so calling it off has to
    // both end the wait and free the port for the next attempt.
    @Test func stopsWaitingWhenTheAttemptIsCalledOff() async throws {
        let port: UInt16 = 8915
        let first = LoopbackServer()
        try await first.start(port: port, timeout: 30)
        let waiting = Task { try await first.waitForRedirect() }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }

        let second = LoopbackServer()
        try await second.start(port: port, timeout: 10)
        async let redirect = second.waitForRedirect()
        _ = try await URLSession(configuration: .ephemeral)
            .data(from: URL(string: "http://127.0.0.1:\(port)/callback?code=second")!)

        #expect(try await redirect["code"] == "second")
    }

    @Test func givesUpWhenTheBrowserNeverComesBack() async throws {
        let server = LoopbackServer()
        try await server.start(port: UInt16.random(in: 49_152...65_535), timeout: 1)
        do {
            _ = try await server.waitForRedirect()
            Issue.record("Expected the browser timeout.")
        } catch {
            #expect(error.localizedDescription == "Timed out waiting for the browser to come back.")
        }
    }

    // Binding fails before a browser tab is ever opened, so a busy port is an error you
    // can act on rather than a wait that goes nowhere.
    @Test func refusesToStartOnAPortAlreadyInUse() async throws {
        let port: UInt16 = 8916
        let holder = LoopbackServer()
        try await holder.start(port: port, timeout: 10)
        defer { holder.stop() }

        await #expect(throws: OAuthError.self) {
            try await LoopbackServer().start(port: port, timeout: 10)
        }
    }
}

struct OAuthConfigTests {

    @Test func namesWhatIsMissingForTheBrowserGrant() {
        var config = OAuthConfig(grant: .authorizationCodePKCE)
        #expect(config.missing.contains("Auth URL"))
        #expect(config.missing.contains("Access token URL"))
        #expect(config.missing.contains("Client ID"))

        config.authURL = "https://id.example/authorize"
        config.tokenURL = "https://id.example/token"
        config.clientID = "abc"
        #expect(config.missing.isEmpty)
    }

    // Client credentials never opens a browser, so the callback is not its problem.
    @Test func doesNotAskForACallbackWithoutABrowser() {
        let config = OAuthConfig(grant: .clientCredentials,
                                 tokenURL: "https://id.example/token",
                                 clientID: "abc",
                                 callbackURL: "nonsense")
        #expect(config.missing.isEmpty)
    }

    // Only a callback on this machine can be listened for; anything else has to be carried
    // back by hand, so the two are told apart before a browser is opened.
    @Test func knowsWhichCallbacksItCanCatchItself() {
        #expect(OAuthConfig(callbackURL: "http://127.0.0.1:8234/callback").usesLoopback)
        #expect(OAuthConfig(callbackURL: "http://localhost:8234/callback").usesLoopback)
        #expect(OAuthConfig(callbackURL: "https://oauth.pstmn.io/v1/callback").usesLoopback == false)
        #expect(OAuthConfig(callbackURL: "").usesLoopback == false)
    }

    // A callback that is not ours needs no port, and asking for one would block a setup
    // that works.
    @Test func onlyAsksForAPortOnACallbackItListensTo() {
        let elsewhere = OAuthConfig(authURL: "https://id.example/authorize",
                                    tokenURL: "https://id.example/token",
                                    clientID: "abc",
                                    callbackURL: "https://oauth.pstmn.io/v1/callback")
        #expect(elsewhere.missing.isEmpty)

        var loopback = elsewhere
        loopback.callbackURL = "http://127.0.0.1/callback"
        #expect(loopback.missing == ["a port on the callback URL"])
    }

    // A client id pasted with a trailing space is an unknown client to the provider,
    // which answers with nothing that names the real problem.
    @Test func shedsPastedWhitespaceBeforeAnythingIsSent() {
        var config = OAuthConfig(authURL: " https://id.example/authorize ",
                                 tokenURL: "https://id.example/token\n",
                                 clientID: "54ade699-f4f8  ",
                                 clientSecret: " shh ",
                                 scope: " okta ")
        let cleaned = config.cleaned()
        #expect(cleaned.clientID == "54ade699-f4f8")
        #expect(cleaned.authURL == "https://id.example/authorize")
        #expect(cleaned.tokenURL == "https://id.example/token")
        #expect(cleaned.clientSecret == "shh")
        #expect(cleaned.scope == "okta")

        // The identity trims itself, so a token fetched with the cleaned config still
        // counts for the config as typed.
        #expect(config.identity == cleaned.identity)

        config.clientID = "   "
        #expect(config.missing.contains("Client ID"))
    }

    @Test func takesThePortOffTheCallback() {
        #expect(OAuthConfig(callbackURL: "http://127.0.0.1:8234/callback").callbackPort == 8234)
        #expect(OAuthConfig(callbackURL: "http://localhost/callback").callbackPort == nil)
        #expect(OAuthConfig(callbackURL: "").callbackPort == nil)
    }

    @Test func readsTheTokenCallsAnswer() throws {
        let json = """
        {"access_token":"tok","token_type":"Bearer","expires_in":3600,"refresh_token":"ref"}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(TokenResponse.self, from: Data(json.utf8))
        let token = try #require(response.token(keepingRefresh: nil, identity: nil))

        #expect(token.accessToken == "tok")
        #expect(token.refreshToken == "ref")
        #expect(token.isExpired == false)
        #expect(token.expiresAt?.timeIntervalSinceNow ?? 0 > 3500)
    }

    // Refreshing often answers without a refresh token of its own, and losing the old one
    // would mean signing in through the browser again.
    @Test func keepsTheOldRefreshTokenWhenTheNewAnswerHasNone() throws {
        let json = #"{"access_token":"tok2","expires_in":60}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(TokenResponse.self, from: Data(json.utf8))

        #expect(response.token(keepingRefresh: "old-ref", identity: nil)?.refreshToken == "old-ref")
    }

    @Test func readsARefusalAsAFailure() throws {
        let json = #"{"error":"invalid_client","error_description":"Bad secret"}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(TokenResponse.self, from: Data(json.utf8))

        #expect(response.failure == "invalid_client: Bad secret")
        #expect(response.token(keepingRefresh: nil, identity: nil) == nil)
    }

    // A token about to die is treated as dead, since the request still has to travel.
    @Test func countsATokenOnItsLastSecondsAsExpired() {
        func token(expiringIn seconds: TimeInterval) -> OAuthToken {
            OAuthToken(accessToken: "t", tokenType: "Bearer",
                       expiresAt: Date().addingTimeInterval(seconds), obtainedAt: Date())
        }
        #expect(token(expiringIn: 300).isExpired == false)
        #expect(token(expiringIn: 5).isExpired)
        #expect(token(expiringIn: -1).isExpired)

        let noExpiry = OAuthToken(accessToken: "t", tokenType: "Bearer", obtainedAt: Date())
        #expect(noExpiry.isExpired == false)
    }
}

// A token says nothing about a client it was not issued for, and the settings can be
// edited long after it was fetched.
struct TokenIdentityTests {

    private var config: OAuthConfig {
        OAuthConfig(grant: .authorizationCodePKCE,
                    authURL: "https://id.example/authorize",
                    tokenURL: "https://id.example/token",
                    clientID: "abc",
                    clientSecret: "shh",
                    scope: "okta")
    }

    private func token(for config: OAuthConfig?) -> OAuthToken {
        OAuthToken(accessToken: "t", tokenType: "Bearer",
                   expiresAt: Date().addingTimeInterval(3600), obtainedAt: Date(),
                   identity: config?.identity)
    }

    @Test func disownsATokenWhenTheClientOrProviderChanges() {
        let token = token(for: config)
        #expect(token.matches(config))

        for change in [\OAuthConfig.clientID, \.authURL, \.tokenURL, \.scope] {
            var edited = config
            edited[keyPath: change] = "something else"
            #expect(token.matches(edited) == false)
        }

        var otherGrant = config
        otherGrant.grant = .clientCredentials
        #expect(token.matches(otherGrant) == false)
    }

    // Everything else is about how the token is fetched, not who it is for, so editing it
    // must not put a working token out of use.
    @Test func keepsATokenWhenOnlyTheMechanicsChange() {
        let token = token(for: config)

        var edited = config
        edited.callbackURL = "https://oauth.pstmn.io/v1/callback"
        edited.headerPrefix = "Token"
        edited.clientAuth = .basicHeader
        edited.clientSecret = "rotated"
        edited.state = "fixed-state"

        #expect(token.matches(edited))
    }

    // Tokens stored before the settings were recorded alongside them. There is nothing to
    // compare, so they are taken at face value rather than being cut off.
    @Test func trustsATokenStoredWithoutItsSettings() throws {
        let json = #"{"accessToken":"t","tokenType":"Bearer","obtainedAt":"2026-08-05T06:18:46Z"}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let token = try decoder.decode(OAuthToken.self, from: Data(json.utf8))

        #expect(token.identity == nil)
        #expect(token.matches(config))
    }

    @Test func survivesARoundTripThroughTheKeychain() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601

        let stored = try decoder.decode(OAuthToken.self, from: encoder.encode(token(for: config)))
        #expect(stored.matches(config))
    }
}

// What the user pastes back when the provider only redirects to somewhere out of reach.
struct RedirectAnswerTests {

    @Test func takesTheCodeOutOfAPastedURL() {
        let url = "https://oauth.pstmn.io/v1/callback?iss=https%3A%2F%2Fid.example&code=sZBlNt0J3&state=abc"
        guard case .code(let code, let state) = RedirectAnswer.parse(url) else {
            Issue.record("expected a code")
            return
        }
        #expect(code == "sZBlNt0J3")
        #expect(state == "abc")
    }

    // Copying the whole address bar is the obvious move, but so is copying just the code.
    @Test func takesACodePastedOnItsOwn() {
        guard case .code(let code, let state) = RedirectAnswer.parse("  sZBlNt0J3XjM6IOBc3iRDngeK8x7snX7 ") else {
            Issue.record("expected a code")
            return
        }
        #expect(code == "sZBlNt0J3XjM6IOBc3iRDngeK8x7snX7")
        #expect(state == nil)
    }

    @Test func readsARefusalInThePastedURL() {
        let url = "https://oauth.pstmn.io/v1/callback?error=access_denied&error_description=Nope"
        guard case .refused(let message) = RedirectAnswer.parse(url) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(message == "access_denied: Nope")
    }

    @Test func rejectsWhatIsNotAnAnswerAtAll() {
        for text in ["", "   ", "https://id.example/signed-in", "some words here"] {
            guard case .unreadable = RedirectAnswer.parse(text) else {
                Issue.record("expected \(text) to be unreadable")
                return
            }
        }
    }
}

struct ApiEnvironmentTests {

    @Test func resolvesEnvEverywhereItAppears() {
        let template = "https://api.{{env}}.example/v1/{{env}}/payments"
        #expect(ApiEnvironment.staging.resolve(template) == "https://api.dev.example/v1/dev/payments")
        #expect(ApiEnvironment.production.resolve(template) == "https://api.prd.example/v1/prd/payments")
    }

    // An unknown variable staying as typed is what makes the typo visible.
    @Test func leavesUnknownVariablesAlone() {
        #expect(ApiEnvironment.staging.resolve("https://api.{{environment}}.example")
                == "https://api.{{environment}}.example")
        #expect(ApiEnvironment.staging.resolve("no variables here") == "no variables here")
    }

    @Test func shortensTheTokenURLToItsHostForTheCard() {
        let config = OAuthConfig(tokenURL: "https://auth.dev.example/oauth2/token")
        #expect(config.tokenHost == "auth.dev.example/oauth2/token")
    }
}

struct SavedRequestTests {

    // The requests file gains fields over time, and a file written before one existed has
    // to keep loading or the whole collection is lost.
    @Test func loadsAFileWrittenBeforeAFieldExisted() throws {
        let json = """
        [{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","name":"Old","method":"GET",
          "url":"https://example.test","headers":[],"bodyType":"none","body":""}]
        """
        let requests = try JSONDecoder().decode([SavedRequest].self, from: Data(json.utf8))

        #expect(requests.count == 1)
        #expect(requests[0].name == "Old")
        #expect(requests[0].useAuth)
    }

    @Test func survivesARoundTripThroughTheFile() throws {
        let request = SavedRequest(name: "Fetch", method: .post, url: "https://example.test",
                                   headers: [HeaderField(key: "X-Trace", value: "1", enabled: false)],
                                   bodyType: .json, body: "{}", useAuth: false)
        let data = try JSONEncoder().encode([request])

        #expect(try JSONDecoder().decode([SavedRequest].self, from: data) == [request])
    }
}
