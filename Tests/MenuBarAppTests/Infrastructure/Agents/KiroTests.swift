import Foundation
import SQLite3
import Testing
@testable import MenuBarApp

// The messages here are trimmed from what kiro-cli 3.5.0 sent over ACP on its V3 engine,
// recorded against a free account.
struct KiroConnectionTests {
    @Test func opensAnACPSessionAndSendsThePrompt() throws {
        let wire = try KiroWire()
        #expect(wire.connection.start("Fix the login retry"))
        let initialize = try wire.lastRequest()
        #expect(initialize["method"] as? String == "initialize")
        let params = try #require(initialize["params"] as? [String: Any])
        #expect(params["protocolVersion"] as? Int == 1)
        let capabilities = try #require(params["clientCapabilities"] as? [String: Any])
        #expect((capabilities["_meta"] as? [String: Any])?["terminal-auth"] as? Bool == true)
        #expect(capabilities["terminal"] as? Bool == false)

        _ = try wire.respond(initialize, ["protocolVersion": 1])
        let open = try wire.lastRequest()
        #expect(open["method"] as? String == "session/new")
        let openParams = try #require(open["params"] as? [String: Any])
        #expect(openParams["cwd"] as? String == "/tmp/project")
        #expect((openParams["mcpServers"] as? [Any])?.isEmpty == true)

        let opened = try wire.respond(open, ["sessionId": "sess_1"])
        #expect(opened.contains { if case .initialized("sess_1") = $0 { true } else { false } })
        let prompt = try wire.lastRequest()
        #expect(prompt["method"] as? String == "session/prompt")
        let blocks = (prompt["params"] as? [String: Any])?["prompt"] as? [[String: Any]]
        #expect(blocks?.first?["text"] as? String == "Fix the login retry")
    }

    @Test func setsTheChosenModelBeforeThePrompt() throws {
        let wire = try KiroWire(settings: SessionSettings(model: "claude-haiku-4.5"))
        try wire.open(options: [Self.option("model", "auto"), Self.option("mode", "vibe")])
        let set = try wire.lastRequest()
        #expect(set["method"] as? String == "session/set_config_option")
        let params = try #require(set["params"] as? [String: Any])
        #expect(params["configId"] as? String == "model")
        #expect(params["value"] as? String == "claude-haiku-4.5")
        _ = try wire.respond(set, [:])
        #expect(try wire.lastRequest()["method"] as? String == "session/prompt")
    }

    @Test func leavesOptionsAloneWhenTheSessionAlreadyHasThem() throws {
        let wire = try KiroWire(settings: SessionSettings(model: "auto"))
        try wire.open(options: [Self.option("model", "auto"), Self.option("mode", "vibe")])
        #expect(try wire.lastRequest()["method"] as? String == "session/prompt")
    }

    @Test func plansInKirosOwnPlanMode() throws {
        let wire = try KiroWire(settings: SessionSettings(permissionMode: .plan))
        try wire.open(options: [Self.option("mode", "vibe")])
        let set = try wire.lastRequest()
        #expect((set["params"] as? [String: Any])?["configId"] as? String == "mode")
        #expect((set["params"] as? [String: Any])?["value"] as? String == "plan")
    }

