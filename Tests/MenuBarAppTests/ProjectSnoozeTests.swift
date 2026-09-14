import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MenuBarApp

// Snooze gives one project an extra day before its old sessions are offered for deletion
// or taken by the unattended sweep. What matters here is that a snooze really does take
// the project out of every count that leads to a deletion, and that it comes back on its
// own without anyone having to press anything.
struct ProjectSnoozeTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    private func session(daysAgo: Double, project: UUID) -> ChatSession {
        var session = ChatSession(projectID: project)
        session.createdAt = now.addingTimeInterval(-daysAgo * day)
        return session
    }

    // MARK: - The deadline

    @Test func firstPressBuysOneDayFromNow() {
        #expect(ProjectSnooze.extended(nil, now: now) == now.addingTimeInterval(day))
    }

    // A second press extends the deadline the project already has instead of restarting
    // from today, so two presses are worth two days rather than one.
    @Test func eachPressAddsADayToTheDeadlineAlreadySet() {
        let first = ProjectSnooze.extended(nil, now: now)
        let second = ProjectSnooze.extended(first, now: now)

        #expect(second == now.addingTimeInterval(2 * day))
        #expect(ProjectSnooze.remainingDays(until: second, now: now) == 2)
        #expect(ProjectSnooze.title("acquiring-api", until: second, now: now)
                == "acquiring-api snoozed for 2 days")
    }

    // An app that was closed over the weekend must not hand back a deadline further out
    // than one day, so an expired snooze is counted from now rather than from itself.
    @Test func anExpiredDeadlineIsNotExtendedFromThePast() {
        let stale = now.addingTimeInterval(-5 * day)
        #expect(ProjectSnooze.extended(stale, now: now) == now.addingTimeInterval(day))
    }

    @Test func aDeadlineInThePastIsNoLongerActive() {
        #expect(!ProjectSnooze.isActive(nil, now: now))
        #expect(!ProjectSnooze.isActive(now.addingTimeInterval(-1), now: now))
        #expect(ProjectSnooze.isActive(now.addingTimeInterval(1), now: now))
    }

    // The badge counts the day that is still running rather than the ones fully left, so
    // it never reads as nothing while the sessions are still held back.
    @Test func theBadgeRoundsThePartDayUp() {
        #expect(ProjectSnooze.badge(until: now.addingTimeInterval(day), now: now) == "1d")
        #expect(ProjectSnooze.badge(until: now.addingTimeInterval(0.1 * day), now: now) == "1d")
        #expect(ProjectSnooze.badge(until: now.addingTimeInterval(1.2 * day), now: now) == "2d")
    }

    @Test func oneDayReadsAsTomorrowRatherThanAsACount() {
        let tomorrow = ProjectSnooze.extended(nil, now: now)
        #expect(ProjectSnooze.title("code-station", until: tomorrow, now: now)
                == "code-station snoozed until tomorrow")
    }

    // MARK: - What counts as old

    @Test func aSnoozedProjectsSessionsAreNotOld() {
        let snoozed = UUID()
        let awake = UUID()
        let sessions = [session(daysAgo: 9, project: snoozed),
                        session(daysAgo: 8, project: awake)]
        let deadline = now.addingTimeInterval(day)

        let old = OldSessions.olderThan(7, in: sessions, now: now,
                                        snoozedUntil: { $0.projectID == snoozed ? deadline : nil })

        #expect(old.map(\.id) == [sessions[1].id])
    }

    // Expiry needs no cleanup pass of its own: the same deadline simply stops matching
    // once the day it named has gone by.
    @Test func anExpiredSnoozeHandsItsSessionsBackWithoutBeingCleared() {
        let sessions = [session(daysAgo: 9, project: UUID())]
        let deadline = now.addingTimeInterval(day)
        let resolve: OldSessions.SnoozeDeadline = { _ in deadline }

        #expect(OldSessions.olderThan(7, in: sessions, now: now, snoozedUntil: resolve).isEmpty)
        #expect(OldSessions.olderThan(7, in: sessions, now: deadline.addingTimeInterval(1),
                                      snoozedUntil: resolve).count == 1)
    }

    // The strip's countdown has to wake on the minute a project comes back, not at the
    // next hourly pass, so the wake date is one of the answers this can give.
    @Test func theNextChangeCanBeASnoozeRunningOut() {
        let wakesAt = now.addingTimeInterval(day)
        let sessions = [session(daysAgo: 9, project: UUID())]

        #expect(OldSessions.nextOldAt(7, in: sessions, now: now,
                                      snoozedUntil: { _ in wakesAt }) == wakesAt)
    }

    // A session still on its way to being old is the earlier answer of the two, and the
    // one that has to be picked.
    @Test func theNextChangeIsWhicheverComesFirst() {
        let sessions = [session(daysAgo: 6.5, project: UUID())]
        let wakesAt = now.addingTimeInterval(5 * day)

        #expect(OldSessions.nextOldAt(7, in: sessions, now: now,
                                      snoozedUntil: { _ in wakesAt })
                == now.addingTimeInterval(12 * 3_600))
    }

    // MARK: - The sweep

    @MainActor
    @Test func theSweepLeavesASnoozedProjectAlone() {
        let snoozed = UUID()
        let sessions = [session(daysAgo: 9, project: snoozed),
                        session(daysAgo: 8, project: UUID())]
        let deadline = now.addingTimeInterval(day)

        let due = OldSessionSweep.due(days: 7, in: sessions, now: now,
                                      isBusy: { _ in false }, isOpen: { _ in false },
                                      snoozedUntil: { $0.projectID == snoozed ? deadline : nil })

        #expect(due.map(\.id) == [sessions[1].id])
    }
}

