import Darwin
import Foundation
import Testing
@testable import MenuBarApp

// Cloning a repository to make a project from it. The clone runs against a throwaway local
// repository, and what matters most is what is left on disk when it does not work out.
struct GitCloneTests {
    private let sandbox = ScratchDirectory(prefix: "clone")

    private func leftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: sandbox.url.path)
    }

    // MARK: - Naming the folder

    @Test(arguments: [
        ("https://github.com/owner/repo.git", "repo"),
        ("https://github.com/owner/repo", "repo"),
        ("https://github.com/owner/repo/", "repo"),
        ("git@github.com:owner/repo.git", "repo"),
        ("git@host:repo.git", "repo"),
        ("ssh://git@host:22/owner/repo.git", "repo"),
        ("  https://github.com/owner/repo.git\n", "repo"),
        ("/Users/me/code/repo", "repo")
    ])
    func namesTheFolderAfterTheRepository(remote: String, name: String) {
        #expect(GitClone.folderName(for: remote) == name)
    }

    @Test(arguments: ["", "   ", "/", ".git", "https://github.com/.."])
    func offersNoNameWhenTheAddressHasNone(remote: String) {
        #expect(GitClone.folderName(for: remote) == nil)
    }

    // MARK: - Reading git's output

    // A meter update ends in a carriage return and can be split across two reads.
    @Test func readsTheMeterAcrossChunks() {
        var output = GitClone.Output()
        #expect(output.read(Data("Receiving objects:  4".utf8)) == nil)
        let progress = output.read(Data("5% (450/1000)\r".utf8))
        #expect(progress == GitClone.Progress(phase: "Receiving objects", percent: 45))
        #expect(output.complaint.isEmpty)
    }

    // The reason comes after the meter, and is what the person needs to read.
    @Test func keepsTheReasonAndDropsTheChatter() {
        var output = GitClone.Output()
        let text = "Cloning into 'x'...\n"
            + "remote: Enumerating objects: 3, done.\n"
            + "remote: Counting objects:  50% (1/2)\r"
            + "remote: Repository not found.\n"
            + "fatal: repository 'x' not found\n"
        let progress = output.read(Data(text.utf8))
        #expect(progress == GitClone.Progress(phase: "Counting objects", percent: 50))
        #expect(output.complaint == "remote: Repository not found.\nfatal: repository 'x' not found")
    }

    // Word for word what git and ssh print when a host key no longer matches.
    private static let changedHostKey = """
        Cloning into 'x'...
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
        Someone could be eavesdropping on you right now (man-in-the-middle attack)!
        It is also possible that a host key has just been changed.
        The fingerprint for the ED25519 key sent by the remote host is
        SHA256:rPrSUVv6lu2EfHWnbX6nEX37yDGbSOIM1jWm1mxS9NA.
        Please contact your system administrator.
        Add correct host key in /Users/me/.ssh/known_hosts to get rid of this message.
        Offending ED25519 key in /Users/me/.ssh/known_hosts:1
        Host key for github.com has changed and you have requested strict checking.
        Host key verification failed.
        fatal: Could not read from remote repository.

        Please make sure you have the correct access rights
        and the repository exists.

        """

    // A changed key can be an attack, so it must not be reported as a server not yet trusted.
    @Test func aChangedHostKeyIsReportedAsChanged() {
        var output = GitClone.Output()
        _ = output.read(Data(Self.changedHostKey.utf8))

        guard case .signInRequired(let signIn) = output.failure(address: "git@github.com:owner/repo.git") else {
            Issue.record("Expected a sign-in problem")
            return
        }
        #expect(signIn.message.contains("intercepting"))
        #expect(output.complaint.split(separator: "\n").count == 6)
    }

    @Test func aLongBannerDoesNotHideTheReason() {
        var output = GitClone.Output()
        let banner = "remote: " + String(repeating: "policy ", count: 40) + "\n"
        _ = output.read(Data((banner + banner + "fatal: Authentication failed for 'https://github.com/owner/repo.git/'\n").utf8))

        #expect(output.complaint.count == 500)
        #expect(output.complaint.hasSuffix("fatal: Authentication failed for 'https://github.com/owner/repo.git/'"))
        guard case .signInRequired = output.failure(address: "https://github.com/owner/repo.git") else {
            Issue.record("Expected a sign-in problem")
            return
        }
    }

    // MARK: - Cloning

    @Test func clonesIntoTheDestinationAndLeavesNothingElse() async throws {
        let repo = try GitRepo()
        let destination = sandbox.path("copy")

        let outcome = await GitClone.clone(repo.path, to: destination) { _ in }

        #expect(outcome == .cloned(destination))
        #expect(try String(contentsOf: destination.appendingPathComponent("README.md"),
                           encoding: .utf8) == "hello")
        #expect(try leftovers() == ["copy"])
    }

    @Test func aFailedCloneSaysWhyAndLeavesNoFolder() async throws {
        let outcome = await GitClone.clone(sandbox.path("nothing-here").path,
                                           to: sandbox.path("copy")) { _ in }

        guard case .failed(let message) = outcome else {
            Issue.record("Expected a failure, got \(outcome)")
            return
        }
        #expect(message.contains("does not exist"))
        #expect(try leftovers().isEmpty)
    }

    // An existing folder is never written into, even an empty one that git would accept.
    @Test func refusesAFolderThatAlreadyExists() async throws {
        let repo = try GitRepo()
        let destination = sandbox.path("copy")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let outcome = await GitClone.clone(repo.path, to: destination) { _ in }

        guard case .failed = outcome else {
            Issue.record("Expected a failure, got \(outcome)")
            return
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    // The server takes the connection and never answers, so git is still running when
    // the cancel arrives and has a folder to clear up.
    @Test func cancellingARunningCloneLeavesNoFolder() async throws {
        let server = try SilentServer()
        let store = sandbox.preferences.store
        let address = "git://127.0.0.1:\(server.port)/repo.git"
        let task = Task {
            await GitClone.clone(address, to: sandbox.path("copy"),
                                 preferences: sandbox.preferences.store) { _ in }
        }

        #expect(await waitUntil(timeout: .seconds(10)) { (try? leftovers())?.isEmpty == false })
        #expect(Preferences.partialClones(in: store).count == 1)
        task.cancel()

        #expect(await task.value == .cancelled)
        #expect(try leftovers().isEmpty)
        #expect(Preferences.partialClones(in: store).isEmpty)
    }

    // MARK: - After a quit or a crash

    @Test func theNextLaunchRemovesWhatAnEndedRunLeft() throws {
        let store = sandbox.preferences.store
        let partial = sandbox.path(".repo.cloning-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        let alreadyGone = sandbox.path(".other.cloning-\(UUID().uuidString)").path
        Preferences.setPartialClones([partial.path, alreadyGone], in: store)

        #expect(GitClone.removeLeftovers(in: store) == 1)
        #expect(try leftovers().isEmpty)
        #expect(Preferences.partialClones(in: store).isEmpty)
    }

    // The list is only a preference, and removing is recursive.
    @Test func onlyAFolderThisCodeNamedIsEverRemoved() throws {
        let store = sandbox.preferences.store
        let project = sandbox.path("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        Preferences.setPartialClones([project.path], in: store)

        #expect(GitClone.removeLeftovers(in: store) == 0)
        #expect(try leftovers() == ["project"])
        #expect(Preferences.partialClones(in: store).isEmpty)
    }

    @Test func aCloneCancelledBeforeItStartsLeavesNoFolder() async throws {
        let repo = try GitRepo()
        let task = Task { await GitClone.clone(repo.path, to: sandbox.path("copy")) { _ in } }
        task.cancel()

        #expect(await task.value == .cancelled)
        #expect(try leftovers().isEmpty)
    }
}

// Listens on a local port without ever replying. The system accepts the connection, so a
// client that connects waits for an answer until it is stopped.
private final class SilentServer {
    let port: UInt16
    private let socket: Int32

    struct Failure: Error {}

    init() throws {
        let listener = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.bind(listener, generic, length) == 0
                    && getsockname(listener, generic, &length) == 0
            }
        }
        guard bound, listen(listener, 1) == 0 else {
            close(listener)
            throw Failure()
        }
        socket = listener
        port = UInt16(bigEndian: address.sin_port)
    }

    deinit { close(socket) }
}