    @Test func foldsChunksAndToolCallsOntoTheTurn() throws {
        let wire = try KiroWire()
        try wire.open()
        var events = try wire.update(["sessionUpdate": "session_info_update",
                                      "_meta": ["kiro": ["kind": "turn_start"]]])
        events += try wire.update(Self.chunk("agent_thought_chunk", "The user wants a file"))
        events += try wire.update(Self.chunk("agent_message_chunk", "I'll create "))
        events += try wire.update(Self.chunk("agent_message_chunk", "the file."))
        events += try wire.update([
            "sessionUpdate": "tool_call", "toolCallId": "call_1", "title": "Write File",
            "kind": "edit", "status": "in_progress",
            "rawInput": ["path": "/tmp/project/hello.txt", "text": "hello"],
        ])
        events += try wire.update([
            "sessionUpdate": "tool_call_update", "toolCallId": "call_1", "status": "completed",
            "rawOutput": ["message": "Created the /tmp/project/hello.txt file."],
        ])
        events += try wire.update(Self.chunk("agent_message_chunk", "Done."))
        events += try wire.respond(wire.promptRequest(), ["stopReason": "end_turn"])

        // Each chunk is handed on as it arrives. The second piece of text carries on the
        // first; the text after the tool call opens a block of its own.
        guard events.count == 8,
              case .turnStarted = events[0],
              case .thinkingChunk("The user wants a file", false) = events[1],
              case .textChunk("I'll create ", false) = events[2],
              case .textChunk("the file.", true) = events[3],
              case .toolUse(let tool) = events[4],
              case .toolResult("call_1", "Created the /tmp/project/hello.txt file.", false, nil) = events[5],
              case .textChunk("Done.", false) = events[6],
              case .finished(false, nil) = events[7] else {
            Issue.record("Unexpected events: \(events.map(\.logSummary))")
            return
        }
        #expect(tool.name == "Write")
        #expect(tool.input.contains("\"file_path\" : \"/tmp/project/hello.txt\""))
    }

    @Test func thinkingCarriesOnUntilTextInterrupts() throws {
        let wire = try KiroWire()
        try wire.open()
        let events = try wire.update(Self.chunk("agent_thought_chunk", "First"))
            + wire.update(Self.chunk("agent_thought_chunk", " thought"))
            + wire.update(Self.chunk("agent_message_chunk", "Text"))
            + wire.update(Self.chunk("agent_thought_chunk", "Second"))
            + wire.update(Self.chunk("agent_message_chunk", ""))
        guard events.count == 4,
              case .thinkingChunk("First", false) = events[0],
              case .thinkingChunk(" thought", true) = events[1],
              case .textChunk("Text", false) = events[2],
              case .thinkingChunk("Second", false) = events[3] else {
            Issue.record("Unexpected events: \(events.map(\.logSummary))")
            return
        }
    }

