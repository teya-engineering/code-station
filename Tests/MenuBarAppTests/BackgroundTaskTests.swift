import Foundation
import Testing
@testable import MenuBarApp

// A turn that starts a background task is not over when its result arrives: the CLI runs
// a follow-up turn when the task finishes, but only while its process is alive. These
// cover the two pieces that make holding the process open safe - knowing which tasks are
// still running, and not charging a run's cumulative usage totals twice.
struct BackgroundTaskTests {

    // MARK: - Reading the task list off the stream

    @Test func readsTheTasksStillRunning() {
        let line = """
        {"type":"system","subtype":"background_tasks_changed","tasks":\
        [{"task_id":"abc123","task_type":"local_bash","description":"sleep"},\
        {"task_id":"def456","task_type":"local_agent","description":"tests"}]}
        """
        guard case .backgroundTasks(let ids)? = StreamEvent.parse(line).first else {
            Issue.record("expected a task list, got \(StreamEvent.parse(line))")
            return
        }
        #expect(Set(ids) == ["abc123", "def456"])
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
