import Foundation
import Testing
@testable import CodeStationCore

// Part of the station contract (see StationContract.swift): the composer as the GUI's
// offers it. A session's run settings for its next turn (the agent it is fixed to, the
// model, the effort, how much the agent asks first or the access Codex and Copilot run
// with, and a Design conversation's ambition), a prompt sent with files attached by
// their path on the host's machine and custom instructions, the slash commands a session
// can be sent, and granting the agent a folder outside the session's when it asks.
@MainActor
struct StationComposerTests {

    private static let silent = """
    IFS= read -r input
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
    printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}'
    """

    // A Claude Code session lists the agent it is fixed to, then its model, effort and
    // permission mode, each following the app's default until one is chosen. A choice is
    // kept on the session, and the answer shows it.
    @Test(arguments: StationImplementation.allCases)
    func aSessionsRunSettingsAreChangedOneAtATime(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: Self.silent, host: RecordingHost())
        defer { fixture.tearDown() }
        let commands = kind.connect(to: StationCommands(store: fixture.store, runner: fixture.runner))
        let id = fixture.session.id.uuidString

        let settings = try await commands.readRunSettings(id)

        let rows = settings.sections.flatMap(\.settings)
        #expect(rows.map(\.id) == ["agent", "model", "effort", "permissionMode"])
        #expect(settings.setting("agent")?.choices.map(\.title) == ["Claude Code"])
        #expect(settings.setting("model")?.value == "")
        #expect(settings.setting("model")?.choices.map(\.value).contains("opus") == true)
        #expect(settings.setting("permissionMode")?.value == "")
        #expect(settings.setting("permissionMode")?.choices.map(\.value) == ["", "acceptEdits", "manual", "auto", "plan"])

        let changed = try await commands.changeRunSetting(id, "model", to: "opus")
        #expect(changed.setting("model")?.value == "opus")
        #expect(fixture.store.session(fixture.session.id)?.settings?.model == "opus")

        _ = try await commands.changeRunSetting(id, "permissionMode", to: "plan")
        #expect(fixture.store.session(fixture.session.id)?.settings?.permissionMode == .plan)
        let effort = try #require(changed.setting("effort")?.choices.last?.value)
        _ = try await commands.changeRunSetting(id, "effort", to: effort)
        #expect(fixture.store.session(fixture.session.id)?.settings?.effort == effort)

        // Back to following the default.
        let reset = try await commands.changeRunSetting(id, "model", to: "")
        #expect(reset.setting("model")?.value == "")
        #expect(fixture.store.session(fixture.session.id)?.settings?.model == nil)