    @Test func letsEditsInsideTheWorkspaceThroughWhenEditsAreAllowed() throws {
        let wire = try KiroWire(settings: SessionSettings(permissionMode: .acceptEdits))
        try wire.open()
        let before = wire.output.messages.count
        let events = try wire.askPermission(id: 41, capability: "fs_write", resource: "hello.txt")
        #expect(events.isEmpty)
        let reply = try wire.decode(#require(wire.output.messages.last))
        #expect(wire.output.messages.count == before + 1)
        #expect(reply["id"] as? Int == 41)
        #expect(Self.optionID(in: reply) == "accept")
    }

    @Test func asksAboutEditsOutsideTheWorkspace() throws {
        let wire = try KiroWire(settings: SessionSettings(permissionMode: .acceptEdits))
        try wire.open()
        let events = try wire.askPermission(id: 42, capability: "fs_write", resource: "/etc/hosts")
        #expect(events.count == 1)
    }

    @Test(arguments: [(PermissionAnswer.allowOnce, "accept"), (.allowAlways, "always-accept"),
                      (.deny, "reject")])
    func asksAboutCommandsAndSendsTheMatchingOption(answer: PermissionAnswer, option: String) throws {
        let wire = try KiroWire(settings: SessionSettings(permissionMode: .acceptEdits))
        try wire.open()
        _ = try wire.update([
            "sessionUpdate": "tool_call", "toolCallId": "run_1", "title": "Run Command",
            "kind": "execute", "status": "pending",
            "rawInput": ["command": "cat hello.txt", "cwd": "/tmp/project"],
        ])
        let events = try wire.askPermission(id: 43, capability: "shell", resource: "cat hello.txt",
                                            callID: "run_1", title: "cat hello.txt")
        guard case .permissionRequest(let request) = events.first else {
            Issue.record("Expected a permission request, got \(events.map(\.logSummary))")
            return
        }
        #expect(request.toolName == "Bash")
        #expect(request.subject == "cat hello.txt")
        #expect(request.alwaysTitle != nil)
        #expect(wire.connection.answer(request, with: answer))
        let reply = try wire.decode(#require(wire.output.messages.last))
        #expect(reply["id"] as? Int == 43)
        #expect(Self.optionID(in: reply) == option)
    }

    @Test func resumesByLoadingTheSessionAndSkipsItsReplay() throws {
        let wire = try KiroWire(resume: "sess_old")
        #expect(wire.connection.start("What did you create?"))
        _ = try wire.respond(wire.lastRequest(), ["protocolVersion": 1])
        let load = try wire.lastRequest()
        #expect(load["method"] as? String == "session/load")
        #expect((load["params"] as? [String: Any])?["sessionId"] as? String == "sess_old")
        let replay = try wire.update([
            "sessionUpdate": "agent_message_chunk",
            "content": ["type": "text", "text": "Created hello.txt"],
            "_meta": ["kiro": ["replay": true]],
        ], session: "sess_old")
        #expect(replay.isEmpty)
        // Loading answers without naming the session, so the one asked for is kept.
        let opened = try wire.respond(load, [:])
        #expect(opened.contains { if case .initialized("sess_old") = $0 { true } else { false } })
    }

    @Test func aSignedOutKiroReadsAsSignedOut() throws {
        let wire = try KiroWire()
        #expect(wire.connection.start("Hello"))
        _ = try wire.respond(wire.lastRequest(), ["protocolVersion": 1])
        let events = wire.connection.receive(try wire.frame([
            "id": try #require(wire.lastRequest()["id"]),
            "error": ["code": -32000, "message": "Authentication required. Not logged in. Set the KIRO_API_KEY environment variable or run `kiro-cli login` first. Then reconnect to start the Kiro agent."],
        ]))
        guard case .finished(true, let message?) = events.first else {
            Issue.record("Expected a failed turn, got \(events.map(\.logSummary))")
            return
        }
        #expect(SessionRunner.signedOut(.kiro, message: message))
    }

    @Test func cancellingSendsTheACPNotificationAndTheTurnEnds() throws {
        let wire = try KiroWire()
        try wire.open()
        let prompt = try wire.promptRequest()
        #expect(wire.connection.cancelTasks())
        let cancel = try wire.lastRequest()
        #expect(cancel["method"] as? String == "session/cancel")
        #expect(cancel["id"] == nil)
        let events = try wire.respond(prompt, ["stopReason": "cancelled"])
        #expect(events.contains { if case .finished(false, _) = $0 { true } else { false } })
    }

    @Test func aRefusalFailsTheTurn() throws {
        let wire = try KiroWire()
        try wire.open()
        let events = try wire.respond(wire.promptRequest(), ["stopReason": "refusal"])
        #expect(events.contains { if case .finished(true, _) = $0 { true } else { false } })
    }

    static func option(_ id: String, _ value: String) -> [String: Any] {
        ["type": "select", "id": id, "currentValue": value]
    }

    static func chunk(_ kind: String, _ text: String) -> [String: Any] {
        ["sessionUpdate": kind, "content": ["type": "text", "text": text]]
    }

    static func optionID(in reply: [String: Any]) -> String? {
        ((reply["result"] as? [String: Any])?["outcome"] as? [String: Any])?["optionId"] as? String
    }
}

struct KiroServiceTests {
    @Test func readsWhoIsSignedIn() throws {
        let github = KiroCLI.reading(
            status: 0, output: #"{"accountType":"SocialGitHub","provider":"GitHub","email":"person@example.com"}"#,
            errorOutput: "")
        guard case .signedIn(let account) = github else { Issue.record("\(github)"); return }
        #expect(account.summary == "person@example.com · via GitHub")
        #expect(KiroCLI.reading(status: 1, output: #"{"account":null}"#, errorOutput: "") == .signedOut)
    }

    // Kiro says who is signed in differently for each way in. Whatever shape the answer
    // takes, a successful whoami is a signed-in account.
    @Test(arguments: [
        #"{"accountType":"IamIdentityCenter","startUrl":"https://d-1.awsapps.com/start","region":"eu-west-1"}"#,
        #"{"account":{"type":"IdC","startUrl":"https://d-1.awsapps.com/start"}}"#,
        "A new version of kiro-cli is available\n{\"accountType\":\"IamIdentityCenter\"}",
        "{}",
    ])
    func anySuccessfulAnswerIsSignedIn(output: String) {
        guard case .signedIn(let account) = KiroCLI.reading(status: 0, output: output, errorOutput: "") else {
            Issue.record("Expected a signed-in reading for \(output)")
            return
        }
        #expect(!account.summary.isEmpty)
    }

    @Test func namesIdentityCenterByItsOrganisation() {
        let account = KiroCLI.Account(fields: ["accountType": "IamIdentityCenter",
                                               "startUrl": "https://d-1.awsapps.com/start"])
        #expect(account.summary == "d-1.awsapps.com · via IAM Identity Center")
    }

    @Test func readsThePlainTextAnswerToo() {
        guard case .signedIn(let account) = KiroCLI.reading(
            status: 0, output: "Logged in with IAM Identity Center\nEmail: person@example.com", errorOutput: "")
        else { Issue.record("Expected signed in"); return }
        #expect(account.summary == "person@example.com · via IAM Identity Center")
    }

    @Test func keepsWhatTheCLISaidWhenTheAnswerCannotBeRead() {
        #expect(KiroCLI.reading(status: 1, output: "", errorOutput: "Not logged in. Run kiro-cli login")
            == .signedOut)
        #expect(KiroCLI.reading(status: 2, output: "", errorOutput: "error: token refresh failed\nmore")
            == .unknown("error: token refresh failed"))
    }

