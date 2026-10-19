import Foundation
import Testing
@testable import CodeStationCore

// Part of the station contract (see StationContract.swift): looking after a session from
// a client, as the GUI's session card menu and its transcript do. Rename, regenerate the
// title, pin, mark read or unread and delete with the impact the GUI asks with; rewind or
// fork from a prompt; continue after a failure or dismiss it; take back a queued prompt;
// ask for a recap; and take the suggested next prompt. What a client needs to offer them
// travels on the open session's header.
@MainActor
struct StationSessionUpkeepTests {

    private static func station(_ fixture: RunnerHarness) -> StationCommands {
        StationCommands(store: fixture.store, runner: fixture.runner, refreshInterval: .milliseconds(50))
    }

    private func row(_ id: UUID, in commands: any StationInterface) async throws -> RemoteSessionRow? {
        try await commands.listDirectory().containers?.flatMap(\.sessions).first { $0.id == id.uuidString }
    }

    // Rename, pin and unpin, and mark unread and read, each show in the directory, as the
    // card's menu does them in the GUI. An empty name is refused.
    @Test(arguments: StationImplementation.allCases)
    func renamePinAndUnreadShowInTheDirectory(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0")
        defer { fixture.tearDown() }
        let commands = kind.connect(to: Self.station(fixture))
        let id = fixture.session.id.uuidString

        _ = try await commands.sessionAction(id, .rename(title: "  Fix the login bug "))
        _ = try await commands.sessionAction(id, .pin)
        _ = try await commands.sessionAction(id, .markUnread)
        var listed = try #require(try await row(fixture.session.id, in: commands))
        #expect(listed.title == "Fix the login bug")
        #expect(listed.isPinned == true)
        #expect(listed.isUnread == true)

        _ = try await commands.sessionAction(id, .unpin)
        _ = try await commands.sessionAction(id, .markRead)
        listed = try #require(try await row(fixture.session.id, in: commands))
        #expect(listed.isPinned == false)
        #expect(listed.isUnread == false)

        await #expect(throws: StationRefusal("Give the session a name.")) {
            try await commands.sessionAction(id, .rename(title: "   "))
        }
        await #expect(throws: StationRefusal.noSession) {
            try await commands.sessionAction(UUID().uuidString, .pin)
        }
    }

    // Deleting asks with what goes and what stays, as the GUI's dialog does, then the
    // session leaves the directory and the store.
    @Test(arguments: StationImplementation.allCases)
    func deletingDescribesItsImpactThenRemovesTheSession(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0")
        defer { fixture.tearDown() }
        fixture.store.renameSession(fixture.session.id, to: "Fix the login bug")
        let commands = kind.connect(to: Self.station(fixture))
        let id = fixture.session.id.uuidString

        let impact = try await commands.sessionRemovalImpact(id)
        #expect(impact.title == "Delete this session?")
        #expect(impact.message == "Fix the login bug")
        #expect(impact.subject == RemoteImpact.Subject(name: "project", kind: .project))
        #expect(impact.rows.first == RemoteImpact.Row(title: "Conversation history", detail: "Removed from Code Station."))
        #expect(impact.rows.last?.title == "Project folder stays")
        #expect(impact.rows.last?.kept == true)
        #expect(impact.warning == "Conversation history cannot be restored.")
        #expect(impact.action == "Delete session")

        _ = try await commands.sessionAction(id, .delete)
        #expect(try await row(fixture.session.id, in: commands) == nil)
        #expect(fixture.store.session(fixture.session.id) == nil)
    }

    // A conversation of two Claude turns, the second prompt carrying the checkpoint it
    // started from, in a session in the project folder.
    private func twoTurns(_ fixture: RunnerHarness) -> (first: ChatMessage, second: ChatMessage) {
        let id = fixture.session.id
        var first = ChatMessage(role: .user, text: "Build the thing")
        first.checkpoint = ConversationCheckpoint(agent: .claudeCode)
        fixture.store.append(first, to: id)
        fixture.store.append(ChatMessage(role: .assistant, text: "Built it"), to: id)
        var second = ChatMessage(role: .user, text: "Now break it")
        second.checkpoint = ConversationCheckpoint(agent: .claudeCode, claudeSessionID: "claude-1")
        fixture.store.append(second, to: id)
        fixture.store.append(ChatMessage(role: .assistant, text: "Broke it"), to: id)
        fixture.store.setAgentSessionID("claude-2", agent: .claudeCode, for: id)
        return (first, second)
    }

    // The header names the prompts a client can rewind or fork from. Rewinding drops
    // them and everything after, and answers with the prompt for the composer; forking
    // answers with a new session to open, holding the conversation up to the prompt.
    @Test(arguments: StationImplementation.allCases)
    func rewindAndForkFromAPrompt(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0")
        defer { fixture.tearDown() }
        fixture.store.renameSession(fixture.session.id, to: "Thing")
        let (first, second) = twoTurns(fixture)
        let commands = kind.connect(to: Self.station(fixture))
        let id = fixture.session.id.uuidString

        let opened = try #require(try await commands.openSession(id))
        let upkeep = try #require(opened.snapshot.header.upkeep)
        #expect(Set(upkeep.rewindable) == [first.id.uuidString, second.id.uuidString])
        #expect(Set(upkeep.forkable) == [first.id.uuidString, second.id.uuidString])

        let fork = try await commands.sessionAction(id, .fork(messageID: second.id.uuidString))
        let forkID = try #require(fork.openSession)
        #expect(fork.draft == "Now break it")
        let forked = try #require(try await commands.openSession(forkID))
        #expect(forked.snapshot.header.title == "Thing · fork")
        #expect(forked.snapshot.messages.map(\.text).prefix(2) == ["Build the thing", "Built it"])
        #expect(forked.snapshot.messages.count == 3)

        let rewound = try await commands.sessionAction(id, .rewind(messageID: second.id.uuidString, draft: ""))
        #expect(rewound.draft == "Now break it")
        #expect(rewound.openSession == nil)
        let after = try #require(try await commands.openSession(id))
        #expect(after.snapshot.messages.map(\.text).prefix(2) == ["Build the thing", "Built it"])
        #expect(!after.snapshot.messages.contains { $0.id == second.id.uuidString })

        await #expect(throws: StationRefusal("The conversation can't go back to that prompt.")) {
            try await commands.sessionAction(id, .rewind(messageID: UUID().uuidString, draft: ""))
        }
    }

    // A turn that fails offers Continue and Dismiss on the header. Continuing runs a
    // recovery turn on the fixture CLI; dismissing clears the failure.
    @Test(arguments: StationImplementation.allCases)
    func continueAndDismissAfterAFailure(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: """
        IFS= read -r input
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
        case "$input" in
            *"Inspect the current state"*)
                printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Carried on"}]}}'
                printf '%s\\n' '{"type":"result","is_error":false,"result":"Carried on"}' ;;
            *)
                printf '%s\\n' '{"type":"result","is_error":true,"result":"The agent fell over"}' ;;
        esac
        """)
        defer { fixture.tearDown() }
        let station = Self.station(fixture)
        let commands = kind.connect(to: station)
        let id = fixture.session.id.uuidString
        let opened = try #require(try await commands.openSession(id))
        let log = EventLog()
        log.mirror = RemoteTranscript(opened.snapshot)
        let reader = Task { @MainActor in
            for await event in opened.events { log.mirror?.apply(event) }
        }
        defer { reader.cancel() }

        try await commands.sendPrompt(id, prompt: "Do it")
        #expect(await eventually { log.mirror?.header.upkeep?.canContinue == true })
        #expect(log.mirror?.header.failure != nil)

        _ = try await commands.sessionAction(id, .continue)
        #expect(await eventually { log.mirror?.messages.contains { $0.text == "Carried on" } == true })
        #expect(await eventually { log.mirror?.header.isBusy == false })

        try await commands.sendPrompt(id, prompt: "Do it again")
        #expect(await eventually { log.mirror?.header.failure != nil })
        _ = try await commands.sessionAction(id, .dismissFailure)
        #expect(await eventually { log.mirror?.header.failure == nil })
        #expect(log.mirror?.header.upkeep?.canContinue == false)

        await #expect(throws: StationRefusal("There is nothing to continue.")) {
            try await commands.sessionAction(id, .continue)
        }
    }

    // A prompt queued behind a running turn can be taken back before it is sent.
    @Test(arguments: StationImplementation.allCases)
    func aQueuedPromptCanBeTakenBack(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: """
        IFS= read -r input
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
        wait_for "$folder/release"
        printf '%s\\n' '{"type":"result","is_error":false,"result":"Done"}'
        """)
        defer { fixture.tearDown() }
        let commands = kind.connect(to: Self.station(fixture))
        let id = fixture.session.id.uuidString

        try await commands.sendPrompt(id, prompt: "First")
        try await commands.sendPrompt(id, prompt: "Second")
        var queued: [RemoteQueuedPrompt] = []
        #expect(await eventually {
            queued = try await commands.openSession(id)?.snapshot.queued ?? []
            return queued.count == 1
        })
        _ = try await commands.sessionAction(id, .unqueue(promptID: queued[0].id))
        #expect(fixture.runner.queued(fixture.session.id).isEmpty)
        await #expect(throws: StationRefusal("That prompt is no longer queued.")) {
            try await commands.sessionAction(id, .unqueue(promptID: queued[0].id))
        }
        try Data().write(to: fixture.scratch.path("release"))
        #expect(await eventually { !fixture.runner.state(fixture.session.id).isBusy })
    }

    // A recap and a regenerated title each run on the fixture CLI and show on the
    // header; the suggestion the agent predicted shows there too, and can be sent as the
    // next prompt, taken into the composer or dismissed.
    @Test(arguments: StationImplementation.allCases)
    func recapTitleAndSuggestion(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .codex, script: """
        input=$(cat)
        answer='Work complete'
        case "$input $*" in
            *'Return only the title.'*) answer='Fix login retries' ;;
            *'Return only the recap.'*) answer='The retry fix is complete.' ;;
            *'Return only the prompt.'*) answer='Add a regression test' ;;
        esac
        printf '%s\\n' '{"type":"thread.started","thread_id":"thread-1"}'
        printf '%s\\n' '{"type":"item.completed","item":{"id":"answer","item_type":"agent_message","text":"'"$answer"'"}}'
        printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}'
        """, promptSuggestionsEnabled: { true })
        defer { fixture.tearDown() }
        let commands = kind.connect(to: Self.station(fixture))
        let id = fixture.session.id.uuidString
        let opened = try #require(try await commands.openSession(id))
        let log = EventLog()
        log.mirror = RemoteTranscript(opened.snapshot)
        let reader = Task { @MainActor in
            for await event in opened.events { log.mirror?.apply(event) }
        }
        defer { reader.cancel() }
        #expect(opened.snapshot.header.upkeep?.canRecap == false)

        try await commands.sendPrompt(id, prompt: "Fix the login retry")
        #expect(await eventually { log.mirror?.header.upkeep?.suggestion == "Add a regression test" })
        #expect(log.mirror?.header.upkeep?.canRecap == true)
        #expect(log.mirror?.header.upkeep?.canRegenerateTitle == true)

        let taken = try await commands.sessionAction(id, .takeSuggestion)
        #expect(taken.draft == "Add a regression test")
        #expect(await eventually { log.mirror?.header.upkeep?.suggestion == nil })

        _ = try await commands.sessionAction(id, .regenerateTitle)
        #expect(await eventually { log.mirror?.header.title == "Fix login retries" })
        #expect(await eventually { log.mirror?.header.isBusy == false })

        _ = try await commands.sessionAction(id, .recap)
        #expect(await eventually { log.mirror?.header.upkeep?.recap == "The retry fix is complete." })
        // The recap never joins the conversation.
        #expect(log.mirror?.messages.map(\.text) == ["Fix the login retry", "Work complete"])

        await #expect(throws: StationRefusal("There is no suggestion to take.")) {
            try await commands.sessionAction(id, .sendSuggestion)
        }
    }
}
