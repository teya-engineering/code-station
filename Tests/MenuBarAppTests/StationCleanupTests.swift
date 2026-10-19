import Foundation
import Testing
@testable import CodeStationCore

// Part of the station contract (see StationContract.swift): repairing and tidying the
// station from any front end. A lost worktree is rebuilt from the session's warning, the
// orphaned worktrees the host's upkeep found are pruned once the person has read them,
// and old sessions are reviewed with what deleting each would cost, then deleted.
@MainActor
struct StationCleanupTests {

    // MARK: - Rebuild

    // A worktree removed outside the app is offered back: reading the rebuild names where
    // its commits come from, and rebuilding puts the folder back with them, so the
    // session's warning goes. With nothing lost there is nothing to rebuild.
    @Test(arguments: StationImplementation.allCases)
    func aLostWorktreeIsRebuiltWithItsCommits(_ kind: StationImplementation) async throws {
        let repo = try GitRepo()
        let scratch = ScratchDirectory(prefix: "station-cleanup")
        let checkout = scratch.path("checkout")
        try repo.git("worktree", "add", "-q", checkout.path, "-b", "code-station/abc")
        try "work".write(to: checkout.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        try GitRepo.run(["add", "."], in: checkout)
        try GitRepo.run(["commit", "-qm", "the work"], in: checkout)
        try FileManager.default.removeItem(at: checkout)

        let store = ProjectStore(storeURL: scratch.path("projects.json"))
        let project = try #require(store.addProject(at: repo.url))
        let session = store.newSession(in: project.id, worktreePath: checkout.path,
                                       worktreeBranch: "code-station/abc")
        let station = StationCommands(store: store, runner: SessionRunner(host: RecordingHost()),
                                      refreshInterval: .milliseconds(50))
        let commands = kind.connect(to: station)
        let id = session.id.uuidString

        let warning = try #require(try await commands.openSession(id)?.snapshot.header.warnings?.first)
        #expect(warning.canRebuild)
        await commands.closeSession(id)

        let offer = try await commands.readRebuild(id)
        #expect(offer.title == "Rebuild the missing folder?")
        #expect(offer.message == "code-station/abc is still on this machine, so its commits come back. "
            + "Anything never committed is gone.")
        #expect(offer.action == "Rebuild")

        try await commands.rebuild(id)

        #expect(try String(contentsOf: checkout.appendingPathComponent("note.txt"), encoding: .utf8) == "work")
        #expect(try GitRepo.run(["log", "-1", "--pretty=%s"], in: checkout) == "the work")
        #expect(try await commands.openSession(id)?.snapshot.header.warnings == [])
        await #expect(throws: StationRefusal.self) { try await commands.readRebuild(id) }
        await #expect(throws: StationRefusal.self) { try await commands.rebuild(id) }
        await #expect(throws: StationRefusal.self) { try await commands.readRebuild(UUID().uuidString) }
    }

    // MARK: - Orphaned worktrees

