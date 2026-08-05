import Foundation
import Testing
@testable import MenuBarApp

// The control protocol is the only part of the CLI the app has to answer rather than just
// read, and a wrong answer parks a turn forever or lets a tool run that was denied. The
// payloads here are real ones taken off the wire.
struct PermissionRequestTests {

    private let toolRequest = """
    {"type":"control_request","request_id":"a79df114","request":{"subtype":"can_use_tool",\
    "tool_name":"Write","display_name":"Write","input":{"file_path":"/tmp/p/hello.txt","content":"hi\\n"},\
    "description":"hello.txt","permission_suggestions":[{"type":"setMode","mode":"acceptEdits",\
    "destination":"session"}],"tool_use_id":"toolu_01Xr"}}
    """

    private let questionRequest = """
    {"type":"control_request","request_id":"7c28face","request":{"subtype":"can_use_tool",\
    "tool_name":"AskUserQuestion","display_name":"AskUserQuestion","input":{"questions":[\
    {"question":"Tabs or spaces?","header":"Indentation","options":[\
    {"label":"Spaces","description":"Renders the same everywhere."},\
    {"label":"Tabs","description":"Each reader sets the width."}],"multiSelect":false}]},\
    "tool_use_id":"toolu_01DV","requires_user_interaction":true}}
    """

    private func parsed(_ line: String) throws -> PermissionRequest {
        let events = StreamEvent.parse(line, projectPath: "/tmp/p")
        guard case .permissionRequest(let request)? = events.first else {
            Issue.record("expected a permission request, got \(events)")
            throw CancellationError()
        }
        return request
    }

