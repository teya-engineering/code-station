import Foundation
import Testing
@testable import MenuBarApp

// A fan-out arrives in the same flat stream as everything else: the only thing saying a
// call was made by an agent rather than by the main loop is the call that started it.
struct AgentActivityTests {

    private func call(_ id: String, name: String = "Bash", parent: String? = nil,
                      at offset: Int? = 0, result: String? = "ok") -> ToolUse {
        ToolUse(id: id, name: name, input: "{}", result: result,
                textOffset: offset, parentID: parent)
    }

    private func message(_ tools: [ToolUse], text: String = "") -> ChatMessage {
        ChatMessage(role: .assistant, text: text, tools: tools)
    }

    // MARK: - Reading the stream

    @Test func namesTheAgentBehindACallItMade() throws {
        let line = """
        {"type":"assistant","parent_tool_use_id":"agent_1","message":{"role":"assistant","content":\
        [{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}
        """
        guard case .toolUse(let tool)? = StreamEvent.parse(line).first else {
            Issue.record("expected a tool call, got \(StreamEvent.parse(line))")
            return
        }
        #expect(tool.parentID == "agent_1")
    }

    @Test func leavesACallTheMainLoopMadeUnparented() throws {
        let line = """
        {"type":"assistant","message":{"role":"assistant","content":\
        [{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}
        """
        guard case .toolUse(let tool)? = StreamEvent.parse(line).first else {
            Issue.record("expected a tool call")
            return
        }
        #expect(tool.parentID == nil)
    }

    // An agent's words are not part of the conversation - it reports back through its
    // result - so they never land in the transcript as something the model said.
    @Test func keepsWhatAnAgentSaysOutOfTheTranscript() {
        let line = """
        {"type":"assistant","parent_tool_use_id":"agent_1","message":{"role":"assistant",\
        "content":[{"type":"text","text":"Downloading the floorplan."}]}}
        """
        let events = StreamEvent.parse(line)
        guard case .agentText(let parentID, let text)? = events.first else {
            Issue.record("expected agent text, got \(events)")
            return
        }
        #expect(parentID == "agent_1")
        #expect(text == "Downloading the floorplan.")
    }

    @Test func keepsTheMainLoopsThinking() {
        let line = """
        {"type":"assistant","message":{"role":"assistant","content":\
        [{"type":"thinking","thinking":"The bug is in the parser.","signature":"sig"},\
        {"type":"text","text":"Found it."}]}}
        """
        let events = StreamEvent.parse(line)
        guard case .thinking(let thought)? = events.first,
              case .text(let text)? = events.last else {
            Issue.record("expected thinking then text, got \(events)")
            return
        }
        #expect(thought == "The bug is in the parser.")
        #expect(text == "Found it.")
    }

    // An agent's thinking stays with the agent, and redacted thinking arrives encrypted,
    // so neither has anything to show.
    @Test func dropsThinkingTheConversationCannotShow() {
        let agents = """
        {"type":"assistant","parent_tool_use_id":"agent_1","message":{"role":"assistant",\
        "content":[{"type":"thinking","thinking":"Reading the floorplan."}]}}
        """
        #expect(StreamEvent.parse(agents).isEmpty)
        let redacted = """
        {"type":"assistant","message":{"role":"assistant","content":\
        [{"type":"redacted_thinking","data":"opaque-bytes"}]}}
        """
        #expect(StreamEvent.parse(redacted).isEmpty)
    }

    // MARK: - Folding the turn into a tree

    @Test func hangsACallUnderTheAgentThatMadeIt() throws {
        let tree = message([call("a", name: "Agent"), call("b", parent: "a"),
                            call("c", parent: "a")]).toolTree

        #expect(tree.map(\.id) == ["a"])
        #expect(tree[0].children.map(\.id) == ["b", "c"])
    }

    @Test func countsEverythingThatRanInsideAWorkflow() throws {
        let tree = message([call("w", name: "Workflow"),
                            call("a1", name: "Agent", parent: "w"),
                            call("a2", name: "Agent", parent: "w"),
                            call("b", parent: "a1"),
                            call("c", parent: "a2")]).toolTree

        #expect(tree[0].callCount == 4)
        #expect(tree[0].agentCount == 2)
    }

    // An agent that hands its work on again is still one more agent at work, so it is
    // counted as deep as the calls it made are.
    @Test func countsAnAgentThatAnotherAgentStarted() throws {
        let tree = message([call("w", name: "Workflow"),
                            call("a1", name: "Agent", parent: "w"),
                            call("a2", name: "Agent", parent: "a1"),
                            call("b", parent: "a2")]).toolTree

        #expect(tree[0].agentCount == 2)
    }

    // An agent sent to the background reports its own result at once and keeps working,
    // so a call still in flight can sit under one that has already finished.
    @Test func seesWorkStillRunningUnderAFinishedCall() throws {
        let tree = message([call("a", name: "Agent", result: "started"),
                            call("b", parent: "a", result: nil)]).toolTree

        #expect(tree[0].tool.isRunning == false)
        #expect(tree[0].isWorking(agents: []))
    }

    @Test func reportsNothingRunningOnceEveryCallIsBack() throws {
        let tree = message([call("a", name: "Agent"), call("b", parent: "a")]).toolTree

        #expect(!tree[0].isWorking(agents: []))
    }

    // MARK: - An agent sent to the background