        // The agent is fixed for the session's life, and a value not on offer is refused.
        await #expect(throws: StationRefusal.self) { try await commands.changeRunSetting(id, "agent", to: "codex") }
        await #expect(throws: StationRefusal.self) {
            try await commands.changeRunSetting(id, "permissionMode", to: "yolo")
        }
    }

    // Codex and Copilot sessions run with an access policy in place of a permission mode,
    // and a Design conversation also says how far its look is pushed.
    @Test(arguments: StationImplementation.allCases)
    func eachAgentOffersItsOwnAccessAndDesignItsAmbition(_ kind: StationImplementation) async throws {
        let codex = try RunnerHarness(agent: .codex, script: Self.silent, host: RecordingHost())
        defer { codex.tearDown() }
        let codexCommands = kind.connect(to: StationCommands(store: codex.store, runner: codex.runner))
        let codexID = codex.session.id.uuidString
        let codexSettings = try await codexCommands.readRunSettings(codexID)
        #expect(codexSettings.sections.flatMap(\.settings).map(\.id) == ["agent", "model", "effort", "codexSandbox"])
        _ = try await codexCommands.changeRunSetting(codexID, "codexSandbox", to: "danger-full-access")
        #expect(codex.store.session(codex.session.id)?.settings?.codexSandboxMode == .fullAccess)

        let copilot = try RunnerHarness(agent: .copilot, script: Self.silent, host: RecordingHost())
        defer { copilot.tearDown() }
        let copilotCommands = kind.connect(to: StationCommands(store: copilot.store, runner: copilot.runner))
        let copilotID = copilot.session.id.uuidString
        let copilotSettings = try await copilotCommands.readRunSettings(copilotID)
        #expect(copilotSettings.setting("copilotAccess")?.choices.map(\.value) == ["", "workspace", "full-access"])
        _ = try await copilotCommands.changeRunSetting(copilotID, "copilotAccess", to: "full-access")
        #expect(copilot.store.session(copilot.session.id)?.settings?.copilotAccessMode == .fullAccess)

        let design = try codex.store.startDesign(for: codex.session.id).get()
        let designSettings = try await codexCommands.readRunSettings(design.id.uuidString)
        #expect(designSettings.setting("designAmbition")?.value == "")
        _ = try await codexCommands.changeRunSetting(design.id.uuidString, "designAmbition", to: "all-out")
        #expect(codex.store.session(design.id)?.settings?.designAmbition == .allOut)
        #expect(codexSettings.setting("designAmbition") == nil)
    }

    // A prompt goes with files named by their path on the host and with instructions for
    // it alone: the agent reads both, and the transcript keeps the files on the prompt and
    // the instructions beside it. A path to nothing is refused before anything is sent.
    @Test(arguments: StationImplementation.allCases)
    func aPromptGoesWithItsFilesAndCustomInstructions(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: """
        IFS= read -r input
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
        case "$input" in *'Answer in French.'*) ;; *) exit 7 ;; esac
        case "$input" in *'Attached files:'*'notes.txt'*) ;; *) exit 8 ;; esac
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Read them."}]}}'
        """, host: RecordingHost())
        defer { fixture.tearDown() }
        let file = fixture.scratch.path("notes.txt")
        try "remember the milk".write(to: file, atomically: true, encoding: .utf8)
        let session = try await Followed(fixture, kind)

        await #expect(throws: StationRefusal.self) {
            try await session.commands.sendPrompt(session.id, RemotePrompt(
                text: "Look", attachments: [fixture.scratch.path("missing.txt").path]))
        }
        try await session.commands.sendPrompt(session.id, RemotePrompt(
            text: "Look at this", attachments: [file.path], customInstructions: "  Answer in French.  "))

        #expect(await waitUntil {
            session.log.mirror?.header.isBusy == false
                && session.log.mirror?.messages.last?.text.hasSuffix("Read them.") == true
        }, "\(session.log.mirror?.messages.map(\.text) ?? [])")
        let messages = session.log.mirror?.messages ?? []
        let prompt = try #require(messages.first { $0.role == "user" })
        #expect(prompt.text == "Look at this")
        #expect(prompt.attachments == ["notes.txt"])
        #expect(messages.contains { $0.role == "instructions" && $0.text == "Answer in French." })
    }

    // The command menu lists what the app answers, the session's project commands, the
    // person's own and the CLI's, nearest first, each with the line under its name.
    @Test(arguments: StationImplementation.allCases)
    func theSlashCommandsAreListedNearestFirst(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: Self.silent, host: RecordingHost())
        defer { fixture.tearDown() }
        let commandsFolder = fixture.projectURL.appendingPathComponent(".claude/commands")
        try FileManager.default.createDirectory(at: commandsFolder, withIntermediateDirectories: true)
        try "---\ndescription: Ship the branch\n---\nShip it." .write(
            to: commandsFolder.appendingPathComponent("ship.md"), atomically: true, encoding: .utf8)
        let home = fixture.scratch.path("home")
        let userFolder = home.appendingPathComponent(".claude/commands")
        try FileManager.default.createDirectory(at: userFolder, withIntermediateDirectories: true)
        try "Tidy the imports.".write(to: userFolder.appendingPathComponent("tidy.md"), atomically: true, encoding: .utf8)
        let station = StationCommands(store: fixture.store, runner: fixture.runner)
        station.agentCommandsHome = home
        let commands = kind.connect(to: station)

        let listed = try await commands.listCommands(fixture.session.id.uuidString)

        #expect(listed.map(\.name) == ["clear", "compact", "plan", "ship", "tidy", "init", "review", "security-review"])
        #expect(listed.map(\.scope) == [.app, .app, .app, .project, .user, .builtIn, .builtIn, .builtIn])
        #expect(listed.first { $0.name == "ship" }?.summary == "Ship the branch")
        #expect(listed.first { $0.name == "tidy" }?.summary == "Tidy the imports.")
        await #expect(throws: StationRefusal.self) { try await commands.listCommands(UUID().uuidString) }
    }

    // A call that reaches a folder outside the session's says which, and allowing it with
    // the folder added hands the agent the folder and keeps it on the session for every
    // turn after. A call that reaches nowhere new offers no folder to add.
    @Test(arguments: StationImplementation.allCases)
    func grantingTheFolderACallReachesKeepsItOnTheSession(_ kind: StationImplementation) async throws {
        let outside = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
            .appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let folder = outside.resolvingSymlinksInPath().path
        let request = #"{"type":"control_request","request_id":"r9","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"cd \#(folder) && ls"}}}"#
        let fixture = try RunnerHarness(agent: .claudeCode, script: """
        IFS= read -r input
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
        printf '%s\\n' '\(request)'
        IFS= read -r answer
        case "$answer" in *'"addDirectories"'*) ;; *) exit 7 ;; esac
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Listed it."}]}}'
        """, host: RecordingHost())
        defer { fixture.tearDown() }
        let session = try await Followed(fixture, kind)

        try await session.commands.sendPrompt(session.id, prompt: "List it")
        #expect(await waitUntil { session.log.mirror?.permission != nil })
        let permission = try #require(session.log.mirror?.permission)
        #expect(permission.outsideDirectory == folder)

        try await session.commands.answerPermission(session.id, requestID: "r9", answer: .allowAddingDirectory)

        #expect(await waitUntil {
            session.log.mirror?.header.isBusy == false
                && session.log.mirror?.messages.last?.text.hasSuffix("Listed it.") == true
        }, "\(session.log.mirror?.messages.map(\.text) ?? [])")
        #expect(fixture.store.session(fixture.session.id)?.grantedDirectories == [folder])
    }

    // Asking to add a folder for a call that reaches none is refused, and the call still
    // waits for an answer.
    @Test(arguments: StationImplementation.allCases)
    func addingAFolderIsRefusedWhenTheCallReachesNone(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: """
        IFS= read -r input
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
        printf '%s\\n' '{"type":"control_request","request_id":"r3","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"}}}'
        IFS= read -r answer
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}'
        """, host: RecordingHost())
        defer { fixture.tearDown() }
        let session = try await Followed(fixture, kind)
        try await session.commands.sendPrompt(session.id, prompt: "List")
        #expect(await waitUntil { session.log.mirror?.permission != nil })
        #expect(session.log.mirror?.permission?.outsideDirectory == nil)

        await #expect(throws: StationRefusal.self) {
            try await session.commands.answerPermission(session.id, requestID: "r3", answer: .allowAddingDirectory)
        }
        #expect(session.log.mirror?.permission?.id == "r3")
        try await session.commands.answerPermission(session.id, requestID: "r3", answer: .deny)
    }
}
