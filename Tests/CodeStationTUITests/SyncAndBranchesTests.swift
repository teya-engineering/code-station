import CodeStationCore
import Foundation
import TerminalKit
import Testing

extension TUITests {
    // Push, pull and fetch, and the branch picker, from the Changes tab and a project's
    // screen: the line under the screen says what is running, then what it did or why
    // it could not, and the picker switches to or creates a branch.
    @MainActor
    @Suite
    struct SyncAndBranchesTests {

        // A project whose folder tracks a bare origin, with one session in it.
        private func trackedProject(_ tui: TUIHarness) throws -> (project: Project, origin: URL) {
            let alpha = try tui.addProject("alpha", committing: ["README.md": "hello\n"])
            let origin = tui.scratch.path("alpha-origin.git")
            try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
            try git("init", "-q", "--bare", "-b", "main", in: origin)
            try git("remote", "add", "origin", origin.path, in: alpha.url)
            try git("push", "-q", "-u", "origin", "main", in: alpha.url)
            try tui.addSession("Edit the readme", in: alpha)
            return (alpha, origin)
        }

        private func openChanges(_ tui: TUIHarness) async {
            await tui.press(.enter([]))
            await tui.press(.char("4", []))
            #expect(await tui.waitFor("No changes."), "\(tui.text)")
        }

        private func commit(_ file: String, _ subject: String, in folder: URL) throws {
            try subject.write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
            try git("add", "-A", in: folder)
            try git("commit", "-qm", subject, in: folder)
        }

        // Another clone pushes a commit to origin, as a teammate would.
        private func teammatePushes(_ subject: String, to origin: URL, tui: TUIHarness) throws {
            let other = tui.scratch.path("teammate-\(UUID().uuidString)")
            try git("clone", "-q", origin.path, other.path, in: tui.scratch.url)
            try git("config", "user.email", "t@example.com", in: other)
            try git("config", "user.name", "Teammate", in: other)
            try git("config", "commit.gpgsign", "false", in: other)
            try commit("theirs.txt", subject, in: other)
            try git("push", "-q", "origin", "HEAD:main", in: other)
        }

        @discardableResult
        private func git(_ arguments: String..., in folder: URL) throws -> String {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = folder
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private var lastLine: (TUIHarness) -> String {
            { $0.mainPane.last?.text ?? "" }
        }

        // `P` in the Changes tab pushes the checkout's new commits, and the line under the
        // list says what went.
        @Test func pPushesFromTheChangesTab() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 140, rows: 24))
            defer { tui.tearDown() }
            let (alpha, origin) = try trackedProject(tui)
            try commit("app.txt", "Add the app", in: alpha.url)
            try await tui.start()
            await openChanges(tui)

            await tui.press(.char("P", []))