    // The receipt an agent answers with names it, and that name is how the CLI's list of
    // running agents refers to it.
    @Test func readsTheIDOffAnAgentsLaunchReceipt() {
        let receipt = """
        Async agent launched successfully. (This tool result is internal metadata.) \
        agentId: af1aa370d8fa76988 (internal ID - do not mention to user.)
        """
        #expect(call("a", name: "Agent", result: receipt).backgroundAgentID
                == "af1aa370d8fa76988")
    }

    @Test func readsNoIDOffAnOrdinaryCall() {
        #expect(call("b", result: "agentId: af1aa370d8fa76988").backgroundAgentID == nil)
        #expect(call("a", name: "Agent", result: "done").backgroundAgentID == nil)
        #expect(call("a", name: "Agent", result: nil).backgroundAgentID == nil)
    }

    // The whole point of the id: an agent that has answered its own call is still at work
    // for as long as the CLI keeps listing it, and nothing else in the turn says so.
    @Test func countsABackgroundAgentAsWorkingWhileTheCLIListsIt() {
        let tree = message([call("a", name: "Agent",
                                 result: "launched. agentId: af1aa370 (internal)")]).toolTree

        #expect(tree[0].isWorking(agents: ["af1aa370"]))
        #expect(!tree[0].isWorking(agents: ["other"]))
    }

    // A row stands for everything under it, so an agent that started another one is still
    // working while its own agents are.
    @Test func countsAnAgentAsWorkingWhileItsOwnAgentsAre() {
        let tree = message([call("w", name: "Workflow"),
                            call("a", name: "Agent", parent: "w",
                                 result: "launched. agentId: af1aa370 (internal)")]).toolTree

        #expect(tree[0].isWorking(agents: ["af1aa370"]))
    }

    // A failure deep inside a fan-out is the one thing a folded block has to say out loud.
    @Test func seesAFailureAnywhereInsideAFanOut() throws {
        var failed = call("b", parent: "a")
        failed.isError = true
        let tree = message([call("a", name: "Agent"), failed]).toolTree

        #expect(tree[0].hasError)
    }

    // A call whose parent is missing is still work that happened, so it is drawn where it
    // can be seen rather than dropped with the agent that owned it.
    @Test func keepsACallWhoseAgentIsMissing() {
        let tree = message([call("a"), call("orphan", parent: "gone")]).toolTree

        #expect(tree.map(\.id) == ["a", "orphan"])
    }

    // The newest call of the whole fan-out is what a running row reports, and it can sit
    // at any depth - the tree loses the order between branches, the position does not.
    @Test func findsTheNewestCallAnywhereInsideAFanOut() throws {
        let tree = message([call("w", name: "Workflow"),
                            call("a1", name: "Agent", parent: "w"),
                            call("a2", name: "Agent", parent: "w"),
                            call("early", parent: "a2"),
                            call("newest", parent: "a1")]).toolTree

        #expect(tree[0].newestDescendant?.id == "newest")
    }

    // Only what the main loop did sets the shape of the turn: an agent's calls belong to
    // the row that started it, however much text arrived while they ran.
    @Test func leavesAnAgentsCallsOutOfTheTurnsOwnRounds() {
        let message = message([call("a", name: "Agent", at: 4),
                               call("inside", parent: "a", at: 4),
                               call("b", at: 9)],
                              text: "Off.\n\nBack.")
        let rounds = message.blocks.compactMap { block -> [String]? in
            guard case .tools(_, let nodes) = block else { return nil }
            return nodes.map(\.id)
        }

        #expect(rounds == [["a"], ["b"]])
    }

    // MARK: - Naming the call

    @Test func namesAWorkflowByWhatItIsCalled() {
        #expect(presented("Workflow", #"{"name":"find-flaky-tests"}"#) == "find-flaky-tests")
    }

    @Test func namesAResumedWorkflowByItsScriptFile() {
        #expect(presented("Workflow", #"{"scriptPath":"/tmp/wf/house-inspect.js"}"#)
                == "house-inspect.js")
    }

    // A workflow launched inline carries its whole script, and the only thing in there
    // worth a row is the name it gives itself.
    @Test func readsAnInlineWorkflowsNameOutOfItsScript() {
        let input = """
        {"script":"export const meta = {\\n  name: 'review-changes',\\n  description: 'x',\\n}\\nphase('Review')"}
        """
        #expect(presented("Workflow", input) == "review-changes")
    }

    @Test func fallsBackToCallingItAWorkflow() {
        #expect(presented("Workflow", #"{"script":"phase('Review')"}"#) == "workflow")
    }

    @Test func namesAnAgentByWhatItWasAskedToDo() {
        #expect(presented("Agent", #"{"description":"review the diff","prompt":"long…"}"#)
                == "review the diff")
    }

    // A fan-out sends several agents after the same kind of work, so which agent went is
    // as much of the row as what it was sent to do.
    @Test func saysWhichAgentWasSent() {
        #expect(presented("Task", #"{"subagent_type":"general-purpose","description":"read the log"}"#)
                == "general-purpose · read the log")
    }

    // An agent given a name of its own is known by it, the way the CLI's own list of
    // running agents reads: the type it was built from is the less specific of the two.
    @Test func prefersTheNameAnAgentWasGiven() {
        #expect(presented("Agent", #"{"name":"Navigator","subagent_type":"general-purpose","description":"map the site"}"#)
                == "Navigator · map the site")
    }

    @Test func namesAnAgentThatOnlySaysItsType() {
        #expect(presented("Task", #"{"subagent_type":"Explore","prompt":"find every caller"}"#)
                == "Explore · find every caller")
    }

    private func presented(_ name: String, _ input: String) -> String {
        ToolPresentation(tool: ToolUse(id: "t", name: name, input: input),
                         projectPath: "/tmp/p").argument
    }
}
