import Foundation
import Testing
@testable import MenuBarApp

struct SessionTitleTests {
    @Test func cleansPlainTextTitles() {
        #expect(SessionTitle.cleaned("  ## Title: \"Fix the login retry\"  ") == "Fix the login retry")
        #expect(SessionTitle.cleaned("Fix\n the login\t retry") == "Fix the login retry")
        #expect(SessionTitle.cleaned("Login \u{2014} fix retries") == "Login - fix retries")
    }

    @Test func rejectsEmptyOrVerboseAnswers() {
        #expect(SessionTitle.cleaned(nil) == nil)
        #expect(SessionTitle.cleaned(" \n ") == nil)
        #expect(SessionTitle.cleaned("Here is a title and an explanation of the changes") == nil)
        #expect(SessionTitle.cleaned(String(repeating: "x", count: 61)) == nil)
    }

    @Test func namesASessionAfterWhatItsFirstPromptCarries() {
        #expect(retitled(ChatMessage(role: .user, text: "Fix the login retry"))
            == "Fix the login retry")
        #expect(retitled(message(text: "", attachments: ["/tmp/pasted-3dea7157.png"]))
            == "Pasted image")
        #expect(retitled(message(text: "", attachments: ["/tmp/pasted-text-3dea7157.txt"]))
            == "Pasted text")
        #expect(retitled(message(text: "", attachments: ["/tmp/crash-report.txt"]))
            == "crash-report.txt")
        #expect(retitled(message(text: "", attachments: ["/tmp/one.png", "/tmp/two.png"]))
            == "2 attachments")
        #expect(retitled(ChatMessage(role: .user, text: " \n ")) == "New session")
    }

    private func message(text: String, attachments: [String]) -> ChatMessage {
        var message = ChatMessage(role: .user, text: text)
        message.attachments = attachments
        return message
    }

    private func retitled(_ message: ChatMessage) -> String {
        var session = ChatSession(projectID: UUID())
        session.retitleIfNeeded(from: message)
        return session.title
    }
}

