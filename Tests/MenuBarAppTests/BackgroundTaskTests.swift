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

    // The whole point of the hold: the turn has answered, the process is still alive, and
    // what it is waiting for is on hand to say so.
    @MainActor @Test func holdsTheTurnOpenAndNamesWhatItIsWaitingFor() async throws {
        let fixture = try heldOpenTurn()
        defer { fixture.tearDown() }

        #expect(await fixture.waitUntil { fixture.runner.state(fixture.session.id) == .waiting })
        #expect(BackgroundTaskPhrase.of(fixture.runner.backgroundTasks(fixture.session.id))
                == "2 background tasks")
        #expect(fixture.runner.waitingSince(fixture.session.id) != nil)
    }

    // One of two tasks ending is not the end of the wait, and what is on screen has to
    // follow the list down rather than keep reporting the set the result arrived with.
    @MainActor @Test func followsTheTaskListDownWhileItWaits() async throws {
        let fixture = try turnThatDropsATask()
        defer { fixture.tearDown() }
        #expect(await fixture.waitUntil { fixture.runner.state(fixture.session.id) == .waiting })

        fixture.dropATask()

        #expect(await fixture.waitUntil {
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
        #expect(await fixture.waitUntil { fixture.runner.state(fixture.session.id) == .waiting })

        fixture.runner.endWait(fixture.session.id)

        #expect(await fixture.waitUntil { fixture.runner.state(fixture.session.id) == .idle })
        #expect(fixture.runner.backgroundTasks(fixture.session.id).isEmpty)
        #expect(fixture.runner.waitingSince(fixture.session.id) == nil)
    }

    // A CLI that answers with nothing running behind it ends the turn there and then, so
    // the hold cannot be what keeps an ordinary session busy.
    @MainActor @Test func aTurnWithNoTasksIsOverWhenItAnswers() async throws {
        let fixture = try turn(script: """
        printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"done"}'
        cat > /dev/null
        """)
        defer { fixture.tearDown() }

        #expect(await fixture.waitUntil { fixture.runner.state(fixture.session.id) == .idle })
        #expect(fixture.runner.waitingSince(fixture.session.id) == nil)
    }

    // A fake CLI that reports two tasks, answers, and then waits on its input the way the
    // real one does while a task of its own is still running.
    @MainActor
    private func heldOpenTurn() throws -> RunnerFixture {
        try turn(script: Self.reportsTwoTasks + """
        cat > /dev/null
        """)
    }

    // The same, but one of the two ends when the test says so rather than on a timer, so
    // what the test observes does not depend on how loaded the machine is.
    @MainActor
    private func turnThatDropsATask() throws -> RunnerFixture {
        try turn(script: Self.reportsTwoTasks + """
        while [ ! -f "$(dirname "$0")/drop" ]; do sleep 0.02; done
        printf '%s\\n' '{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"t1","task_type":"local_bash","description":"yarn dev"}]}'
        cat > /dev/null
        """)
    }

    private static let reportsTwoTasks = """
    printf '%s\\n' '{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"t1","task_type":"local_bash","description":"yarn dev"},{"task_id":"t2","task_type":"local_bash","description":"tsc --watch"}]}'
    printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"done"}'

    """

    @MainActor
    private func turn(script: String) throws -> RunnerFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("background-tasks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("claude-fixture")
        try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: executable.path)
        let projectURL = directory.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let store = ProjectStore(storeURL: directory.appendingPathComponent("projects.json"))
        let project = try #require(store.addProject(at: projectURL))
        let session = try store.insertSession(in: project.id, agent: .claudeCode).get()
        let runner = SessionRunner(paths: [.claudeCode: executable.path])
        runner.send("start", sessionID: session.id, store: store)
        return RunnerFixture(directory: directory, store: store, session: session, runner: runner)
    }

    @MainActor
    private struct RunnerFixture {
        let directory: URL
        let store: ProjectStore
        let session: ChatSession
        let runner: SessionRunner

        // Tells the fake CLI that one of its tasks has ended.
        func dropATask() {
            FileManager.default.createFile(atPath: directory.appendingPathComponent("drop").path,
                                           contents: nil)
        }

        func waitUntil(_ condition: () -> Bool) async -> Bool {
            for _ in 0..<1_000 {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return condition()
        }

        // A fixture that failed part way through can leave the fake CLI blocked on its
        // input for good, so the process is let go whatever the test decided.
        func tearDown() {
            runner.stopAll()
            try? FileManager.default.removeItem(at: directory)
        }
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
