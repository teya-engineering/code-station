import Foundation
import Testing
@testable import MenuBarApp

// A turn that starts a background task is not over when its result arrives: the CLI runs
// a follow-up turn when the task finishes, but only while its process is alive. These
// cover the pieces that make holding the process open safe and legible - knowing which
// tasks are still running and what they are, saying so on the rows that describe the
// session, and not charging a run's cumulative usage totals twice.
struct BackgroundTaskTests {

    // MARK: - Reading the task list off the stream

    @Test func readsTheTasksStillRunning() {
        let line = """
        {"type":"system","subtype":"background_tasks_changed","tasks":\
        [{"task_id":"abc123","task_type":"local_bash","description":"sleep"},\
        {"task_id":"def456","task_type":"local_agent","description":"tests"}]}
        """
        guard case .backgroundTasks(let tasks)? = StreamEvent.parse(line).first else {
            Issue.record("expected a task list, got \(StreamEvent.parse(line))")
            return
        }
        #expect(tasks.map(\.id) == ["abc123", "def456"])
        #expect(tasks.map(\.description) == ["sleep", "tests"])
        #expect(tasks.map(\.kind) == ["local_bash", "local_agent"])
    }

    // What the task is called is the only thing that says whether the wait will end on its
    // own, so it has to survive the trip off the stream.
    @Test func namesATaskByItsDescription() {
        let line = """
        {"type":"system","subtype":"background_tasks_changed","tasks":\
        [{"task_id":"abc123","task_type":"local_bash","description":"Run the dev server"}]}
        """
        guard case .backgroundTasks(let tasks)? = StreamEvent.parse(line).first else {
            Issue.record("expected a task list")
            return
        }
        #expect(tasks.first?.label == "Run the dev server")
    }

    // Which agent is running is only said once, on the event that starts the task, and
    // the lists of live tasks that follow never repeat it.
    @Test func readsTheAgentBehindATask() {
        let line = """
        {"type":"system","subtype":"task_started","task_id":"abc123","description":"read the log",\
        "subagent_type":"general-purpose","task_type":"local_agent"}
        """
        guard case .agentTaskStarted(let task)? = StreamEvent.parse(line).first else {
            Issue.record("expected a task agent, got \(StreamEvent.parse(line))")
            return
        }
        #expect(task.id == "abc123")
        #expect(task.agentName == "general-purpose")
    }

    // A workflow names itself rather than a subagent type, and the row still has to say
    // which one is holding the turn open.
    @Test func readsTheWorkflowBehindATask() {
        let line = """
        {"type":"system","subtype":"task_started","task_id":"w1","description":"review",\
        "workflow_name":"review-changes","task_type":"local_workflow"}
        """
        guard case .agentTaskStarted(let task)? = StreamEvent.parse(line).first else {
            Issue.record("expected a task agent")
            return
        }
        #expect(task.agentName == "review-changes")
    }

    // A shell command in the background has no agent behind it, and the event that starts
    // it must not be read as one.
    @Test func aPlainCommandHasNoAgentBehindIt() {
        let line = """
        {"type":"system","subtype":"task_started","task_id":"b1","description":"yarn dev",\
        "task_type":"local_bash"}
        """
        #expect(StreamEvent.parse(line).isEmpty)
    }

