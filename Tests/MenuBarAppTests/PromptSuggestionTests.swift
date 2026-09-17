import Foundation
import Testing
@testable import MenuBarApp

struct PromptSuggestionTests {
    @Test func keepsSomethingAPersonWouldHaveTyped() {
        #expect(PromptSuggestion.cleaned("Add a test for the retry path.")
            == "Add a test for the retry path.")
        #expect(PromptSuggestion.cleaned("  <suggestion>Run the tests</suggestion>  ")
            == "Run the tests")
        #expect(PromptSuggestion.cleaned("Suggestion: Run the tests") == "Run the tests")
        #expect(PromptSuggestion.cleaned("\"Run the tests\"") == "Run the tests")
        #expect(PromptSuggestion.cleaned("Ship it \u{2014} carefully") == "Ship it - carefully")
    }

    @Test func dropsAnythingThatReadsLikeTheAgentTalking() {
        #expect(PromptSuggestion.cleaned(nil) == nil)
        #expect(PromptSuggestion.cleaned("   ") == nil)
        #expect(PromptSuggestion.cleaned("none") == nil)
        #expect(PromptSuggestion.cleaned("No suggestion, the task looks finished") == nil)
        #expect(PromptSuggestion.cleaned("Run the tests. Then open a pull request.") == nil)
        #expect(PromptSuggestion.cleaned("Run the **tests**") == nil)
        #expect(PromptSuggestion.cleaned("Run the tests\nThen review") == nil)
        #expect(PromptSuggestion.cleaned("Go") == nil)
        #expect(PromptSuggestion.cleaned(
            String(repeating: "word ", count: 25).trimmingCharacters(in: .whitespaces)) == nil)
    }

    @Test func readsTheClaudeCodeStreamEvent() {
        let events = StreamEvent.parse(
            #"{"type":"prompt_suggestion","suggestion":"Show me a POST example.","session_id":"s"}"#)
        guard case .promptSuggestion(let suggestion) = events.first else {
            Issue.record("expected a prompt suggestion, got \(events)")
            return
        }
        #expect(suggestion == "Show me a POST example.")
        #expect(StreamEvent.parse(#"{"type":"prompt_suggestion","suggestion":"none"}"#).isEmpty)
        #expect(StreamEvent.parse(#"{"type":"prompt_suggestion"}"#).isEmpty)
    }

    @Test func asksTheOtherCLIsWithoutTouchingTheirSandboxOrTools() {
        let codex = PromptSuggestion.arguments(for: .codex, prompt: "ask")
        #expect(codex.contains("--sandbox"))
        #expect(codex.contains("read-only"))
        #expect(codex.last == "ask")

        let copilot = PromptSuggestion.arguments(for: .copilot, prompt: "ask")
        #expect(copilot.contains("--no-ask-user"))
        #expect(copilot.contains("--disable-builtin-mcps"))
        #expect(copilot.contains("ask"))
    }

    @Test func keepsTheConversationTailWithinBounds() {
        let tail = PromptSuggestion.conversationTail(
            lastPrompt: String(repeating: "a", count: 5_000),
            lastReply: String(repeating: "b", count: 5_000))
        #expect(tail.contains("Return only the prompt."))
        #expect(!tail.contains(String(repeating: "a", count: 2_001)))
        #expect(!tail.contains(String(repeating: "b", count: 2_001)))
    }
}

