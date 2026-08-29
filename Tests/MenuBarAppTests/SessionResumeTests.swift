import Foundation
import Testing
@testable import MenuBarApp

struct SessionRecapTests {
    @Test func cleansARecapForPlainTextDisplay() {
        #expect(SessionRecap.cleaned("  ## Goal\n\nDone \u{2014} continue with tests.  ")
            == "Goal Done - continue with tests.")
    }

    @Test func rejectsClaudeCodeControlMessages() {
        #expect(SessionRecap.nativeText(from: "Couldn't generate a recap. Run with --debug.") == nil)
        #expect(SessionRecap.nativeText(from: "Nothing to recap yet - send a message first.") == nil)
        #expect(SessionRecap.nativeText(from: "Recap cancelled.") == nil)
    }

    @Test func acceptsAClaudeCodeRecap() {
        #expect(SessionRecap.nativeText(
            from: "The retry change is complete and tested. Review the diff next.")
            == "The retry change is complete and tested. Review the diff next.")
    }
}

@MainActor
struct SessionRecapStoreTests {
    private let store: ProjectStore
    private let scratch: ScratchDirectory
    private let project: Project

    init() throws {
        (store, scratch) = TestStore.make()
        project = try TestStore.project(in: store)
    }

    @Test func persistsTheLatestRecapOutsideTheTranscript() throws {
        let session = store.newSession(in: project.id)
        let recap = SessionRecap(text: "The work is complete.",
                                 generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                 source: .prompt)

        store.setRecap(recap, for: session.id)
        #expect(store.save())

        let reloaded = try #require(ProjectStore(storeURL: store.storeURL).session(session.id))
        #expect(reloaded.recap == recap)
        #expect(store.transcript(of: session.id).isEmpty)
    }

    @Test func markingTheSessionSeenDismissesItsRecap() {
        let session = store.newSession(in: project.id)
        store.setRecap(SessionRecap(text: "Ready to review.", generatedAt: Date(),
                                    source: .claudeCode), for: session.id)

        store.markSessionSeen(session.id)

        #expect(store.recap(for: session.id) == nil)
    }
}

