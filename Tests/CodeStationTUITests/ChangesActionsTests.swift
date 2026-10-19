import CodeStationCore
import Foundation
import TerminalKit
import Testing

extension TUITests {
    // The Changes tab keeping itself current, and what it does with the changes: tick
    // files, commit them (or everything) with a message, and discard a file's changes
    // after a confirmation, as the GUI's changes view does.
    @MainActor
    @Suite
    struct ChangesActionsTests {

    // The live changes are read with git on a queue the whole test process shares, which
    // other suites' git work can keep busy for a long while. A wait returns as soon as
    // what it waits for shows, so a generous one costs nothing when the machine is idle.
    static let liveWait: Duration = .seconds(120)

        // A project whose README the session has changed, its Changes tab open.
        private func openChanges(_ tui: TUIHarness, edits: [String: String] = ["README.md": "hello\nworld\n"])
            async throws -> Project {
            let alpha = try tui.addProject("alpha", committing: ["README.md": "hello\n", "app.txt": "one\n"])
            for (path, contents) in edits {
                try contents.write(to: alpha.url.appendingPathComponent(path), atomically: true, encoding: .utf8)
            }
            try tui.addSession("Edit the readme", in: alpha)
            try await tui.start()
            await tui.press(.enter([]))
            await tui.press(.char("4", []))
            for path in edits.keys { #expect(await tui.waitFor(path, timeout: Self.liveWait), "\(tui.text)") }
            return alpha
        }

        private func git(_ arguments: String..., in project: Project) throws -> String {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = project.url
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // The help line names every key the list takes, the history included.
        @Test func theHelpLineNamesTheHistory() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 200, rows: 24))
            defer { tui.tearDown() }
            _ = try await openChanges(tui)

            #expect(tui.contains("H history"), "\(tui.text)")
        }

        // A file the agent edits while the tab is open shows up by itself.
        @Test func theListFollowsEditsWithoutReloading() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 140, rows: 24))
            defer { tui.tearDown() }
            let alpha = try await openChanges(tui)

            try "one\ntwo\n".write(to: alpha.url.appendingPathComponent("app.txt"), atomically: true, encoding: .utf8)

            #expect(await tui.waitFor("app.txt", timeout: Self.liveWait), "\(tui.text)")
            #expect(tui.mainPane[0].text.hasPrefix(" Changes · Edit the readme · 2 files"), "\(tui.text)")
        }

        // `c` asks for a message and commits every change; the list empties by itself.
        @Test func cCommitsEverythingWithAMessage() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 140, rows: 24))
            defer { tui.tearDown() }
            let alpha = try await openChanges(tui, edits: ["README.md": "hello\nworld\n", "app.txt": "two\n"])

            await tui.press(.char("c", []))

            #expect(tui.mainPane[0].text.hasPrefix(" Commit all 2 files in alpha"), "\(tui.text)")
            #expect(tui.mainPane.contains { $0.text.contains("enter commit · esc cancel") }, "\(tui.text)")

            // Number keys are text here, not tabs.
            await tui.type("Say hello 2")
            await tui.press(.enter([]))

            #expect(await tui.waitFor("No changes.", timeout: Self.liveWait), "\(tui.text)")
            #expect(try git("log", "-1", "--format=%s", in: alpha) == "Say hello 2")
            #expect(try git("status", "--porcelain", in: alpha) == "")
            #expect(tui.contains("Committed 2 files."), "\(tui.text)")
        }

        // Space ticks files; `c` then commits only the ticked ones and the rest stay.
        @Test func spaceTicksTheFilesACommitTakes() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 140, rows: 24))
            defer { tui.tearDown() }
            let alpha = try await openChanges(tui, edits: ["README.md": "hello\nworld\n", "app.txt": "two\n"])
            // app.txt is listed first, as the changes sort their files, and selected.
            await tui.press(.char(" ", []))

            let ticked = try #require(tui.line(containing: "app.txt"), "\(tui.text)")
            #expect(ticked.text.contains("✓"), "\(ticked.text)")
            #expect(tui.line(containing: "README.md")?.text.contains("✓") == false)

            await tui.press(.char("c", []))
            #expect(tui.mainPane[0].text.hasPrefix(" Commit 1 file in alpha"), "\(tui.text)")
            await tui.type("Only the app")
            await tui.press(.enter([]))

            #expect(await waitUntil(timeout: Self.liveWait) { tui.line(containing: "app.txt") == nil }, "\(tui.text)")
            #expect(tui.contains("README.md"), "\(tui.text)")
            #expect(try git("show", "--name-only", "--format=", "HEAD", in: alpha) == "app.txt")
        }

        // Esc leaves the message prompt without committing; an empty message is refused
        // with the station's reason, and the prompt stays.
        @Test func theCommitPromptCancelsAndSaysWhyItRefuses() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 140, rows: 24))
            defer { tui.tearDown() }
            let alpha = try await openChanges(tui)
            let head = try git("rev-parse", "HEAD", in: alpha)

            await tui.press(.char("c", []))
            await tui.press(.enter([]))

            #expect(tui.contains("Write a commit message first."), "\(tui.text)")
            #expect(tui.mainPane[0].text.hasPrefix(" Commit all 1 file in alpha"), "\(tui.text)")

            await tui.press(.escape)

            #expect(tui.mainPane[0].text.hasPrefix(" Changes · Edit the readme · 1 file"), "\(tui.text)")
            #expect(try git("rev-parse", "HEAD", in: alpha) == head)
        }

        // `D` asks first, with what goes and what stays; Esc keeps the file, `y` puts it
        // back the way the last commit has it.
        @Test func dDiscardsAFileAfterAConfirmation() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 140, rows: 24))
            defer { tui.tearDown() }
            let alpha = try await openChanges(tui, edits: ["README.md": "hello\nworld\n", "app.txt": "two\n"])
            await tui.press(.char("j", []))

            await tui.press(.char("D", []))

            #expect(tui.contains("Discard changes?"), "\(tui.text)")
            #expect(tui.contains("− README.md"), "\(tui.text)")
            #expect(tui.contains("✓ Other changes"), "\(tui.text)")
            #expect(tui.contains("[ Discard ]"), "\(tui.text)")

            await tui.press(.escape)

            #expect(tui.mainPane[0].text.hasPrefix(" Changes · Edit the readme · 2 files"), "\(tui.text)")
            #expect(try String(contentsOf: alpha.url.appendingPathComponent("README.md"), encoding: .utf8)
                == "hello\nworld\n")

            await tui.press(.char("D", []))
            await tui.press(.char("y", []))

            #expect(await waitUntil(timeout: Self.liveWait) { tui.line(containing: "M README.md") == nil }, "\(tui.text)")
            #expect(tui.contains("Discarded the changes in README.md."), "\(tui.text)")
            #expect(try String(contentsOf: alpha.url.appendingPathComponent("README.md"), encoding: .utf8) == "hello\n")
            #expect(tui.contains("app.txt"), "\(tui.text)")
        }
    }
}
