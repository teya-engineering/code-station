import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct PersistenceSafetyTests {
    @Test func configDecodeFailureDoesNotOverwriteTheFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("config.json")
        let malformed = Data("not config json".utf8)
        try malformed.write(to: file)

        let store = ConfigStore(configURL: file)
        #expect(store.loadError != nil)

        store.upsertGrafana(scope: .platform, env: .dev, token: "must stay in memory")

        #expect(store.saveError != nil)
        #expect(try Data(contentsOf: file) == malformed)
    }

    @Test func failedConfigWriteStaysDirtyAndCanBeRetried() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.json")
        let failures = FileFailureController()
        failures.failWrites(to: file)
        let store = ConfigStore(configURL: file, files: failures.client)

        store.upsertGrafana(scope: .platform, env: .dev, token: "token")

        #expect(store.saveError != nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        failures.allowWrites(to: file)

        #expect(store.flushPendingSave())
        #expect(store.saveError == nil)
        #expect(ConfigStore(configURL: file).servers.map(\.name) == ["grafana-platform-dev"])
    }

    @Test func projectIndexDecodeFailureDoesNotOverwriteTheFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("projects.json")
        let malformed = Data("not project json".utf8)
        try malformed.write(to: file)

        let store = ProjectStore(storeURL: file)
        #expect(store.loadError != nil)

        _ = store.addProject(at: directory.appendingPathComponent("project"))

        #expect(!store.save())
        #expect(try Data(contentsOf: file) == malformed)
    }

    @Test func malformedTranscriptIsNotReplacedByLaterMessages() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("projects.json")
        let original = ProjectStore(storeURL: index)
        let project = try #require(original.addProject(
            at: directory.appendingPathComponent("project")))
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
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("projects.json")
        let store = ProjectStore(storeURL: index)

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

    @Test func postmanDecodeFailureDoesNotOverwriteTheFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("postman.json")
        let malformed = Data("not request json".utf8)
        try malformed.write(to: file)

        let store = PostmanStore(storeURL: file)
        #expect(store.loadError != nil)

        store.add(SavedRequest(name: "Must stay in memory"))

        #expect(!store.save())
        #expect(try Data(contentsOf: file) == malformed)
    }

    @Test func postmanWriteFailureIsReportedAndCanBeRetried() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("postman.json")
        let store = PostmanStore(storeURL: file)

        try Data("a file where a directory should be".utf8).write(to: directory)
        store.add(SavedRequest(name: "Retained request"))

        #expect(store.saveError != nil)

        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        #expect(store.save())
        #expect(store.saveError == nil)
        #expect(PostmanStore(storeURL: file).requests.contains { $0.name == "Retained request" })
    }

    @Test func oauthDecodeFailureDoesNotOverwriteTheFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("postman-auth.json")
        let malformed = Data("not oauth json".utf8)
        try malformed.write(to: file)

        let store = PostmanAuthStore(storeURL: file, keychain: .empty)
        #expect(store.loadError != nil)

        var staging = store.staging
        staging.clientID = "edited"
        store.setConfig(staging, for: .staging)

        #expect(!store.save())
        #expect(try Data(contentsOf: file) == malformed)
    }

    @Test func failedKeychainWriteIsRetried() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keychain = KeychainStub()
        keychain.shouldFailWrites = true
        let store = PostmanAuthStore(
            storeURL: directory.appendingPathComponent("postman-auth.json"),
            keychain: keychain.client)
        var staging = store.staging
        staging.clientSecret = "secret"
        store.setConfig(staging, for: .staging)

        #expect(!store.save())
        #expect(store.saveError != nil)
        #expect(keychain.writeAttempts == 1)

        keychain.shouldFailWrites = false

        #expect(store.save())
        #expect(store.saveError == nil)
        #expect(keychain.writeAttempts == 2)
        #expect(keychain.value(for: .stagingClientSecret) == "secret")
    }

    @Test func readsTheCombinedKeychainItemOnce() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keychain = KeychainStub(values: [
            .stagingClientSecret: "staging-secret",
            .productionClientSecret: "production-secret"
        ])

        let store = PostmanAuthStore(
            storeURL: directory.appendingPathComponent("postman-auth.json"),
            keychain: keychain.client)

        #expect(keychain.readAttempts == 1)
        #expect(store.staging.clientSecret == "staging-secret")
        #expect(store.production.clientSecret == "production-secret")
    }

    @Test func writesAllKeychainChangesTogether() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keychain = KeychainStub()
        let store = PostmanAuthStore(
            storeURL: directory.appendingPathComponent("postman-auth.json"),
            keychain: keychain.client)
        var staging = store.staging
        staging.clientSecret = "staging-secret"
        store.setConfig(staging, for: .staging)
        var production = store.production
        production.clientSecret = "production-secret"
        store.setConfig(production, for: .production)

        #expect(store.save())
        #expect(keychain.writeAttempts == 1)
        #expect(keychain.value(for: .stagingClientSecret) == "staging-secret")
        #expect(keychain.value(for: .productionClientSecret) == "production-secret")
    }

    @Test func queuedWriteCannotRecreateADeletedTranscript() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProjectStore(storeURL: directory.appendingPathComponent("projects.json"))
        let project = try #require(store.addProject(
            at: directory.appendingPathComponent("project")))
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
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("projects.json")
        let failures = FileFailureController()
        let store = ProjectStore(storeURL: index, files: failures.client)
        let project = try #require(store.addProject(
            at: directory.appendingPathComponent("project")))
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
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("projects.json")
        let failures = FileFailureController()
        let store = ProjectStore(storeURL: index, files: failures.client)
        let project = try #require(store.addProject(
            at: directory.appendingPathComponent("project")))
        let session = store.newSession(in: project.id,
                                       worktreePath: "/worktrees/project",
                                       worktreeBranch: "conductor/test")
        #expect(store.save())

        let pending = try #require(store.prepareSessionRemoval(session.id).value)
        #expect(store.session(session.id) == nil)
        #expect(pending.worktrees == [PendingSessionRemoval.Worktree(
            path: "/worktrees/project", projectPath: project.path,
            branch: "conductor/test")])

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
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("projects.json")
        let failures = FileFailureController()
        let store = ProjectStore(storeURL: index, files: failures.client)
        let project = try #require(store.addProject(
            at: directory.appendingPathComponent("project")))
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

    @Test func cancellingBeforeCleanupRestoresTheSessionAndTranscript() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("projects.json")
        let store = ProjectStore(storeURL: index)
        let project = try #require(store.addProject(
            at: directory.appendingPathComponent("project")))
        let session = store.newSession(in: project.id)
        store.append(ChatMessage(role: .user, text: "still here"), to: session.id)

        _ = try #require(store.prepareSessionRemoval(session.id).value)
        #expect(store.session(session.id) == nil)
        #expect(store.cancelSessionRemoval(session.id).isSuccess)

        #expect(store.session(session.id) != nil)
        #expect(store.transcript(of: session.id).map(\.text) == ["still here"])
        #expect(store.pendingSessionRemovals.isEmpty)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("persistence-safety-\(UUID().uuidString)")
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
