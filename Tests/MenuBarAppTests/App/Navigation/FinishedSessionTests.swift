import Foundation
import Testing
@testable import MenuBarApp

// The marker that says a session stopped working while the user was elsewhere: what
// sets it, and what is allowed to clear it.
@MainActor
struct FinishedSessionTests {
    private let store: ProjectStore
    private let scratch: ScratchDirectory
    private let project: Project

    init() throws {
        (store, scratch) = TestStore.make()
        project = try TestStore.project(in: store)
    }

    @Test func marksASessionThatEndedOutOfSight() {
        let background = store.newSession(in: project.id)
        let open = store.newSession(in: project.id)

        store.selection = .session(open.id)
        store.noteTurnEnded(for: background.id)

        #expect(store.hasFinished(background.id))
        #expect(store.unreadCount(in: project.id) == 1)
    }

    // The result of the session being read is already on screen, so there is nothing to
    // come back to.
    // A second opinion ends outside any turn but leaves something to read all the same.
    @Test func aSecondOpinionMarksASessionOutOfSightAndSaysSo() {
        let background = store.newSession(in: project.id)
        let open = store.newSession(in: project.id)

        store.selection = .session(open.id)
        store.noteSecondOpinionReady(for: background.id)

        #expect(store.hasFinished(background.id))
        #expect(store.hasSecondOpinionReady(background.id))

        // A turn ending afterwards is the newer news.
        store.noteTurnEnded(for: background.id)
        #expect(store.hasSecondOpinionReady(background.id) == false)
    }

    @Test func aSecondOpinionLeavesTheSessionOnScreenAlone() {
        let open = store.newSession(in: project.id)

        store.selection = .session(open.id)
        store.noteSecondOpinionReady(for: open.id)

        #expect(store.hasFinished(open.id) == false)
        #expect(store.hasSecondOpinionReady(open.id) == false)
    }

    // The agent is idle while a reviewer works, so the row names the reviewer's work
    // instead of reading IDLE, and says it is done once it is.
    @Test func aRunningSecondOpinionNamesItselfAndMarksTheSessionWhenItEnds() async {
        let preferences = TestPreferences()
        let runner = SessionRunner(store: store, preferences: preferences.store, paths: [:])
        runner.opinions.onSettled = { [store] in runner.secondOpinionSettled($0) }
        let background = store.newSession(in: project.id)
        let open = store.newSession(in: project.id)
        store.selection = .session(open.id)
        let subject = ChatSecondOpinion.Subject(kind: .plan, id: "plan:1", text: "1. Retry.", request: "Plan it.")
        let request = ChatSecondOpinion.Request(subject: subject, reading: .init(), conversation: "",
                                                directories: ["/repo"], executable: "/bin/codex")
        let release = AsyncStream<Void>.makeStream()
        runner.opinions.askReviewer = { [stream = release.stream] _, _, _, _ in
            for await _ in stream { break }
            return .success(.init(verdict: .agrees, summary: "Sound.", points: []))
        }

        runner.opinions.ask(request, reviewers: [.init(agent: .codex)], executables: [.codex: "/bin/codex"],
                            anchor: nil, in: background.id)
        #expect(runner.rowActivity(background.id, live: background.id) == .secondOpinion)
        #expect(store.hasFinished(background.id) == false)

        release.continuation.yield()
        #expect(await waitUntil { !runner.isAskingSecondOpinion(background.id) })
        #expect(runner.rowActivity(background.id, live: background.id) == nil)
        #expect(store.hasSecondOpinionReady(background.id))
    }

    @Test func leavesTheSessionOnScreenAlone() {
        let open = store.newSession(in: project.id)

        store.selection = .session(open.id)
        store.noteTurnEnded(for: open.id)

        #expect(store.hasFinished(open.id) == false)
        #expect(store.unreadCount(in: project.id) == 0)
    }

    @Test func marksTheSelectedSessionWhenTheAppIsInactive() {
        let open = store.newSession(in: project.id)

        store.applicationWillResignActive()
        store.noteTurnEnded(for: open.id)

        #expect(store.hasFinished(open.id))
        #expect(store.unreadCount(in: project.id) == 1)
    }

    @Test func openingTheSessionClearsIt() {
        let background = store.newSession(in: project.id)
        let open = store.newSession(in: project.id)

        store.selection = .session(open.id)
        store.noteTurnEnded(for: background.id)
        store.selection = .session(background.id)

        #expect(store.hasFinished(background.id) == false)
        #expect(store.unreadCount(in: project.id) == 0)
    }

    @Test func openingAReviewCarriesItsDestination() {
        let session = store.newSession(in: project.id)

        store.selectHome()
        store.selectSession(session.id, destination: .changes)

        #expect(store.selection == .session(session.id))
        #expect(store.sessionOpenRequest
            == SessionOpenRequest(sessionID: session.id, destination: .changes))
    }

    @Test func openingAnOrdinarySessionTargetsTheConversation() {
        let first = store.newSession(in: project.id)
        let second = store.newSession(in: project.id)

        store.selectSession(first.id, destination: .changes)
        store.selectSession(second.id)

        #expect(store.sessionOpenRequest
            == SessionOpenRequest(sessionID: second.id, destination: .conversation))
    }

    @Test func leavesASessionBeingReadOnMobileAlone() {
        let session = store.newSession(in: project.id)

        store.hold(session.id, for: .remote)
        store.noteTurnEnded(for: session.id)

        #expect(store.hasFinished(session.id) == false)
        #expect(store.unreadCount(in: project.id) == 0)
    }

    @Test func openingTheSessionOnMobileClearsIt() {
        let session = store.newSession(in: project.id)

        store.noteTurnEnded(for: session.id)
        store.hold(session.id, for: .remote)

        #expect(store.hasFinished(session.id) == false)
        #expect(store.unreadCount(in: project.id) == 0)
    }

    // Looking at another session, or at no session at all, is not reading this one.
    @Test func staysUntilThatSessionIsOpened() {
        let background = store.newSession(in: project.id)
        let other = store.newSession(in: project.id)

        store.selection = .session(other.id)
        store.noteTurnEnded(for: background.id)
        store.selection = nil
        store.selection = .session(other.id)

        #expect(store.hasFinished(background.id))
    }

    @Test func deletingTheSessionTakesItsMarkWithIt() {
        let background = store.newSession(in: project.id)
        let open = store.newSession(in: project.id)

        store.selection = .session(open.id)
        store.noteTurnEnded(for: background.id)
        store.removeSession(background.id)

        #expect(store.unreadCount(in: project.id) == 0)
    }
}
