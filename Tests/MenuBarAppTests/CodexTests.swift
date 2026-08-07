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
                                                 url: nil))
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

    @Test func anEditArrivesAsAFinishedToolCall() {
        let events = StreamEvent.parseCodex("""
        {"type":"item.completed","item":{"id":"item_4","item_type":"file_change","status":"completed",\
        "changes":[{"path":"Sources/App.swift","kind":"update"},{"path":"README.md","kind":"add"}]}}
        """)
        #expect(events.count == 2)
        guard case .toolUse(let tool)? = events.first else {
            Issue.record("expected a tool call, got \(events)")
            return
        }
        #expect(tool.name == "Edit")
        #expect(tool.input == "update Sources/App.swift\nadd README.md")
        if case .toolResult(let id, _, let isError)? = events.last {
            #expect(id == "item_4")
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

    @Test func reasoningAndUnknownItemsAreDropped() {
        let reasoning = StreamEvent.parseCodex("""
        {"type":"item.completed","item":{"id":"item_5","item_type":"reasoning","text":"thinking"}}
        """)
        #expect(reasoning.isEmpty)
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
        let payload = try JSONSerialization.data(withJSONObject: claims)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
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
