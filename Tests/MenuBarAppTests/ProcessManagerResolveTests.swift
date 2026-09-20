import Foundation
import Testing
@testable import MenuBarApp

// Every command-line integration in the app finds its binary through this, and a
// Finder-launched app is handed a PATH with almost nothing on it. What the lookup accepts
// and where it looks is therefore what decides whether git, the agent CLIs and the MCP
// servers are found at all once the app is launched the way a user launches it.
struct ProcessManagerResolveTests {

    @Test func nothingResolvesToNothing() {
        #expect(ProcessManager.resolve("") == nil)
    }

    // A path is taken as given rather than searched for, so a configured command can point
    // anywhere on disk.
    @Test func aPathToAnExecutableResolvesToItself() throws {
        let scratch = ScratchDirectory(prefix: "resolve")
        let tool = scratch.path("tool")
        try "#!/bin/sh\nexit 0\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        #expect(ProcessManager.resolve(tool.path) == tool.path)
    }

    // A file that happens to sit at the configured path but cannot be run is not a find:
    // reporting it would turn a clear "not installed" into a launch failure later.
    @Test func aPathToSomethingThatCannotBeRunDoesNotResolve() throws {
        let scratch = ScratchDirectory(prefix: "resolve")
        let notExecutable = scratch.path("notes.txt")
        try "not a program".write(to: notExecutable, atomically: true, encoding: .utf8)

        #expect(ProcessManager.resolve(notExecutable.path) == nil)
        #expect(ProcessManager.resolve(scratch.path("missing").path) == nil)
    }

    @Test func aNameThatIsNowhereOnThePathDoesNotResolve() {
        #expect(ProcessManager.resolve("code-station-absent-\(UUID().uuidString)") == nil)
    }

    // A bare name comes back as an absolute path, which is the point: the CLIs are started
    // without a shell, so a name alone would not be found.
    @Test func aBareNameResolvesToAnAbsolutePathThatCanBeRun() throws {
        let git = try #require(ProcessManager.resolve("git"))

        #expect(git.hasPrefix("/"))
        #expect(FileManager.default.isExecutableFile(atPath: git))
    }

    // The search path is what gets handed to every CLI the app starts, so the usual
    // install directories have to be on it even when the inherited PATH is bare.
    @Test func theSearchPathCoversTheUsualInstallDirectories() {
        let dirs = ProcessManager.searchPath.split(separator: ":").map(String.init)

        for expected in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
            #expect(dirs.contains(expected), "\(expected) is missing from the search path")
        }
        #expect(dirs.contains { $0.hasSuffix("/go/bin") })
        #expect(dirs.contains { $0.hasSuffix("/.local/bin") })
    }

    // A command that was not found is looked up again rather than remembered as missing,
    // so installing a CLI while the app runs takes effect without a restart.
    @Test func aCommandInstalledAfterAFailedLookupIsFoundOnTheNextAsk() throws {
        let scratch = ScratchDirectory(prefix: "resolve")
        let tool = scratch.path("late-tool")

        #expect(ProcessManager.resolve(tool.path) == nil)

        try "#!/bin/sh\nexit 0\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        #expect(ProcessManager.resolve(tool.path) == tool.path)
    }
}
