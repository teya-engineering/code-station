import Foundation
import Testing
@testable import CodeStationCore

// Part of the station contract (see StationContract.swift): the directory carries the
// GUI's sidebar tree alongside the phone's project list. Containers are projects, tasks
// and workspaces, in the order the shared sort preference gives with pinned ones first;
// workspace sessions sit under their workspace, and pins and unread marks come along.
@MainActor
struct StationDirectoryTreeTests {

    @Test(arguments: StationImplementation.allCases)
    func theDirectoryListsContainersWithKindPinsUnreadAndWorkspaceSessions(
        _ kind: StationImplementation
    ) async throws {
        let scratch = ScratchDirectory(prefix: "station-tree")
        let index = scratch.path("projects.json")
        let preferences = try #require(UserDefaults(suiteName: "station-tree-\(UUID().uuidString)"))
        Preferences.setProjectSort(.name, in: preferences)
        Preferences.setProjectGrouping(.kind, in: preferences)
        do {
            let seed = ProjectStore(storeURL: index)
            let alpha = try project(named: "alpha", in: seed, under: scratch)
            let beta = try project(named: "beta", in: seed, under: scratch)
            let nightly = try seed.addTask(named: "nightly", prompt: "Check the build",
                                           in: scratch.path("tasks")).get()
            var schedule = TaskSchedule()
            schedule.isEnabled = true
            schedule.interval = 15
            schedule.intervalUnit = .minutes
            schedule.restart(at: Date())
            var spec = try #require(nightly.task)
            spec.schedule = schedule
            seed.setTaskSpec(spec, for: nightly.id)
            let both = try #require(seed.addWorkspace(name: "both", projectIDs: [alpha.id, beta.id],
                                                      leadProjectID: alpha.id))
            let fix = try seed.insertSession(in: alpha.id, seed: .init(agent: .claudeCode)).get()
            seed.renameSession(fix.id, to: "Fix the bug")
            reply(at: 1_000, in: fix.id, of: seed)
            seed.setMarkedUnread(true, for: fix.id)
            let docs = try seed.insertSession(in: beta.id, seed: .init(agent: .claudeCode)).get()
            seed.renameSession(docs.id, to: "Write the docs")
            reply(at: 2_000, in: docs.id, of: seed)
            let cross = try seed.insertSession(in: both.id, projects: [SessionProject(projectID: alpha.id),
                                                                      SessionProject(projectID: beta.id)],
                                               seed: .init(agent: .claudeCode)).get()
            seed.renameSession(cross.id, to: "Cross repo change")
            reply(at: 3_000, in: cross.id, of: seed)
            seed.setPinned(true, forProject: beta.id)
            #expect(seed.save())
        }

        let station = StationCommands.start(host: RecordingHost(), storeURL: index, preferences: preferences)
        let commands = kind.connect(to: station)
        let directory = try await commands.listDirectory()

        #expect(directory.arrangement == RemoteArrangement(sort: .name, grouping: .kind))
        let containers = try #require(directory.containers)
        // A-Z, with the pinned project first.
        #expect(containers.map(\.name) == ["beta", "alpha", "both", "nightly"])
        #expect(containers.map(\.kind) == [.project, .project, .workspace, .task])
        #expect(containers.map(\.isPinned) == [true, false, false, false])
        #expect(containers.map { $0.sessions.map(\.title) }
                == [["Write the docs"], ["Fix the bug"], ["Cross repo change"], []])
        #expect(containers.map(\.unread) == [0, 1, 0, 0])
        #expect(containers[1].sessions.first?.isUnread == true)
        #expect(containers[0].sessions.first?.isUnread == false)
        #expect(containers[2].path == "alpha + beta")
        // A task carries its timer, filled as the phone's project list fills it.
        let timer = try #require(containers[3].schedule)
        #expect(timer.isActive)
        #expect(timer.nextRunAt != nil)
        #expect(timer == directory.projects.first { $0.name == "nightly" }?.schedule)
        #expect(containers[0...2].allSatisfy { $0.schedule == nil })
        // The phone's list is as it was: the workspace session under the project leading it.
        #expect(directory.projects.first { $0.name == "alpha" }?.sessions.map(\.title)
                == ["Cross repo change", "Fix the bug"])

        // The sort is the shared preference, read again for each list.
        Preferences.setProjectSort(.lastUsed, in: preferences)
        let byLastUse = try #require(try await commands.listDirectory().containers)
        #expect(byLastUse.map(\.name) == ["beta", "both", "alpha", "nightly"])
    }

    // A pinned session comes first in its container and pins the container too.
    @Test(arguments: StationImplementation.allCases)
    func aPinnedSessionComesFirstAndLiftsItsContainer(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-tree")
        let index = scratch.path("projects.json")
        let preferences = try #require(UserDefaults(suiteName: "station-tree-\(UUID().uuidString)"))
        do {
            let seed = ProjectStore(storeURL: index)
            _ = try project(named: "alpha", in: seed, under: scratch)
            let beta = try project(named: "beta", in: seed, under: scratch)
            let old = try seed.insertSession(in: beta.id, seed: .init(agent: .claudeCode)).get()
            seed.renameSession(old.id, to: "Old one")
            reply(at: 1_000, in: old.id, of: seed)
            let new = try seed.insertSession(in: beta.id, seed: .init(agent: .claudeCode)).get()
            seed.renameSession(new.id, to: "New one")
            reply(at: 2_000, in: new.id, of: seed)
            seed.setPinned(true, forSession: old.id)
            #expect(seed.save())
        }

        let station = StationCommands.start(host: RecordingHost(), storeURL: index, preferences: preferences)
        let containers = try #require(try await kind.connect(to: station).listDirectory().containers)

        #expect(containers.map(\.name) == ["beta", "alpha"])
        #expect(containers[0].sessions.map(\.title) == ["Old one", "New one"])
        #expect(containers[0].sessions.map(\.isPinned) == [true, false])
        #expect(containers[0].isPinned == false)
    }

    // What a card says beyond its state word: the activity line and the chips (WT,
    // MIXED, TROUBLESHOOT, uncommitted), and on each container how many of its sessions
    // need the person and how many are running, for the marks a folded row wears.
    @Test(arguments: StationImplementation.allCases)
    func sessionRowsCarryTheActivityLineChipsAndContainerCounts(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-tree")
        let index = scratch.path("projects.json")
        let preferences = try #require(UserDefaults(suiteName: "station-tree-\(UUID().uuidString)"))
        let repo = try GitRepo()
        try repo.write("dirty.txt", "not committed")
        do {
            let seed = ProjectStore(storeURL: index)
            let alpha = try #require(seed.addProject(at: repo.url))
            let beta = try project(named: "beta", in: seed, under: scratch)
            let both = try #require(seed.addWorkspace(name: "both", projectIDs: [alpha.id, beta.id],
                                                      leadProjectID: alpha.id))
            let plain = try seed.insertSession(in: alpha.id, seed: .init(agent: .claudeCode)).get()
            seed.renameSession(plain.id, to: "Plain")
            seed.append(ChatMessage(role: .assistant, tools: [
                ToolUse(id: "shell", name: "Bash", input: #"{"command":"swift build"}"#, result: "ok"),
            ], date: Date(timeIntervalSince1970: 1_000)), to: plain.id)
            seed.setMarkedUnread(true, for: plain.id)
            let isolated = try seed.insertSession(in: beta.id, worktreePath: scratch.path("wt").path,
                                                  worktreeBranch: "feature",
                                                  seed: .init(agent: .claudeCode, isTroubleshooting: true)).get()
            seed.renameSession(isolated.id, to: "Isolated")
            reply(at: 2_000, in: isolated.id, of: seed)
            let mixed = try seed.insertSession(in: both.id, projects: [
                SessionProject(projectID: alpha.id, worktreePath: scratch.path("wt2").path, worktreeBranch: "x"),
                SessionProject(projectID: beta.id),
            ], seed: .init(agent: .claudeCode)).get()
            seed.renameSession(mixed.id, to: "Mixed")
            reply(at: 3_000, in: mixed.id, of: seed)
            #expect(seed.save())
        }

        let station = StationCommands.start(host: RecordingHost(), storeURL: index, preferences: preferences)
        let commands = kind.connect(to: station)
        func row(_ title: String, in directory: RemoteDirectory) -> RemoteSessionRow? {
            directory.containers?.flatMap(\.sessions).first { $0.title == title }
        }
        // Git is asked off the main thread, so the uncommitted mark comes in a moment later.
        var directory = try await commands.listDirectory()
        let deadline = SuspendingClock.now + .seconds(30)
        while row("Plain", in: directory)?.hasUncommittedChanges != true, SuspendingClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            directory = try await commands.listDirectory()
        }

        let plain = try #require(row("Plain", in: directory))
        #expect(plain.activity == "last: Bash · swift build", "\(plain.activity ?? "nil")")
        #expect(plain.worktree == nil)
        #expect(plain.isTroubleshooting == false)
        #expect(plain.hasUncommittedChanges == true)
        let isolated = try #require(row("Isolated", in: directory))
        #expect(isolated.worktree == .all)
        #expect(isolated.isTroubleshooting)
        #expect(isolated.hasUncommittedChanges == false)
        // A card with nothing to say draws no line.
        #expect(isolated.activity == nil)
        #expect(row("Mixed", in: directory)?.worktree == .partial)

        let containers = try #require(directory.containers)
        let alpha = try #require(containers.first { $0.sessions.contains { $0.title == "Plain" } })
        #expect(alpha.needsYou == 1)
        #expect(alpha.running == 0)
        #expect(containers.first { $0.name == "both" }?.needsYou == 0)
    }

    // The folding the GUI remembers and the number of cards it shows per container come
    // with the tree, so a front end starts from the same picture.
    @Test(arguments: StationImplementation.allCases)
    func theArrangementCarriesTheStoredFoldingAndSessionsShown(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-tree")
        let index = scratch.path("projects.json")
        let preferences = try #require(UserDefaults(suiteName: "station-tree-\(UUID().uuidString)"))
        let station = StationCommands.start(host: RecordingHost(), storeURL: index, preferences: preferences)
        let commands = kind.connect(to: station)

        let plain = try #require(try await commands.listDirectory().arrangement)
        #expect(plain.sessionLimit == 4)
        #expect(plain.collapsedSections.isEmpty)
        #expect(plain.expansion.isEmpty)

        let folded = UUID()
        let opened = UUID()
        Preferences.setSidebarSessionLimit(7, in: preferences)
        Preferences.setCollapsedSidebarGroups([.tasks], in: preferences)
        Preferences.setSidebarExpansion([folded: false, opened: true], in: preferences)
        let stored = try #require(try await commands.listDirectory().arrangement)
        #expect(stored.sessionLimit == 7)
        #expect(stored.collapsedSections == [.tasks])
        #expect(stored.expansion == [folded.uuidString: false, opened.uuidString: true])

        // Out of the GUI's range, the limit is clamped as the GUI clamps it.
        preferences.set(40, forKey: "sidebarSessionLimit")
        #expect(try await commands.listDirectory().arrangement?.sessionLimit == 10)
    }

    private func reply(at seconds: TimeInterval, in sessionID: UUID, of store: ProjectStore) {
        store.append(ChatMessage(role: .assistant, text: "Done",
                                 date: Date(timeIntervalSince1970: seconds)), to: sessionID)
    }

    private func project(named name: String, in store: ProjectStore,
                         under scratch: ScratchDirectory) throws -> Project {
        let folder = scratch.path(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try #require(store.addProject(at: folder))
    }
}
