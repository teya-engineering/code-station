import Foundation
import Testing
@testable import MenuBarApp

// A request that signs in with a username and password keeps the password in the
// Keychain, so these cover the two things that makes tricky: getting it back on the next
// launch, and letting go of it when the request it belongs to is gone.
@MainActor
struct BasicAuthTests {
    @Test func buildsTheHeaderFromTheUsernameAndPassword() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = UUID()
        let store = authStore(in: directory, keychain: Vault())
        store.setBasicPassword("s3cr3t", for: request)

        let header = store.basicHeader(username: " svc-orders ", requestID: request)

        #expect(header == "Basic " + Data("svc-orders:s3cr3t".utf8).base64EncodedString())
    }

    @Test func sendsNothingWhenNeitherHalfIsFilledIn() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = authStore(in: directory, keychain: Vault())

        #expect(store.basicHeader(username: "", requestID: UUID()) == nil)
    }

    @Test func keepsThePasswordInTheKeychainRatherThanTheFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = Vault()
        let request = UUID()
        let store = authStore(in: directory, keychain: vault)
        store.setBasicPassword("s3cr3t", for: request)

        #expect(store.save())
        #expect(vault[.basicPassword(for: request)] == "s3cr3t")
        let file = try String(contentsOf: storeURL(in: directory), encoding: .utf8)
        #expect(!file.contains("s3cr3t"))

        // What a later launch sees: a fresh store reading the same Keychain.
        #expect(authStore(in: directory, keychain: vault).basicPassword(for: request) == "s3cr3t")
    }

    @Test func clearingThePasswordTakesItOutOfTheKeychain() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = Vault()
        let request = UUID()
        let store = authStore(in: directory, keychain: vault)
        store.setBasicPassword("s3cr3t", for: request)
        #expect(store.save())

        store.setBasicPassword("", for: request)

        #expect(store.save())
        #expect(vault[.basicPassword(for: request)] == nil)
    }

    @Test func deletingARequestDoesNotLeaveItsPasswordBehind() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = Vault()
        let request = UUID()
        let store = authStore(in: directory, keychain: vault)
        store.setBasicPassword("s3cr3t", for: request)
        #expect(store.save())

        store.forgetBasicPassword(for: request)

        #expect(vault[.basicPassword(for: request)] == nil)
    }

    @Test func aDuplicatedRequestSignsInAsTheOriginal() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = UUID()
        let copy = UUID()
        let store = authStore(in: directory, keychain: Vault())
        store.setBasicPassword("s3cr3t", for: request)

        store.copyBasicPassword(from: request, to: copy)

        #expect(store.basicPassword(for: copy) == "s3cr3t")
    }

    // A password sits in the same Keychain item as the OAuth secrets, so writing one must
    // not carry off the other.
    @Test func keepsTheClientSecretsAlongsideThePasswords() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = Vault()
        let request = UUID()
        let store = authStore(in: directory, keychain: vault)
        var staging = store.staging
        staging.clientSecret = "client-secret"
        store.setConfig(staging, for: .staging)
        store.setBasicPassword("s3cr3t", for: request)

        #expect(store.save())
        #expect(vault[.stagingClientSecret] == "client-secret")
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

    private func authStore(in directory: URL, keychain: Vault) -> DispatchAuthStore {
        DispatchAuthStore(storeURL: storeURL(in: directory), keychain: keychain.client)
    }

    private func storeURL(in directory: URL) -> URL {
        directory.appendingPathComponent("dispatch-auth.json")
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("basic-auth-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
