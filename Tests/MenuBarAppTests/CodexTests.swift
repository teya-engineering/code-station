import Foundation
import Testing
@testable import MenuBarApp

// Running a session on Codex: the arguments its CLI takes, its JSONL stream folded onto
// the app's events, and its sign-in file read back into account details.
struct CodexTests {

    // MARK: - MCP registration

    @Test func codexRegistersAStdioMCPServerWithItsEnvironment() {
        let server = Server(name: "grafana-platform-dev", command: "mcp-grafana", args: ["--debug"],
                            url: nil, type: nil,
                            env: [EnvVar(key: "GRAFANA_URL", value: "https://grafana.example")],
                            headers: [], disabled: false)

        #expect(CodexCodeManager.addArguments(for: server, executable: "/opt/homebrew/bin/mcp-grafana") == [
            "mcp", "add", "grafana-platform-dev", "--env", "GRAFANA_URL=https://grafana.example",
            "--", "/opt/homebrew/bin/mcp-grafana", "--debug",
        ])
    }

    @Test func codexRegistersStreamableHTTPServersWithoutHeaders() {
        let server = Server(name: "remote", command: nil, args: [], url: "https://mcp.example/mcp",
                            type: "http", env: [], headers: [], disabled: false)

        #expect(CodexCodeManager.addArguments(for: server, executable: nil) == [
            "mcp", "add", "remote", "--url", "https://mcp.example/mcp",
        ])
    }

    @Test func codexDoesNotPretendToSupportSSEOrCustomHeaders() {
        let sse = Server(name: "sse", command: nil, args: [], url: "https://mcp.example/sse",
                         type: "sse", env: [], headers: [], disabled: false)
        let headers = Server(name: "headers", command: nil, args: [], url: "https://mcp.example/mcp",
                             type: "http", env: [],
                             headers: [EnvVar(key: "X-API-Key", value: "secret")], disabled: false)

        #expect(CodexCodeManager.addArguments(for: sse, executable: nil) == nil)
        #expect(CodexCodeManager.addArguments(for: headers, executable: nil) == nil)
    }

    @MainActor @Test func codexReadsTheTransportReturnedByItsCLI() {
        let entry = CodexCodeManager.Entry(json: """
        {
          "name": "grafana-platform-dev",
          "enabled": true,
          "transport": {
            "type": "stdio",
            "command": "/opt/homebrew/bin/mcp-grafana",
            "args": ["--debug"],
            "env": { "GRAFANA_URL": "https://grafana.example" }
          }
        }
        """)

        #expect(entry == CodexCodeManager.Entry(command: "/opt/homebrew/bin/mcp-grafana",
                                                 args: ["--debug"],
                                                 env: ["GRAFANA_URL": "https://grafana.example"],
                                                 url: nil,
                                                 enabled: true))
    }

    @Test func parsesDisabledServerState() throws {
        let entry = try #require(CodexCodeManager.Entry(json: """
            {
              "name": "grafana-platform-dev",
              "enabled": false,
              "transport": {
                "type": "stdio",
                "command": "mcp-grafana"
              }
            }
            """))

        #expect(!entry.enabled)
    }

    @Test func readsRemoteTransportForDiscovery() throws {
        let entry = try #require(CodexCodeManager.Entry(json: """
            {
              "name": "remote",
              "enabled": true,
              "transport": {
                "type": "streamable_http",
                "url": "https://mcp.example/api"
              }
            }
            """))

        #expect(entry.url == "https://mcp.example/api")
        #expect(entry.type == "streamable_http")
    }

    @Test func readsEveryServerNameFromTheCodexInventory() throws {
        let data = Data("""
            [
              { "name": "zeta", "enabled": false },
              { "name": "alpha", "enabled": true }
            ]
            """.utf8)

        #expect(CodexCodeManager.serverNames(in: data) == ["alpha", "zeta"])
        #expect(CodexCodeManager.serverNames(in: Data("{}".utf8)) == nil)
    }

    // MARK: - Arguments

    @Test func codexRunsExecWithASandboxAndStdinPrompt() {
        let arguments = SessionRunner.arguments(agent: .codex,
                                                settings: SessionSettings(),
                                                defaults: SessionSettings())
        #expect(arguments.first == "exec")
        #expect(arguments.contains("--json"))
        #expect(arguments.contains("sandbox_mode=\"workspace-write\""))
        // The prompt comes over stdin, asked for with "-" at the end.
        #expect(arguments.last == "-")
        #expect(!arguments.contains("resume"))
        // Claude Code's flags have no place here.
        #expect(!arguments.contains("--permission-mode"))
        #expect(!arguments.contains("--effort"))
    }

    @Test func codexFullAccessBypassesTheSandboxForNewAndResumedTurns() {
        let settings = SessionSettings(codexSandboxMode: CodexSandboxMode.fullAccess.rawValue)
        let arguments = SessionRunner.arguments(agent: .codex,
                                                settings: settings,
                                                defaults: SessionSettings(),
                                                writableRoots: ["/Users/jo/Code/app/.git"])
        #expect(arguments.contains("--dangerously-bypass-approvals-and-sandbox"))
        #expect(!arguments.contains { $0.hasPrefix("sandbox_mode") })
        #expect(!arguments.contains { $0.hasPrefix("sandbox_workspace_write") })

        let resumed = SessionRunner.arguments(agent: .codex,
                                              settings: settings,
                                              defaults: SessionSettings(),
                                              resume: "thread-1")
        #expect(resumed.contains("--dangerously-bypass-approvals-and-sandbox"))
    }

    @Test func codexApproveForMeKeepsTheSandboxForNewAndResumedTurns() {
        let settings = SessionSettings(codexSandboxMode: CodexSandboxMode.approveForMe.rawValue)
        let arguments = SessionRunner.arguments(agent: .codex,
                                                settings: settings,
                                                defaults: SessionSettings(),
                                                writableRoots: ["/Users/jo/Code/app/.git"])
        #expect(arguments.contains("sandbox_mode=\"workspace-write\""))
        #expect(arguments.contains("sandbox_workspace_write.writable_roots=[\"/Users/jo/Code/app/.git\"]"))
        #expect(arguments.contains("--approve-for-me"))
        #expect(!arguments.contains("--dangerously-bypass-approvals-and-sandbox"))

        let resumed = SessionRunner.arguments(agent: .codex,
                                              settings: settings,
                                              defaults: SessionSettings(),
                                              resume: "thread-1")
        #expect(!resumed.contains("--approve-for-me"))
        #expect(resumed.contains("approval_policy=\"on-failure\""))
        #expect(resumed.contains("approvals_reviewer=\"auto_review\""))
        #expect(!resumed.contains("--dangerously-bypass-approvals-and-sandbox"))
    }

    // A worktree's git metadata lives in the main checkout's .git directory, so a
    // worktree session has to open that directory up or git cannot write anything.
    @Test func aWorktreeSessionOpensTheSharedGitDirectory() {
        let arguments = SessionRunner.arguments(agent: .codex,
                                                settings: SessionSettings(),
                                                defaults: SessionSettings(),
                                                writableRoots: ["/Users/jo/Code/app/.git"])
        #expect(arguments.contains("sandbox_workspace_write.writable_roots=[\"/Users/jo/Code/app/.git\"]"))

        let withoutRoots = SessionRunner.arguments(agent: .codex,
                                                   settings: SessionSettings(),
                                                   defaults: SessionSettings())
        #expect(!withoutRoots.contains { $0.hasPrefix("sandbox_workspace_write") })
    }

    @Test func codexAddsWorkspaceRootsOnANewTurnAndKeepsThemWritableOnResume() {
        let root = "/Users/jo/Code/web"
        let writable = [root, "/Users/jo/Code/api/.git"]
        let initial = SessionRunner.arguments(agent: .codex,
                                              settings: SessionSettings(),
                                              defaults: SessionSettings(),
                                              addDirectories: [root],
                                              writableRoots: writable)

        #expect(pair(initial, after: "--add-dir") == root)
        #expect(initial.contains(
            "sandbox_workspace_write.writable_roots=[\"/Users/jo/Code/web\",\"/Users/jo/Code/api/.git\"]"))

        let resumed = SessionRunner.arguments(agent: .codex,
                                              settings: SessionSettings(),
                                              defaults: SessionSettings(),
                                              addDirectories: [root],
                                              writableRoots: writable,
                                              resume: "thread-1")
        #expect(!resumed.contains("--add-dir"))
        #expect(resumed.contains(
            "sandbox_workspace_write.writable_roots=[\"/Users/jo/Code/web\",\"/Users/jo/Code/api/.git\"]"))
    }

    @Test func codexResumesAThreadThroughTheSubcommand() {
        let arguments = SessionRunner.arguments(agent: .codex,
                                                settings: SessionSettings(),
                                                defaults: SessionSettings(),
                                                resume: "thread-1")
        // Resume is a subcommand, so it has to come straight after exec.
        #expect(Array(arguments.prefix(3)) == ["exec", "resume", "thread-1"])
        // Resume takes no "--sandbox" flag, only the config override.
        #expect(!arguments.contains("--sandbox"))
        #expect(arguments.contains("sandbox_mode=\"workspace-write\""))
    }

    // Without this override the stream carries no reasoning items at all, and the
    // transcript would never have thinking to show for a Codex turn.
    @Test func codexIsAskedForItsReasoningSummaries() {
        let arguments = SessionRunner.arguments(agent: .codex,
                                                settings: SessionSettings(),
                                                defaults: SessionSettings())
        #expect(arguments.contains("model_reasoning_summary=\"detailed\""))

        let resumed = SessionRunner.arguments(agent: .codex,
                                              settings: SessionSettings(),
                                              defaults: SessionSettings(),
                                              resume: "thread-1")
        #expect(resumed.contains("model_reasoning_summary=\"detailed\""))
    }

    @Test func codexTakesItsOwnModelAndEffort() {
        let settings = SessionSettings(model: "gpt-5.6-terra", effort: "high")
        let arguments = SessionRunner.arguments(agent: .codex,
                                                settings: settings,
                                                defaults: SessionSettings())
        #expect(pair(arguments, after: "--model") == "gpt-5.6-terra")
        // The sandbox is the first "-c", so the effort override is matched anywhere.
        #expect(arguments.contains("model_reasoning_effort=\"high\""))
    }

    // A model picked while the other agent was active would only be refused, so it is
    // left off entirely and the agent's own default decides.
    @Test func aForeignModelReadsAsUnchosen() {
        let claudeChoice = SessionSettings(model: "opus")
        let codexArguments = SessionRunner.arguments(agent: .codex,
                                                     settings: claudeChoice,
                                                     defaults: SessionSettings())
        #expect(!codexArguments.contains("--model"))

        let codexChoice = SessionSettings(model: "gpt-5.6-terra")
        let claudeArguments = SessionRunner.arguments(agent: .claudeCode,
                                                      settings: codexChoice,
                                                      defaults: SessionSettings())
        #expect(!claudeArguments.contains("--model"))
    }

    private func pair(_ arguments: [String], after flag: String) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    // MARK: - Reading the stream

    @Test func aStartedThreadCarriesTheResumeID() {
        let events = StreamEvent.parseCodex(#"{"type":"thread.started","thread_id":"t-9"}"#)
        guard case .initialized(let id)? = events.first else {
            Issue.record("expected initialized, got \(events)")
            return
        }
        #expect(id == "t-9")
    }

    @Test func aCommandBecomesAToolCallAndItsResult() throws {
        let started = StreamEvent.parseCodex("""
        {"type":"item.started","item":{"id":"item_1","item_type":"command_execution",\
        "command":"ls -la","status":"in_progress"}}
        """)
        guard case .toolUse(let tool)? = started.first else {
            Issue.record("expected a tool call, got \(started)")
            return
        }
        #expect(tool.id == "item_1")
        #expect(tool.name == "Bash")
        #expect(tool.input == "ls -la")

        let completed = StreamEvent.parseCodex("""
        {"type":"item.completed","item":{"id":"item_1","item_type":"command_execution",\
        "command":"ls -la","aggregated_output":"README.md","exit_code":0,"status":"completed"}}
        """)
        guard case .toolResult(let id, let output, let isError)? = completed.first else {
            Issue.record("expected a tool result, got \(completed)")
            return
        }
        #expect(id == "item_1")
        #expect(output == "README.md")
        #expect(!isError)
    }

    @Test func aFailingCommandIsAnError() {
        let events = StreamEvent.parseCodex("""
        {"type":"item.completed","item":{"id":"item_2","item_type":"command_execution",\
        "command":"false","aggregated_output":"","exit_code":1,"status":"failed"}}
        """)
        guard case .toolResult(_, _, let isError)? = events.first else {
            Issue.record("expected a tool result, got \(events)")
            return
        }
        #expect(isError)
    }

    // The completed message carries the whole text, so only it speaks; acting on the
    // started item as well would say everything twice.
    @Test func onlyTheCompletedMessageSpeaks() {
        let started = StreamEvent.parseCodex("""
        {"type":"item.started","item":{"id":"item_3","item_type":"agent_message","text":"Hal"}}
        """)
        #expect(started.isEmpty)

        let completed = StreamEvent.parseCodex("""
        {"type":"item.completed","item":{"id":"item_3","item_type":"agent_message","text":"Hallo!"}}
        """)
        guard case .text(let text)? = completed.first else {
            Issue.record("expected text, got \(completed)")
            return
        }
        #expect(text == "Hallo!")
    }

    @Test func eachEditedFileArrivesAsAFinishedToolCallOfItsOwn() throws {
        let events = StreamEvent.parseCodex("""
        {"type":"item.completed","item":{"id":"item_4","item_type":"file_change","status":"completed",\
        "changes":[{"path":"Sources/App.swift","kind":"update","diff":"@@ -1,2 +1,2 @@\\n-old\\n+new\\n"},\
        {"path":"README.md","kind":"add"}]}}
        """)
        #expect(events.count == 4)

        guard case .toolUse(let edit)? = events.first else {
            Issue.record("expected a tool call, got \(events)")
            return
        }
        #expect(edit.id == "item_4")
        #expect(edit.name == "Edit")
        let fields = try #require(try JSONSerialization.jsonObject(with: Data(edit.input.utf8))
            as? [String: String])
        #expect(fields["file_path"] == "Sources/App.swift")
        #expect(fields["diff"] == "@@ -1,2 +1,2 @@\n-old\n+new\n")

        // The item's own id belongs to the first call, so the rest need ids of their own.
        guard case .toolUse(let write)? = events.dropFirst(2).first else {
            Issue.record("expected a second tool call, got \(events)")
            return
        }
        #expect(write.id == "item_4#1")
        #expect(write.name == "Write")

        if case .toolResult(let id, _, let isError)? = events.last {
            #expect(id == "item_4#1")
            #expect(!isError)
        } else {
            Issue.record("expected the call to finish, got \(events)")
        }
    }

    @Test func aCompletedTurnReportsUsageAndEnds() {
        let events = StreamEvent.parseCodex("""
        {"type":"turn.completed","usage":{"input_tokens":1200,"cached_input_tokens":1000,"output_tokens":40}}
        """)
        #expect(events.count == 2)
        guard case .usage(let usage)? = events.first else {
            Issue.record("expected usage, got \(events)")
            return
        }
        // Codex counts cached tokens inside input_tokens; the app keeps them apart.
        #expect(usage.inputTokens == 200)
        #expect(usage.cacheReadTokens == 1000)
        #expect(usage.outputTokens == 40)
        if case .finished(let isError, _)? = events.last {
            #expect(!isError)
        } else {
            Issue.record("expected the turn to finish, got \(events)")
        }
    }

    @Test func readsTheLatestContextFromACodexRollout() async throws {
        let home = ScratchDirectory(prefix: "codex-context")
        let folder = home.path("sessions/2026/08/11")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let threadID = "019ff016-7f30-7330-a72a-eea8f3984538"
        let rollout = folder.appendingPathComponent("rollout-2026-08-11T10-10-34-\(threadID).jsonl")
        let contents = """
        {"type":"turn_context","payload":{"model":"gpt-5.6-terra"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":18000},"model_context_window":258400}}}
        not json
        {"type":"turn_context","payload":{"model":"gpt-5.6-sol"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20970,"total_tokens":21120},"model_context_window":258400}}}
        """
        try Data(contents.utf8).write(to: rollout)

        let reading = await CodexContextReader(codexHome: home.url).read(threadID: threadID)

        #expect(reading == .measured(CodexContextSnapshot(contextTokens: 21_120,
                                                          contextWindow: 258_400,
                                                          model: "gpt-5.6-sol")))
    }

    @Test func fallsBackToInputTokensFromOlderCodexRollouts() async throws {
        let home = ScratchDirectory(prefix: "codex-context")
        let folder = home.path("sessions")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let threadID = "019ff016-7f30-7330-a72a-eea8f3984539"
        let rollout = folder.appendingPathComponent("rollout-\(threadID).jsonl")
        let contents = """
        {"type":"turn_context","payload":{"model":"gpt-5.6-sol"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20970},"model_context_window":258400}}}
        """
        try Data(contents.utf8).write(to: rollout)

        let reading = await CodexContextReader(codexHome: home.url).read(threadID: threadID)

        #expect(reading == .measured(CodexContextSnapshot(contextTokens: 20_970,
                                                          contextWindow: 258_400,
                                                          model: "gpt-5.6-sol")))
    }

    @Test func readsCamelCaseContextFields() async throws {
        let home = ScratchDirectory(prefix: "codex-context")
        let folder = home.path("sessions")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let threadID = "019ff016-7f30-7330-a72a-eea8f3984540"
        let rollout = folder.appendingPathComponent("rollout-\(threadID).jsonl")
        let contents = """
        {"type":"turn_context","payload":{"model":"gpt-5.6-sol"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"lastTokenUsage":{"inputTokens":20970,"totalTokens":21120},"modelContextWindow":258400}}}
        """
        try Data(contents.utf8).write(to: rollout)

        let reading = await CodexContextReader(codexHome: home.url).read(threadID: threadID)

        #expect(reading == .measured(CodexContextSnapshot(contextTokens: 21_120,
                                                          contextWindow: 258_400,
                                                          model: "gpt-5.6-sol")))
    }

    @Test func retiresTheOldReadingWhenCodexCompacts() async throws {
        let home = ScratchDirectory(prefix: "codex-context")
        let folder = home.path("sessions")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let threadID = "019ff016-7f30-7330-a72a-eea8f3984541"
        let rollout = folder.appendingPathComponent("rollout-\(threadID).jsonl")
        let compacted = """
        {"type":"turn_context","payload":{"model":"gpt-5.6-sol"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":235845},"model_context_window":258400}}}
        {"type":"event_msg","payload":{"type":"context_compacted"}}
        """
        try Data(compacted.utf8).write(to: rollout)
        let reader = CodexContextReader(codexHome: home.url)

        #expect(await reader.read(threadID: threadID) == .compacted)

        let measured = compacted + """

        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":22422},"model_context_window":258400}}}
        """
        try Data(measured.utf8).write(to: rollout)

        #expect(await reader.read(threadID: threadID)
            == .measured(CodexContextSnapshot(contextTokens: 22_422,
                                               contextWindow: 258_400,
                                               model: "gpt-5.6-sol")))
    }

    @Test func codexHomeHonoursTheCLIEnvironment() {
        let configured = CodexContextReader.defaultHome(environment: [
            "CODEX_HOME": "/tmp/another-codex-home",
        ])
        #expect(configured.path == "/tmp/another-codex-home")
    }

    @Test func codexReadsCurrentAccountUsage() {
        let checkedAt = Date(timeIntervalSince1970: 1_786_202_880)
        let usage = CodexUsage(response: [
            "rateLimitsByLimitId": [
                "codex": [
                    "limitName": NSNull(),
                    "primary": [
                        "usedPercent": 6,
                        "resetsAt": 1_786_736_546,
                    ],
                    "secondary": [
                        "usedPercent": 40,
                        "resetsAt": 1_786_800_000,
                    ],
                ],
                "codex_spark": [
                    "limitName": "GPT-5.3-Codex-Spark",
                    "primary": ["usedPercent": 0],
                ],
            ],
        ], checkedAt: checkedAt)

        #expect(usage?.windows.map(\.title) == [
            "Current limit", "Current limit - secondary", "GPT-5.3-Codex-Spark",
        ])
        #expect(usage?.windows.map(\.usedPercent) == [6, 40, 0])
        #expect(usage?.windows.first?.resetsAt == Date(timeIntervalSince1970: 1_786_736_546))
        #expect(usage?.checkedAt == checkedAt)
    }

    @Test func aFailedTurnCarriesItsMessage() {
        let events = StreamEvent.parseCodex("""
        {"type":"turn.failed","error":{"message":"stream disconnected"}}
        """)
        #expect(events.count == 1)
        if case .finished(let isError, let message) = events[0] {
            #expect(isError)
            #expect(message == "stream disconnected")
        } else {
            Issue.record("expected a finished event, got \(events)")
        }
    }

    @Test func aConnectionErrorDoesNotFinishTheTurn() {
        let events = StreamEvent.parseCodex("""
        {"type":"error","message":"Reconnecting... 2/5"}
        """)
        #expect(events.count == 1)
        if case .streamError(let message) = events[0] {
            #expect(message == "Reconnecting... 2/5")
        } else {
            Issue.record("expected a stream error, got \(events)")
        }
    }

    @MainActor @Test func aReconnectThatCompletesIsSuccessful() async throws {
        let fixture = try RunnerHarness(agent: .codex, script: """
        input=$(cat)
        printf '%s\n' '{"type":"thread.started","thread_id":"thread-1"}'
        printf '%s\n' '{"type":"error","message":"Reconnecting... 1/5"}'
        printf '%s\n' '{"type":"error","message":"Reconnecting... 2/5"}'
        wait_for "$folder/finish"
        printf '%s\n' '{"type":"item.completed","item":{"id":"answer","item_type":"agent_message","text":"Done"}}'
        printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}'
        """)
        defer { fixture.tearDown() }

        fixture.runner.send("finish the work", sessionID: fixture.session.id, store: fixture.store)

        let sawReconnect = await waitUntil {
            if case .reconnecting = fixture.runner.state(fixture.session.id) { return true }
            return false
        }
        try Data().write(to: fixture.scratch.path("finish"))
        #expect(sawReconnect)
        #expect(await waitUntil { fixture.runner.state(fixture.session.id) == .idle })
        #expect(fixture.store.transcript(of: fixture.session.id).last?.text == "Done")
    }

    @MainActor @Test func aDisconnectedStreamWithoutCompletionFails() async throws {
        let fixture = try RunnerHarness(agent: .codex, script: """
        input=$(cat)
        printf '%s\n' '{"type":"thread.started","thread_id":"thread-1"}'
        printf '%s\n' '{"type":"error","message":"Reconnecting... 5/5"}'
        """)
        defer { fixture.tearDown() }

        fixture.runner.send("finish the work", sessionID: fixture.session.id, store: fixture.store)

        #expect(await waitUntil { !fixture.runner.state(fixture.session.id).isBusy })
        guard case .failed(let message) = fixture.runner.state(fixture.session.id) else {
            Issue.record("expected the turn to fail")
            return
        }
        #expect(message == "Reconnecting... 5/5")
        fixture.runner.dismissFailure(fixture.session.id)
        #expect(fixture.runner.state(fixture.session.id) == .idle)
    }

    @MainActor @Test func continueResumesWithoutReplayingTheOriginalPrompt() async throws {
        let fixture = try RunnerHarness(agent: .codex, script: """
        input=$(cat)
        count_file="$folder/count"
        count=0
        if [ -f "$count_file" ]; then count=$(cat "$count_file"); fi
        count=$((count + 1))
        printf '%s' "$count" > "$count_file"
        printf '%s' "$input" > "$folder/prompt-$count.txt"
        printf '%s\n' "$@" > "$folder/arguments-$count.txt"
        printf '%s\n' '{"type":"thread.started","thread_id":"thread-1"}'
        if [ "$count" -eq 1 ]; then
            printf '%s\n' '{"type":"turn.failed","error":{"message":"connection failed"}}'
            exit 1
        fi
        printf '%s\n' '{"type":"item.completed","item":{"id":"answer","item_type":"agent_message","text":"Recovered"}}'
        printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}'
        """)
        defer { fixture.tearDown() }

        let originalPrompt = "change the production setting"
        fixture.runner.send(originalPrompt, sessionID: fixture.session.id, store: fixture.store)
        #expect(await waitUntil {
            if case .failed = fixture.runner.state(fixture.session.id) { return true }
            return false
        })

        #expect(fixture.runner.continueAfterFailure(fixture.session.id, store: fixture.store))
        #expect(await waitUntil { fixture.runner.state(fixture.session.id) == .idle })

        let recoveryPrompt = try String(contentsOf: fixture.scratch.path("prompt-2.txt"), encoding: .utf8)
        let recoveryArguments = try String(contentsOf: fixture.scratch.path("arguments-2.txt"), encoding: .utf8)
        #expect(recoveryPrompt == SessionRunner.recoveryPrompt)
        #expect(recoveryPrompt != originalPrompt)
        #expect(recoveryArguments.contains("resume\nthread-1"))
        #expect(fixture.store.transcript(of: fixture.session.id)
            .filter { $0.role == .user }.map(\.text) == [originalPrompt])
    }

    // A stopped turn ends mid-work with nothing wrong, so the transcript has to say so
    // itself: an idle session under a conversation that stops mid-command reads as a crash.
    @MainActor @Test func aTurnStoppedByHandSaysSoAndCanBeCarriedOn() async throws {
        let fixture = try RunnerHarness(agent: .codex, script: """
        input=$(cat)
        count_file="$folder/count"
        count=0
        if [ -f "$count_file" ]; then count=$(cat "$count_file"); fi
        count=$((count + 1))
        printf '%s' "$count" > "$count_file"
        printf '%s' "$input" > "$folder/prompt-$count.txt"
        printf '%s\n' '{"type":"thread.started","thread_id":"thread-1"}'
        if [ "$count" -eq 1 ]; then
            printf '%s\n' '{"type":"item.started","item":{"id":"command-1","item_type":"command_execution","command":"sed -n 1,240p SKILL.md"}}'
            wait_for "$folder/never"
        fi
        printf '%s\n' '{"type":"item.completed","item":{"id":"answer","item_type":"agent_message","text":"Finished"}}'
        printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}'
        """)
        defer { fixture.tearDown() }

        fixture.runner.send("improve this menu", sessionID: fixture.session.id,
                            store: fixture.store)
        #expect(await waitUntil { fixture.runner.runningTool(fixture.session.id) != nil })

        fixture.runner.stop(fixture.session.id)
        #expect(await waitUntil { fixture.runner.state(fixture.session.id) == .idle })

        let stopped = try #require(fixture.store.transcript(of: fixture.session.id).last)
        #expect(stopped.role == .system)
        #expect(stopped.text == "Stopped. The turn ended before it finished.")
        #expect(fixture.runner.canContinueAfterStop(fixture.session.id, store: fixture.store))

        #expect(fixture.runner.continueAfterStop(fixture.session.id, store: fixture.store))
        #expect(await waitUntil { fixture.store.transcript(of: fixture.session.id).last?.text == "Finished" })

        // The offer goes with the turn it belonged to, and the original prompt is not run
        // a second time.
        #expect(!fixture.runner.canContinueAfterStop(fixture.session.id, store: fixture.store))
        let recoveryPrompt = try String(contentsOf: fixture.scratch.path("prompt-2.txt"), encoding: .utf8)
        #expect(recoveryPrompt == SessionRunner.recoveryPrompt)
        #expect(fixture.store.transcript(of: fixture.session.id)
            .filter { $0.role == .user }.map(\.text) == ["improve this menu"])
    }

    @MainActor @Test func aSilentTurnCanBeRetriedWithoutReplayingItsPrompt() async throws {
        let fixture = try RunnerHarness(agent: .codex, script: """
        input=$(cat)
        count_file="$folder/count"
        count=0
        if [ -f "$count_file" ]; then count=$(cat "$count_file"); fi
        count=$((count + 1))
        printf '%s' "$count" > "$count_file"
        printf '%s' "$input" > "$folder/prompt-$count.txt"
        printf '%s\n' "$@" > "$folder/arguments-$count.txt"
        printf '%s\n' '{"type":"thread.started","thread_id":"thread-1"}'
        if [ "$count" -eq 1 ]; then
            wait_for "$folder/stall-forever"
        fi
        printf '%s\n' '{"type":"item.completed","item":{"id":"answer","item_type":"agent_message","text":"Recovered"}}'
        printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}'
        """, stalledAfter: 0.08, stallCheckInterval: .milliseconds(10))
        defer { fixture.tearDown() }

        let originalPrompt = "change the production setting"
        fixture.runner.send(originalPrompt, sessionID: fixture.session.id, store: fixture.store)

        #expect(await waitUntil {
            fixture.runner.state(fixture.session.id) == .stalled
                && fixture.runner.canRetryStalled(fixture.session.id, store: fixture.store)
        })
        #expect(fixture.runner.retryStalled(fixture.session.id, store: fixture.store))
        #expect(await waitUntil { fixture.runner.state(fixture.session.id) == .idle })

        let recoveryPrompt = try String(contentsOf: fixture.scratch.path("prompt-2.txt"), encoding: .utf8)
        let recoveryArguments = try String(contentsOf: fixture.scratch.path("arguments-2.txt"), encoding: .utf8)
        #expect(recoveryPrompt == SessionRunner.recoveryPrompt)
        #expect(recoveryPrompt != originalPrompt)
        #expect(recoveryArguments.contains("resume\nthread-1"))
        #expect(fixture.store.transcript(of: fixture.session.id)
            .filter { $0.role == .user }.map(\.text) == [originalPrompt])
        #expect(fixture.store.transcript(of: fixture.session.id).last?.text == "Recovered")
    }

    @MainActor @Test func aSilentRunningCommandDoesNotMarkTheTurnAsStalled() async throws {
        let fixture = try RunnerHarness(agent: .codex, script: """
        input=$(cat)
        printf '%s\n' '{"type":"thread.started","thread_id":"thread-1"}'
        printf '%s\n' '{"type":"item.started","item":{"id":"command-1","item_type":"command_execution","command":"swift test"}}'
        wait_for "$folder/finish"
        printf '%s\n' '{"type":"item.completed","item":{"id":"command-1","item_type":"command_execution","command":"swift test","aggregated_output":"passed","exit_code":0,"status":"completed"}}'
        printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}'
        """, stalledAfter: 0.05, stallCheckInterval: .milliseconds(10))
        defer { fixture.tearDown() }

        fixture.runner.send("run the tests", sessionID: fixture.session.id, store: fixture.store)

        #expect(await waitUntil { fixture.runner.runningTool(fixture.session.id) != nil })
        try? await Task.sleep(for: .milliseconds(120))
        #expect(fixture.runner.state(fixture.session.id) != .stalled)
        try Data().write(to: fixture.scratch.path("finish"))
        #expect(await waitUntil { fixture.runner.state(fixture.session.id) == .idle })
    }

    // Codex says nothing about a file written by a command it ran, exactly as Claude Code
    // says nothing. Both streams meet in the same handler, and this is what shows that the
    // change is measured off the working tree for Codex too.
    //
    // The turn here ends the instant the command reports in, which is what a real turn does
    // when its last act is to write. The change is worked out after that, so this also
    // stands for every change that outlives the turn that made it.
    @MainActor @Test func seesWhatACodexCommandWroteThroughTheShell() async throws {
        let fixture = try RunnerHarness(agent: .codex, script: """
        input=$(cat)
        printf '%s\\n' '{"type":"thread.started","thread_id":"thread-1"}'
        printf '%s\\n' '{"type":"item.started","item":{"id":"command-1","item_type":"command_execution","command":"cat > notes.md"}}'
        wait_for "$folder/go"
        printf 'first\\nsecond\\n' > notes.md
        printf '%s\\n' '{"type":"item.completed","item":{"id":"command-1","item_type":"command_execution","command":"cat > notes.md","aggregated_output":"","exit_code":0,"status":"completed"}}'
        printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}'
        """)
        defer { fixture.tearDown() }
        try fixture.makeProjectARepository()

        fixture.runner.send("write the notes", sessionID: fixture.session.id, store: fixture.store)

        // Snapshots run in order on one queue, so waiting on one of our own is waiting for
        // the turn's baseline to have been taken. Only then is the fixture let write, which
        // is what a real agent's seconds of thinking does for free.
        await fixture.waitForBaseline()
        try Data().write(to: fixture.scratch.path("go"))

        #expect(await waitUntil { fixture.writtenChange != nil })
        let change = try #require(fixture.writtenChange)
        #expect(change.files == 1)
        #expect(change.added == 2)
        #expect(try #require(change.patch).contains("notes.md"))

        // And it reaches the row as a diff, which is the whole point of measuring it.
        let tool = try #require(fixture.store.transcript(of: fixture.session.id)
            .flatMap(\.tools).first { $0.name == "Bash" })
        let presentation = ToolPresentation(tool: tool, projectPath: "")
        #expect(presentation.changes.map(\.name) == ["notes.md"])
        #expect(presentation.changes[0].lines.map(\.text) == ["first", "second"])
    }

    @Test func aCompletedReasoningItemBecomesThinking() {
        let events = StreamEvent.parseCodex("""
        {"type":"item.completed","item":{"id":"item_5","item_type":"reasoning","text":"weighing options"}}
        """)
        guard case .thinking(let text)? = events.first else {
            Issue.record("expected a thinking event, got \(events)")
            return
        }
        #expect(text == "weighing options")
        // The completed item carries the whole text again, so the started one is noise.
        #expect(StreamEvent.parseCodex("""
        {"type":"item.started","item":{"id":"item_5","item_type":"reasoning","text":"weighing"}}
        """).isEmpty)
    }

    // Codex fans out onto threads of its own and sends the state of the whole team with
    // every collaboration call, which is the only place its agents are named.
    @Test func namesTheAgentsCodexHasRunning() {
        let events = StreamEvent.parseCodex("""
        {"type":"item.started","item":{"id":"item_7","item_type":"collab_tool_call","tool":"wait",\
        "agents_states":{"t2":{"agent_name":"search_west","agent_status":"running"},\
        "t1":{"agent_name":"search_east","agent_status":"running"}},"status":"in_progress"}}
        """)
        guard case .toolUse(let tool)? = events.first else {
            Issue.record("expected a tool call, got \(events)")
            return
        }
        #expect(tool.name == "Agent")
        #expect(ToolPresentation(tool: tool, projectPath: "").argument
                == "search_east, search_west · waiting")
    }

    @Test func namesTheAgentsASpawnIsSendingOut() {
        let events = StreamEvent.parseCodex("""
        {"type":"item.started","item":{"id":"item_8","item_type":"collab_tool_call",\
        "tool":"spawn_agent","receiver_agents":["counter"],"agents_states":{},"status":"in_progress"}}
        """)
        guard case .toolUse(let tool)? = events.first else {
            Issue.record("expected a tool call, got \(events)")
            return
        }
        #expect(ToolPresentation(tool: tool, projectPath: "").argument == "counter · spawned")
    }

    // Codex sends one of these on ordinary turns where nothing was spawned. A row for a
    // team of nobody would be on every Codex conversation in the app.
    @Test func dropsACollaborationCallWithNoAgentsBehindIt() {
        #expect(StreamEvent.parseCodex("""
        {"type":"item.started","item":{"id":"item_9","item_type":"collab_tool_call","tool":"wait",\
        "receiver_thread_ids":[],"prompt":null,"agents_states":{},"status":"in_progress"}}
        """).isEmpty)
    }

    // The call has to be able to finish whatever the team looked like by then, or the row
    // it opened would say "running" for the rest of the conversation.
    @Test func aFinishedCollaborationCallClosesItsRow() {
        let events = StreamEvent.parseCodex("""
        {"type":"item.completed","item":{"id":"item_7","item_type":"collab_tool_call",\
        "tool":"wait","agents_states":{},"status":"completed"}}
        """)
        guard case .toolResult(let id, _, let isError)? = events.first else {
            Issue.record("expected a tool result, got \(events)")
            return
        }
        #expect(id == "item_7")
        #expect(!isError)
    }

    @Test func unknownItemsAreDropped() {
        let todo = StreamEvent.parseCodex("""
        {"type":"item.completed","item":{"id":"item_6","item_type":"todo_list","items":[]}}
        """)
        #expect(todo.isEmpty)
        #expect(StreamEvent.parseCodex("not json at all").isEmpty)
        #expect(StreamEvent.parseCodex(#"{"type":"turn.started"}"#).isEmpty)
    }

    // MARK: - Choices per agent

    @Test func choicesBelongToTheirAgent() {
        #expect(ModelChoice.valid("opus", for: .claudeCode) == "opus")
        #expect(ModelChoice.valid("opus", for: .codex) == nil)
        #expect(ModelChoice.valid("gpt-5.6-terra", for: .codex) == "gpt-5.6-terra")
        #expect(ModelChoice.valid("gpt-5.6-terra", for: .claudeCode) == nil)
        #expect(ModelChoice.shortName(of: "gpt-5.6-terra") == "Terra")
        #expect(ModelChoice.valid("", for: .claudeCode) == nil)
        #expect(EffortChoice.valid("max", for: .codex) == "max")
        #expect(EffortChoice.valid("high", for: .codex) == "high")
        #expect(EffortChoice.valid("high", for: .claudeCode) == "high")
    }

    // MARK: - Reading the sign-in file

    @MainActor @Test func readsAChatGPTLoginOffTheAuthFile() throws {
        let claims: [String: Any] = [
            "email": "worldtiki@gmail.com",
            "https://api.openai.com/auth": ["chatgpt_plan_type": "plus"],
        ]
        let payload = try JSONSerialization.data(withJSONObject: claims).base64URLEncoded
        let account = CodexAgentInfo.account(from: [
            "tokens": ["id_token": "head.\(payload).signature"],
        ])
        #expect(account?.method == "ChatGPT login")
        #expect(account?.email == "worldtiki@gmail.com")
        #expect(account?.plan == "ChatGPT Plus")
    }

    @MainActor @Test func anAPIKeyCountsAsSignedInWithoutAnAccount() {
        let account = CodexAgentInfo.account(from: ["OPENAI_API_KEY": "sk-test"])
        #expect(account?.method == "API key")
        #expect(account?.email == nil)
        #expect(account?.plan == nil)
    }

    @MainActor @Test func anEmptyAuthFileReadsAsSignedOut() {
        #expect(CodexAgentInfo.account(from: [:]) == nil)
        #expect(CodexAgentInfo.account(from: ["OPENAI_API_KEY": ""]) == nil)
        // A token that is not a JWT falls back to the key, and failing that, to nothing.
        #expect(CodexAgentInfo.account(from: ["tokens": ["id_token": "garbage"]]) == nil)
    }
}

// What the Codex runner tests read off the harness that the other suites do not need.
private extension RunnerHarness {
    // Snapshots run in order on one queue, so waiting on one of our own is waiting for
    // the turn's baseline to have been taken.
    func waitForBaseline() async {
        let git = GitInspector.GitTool(path: "/usr/bin/git", searchPath: "/usr/bin:/bin")
        _ = await withCheckedContinuation { continuation in
            TreeSnapshots.shared.change(at: projectURL.path, using: git) {
                continuation.resume(returning: $0)
            }
        }
    }

    var writtenChange: WrittenChange? {
        store.transcript(of: session.id).flatMap(\.tools).compactMap(\.written).first
    }
}