    // The orphans the upkeep found are read with their project, branch, place and size,
    // asked about with every one named, and pruned once confirmed. The strip's count
    // follows. A removal git refuses is refused with git's reason.
    @Test(arguments: StationImplementation.allCases)
    func orphanedWorktreesArePrunedOnceConfirmed(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-cleanup")
        let store = ProjectStore(storeURL: scratch.path("projects.json"))
        let folder = scratch.path("alpha")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try #require(store.addProject(at: folder))
        let disk = OrphanDisk()
        var refusing: Set<String> = []
        let monitor = OrphanedWorktreeMonitor(
            discover: { @MainActor _, _ in
                [GitWorktree.Orphaned(path: "/worktrees/one", branch: "code-station/one", allocatedBytes: 4_096),
                 GitWorktree.Orphaned(path: "/worktrees/two", branch: nil, allocatedBytes: 0)]
                    .filter { !disk.removed.contains($0.path) }
            },
            remove: { @MainActor orphan in
                if refusing.contains(orphan.path) { return .failure(GitWorktree.Failure(message: "git said no")) }
                disk.removed.append(orphan.path)
                return .success(())
            })
        let station = StationCommands(store: store, runner: SessionRunner(host: RecordingHost()),
                                      refreshInterval: .milliseconds(50))
        let upkeep = StationUpkeep(station: station, orphanedWorktrees: monitor,
                                   preferences: StationBackgroundTests.preferences(), pace: .test)
        upkeep.start()
        defer { upkeep.stop() }
        let commands = kind.connect(to: station)
        #expect(await eventually { try await commands.listDirectory().cleanup?.orphanedWorktrees == 2 })

        let orphans = try await commands.readOrphanedWorktrees()
        #expect(orphans.map(\.path) == ["/worktrees/one", "/worktrees/two"])
        #expect(orphans.first == RemoteOrphanedWorktree(projectName: "alpha", path: "/worktrees/one",
                                                        branch: "code-station/one", bytes: 4_096))
        let impact = RemoteOrphanedWorktree.pruneImpact(orphans)
        #expect(impact.title == "Prune 2 orphaned worktrees?")
        #expect(impact.rows.map(\.title) == ["alpha · code-station/one", "alpha · Detached HEAD"])
        #expect(impact.rows.allSatisfy { !$0.kept })
        #expect(impact.rows.first?.detail == "/worktrees/one · 4 KB")
        #expect(impact.action == "Prune all")

        refusing = ["/worktrees/two"]
        await #expect(throws: StationRefusal("git said no")) {
            try await commands.pruneOrphanedWorktrees(paths: orphans.map(\.path))
        }
        #expect(disk.removed == ["/worktrees/one"])
        #expect(await eventually { try await commands.listDirectory().cleanup?.orphanedWorktrees == 1 })

        refusing = []
        try await commands.pruneOrphanedWorktrees(paths: ["/worktrees/two"])
        #expect(disk.removed == ["/worktrees/one", "/worktrees/two"])
        #expect(await eventually { try await commands.listDirectory().cleanup?.orphanedWorktrees == 0 })
        #expect(try await commands.readOrphanedWorktrees().isEmpty)
    }

    // A host that does not look after worktrees has none to show and refuses to prune.
    @Test(arguments: StationImplementation.allCases)
    func aHostWithNoUpkeepHasNoOrphansToPrune(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-cleanup")
        let store = ProjectStore(storeURL: scratch.path("projects.json"))
        let station = StationCommands(store: store, runner: SessionRunner(host: RecordingHost()))
        let commands = kind.connect(to: station)

        #expect(try await commands.readOrphanedWorktrees().isEmpty)
        await #expect(throws: StationRefusal.self) {
            try await commands.pruneOrphanedWorktrees(paths: ["/worktrees/one"])
        }
    }

    // MARK: - Old sessions

    // The review lists the sessions past the shared age by project, each with what
    // deleting it costs: history alone arrives ticked, uncommitted work does not. A
    // snoozed project is listed with its snooze rather than its sessions' costs. Deleting
    // takes only the sessions chosen; deleting saved work asks with what goes.
    @Test(arguments: StationImplementation.allCases)
    func oldSessionsAreReviewedWithTheirCostsAndDeleted(_ kind: StationImplementation) async throws {
        let repo = try GitRepo()
        let scratch = ScratchDirectory(prefix: "station-cleanup")
        let store = ProjectStore(storeURL: scratch.path("projects.json"))
        let project = try #require(store.addProject(at: repo.url))
        let otherFolder = scratch.path("other")
        try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
        let other = try #require(store.addProject(at: otherFolder))
        let checkout = scratch.path("dirty")
        try repo.git("worktree", "add", "-q", checkout.path, "-b", "code-station/dirty")
        try "hello\nmore\n".write(to: checkout.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let tenDaysAgo = Date().addingTimeInterval(-10 * 86_400)
        let quiet = store.newSession(in: project.id)
        store.renameSession(quiet.id, to: "Quiet")
        store.append(ChatMessage(role: .user, text: "Old", date: tenDaysAgo.addingTimeInterval(-120)), to: quiet.id)
        let dirty = store.newSession(in: project.id, worktreePath: checkout.path,
                                     worktreeBranch: "code-station/dirty")
        store.renameSession(dirty.id, to: "Dirty")
        store.append(ChatMessage(role: .user, text: "Old", date: tenDaysAgo.addingTimeInterval(-60)), to: dirty.id)
        let snoozed = store.newSession(in: other.id)
        store.append(ChatMessage(role: .user, text: "Old", date: tenDaysAgo), to: snoozed.id)
        store.snoozeCleanup(forProject: other.id)
        let recent = store.newSession(in: project.id)
        store.append(ChatMessage(role: .user, text: "New", date: Date()), to: recent.id)

        let preferences = StationBackgroundTests.preferences()
        Preferences.setOldSessionDays(7, in: preferences)
        let station = StationCommands(store: store, runner: SessionRunner(host: RecordingHost()),
                                      refreshInterval: .milliseconds(50), preferences: preferences)
        let commands = kind.connect(to: station)

        let review = try await commands.readOldSessions()
        #expect(review.days == 7)
        #expect(review.groups.map(\.name) == [project.name, other.name])
        let rows = try #require(review.groups.first?.sessions)
        #expect(rows.map(\.title) == ["Quiet", "Dirty"])
        #expect(rows[0].cost == "history only")
        #expect(rows[0].isTicked && rows[0].canSelect)
        #expect(rows[0].detail == "last turn 10 days ago · no worktree")
        #expect(rows[1].cost == "would lose work")
        #expect(!rows[1].isTicked && rows[1].canSelect && rows[1].losesWork)
        #expect(rows[1].detail.hasPrefix("last turn 10 days ago · ⑂ code-station/dirty · +"), "\(rows[1].detail)")
        #expect(rows[1].detail.hasSuffix("uncommitted"), "\(rows[1].detail)")
        #expect(review.groups[1].snoozedUntil != nil)
        #expect(review.notices == ["One session has uncommitted changes in its worktree, so it is left unticked. "
            + "Deleting it loses those changes; its branch survives if git considers that safe."])

        let ask = try #require(RemoteOldSessions.deletionImpact(of: [rows[1]]))
        #expect(ask.title == "Delete a session with saved work?")
        #expect(ask.rows.map(\.title) == ["1 worktree with uncommitted changes"])
        #expect(ask.warning == "This work cannot be restored.")
        #expect(ask.action == "Delete 1 session")
        #expect(RemoteOldSessions.deletionImpact(of: [rows[0]]) == nil)

        try await commands.deleteOldSessions([quiet.id.uuidString])

        let left = try await commands.listDirectory().projects.flatMap { $0.sessions.map(\.id) }
        #expect(!left.contains(quiet.id.uuidString))
        #expect(left.contains(dirty.id.uuidString) && left.contains(recent.id.uuidString))
        #expect(try await commands.readOldSessions().groups.first?.sessions.map(\.title) == ["Dirty"])
        await #expect(throws: StationRefusal.self) {
            try await commands.deleteOldSessions([UUID().uuidString])
        }
        // A session that is not old is not this screen's to delete.
        await #expect(throws: StationRefusal.self) {
            try await commands.deleteOldSessions([recent.id.uuidString])
        }
    }
}
