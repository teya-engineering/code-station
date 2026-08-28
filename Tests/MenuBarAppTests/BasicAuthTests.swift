import Foundation
import Testing
@testable import MenuBarApp

// A request that signs in with a username and password keeps the password in the
// Keychain, so these cover the two things that makes tricky: getting it back on the next
// launch, and letting go of it when the request it belongs to is gone.
@MainActor
struct BasicAuthTests {
    private let scratch = ScratchDirectory(prefix: "basic-auth")

    @Test func buildsTheHeaderFromTheUsernameAndPassword() {
        let request = UUID()
        let store = authStore(keychain: Vault())
        store.setBasicPassword("s3cr3t", for: request)

        let header = store.basicHeader(username: " svc-orders ", requestID: request)

        #expect(header == "Basic " + Data("svc-orders:s3cr3t".utf8).base64EncodedString())
    }

    @Test func sendsNothingWhenNeitherHalfIsFilledIn() {
        let store = authStore(keychain: Vault())

        #expect(store.basicHeader(username: "", requestID: UUID()) == nil)
    }

    @Test func keepsThePasswordInTheKeychainRatherThanTheFile() throws {
        let vault = Vault()
        let request = UUID()
        let store = authStore(keychain: vault)
        store.setBasicPassword("s3cr3t", for: request)

        #expect(store.save())
        #expect(vault[.basicPassword(for: request)] == "s3cr3t")
        let file = try String(contentsOf: storeURL, encoding: .utf8)
        #expect(!file.contains("s3cr3t"))

        // What a later launch sees: a fresh store reading the same Keychain.
        #expect(authStore(keychain: vault).basicPassword(for: request) == "s3cr3t")
    }

    @Test func clearingThePasswordTakesItOutOfTheKeychain() {
        let vault = Vault()
        let request = UUID()
        let store = authStore(keychain: vault)
        store.setBasicPassword("s3cr3t", for: request)
        #expect(store.save())

        store.setBasicPassword("", for: request)

        #expect(store.save())
        #expect(vault[.basicPassword(for: request)] == nil)
    }

    @Test func deletingARequestDoesNotLeaveItsPasswordBehind() {
        let vault = Vault()
        let request = UUID()
        let store = authStore(keychain: vault)
        store.setBasicPassword("s3cr3t", for: request)
        #expect(store.save())

        store.forgetBasicPassword(for: request)

        #expect(vault[.basicPassword(for: request)] == nil)
    }

    @Test func aDuplicatedRequestSignsInAsTheOriginal() {
        let request = UUID()
        let copy = UUID()
        let store = authStore(keychain: Vault())
        store.setBasicPassword("s3cr3t", for: request)

        store.copyBasicPassword(from: request, to: copy)

        #expect(store.basicPassword(for: copy) == "s3cr3t")
    }

    // A password sits in the same Keychain item as the OAuth secrets, so writing one must
    // not carry off the other.
    @Test func keepsTheClientSecretsAlongsideThePasswords() {
        let vault = Vault()
        let request = UUID()
        let store = authStore(keychain: vault)
        let environment = store.environments[0]
        var config = store.config(for: environment)
        config.clientSecret = "client-secret"
        store.setConfig(config, for: environment)
        store.setBasicPassword("s3cr3t", for: request)

        #expect(store.save())
        #expect(vault[.dispatchClientSecret(for: "staging")] == "client-secret")
        #expect(vault[.basicPassword(for: request)] == "s3cr3t")
    }

    // MARK: - Helpers

    private final class Vault: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Keychain.Account: String] = [:]

        var client: KeychainClient {
            KeychainClient(read: { [self] in withLock { values } },
                           write: { [self] new in withLock { values = new } })
        }

        subscript(account: Keychain.Account) -> String? {
            withLock { values[account] }
        }

        private func withLock<T>(_ operation: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return operation()
        }
    }

    private func authStore(keychain: Vault) -> DispatchAuthStore {
        DispatchAuthStore(storeURL: storeURL,
                          keychain: keychain.client,
                          siteDefaults: SiteDefaults())
    }

    private var storeURL: URL {
        scratch.path("dispatch-auth.json")
    }
}