@MainActor
struct PromptSuggestionRunnerTests {
    @Test func offersWhatClaudeCodePredictedAndPutsItInTheComposer() async throws {
        let harness = try RunnerHarness(agent: .claudeCode, script: Self.script(.claudeCode),
                                        promptSuggestionsEnabled: { true })
        defer { harness.tearDown() }
        harness.runner.send("Fix the login retry", sessionID: harness.session.id,
                            store: harness.store)
        #expect(await waitUntil { harness.runner.suggestion(harness.session.id) != nil })
        #expect(harness.runner.suggestion(harness.session.id) == "Add a regression test")

        // The CLI is only told to predict when the preference is on, and needs it said
        // in the environment as well as on the command line.
        let arguments = try Self.arguments(harness)
        #expect(arguments.contains("--prompt-suggestions"))

        harness.runner.takeSuggestion(harness.session.id)
        #expect(harness.runner.draft(harness.session.id).text == "Add a regression test")
        #expect(harness.runner.suggestion(harness.session.id) == nil)
        // It never becomes part of the conversation, however it is used.
        #expect(harness.store.transcript(of: harness.session.id).map(\.text)
            == ["Fix the login retry", "Work complete"])
    }

    @Test func staysQuietAndUnaskedWhenTheSettingIsOff() async throws {
        let harness = try RunnerHarness(agent: .claudeCode, script: Self.script(.claudeCode))
        defer { harness.tearDown() }
        harness.runner.send("Fix the login retry", sessionID: harness.session.id,
                            store: harness.store)
        #expect(await waitUntil { harness.runner.state(harness.session.id) == .idle })
        #expect(harness.runner.suggestion(harness.session.id) == nil)
        #expect(!(try Self.arguments(harness).contains("--prompt-suggestions")))
    }

    @Test(arguments: [AgentKind.codex, .copilot])
    func asksTheCLIsThatCannotPredictInARunOfTheirOwn(agent: AgentKind) async throws {
        let harness = try RunnerHarness(agent: agent, script: Self.script(agent),
                                        promptSuggestionsEnabled: { true })
        defer { harness.tearDown() }
        harness.runner.send("Fix the login retry", sessionID: harness.session.id,
                            store: harness.store)
        #expect(await waitUntil { harness.runner.suggestion(harness.session.id) != nil })
        #expect(harness.runner.suggestion(harness.session.id) == "Add a regression test")
        // The asking runs beside the session rather than inside it, so the conversation
        // is the turn and nothing else.
        #expect(harness.store.transcript(of: harness.session.id).map(\.text)
            == ["Fix the login retry", "Work complete"])
        #expect(try Self.starts(harness) == "work\nsuggest\n")
    }

    @Test func sendsTheSuggestionAsItsOwnTurnAndLeavesTheRestOfTheDraftAlone() async throws {
        let harness = try RunnerHarness(agent: .claudeCode, script: Self.script(.claudeCode),
                                        promptSuggestionsEnabled: { true })
        defer { harness.tearDown() }
        harness.runner.send("Fix the login retry", sessionID: harness.session.id,
                            store: harness.store)
        #expect(await waitUntil { harness.runner.suggestion(harness.session.id) != nil })

        // Nothing typed, but a file already waiting to go out with whatever is typed next.
        let file = harness.scratch.path("notes.txt")
        try "notes".write(to: file, atomically: true, encoding: .utf8)
        harness.runner.attach([Attachment(url: file)], to: harness.session.id)

        harness.runner.sendSuggestion(harness.session.id, store: harness.store)
        #expect(harness.runner.suggestion(harness.session.id) == nil)
        #expect(await waitUntil {
            harness.store.transcript(of: harness.session.id).last?.text == "Work complete"
                && harness.store.transcript(of: harness.session.id).count == 4
        })
        #expect(harness.store.transcript(of: harness.session.id).map(\.text)
            == ["Fix the login retry", "Work complete", "Add a regression test", "Work complete"])
        // The turn went out on its own, so the file is still waiting on the composer.
        #expect(harness.runner.draft(harness.session.id).attachments.map(\.url) == [file])
        #expect(harness.runner.draft(harness.session.id).text.isEmpty)
    }

    @Test func neverSendsOverSomethingAlreadyTyped() async throws {
        let harness = try RunnerHarness(agent: .claudeCode, script: Self.script(.claudeCode),
                                        promptSuggestionsEnabled: { true })
        defer { harness.tearDown() }
        harness.runner.send("Fix the login retry", sessionID: harness.session.id,
                            store: harness.store)
        #expect(await waitUntil { harness.runner.suggestion(harness.session.id) != nil })
        harness.runner.editDraft(harness.session.id) { $0.text = "also check the changelog" }

        harness.runner.sendSuggestion(harness.session.id, store: harness.store)
        #expect(harness.runner.draft(harness.session.id).text == "also check the changelog")
        #expect(harness.runner.suggestion(harness.session.id) == "Add a regression test")
        #expect(harness.store.transcript(of: harness.session.id).map(\.text)
            == ["Fix the login retry", "Work complete"])

        // The one thing it can do to a draft is join the end of it.
        harness.runner.takeSuggestion(harness.session.id)
        #expect(harness.runner.draft(harness.session.id).text
            == "also check the changelog Add a regression test")
        #expect(harness.runner.suggestion(harness.session.id) == nil)
    }

    @Test func forgetsThePredictionOnceTheSessionStartsWorkingAgain() async throws {
        let harness = try RunnerHarness(agent: .claudeCode, script: Self.script(.claudeCode),
                                        promptSuggestionsEnabled: { true })
        defer { harness.tearDown() }
        harness.runner.send("Fix the login retry", sessionID: harness.session.id,
                            store: harness.store)
        #expect(await waitUntil { harness.runner.suggestion(harness.session.id) != nil })
        harness.runner.send("Add a regression test", sessionID: harness.session.id,
                            store: harness.store)
        #expect(harness.runner.suggestion(harness.session.id) == nil)
    }

    private static func starts(_ harness: RunnerHarness) throws -> String {
        try String(contentsOf: harness.scratch.path("starts"), encoding: .utf8)
    }

    private static func arguments(_ harness: RunnerHarness) throws -> [String] {
        try String(contentsOf: harness.scratch.path("arguments"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    // A fake CLI that answers a turn, and answers the suggestion request the runner makes
    // of the agents that cannot predict one themselves.
    private static func script(_ agent: AgentKind) -> String {
        let read = switch agent {
        case .claudeCode: "IFS= read -r input"
        case .codex: "input=$(cat)"
        case .copilot: "input=\"$*\""
        }
        let turn = switch agent {
        case .claudeCode:
            """
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
            printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Work complete"}]}}'
            printf '%s\\n' '{"type":"result","is_error":false,"result":"Work complete"}'
            printf '%s\\n' '{"type":"prompt_suggestion","suggestion":"Add a regression test"}'
            """
        case .codex:
            """
            printf '%s\\n' '{"type":"thread.started","thread_id":"thread-1"}'
            printf '%s\\n' '{"type":"item.completed","item":{"id":"answer","item_type":"agent_message","text":"Work complete"}}'
            printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}'
            """
        case .copilot:
            """
            printf '%s\\n' '{"type":"assistant.message","data":{"messageId":"answer","content":"Work complete"}}'
            printf '%s\\n' '{"type":"result","sessionId":"copilot-1","exitCode":0}'
            """
        }
        let suggestion = switch agent {
        case .claudeCode:
            """
            printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Add a regression test"}]}}'
            printf '%s\\n' '{"type":"result","is_error":false,"result":"Add a regression test"}'
            """
        case .codex:
            """
            printf '%s\\n' '{"type":"thread.started","thread_id":"thread-2"}'
            printf '%s\\n' '{"type":"item.completed","item":{"id":"answer","item_type":"agent_message","text":"Add a regression test"}}'
            printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}'
            """
        case .copilot:
            """
            printf '%s\\n' '{"type":"assistant.message","data":{"messageId":"answer","content":"Add a regression test"}}'
            printf '%s\\n' '{"type":"result","sessionId":"copilot-1","exitCode":0}'
            """
        }
        // Every CLI is asked for a suggestion through its arguments, so the marker is
        // looked for there whatever the turn itself is given on stdin.
        return """
        case "$*" in
            *'Return only the prompt.'*)
                printf 'suggest\\n' >> "$folder/starts"
                \(suggestion)
                exit 0
                ;;
        esac
        printf '%s\\n' "$@" > "$folder/arguments"
        \(read)
        printf 'work\\n' >> "$folder/starts"
        \(turn)
        """
    }
}
