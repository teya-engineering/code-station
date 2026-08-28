import Foundation
import Testing
@testable import MenuBarApp

// Polls until the condition holds or the timeout passes. Returns whether it held. The
// default window is generous because these waits cover real processes, and a loaded
// machine can take many times longer than a quiet one.
//
// The condition runs on the caller's actor, so a @MainActor test can read main-actor
// state in it without the closure having to be Sendable.
func waitUntil(timeout: Duration = .seconds(30),
               isolation: isolated (any Actor)? = #isolation,
               _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

// A throwaway folder under the temp directory, removed when the value goes away.
final class ScratchDirectory: @unchecked Sendable {
    let url: URL

    init(prefix: String = "code-station-test") {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func path(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }
}

// A throwaway git repository with the config tests need: an identity of its own and no
// commit signing, so nothing depends on the machine's git config.
final class GitRepo: @unchecked Sendable {
    let url: URL
    var path: String { url.path }
    private let scratch: ScratchDirectory

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    init(initialCommit: Bool = true) throws {
        scratch = ScratchDirectory(prefix: "git-repo")
        url = scratch.url
        try git("init", "-q", "-b", "main")
        try configureIdentity()
        guard initialCommit else { return }
        try write("README.md", "hello")
        try commit("first")
    }

    private init(scratch: ScratchDirectory) throws {
        self.scratch = scratch
        url = scratch.url
        try configureIdentity()
    }

    // Runs git in the repository and returns what it printed, trimmed. A failing command
    // throws with git's own complaint, so a broken fixture fails loudly.
    @discardableResult
    func git(_ args: String...) throws -> String {
        try Self.run(args, in: url)
    }

    func write(_ name: String, _ contents: String) throws {
        let file = url.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }

    func read(_ name: String) -> String? {
        try? String(contentsOf: url.appendingPathComponent(name), encoding: .utf8)
    }

    func commit(_ message: String) throws {
        try git("add", "-A")
        try git("commit", "-qm", message)
    }

    var head: String {
        (try? git("rev-parse", "HEAD")) ?? ""
    }

    // A copy of this repository, which stands in for a remote when it is bare.
    func clone(bare: Bool = false) throws -> GitRepo {
        let scratch = ScratchDirectory(prefix: bare ? "git-remote" : "git-clone")
        // Clone wants to create the folder itself.
        try? FileManager.default.removeItem(at: scratch.url)
        var args = ["clone", "-q"]
        if bare { args.append("--bare") }
        try Self.run(args + [url.path, scratch.url.path],
                     in: FileManager.default.temporaryDirectory)
        return try GitRepo(scratch: scratch)
    }

    // An empty bare repository, which stands in for a remote nothing has been pushed to.
    static func bare() throws -> GitRepo {
        let scratch = ScratchDirectory(prefix: "git-remote")
        try run(["init", "-q", "--bare", "-b", "main"], in: scratch.url)
        return try GitRepo(scratch: scratch)
    }

    func addRemote(_ remote: GitRepo, named name: String = "origin") throws {
        try git("remote", "add", name, remote.path)
    }

    private func configureIdentity() throws {
        try git("config", "user.email", "t@example.com")
        try git("config", "user.name", "Test")
        try git("config", "commit.gpgsign", "false")
    }

    @discardableResult
    static func run(_ args: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = directory
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        let complained = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(description: "git \(args.joined(separator: " ")) failed: "
                + String(decoding: complained, as: UTF8.self).trimmed)
        }
        return String(decoding: printed, as: UTF8.self).trimmed
    }
}

// A ProjectStore on its own scratch index, plus a throwaway project when asked. The index
// is passed in rather than set through the environment, since setenv is process-global
// and tests run in parallel.
@MainActor
enum TestStore {
    static func make() -> (store: ProjectStore, scratch: ScratchDirectory) {
        let scratch = ScratchDirectory(prefix: "project-store")
        return (ProjectStore(storeURL: scratch.path("projects.json")), scratch)
    }

    // The project folder sits next to the store's index, so it goes when the index does.
    static func project(in store: ProjectStore, named name: String = "project") throws -> Project {
        let folder = store.storeURL.deletingLastPathComponent()
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try #require(store.addProject(at: folder))
    }
}

// A SessionRunner driven by a fake CLI script written with FixtureCLI. The script, the
// project folder and the store's index all live in one scratch folder.
@MainActor
final class RunnerHarness {
    let scratch: ScratchDirectory
    let store: ProjectStore
    let session: ChatSession
    let runner: SessionRunner
    let executable: URL

    var projectURL: URL { scratch.path("project") }

    init(agent: AgentKind, script: String,
         stalledAfter: TimeInterval = 5 * 60,
         stallCheckInterval: Duration = .seconds(5)) throws {
        scratch = ScratchDirectory(prefix: "runner-\(agent.rawValue)")
        executable = scratch.path("\(agent.rawValue)-fixture")
        try FixtureCLI.write(script, to: executable)
        try FileManager.default.createDirectory(at: scratch.path("project"),
                                                withIntermediateDirectories: true)
        store = ProjectStore(storeURL: scratch.path("projects.json"))
        let project = try #require(store.addProject(at: scratch.path("project")))
        session = try store.insertSession(in: project.id, seed: .init(agent: agent)).get()
        runner = SessionRunner(paths: [agent: executable.path],
                               stalledAfter: stalledAfter,
                               stallCheckInterval: stallCheckInterval)
    }

    // Snapshots only mean anything inside a repository, so a test that expects one has
    // to make the project folder into a repository first.
    func makeProjectARepository() throws {
        try GitRepo.run(["init", "-q", "-b", "main"], in: projectURL)
        try GitRepo.run(["config", "user.email", "test@example.com"], in: projectURL)
        try GitRepo.run(["config", "user.name", "Test"], in: projectURL)
        try GitRepo.run(["commit", "-q", "--allow-empty", "-m", "start"], in: projectURL)
    }

    // A test that failed part way through can leave the fake CLI waiting for good, so the
    // process is let go whatever the test decided. The folder goes afterwards, because a
    // script still waiting on a marker inside it would never see the marker arrive.
    func tearDown() {
        runner.stopAll()
        try? FileManager.default.removeItem(at: scratch.url)
    }
}

// Marker-file helpers for the shell registry tests. Every test gets its own folder, so a
// test shell is never written into the one the real app reaps from.
enum ShellNotes {
    static func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("shell-registry-\(UUID().uuidString)")
    }

    static func markers(in directory: URL) -> [URL] {
        let found = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return found.filter { $0.pathExtension == "json" }
    }
}
