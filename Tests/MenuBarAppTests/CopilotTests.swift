import Foundation
import Testing
@testable import MenuBarApp

// Running a session on Copilot: the arguments its CLI takes, its JSONL session log
// folded onto the app's events, its model catalog and sign-in read off its headless
// server, and a turn driven end to end through a fake CLI.
struct CopilotTests {

    // MARK: - MCP registration

    @Test func copilotRegistersAStdioMCPServerWithItsEnvironment() {
        let server = Server(name: "grafana-platform-dev", command: "mcp-grafana", args: ["--debug"],
                            url: nil, type: nil,
                            env: [EnvVar(key: "GRAFANA_URL", value: "https://grafana.example")],
                            headers: [], disabled: false)

        #expect(CopilotCodeManager.addArguments(for: server, executable: "/opt/homebrew/bin/mcp-grafana") == [
            "mcp", "add", "grafana-platform-dev", "--env", "GRAFANA_URL=https://grafana.example",
            "--", "/opt/homebrew/bin/mcp-grafana", "--debug",
        ])
    }

    @Test func copilotRegistersRemoteServersWithTheirHeadersAndTransport() {
        let http = Server(name: "remote", command: nil, args: [], url: "https://mcp.example/mcp",
                          type: "http", env: [],
                          headers: [EnvVar(key: "Authorization", value: "Bearer t")], disabled: false)
        #expect(CopilotCodeManager.addArguments(for: http, executable: nil) == [
            "mcp", "add", "remote", "https://mcp.example/mcp", "--header", "Authorization: Bearer t",
        ])

        let sse = Server(name: "events", command: nil, args: [], url: "https://mcp.example/sse",
                         type: "sse", env: [], headers: [], disabled: false)
        #expect(CopilotCodeManager.addArguments(for: sse, executable: nil) == [
            "mcp", "add", "events", "https://mcp.example/sse", "--transport", "sse",
        ])
        #expect(CopilotCodeManager.addArguments(for: Server(
            name: "none", command: nil, args: [], url: nil, type: nil, env: [], headers: [],
            disabled: false), executable: nil) == nil)
    }

    @Test func copilotListsItsServersAsAMapByName() throws {
        let entries = try #require(CopilotCodeManager.entries(in: Data("""
        {"mcpServers": {
          "local": {"tools": ["*"], "type": "local", "command": "/usr/bin/false",
                    "args": ["--flag"], "env": {"FOO": "bar"}, "source": "user", "enabled": true},
          "remote": {"tools": ["*"], "type": "http", "url": "https://mcp.example/mcp",
                     "headers": {"Authorization": "Bearer x"}, "source": "user", "enabled": false}
        }}
        """.utf8)))
        #expect(entries["local"] == CopilotCodeManager.Entry(
            command: "/usr/bin/false", args: ["--flag"], env: ["FOO": "bar"], url: nil, type: nil,
            headers: [:], enabled: true))
        #expect(entries["remote"] == CopilotCodeManager.Entry(
            command: nil, args: [], env: [:], url: "https://mcp.example/mcp", type: "http",
            headers: ["Authorization": "Bearer x"], enabled: false))
    }

    // MARK: - Arguments

    @Test func copilotRunsPromptModeWithThePromptAsAnArgument() {
        let arguments = SessionRunner.arguments(agent: .copilot,
                                                settings: SessionSettings(),
                                                defaults: SessionSettings(),
                                                newSessionID: "11111111-2222-4333-8444-555555555555",
                                                prompt: "-dash first")
        #expect(arguments.starts(with: ["-p", "-dash first", "--output-format", "json"]))
        #expect(arguments.contains("--allow-all-tools"))
        #expect(!arguments.contains("--allow-all"))
        #expect(arguments.contains("--no-ask-user"))
        #expect(arguments.contains("--session-id"))
        #expect(arguments.contains("11111111-2222-4333-8444-555555555555"))
        #expect(!arguments.contains("--resume"))
        // The other CLIs' flags have no place here.
        #expect(!arguments.contains("--permission-mode"))
        #expect(!arguments.contains("exec"))
        #expect(arguments.last != "-")
    }

    @Test func aResumedCopilotTurnNamesItsSessionInsteadOfANewOne() {
        let arguments = SessionRunner.arguments(agent: .copilot,
                                                settings: SessionSettings(),
                                                defaults: SessionSettings(),
                                                resume: "session-1",
                                                newSessionID: "unused",
                                                prompt: "carry on")
        #expect(arguments.contains("--resume"))
        #expect(arguments.contains("session-1"))
        #expect(!arguments.contains("--session-id"))
        #expect(!arguments.contains("unused"))
    }

    @Test func copilotFullAccessOpensEverything() {
        let settings = SessionSettings(copilotAccessMode: CopilotAccessMode.fullAccess.rawValue)
        let arguments = SessionRunner.arguments(agent: .copilot,
                                                settings: settings,
                                                defaults: SessionSettings(),
                                                prompt: "go")
        #expect(arguments.contains("--allow-all"))
        #expect(!arguments.contains("--allow-all-tools"))
    }

    @Test func copilotGuidanceRidesInThePrompt() {
        let arguments = SessionRunner.arguments(agent: .copilot,
                                                settings: SessionSettings(),
                                                defaults: SessionSettings(),
                                                addDirectories: ["/tmp/shots"],
                                                prompt: "draw it",
                                                additionalSystemPrompt: "Write the design to canvas.html.")
        #expect(arguments[1] == "Write the design to canvas.html.\n\ndraw it")
        #expect(!arguments.contains("--append-system-prompt"))
        #expect(arguments.contains("--add-dir"))
        #expect(arguments.contains("/tmp/shots"))
    }

    @Test func copilotTakesTheChosenModelEffortAndServerChoices() {
        let settings = SessionSettings(model: "claude-opus-5", effort: "high",
                                       mcpServersEnabled: false,
                                       disabledMCPServers: [
                                           DisabledMCPServer(name: "grafana", transport: .stdio),
                                       ])
        let arguments = SessionRunner.arguments(agent: .copilot,
                                                settings: settings,
                                                defaults: SessionSettings(),
                                                prompt: "go")
        #expect(arguments.contains("--model"))
        #expect(arguments.contains("claude-opus-5"))
        #expect(arguments.contains("--effort"))
        #expect(arguments.contains("high"))
        #expect(arguments.contains("--disable-builtin-mcps"))
        #expect(arguments.contains("--disable-mcp-server"))
        #expect(arguments.contains("grafana"))
    }

    // MARK: - Models

    @Test func copilotAcceptsAnyModelUntilItsCatalogIsKnown() {
        #expect(ModelChoice.valid("claude-sonnet-5", for: .copilot) == "claude-sonnet-5")
        #expect(ModelChoice.valid("gpt-5.4", for: .copilot) == "gpt-5.4")
        let discovered = [ModelChoice.Option(id: "auto", title: "Auto", detail: "")]
        #expect(ModelChoice.valid("auto", for: .copilot, discovered: discovered) == "auto")
        #expect(ModelChoice.valid("gpt-5.4", for: .copilot, discovered: discovered) == nil)
        #expect(ModelChoice.options(for: .copilot, discovered: discovered).map(\.id) == [nil, "auto"])
    }

    @Test func theCatalogIsReadOffTheServerReply() throws {
        let response: [String: Any] = ["models": [
            ["id": "auto", "name": "Auto", "capabilities": [:]],
            ["id": "claude-sonnet-5", "name": "Claude Sonnet 5",
             "modelPickerCategory": "versatile",
             "supportedReasoningEfforts": ["low", "medium", "high"],
             "policy": ["state": "enabled"]],
            ["id": "gpt-5.4", "name": "GPT-5.4", "policy": ["state": "disabled"]],
            ["id": "claude-sonnet-5", "name": "Again"],
        ]]
        let options = try #require(CopilotServer.options(in: response))
        #expect(options.map(\.id) == ["auto", "claude-sonnet-5"])
        #expect(options[0].detail == "Copilot picks the model for each request.")
        #expect(options[1].supportedEfforts == ["low", "medium", "high"])
        #expect(EffortChoice.all(for: .copilot, model: "claude-sonnet-5",
                                 discovered: options).compactMap(\.id) == ["low", "medium", "high"])
    }

    @Test func theSignInIsReadOffTheServerReply() {
        let status = CopilotServer.AuthStatus(response: [
            "isAuthenticated": true, "authType": "gh-cli", "login": "jo",
        ])
        #expect(status?.summary == "jo · via the gh CLI")
        let signedOut = CopilotServer.AuthStatus(response: ["isAuthenticated": false])
        #expect(signedOut?.summary == nil)
    }

    // MARK: - Stream

    @Test func aMessageBecomesText() {
        let stream = CopilotStream()
        let events = stream.parse(#"{"type":"assistant.message","data":{"messageId":"m1","content":"Hallo!"}}"#)
        guard case .text(let text)? = events.first else {
            Issue.record("expected text, got \(events)")
            return
        }
        #expect(text == "Hallo!")
        #expect(stream.parse(#"{"type":"assistant.message","data":{"messageId":"m2","content":""}}"#).isEmpty)
        #expect(stream.parse(#"{"type":"assistant.message_delta","data":{"deltaContent":"Ha"}}"#).isEmpty)
    }

    @Test func aFileViewBecomesAReadCallAndItsResult() throws {
        let stream = CopilotStream()
        let started = stream.parse("""
        {"type":"tool.execution_start","data":{"toolCallId":"t1","toolName":"view",\
        "arguments":{"path":"/repo/README.md"}}}
        """)
        guard case .toolUse(let tool)? = started.first else {
            Issue.record("expected a tool call, got \(started)")
            return
        }
        #expect(tool.id == "t1")
        #expect(tool.name == "Read")
        let input = try #require(try JSONSerialization.jsonObject(with: Data(tool.input.utf8)) as? [String: Any])
        #expect(input["file_path"] as? String == "/repo/README.md")

        let completed = stream.parse("""
        {"type":"tool.execution_complete","data":{"toolCallId":"t1","success":true,\
        "result":{"content":"# Hello"}}}
        """)
        guard case .toolResult(let id, let output, let isError, _)? = completed.first else {
            Issue.record("expected a tool result, got \(completed)")
            return
        }
        #expect(id == "t1")
        #expect(output == "# Hello")
        #expect(!isError)
    }

    @Test func anEditCarriesItsChangeUnderTheAppsNames() throws {
        let stream = CopilotStream()
        let events = stream.parse("""
        {"type":"tool.execution_start","data":{"toolCallId":"t2","toolName":"edit",\
        "arguments":{"path":"/repo/a.swift","old_str":"let a = 1","new_str":"let a = 2"}}}
        """)
        guard case .toolUse(let tool)? = events.first else {
            Issue.record("expected a tool call, got \(events)")
            return
        }
        #expect(tool.name == "Edit")
        #expect(tool.describesOwnChange)
    }

    @Test func aFailedCommandIsAnErrorWithItsMessage() {
        let stream = CopilotStream()
        _ = stream.parse("""
        {"type":"tool.execution_start","data":{"toolCallId":"t3","toolName":"bash",\
        "arguments":{"command":"false"}}}
        """)
        let events = stream.parse("""
        {"type":"tool.execution_complete","data":{"toolCallId":"t3","success":false,\
        "error":{"message":"exit 1"}}}
        """)
        guard case .toolResult(_, let output, let isError, _)? = events.first else {
            Issue.record("expected a tool result, got \(events)")
            return
        }
        #expect(isError)
        #expect(output == "exit 1")
    }

    @Test func bookkeepingToolsAreNotWorthARow() {
        let stream = CopilotStream()
        #expect(stream.parse("""
        {"type":"tool.execution_start","data":{"toolCallId":"t4","toolName":"report_intent",\
        "arguments":{"intent":"Reading"}}}
        """).isEmpty)
        #expect(stream.parse("""
        {"type":"tool.execution_complete","data":{"toolCallId":"t4","success":true}}
        """).isEmpty)
    }

    @Test func anMCPCallIsNamedAfterItsServer() {
        let stream = CopilotStream()
        let events = stream.parse("""
        {"type":"tool.execution_start","data":{"toolCallId":"t5","toolName":"github-mcp-server-list_issues",\
        "mcpServerName":"github-mcp-server","mcpToolName":"list_issues","arguments":{}}}
        """)
        guard case .toolUse(let tool)? = events.first else {
            Issue.record("expected a tool call, got \(events)")
            return
        }
        #expect(tool.name == "MCP")
        #expect(tool.input == "github-mcp-server.list_issues")
    }

    @Test func anAgentsWordsStayWithTheCallThatStartedIt() {
        let stream = CopilotStream()
        let events = stream.parse("""
        {"type":"assistant.message","data":{"messageId":"m3","content":"Looking","parentToolCallId":"task-1"}}
        """)
        guard case .agentText(let parentID, let text)? = events.first else {
            Issue.record("expected agent text, got \(events)")
            return
        }
        #expect(parentID == "task-1")
        #expect(text == "Looking")
    }

    // Usage arrives once per model call, and the runner records every report as what
    // has grown since the one before, so each report carries the whole turn so far.
    @Test func usageAddsUpAcrossModelCallsAndMeasuresTheWindow() {
        let stream = CopilotStream()
        let first = stream.parse("""
        {"type":"assistant.usage","data":{"model":"claude-sonnet-5","inputTokens":100,"outputTokens":10,\
        "cacheReadTokens":50,"cacheWriteTokens":5,"maxPromptTokens":200000}}
        """)
        #expect(first.count == 2)
        guard case .usage(let usage)? = first.first, case .context(let tokens)? = first.last else {
            Issue.record("expected usage and context, got \(first)")
            return
        }
        #expect(usage.inputTokens == 100)
        #expect(usage.contextWindow == 200_000)
        #expect(usage.model == "claude-sonnet-5")
        #expect(tokens == 155)

        let second = stream.parse("""
        {"type":"assistant.usage","data":{"model":"claude-sonnet-5","inputTokens":200,"outputTokens":20,\
        "cacheReadTokens":0,"cacheWriteTokens":0}}
        """)
        guard case .usage(let total)? = second.first, case .context(let latest)? = second.last else {
            Issue.record("expected usage and context, got \(second)")
            return
        }
        #expect(total.inputTokens == 300)
        #expect(total.outputTokens == 30)
        #expect(total.contextWindow == 200_000)
        #expect(latest == 200)

        // A subagent's call is spend but not the conversation's window.
        let agent = stream.parse("""
        {"type":"assistant.usage","data":{"model":"claude-sonnet-5","inputTokens":1000,"outputTokens":1,\
        "parentToolCallId":"task-1","initiator":"sub-agent"}}
        """)
        #expect(agent.count == 1)
        guard case .usage(let withAgent)? = agent.first else {
            Issue.record("expected usage, got \(agent)")
            return
        }
        #expect(withAgent.inputTokens == 1300)
    }

    @Test func reasoningIsThinkingAndIsNotSaidTwice() {
        let stream = CopilotStream()
        let events = stream.parse(#"{"type":"assistant.reasoning","data":{"reasoningId":"r1","content":"Hmm"}}"#)
        guard case .thinking(let text)? = events.first else {
            Issue.record("expected thinking, got \(events)")
            return
        }
        #expect(text == "Hmm")
        let message = stream.parse(#"{"type":"assistant.message","data":{"messageId":"m4","content":"Done","reasoningText":"Hmm"}}"#)
        #expect(message.count == 1)

        let quiet = CopilotStream()
        let only = quiet.parse(#"{"type":"assistant.message","data":{"messageId":"m5","content":"Done","reasoningText":"Thought"}}"#)
        guard case .thinking(let thought)? = only.first else {
            Issue.record("expected thinking from the message, got \(only)")
            return
        }
        #expect(thought == "Thought")
    }

    @Test func aCompactionReportsItsSizes() {
        let stream = CopilotStream()
        let events = stream.parse("""
        {"type":"session.compaction_complete","data":{"success":true,"preCompactionTokens":90000,"postCompactionTokens":12000}}
        """)
        guard case .compacted(let pre, let post)? = events.first else {
            Issue.record("expected compacted, got \(events)")
            return
        }
        #expect(pre == 90_000)
        #expect(post == 12_000)
    }

    @Test func theLastLineEndsTheTurnAndCarriesTheSessionID() {
        let stream = CopilotStream()
        let events = stream.parse("""
        {"type":"result","timestamp":"2026-09-13T13:48:32.349Z","sessionId":"abc","exitCode":0,\
        "usage":{"premiumRequests":1}}
        """)
        #expect(events.count == 2)
        guard case .initialized(let id)? = events.first,
              case .finished(let isError, let message)? = events.last else {
            Issue.record("expected initialized and finished, got \(events)")
            return
        }
        #expect(id == "abc")
        #expect(!isError)
        #expect(message == nil)
    }

    @Test func anErrorIsReportedWhenTheRunEndsBadly() {
        let stream = CopilotStream()
        #expect(stream.parse("""
        {"type":"session.error","data":{"errorType":"quota","message":"You have exceeded your monthly quota"}}
        """).isEmpty)
        let events = stream.parse(#"{"type":"result","sessionId":"abc","exitCode":1}"#)
        guard case .finished(let isError, let message)? = events.last else {
            Issue.record("expected finished, got \(events)")
            return
        }
        #expect(isError)
        #expect(message == "You have exceeded your monthly quota")
    }

    @Test func noiseIsDropped() {
        let stream = CopilotStream()
        #expect(stream.parse(#"{"type":"session.mcp_server_status_changed","data":{"status":"pending"}}"#).isEmpty)
        #expect(stream.parse(#"{"type":"user.message","data":{"content":"hi"}}"#).isEmpty)
        #expect(stream.parse("not json").isEmpty)
    }

    // MARK: - Runner

    @MainActor @Test func aCopilotTurnRunsToTheLastLine() async throws {
        let fixture = try RunnerHarness(agent: .copilot, script: """
        printf '%s\\n' "$@" > "$folder/arguments.txt"
        input=$(cat)
        printf '%s' "$input" > "$folder/stdin.txt"
        sid=""
        prev=""
        for a in "$@"; do
            if [ "$prev" = "--session-id" ]; then sid="$a"; fi
            prev="$a"
        done
        printf '%s\\n' '{"type":"assistant.message","data":{"messageId":"m1","content":"Done"}}'
        printf '%s\\n' '{"type":"assistant.usage","data":{"model":"claude-sonnet-5","inputTokens":10,"outputTokens":2,"maxPromptTokens":1000}}'
        printf '%s\\n' '{"type":"result","sessionId":"'"$sid"'","exitCode":0}'
        """)
        defer { fixture.tearDown() }

        fixture.runner.send("say done", sessionID: fixture.session.id, store: fixture.store)

        #expect(await waitUntil { fixture.runner.state(fixture.session.id) == .idle })
        #expect(fixture.store.transcript(of: fixture.session.id).last?.text == "Done")
        let arguments = try String(contentsOf: fixture.scratch.path("arguments.txt"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(arguments.first == "-p")
        #expect(arguments.contains { $0.hasSuffix("say done") })
        // The prompt went over as an argument, and stdin was shut before the CLI read it.
        #expect(try String(contentsOf: fixture.scratch.path("stdin.txt"), encoding: .utf8).isEmpty)
        // The id the CLI was told to use is the one the session resumes with.
        let session = try #require(fixture.store.session(fixture.session.id))
        let index = try #require(arguments.firstIndex(of: "--session-id"))
        #expect(session.copilotSessionID == arguments[index + 1])
        #expect(session.usage?.contextWindow == 1000)
        #expect(session.usage?.contextTokens == 10)
    }

    @MainActor @Test func aLostCopilotSessionIsStartedAgainWithoutResuming() async throws {
        let fixture = try RunnerHarness(agent: .copilot, script: """
        count_file="$folder/count"
        count=0
        if [ -f "$count_file" ]; then count=$(cat "$count_file"); fi
        count=$((count + 1))
        printf '%s' "$count" > "$count_file"
        printf '%s\\n' "$@" > "$folder/arguments-$count.txt"
        if [ "$count" -eq 1 ]; then
            printf '%s\\n' "Error: No session, task, or name matched 'stale'." >&2
            exit 1
        fi
        printf '%s\\n' '{"type":"assistant.message","data":{"messageId":"m1","content":"Fresh start"}}'
        printf '%s\\n' '{"type":"result","sessionId":"fresh","exitCode":0}'
        """)
        defer { fixture.tearDown() }
        fixture.store.setAgentSessionID("stale", agent: .copilot, for: fixture.session.id)

        fixture.runner.send("carry on", sessionID: fixture.session.id, store: fixture.store)

        #expect(await waitUntil { fixture.runner.state(fixture.session.id) == .idle })
        let first = try String(contentsOf: fixture.scratch.path("arguments-1.txt"), encoding: .utf8)
        #expect(first.contains("--resume"))
        let second = try String(contentsOf: fixture.scratch.path("arguments-2.txt"), encoding: .utf8)
        #expect(!second.contains("--resume"))
        #expect(second.contains("--session-id"))
        #expect(fixture.store.transcript(of: fixture.session.id).last?.text == "Fresh start")
        #expect(fixture.store.transcript(of: fixture.session.id)
            .contains { $0.role == .system && $0.text.contains("could not be resumed") })
    }

    @MainActor @Test func aRunThatEndsWithoutItsLastLineFails() async throws {
        let fixture = try RunnerHarness(agent: .copilot, script: """
        printf '%s\\n' '{"type":"assistant.message","data":{"messageId":"m1","content":"Half"}}'
        """)
        defer { fixture.tearDown() }

        fixture.runner.send("go", sessionID: fixture.session.id, store: fixture.store)

        #expect(await waitUntil { !fixture.runner.state(fixture.session.id).isBusy })
        guard case .failed(let message) = fixture.runner.state(fixture.session.id) else {
            Issue.record("expected the turn to fail")
            return
        }
        #expect(message == "Copilot ended before completing the turn.")
        // The id was saved when the process started, so the next turn still resumes
        // whatever the CLI managed to write down.
        #expect(fixture.store.session(fixture.session.id)?.copilotSessionID != nil)
    }
}
