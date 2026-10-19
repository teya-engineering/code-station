import Foundation
import Testing
@testable import CodeStationCore

// Part of the station contract (see StationContract.swift): what a front end does to a
// workspace, as the GUI's Add button, workspace row and workspace screen do it. It
// creates one from several projects with a lead, changes the lead and whether each member
// starts on a worktree, renames and pins it, starts a session across its projects, reads
// what deleting it takes before deleting it, and reads its changes across members.
@MainActor
struct StationWorkspacesTests {

    // Several projects make a workspace, the lead first; the list then has it with its
    // members. Fewer than two projects, no name or a lead outside the members is refused.
    @Test(arguments: StationImplementation.allCases)
    func aWorkspaceIsCreatedFromSeveralProjectsLeadFirst(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-workspaces")
        let host = station(scratch)
        let alpha = try repository("alpha", in: host.store, under: scratch)
        let beta = try folder("beta", in: host.store, under: scratch)
        let commands = kind.connect(to: host)

        let id = try await commands.createWorkspace(name: " Both ", projectIDs: [alpha.id.uuidString, beta.id.uuidString],
                                                    leadProjectID: beta.id.uuidString)

        let created = try #require(try await container(id, in: commands))
        #expect(created.kind == .workspace)
        #expect(created.name == "Both")
        #expect(created.members == ["beta", "alpha"])
        let members = try #require(try await commands.readContainerStatus(id).members)
        #expect(members.map(\.isLead) == [true, false])
        // A git repository starts on a worktree of its own; a plain folder cannot.
        #expect(members.map(\.usesWorktree) == [false, true])
        #expect(members.map(\.isGit) == [false, true])

        let ids = [alpha.id.uuidString, beta.id.uuidString]
        await #expect(throws: StationRefusal("Give the workspace a name.")) {
            try await commands.createWorkspace(name: " ", projectIDs: ids, leadProjectID: ids[0])
        }
        await #expect(throws: StationRefusal("A workspace needs at least two projects.")) {
            try await commands.createWorkspace(name: "One", projectIDs: [ids[0]], leadProjectID: ids[0])
        }
        await #expect(throws: StationRefusal("The lead must be one of the workspace's projects.")) {
            try await commands.createWorkspace(name: "Two", projectIDs: ids, leadProjectID: UUID().uuidString)
        }
        #expect(try await commandsWorkspaces(commands) == [id])
    }

    // The lead, each member's checkout, the name and the pin each change the workspace as
    // the list and its strip then show it.
    @Test(arguments: StationImplementation.allCases)
    func aWorkspaceChangesItsLeadCheckoutsNameAndPin(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-workspaces")
        let host = station(scratch)
        let alpha = try repository("alpha", in: host.store, under: scratch)
        let beta = try repository("beta", in: host.store, under: scratch)
        let plain = try folder("plain", in: host.store, under: scratch)
        let both = try #require(host.store.addWorkspace(name: "both", projectIDs: [alpha.id, beta.id, plain.id],
                                                        leadProjectID: alpha.id))
        let id = both.id.uuidString
        let commands = kind.connect(to: host)

        try await commands.changeWorkspace(id, .lead(projectID: beta.id.uuidString))
        try await commands.changeWorkspace(id, .worktree(projectID: alpha.id.uuidString, uses: false))
        let members = try #require(try await commands.readContainerStatus(id).members)
        #expect(members.map(\.name) == ["beta", "alpha", "plain"])
        #expect(members.map(\.isLead) == [true, false, false])
        #expect(members.map(\.usesWorktree) == [true, false, false])
        await #expect(throws: StationRefusal("plain is not a git repository, so it cannot have a worktree.")) {
            try await commands.changeWorkspace(id, .worktree(projectID: plain.id.uuidString, uses: true))
        }
        await #expect(throws: StationRefusal("That project is not in both.")) {
            try await commands.changeWorkspace(id, .lead(projectID: UUID().uuidString))
        }

        try await commands.changeWorkspace(id, .rename(name: " Both apps "))
        #expect(await eventually { try await container(id, in: commands)?.name == "Both apps" })
        await #expect(throws: StationRefusal("Give Both apps a name.")) {
            try await commands.changeWorkspace(id, .rename(name: "  "))
        }
        try await commands.changeWorkspace(id, .pin(true))
        #expect(await eventually { try await container(id, in: commands)?.isPinned == true })
        try await commands.changeWorkspace(id, .pin(false))
        #expect(await eventually { try await container(id, in: commands)?.isPinned == false })

        await #expect(throws: StationRefusal("That workspace is no longer available.")) {
            try await commands.changeWorkspace(UUID().uuidString, .pin(true))
        }
    }

    // A session in a workspace works across its projects: the lead first whatever order
    // they came in, one on a worktree of its own and one in its folder, as asked. It is
    // listed under the workspace. Leaving the lead out, or a plain folder on a worktree,
    // is refused and leaves nothing behind.
    @Test(arguments: StationImplementation.allCases)
    func aWorkspaceSessionWorksAcrossItsProjectsAsAsked(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-workspaces")
        let host = station(scratch)
        let alpha = try repository("alpha", in: host.store, under: scratch)
        let beta = try repository("beta", in: host.store, under: scratch)
        let plain = try folder("plain", in: host.store, under: scratch)
        let both = try #require(host.store.addWorkspace(name: "both", projectIDs: [alpha.id, beta.id, plain.id],
                                                        leadProjectID: alpha.id))
        let commands = kind.connect(to: host)

        func request(_ checkouts: [(Project, Bool)]) -> RemoteNewWorkspaceSession {
            RemoteNewWorkspaceSession(workspaceID: both.id.uuidString, agent: .claudeCode, model: nil,
                                      projects: checkouts.map { .init(projectID: $0.0.id.uuidString, worktree: $0.1) })
        }

        await #expect(throws: StationRefusal("plain is not a git repository, so it cannot have a worktree.")) {
            try await commands.createWorkspaceSession(request([(alpha, true), (plain, true)]))
        }
        await #expect(throws: StationRefusal("A session in both works in its lead project, so it cannot be left out.")) {
            try await commands.createWorkspaceSession(request([(beta, true), (plain, false)]))
        }
        #expect(host.store.sessions.isEmpty)

        let id = try await commands.createWorkspaceSession(request([(beta, false), (alpha, true), (plain, false)]))

        let sessionID = try #require(UUID(uuidString: id))
        let session = try #require(host.store.session(sessionID))
        #expect(session.workspaceID == both.id)
        let checkouts = host.store.checkoutProjects(for: session)
        #expect(checkouts.map(\.projectID) == [alpha.id, beta.id, plain.id])
        let tree = try #require(checkouts[0].worktreePath)
        #expect(tree.hasPrefix(scratch.path("worktrees").path))
        #expect(FileManager.default.fileExists(atPath: tree + "/README.md"))
        #expect(checkouts[1].worktreePath == nil)
        #expect(checkouts[2].worktreePath == nil)
        #expect(try await container(both.id.uuidString, in: commands)?.sessions.map(\.id) == [id])
    }

    // Deleting reads first: the sessions and worktrees that go and the projects that
    // stay, with the warning. Deleting then takes the workspace, its sessions and their
    // worktrees; the projects stay in the list.
    @Test(arguments: StationImplementation.allCases)
    func deletingAWorkspaceSaysWhatGoesThenTakesIt(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-workspaces")
        let host = station(scratch)
        let alpha = try repository("alpha", in: host.store, under: scratch)
        let beta = try folder("beta", in: host.store, under: scratch)
        let both = try #require(host.store.addWorkspace(name: "both", projectIDs: [alpha.id, beta.id],
                                                        leadProjectID: alpha.id))
        let id = both.id.uuidString
        let commands = kind.connect(to: host)
        _ = try await commands.createWorkspaceSession(RemoteNewWorkspaceSession(
            workspaceID: id, agent: .claudeCode, model: nil,
            projects: [.init(projectID: alpha.id.uuidString, worktree: true),
                       .init(projectID: beta.id.uuidString, worktree: false)]))
        let tree = try #require(host.store.sessions.first.flatMap { host.store.checkoutProjects(for: $0).first?.worktreePath })

        let impact = try await commands.readWorkspaceRemoval(id)
        #expect(impact.title == "Delete both?")
        #expect(impact.message == "This workspace and its sessions will leave Code Station.")
        #expect(impact.subject == RemoteImpact.Subject(name: "both", kind: .workspace))
        #expect(impact.rows == [
            RemoteImpact.Row(title: "1 session and 1 worktree",
                             detail: "Session history is removed from Code Station. Worktrees are removed from disk."),
            RemoteImpact.Row(title: "Its projects stay", detail: "alpha, beta", kept: true),
        ])
        #expect(impact.warning == "Session history cannot be restored.")
        #expect(impact.action == "Delete workspace")

        try await commands.removeWorkspace(id)
        #expect(await eventually { try await container(id, in: commands) == nil })
        #expect(host.store.sessions.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: tree))
        #expect(try await container(alpha.id.uuidString, in: commands) != nil)
        #expect(try await container(beta.id.uuidString, in: commands) != nil)
        await #expect(throws: StationRefusal("That workspace is no longer available.")) {
            try await commands.readWorkspaceRemoval(id)
        }
    }

    // The workspace's changes are each member's folder, the lead first, with its files
    // and their diffs; a session in it reads one checkout per member it works in.
    @Test(arguments: StationImplementation.allCases)
    func aWorkspaceReadsItsChangesAcrossMembers(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-workspaces")
        let host = station(scratch)
        let alpha = try repository("alpha", in: host.store, under: scratch)
        let beta = try repository("beta", in: host.store, under: scratch)
        let both = try #require(host.store.addWorkspace(name: "both", projectIDs: [alpha.id, beta.id],
                                                        leadProjectID: beta.id))
        try "two\n".write(to: scratch.path("alpha/README.md"), atomically: true, encoding: .utf8)
        try "new\n".write(to: scratch.path("beta/NEW.md"), atomically: true, encoding: .utf8)
        let commands = kind.connect(to: host)

        let checkouts = try await commands.readWorkspaceChanges(both.id.uuidString)

        #expect(checkouts.map(\.project) == ["beta", "alpha"])
        #expect(checkouts.map(\.branch) == ["main", "main"])
        #expect(checkouts.map(\.isWorktree) == [false, false])
        #expect(checkouts[0].files.map(\.path) == ["NEW.md"])
        #expect(checkouts[1].files.map(\.path) == ["README.md"])
        #expect(checkouts[1].files.first?.diff.lines.contains(RemoteDiffLine(kind: .addition, text: "+two")) == true)

        let id = try await commands.createWorkspaceSession(RemoteNewWorkspaceSession(
            workspaceID: both.id.uuidString, agent: .claudeCode, model: nil,
            projects: [.init(projectID: alpha.id.uuidString, worktree: false),
                       .init(projectID: beta.id.uuidString, worktree: false)]))
        let changes = try #require(try await commands.readChanges(id))
        #expect(changes.checkouts.map(\.project) == ["beta", "alpha"])
        #expect(changes.checkouts.map { $0.files.count } == [1, 1])

        await #expect(throws: StationRefusal("That workspace is no longer available.")) {
            try await commands.readWorkspaceChanges(UUID().uuidString)
        }
    }

    // MARK: - Helpers

    private func station(_ scratch: ScratchDirectory) -> StationCommands {
        let host = StationCommands(store: ProjectStore(storeURL: scratch.path("projects.json")),
                                   runner: StationNewSessionTests.runner(), refreshInterval: .milliseconds(50))
        host.worktrees = Self.worktrees(in: scratch.path("worktrees"))
        return host
    }

    private func container(_ id: String, in commands: any StationInterface) async throws -> RemoteContainer? {
        try await commands.listDirectory().containers?.first { $0.id == id }
    }

    private func commandsWorkspaces(_ commands: any StationInterface) async throws -> [String] {
        try await commands.listDirectory().containers?.filter { $0.kind == .workspace }.map(\.id) ?? []
    }

    private func folder(_ name: String, in store: ProjectStore, under scratch: ScratchDirectory) throws -> Project {
        let folder = scratch.path(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try #require(store.addProject(at: folder))
    }

    private func repository(_ name: String, in store: ProjectStore, under scratch: ScratchDirectory) throws -> Project {
        let folder = scratch.path(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try GitRepo.run(["init", "-q", "-b", "main"], in: folder)
        try GitRepo.run(["config", "user.email", "test@example.com"], in: folder)
        try GitRepo.run(["config", "user.name", "Test"], in: folder)
        try GitRepo.run(["config", "commit.gpgsign", "false"], in: folder)
        try "one\n".write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try GitRepo.run(["add", "-A"], in: folder)
        try GitRepo.run(["commit", "-qm", "first"], in: folder)
        return try #require(store.addProject(at: folder))
    }

    // The app's own worktree code for workspace members, making checkouts in a scratch
    // folder rather than in ~/.code-station.
    static func worktrees(in folder: URL) -> WorktreeOperations {
        WorktreeOperations(
            addProject: { _, _, _, _ in .failure(GitWorktree.Failure(message: "Unexpected project operation")) },
            addWorkspaceProject: { path, name, projectID, sessionID, base in
                let planned = GitWorktree.plan(projectName: name, projectID: projectID, sessionID: sessionID)
                let relative = planned.path.split(separator: "/").suffix(2).joined(separator: "/")
                let target = folder.appendingPathComponent(relative).path
                try? FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent,
                                                         withIntermediateDirectories: true)
                return await GitWorktree.add(projectPath: path,
                                             planned: GitWorktree.Created(path: target, branch: planned.branch),
                                             from: base)
            },
            remove: { worktree, project, branch in
                await GitWorktree.remove(worktreePath: worktree, projectPath: project, branch: branch)
            })
    }
}
