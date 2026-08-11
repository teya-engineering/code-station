import CryptoKit
import Foundation

// The two grants worth having here: the browser dance for calling an API as yourself,
// and the straight token call for service-to-service credentials.
enum GrantType: String, CaseIterable, Identifiable, Codable {
    case authorizationCodePKCE, clientCredentials

    var id: String { rawValue }

    var label: String {
        switch self {
        case .authorizationCodePKCE: "Authorization Code (PKCE)"
        case .clientCredentials: "Client Credentials"
        }
    }

    var usesBrowser: Bool { self == .authorizationCodePKCE }
}

// Where the client id and secret go on the token call. Providers differ, and sending
// them the wrong way is a plain 401 with no hint, so it is a setting rather than a guess.
enum ClientAuthentication: String, CaseIterable, Identifiable, Codable {
    case body, basicHeader

    var id: String { rawValue }

    var label: String {
        switch self {
        case .body: "Send client credentials in body"
        case .basicHeader: "Send as Basic Auth header"
        }
    }
}

// What a token is good for. A token belongs to the client and the provider that issued it,
// so the settings that produced it are kept beside it and checked before it is sent.
struct TokenIdentity: Codable, Equatable {
    var grant: GrantType
    var authURL: String
    var tokenURL: String
    var clientID: String
    var scope: String
}

// One environment's whole OAuth setup. The secret lives in the Keychain; the store's
// file only ever holds the addresses and the client id.
struct OAuthConfig: Codable, Equatable {
    var grant: GrantType = .authorizationCodePKCE
    var authURL = ""
    var tokenURL = ""
    var clientID = ""
    var clientSecret = ""
    var scope = ""
    var state = ""
    // The redirect the identity provider sends the browser back to. It has to be one the
    // provider already allows for this client, which is why it is editable.
    var callbackURL = "http://127.0.0.1:8234/callback"
    var headerPrefix = "Bearer"
    var clientAuth: ClientAuthentication = .body

    // The parts of the setup a token is tied to. The rest - the callback, the header
    // prefix, where the secret goes - only shapes how the token is fetched.
    var identity: TokenIdentity {
        TokenIdentity(grant: grant, authURL: authURL.trimmed, tokenURL: tokenURL.trimmed,
                      clientID: clientID.trimmed, scope: scope.trimmed)
    }

    // Pasted values arrive with stray whitespace, and an identity provider answers a
    // client id with a trailing space as an unknown client. Every field is trimmed
    // before it goes anywhere near a request.
    func cleaned() -> OAuthConfig {
        var config = self
        config.authURL = authURL.trimmed
        config.tokenURL = tokenURL.trimmed
        config.clientID = clientID.trimmed
        config.clientSecret = clientSecret.trimmed
        config.scope = scope.trimmed
        config.state = state.trimmed
        config.callbackURL = callbackURL.trimmed
        config.headerPrefix = headerPrefix.trimmed
        return config
    }

    var callbackPort: UInt16? {
        guard let port = URLComponents(string: callbackURL)?.port else { return nil }
        return UInt16(exactly: port)
    }

    // A callback on this machine can be caught by listening for it. Anything else, such as
    // a provider that only allows a callback owned by another client, ends up on a page
    // so the code has to be carried back by hand.
    var usesLoopback: Bool {
        guard let host = URLComponents(string: callbackURL)?.host else { return false }
        return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
    }

    // Everything the chosen grant cannot run without.
    var missing: [String] {
        var gaps: [String] = []
        if tokenURL.trimmed.isEmpty { gaps.append("Access token URL") }
        if clientID.trimmed.isEmpty { gaps.append("Client ID") }
        if grant.usesBrowser {
            if authURL.trimmed.isEmpty { gaps.append("Auth URL") }
            if callbackURL.trimmed.isEmpty { gaps.append("Callback URL") }
            if usesLoopback, callbackPort == nil { gaps.append("a port on the callback URL") }
        }
        return gaps
    }

    // The token endpoint without its scheme, short enough for the token card's one line.
    var tokenHost: String {
        tokenURL
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }
}

// What the browser ended up on, pasted back by hand. Providers put the code in the query
// of the redirect, so either the whole URL or the code on its own is enough to go on.
enum RedirectAnswer {
    case code(String, state: String?)
    case refused(String)
    case unreadable

    static func parse(_ text: String) -> RedirectAnswer {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unreadable }

        if let items = URLComponents(string: trimmed)?.queryItems, !items.isEmpty {
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            if let error = value("error") {
                return .refused([error, value("error_description")].compactMap { $0 }.joined(separator: ": "))
            }
            if let code = value("code") { return .code(code, state: value("state")) }
            return .unreadable
        }

        // A code copied on its own, without the URL around it.
        guard !trimmed.contains(where: \.isWhitespace), !trimmed.contains("://") else { return .unreadable }
        return .code(trimmed, state: nil)
    }
}

struct OAuthToken: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var tokenType: String
    var scope: String?
    var expiresAt: Date?
    var obtainedAt: Date
    // Missing on a token stored before this was recorded. That says nothing about where the
    // token came from, so such a token is taken at face value rather than thrown away.
    var identity: TokenIdentity?

    func matches(_ config: OAuthConfig) -> Bool {
        identity == nil || identity == config.identity
    }

    var isExpired: Bool {
        guard let expiresAt else { return false }
        // A token that dies in the next few seconds is already useless to a request that
        // still has to travel.
        return expiresAt.timeIntervalSinceNow < 10
    }

    // The short remaining life on the token card: "41 min".
    var remainingText: String {
        guard let expiresAt else { return "no expiry" }
        let seconds = Int(expiresAt.timeIntervalSinceNow)
        if seconds <= 0 { return "expired" }
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return "\(seconds / 3600) h \((seconds % 3600) / 60) min"
    }

    // The full sentence in the Environments sheet: "Token valid for 41 min".
    var validityText: String {
        guard expiresAt != nil else { return "Token has no expiry" }
        return isExpired ? "Token expired" : "Token valid for \(remainingText)"
    }
}

// The provider's answer on the token endpoint, in both its shapes.
struct TokenResponse: Decodable {
    var accessToken: String?
    var refreshToken: String?
    var tokenType: String?
    var expiresIn: Double?
    var scope: String?
    var error: String?
    var errorDescription: String?

    func token(keepingRefresh existing: String?, identity: TokenIdentity?) -> OAuthToken? {
        guard let accessToken else { return nil }
        return OAuthToken(accessToken: accessToken,
                          refreshToken: refreshToken ?? existing,
                          tokenType: tokenType ?? "Bearer",
                          scope: scope,
                          expiresAt: expiresIn.map { Date().addingTimeInterval($0) },
                          obtainedAt: Date(),
                          identity: identity)
    }

    var failure: String? {
        guard let error else { return nil }
        return [error, errorDescription].compactMap { $0 }.joined(separator: ": ")
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

struct OAuthError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// PKCE: a secret made up per attempt, sent to the browser only as a hash, and proved on
// the token call. It is what makes a public client safe without a secret to leak.
enum PKCE {
    static func verifier() -> String {
        let allowed = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<64).map { _ in allowed.randomElement()! })
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
