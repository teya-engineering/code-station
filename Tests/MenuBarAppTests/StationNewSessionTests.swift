import Foundation
import Testing
@testable import CodeStationCore

// Starting a session through the station commands façade: the project, the agent, the
// model and whether the session gets a worktree of its own go in as one plain value, and
// the new session is saved to the store, so the GUI lists it the next time it opens.
@MainActor
struct StationNewSessionTests {

    // A session in a plain folder works in the folder itself, on the agent and model
    // asked for, and is in the index on disk as soon as it is made.
    @Test(arguments: StationImplementation.allCases)
    func aSessionInAPlainFolderIsSavedWithItsAgentAndModel(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-new")
        let folder = scratch.path("plain")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let storeURL = scratch.path("projects.json")
        let store = ProjectStore(storeURL: storeURL)
        let project = try #require(store.addProject(at: folder))
        let station = StationCommands(store: store, runner: Self.runner())
        let commands = kind.connect(to: station)

        let id = try await commands.createSession(
            RemoteNewSession(projectID: project.id.uuidString, agent: .codex,
                             model: "gpt-5.6-terra", worktree: false))

        let sessionID = try #require(UUID(uuidString: id))
        let saved = try #require(ProjectStore(storeURL: storeURL).session(sessionID))
        #expect(saved.projectID == project.id)
        #expect(saved.agent == .codex)
        #expect(saved.settings?.model == "gpt-5.6-terra")
        #expect(saved.worktreePath == nil)
        #expect(try await commands.listDirectory().projects.first?.sessions.map(\.id) == [id])
        #expect(try await commands.openSession(id)?.snapshot.header.agent == "Codex")
    }

    // In a git repository a session can have a checkout of its own: a real worktree on
    // its own branch, which the session records and the index on disk keeps. One that
    // asks for no worktree works in the project folder, on the repository's branch.
    @Test(arguments: StationImplementation.allCases)
    func aGitProjectSessionGetsAWorktreeOnlyWhenAskedFor(_ kind: StationImplementation) async throws {
        let repo = try GitRepo()
        try repo.write("app.txt", "one\n")
        try repo.commit("add app")
        let scratch = ScratchDirectory(prefix: "station-new")
        let storeURL = scratch.path("projects.json")
        let store = ProjectStore(storeURL: storeURL)
        let project = try #require(store.addProject(at: repo.url))
        let station = StationCommands(store: store, runner: Self.runner())
        let commands = kind.connect(to: station)
        station.worktrees = Self.worktrees(in: scratch.path("worktrees"))

        let treeID = try await commands.createSession(
            RemoteNewSession(projectID: project.id.uuidString, agent: .claudeCode,
                             model: "sonnet", worktree: true))
        let folderID = try await commands.createSession(
            RemoteNewSession(projectID: project.id.uuidString, agent: .claudeCode,
                             model: nil, worktree: false))

        let reopened = ProjectStore(storeURL: storeURL)
        let treeUUID = try #require(UUID(uuidString: treeID))
        let folderUUID = try #require(UUID(uuidString: folderID))
        let tree = try #require(reopened.session(treeUUID))
        let path = try #require(tree.worktreePath)
        let suffix = String(treeID.prefix(8)).lowercased()
        #expect(path.hasPrefix(scratch.path("worktrees").path))
        #expect(tree.worktreeBranch == "code-station/\(suffix)")
        #expect(tree.settings?.model == "sonnet")
        #expect(FileManager.default.fileExists(atPath: path + "/app.txt"))
        #expect(try GitRepo.run(["rev-parse", "--abbrev-ref", "HEAD"], in: URL(fileURLWithPath: path))
                == "code-station/\(suffix)")
        #expect(try repo.git("rev-parse", "--abbrev-ref", "HEAD") == "main")