    private func decoded(_ line: Data?) throws -> [String: Any] {
        let data = try #require(line)
        #expect(data.last == 0x0A, "the CLI reads stdin a line at a time")
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decision(_ line: Data?) throws -> [String: Any] {
        let outer = try decoded(line)
        let response = try #require(outer["response"] as? [String: Any])
        #expect(outer["type"] as? String == "control_response")
        #expect(response["subtype"] as? String == "success")
        return try #require(response["response"] as? [String: Any])
    }

    // MARK: - Reading what was asked

    @Test func readsAToolWaitingForPermission() throws {
        let request = try parsed(toolRequest)

        #expect(request.id == "a79df114")
        #expect(request.toolName == "Write")
        #expect(request.title == "Write")
        #expect(request.subject == "hello.txt")
        // The CLI said the same thing the input already says, so there is nothing to add.
        #expect(request.detail == "")
        #expect(request.isQuestion == false)
        // The CLI decides what "do not ask again" would mean here, and it offered a mode.
        #expect(request.alwaysTitle == "Accept edits from now on")
    }

    @Test func readsAQuestionWithItsOptions() throws {
        let request = try parsed(questionRequest)
        let question = try #require(request.questions.first)

        #expect(request.isQuestion)
        #expect(question.header == "Indentation")
        #expect(question.text == "Tabs or spaces?")
        #expect(question.multiSelect == false)
        #expect(question.options.map(\.label) == ["Spaces", "Tabs"])
        // Nothing was suggested, so there is no "always" button to offer.
        #expect(request.alwaysTitle == nil)
    }

    // A tool the CLI does not describe is summarised the way the transcript summarises it.
    @Test func fallsBackToSummarisingTheInput() throws {
        let line = """
        {"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool",\
        "tool_name":"Bash","input":{"command":"npm test"},"tool_use_id":"t1"}}
        """
        #expect(try parsed(line).subject == "npm test")
    }

    // The description is what the agent meant to do; the command is what would happen.
    // Deciding on the description alone would mean approving a command nobody read.
    @Test func showsTheCommandAlongsideTheDescription() throws {
        let line = """
        {"type":"control_request","request_id":"r2","request":{"subtype":"can_use_tool",\
        "tool_name":"Bash","input":{"command":"env LOG=2 swift run App\\ncat /etc/hosts"},\
        "description":"Run the app with logging","tool_use_id":"t2"}}
        """
        let request = try parsed(line)

        #expect(request.subject == "env LOG=2 swift run App\ncat /etc/hosts")
        #expect(request.detail == "Run the app with logging")
    }

    // The CLI parks the turn on every control request until that exact request id is
    // answered. One it can ask for and the app cannot serve - a dialog, a hook, an MCP
    // relay - therefore has to come back refused; staying quiet is a turn that thinks
    // forever with nothing on screen to explain it.
    @Test func refusesControlTrafficItCannotAnswer() throws {
        let dialog = """
        {"type":"control_request","request_id":"k1","request":{"subtype":"request_user_dialog",\
        "dialog":{"title":"Sign in"}}}
        """
        guard case .unanswerable(let id, let subtype)? = StreamEvent.parse(dialog).first else {
            Issue.record("expected a refusal, got \(StreamEvent.parse(dialog))")
            return
        }
        #expect(id == "k1")
        #expect(subtype == "request_user_dialog")

        let outer = try decoded(SessionRunner.refusalLine(requestID: id, subtype: subtype))
        let response = try #require(outer["response"] as? [String: Any])
        #expect(outer["type"] as? String == "control_response")
        #expect(response["subtype"] as? String == "error")
        #expect(response["request_id"] as? String == "k1")
    }

    // A permission request whose shape the app cannot read is still a request the CLI is
    // holding the turn on, so it goes back the same way rather than being dropped.
    @Test func refusesAPermissionRequestItCannotRead() {
        let malformed = """
        {"type":"control_request","request_id":"k2","request":{"subtype":"can_use_tool",\
        "input":{"command":"ls"}}}
        """
        guard case .unanswerable(let id, let subtype)? = StreamEvent.parse(malformed).first else {
            Issue.record("expected a refusal, got \(StreamEvent.parse(malformed))")
            return
        }
        #expect(id == "k2")
        #expect(subtype == "can_use_tool")
    }

    // Without a request id there is nobody to answer, so there is nothing to do.
    @Test func ignoresAControlRequestWithNoIdentity() {
        #expect(StreamEvent.parse(#"{"type":"control_request","request":{"subtype":"x"}}"#).isEmpty)
    }

    // The agent gives up on its own question when a turn is interrupted, and the card has
    // to go with it.
    @Test func noticesARequestBeingWithdrawn() {
        let events = StreamEvent.parse(#"{"type":"control_cancel_request","request_id":"a79df114"}"#)
        guard case .permissionWithdrawn(let id)? = events.first else {
            Issue.record("expected a withdrawal, got \(events)")
            return
        }
        #expect(id == "a79df114")
    }

    // MARK: - Answering

    @Test func allowingHandsTheInputBackUntouched() throws {
        let request = try parsed(toolRequest)
        let decision = try decision(request.responseLine(.allowOnce))

        #expect(decision["behavior"] as? String == "allow")
        #expect(decision["updatedInput"] as? [String: String]
                == ["file_path": "/tmp/p/hello.txt", "content": "hi\n"])
        // Only "always" carries a permission change; a plain allow is for this call alone.
        #expect(decision["updatedPermissions"] == nil)
    }

    @Test func alwaysAllowingSendsBackWhatTheCLISuggested() throws {
        let request = try parsed(toolRequest)
        let decision = try decision(request.responseLine(.allowAlways))
        let permissions = try #require(decision["updatedPermissions"] as? [[String: Any]])

        #expect(decision["behavior"] as? String == "allow")
        #expect(permissions.first?["type"] as? String == "setMode")
        #expect(permissions.first?["mode"] as? String == "acceptEdits")
    }

    @Test func denyingCarriesASentenceTheAgentCanRead() throws {
        let request = try parsed(toolRequest)
        let decision = try decision(request.responseLine(.deny))

        #expect(decision["behavior"] as? String == "deny")
        #expect((decision["message"] as? String)?.isEmpty == false)
        #expect(decision["updatedInput"] == nil)
    }

    // An answered question is allowed, not denied: the answers ride back inside the tool's
    // own input, which is where AskUserQuestion reads them from.
    @Test func answersRideBackInsideTheToolInput() throws {
        let request = try parsed(questionRequest)
        let decision = try decision(request.responseLine(.answers(["Tabs or spaces?": "Tabs"])))
        let input = try #require(decision["updatedInput"] as? [String: Any])

        #expect(decision["behavior"] as? String == "allow")
        #expect(input["answers"] as? [String: String] == ["Tabs or spaces?": "Tabs"])
        // The questions have to survive the round trip, or the tool has nothing to match
        // the answers against.
        #expect((input["questions"] as? [Any])?.count == 1)
    }

    @Test func showsTheAnswersInTheTranscript() {
        let text = PermissionRequest.transcript(of: ["Tabs or spaces?": "Tabs"])
        #expect(text == "Tabs or spaces?\nTabs")
    }
}
