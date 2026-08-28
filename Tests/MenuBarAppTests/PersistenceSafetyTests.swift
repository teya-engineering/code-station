import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct PersistenceSafetyTests {
    private let scratch = ScratchDirectory(prefix: "persistence-safety")

    private var directory: URL { scratch.url }

    private var grafanaPreset: SiteDefaults.MCP.Preset {
        .init(name: "grafana-platform-dev",
              environment: "dev",
              command: "mcp-grafana",
              env: [
                .init(key: "GRAFANA_URL", value: "https://grafana.example"),
                .init(key: "GRAFANA_SERVICE_ACCOUNT_TOKEN", value: ""),
              ])
    }

    @Test func configDecodeFailureDoesNotOverwriteTheFile() throws {
        let file = scratch.path("config.json")
        let malformed = Data("not config json".utf8)
        try malformed.write(to: file)

        let store = ConfigStore(configURL: file)
        #expect(store.loadError != nil)

        store.upsert(preset: grafanaPreset,
                     environmentValues: ["GRAFANA_SERVICE_ACCOUNT_TOKEN": "must stay in memory"])

        #expect(store.saveError != nil)
        #expect(try Data(contentsOf: file) == malformed)
    }

    @Test func failedConfigWriteStaysDirtyAndCanBeRetried() throws {
        let file = scratch.path("config.json")
        let failures = FileFailureController()
        failures.failWrites(to: file)
        let store = ConfigStore(configURL: file, files: failures.client)

        store.upsert(preset: grafanaPreset,
                     environmentValues: ["GRAFANA_SERVICE_ACCOUNT_TOKEN": "token"])

        #expect(store.saveError != nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        failures.allowWrites(to: file)

        #expect(store.flushPendingSave())
        #expect(store.saveError == nil)
        #expect(ConfigStore(configURL: file).servers.map(\.name) == ["grafana-platform-dev"])
    }

    @Test func projectIndexDecodeFailureDoesNotOverwriteTheFile() throws {
        let file = scratch.path("projects.json")
        let malformed = Data("not project json".utf8)
        try malformed.write(to: file)

        let store = ProjectStore(storeURL: file)
        #expect(store.loadError != nil)

        _ = store.addProject(at: scratch.path("project"))

        #expect(!store.save())
        #expect(try Data(contentsOf: file) == malformed)
    }

    @Test func malformedTranscriptIsNotReplacedByLaterMessages() throws {
        let index = scratch.path("projects.json")
        let original = ProjectStore(storeURL: index)
        let project = try #require(original.addProject(at: scratch.path("project")))
        let session = original.newSession(in: project.id)
        original.append(ChatMessage(role: .user, text: "saved message"), to: session.id)
        #expect(original.save())

        let transcript = original.transcriptsURL
            .appendingPathComponent("\(session.id.uuidString).json")
        let malformed = Data("not transcript json".utf8)
        try malformed.write(to: transcript)

        let loaded = ProjectStore(storeURL: index)
        _ = loaded.transcript(of: session.id)
        #expect(loaded.transcriptLoadErrors[session.id] != nil)

        loaded.append(ChatMessage(role: .user, text: "must not replace it"), to: session.id)

        #expect(!loaded.save())
        #expect(try Data(contentsOf: transcript) == malformed)
    }

    @Test func failedProjectWriteStaysDirtyAndCanBeRetried() throws {
        let index = scratch.path("projects.json")
        let store = ProjectStore(storeURL: index)

        // A file sits where the store's folder should be, so the write cannot land.
        try FileManager.default.removeItem(at: directory)
        try Data("a file where a directory should be".utf8).write(to: directory)
        _ = store.addProject(at: URL(fileURLWithPath: "/tmp/project"))

        #expect(!store.save())
        #expect(store.saveError != nil)

        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        #expect(store.save())
        #expect(store.saveError == nil)
        #expect(ProjectStore(storeURL: index).projects.count == 1)
    }

    @Test func dispatchDecodeFailureDoesNotOverwriteTheFile() throws {
        let file = scratch.path("dispatch.json")
        let malformed = Data("not request json".utf8)
        try malformed.write(to: file)

        let store = DispatchStore(storeURL: file, siteDefaults: SiteDefaults())
        #expect(store.loadError != nil)

        store.add(SavedRequest(name: "Must stay in memory"))

        #expect(!store.save())
        #expect(try Data(contentsOf: file) == malformed)
    }

    @Test func dispatchWriteFailureIsReportedAndCanBeRetried() throws {
        let file = scratch.path("dispatch.json")
        let store = DispatchStore(storeURL: file, siteDefaults: SiteDefaults())

        // A file sits where the store's folder should be, so the write cannot land.
        try FileManager.default.removeItem(at: directory)
        try Data("a file where a directory should be".utf8).write(to: directory)
        store.add(SavedRequest(name: "Retained request"))

        #expect(store.saveError != nil)

        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        #expect(store.save())
        #expect(store.saveError == nil)
        #expect(DispatchStore(storeURL: file, siteDefaults: SiteDefaults())
            .requests.contains { $0.name == "Retained request" })
    }

    @Test func oauthDecodeFailureDoesNotOverwriteTheFile() throws {
        let file = scratch.path("dispatch-auth.json")
        let malformed = Data("not oauth json".utf8)
        try malformed.write(to: file)

        let store = DispatchAuthStore(storeURL: file,
                                      keychain: .empty,
                                      siteDefaults: SiteDefaults())
        #expect(store.loadError != nil)

        let environment = store.environments[0]
        var config = store.config(for: environment)
        config.clientID = "edited"
        store.setConfig(config, for: environment)

        #expect(!store.save())
        #expect(try Data(contentsOf: file) == malformed)
    }

    @Test func failedKeychainWriteIsRetried() throws {
        let keychain = KeychainStub()
        keychain.shouldFailWrites = true
        let store = DispatchAuthStore(
            storeURL: scratch.path("dispatch-auth.json"),
            keychain: keychain.client,
            siteDefaults: SiteDefaults())
        let environment = store.environments[0]
        var config = store.config(for: environment)
        config.clientSecret = "secret"
        store.setConfig(config, for: environment)

        #expect(!store.save())
        #expect(store.saveError != nil)
        #expect(keychain.writeAttempts == 1)

        keychain.shouldFailWrites = false

        #expect(store.save())
        #expect(store.saveError == nil)
        #expect(keychain.writeAttempts == 2)
        #expect(keychain.value(for: .dispatchClientSecret(for: "staging")) == "secret")
    }

    @Test func readsTheCombinedKeychainItemOnce() throws {
        let keychain = KeychainStub(values: [
            .stagingClientSecret: "staging-secret",
            .productionClientSecret: "production-secret"
        ])

        let store = DispatchAuthStore(
            storeURL: scratch.path("dispatch-auth.json"),
            keychain: keychain.client,
            siteDefaults: SiteDefaults())

        #expect(keychain.readAttempts == 1)
        #expect(store.config(for: store.environments[0]).clientSecret == "staging-secret")
        #expect(store.config(for: store.environments[1]).clientSecret == "production-secret")
    }

    @Test func mapsPreviousKeychainAccountsToDispatch() {
        let values = Keychain.normalizedValues([
            "postman.staging.client-secret": "staging-secret",
            "postman.production.token": "production-token"
        ])

        #expect(values["dispatch.staging.client-secret"] == "staging-secret")
        #expect(values["dispatch.production.token"] == "production-token")
        #expect(values["postman.staging.client-secret"] == nil)
    }

    @Test func writesAllKeychainChangesTogether() throws {
        let keychain = KeychainStub()
        let store = DispatchAuthStore(
            storeURL: scratch.path("dispatch-auth.json"),
            keychain: keychain.client,
            siteDefaults: SiteDefaults())
        let staging = store.environments[0]
        var stagingConfig = store.config(for: staging)
        stagingConfig.clientSecret = "staging-secret"
        store.setConfig(stagingConfig, for: staging)
        let production = store.environments[1]
        var productionConfig = store.config(for: production)
        productionConfig.clientSecret = "production-secret"
        store.setConfig(productionConfig, for: production)

        #expect(store.save())
        #expect(keychain.writeAttempts == 1)
        #expect(keychain.value(for: .dispatchClientSecret(for: "staging")) == "staging-secret")
        #expect(keychain.value(for: .dispatchClientSecret(for: "production")) == "production-secret")
    }

    @Test func keepsSettingsForEveryConfiguredEnvironment() throws {
        let file = scratch.path("dispatch-auth.json")
        let keychain = KeychainStub()
        let defaults = SiteDefaults(
            dispatch: .init(oauth: .init(tokenURL: "https://id.example/token",
                                         clientID: "shared-client")),
            environments: [
                .init(name: "dev", title: "Development"),
                .init(name: "prd", title: "Production", danger: true),
                .init(name: "shared", title: "Shared")
            ])
        let store = DispatchAuthStore(storeURL: file,
                                      keychain: keychain.client,
                                      siteDefaults: defaults)

        #expect(store.environments.map(\.name) == ["dev", "prd", "shared"])
        #expect(store.environments.map(\.label) == ["Development", "Production", "Shared"])
        #expect(store.environments.map(\.isDangerous) == [false, true, false])

        let shared = try #require(store.environments.first { $0.name == "shared" })
        var sharedConfig = store.config(for: shared)
        sharedConfig.clientID = "shared-environment-client"
        sharedConfig.clientSecret = "shared-secret"
        store.setConfig(sharedConfig, for: shared)
        store.active = shared

        #expect(store.save())
        #expect(keychain.value(for: .dispatchClientSecret(for: "shared")) == "shared-secret")

        let restored = DispatchAuthStore(storeURL: file,
                                         keychain: keychain.client,
                                         siteDefaults: defaults)
        let restoredShared = try #require(restored.environments.first { $0.name == "shared" })
        #expect(restored.active == restoredShared)
        #expect(restored.config(for: restoredShared).clientID == "shared-environment-client")
        #expect(restored.config(for: restoredShared).clientSecret == "shared-secret")

        var changedDefaults = defaults
        changedDefaults.environments = [
            .init(name: "sandbox", title: "Sandbox"),
            .init(name: "live", title: "Live", danger: true)
        ]
        restored.applyEnvironments(from: changedDefaults)

        #expect(restored.environments.map(\.name) == ["sandbox", "live"])
        #expect(restored.active.name == "sandbox")
        #expect(restored.config(for: restored.active).clientID == "shared-client")
    }

    @Test func migratesFixedOAuthSlotsToConfiguredEnvironmentNames() throws {
        let file = scratch.path("dispatch-auth.json")
        try JSONEncoder().encode(PreviousDispatchAuth(
            active: "production",
            staging: OAuthConfig(clientID: "development-client"),
            production: OAuthConfig(clientID: "production-client")))
            .write(to: file)
        let keychain = KeychainStub(values: [
            .stagingClientSecret: "development-secret",
            .productionClientSecret: "production-secret"
        ])
        let defaults = SiteDefaults(
            dispatch: .init(oauth: .init(clientID: "shared-client"),
                            environments: .init(staging: "dev", production: "prd")),
            environments: [
                .init(name: "dev", title: "Development"),
                .init(name: "prd", title: "Production", danger: true),
                .init(name: "shared", title: "Shared")
            ])

        let store = DispatchAuthStore(storeURL: file,
                                      keychain: keychain.client,
                                      siteDefaults: defaults)
        let dev = try #require(store.environments.first { $0.name == "dev" })
        let prd = try #require(store.environments.first { $0.name == "prd" })
        let shared = try #require(store.environments.first { $0.name == "shared" })

        #expect(store.active == prd)
        #expect(store.config(for: dev).clientID == "development-client")
        #expect(store.config(for: dev).clientSecret == "development-secret")
        #expect(store.config(for: prd).clientID == "production-client")
        #expect(store.config(for: prd).clientSecret == "production-secret")
        #expect(store.config(for: shared).clientID == "shared-client")
    }

    @Test func queuedWriteCannotRecreateADeletedTranscript() async throws {
        let store = ProjectStore(storeURL: scratch.path("projects.json"))
        let project = try #require(store.addProject(at: scratch.path("project")))
        let session = store.newSession(in: project.id)
        store.append(ChatMessage(role: .assistant,
                                 text: String(repeating: "x", count: 12_000_000)),
                     to: session.id)

        try await Task.sleep(for: .milliseconds(1_005))
        store.removeSession(session.id)

        let transcript = store.transcriptsURL
            .appendingPathComponent("\(session.id.uuidString).json")
        #expect(!FileManager.default.fileExists(atPath: transcript.path))
    }

    @Test func failedSessionInsertionIsReportedAndRolledBack() throws {
        let index = scratch.path("projects.json")
        let failures = FileFailureController()
        let store = ProjectStore(storeURL: index, files: failures.client)
        let project = try #require(store.addProject(at: scratch.path("project")))
        failures.failWrites(to: index)

        let result = store.insertSession(in: project.id)

        guard case .failure(let failure) = result else {
            Issue.record("Expected insertion to fail")
            return
        }
        #expect(failure.message.contains("could not be saved"))
        #expect(store.sessions.isEmpty)
        #expect(ProjectStore(storeURL: index).sessions.isEmpty)
    }

    @Test func pendingRemovalPreventsADeletedSessionFromReappearing() throws {
        let index = scratch.path("projects.json")
        let failures = FileFailureController()
        let store = ProjectStore(storeURL: index, files: failures.client)
        let project = try #require(store.addProject(at: scratch.path("project")))
        let session = store.newSession(in: project.id,
                                       worktreePath: "/worktrees/project",
                                       worktreeBranch: "code-station/test")
        #expect(store.save())

        let pending = try #require(store.prepareSessionRemoval(session.id).value)
        #expect(store.session(session.id) == nil)
        #expect(pending.worktrees == [PendingSessionRemoval.Worktree(
            path: "/worktrees/project", projectPath: project.path,
            branch: "code-station/test")])

        failures.failWrites(to: index)
        guard case .failure = store.finishSessionRemoval(session.id) else {
            Issue.record("Expected the index write to fail")
            return
        }

        let restarted = ProjectStore(storeURL: index)
        #expect(restarted.session(session.id) == nil)
        #expect(restarted.pendingSessionRemovals.map(\.id) == [session.id])
        #expect(restarted.finishSessionRemoval(session.id).isSuccess)

        let recovered = ProjectStore(storeURL: index)
        #expect(recovered.session(session.id) == nil)
        #expect(recovered.pendingSessionRemovals.isEmpty)
    }

    @Test func transcriptDeleteFailureStaysPendingAndCanBeRetried() throws {
        let index = scratch.path("projects.json")
        let failures = FileFailureController()
        let store = ProjectStore(storeURL: index, files: failures.client)
        let project = try #require(store.addProject(at: scratch.path("project")))
        let session = store.newSession(in: project.id)
        store.append(ChatMessage(role: .user, text: "keep until deletion succeeds"),
                     to: session.id)
        #expect(store.save())
        let transcript = store.transcriptsURL
            .appendingPathComponent("\(session.id.uuidString).json")
        _ = try #require(store.prepareSessionRemoval(session.id).value)
        failures.failRemovals(of: transcript)

        guard case .failure(let failure) = store.finishSessionRemoval(session.id) else {
            Issue.record("Expected transcript deletion to fail")
            return
        }
        #expect(failure.message.contains("could not be deleted"))
        #expect(FileManager.default.fileExists(atPath: transcript.path))
        #expect(store.pendingSessionRemovals.map(\.id) == [session.id])

        failures.allowRemovals(of: transcript)
        #expect(store.finishSessionRemoval(session.id).isSuccess)
        #expect(!FileManager.default.fileExists(atPath: transcript.path))
        #expect(store.pendingSessionRemovals.isEmpty)
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var value: Success? {
        if case .success(let value) = self { return value }
        return nil
    }
}