        let folder = try #require(reopened.session(folderUUID))
        #expect(folder.worktreePath == nil)
        #expect(folder.agent == .claudeCode)
        #expect(folder.settings?.model == nil)
        #expect(Set(try await commands.listDirectory().projects.first?.sessions.map(\.id) ?? [])
                == [treeID, folderID])
    }

    // What cannot be started is turned down in words a front end shows as they are, and
    // leaves nothing behind: no session in the store and no worktree on disk.
    @Test(arguments: StationImplementation.allCases)
    func whatCannotBeStartedIsRefusedAndLeavesNothingBehind(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-new")
        let plainURL = scratch.path("plain")
        let goneURL = scratch.path("gone")
        try FileManager.default.createDirectory(at: plainURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: goneURL, withIntermediateDirectories: true)
        let store = ProjectStore(storeURL: scratch.path("projects.json"))
        let plain = try #require(store.addProject(at: plainURL))
        let gone = try #require(store.addProject(at: goneURL))
        try FileManager.default.removeItem(at: goneURL)
        let station = StationCommands(store: store, runner: Self.runner())
        let commands = kind.connect(to: station)
        station.worktrees = Self.worktrees(in: scratch.path("worktrees"))

        func refusal(_ request: RemoteNewSession) async -> StationRefusal? {
            do {
                _ = try await commands.createSession(request)
                return nil
            } catch {
                return error
            }
        }

        let plainID = plain.id.uuidString
        #expect(await refusal(RemoteNewSession(projectID: plainID, agent: .claudeCode,
                                               model: nil, worktree: true))
                == StationRefusal("plain is not a git repository, so it cannot have a worktree."))
        #expect(await refusal(RemoteNewSession(projectID: plainID, agent: .copilot,
                                               model: nil, worktree: false))
                == StationRefusal("Copilot is not installed."))
        #expect(await refusal(RemoteNewSession(projectID: plainID, agent: .codex,
                                               model: "opus", worktree: false))
                == StationRefusal("Codex does not offer that model."))
        #expect(await refusal(RemoteNewSession(projectID: gone.id.uuidString, agent: .claudeCode,
                                               model: nil, worktree: false))
                == StationRefusal("gone is missing from disk."))
        #expect(await refusal(RemoteNewSession(projectID: UUID().uuidString, agent: .claudeCode,
                                               model: nil, worktree: false))
                == StationRefusal("That project is no longer available."))
        #expect(await refusal(RemoteNewSession(projectID: "not an id", agent: .claudeCode,
                                               model: nil, worktree: false))
                == StationRefusal("That project is no longer available."))

        #expect(try await commands.listDirectory().projects.allSatisfy { $0.sessions.isEmpty })
        #expect(!FileManager.default.fileExists(atPath: scratch.path("worktrees").path))
    }

    // A form offers every agent, says which are installed, and lists each agent's models
    // with "Default" first. With only Codex on PATH, a new session starts on Codex. The
    // choices and the request both survive being written out and read back.
    @Test(arguments: StationImplementation.allCases)
    func theOptionsNameTheInstalledAgentsAndTheirModels(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-new")
        let store = ProjectStore(storeURL: scratch.path("projects.json"))
        let station = StationCommands(
                                      store: store, runner: SessionRunner(paths: [.codex: "/usr/bin/true"], host: RecordingHost()))
        let commands = kind.connect(to: station)

        let options = try await commands.sessionOptions()

        #expect(options.agents.map(\.agent) == [.claudeCode, .codex, .copilot])
        #expect(options.agents.map(\.installed) == [false, true, false])
        #expect(options.defaultAgent == .codex)
        let codex = try #require(options.agent(.codex))
        #expect(codex.title == "Codex")
        #expect(codex.models.map(\.title) == ["Default", "Sol", "Terra", "Luna"])
        #expect(codex.models.map(\.id) == [nil, "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"])
        #expect(options.agent(.claudeCode)?.models.map(\.id) == [nil, "opus", "sonnet", "haiku", "fable"])

        let data = try JSONEncoder().encode(options)
        #expect(try JSONDecoder().decode(RemoteSessionOptions.self, from: data) == options)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["type"] as? String == "sessionOptions")
        #expect(object["defaultAgent"] as? String == "codex")

        let request = RemoteNewSession(projectID: UUID().uuidString, agent: .claudeCode,
                                       model: "opus", worktree: true)
        let sent = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(RemoteNewSession.self, from: sent) == request)
        let wire = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        #expect(wire["type"] as? String == "createSession")
        #expect(wire["agent"] as? String == "claude")
        #expect(wire["worktree"] as? Bool == true)
    }

    // Two agents on PATH, so the choice between them is a real one.
    static func runner() -> SessionRunner {
        SessionRunner(paths: [.claudeCode: "/usr/bin/true", .codex: "/usr/bin/true"],
                      host: RecordingHost())
    }

    // The app's own worktree code, making checkouts in a scratch folder rather than in
    // ~/.code-station, on the branch the app would name.
    static func worktrees(in folder: URL) -> WorktreeOperations {
        WorktreeOperations(
            addProject: { path, name, sessionID, base in
                let planned = GitWorktree.plan(projectName: name, sessionID: sessionID)
                let target = folder.appendingPathComponent(
                    URL(fileURLWithPath: planned.path).lastPathComponent).path
                return await GitWorktree.add(projectPath: path,
                                             planned: GitWorktree.Created(path: target,
                                                                          branch: planned.branch),
                                             from: base)
            },
            addWorkspaceProject: { _, _, _, _, _ in
                .failure(GitWorktree.Failure(message: "Unexpected workspace operation"))
            },
            remove: { worktree, project, branch in
                await GitWorktree.remove(worktreePath: worktree, projectPath: project, branch: branch)
            })
    }
}