@MainActor
struct SessionTitleRunnerTests {
    @Test(arguments: AgentKind.allCases)
    func automaticallyTitlesOnlyTheFirstTurn(agent: AgentKind) async throws {
        let harness = try RunnerHarness(agent: agent, script: script(agent),
                                        automaticTitlesEnabled: { true })
        defer { harness.tearDown() }
        harness.store.selection = .session(harness.session.id)
        harness.runner.send("Please fix the login retry logic", sessionID: harness.session.id,
                            store: harness.store)
        #expect(await waitUntil { harness.store.session(harness.session.id)?.title == "Fix login retries" })
        #expect(harness.store.transcript(of: harness.session.id).map(\.text)
            == ["Please fix the login retry logic", "Work complete"])
        #expect(harness.store.sidebarSession(harness.session.id)?.title == "Fix login retries")
        #expect(harness.store.save())
        #expect(ProjectStore(storeURL: harness.store.storeURL).session(harness.session.id)?.title
            == "Fix login retries")

        harness.runner.send("Add a regression test", sessionID: harness.session.id,
                            store: harness.store)
        #expect(await waitUntil { harness.runner.state(harness.session.id) == .idle })
        #expect(try starts(harness) == "work\ntitle\nwork\n")
    }

    @Test(arguments: AgentKind.allCases)
    func manualGenerationWorksWithAutomaticTitlesOff(agent: AgentKind) async throws {
        let harness = try RunnerHarness(agent: agent, script: script(agent))
        defer { harness.tearDown() }
        #expect(!harness.runner.canRegenerateTitle(harness.session.id, store: harness.store))
        harness.runner.send("Please fix the login retry logic", sessionID: harness.session.id,
                            store: harness.store)
        #expect(!harness.runner.canRegenerateTitle(harness.session.id, store: harness.store))
        #expect(await waitUntil { harness.runner.state(harness.session.id) == .idle })
        #expect(harness.store.session(harness.session.id)?.title == "Please fix the login retry logic")
        #expect(try starts(harness) == "work\n")
        harness.store.renameSession(harness.session.id, to: "My old title")
        #expect(harness.runner.regenerateTitle(harness.session.id, store: harness.store))
        #expect(!harness.runner.regenerateTitle(harness.session.id, store: harness.store))
        #expect(await waitUntil { harness.store.session(harness.session.id)?.title == "Fix login retries" })
        #expect(harness.store.transcript(of: harness.session.id).map(\.text)
            == ["Please fix the login retry logic", "Work complete"])
    }

    @Test func titlesBeforeRunningAQueuedFollowUp() async throws {
        let harness = try RunnerHarness(agent: .codex, script: script(.codex),
                                        automaticTitlesEnabled: { true })
        defer { harness.tearDown() }
        harness.runner.send("Fix the login retry", sessionID: harness.session.id, store: harness.store)
        harness.runner.send("Add a regression test", sessionID: harness.session.id, store: harness.store)
        #expect(await waitUntil { harness.runner.state(harness.session.id) == .idle })
        #expect(try starts(harness) == "work\ntitle\nwork\n")
        #expect(harness.store.transcript(of: harness.session.id).map(\.text)
            == ["Fix the login retry", "Work complete", "Add a regression test", "Work complete"])
    }

    @Test func automaticallyGeneratesBothATitleAndAnUnseenRecap() async throws {
        let harness = try RunnerHarness(agent: .codex, script: script(.codex),
                                        automaticRecapsEnabled: { true },
                                        automaticTitlesEnabled: { true })
        defer { harness.tearDown() }
        harness.store.selection = .session(harness.store.newSession(in: harness.session.projectID).id)
        harness.runner.send("Fix the login retry", sessionID: harness.session.id, store: harness.store)
        #expect(await waitUntil { harness.store.recap(for: harness.session.id) != nil })
        #expect(harness.store.session(harness.session.id)?.title == "Fix login retries")
        #expect(harness.store.hasFinished(harness.session.id))
        #expect(try starts(harness) == "work\ntitle\nrecap\n")
        #expect(harness.store.transcript(of: harness.session.id).map(\.text)
            == ["Fix the login retry", "Work complete"])
    }

    @Test func leavesAManuallyNamedSessionAlone() async throws {
        let harness = try RunnerHarness(agent: .codex, script: script(.codex),
                                        automaticTitlesEnabled: { true })
        defer { harness.tearDown() }
        harness.store.renameSession(harness.session.id, to: "My title")
        harness.runner.send("Fix the login retry", sessionID: harness.session.id, store: harness.store)
        #expect(await waitUntil { harness.runner.state(harness.session.id) == .idle })
        #expect(harness.store.session(harness.session.id)?.title == "My title")
        #expect(try starts(harness) == "work\n")
    }

    @Test func aRenameDuringGenerationWinsEvenWhenTheNameIsReused() async throws {
        let harness = try RunnerHarness(agent: .codex, script: script(.codex, holdsTitle: true))
        defer { harness.tearDown() }
        harness.runner.send("Fix the login retry", sessionID: harness.session.id, store: harness.store)
        #expect(await waitUntil { harness.runner.state(harness.session.id) == .idle })
        #expect(harness.runner.regenerateTitle(harness.session.id, store: harness.store))
        #expect(await waitUntil {
            FileManager.default.fileExists(atPath: harness.scratch.path("title-streamed").path)
        })
        #expect(harness.store.transcript(of: harness.session.id).map(\.text)
            == ["Fix the login retry", "Work complete"])
        harness.store.renameSession(harness.session.id, to: "Another name")
        harness.store.renameSession(harness.session.id, to: "Fix the login retry")
        try Data().write(to: harness.scratch.path("release-title"))
        #expect(await waitUntil { harness.runner.state(harness.session.id) == .idle })
        #expect(harness.store.session(harness.session.id)?.title == "Fix the login retry")
    }

    @Test(arguments: ["failure", "empty", "verbose"])
    func anUnusableTitleKeepsTheExistingName(outcome: String) async throws {
        let harness = try RunnerHarness(agent: .codex, script: script(.codex, titleOutcome: outcome),
                                        automaticTitlesEnabled: { true })
        defer { harness.tearDown() }
        harness.runner.send("Fix the login retry", sessionID: harness.session.id, store: harness.store)
        #expect(await waitUntil { harness.runner.state(harness.session.id) == .idle })
        #expect(harness.store.session(harness.session.id)?.title == "Fix the login retry")
        #expect(harness.store.transcript(of: harness.session.id).map(\.text)
            == ["Fix the login retry", "Work complete"])
        #expect(try starts(harness) == "work\ntitle\n")
    }

    @Test func enablingTitlesDoesNotRenameAnExistingConversation() async throws {
        var enabled = false
        let harness = try RunnerHarness(agent: .codex, script: script(.codex),
                                        automaticTitlesEnabled: { enabled })
        defer { harness.tearDown() }
        harness.runner.send("Fix the login retry", sessionID: harness.session.id, store: harness.store)
        #expect(await waitUntil { harness.runner.state(harness.session.id) == .idle })
        enabled = true
        harness.runner.send("Add a regression test", sessionID: harness.session.id, store: harness.store)
        #expect(await waitUntil { harness.runner.state(harness.session.id) == .idle })
        #expect(harness.store.session(harness.session.id)?.title == "Fix the login retry")
        #expect(try starts(harness) == "work\nwork\n")
    }

    @Test func aStoppedGenerationKeepsTheTitleAndQueuedPrompt() async throws {
        let harness = try RunnerHarness(agent: .codex, script: script(.codex, holdsTitle: true))
        defer { harness.tearDown() }
        harness.runner.send("Fix the login retry", sessionID: harness.session.id, store: harness.store)
        #expect(await waitUntil { harness.runner.state(harness.session.id) == .idle })
        #expect(harness.runner.regenerateTitle(harness.session.id, store: harness.store))
        #expect(await waitUntil {
            FileManager.default.fileExists(atPath: harness.scratch.path("title-streamed").path)
        })
        harness.runner.send("Add a regression test", sessionID: harness.session.id, store: harness.store)
        harness.runner.stop(harness.session.id)
        #expect(await waitUntil { harness.runner.state(harness.session.id) == .idle })
        #expect(harness.store.session(harness.session.id)?.title == "Fix the login retry")
        #expect(harness.store.transcript(of: harness.session.id).map(\.text)
            == ["Fix the login retry", "Work complete"])
        #expect(harness.runner.queued(harness.session.id).map(\.text) == ["Add a regression test"])
    }

    @Test func aFailedFirstTurnDoesNotGenerateATitle() async throws {
        let harness = try RunnerHarness(agent: .codex, script: """
        input=$(cat)
        printf '%s\\n' '{"type":"thread.started","thread_id":"thread-1"}'
        exit 1
        """, automaticTitlesEnabled: { true })
        defer { harness.tearDown() }
        harness.runner.send("Fix the login retry", sessionID: harness.session.id, store: harness.store)
        #expect(await waitUntil {
            if case .failed = harness.runner.state(harness.session.id) { return true }
            return false
        })
        #expect(!harness.runner.isGeneratingTitle(harness.session.id, store: harness.store))
        #expect(harness.store.session(harness.session.id)?.title == "Fix the login retry")
    }

    @Test func aDesignConversationUpdatesItsVisibleSessionTitle() async throws {
        let harness = try RunnerHarness(agent: .codex, script: script(.codex),
                                        automaticTitlesEnabled: { true })
        defer { harness.tearDown() }
        let design = try harness.store.startDesign(for: harness.session.id).get()
        harness.runner.send("Design a login form", sessionID: design.id, store: harness.store)
        #expect(await waitUntil { harness.store.session(harness.session.id)?.title == "Fix login retries" })
        #expect(harness.store.session(design.id)?.title == "Design")
        #expect(harness.runner.regenerateTitle(harness.session.id, store: harness.store))
        #expect(await waitUntil { harness.runner.state(design.id) == .idle })
        #expect(try starts(harness) == "work\ntitle\ntitle\n")
        #expect(harness.store.transcript(of: design.id).map(\.text)
            == ["Design a login form", "Work complete"])
    }

    private func starts(_ harness: RunnerHarness) throws -> String {
        try String(contentsOf: harness.scratch.path("starts"), encoding: .utf8)
    }

    private func script(_ agent: AgentKind, holdsTitle: Bool = false,
                        titleOutcome: String = "success") -> String {
        let read = switch agent {
        case .claudeCode: "IFS= read -r input"
        case .codex: "input=$(cat)"
        case .copilot: "input=\"$*\""
        }
        let output = switch agent {
        case .claudeCode:
            """
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
            printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"'"$answer"'"}]}}'
            """
        case .codex:
            """
            printf '%s\\n' '{"type":"thread.started","thread_id":"thread-1"}'
            printf '%s\\n' '{"type":"item.completed","item":{"id":"answer","item_type":"agent_message","text":"'"$answer"'"}}'
            """
        case .copilot:
            """
            printf '%s\\n' '{"type":"assistant.message","data":{"messageId":"answer","content":"'"$answer"'"}}'
            """
        }
        let completion = switch agent {
        case .claudeCode:
            """
            printf '%s\\n' '{"type":"result","is_error":false,"result":"'"$answer"'"}'
            """
        case .codex:
            """
            printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}'
            """
        case .copilot:
            """
            printf '%s\\n' '{"type":"result","sessionId":"copilot-1","exitCode":0}'
            """
        }
        return """
        \(read)
        kind=work
        answer='Work complete'
        case "$input" in
            *'Return only the title.'*) kind=title; answer='Fix login retries' ;;
            *'Return only the recap.'*) kind=recap; answer='The retry fix is complete. Review it next.' ;;
        esac
        printf '%s\\n' "$kind" >> "$folder/starts"
        if [ "$kind" = title ]; then
            case '\(titleOutcome)' in
                failure) exit 1 ;;
                empty) answer='' ;;
                verbose) answer='Here is a title and an explanation of all of the changes made in this session' ;;
            esac
        fi
        \(output)
        if [ "$kind" = title ] && [ '\(holdsTitle)' = true ]; then
            : > "$folder/title-streamed"
            wait_for "$folder/release-title"
        fi
        \(completion)
        """
    }
}