private struct PreviousDispatchAuth: Codable {
    var active: String
    var staging: OAuthConfig
    var production: OAuthConfig
}

private extension KeychainClient {
    static var empty: KeychainClient {
        KeychainClient(read: { [:] }, write: { _ in })
    }
}

private final class KeychainStub: @unchecked Sendable {
    private struct WriteFailure: Error {}

    private let lock = NSLock()
    private var values: [Keychain.Account: String] = [:]
    private var failing = false
    private var reads = 0
    private var attempts = 0

    init(values: [Keychain.Account: String] = [:]) {
        self.values = values
    }

    var client: KeychainClient {
        KeychainClient(
            read: { [self] in read() },
            write: { [self] values in try write(values) }
        )
    }

    var shouldFailWrites: Bool {
        get { withLock { failing } }
        set { withLock { failing = newValue } }
    }

    var readAttempts: Int { withLock { reads } }
    var writeAttempts: Int { withLock { attempts } }

    func value(for account: Keychain.Account) -> String? {
        withLock { values[account] }
    }

    private func read() -> [Keychain.Account: String] {
        withLock {
            reads += 1
            return values
        }
    }

    private func write(_ values: [Keychain.Account: String]) throws {
        try withLock {
            attempts += 1
            if failing { throw WriteFailure() }
            self.values = values
        }
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

private final class FileFailureController: @unchecked Sendable {
    private struct ExpectedFailure: Error {}

    private let lock = NSLock()
    private var failedWrites: Set<String> = []
    private var failedRemovals: Set<String> = []

    var client: PersistentFileClient {
        PersistentFileClient(
            readIfPresent: { try PersistentFile.readIfPresent($0) },
            write: { [self] data, url in
                if withLock({ failedWrites.contains(url.path) }) { throw ExpectedFailure() }
                try PersistentFile.write(data, to: url)
            },
            removeIfPresent: { [self] url in
                if withLock({ failedRemovals.contains(url.path) }) { throw ExpectedFailure() }
                try PersistentFile.removeIfPresent(url)
            })
    }

    func failWrites(to url: URL) {
        _ = withLock { failedWrites.insert(url.path) }
    }

    func allowWrites(to url: URL) {
        _ = withLock { failedWrites.remove(url.path) }
    }

    func failRemovals(of url: URL) {
        _ = withLock { failedRemovals.insert(url.path) }
    }

    func allowRemovals(of url: URL) {
        _ = withLock { failedRemovals.remove(url.path) }
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