// The snooze is kept with the rest of the project record, so it survives relaunch and is
// set and cleared through the store the same way pinning is.
@MainActor
struct ProjectSnoozeStoreTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func snoozingAndWakingAProjectThroughTheStore() throws {
        let (store, _) = TestStore.make()
        let project = try TestStore.project(in: store)

        store.snoozeCleanup(forProject: project.id, now: now)
        #expect(store.project(project.id)?.snoozedUntil == now.addingTimeInterval(86_400))

        store.snoozeCleanup(forProject: project.id, now: now)
        #expect(store.project(project.id)?.snoozedUntil == now.addingTimeInterval(2 * 86_400))

        // One press puts it back, with no dialog: nothing was destroyed.
        store.wakeCleanup(forProject: project.id)
        #expect(store.project(project.id)?.snoozedUntil == nil)
    }

    @Test func aSnoozeSurvivesReloadingTheIndex() throws {
        let (store, scratch) = TestStore.make()
        let project = try TestStore.project(in: store)
        store.snoozeCleanup(forProject: project.id, now: now)

        let reloaded = ProjectStore(storeURL: scratch.path("projects.json"))

        #expect(reloaded.project(project.id)?.snoozedUntil == now.addingTimeInterval(86_400))
    }

    // A session's deadline is the one on the project it runs in, which is the project its
    // rows are grouped under in the review sheet.
    @Test func aSessionTakesTheDeadlineOfItsProject() throws {
        let (store, _) = TestStore.make()
        let project = try TestStore.project(in: store)
        let session = store.newSession(in: project.id)

        #expect(store.snoozeDeadline(for: session) == nil)
        store.snoozeCleanup(forProject: project.id, now: now)
        #expect(store.snoozeDeadline(for: session) == now.addingTimeInterval(86_400))
    }
}

// The review sheet rendered for real, so the grouping and the fold are exercised rather
// than described. What is checked is the shape the sheet takes, since the counts behind
// it belong to the rules above.
@MainActor
struct OldSessionsSheetTests {

    private func sheet(_ store: ProjectStore) -> NSWindow {
        let settings = AppSettings(
            agentAvatarURL: store.storeURL.deletingLastPathComponent()
                .appendingPathComponent("avatar.png"),
            preferences: UserDefaults(suiteName: "snooze-\(UUID().uuidString)") ?? .standard)
        let view = OldSessionsView()
            .environment(store)
            .environment(SessionRunner(paths: [:]))
            .environment(DialogPresenter())
            .environment(settings)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 760),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view)
        window.layoutIfNeeded()
        return window
    }

    private func agedSessions(_ count: Int, in project: Project, store: ProjectStore) {
        for _ in 0..<count {
            let session = store.newSession(in: project.id)
            store.append(ChatMessage(role: .user, text: "Old work",
                                     date: Date().addingTimeInterval(-9 * 86_400)),
                         to: session.id)
        }
    }

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    }

    // Three rows give way to one folded card, so the sheet gets shorter. The group header
    // stays either way, which is what keeps the snooze on screen and reversible.
    @Test func snoozingAProjectFoldsItsRowsIntoOneCard() throws {
        let (store, _) = TestStore.make()
        let alpha = try TestStore.project(in: store, named: "alpha")
        let beta = try TestStore.project(in: store, named: "beta")
        agedSessions(3, in: alpha, store: store)
        agedSessions(2, in: beta, store: store)

        let window = sheet(store)
        let content = try #require(window.contentView)
        settle()
        let listed = content.fittingSize.height
        #expect(listed > 0)

        store.snoozeCleanup(forProject: alpha.id)
        settle()
        let folded = content.fittingSize.height

        #expect(folded < listed)

        // Waking puts the rows back exactly as they were.
        store.wakeCleanup(forProject: alpha.id)
        settle()
        #expect(content.fittingSize.height == listed)
    }

    // Every project snoozed is still a sheet worth showing: the groups stay, each with its
    // way back, so nothing has to be remembered to undo it.
    @Test func snoozingEveryProjectLeavesTheGroupsOnScreen() throws {
        let (store, _) = TestStore.make()
        let alpha = try TestStore.project(in: store, named: "alpha")
        agedSessions(2, in: alpha, store: store)

        let window = sheet(store)
        let content = try #require(window.contentView)
        settle()
        let listed = content.fittingSize.height

        store.snoozeCleanup(forProject: alpha.id)
        settle()
        let snoozed = content.fittingSize.height

        // The folded card and the note that nothing is being cleared, rather than an
        // empty sheet with no way back.
        #expect(snoozed > 0)
        #expect(snoozed != listed)

        store.wakeCleanup(forProject: alpha.id)
        settle()
        #expect(content.fittingSize.height == listed)
    }
}
