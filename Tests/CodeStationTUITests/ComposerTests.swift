@testable import CodeStationCore
import Foundation
import TerminalKit
import Testing
@testable import CodeStationTUI

extension TUITests {
    // The composer as the GUI's offers it, from the TUI: the open session's run settings
    // (`r`), files attached by a typed path with chips over the prompt (`+`), custom
    // instructions (`I`), the slash command menu, and granting the folder a call reaches
    // when the agent asks.
    @MainActor
    @Suite
    struct ComposerTests {

        private static let reply = """
        IFS= read -r input
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
        case "$input" in *'Answer in French.'*) ;; *) exit 7 ;; esac
        case "$input" in *'Attached files:'*'notes.txt'*) ;; *) exit 8 ;; esac
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Read them."}]}}'
        printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"Read them."}'
        """

        // `r` lists the run settings on the settings screen under the session's name;
        // the arrows change one for the next turn, kept on the session.
        @Test func runSettingsAreChangedFromTheSession() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            let session = try tui.addSession("Fix the login bug", in: alpha)
            try await tui.start()
            await tui.press(.enter([]))
            #expect(await waitUntil { tui.topBarText.contains("Fix the login bug") }, "\(tui.text)")

            await tui.press(.char("r", []))

            #expect(tui.frame[0].text.hasPrefix(" Run settings · Fix the login bug"), "\(tui.text)")
            #expect(tui.line(containing: "Agent")?.text.contains("‹ Claude Code ›") == true, "\(tui.text)")
            #expect(tui.line(containing: "Model")?.text.contains("‹ Claude Code default ›") == true, "\(tui.text)")
            #expect(tui.line(containing: "Asks before")?.text.contains("Default (Allow edits)") == true, "\(tui.text)")

            await tui.press(.down([]), .right([]))
            #expect(await waitUntil { tui.line(containing: "Model")?.text.contains("‹ Opus ›") == true }, "\(tui.text)")
            #expect(tui.store.session(session.id)?.settings?.model == "opus")

            // The agent is fixed: changing it says why.
            await tui.press(.up([]), .right([]))
            #expect(await tui.waitFor("always runs on Claude Code"), "\(tui.text)")

            await tui.press(.escape)
            #expect(!tui.contains("Run settings"), "\(tui.text)")
            #expect(tui.topBarText.contains("Fix the login bug"), "\(tui.text)")
        }

        // `+` asks for a file by path, completing file names; the file shows as a chip
        // over the prompt. `I` writes instructions, shown there too. Both go with the
        // prompt sent, and leave with it.
        @Test func filesAndInstructionsGoWithThePrompt() async throws {
            let tui = try TUIHarness(agentScript: Self.reply)
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try "remember the milk".write(to: tui.scratch.path("alpha/notes.txt"), atomically: true, encoding: .utf8)
            try tui.addSession("Read my notes", in: alpha)
            try await tui.start()
            await tui.press(.enter([]))
            #expect(await waitUntil { tui.topBarText.contains("Read my notes") }, "\(tui.text)")

            await tui.press(.char("+", []))
            #expect(tui.frame[0].text == " Attach a file", "\(tui.text)")
            await tui.type("no")
            await tui.press(.tab([]))
            #expect(tui.contains("notes.txt"), "\(tui.text)")
            await tui.press(.enter([]))
            #expect(await waitUntil { tui.mainLine(containing: "⎘ notes.txt") != nil }, "\(tui.text)")
            let chip = try #require(tui.mainLine(containing: "⎘ notes.txt"))
            #expect(chip.style(of: "⎘ notes.txt")?.foreground == .basic(36))

            await tui.press(.tab([]), .char("I", []))
            #expect(tui.frame[0].text == " Custom instructions for the next prompt", "\(tui.text)")
            await tui.type("Answer in French.")
            await tui.press(.enter([]))
            #expect(tui.mainLine(containing: "✎ Instructions: Answer in French.") != nil, "\(tui.text)")

            await tui.press(.char("i", []))
            await tui.type("Look at this")
            await tui.press(.enter([]))

            #expect(await tui.waitFor("Read them."), "\(tui.text)")
            #expect(await waitUntil { tui.mainLine(containing: "⎘ notes.txt") == nil }, "\(tui.text)")
            #expect(tui.mainLine(containing: "✎ Instructions") == nil, "\(tui.text)")
        }

        // A path to nothing asks again with the reason; Backspace on an empty prompt
        // takes the last file off.
        @Test func aMissingFileIsRefusedAndAChipCanBeTakenOff() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try "x".write(to: tui.scratch.path("alpha/a.txt"), atomically: true, encoding: .utf8)
            try tui.addSession("Read my notes", in: alpha)
            try await tui.start()
            await tui.press(.enter([]))
            #expect(await waitUntil { tui.topBarText.contains("Read my notes") }, "\(tui.text)")