            #expect(await waitUntil { self.lastLine(tui).contains("✓ Pushed 1 commit to origin/main") },
                    "\(tui.text)")
            #expect(try git("rev-parse", "main", in: origin) == git("rev-parse", "HEAD", in: alpha.url))

            // The next key puts the key help back.
            await tui.press(.char("j", []))
            #expect(lastLine(tui).contains("P/U/F push pull fetch"), "\(tui.text)")
        }

        // While a fetch waits on origin the line says so; when origin cannot be reached the
        // line says why, in git's words.
        @Test func aFetchShowsItsProgressThenWhyItFailed() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 160, rows: 24))
            defer { tui.tearDown() }
            let (alpha, _) = try trackedProject(tui)
            try git("remote", "set-url", "origin", "ssh://example.invalid/alpha.git", in: alpha.url)
            try git("config", "ssh.variant", "simple", in: alpha.url)
            try git("config", "core.sshCommand", "sh -c 'sleep 2; echo origin is unreachable >&2; exit 1'",
                    in: alpha.url)
            try await tui.start()
            await openChanges(tui)

            tui.terminal.send(.key(.char("F", [])))

            #expect(await waitUntil { self.lastLine(tui).contains("⟳ Fetching alpha…") }, "\(tui.text)")
            await tui.settle()
            #expect(await waitUntil { self.lastLine(tui).contains("✗ Could not fetch: origin is unreachable") },
                    "\(tui.text)")
        }

        // `B` opens the branch picker over the tab: create a branch by name and the
        // checkout moves to it.
        @Test func theBranchPickerCreatesABranch() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 140, rows: 24))
            defer { tui.tearDown() }
            let (alpha, _) = try trackedProject(tui)
            try await tui.start()
            await openChanges(tui)

            await tui.press(.char("B", []))

            #expect(await tui.waitFor("Branches · alpha · on main"), "\(tui.text)")
            #expect(tui.contains("+ Create new branch…"), "\(tui.text)")
            #expect(tui.contains(" LOCAL"), "\(tui.text)")
            #expect(tui.line(containing: "● main") != nil, "\(tui.text)")
            #expect(tui.contains("origin/main"), "\(tui.text)")
            #expect(tui.contains("type to filter · ↑↓ move · enter switch · esc close"), "\(tui.text)")

            // Number keys are text here, not tabs.
            await tui.press(.enter([]))
            #expect(tui.contains("New branch, from main"), "\(tui.text)")
            await tui.type("feature-2")
            await tui.press(.enter([]))

            #expect(await waitUntil { self.lastLine(tui).contains("✓ Created feature-2 and switched to it") },
                    "\(tui.text)")
            #expect(try git("branch", "--show-current", in: alpha.url) == "feature-2")
            #expect(await tui.waitFor("⎇ feature-2", timeout: .seconds(10)), "\(tui.text)")
        }

        // Typing narrows the branches; Enter switches to the one picked. A name that is
        // taken is refused in the picker's footer, and the picker stays.
        @Test func theBranchPickerFiltersSwitchesAndRefuses() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 140, rows: 24))
            defer { tui.tearDown() }
            let (alpha, _) = try trackedProject(tui)
            try git("branch", "topic", in: alpha.url)
            try git("branch", "other", in: alpha.url)
            try await tui.start()
            await openChanges(tui)

            await tui.press(.char("B", []))
            #expect(await tui.waitFor("Branches · alpha"), "\(tui.text)")
            await tui.type("top")

            #expect(tui.line(containing: "▸   topic") != nil, "\(tui.text)")
            #expect(!tui.contains("other"), "\(tui.text)")

            await tui.press(.enter([]))
            #expect(await waitUntil { self.lastLine(tui).contains("✓ Switched to topic") }, "\(tui.text)")
            #expect(try git("branch", "--show-current", in: alpha.url) == "topic")

            await tui.press(.char("B", []))
            #expect(await tui.waitFor("on topic"), "\(tui.text)")
            await tui.press(.enter([]))
            await tui.type("main")
            await tui.press(.enter([]))

            #expect(await tui.waitFor("✗ A branch called main already exists."), "\(tui.text)")
            #expect(tui.contains("New branch, from topic"), "\(tui.text)")
            await tui.press(.escape)
            await tui.press(.escape)
            #expect(tui.mainPane[0].text.hasPrefix(" Changes · Edit the readme"), "\(tui.text)")
        }

        // A project's screen fetches, pulls and pushes its folder, and its strip follows.
        @Test func aProjectScreenSyncsItsFolder() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 160, rows: 24))
            defer { tui.tearDown() }
            let (alpha, origin) = try trackedProject(tui)
            try teammatePushes("Teammate's work", to: origin, tui: tui)
            try await tui.start()
            await tui.press(.char("g", []))
            for _ in 0..<6 where tui.sidebarLine(containing: "▸ ")?.text.contains("alpha") != true {
                await tui.press(.down([]))
            }
            await tui.press(.enter([]))
            #expect(await waitUntil { tui.topBar.count > 1 && tui.topBar[1].text.contains("CLEAN") }, "\(tui.topBarText)")
            #expect(tui.contains("P/U/F push pull fetch · B branch"), "\(tui.text)")

            await tui.press(.char("F", []))
            #expect(await waitUntil { self.lastLine(tui).contains("✓ Fetched origin · 0 ahead · 1 behind origin/main") },
                    "\(tui.text)")
            #expect(await waitUntil { tui.topBar[1].text.contains("↓1") }, "\(tui.topBarText)")

            await tui.press(.char("U", []))
            #expect(await waitUntil { self.lastLine(tui).contains("✓ Pulled 1 commit from origin/main") },
                    "\(tui.text)")
            #expect(await waitUntil { tui.topBar[1].text.contains("Teammate's work") }, "\(tui.topBarText)")

            try commit("mine.txt", "My work", in: alpha.url)
            await tui.press(.char("P", []))
            #expect(await waitUntil { self.lastLine(tui).contains("✓ Pushed 1 commit to origin/main") },
                    "\(tui.text)")
            #expect(try git("log", "-1", "--format=%s", "main", in: origin) == "My work")
        }
    }
}