    @Test func namesATaskByItsAgentAndItsWork() {
        #expect(BackgroundTask(id: "a", kind: "local_agent", description: "read the log",
                               agentName: "general-purpose").label
                == "general-purpose · read the log")
    }

    // An older CLI, or a kind that does not describe itself, still has to read as something.
    @Test func fallsBackToTheKindOfTask() {
        #expect(BackgroundTask(id: "a", kind: "local_bash", description: nil).label == "a command")
        #expect(BackgroundTask(id: "a", kind: "local_agent", description: "").label == "an agent")
        #expect(BackgroundTask(id: "a", kind: nil, description: nil).label == "a background task")
    }

    // MARK: - How a wait reads

    private func task(_ id: String, _ description: String) -> BackgroundTask {
        BackgroundTask(id: id, kind: "local_bash", description: description)
    }

    @Test func namesTheOneTaskItIsWaitingFor() {
        #expect(BackgroundTaskPhrase.of([task("a", "yarn dev")]) == "yarn dev")
    }

    // Past one there is no room to name them all on a row, and the count is what a reader
    // can act on. The list itself is on the card.
    @Test func countsTasksPastTheFirst() {
        #expect(BackgroundTaskPhrase.of([task("a", "yarn dev"), task("b", "tsc --watch")])
                == "2 background tasks")
    }

    @Test func staysReadableWithNoTasks() {
        #expect(BackgroundTaskPhrase.of([]) == "a background task")
    }

    // The line under a session title says the wait rather than the call that started it:
    // the tool is over, and only the wait explains why the session is still here.
    @Test func theActivityLineSaysWhatItIsWaitingFor() {
        let line = SessionActivity.line(permission: nil, runningTool: nil, root: "/tmp",
                                        lastTool: "Bash · yarn dev", finished: false,
                                        backgroundTasks: [task("a", "yarn dev")])
        #expect(line == "waiting for yarn dev")
    }

    // MARK: - The state a wait reads as

    // A held-open turn is alive but is not working, and a row that says RUNNING through an
    // hour of it is what sends someone looking for a hang.
    @Test func waitingIsItsOwnState() {
        #expect(SessionTone(busy: true, waiting: true) == .waiting)
        #expect(SessionTone(busy: true, waiting: true).word == "WAITING")
        #expect(SessionTone(busy: true) == .running)
    }

    // A question outranks the wait: the CLI can ask for permission in the follow-up turn a
    // finished task wakes, and an answer is the only thing that moves it.
    @Test func aQuestionOutranksTheWait() {
        #expect(SessionTone(busy: true, needsInput: true, waiting: true) == .needsYou)
    }

    // A wait only reads as live while it can still end by itself. The task holding this
    // one open is never going to report, so the row has to stop looking like work in
    // progress and start asking for someone.
    @Test func aStaleWaitAsksForSomeone() {
        #expect(SessionTone(busy: true, waiting: true, waitIsStale: true) == .needsYou)
        #expect(SessionTone(busy: true, waiting: true, waitIsStale: true).word == "NEEDS YOU")
    }

    // Staleness is only ever about a wait. A turn that is genuinely working carries the
    // flag through untouched rather than being pulled off its own state by it.
    @Test func aRunningTurnIgnoresStaleness() {
        #expect(SessionTone(busy: true, waiting: false, waitIsStale: true) == .running)
        #expect(SessionTone(busy: false, waiting: false, waitIsStale: true) == .idle)
    }

    @Test func theTallyCountsWaitingApart() {
        let tally = [SessionTone.running, .waiting, .needsYou, .idle, .idle].tally
        #expect(tally == "1 RUNNING · 1 WAITING · 1 NEEDS YOU · 2 IDLE")
    }

    // An empty list is the signal that the wait is over, so it must come through as an
    // event rather than being dropped as noise.
    @Test func readsAnEmptiedTaskList() {
        let line = #"{"type":"system","subtype":"background_tasks_changed","tasks":[]}"#
        guard case .backgroundTasks(let ids)? = StreamEvent.parse(line).first else {
            Issue.record("expected a task list")
            return
        }
        #expect(ids.isEmpty)
    }

    @Test func stillReadsTheSessionIDOffInit() {
        let line = #"{"type":"system","subtype":"init","session_id":"abc-123"}"#
        guard case .initialized(let id)? = StreamEvent.parse(line).first else {
            Issue.record("expected an init event")
            return
        }
        #expect(id == "abc-123")
    }

    @Test func dropsOtherSystemChatter() {
        let line = #"{"type":"system","subtype":"task_notification","task_id":"abc123"}"#
        #expect(StreamEvent.parse(line).isEmpty)
    }

    // MARK: - Holding the turn open, and letting it go

    @MainActor @Test(arguments: [false, true])
    func distinguishesAnAgentReportFromABackgroundLaunchReceipt(background: Bool) async throws {
        let fixture = try turn(script: """
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"launch","name":"Agent","input":{"name":"reviewer","description":"Review","run_in_background":\(background)}}]}}'
        printf '%s\\n' '{"type":"system","subtype":"task_started","task_id":"abc123","tool_use_id":"launch","description":"Review","subagent_type":"general-purpose","task_type":"local_agent"}'
        printf '%s\\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"launch","content":"Agent response. agentId: abc123"}]}}'
        wait_for "$folder/continue"
        printf '%s\\n' '{"type":"system","subtype":"task_notification","task_id":"abc123","status":"completed","summary":"Review complete."}'
        printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"done"}'
        """)
        defer { fixture.tearDown() }
        #expect(await waitUntil {
            fixture.store.transcript(of: fixture.session.id).flatMap(\.tools)
                .first { $0.id == "launch" }?.result != nil
        })
        let tools = fixture.store.transcript(of: fixture.session.id).flatMap(\.tools)
        #expect(tools.count == 1)
        #expect(tools.first?.agentTask?.state == (background ? .running : .completed))
        #expect(tools.first?.agentTask?.task.agentName == "reviewer")
        try Data().write(to: fixture.scratch.path("continue"))
        #expect(await waitUntil { fixture.runner.state(fixture.session.id) == .idle })
        #expect(fixture.store.transcript(of: fixture.session.id).flatMap(\.tools)
            .first?.agentTask?.report == "Review complete.")
    }

    @MainActor @Test func anAgentStartDoesNotHoldTheTurnOpenWithoutABackgroundList() async throws {
        let fixture = try turn(script: """
        printf '%s\\n' '{"type":"system","subtype":"task_started","task_id":"agent-1","description":"Review","subagent_type":"reviewer","task_type":"local_agent"}'
        printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"done"}'
        cat > /dev/null
        """)
        defer { fixture.tearDown() }
        #expect(await waitUntil { fixture.runner.state(fixture.session.id) == .idle })
        #expect(fixture.store.transcript(of: fixture.session.id).flatMap(\.tools)
            .first?.agentTask?.state == .interrupted)
    }

    @MainActor @Test func aBackgroundListDoesNotFinishAForegroundAgent() async throws {
        let fixture = try turn(script: """
        printf '%s\\n' '{"type":"system","subtype":"task_started","task_id":"agent-1","description":"Review","subagent_type":"reviewer","task_type":"local_agent"}'
        printf '%s\\n' '{"type":"system","subtype":"background_tasks_changed","tasks":[]}'
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Reviewing."}]}}'
        wait_for "$folder/continue"
        printf '%s\\n' '{"type":"system","subtype":"task_notification","task_id":"agent-1","status":"completed","summary":"Review complete."}'
        printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"done"}'
        """)
        defer { fixture.tearDown() }
        #expect(await waitUntil {
            fixture.store.transcript(of: fixture.session.id).contains { $0.text == "Reviewing." }
        })
        #expect(fixture.runner.runningAgents(fixture.session.id).contains("agent-1"))
        #expect(fixture.store.transcript(of: fixture.session.id).flatMap(\.tools)
            .first?.agentTask?.state == .running)
        try Data().write(to: fixture.scratch.path("continue"))
        #expect(await waitUntil { fixture.runner.state(fixture.session.id) == .idle })
    }

    @MainActor @Test func backgroundAgentsKeepTheirReportsAcrossFollowUpMessages() async throws {
        let fixture = try turn(script: """
        printf '%s\\n' '{"type":"system","subtype":"task_started","task_id":"agent-1","description":"Review the diff","subagent_type":"reviewer","task_type":"local_agent"}'
        printf '%s\\n' '{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"agent-1","task_type":"local_agent","description":"Review the diff"}]}'
        printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"The review is running."}'
        wait_for "$folder/continue"
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Checking the review."}]}}'
        printf '%s\\n' '{"type":"system","subtype":"task_notification","task_id":"agent-1","status":"failed","summary":"The diff could not be read."}'
        printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"Review ended."}'
        """)
        defer { fixture.tearDown() }
        #expect(await waitUntil { fixture.runner.state(fixture.session.id) == .waiting })
        let original = try #require(fixture.store.transcript(of: fixture.session.id)
            .first { $0.tools.contains { $0.agentTask?.task.id == "agent-1" } })
        #expect(original.tools.first?.agentTask?.state == .running)
        try Data().write(to: fixture.scratch.path("continue"))
        #expect(await waitUntil { fixture.runner.state(fixture.session.id) == .idle })
        let messages = fixture.store.transcript(of: fixture.session.id)
        let recorded = try #require(messages.first { $0.id == original.id }?.tools.first?.agentTask)
        #expect(recorded.state == .failed)
        #expect(recorded.report == "The diff could not be read.")
        #expect(messages.flatMap(\.tools).filter { $0.agentTask != nil }.count == 1)
        #expect(fixture.runner.runningAgents(fixture.session.id).isEmpty)
    }

    @MainActor @Test func anAgentReportedOnlyInTheLiveListSurvivesItsRemoval() async throws {
        let fixture = try turn(script: """
        printf '%s\\n' '{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"agent-1","task_type":"local_agent","description":"Review the diff"}]}'
        wait_for "$folder/continue"
        printf '%s\\n' '{"type":"system","subtype":"background_tasks_changed","tasks":[]}'
        printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"done"}'
        """)
        defer { fixture.tearDown() }
        #expect(await waitUntil { fixture.runner.runningAgents(fixture.session.id).contains("agent-1") })
        try Data().write(to: fixture.scratch.path("continue"))
        #expect(await waitUntil { fixture.runner.state(fixture.session.id) == .idle })
        let tools = fixture.store.transcript(of: fixture.session.id).flatMap(\.tools)
        #expect(tools.count == 1)
        #expect(tools.first?.agentTask?.state == .finished)
    }

    // A task can run alongside the main turn before that turn parks on it. The working
    // set needs the live list during both phases, while wait-specific UI stays empty here.
    @MainActor @Test func exposesTasksWhileTheMainTurnIsStillWorking() async throws {
        let fixture = try turn(script: """
        printf '%s\\n' '{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"t1","task_type":"local_bash","description":"npm run dev"}]}'
        wait_for "$folder/continue"
        printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"done"}'
        """)
        defer { fixture.tearDown() }

        #expect(await waitUntil {
            fixture.runner.activeBackgroundTasks(fixture.session.id).count == 1
        })
        #expect(fixture.runner.backgroundTasks(fixture.session.id).isEmpty)

        try Data().write(to: fixture.scratch.path("continue"))
        #expect(await waitUntil { fixture.runner.state(fixture.session.id) == .idle })
        #expect(fixture.runner.activeBackgroundTasks(fixture.session.id).isEmpty)
    }

    // The whole point of the hold: the turn has answered, the process is still alive, and
    // what it is waiting for is on hand to say so.
    // End to end: the agent named when the task started rides through to the line the row
    // shows while the turn is held open.
    @MainActor @Test func theWaitNamesTheAgentHoldingItOpen() async throws {
        let fixture = try turn(script: """
        printf '%s\\n' '{"type":"system","subtype":"task_started","task_id":"t1","description":"read the log","subagent_type":"general-purpose","task_type":"local_agent"}'
        printf '%s\\n' '{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"t1","task_type":"local_agent","description":"read the log"}]}'
        printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"done"}'
        cat > /dev/null
        """)
        defer { fixture.tearDown() }

        #expect(await waitUntil { fixture.runner.state(fixture.session.id) == .waiting })
        #expect(BackgroundTaskPhrase.of(fixture.runner.backgroundTasks(fixture.session.id))
                == "general-purpose · read the log")
    }

    @MainActor @Test func holdsTheTurnOpenAndNamesWhatItIsWaitingFor() async throws {
        let fixture = try heldOpenTurn()
        defer { fixture.tearDown() }

        #expect(await waitUntil { fixture.runner.state(fixture.session.id) == .waiting })
        #expect(BackgroundTaskPhrase.of(fixture.runner.backgroundTasks(fixture.session.id))
                == "2 background tasks")
        #expect(fixture.runner.waitingSince(fixture.session.id) != nil)
    }

    // One of two tasks ending is not the end of the wait, and what is on screen has to
    // follow the list down rather than keep reporting the set the result arrived with.
    @MainActor @Test func followsTheTaskListDownWhileItWaits() async throws {
        let fixture = try turnThatDropsATask()
        defer { fixture.tearDown() }
        #expect(await waitUntil { fixture.runner.state(fixture.session.id) == .waiting })

        // Tells the fake CLI that one of its tasks has ended.
        try Data().write(to: fixture.scratch.path("drop"))

        #expect(await waitUntil {
            fixture.runner.backgroundTasks(fixture.session.id).count == 1
        })
        #expect(BackgroundTaskPhrase.of(fixture.runner.backgroundTasks(fixture.session.id))
                == "yarn dev")
        #expect(fixture.runner.state(fixture.session.id) == .waiting)
    }

    // Ending the wait by hand is an ordinary end of turn: the input closes, the CLI exits,
    // and the session goes idle rather than reading as stopped or failed.
    @MainActor @Test func endingTheWaitFinishesTheTurn() async throws {
        let fixture = try heldOpenTurn()
        defer { fixture.tearDown() }
        #expect(await waitUntil { fixture.runner.state(fixture.session.id) == .waiting })

        fixture.runner.endWait(fixture.session.id)

        #expect(await waitUntil { fixture.runner.state(fixture.session.id) == .idle })
        #expect(fixture.runner.backgroundTasks(fixture.session.id).isEmpty)
        #expect(fixture.runner.waitingSince(fixture.session.id) == nil)
    }

    // A task that never reports leaves the turn held open for good. Nothing else has a
    // deadline on it - the stall watchdog is off by the time the hold is taken - so this
    // is the only thing that stops a stuck session sitting on a live light all day.
    @MainActor @Test func aWaitThatOverrunsGoesStale() async throws {
        let fixture = try heldOpenTurn(waitingStaleAfter: 0.2)
        defer { fixture.tearDown() }
        #expect(await waitUntil { fixture.runner.state(fixture.session.id) == .waiting })

        #expect(await waitUntil { fixture.runner.waitIsStale(fixture.session.id) })
        // The turn is left alone: its tasks are the CLI's own children and may yet finish,
        // so the wait is reported rather than ended.
        #expect(fixture.runner.state(fixture.session.id) == .waiting)
        #expect(!fixture.runner.backgroundTasks(fixture.session.id).isEmpty)
    }

    // The deadline belongs to the wait it was armed for. A wait that ends on its own has
    // to take its watchdog with it, or the next quiet moment inherits the alarm.
    @MainActor @Test func aWaitThatEndsIsNeverCalledStale() async throws {
        let fixture = try heldOpenTurn(waitingStaleAfter: 0.2)
        defer { fixture.tearDown() }
        #expect(await waitUntil { fixture.runner.state(fixture.session.id) == .waiting })

        fixture.runner.endWait(fixture.session.id)
        #expect(await waitUntil { fixture.runner.state(fixture.session.id) == .idle })
        try? await Task.sleep(for: .milliseconds(400))
        #expect(!fixture.runner.waitIsStale(fixture.session.id))
    }

    // A CLI that answers with nothing running behind it ends the turn there and then, so
    // the hold cannot be what keeps an ordinary session busy.
    @MainActor @Test func aTurnWithNoTasksIsOverWhenItAnswers() async throws {
        let fixture = try turn(script: """
        printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"done"}'
        cat > /dev/null
        """)
        defer { fixture.tearDown() }

        #expect(await waitUntil { fixture.runner.state(fixture.session.id) == .idle })
        #expect(fixture.runner.waitingSince(fixture.session.id) == nil)
    }

    // A resumed process starts by handing over the wake-up the one before it left queued,
    // and that handover ends in an empty result of its own. The turn the app asked for is
    // the one after it, so the hold has to survive the first result rather than close the
    // input on it and leave the CLI with nowhere to report back to.
    @MainActor @Test func aResultBeforeTheTurnAnsweredIsNotTheAnswer() async throws {
        let fixture = try turn(script: """
        printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":""}'
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"abc-123"}'
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"on it"}]}}'
        """ + Self.reportsTwoTasks + """
        cat > /dev/null
        """)
        defer { fixture.tearDown() }

        #expect(await waitUntil { fixture.runner.state(fixture.session.id) == .waiting })
        // The hold is only real if the input is still open. A fake CLI whose input was
        // closed on the first result reaches its last line and exits, so the wait that
        // was there a moment ago is gone by the time it is looked at again.
        try? await Task.sleep(for: .milliseconds(300))
        #expect(fixture.runner.state(fixture.session.id) == .waiting)
        #expect(BackgroundTaskPhrase.of(fixture.runner.backgroundTasks(fixture.session.id))
                == "2 background tasks")
    }

    // The guard is only for a result that answered nothing: once the turn has spoken, an
    // empty result is an ordinary end of turn and has to let the process go.
    @MainActor @Test func anEmptyResultAfterTheTurnSpokeStillEndsIt() async throws {
        let fixture = try turn(script: """
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}'
        printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":""}'
        cat > /dev/null
        """)
        defer { fixture.tearDown() }

        #expect(await waitUntil { fixture.runner.state(fixture.session.id) == .idle })
    }

    // A fake CLI that reports two tasks, answers, and then waits on its input the way the
    // real one does while a task of its own is still running.
    @MainActor
    private func heldOpenTurn(waitingStaleAfter: TimeInterval = 10 * 60) throws -> RunnerHarness {
        try turn(script: Self.reportsTwoTasks + """
        cat > /dev/null
        """, waitingStaleAfter: waitingStaleAfter)
    }

    // The same, but one of the two ends when the test says so rather than on a timer, so
    // what the test observes does not depend on how loaded the machine is.
    @MainActor
    private func turnThatDropsATask() throws -> RunnerHarness {
        try turn(script: Self.reportsTwoTasks + """
        wait_for "$folder/drop"
        printf '%s\\n' '{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"t1","task_type":"local_bash","description":"yarn dev"}]}'
        cat > /dev/null
        """)
    }

    private static let reportsTwoTasks = """
    printf '%s\\n' '{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"t1","task_type":"local_bash","description":"yarn dev"},{"task_id":"t2","task_type":"local_bash","description":"tsc --watch"}]}'
    printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"done"}'

    """

    // A fake Claude Code CLI already running its first turn.
    @MainActor
    private func turn(script: String,
                      waitingStaleAfter: TimeInterval = 10 * 60) throws -> RunnerHarness {
        let harness = try RunnerHarness(agent: .claudeCode, script: script,
                                        waitingStaleAfter: waitingStaleAfter)
        harness.runner.send("start", sessionID: harness.session.id, store: harness.store)
        return harness
    }

    // MARK: - Usage across a held-open turn

    private func usage(cost: Double, input: Int, output: Int,
                       read: Int = 0, write: Int = 0) -> TurnUsage {
        var usage = TurnUsage()
        usage.costUSD = cost
        usage.inputTokens = input
        usage.outputTokens = output
        usage.cacheReadTokens = read
        usage.cacheWriteTokens = write
        return usage
    }

    @Test func firstReportCountsWhole() {
        let totals = usage(cost: 1.5, input: 10, output: 200)
        #expect(SessionRunner.grown(totals, since: nil) == totals)
    }

    @Test func laterReportCountsOnlyWhatGrew() {
        let first = usage(cost: 1.0, input: 10, output: 100, read: 500, write: 50)
        let second = usage(cost: 1.6, input: 14, output: 130, read: 900, write: 50)
        let grown = SessionRunner.grown(second, since: first)
        #expect(abs(grown.costUSD - 0.6) < 0.0001)
        #expect(grown.inputTokens == 4)
        #expect(grown.outputTokens == 30)
        #expect(grown.cacheReadTokens == 400)
        #expect(grown.cacheWriteTokens == 0)
    }

    // A report that shrinks is one that was never cumulative, and the safe reading of it
    // is nothing new rather than a negative charge.
    @Test func neverCountsBackwards() {
        let first = usage(cost: 2.0, input: 20, output: 300)
        let second = usage(cost: 0.5, input: 5, output: 80)
        let grown = SessionRunner.grown(second, since: first)
        #expect(grown.costUSD == 0)
        #expect(grown.inputTokens == 0)
        #expect(grown.outputTokens == 0)
    }

    // MARK: - Naming the command behind a held-open wait

    private func session(with tools: [ToolUse]) -> ChatSession {
        var session = ChatSession(projectID: UUID())
        session.messages = [ChatMessage(role: .assistant, tools: tools)]
        return session
    }

    @Test func findsTheCommandBehindATask() {
        let session = session(with: [
            ToolUse(id: "toolu_1", name: "Bash", input: #"{"command":"npm run dev"}"#),
        ])
        #expect(session.shellCommand(forTaskWith: "toolu_1") == "npm run dev")
    }

    // A wait that will never end is only obvious once the loop itself is on screen, and
    // the loop is usually the longest thing the model ever writes on one line.
    @Test func keepsTheWholeLoopOnOneLine() {
        let session = session(with: [
            ToolUse(id: "toolu_1", name: "Bash",
                    input: #"{"command":"until grep -q done out\ndo :\ndone"}"#),
        ])
        #expect(session.shellCommand(forTaskWith: "toolu_1") == "until grep -q done out do : done")
    }

    // A task whose call has scrolled out of the loaded transcript still has to draw, just
    // without the command.
    @Test func hasNoCommandForAnUnknownCall() {
        let session = session(with: [
            ToolUse(id: "toolu_1", name: "Bash", input: #"{"command":"npm run dev"}"#),
        ])
        #expect(session.shellCommand(forTaskWith: "toolu_other") == nil)
    }

    // An agent is a background task too, and its input names no command.
    @Test func hasNoCommandForACallThatIsNotAShell() {
        let session = session(with: [
            ToolUse(id: "toolu_1", name: "Agent", input: #"{"description":"Review the diff"}"#),
        ])
        #expect(session.shellCommand(forTaskWith: "toolu_1") == nil)
    }

    // The model and window ride along on the newest report even when nothing grew.
    @Test func keepsTheNewestModelAndWindow() {
        let first = usage(cost: 1.0, input: 10, output: 100)
        var second = usage(cost: 1.0, input: 10, output: 100)
        second.model = "claude-fable-5"
        second.contextWindow = 1_000_000
        let grown = SessionRunner.grown(second, since: first)
        #expect(grown.model == "claude-fable-5")
        #expect(grown.contextWindow == 1_000_000)
    }
}
