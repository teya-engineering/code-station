import Foundation
import Testing
@testable import CodeStationCore
@testable import MenuBarApp

// The notices list is the only place in the app that says a session is waiting on a
// person, so what it puts first and how it words each line is what decides whether that
// gets noticed at all.
@MainActor
struct SidebarNoticesTests {
    private func session(_ title: String, activeAt: Date = .now,
                         workspaceID: UUID? = nil) -> ChatSession {
        var session = ChatSession(projectID: UUID())
        session.title = title
        session.summary.lastMessageAt = activeAt
        session.workspaceID = workspaceID
        return session
    }

    private func noticed(_ title: String, _ notice: SessionNotice, activeAt: Date = .now,
                         project: String = "api", workspaceID: UUID? = nil) -> NoticedSession {
        NoticedSession(session: session(title, activeAt: activeAt, workspaceID: workspaceID),
                       project: Project(name: project, path: "/tmp/\(project)"),
                       notice: notice, reason: "")
    }

    private func request(toolName: String, title: String,
                         questions: [AgentQuestion] = []) -> PermissionRequest {
        PermissionRequest(id: "req-1", toolName: toolName, title: title,
                          subject: "", detail: "", input: Data(),
                          suggestions: nil, alwaysTitle: nil, questions: questions)
    }

    // MARK: - What each line says

    // A permission prompt names the tool, since that is what the answer is about.
    @Test func aPermissionNamesTheToolInLowerCase() {
        let reason = SidebarNotices.reason(
            .needsInput, question: request(toolName: "Bash", title: "Run a command"))

        #expect(reason == "permission · bash")
    }

    // A question names what is being asked instead, because the tool behind it is not
    // what the person has to decide.
    @Test func aQuestionNamesWhatIsBeingAsked() {
        let question = AgentQuestion(id: 1, header: "Pick one", text: "Which database?",
                                     multiSelect: false, options: [])
        let reason = SidebarNotices.reason(
            .needsInput,
            question: request(toolName: "AskUserQuestion", title: "Which Database?",
                              questions: [question]))

        #expect(reason == "question · which database?")
    }

    // The notice can outlive the request that caused it, and a row with no words under
    // its title would read as though nothing were wrong.
    @Test func somethingWaitingWithNoRequestStillSaysSo() {
        #expect(SidebarNotices.reason(.needsInput, question: nil)
            == "waiting on an answer")
    }

    @Test func aRunningSessionSaysItIsRunning() {
        #expect(SidebarNotices.reason(.running, question: nil) == "running")
    }

    @Test func aFinishedTurnSaysItEndedWhileAway() {
        #expect(SidebarNotices.reason(.finished, question: nil)
            == "finished while away")
    }

    // MARK: - What comes first

    // Waiting on a person outranks everything: it is the only kind anyone has to act on.
    @Test func whatIsWaitingOnAPersonLeads() {
        let waiting = noticed("waiting", .needsInput, activeAt: .distantPast)
        let running = noticed("running", .running, activeAt: .now)

        #expect(SidebarNotices.comesFirst(waiting, running))
        #expect(!SidebarNotices.comesFirst(running, waiting))
    }

    // A live run outranks an older unseen completion.
    @Test func aLiveRunLeadsAnUnseenCompletion() {
        let running = noticed("running", .running, activeAt: .distantPast)
        let finished = noticed("finished", .finished, activeAt: .now)

        #expect(SidebarNotices.comesFirst(running, finished))
    }

    // Within one kind the rail reads newest first, the way the cards under it do.
    @Test func withinAKindTheMostRecentLeads() {
        let older = noticed("older", .running, activeAt: Date(timeIntervalSince1970: 1_000))
        let newer = noticed("newer", .running, activeAt: Date(timeIntervalSince1970: 2_000))

        #expect(SidebarNotices.comesFirst(newer, older))
        #expect(!SidebarNotices.comesFirst(older, newer))
    }
}
