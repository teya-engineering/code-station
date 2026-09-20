import Foundation
import Testing
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
            .needsInput, question: request(toolName: "Bash", title: "Run a command"),
            activity: nil)

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
                              questions: [question]),
            activity: nil)

        #expect(reason == "question · which database?")
    }

    // The notice can outlive the request that caused it, and a row with no words under
    // its title would read as though nothing were wrong.
    @Test func somethingWaitingWithNoRequestStillSaysSo() {
        #expect(SidebarNotices.reason(.needsInput, question: nil, activity: nil)
            == "waiting on an answer")
    }

    @Test func aRunningSessionBorrowsItsCardsActivityLine() {
        #expect(SidebarNotices.reason(.running, question: nil, activity: "editing Theme.swift")
            == "editing Theme.swift")
    }

    // A run with nothing to say still has to say something.
    @Test func aRunningSessionWithNothingToSayStillSaysItIsRunning() {
        #expect(SidebarNotices.reason(.running, question: nil, activity: nil) == "running")
    }

    @Test func aFinishedTurnSaysItEndedWhileAway() {
        #expect(SidebarNotices.reason(.finished, question: nil, activity: nil)
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

    // MARK: - The menu behind the running count

    private func labels(_ entries: [MenuEntry]) -> [String?] {
        entries.map { entry in
            if case .item(let item) = entry { return item.label }
            return nil
        }
    }

    // The list arrives grouped, so a rule between two neighbours of different kinds is
    // all the separation the menu needs.
    @Test func aRuleSitsOnlyWhereTheKindChanges() {
        let (store, _) = TestStore.make()
        let notices = [noticed("ask", .needsInput), noticed("run one", .running),
                       noticed("run two", .running), noticed("done", .finished)]

        let entries = SidebarNotices.menu(notices, store: store,
                                          isSelected: { _ in false }, open: { _ in })

        let expected: [String?] = ["ask", nil, "run one", "run two", nil, "done"]
        #expect(labels(entries) == expected)
    }

    // A rule before the first entry would draw a stray line at the top of the menu.
    @Test func theMenuNeverOpensWithARule() {
        let (store, _) = TestStore.make()
        let notices = [noticed("only", .needsInput)]

        let entries = SidebarNotices.menu(notices, store: store,
                                          isSelected: { _ in false }, open: { _ in })

        let expected: [String?] = ["only"]
        #expect(entries.count == 1)
        #expect(labels(entries) == expected)
    }

    @Test func nothingNoticedIsAnEmptyMenu() {
        let (store, _) = TestStore.make()

        #expect(SidebarNotices.menu([], store: store,
                                    isSelected: { _ in false }, open: { _ in }).isEmpty)
    }

    // A session says which project it belongs to, so two alike titles are still
    // distinguishable in one flat list.
    @Test func aSessionOutsideAWorkspaceIsFiledUnderItsProject() throws {
        let (store, _) = TestStore.make()
        let notices = [noticed("build", .running, project: "lantern-api")]

        let entries = SidebarNotices.menu(notices, store: store,
                                          isSelected: { _ in false }, open: { _ in })

        let item = try #require(menuItem(entries.first))
        #expect(item.subtitle == "lantern-api")
    }

    // A session in a workspace is filed under the workspace instead: that is the name it
    // is read by, and its lead project alone would be misleading.
    @Test func aSessionInAWorkspaceIsFiledUnderTheWorkspace() throws {
        let (store, _) = TestStore.make()
        let lead = try TestStore.project(in: store, named: "payments-api")
        let other = try TestStore.project(in: store, named: "payments-web")
        let workspace = try #require(store.addWorkspace(name: "Payments",
                                                        projectIDs: [lead.id, other.id],
                                                        leadProjectID: lead.id))
        let notices = [noticed("build", .running, project: "lantern-api",
                               workspaceID: workspace.id)]

        let entries = SidebarNotices.menu(notices, store: store,
                                          isSelected: { _ in false }, open: { _ in })

        let item = try #require(menuItem(entries.first))
        #expect(item.subtitle == "Payments")
    }

    // The menu doubles as a way back to where you already are, so the current session is
    // ticked rather than looking like somewhere else to go.
    @Test func theSessionAlreadyOpenIsTicked() throws {
        let (store, _) = TestStore.make()
        let here = noticed("here", .running)
        let elsewhere = noticed("elsewhere", .running)

        let entries = SidebarNotices.menu([here, elsewhere], store: store,
                                          isSelected: { $0.id == here.session.id },
                                          open: { _ in })

        let open = try #require(menuItem(entries.first))
        let other = try #require(menuItem(entries.last))

        #expect(open.checked)
        #expect(!other.checked)
    }

    // Every row opens the session it names, not the one beside it.
    @Test func eachRowOpensItsOwnSession() throws {
        let (store, _) = TestStore.make()
        let first = noticed("first", .running)
        let second = noticed("second", .running)
        var opened: [UUID] = []

        let entries = SidebarNotices.menu([first, second], store: store,
                                          isSelected: { _ in false },
                                          open: { opened.append($0.id) })

        let lastRow = try #require(menuItem(entries.last))
        let openLastRow = try #require(lastRow.handler)
        openLastRow()

        #expect(opened == [second.session.id])
    }

    private func menuItem(_ entry: MenuEntry?) -> MenuItem? {
        guard case .item(let item) = entry else { return nil }
        return item
    }
}
