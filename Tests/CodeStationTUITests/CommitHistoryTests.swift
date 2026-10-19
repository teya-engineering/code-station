import CodeStationCore
import Foundation
import TerminalKit
import Testing

extension TUITests {
    // The commit history and the session's pull requests, reached with `H` from the
    // Changes tab, and diffs drawn side by side when the pane is wide enough.
    @MainActor
    @Suite
    struct CommitHistoryTests {

        // A project with two commits, the second editing a line, and a session in it that
        // opened a pull request. The session's Changes tab is open.
        private func openChanges(_ tui: TUIHarness) async throws -> Project {
            let alpha = try tui.addProject("alpha", committing: ["app.txt": "one\ntwo\n"])
            try "one\nTWO\nthree\n".write(to: alpha.url.appendingPathComponent("app.txt"),
                                         atomically: true, encoding: .utf8)
            try git(["commit", "-qam", "Shout two"], in: alpha)
            let session = try tui.addSession("Ship it", in: alpha)
            tui.store.notePullRequest(PullRequest(number: 42, url: "https://github.com/teya/alpha/pull/42"),
                                      for: session.id)
            try await tui.start()
            await tui.press(.enter([]))
            await tui.press(.char("4", []))
            #expect(await tui.waitFor("No changes."), "\(tui.text)")
            return alpha
        }

        private func git(_ arguments: [String], in project: Project) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = project.url
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
        }

        // `H` lists the pull requests and the commits, newest first; Enter on a pull
        // request opens it in the browser through the host.
        @Test func hListsThePullRequestsAndCommitsAndOpensAPullRequest() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 100, rows: 24))
            defer { tui.tearDown() }
            _ = try await openChanges(tui)

            await tui.press(.char("H", []))

            #expect(await tui.waitFor("Shout two"), "\(tui.text)")
            #expect(tui.mainPane[0].text.hasPrefix(" History · Ship it"), "\(tui.text)")
            let pullRequest = try #require(tui.line(containing: "https://github.com/teya/alpha/pull/42"),
                                           "\(tui.text)")
            #expect(pullRequest.text.contains("#42"))
            let rows = tui.mainPane.map(\.text)
            let newest = try #require(rows.firstIndex { $0.contains("Shout two") })
            let first = try #require(rows.firstIndex { $0.contains("first") && $0.contains("Test") })
            #expect(newest < first)

            // The cursor starts on the pull request.
            await tui.press(.enter([]))

            #expect(tui.launched == [["/usr/bin/open", "https://github.com/teya/alpha/pull/42"]])
            #expect(tui.contains("Opened #42 in the browser."), "\(tui.text)")
        }

        // Enter on a commit lists the files it changed; Enter on a file shows its diff;
        // Esc steps back each time, out to the changes.
        @Test func enterOpensACommitAndThenAFilesDiff() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 100, rows: 24))
            defer { tui.tearDown() }
            _ = try await openChanges(tui)
            await tui.press(.char("H", []))
            #expect(await tui.waitFor("Shout two"), "\(tui.text)")

            await tui.press(.down([]))
            await tui.press(.enter([]))

            #expect(await tui.waitFor("1 file"), "\(tui.text)")
            #expect(tui.mainPane[0].text.contains("Shout two"), "\(tui.text)")
            let file = try #require(tui.line(containing: "app.txt"), "\(tui.text)")
            #expect(file.text.contains("+2 -1"))

            await tui.press(.enter([]))

            let added = try #require(tui.line(containing: "+TWO"), "\(tui.text)")
            #expect(added.style(of: "+TWO")?.foreground == .basic(32))
            #expect(tui.contains("-two"))

            await tui.press(.escape)
            #expect(tui.line(containing: "+TWO") == nil, "\(tui.text)")
            await tui.press(.escape)
            #expect(tui.mainPane[0].text.hasPrefix(" History · Ship it"), "\(tui.text)")
            await tui.press(.escape)
            #expect(tui.mainPane[0].text.hasPrefix(" Changes · Ship it"), "\(tui.text)")
        }

        // On a wide pane a diff is drawn side by side: the line taken out and the line put
        // in its place share a row, each with its line number.
        @Test func aWidePaneShowsTheDiffSideBySide() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 200, rows: 30))
            defer { tui.tearDown() }
            _ = try await openChanges(tui)
            await tui.press(.char("H", []))
            #expect(await tui.waitFor("Shout two"), "\(tui.text)")
            await tui.press(.down([]))
            await tui.press(.enter([]))
            #expect(await tui.waitFor("1 file"), "\(tui.text)")

            await tui.press(.enter([]))

            let row = try #require(tui.line(containing: "+TWO"), "\(tui.text)")
            #expect(row.text.contains("-two"), "\(row.text)")
            #expect(row.text.contains("2 -two") && row.text.contains("2 +TWO"), "\(row.text)")
            #expect(row.style(of: "-two")?.foreground == .basic(31))
            #expect(row.style(of: "+TWO")?.foreground == .basic(32))
            let context = try #require(tui.line(containing: "1  one"), "\(tui.text)")
            #expect(context.text.components(separatedBy: " one").count == 3, "\(context.text)")
            let added = try #require(tui.line(containing: "+three"), "\(tui.text)")
            #expect(!added.text.contains("-"), "\(added.text)")
        }

        // On a narrow pane the same diff is unified: one line per row.
        @Test func aNarrowPaneShowsTheDiffUnified() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 100, rows: 30))
            defer { tui.tearDown() }
            _ = try await openChanges(tui)
            await tui.press(.char("H", []))
            #expect(await tui.waitFor("Shout two"), "\(tui.text)")
            await tui.press(.down([]))
            await tui.press(.enter([]))
            #expect(await tui.waitFor("1 file"), "\(tui.text)")

            await tui.press(.enter([]))

            let added = try #require(tui.line(containing: "+TWO"), "\(tui.text)")
            #expect(!added.text.contains("-two"), "\(added.text)")
            #expect(tui.line(containing: "-two") != nil, "\(tui.text)")
        }

        // The Changes tab's own diff follows the width the same way.
        @Test func theChangesDiffIsSideBySideOnAWidePane() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 200, rows: 30))
            defer { tui.tearDown() }
            let alpha = try await openChanges(tui)
            try "one\nTwo\nthree\n".write(to: alpha.url.appendingPathComponent("app.txt"),
                                         atomically: true, encoding: .utf8)
            #expect(await tui.waitFor("app.txt", timeout: .seconds(10)), "\(tui.text)")

            await tui.press(.enter([]))

            let row = try #require(tui.line(containing: "+Two"), "\(tui.text)")
            #expect(row.text.contains("2 -TWO") && row.text.contains("2 +Two"), "\(row.text)")
        }
    }
}