@MainActor
struct SessionRecapRunnerTests {
    @Test func usesClaudeCodesNativeRecapWithoutAddingItToTheTranscript() async throws {
        let harness = try RunnerHarness(agent: .claudeCode, script: """
        IFS= read -r input
        count_file="$folder/count"
        count=0
        if [ -f "$count_file" ]; then count=$(cat "$count_file"); fi
        count=$((count + 1))
        printf '%s' "$count" > "$count_file"
        printf '%s' "$input" > "$folder/prompt-$count.txt"
        printf '%s\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
        if [ "$count" -eq 1 ]; then
            printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Initial response"}]}}'
            printf '%s\n' '{"type":"result","is_error":false,"result":"Initial response"}'
        else
            printf '%s\n' '{"type":"result","is_error":false,"result":"The retry change is complete and tested. Review the diff next."}'
        fi
        """)
        defer { harness.tearDown() }
        harness.store.selection = .session(harness.session.id)

        harness.runner.send("Improve retries", sessionID: harness.session.id,
                            store: harness.store)
        #expect(await waitUntil { harness.runner.state(harness.session.id) == .idle })
        #expect(harness.runner.recap(harness.session.id, store: harness.store))
        #expect(await waitUntil { harness.store.recap(for: harness.session.id) != nil })

        let recap = try #require(harness.store.recap(for: harness.session.id))
        #expect(recap.source == .claudeCode)
        #expect(recap.text == "The retry change is complete and tested. Review the diff next.")
        #expect(harness.store.transcript(of: harness.session.id).map(\.text)
            == ["Improve retries", "Initial response"])
        let command = try String(contentsOf: harness.scratch.path("prompt-2.txt"), encoding: .utf8)
        #expect(command.contains("/recap"))
    }

    @Test func fallsBackToAPromptWhenTheNativeRecapIsUnavailable() async throws {
        let harness = try RunnerHarness(agent: .claudeCode, script: """
        IFS= read -r input
        count_file="$folder/count"
        count=0
        if [ -f "$count_file" ]; then count=$(cat "$count_file"); fi
        count=$((count + 1))
        printf '%s' "$count" > "$count_file"
        printf '%s' "$input" > "$folder/prompt-$count.txt"
        printf '%s\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
        if [ "$count" -eq 1 ]; then
            printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Initial response"}]}}'
            printf '%s\n' '{"type":"result","is_error":false,"result":"Initial response"}'
        elif [ "$count" -eq 2 ]; then
            printf '%s\n' '{"type":"result","is_error":false,"result":"Could not generate a recap because it is disabled."}'
        else
            printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"The change is ready. Review it next."}]}}'
            printf '%s\n' '{"type":"result","is_error":false,"result":"The change is ready. Review it next."}'
        fi
        """)
        defer { harness.tearDown() }
        harness.store.selection = .session(harness.session.id)

        harness.runner.send("Make the change", sessionID: harness.session.id,
                            store: harness.store)
        #expect(await waitUntil { harness.runner.state(harness.session.id) == .idle })
        #expect(harness.runner.recap(harness.session.id, store: harness.store))
        #expect(await waitUntil { harness.store.recap(for: harness.session.id) != nil })

        #expect(harness.store.recap(for: harness.session.id)?.source == .prompt)
        let fallback = try String(contentsOf: harness.scratch.path("prompt-3.txt"), encoding: .utf8)
        #expect(fallback.contains("Write a recap of this conversation"))
    }

    @Test func automaticallyRecapsOnlyAnUnseenFinishedTurn() async throws {
        let harness = try RunnerHarness(agent: .codex, script: """
        input=$(cat)
        count_file="$folder/count"
        count=0
        if [ -f "$count_file" ]; then count=$(cat "$count_file"); fi
        count=$((count + 1))
        printf '%s' "$count" > "$count_file"
        printf '%s\n' '{"type":"thread.started","thread_id":"thread-1"}'
        if [ "$count" -eq 1 ]; then
            printf '%s\n' '{"type":"item.completed","item":{"id":"answer-1","item_type":"agent_message","text":"Work complete"}}'
        else
            printf '%s\n' '{"type":"item.completed","item":{"id":"answer-2","item_type":"agent_message","text":"The requested work is complete. Review the result next."}}'
        fi
        printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}'
        """, automaticRecapsEnabled: { true })
        defer { harness.tearDown() }
        let other = harness.store.newSession(in: harness.session.projectID)
        harness.store.selection = .session(other.id)

        harness.runner.send("Do the work", sessionID: harness.session.id,
                            store: harness.store)

        #expect(await waitUntil { harness.store.recap(for: harness.session.id) != nil })
        #expect(harness.store.recap(for: harness.session.id)?.source == .prompt)
        #expect(harness.store.hasFinished(harness.session.id))
    }

    @Test func doesNotAutomaticallyRecapATurnThatFinishesOnScreen() async throws {
        let harness = try RunnerHarness(agent: .codex, script: """
        input=$(cat)
        printf '%s' "$input" > "$folder/prompt.txt"
        printf '%s\n' '{"type":"thread.started","thread_id":"thread-1"}'
        printf '%s\n' '{"type":"item.completed","item":{"id":"answer-1","item_type":"agent_message","text":"Work complete"}}'
        printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}'
        """, automaticRecapsEnabled: { true })
        defer { harness.tearDown() }
        harness.store.selection = .session(harness.session.id)

        harness.runner.send("Do the work", sessionID: harness.session.id,
                            store: harness.store)

        #expect(await waitUntil { harness.runner.state(harness.session.id) == .idle })
        #expect(harness.store.recap(for: harness.session.id) == nil)
        #expect(!harness.runner.isRecapping(harness.session.id))
    }
}