            await tui.press(.char("+", []))
            await tui.type("missing.txt")
            await tui.press(.enter([]))
            #expect(tui.frame[0].text == " Attach a file", "\(tui.text)")
            #expect(tui.contains("There is no file at missing.txt."), "\(tui.text)")

            await tui.press(.char("u", .ctrl))
            await tui.type("a.txt")
            await tui.press(.enter([]))
            #expect(await waitUntil { tui.mainLine(containing: "⎘ a.txt") != nil }, "\(tui.text)")

            await tui.press(.backspace([]))
            #expect(tui.mainLine(containing: "⎘ a.txt") == nil, "\(tui.text)")
        }

        // Typing a slash lists the session's commands over the prompt, narrowed as the
        // word grows; Tab takes the one pointed at, with a space for its words.
        @Test func theSlashMenuListsAndCompletesCommands() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            tui.commands.agentCommandsHome = tui.scratch.path("home")
            tui.commands.agentCommandsEnvironment = [:]
            let alpha = try tui.addProject("alpha")
            let folder = tui.scratch.path("alpha/.claude/commands")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "---\ndescription: Ship the branch\n---\nShip it.".write(
                to: folder.appendingPathComponent("ship.md"), atomically: true, encoding: .utf8)
            try tui.addSession("Ship it", in: alpha)
            try await tui.start()
            await tui.press(.enter([]))
            #expect(await waitUntil { tui.topBarText.contains("Ship it") }, "\(tui.text)")
            await tui.press(.char("i", []))
            await tui.type("/")
            #expect(await waitUntil { tui.mainLine(containing: "/clear") != nil }, "\(tui.text)")
            #expect(tui.mainLine(containing: "/ship")?.text.contains("Ship the branch") == true, "\(tui.text)")
            #expect(tui.mainLine(containing: "/ship")?.text.hasSuffix("project") == true, "\(tui.text)")

            await tui.type("sh")
            #expect(tui.mainLine(containing: "/clear") == nil, "\(tui.text)")
            let pointed = try #require(tui.mainLine(containing: "/ship"), "\(tui.text)")
            #expect(pointed.text.hasPrefix(" ▸ /ship"), "\(tui.text)")
            #expect(pointed.style(of: "/ship")?.inverse == true)

            await tui.press(.tab([]))
            #expect(tui.mainLine(containing: "Ship the branch") == nil, "\(tui.text)")
            #expect(tui.mainLine(containing: "› /ship") != nil, "\(tui.text)")

            // Esc waves the list away for the word on screen.
            await tui.press(.char("u", .ctrl))
            await tui.type("/c")
            #expect(tui.mainLine(containing: "/clear") != nil, "\(tui.text)")
            await tui.press(.escape)
            #expect(tui.mainLine(containing: "/clear") == nil, "\(tui.text)")
            #expect(tui.mainLine(containing: "› /c") != nil, "\(tui.text)")
        }

        // A call reaching a folder outside the session's says so, and 2 allows it with
        // the folder added, kept on the session for every turn after.
        @Test func theFolderACallReachesIsGrantedWithTwo() async throws {
            let outside = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
                .appendingPathComponent("outside-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: outside) }
            let folder = outside.resolvingSymlinksInPath().path
            let request = #"{"type":"control_request","request_id":"r9","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"cd \#(folder) && ls"}}}"#
            let tui = try TUIHarness(agentScript: """
            IFS= read -r input
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
            printf '%s\\n' '\(request)'
            IFS= read -r answer
            case "$answer" in *'"addDirectories"'*) ;; *) exit 7 ;; esac
            printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Listed it."}]}}'
            printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"Listed it."}'
            """)
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            let session = try tui.addSession("List a folder", in: alpha)
            try await tui.start()
            await tui.press(.enter([]))
            #expect(await waitUntil { tui.topBarText.contains("List a folder") }, "\(tui.text)")
            await tui.press(.char("i", []))
            await tui.type("List it")
            await tui.press(.enter([]), .tab([]))

            #expect(await tui.waitFor("needs permission"), "\(tui.text)")
            #expect(await waitUntil { tui.contains("outside this session's folders.") }, "\(tui.text)")
            let name = outside.lastPathComponent
            let choices = try #require(tui.line(containing: "allow, and add \(name)"), "\(tui.text)")
            #expect(choices.style(of: " 2 ")?.inverse == true)

            await tui.press(.char("2", []))

            #expect(await tui.waitFor("Listed it."), "\(tui.text)")
            #expect(tui.store.session(session.id)?.grantedDirectories == [folder])
        }
    }
}