    @Test func readsTheModelCatalog() throws {
        let json = #"""
        {"models":[{"model_name":"auto","description":"Models chosen by task","model_id":"auto","rate_multiplier":1.0},
        {"model_name":"claude-sonnet-4.5","description":"Claude Sonnet 4.5 model","model_id":"claude-sonnet-4.5","rate_multiplier":1.3},
        {"model_name":"qwen3-coder-next","description":"Experimental preview of Qwen3 Coder Next","model_id":"qwen3-coder-next","rate_multiplier":0.05}],
        "default_model":"auto"}
        """#
        let options = try #require(KiroCLI.options(in: Data(json.utf8)))
        #expect(options.map(\.id) == ["auto", "claude-sonnet-4.5", "qwen3-coder-next"])
        #expect(options.map(\.title) == ["Auto", "Claude Sonnet 4.5", "Qwen3 Coder Next"])
        #expect(options[0].isDefault)
        #expect(options[1].detail.hasPrefix("Claude Sonnet 4.5 model. "))
        // The multiplier is written the way the Mac's locale writes numbers.
        #expect(options[1].detail.hasSuffix("\(1.3.formatted(.number.precision(.fractionLength(0...2))))× credits."))
    }

    // Kiro keeps one row per token in its database; logging out empties the table.
    @Test(arguments: [
        (["kirocli:social:token"], "via GitHub or Google"),
        (["kirocli:odic:device-registration", "kirocli:odic:token"], "via your organisation's sign-in"),
    ])
    func aTokenInKirosDatabaseIsASignIn(keys: [String], method: String) throws {
        let database = try Self.database(keys: keys)
        guard case .signedIn(let account)? = KiroCLI.storedSignIn(database: database) else {
            Issue.record("Expected a stored sign-in for \(keys)")
            return
        }
        #expect(account.method == method)
    }

    @Test func anEmptyTableIsSignedOutAndNoDatabaseSaysNothing() throws {
        #expect(KiroCLI.storedSignIn(database: try Self.database(keys: [])) == .signedOut)
        #expect(KiroCLI.storedSignIn(database: try Self.database(keys: ["kirocli:odic:device-registration"]))
            == .signedOut)
        #expect(KiroCLI.storedSignIn(database: URL(fileURLWithPath: "/tmp/no-such-kiro.sqlite3")) == nil)
    }

    // An organisation's sign-in reads as nobody to whoami, yet works; the database wins.
    @Test func theDatabaseSpeaksForSignInsWhoamiCannotSee() {
        let organisation = KiroCLI.AccountReading.signedIn(KiroCLI.Account(accountType: "Organization"))
        #expect(KiroCLI.combined(asked: .signedOut, stored: organisation) == organisation)
        #expect(KiroCLI.combined(asked: .unknown("error"), stored: organisation) == organisation)
        #expect(KiroCLI.combined(asked: .signedOut, stored: .signedOut) == .signedOut)
        #expect(KiroCLI.combined(asked: .unknown("error"), stored: nil) == .unknown("error"))
        let github = KiroCLI.AccountReading.signedIn(KiroCLI.Account(provider: "GitHub", email: "a@b.c"))
        #expect(KiroCLI.combined(asked: github, stored: .signedIn(KiroCLI.Account(accountType: "Social"))) == github)
    }

    private static func database(keys: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiro-\(UUID().uuidString).sqlite3")
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        var sql = "CREATE TABLE auth_kv (key TEXT PRIMARY KEY, value TEXT);"
        for key in keys { sql += "INSERT INTO auth_kv VALUES ('\(key)', '{}');" }
        #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
        return url
    }

    @Test func namesKirosToolsTheWayTheAppDrawsThem() {
        #expect(KiroStream.call(kind: "edit", title: "Replace in File",
                                input: ["path": "a.txt", "oldStr": "hello", "newStr": "goodbye"]).name == "Edit")
        #expect(KiroStream.call(kind: "edit", title: "Write File",
                                input: ["path": "a.txt", "text": "hello"]).name == "Write")
        #expect(KiroStream.call(kind: "execute", title: "Run Command",
                                input: ["command": "ls", "cwd": "/tmp"]).name == "Bash")
        #expect(KiroStream.call(kind: "read", title: "Read File",
                                input: ["path": "a.txt", "offset": NSNull()]).name == "Read")
        let other = KiroStream.call(kind: "other", title: "Knowledge", input: ["query": "auth"])
        #expect(other.name == "Knowledge")
        #expect(other.input.contains("\"query\" : \"auth\""))
    }

    @Test func onlyKiroIsMarkedBeta() {
        #expect(AgentKind.allCases.filter(\.isBeta) == [.kiro])
        #expect(AgentKind.kiro.blurb.hasPrefix("Beta"))
        #expect(AgentKind.kiro.betaNote?.contains("beta") == true)
        #expect(AgentKind.codex.betaNote == nil)
        #expect(AgentKind.codex.blurb == "OpenAI's coding agent.")
    }

    @Test func offersOnlyTheModesKiroCanHonour() {
        #expect(PermissionMode.choices(for: .kiro) == [.acceptEdits, .manual, .plan])
        #expect(PermissionMode.choices(for: .claudeCode) == PermissionMode.allCases)
        #expect(EffortChoice.all(for: .kiro).map(\.id) == [nil])
    }
}

private final class KiroWire {
    final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Data] = []
        var messages: [Data] { lock.withLock { stored } }
        func append(_ data: Data) { lock.withLock { stored.append(data) } }
    }

    let output = Output()
    let connection: AgentSessionConnection

    init(settings: SessionSettings = SessionSettings(), resume: String? = nil) throws {
        let output = self.output
        connection = AgentSessionConnection(launch: try AgentServerLaunch(
            configuration: AgentLaunchConfiguration(agent: .kiro, settings: settings,
                                                    defaults: SessionSettings(), resume: resume),
            directory: "/tmp/project")) {
                output.append($0)
                return true
            }
    }

    // Starts the session through to its first prompt.
    func open(options: [[String: Any]]? = nil) throws {
        #expect(connection.start("Create hello.txt"))
        _ = try respond(lastRequest(), ["protocolVersion": 1])
        var result: [String: Any] = ["sessionId": "sess_1"]
        if let options { result["configOptions"] = options }
        _ = try respond(lastRequest(), result)
    }

    func promptRequest() throws -> [String: Any] {
        try #require(output.messages.map(decode).last { $0["method"] as? String == "session/prompt" })
    }

    func frame(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object) + Data([0x0A])
    }

    func decode(_ bytes: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

    func lastRequest() throws -> [String: Any] { try decode(#require(output.messages.last)) }

    func respond(_ request: [String: Any], _ result: [String: Any]) throws -> [StreamEvent] {
        connection.receive(try frame(["jsonrpc": "2.0", "id": try #require(request["id"]), "result": result]))
    }

    func update(_ update: [String: Any], session: String = "sess_1") throws -> [StreamEvent] {
        connection.receive(try frame(["jsonrpc": "2.0", "method": "session/update",
                                      "params": ["sessionId": session, "update": update]]))
    }

    func askPermission(id: Int, capability: String, resource: String,
                       callID: String = "call_9", title: String = "Write File") throws -> [StreamEvent] {
        connection.receive(try frame([
            "jsonrpc": "2.0", "id": id, "method": "session/request_permission",
            "params": [
                "sessionId": "sess_1",
                "toolCall": ["toolCallId": callID, "status": "pending", "title": title],
                "options": [
                    ["optionId": "accept", "name": "Allow", "kind": "allow_once"],
                    ["optionId": "always-accept", "name": "Always allow", "kind": "allow_always"],
                    ["optionId": "reject", "name": "Deny", "kind": "reject_once"],
                    ["optionId": "always-reject", "name": "Always deny", "kind": "reject_always"],
                ],
                "_meta": ["kiro": ["consent": ["capability": capability, "resource": resource,
                                               "workspaceRoot": "/tmp/project"]]],
            ],
        ]))
    }
}

// Kiro's reply reaches the transcript piece by piece, through the real runner.
@MainActor
struct KiroStreamingRunnerTests {
    @Test func piecesJoinIntoTheReplyAndAToolCallStartsANewParagraph() async throws {
        let harness = try RunnerHarness(agent: .kiro, script: FixtureCLI.kiroServer(onPrompt: """
            kiro_think 'Reading '
            kiro_think 'the notes'
            kiro_say 'Let me '
            kiro_say 'look.'
            kiro_tool read_1
            kiro_say 'It says '
            kiro_say 'hello.'
            kiro_end
            """))
        defer { harness.tearDown() }
        harness.runner.send("What is in notes.txt?", sessionID: harness.session.id, store: harness.store)
        #expect(await waitUntil { harness.runner.state(harness.session.id) == .idle })
        let reply = try #require(harness.store.transcript(of: harness.session.id).last)
        #expect(reply.text == "Let me look.\n\nIt says hello.")
        #expect(reply.thinking?.map(\.text) == ["Reading the notes"])
        #expect(reply.tools.map(\.id) == ["read_1"])
        #expect(reply.tools.first?.textOffset == "Let me look.".count)
    }
}

// Kiro sessions are handed Code Station's MCP servers when they open, following the
// session's own choices.
struct KiroMCPServerTests {
    private static let local = Server(name: "grafana", command: "npx", args: ["-y", "grafana,mcp"],
                                      env: [EnvVar(key: "TOKEN", value: "t")], headers: [], disabled: false)
    private static let remote = Server(name: "docs", args: [], url: "https://docs.example/mcp", type: "http",
                                       env: [], headers: [EnvVar(key: "Authorization", value: "Bearer x")],
                                       disabled: false)
    private static let switchedOff = Server(name: "old", command: "old-mcp", args: [], env: [], headers: [],
                                            disabled: true)
    private static let all = [local, remote, switchedOff]

    @Test func handsOverEveryServerSwitchedOnInTheApp() {
        let handed = KiroMCPServer.handedTo(SessionSettings(), from: Self.all,
                                            resolve: { $0 == "npx" ? "/opt/homebrew/bin/npx" : nil })
        #expect(handed.map(\.name) == ["grafana", "docs"])
        #expect(handed[0].command == "/opt/homebrew/bin/npx")
        #expect(handed[0].args == ["-y", "grafana,mcp"])
        #expect(handed[0].env == ["TOKEN": "t"])
        #expect(handed[1].url == "https://docs.example/mcp")
        #expect(handed[1].headers == ["Authorization": "Bearer x"])
    }

    @Test func followsTheSessionsChoices() {
        #expect(KiroMCPServer.handedTo(SessionSettings(mcpServersEnabled: false), from: Self.all).isEmpty)
        #expect(KiroMCPServer.handedTo(SessionSettings(allowedMCPServerNames: ["docs"]), from: Self.all)
            .map(\.name) == ["docs"])
        #expect(KiroMCPServer.handedTo(
            SessionSettings(disabledMCPServers: [DisabledMCPServer(name: "grafana", transport: .stdio)]),
            from: Self.all).map(\.name) == ["docs"])
    }

    @Test func leavesOutServersKiroCannotReach() {
        let websocket = Server(name: "ws", args: [], url: "wss://x", type: "ws", env: [], headers: [], disabled: false)
        let empty = Server(name: "empty", args: [], env: [], headers: [], disabled: false)
        #expect(KiroMCPServer.handedTo(SessionSettings(), from: [websocket, empty]).isEmpty)
    }

    @Test func writesTheEntriesTheWayACPTakesThem() throws {
        let handed = KiroMCPServer.handedTo(SessionSettings(), from: [Self.local, Self.remote])
        let local = handed[0].acp
        #expect(local["name"] as? String == "grafana")
        #expect(local["command"] as? String == "npx")
        #expect(local["args"] as? [String] == ["-y", "grafana,mcp"])
        #expect(local["env"] as? [[String: String]] == [["name": "TOKEN", "value": "t"]])
        let remote = handed[1].acp
        #expect(remote["type"] as? String == "http")
        #expect(remote["url"] as? String == "https://docs.example/mcp")
        #expect(remote["headers"] as? [[String: String]] == [["name": "Authorization", "value": "Bearer x"]])
    }

    @Test func aKiroSessionOpensAndResumesWithItsServers() throws {
        let servers = KiroMCPServer.handedTo(SessionSettings(), from: [Self.local])
        for resume in [nil, "sess_old"] as [String?] {
            let launch = try AgentServerLaunch(
                configuration: AgentLaunchConfiguration(agent: .kiro, settings: SessionSettings(),
                                                        defaults: SessionSettings(), resume: resume,
                                                        kiroMCPServers: servers),
                directory: "/tmp/project")
            let params = try #require(JSONSerialization.jsonObject(with: launch.sessionParameters) as? [String: Any])
            let handed = try #require(params["mcpServers"] as? [[String: Any]])
            #expect(handed.map { $0["name"] as? String } == ["grafana"])
        }
    }

    @MainActor
    @Test func troubleshootCountsTheServersKiroIsHanded() {
        let ready = TroubleshootMCPState.resolve(
            agent: .kiro, enabled: true, servers: [Self.local, Self.remote], hasStartedCheck: false,
            claude: ClaudeCodeManager(), codex: CodexCodeManager(), copilot: CopilotCodeManager())
        #expect(ready == .ready)
        let off = TroubleshootMCPState.resolve(
            agent: .kiro, enabled: true, servers: [Self.local, Self.switchedOff], hasStartedCheck: false,
            claude: ClaudeCodeManager(), codex: CodexCodeManager(), copilot: CopilotCodeManager())
        #expect(off != .ready)
    }
}

// How Kiro's MCP calls read in the transcript, from what kiro-cli 3.5.0 sent.
struct KiroMCPCallTests {
    @Test func anMCPCallReadsLikeTheOtherAgents() {
        let call = KiroStream.call(kind: "other", title: "@ping-local/ping", input: [:])
        #expect(call.name == "MCP")
        #expect(call.input == "ping-local.ping")
        #expect(KiroStream.mcpCall(resource: "ping-local/ping")?.input == "ping-local.ping")
    }

    @Test func kirosToolLoadingIsHidden() throws {
        let wire = try KiroWire()
        try wire.open()
        let events = try wire.update([
            "sessionUpdate": "tool_call", "toolCallId": "load_1", "title": "Tool Load", "kind": "other",
            "status": "in_progress", "rawInput": ["id": "tool::ping-local::ping"],
        ]) + wire.update([
            "sessionUpdate": "tool_call_update", "toolCallId": "load_1", "status": "completed",
            "rawOutput": ["message": "{\"loaded\": []}"],
        ]) + wire.update([
            "sessionUpdate": "tool_call", "toolCallId": "mcp_1", "title": "@ping-local/ping", "kind": "other",
            "status": "pending", "rawInput": [:],
        ]) + wire.update([
            "sessionUpdate": "tool_call_update", "toolCallId": "mcp_1", "status": "completed",
            "rawOutput": ["response": "pong", "message": "pong"],
        ])
        guard events.count == 2, case .toolUse(let tool) = events[0],
              case .toolResult("mcp_1", "pong", false, nil) = events[1] else {
            Issue.record("Unexpected events: \(events.map(\.logSummary))")
            return
        }
        #expect(tool.name == "MCP")
    }
}

// Kiro counts usage in plan credits, reported once per turn.
struct KiroCreditsTests {
    private static func completion(_ usages: [Double], unit: String = "credit", replay: Bool = false) -> [String: Any] {
        var kiro: [String: Any] = [
            "kind": "turn_completion",
            "promptTurnSummaries": usages.map { ["unit": unit, "unitPlural": unit + "s", "usage": $0] },
        ]
        if replay { kiro["replay"] = true }
        return ["sessionUpdate": "session_info_update", "_meta": ["kiro": kiro]]
    }

    @Test func reportsCreditsAsARunningTotal() throws {
        let wire = try KiroWire()
        try wire.open()
        let first = try wire.update(Self.completion([0.03, 0.01]))
        let second = try wire.update(Self.completion([0.02]))
        guard case .usage(let a)? = first.first, case .usage(let b)? = second.first else {
            Issue.record("Expected usage reports, got \((first + second).map(\.logSummary))")
            return
        }
        #expect(abs(a.credits - 0.04) < 1e-9)
        #expect(abs(b.credits - 0.06) < 1e-9)
    }

    @Test func ignoresOtherUnitsAndReplayedTurns() throws {
        let wire = try KiroWire()
        try wire.open()
        #expect(try wire.update(Self.completion([5], unit: "token")).isEmpty)
        #expect(try wire.update(Self.completion([0.5], replay: true)).isEmpty)
    }

    @Test func aSessionSavedBeforeCreditsStillReads() throws {
        let old = #"{"costUSD":0,"inputTokens":1,"outputTokens":2,"cacheReadTokens":0,"cacheWriteTokens":0,"turns":1,"contextTokens":0,"contextWindow":0}"#
        let usage = try JSONDecoder().decode(SessionUsage.self, from: Data(old.utf8))
        #expect(usage.credits == nil)
    }

    @Test func writesCredits() {
        #expect(Money.credits(1) == "1 credit")
        #expect(Money.credits(0.004).hasPrefix("< "))
        #expect(Money.credits(2) == "2 credits")
        #expect(Money.credits(0.25) == "\(0.25.formatted(.number.precision(.fractionLength(0...2)))) credits")
    }
}

@MainActor
struct KiroCreditsRunnerTests {
    @Test func eachTurnsCreditsAddUpOnTheSession() async throws {
        let harness = try RunnerHarness(agent: .kiro, script: FixtureCLI.kiroServer(onPrompt: """
            kiro_say 'Done.'
            kiro_credits 0.25
            kiro_end
            """))
        defer { harness.tearDown() }
        for prompt in ["First", "Second"] {
            harness.runner.send(prompt, sessionID: harness.session.id, store: harness.store)
            #expect(await waitUntil { harness.runner.state(harness.session.id) == .idle })
        }
        let usage = try #require(harness.store.session(harness.session.id)?.usage)
        #expect(usage.credits == 0.5)
        #expect(usage.costUSD == 0)
    }
}
