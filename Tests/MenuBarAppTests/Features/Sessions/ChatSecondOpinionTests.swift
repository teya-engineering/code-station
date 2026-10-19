import Foundation
import Testing
@testable import MenuBarApp
@testable import CodeStationCore

struct ChatSecondOpinionTests {
    private let plan = ChatSecondOpinion.Subject(kind: .plan, id: "plan:1",
                                                 text: "1. Retry read timeouts.\n2. Back off.",
                                                 request: "Plan how we retry timed-out authorisations.")
    private let codex = SecondOpinion.Reviewer(agent: .codex, model: "gpt-5.6-sol", effort: "high")
    private let copilot = SecondOpinion.Reviewer(agent: .copilot, model: "gpt-5.4")

    private func request(_ reading: ChatSecondOpinion.Reading = .init(), conversation: String = "") -> ChatSecondOpinion.Request {
        ChatSecondOpinion.Request(subject: plan, reading: reading, conversation: conversation,
                                  directories: ["/repo"], executable: "/bin/codex")
    }

    @Test func aVerdictIsReadOutOfAWrappedAnswer() throws {
        let answer = """
        Here is what I think:
        ```json
        {"verdict": "agrees_with_changes", "summary": "Step 1 can charge twice.",
         "points": [{"step": 1, "severity": "MUST", "text": "A read timeout may already have reached the acquirer {so} retry connect timeouts only."},
                    {"step": null, "severity": "odd", "text": "Worth a test."},
                    {"step": 2, "severity": "should", "text": "  "}]}
        ```
        """
        let reply = try #require(ChatSecondOpinion.reply(in: answer))
        #expect(reply.verdict == .agreesWithChanges)
        #expect(reply.summary == "Step 1 can charge twice.")
        #expect(reply.points.map(\.step) == [1, nil])
        #expect(reply.points.map(\.severity) == [.must, .look])
        #expect(ChatSecondOpinion.reply(in: "Looks fine to me.") == nil)
        #expect(ChatSecondOpinion.reply(in: #"{"verdict": "maybe"}"#) == nil)
        #expect(ChatSecondOpinion.reply(in: #"{"verdict": "agrees"}"#)?.points == [])
    }

    @Test func thePromptOnlyCarriesWhatThePersonChoseToShare() {
        let plain = ChatSecondOpinion.prompt(for: request(conversation: "User: earlier secret"))
        #expect(plain.contains("1. Retry read timeouts."))
        #expect(plain.contains("Plan how we retry timed-out authorisations."))
        #expect(plain.contains("read the project's files"))
        #expect(!plain.contains("earlier secret"))

        let shared = ChatSecondOpinion.prompt(for: request(.init(files: false, conversation: true),
                                                           conversation: "User: earlier secret"))
        #expect(shared.contains("earlier secret"))
        #expect(shared.contains("Do not open the project's files"))
    }

    @Test func twoSeatsOnTheSameStepAreOnePointWithBothVoices() {
        var opinion = ChatOpinion(subject: plan, anchor: nil, request: request(),
                                  lanes: [.init(reviewer: codex), .init(reviewer: copilot)])
        opinion.take(.init(verdict: .agreesWithChanges, summary: "", points: [
            .init(step: 4, severity: .should, text: "Do not wait on the request thread."),
            .init(step: 1, severity: .should, text: "Read timeouts are unsafe."),
        ]), from: codex)
        opinion.take(.init(verdict: .disagrees, summary: "", points: [
            .init(step: 1, severity: .must, text: "Resend with the original idempotency key."),
            .init(step: 3, severity: .look, text: "The column needs a default."),
        ]), from: copilot)

        #expect(opinion.points.count == 3)
        let first = opinion.points[0]
        #expect(first.step == 1)
        #expect(first.severity == .must)
        #expect(first.voices.map(\.reviewer) == [codex, copilot])
        #expect(first.raisedByMoreThanOne)
        // A worth-a-look point waits unticked; the others are ticked to send.
        #expect(opinion.ticked.map(\.step) == [1, 4])
    }

    @Test func theFeedbackNamesWhoLookedAndOnlyTheTickedPoints() {
        let points = [ChatOpinion.RaisedPoint(step: 1, severity: .must,
                                              voices: [.init(reviewer: codex, text: "Retry connect timeouts only.")],
                                              ticked: true),
                      ChatOpinion.RaisedPoint(step: nil, severity: .should,
                                              voices: [.init(reviewer: copilot, text: "Add a test.")], ticked: true)]
        let text = ChatSecondOpinion.feedback(points, subject: plan, names: "Codex and Copilot")
        #expect(text == "Before you start, Codex and Copilot looked at the plan. Change it for these:\n- Step 1. Retry connect timeouts only.\n- Add a test.")
    }

    @Test func aPlanSentBackWithPointsIsRefusedWithThemAsTheReason() throws {
        let request = PermissionRequest(id: "r1", toolName: "ExitPlanMode", title: "ExitPlanMode", subject: "plan",
                                        subjectIsMarkdown: true, detail: "", input: Data("{}".utf8),
                                        suggestions: nil, alwaysTitle: nil, questions: [])
        let line = try #require(request.responseLine(.revise("Change step 1.")))
        let object = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        let decision = ((object["response"] as? [String: Any])?["response"]) as? [String: Any]
        #expect(decision?["behavior"] as? String == "deny")
        #expect(decision?["message"] as? String == "Change step 1.")
        #expect(!PermissionAnswer.revise("x").allows)
        #expect(PermissionAnswer.allowOnce.allows)
    }

    @MainActor @Test func nothingReachesTheAuthorUntilItIsSent() async {
        let store = ChatOpinionStore()
        store.askReviewer = { _, reviewer, _, _ in
            reviewer.agent == .codex
                ? .success(.init(verdict: .agrees, summary: "Sound.",
                                 points: [.init(step: 2, severity: .look, text: "Cap the delay.")]))
                : .failure(.init(message: "Its answer was not a verdict."))
        }
        let session = UUID()
        let id = store.ask(request(), reviewers: [codex, codex, copilot],
                           executables: [.codex: "/bin/codex", .copilot: "/bin/copilot"],
                           anchor: nil, in: session)
        #expect(store.opinions(session).first?.lanes.count == 2)
        #expect(await waitUntil { store.opinions(session).first?.isRunning == false })
        let opinion = try? #require(store.opinions(session).first)
        #expect(opinion?.id == id)
        #expect(opinion?.lanes.first?.state == .finished(.agrees, summary: "Sound."))
        #expect(opinion?.lanes.last?.state == .failed("Its answer was not a verdict."))
        #expect(opinion?.ticked.isEmpty == true)
        #expect(opinion?.sent == nil)

        if let id, let point = opinion?.points.first {
            store.toggle(point.id, of: id, in: session)
            #expect(store.opinions(session).first?.ticked.count == 1)
            store.markSent(id, count: 1, in: session)
            #expect(store.opinions(session).first?.sent == 1)
        }

        // Asking again on the same subject replaces the earlier opinion.
        store.ask(request(), reviewers: [codex], executables: [.codex: "/bin/codex"], anchor: nil, in: session)
        #expect(store.opinions(session).count == 1)
        #expect(store.opinions(session).first?.sent == nil)
    }

    @MainActor @Test func aSeatWithNoInstalledAgentIsLeftOut() {
        let store = ChatOpinionStore()
        #expect(store.ask(request(), reviewers: [copilot], executables: [.codex: "/bin/codex"],
                          anchor: nil, in: UUID()) == nil)
    }
}
