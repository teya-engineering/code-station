import Darwin
import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct SessionLifecycleTests {
    @Test func recordsAProjectSessionOnlyAfterItsWorktreeExists() async throws {
        let store = makeStore()
        let project = addProject(named: "project", to: store)
        let sessionID = UUID()
        let projectPath = project.path
        let projectName = project.name
        let worktrees = WorktreeOperations(
            addProject: { path, name, receivedID, base in
                #expect(path == projectPath)
                #expect(name == projectName)
                #expect(receivedID == sessionID)
                #expect(base == "origin/main")
                return .success(GitWorktree.Created(path: "/worktrees/project",
                                                    branch: "conductor/test"))
            },
            addWorkspaceProject: { _, _, _, _ in
                .failure(GitWorktree.Failure(message: "Unexpected workspace operation"))
            },
            remove: { _, _, _ in
                .failure(GitWorktree.Failure(message: "Unexpected removal"))
            })

        let result = await SessionLifecycle.createWorktreeSession(
            in: project, id: sessionID, base: "origin/main", store: store,
            worktrees: worktrees)

        let session = try result.get()
        #expect(session.id == sessionID)
        #expect(session.worktreePath == "/worktrees/project")
        #expect(store.session(sessionID)?.worktreeBranch == "conductor/test")
    }

    @Test func rollsBackWorkspaceWorktreesWhenCreationFails() async {
        let store = makeStore()
        let first = addProject(named: "first", to: store)
        let second = addProject(named: "second", to: store)
        let workspace = store.addWorkspace(name: "Workspace",
                                           projectIDs: [first.id, second.id],
                                           leadProjectID: first.id)!
        let recorder = RemovalRecorder()
        let choice = WorkspaceSessionChoice(
            sessionID: UUID(),
            projects: [
                WorkspaceProjectChoice(projectID: first.id, useWorktree: true),
                WorkspaceProjectChoice(projectID: second.id, useWorktree: true)
            ],
            agent: .codex)
        let worktrees = WorktreeOperations(
            addProject: { _, _, _, _ in
                .failure(GitWorktree.Failure(message: "Unexpected project operation"))
            },
            addWorkspaceProject: { _, name, _, _ in
                guard name == "first" else {
                    return .failure(GitWorktree.Failure(message: "Second checkout failed"))
                }
                return .success(GitWorktree.Created(path: "/worktrees/first",
                                                    branch: "conductor/test"))
            },
            remove: { path, _, _ in
                await recorder.record(path)
                return .success(())
            })

        let result = await SessionLifecycle.createWorkspaceSession(
            choice, in: workspace, store: store, worktrees: worktrees)

        guard case .failure(let failure) = result else {
            Issue.record("Expected workspace creation to fail")
            return
        }
        #expect(failure.title == "Could not create a worktree for second")
        #expect(failure.message == "Second checkout failed")
        #expect(store.sessions.isEmpty)
        #expect(await recorder.recordedPaths() == ["/worktrees/first"])
    }

    @Test func rollsBackAWorktreeWhenTheSessionIndexCannotBeSaved() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-lifecycle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ProjectStore(storeURL: directory.appendingPathComponent("projects.json"))
        let project = try #require(store.addProject(
            at: directory.appendingPathComponent("project")))
        let recorder = RemovalRecorder()
        let worktrees = WorktreeOperations(
            addProject: { _, _, _, _ in
                .success(GitWorktree.Created(path: "/worktrees/project",
                                             branch: "conductor/test"))
            },
            addWorkspaceProject: { _, _, _, _ in
                .failure(GitWorktree.Failure(message: "Unexpected workspace operation"))
            },
            remove: { path, _, _ in
                await recorder.record(path)
                return .success(())
            })
        try FileManager.default.removeItem(at: directory)
        try Data("not a directory".utf8).write(to: directory)

        let result = await SessionLifecycle.createWorktreeSession(
            in: project, id: UUID(), base: nil, store: store, worktrees: worktrees)

        guard case .failure(let failure) = result else {
            Issue.record("Expected persistence to fail")
            return
        }
        #expect(failure.title == "Could not save the session")
        #expect(store.sessions.isEmpty)
        #expect(await recorder.recordedPaths() == ["/worktrees/project"])
    }

    @Test func keepsDeletionPendingWhenWorktreeRemovalFails() async {
        let store = makeStore()
        let runner = SessionRunner()
        let project = addProject(named: "project", to: store)
        let session = store.newSession(in: project.id,
                                       worktreePath: "/worktrees/project",
                                       worktreeBranch: "conductor/test")
        let worktrees = operationsForRemoval {
            .failure(GitWorktree.Failure(message: "Checkout is still in use"))
        }

        let result = await SessionLifecycle.remove(
            session, from: store, runner: runner, worktrees: worktrees)

        guard case .failure(let failure) = result else {
            Issue.record("Expected removal to fail")
            return
        }
        #expect(failure.message.contains("Checkout is still in use"))
        #expect(store.session(session.id) == nil)
        #expect(store.pendingSessionRemovals.map(\.id) == [session.id])

        let recoveryFailures = await SessionLifecycle.resumePendingRemovals(
            in: store, worktrees: operationsForRemoval { .success(()) })

        #expect(recoveryFailures.isEmpty)
        #expect(store.pendingSessionRemovals.isEmpty)
        #expect(ProjectStore(storeURL: store.storeURL).session(session.id) == nil)
    }

    @Test func blocksNewPromptsWhileRemovalIsInProgress() {
        let store = makeStore()
        let runner = SessionRunner()
        let project = addProject(named: "project", to: store)
        let session = store.newSession(in: project.id)

        #expect(runner.beginRemoval(session.id))
        runner.send("must not be queued", sessionID: session.id, store: store)

        #expect(runner.queued(session.id).isEmpty)
        runner.cancelRemoval(session.id)
    }

    @Test func waitsForAStoppedAgentToExitBeforeDeletingItsSession() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stopping-session-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let executable = directory.appendingPathComponent("stubborn-agent")
        let descendantPIDFile = directory.appendingPathComponent("descendant.pid")
        try Data("""
        #!/bin/sh
        trap '' TERM
        sleep 30 &
        descendant=$!
        printf '%s' "$descendant" > "$(dirname "$0")/descendant.pid"
        while :; do :; done
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: executable.path)

        let store = ProjectStore(storeURL: directory.appendingPathComponent("projects.json"))
        let projectURL = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let project = try #require(store.addProject(at: projectURL))
        let session = try store.insertSession(in: project.id).get()
        let runner = SessionRunner(paths: [.claudeCode: executable.path])
        runner.agent = .claudeCode
        runner.send("start", sessionID: session.id, store: store)

        #expect(runner.state(session.id).isBusy)
        let descendantPID = try #require(await waitForPID(in: descendantPIDFile))
        defer {
            if processExists(descendantPID) { Darwin.kill(descendantPID, SIGKILL) }
        }
        runner.stop(session.id, store: store)
        #expect(runner.state(session.id) == .stopping)

        let blocked = await SessionLifecycle.remove(
            session, from: store, runner: runner,
            worktrees: operationsForRemoval { .success(()) })
        guard case .failure(let failure) = blocked else {
            Issue.record("Expected deletion to wait for process exit")
            return
        }
        #expect(failure.message == "Stop this session before deleting it.")

        for _ in 0..<200 where runner.state(session.id).isBusy {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!runner.state(session.id).isBusy)
        #expect(!processExists(descendantPID))

        let removed = await SessionLifecycle.remove(
            session, from: store, runner: runner,
            worktrees: operationsForRemoval { .success(()) })
        guard case .success = removed else {
            Issue.record("Expected deletion after process exit")
            return
        }
    }

    @Test func dropsSessionMetadataAfterWorktreeRemovalSucceeds() async {
        let store = makeStore()
        let runner = SessionRunner()
        let project = addProject(named: "project", to: store)
        let session = store.newSession(in: project.id,
                                       worktreePath: "/worktrees/project",
                                       worktreeBranch: "conductor/test")
        let worktrees = operationsForRemoval { .success(()) }

        let result = await SessionLifecycle.remove(
            session, from: store, runner: runner, worktrees: worktrees)

        guard case .success = result else {
            Issue.record("Expected removal to succeed")
            return
        }
        #expect(store.session(session.id) == nil)
    }

    private func makeStore() -> ProjectStore {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("conductor-tests-\(UUID().uuidString).json").path
        setenv("CONDUCTOR_STORE", path, 1)
        return ProjectStore()
    }

    private func addProject(named name: String, to store: ProjectStore) -> Project {
        store.addProject(at: FileManager.default.temporaryDirectory
            .appendingPathComponent(name))!
    }

    private func operationsForRemoval(
        _ remove: @escaping @Sendable () async -> Result<Void, GitWorktree.Failure>
    ) -> WorktreeOperations {
        WorktreeOperations(
            addProject: { _, _, _, _ in
                .failure(GitWorktree.Failure(message: "Unexpected add"))
            },
            addWorkspaceProject: { _, _, _, _ in
                .failure(GitWorktree.Failure(message: "Unexpected add"))
            },
            remove: { _, _, _ in await remove() })
    }

    private func waitForPID(in file: URL) async -> pid_t? {
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: file),
               let text = String(data: data, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    private func processExists(_ pid: pid_t) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }
}

private actor RemovalRecorder {
    private var paths: [String] = []

    func record(_ path: String) {
        paths.append(path)
    }

    func recordedPaths() -> [String] {
        paths
    }
}
