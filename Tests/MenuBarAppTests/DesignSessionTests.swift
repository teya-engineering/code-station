import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct DesignSessionTests {
    private func fixture() throws -> (root: URL, store: ProjectStore, project: Project) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("code-station-design-\(UUID().uuidString)", isDirectory: true)
        let projectURL = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let store = ProjectStore(storeURL: root.appendingPathComponent("projects.json"))
        let project = try #require(store.addProject(at: projectURL))
        return (root, store, project)
    }

    @Test func designHasItsOwnConversationOnTheSameCheckout() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.store.newSession(
            in: fixture.project.id,
            worktreePath: "/tmp/code-station-shared-worktree",
            worktreeBranch: "code-station/design-test",
            agent: .codex,
            model: "gpt-5.6-terra")

        let design = try fixture.store.createDesignSession(for: source.id).get()

        #expect(design.id != source.id)
        #expect(design.designSourceSessionID == source.id)
        #expect(design.agent == source.agent)
        #expect(design.settings == source.settings)
        #expect(design.worktreePath == source.worktreePath)
        #expect(design.worktreeBranch == source.worktreeBranch)
        #expect(fixture.store.workingDirectories(for: design)
            == fixture.store.workingDirectories(for: source))
        #expect(fixture.store.sessions.count == 2)
        #expect(fixture.store.userSessions.map(\.id) == [source.id])
        #expect(fixture.store.sidebarSessions.map(\.id) == [source.id])
        #expect(fixture.store.standaloneSessions(for: fixture.project.id).map(\.id) == [source.id])
        let repeated = try fixture.store.createDesignSession(for: source.id).get()
        #expect(repeated.id == design.id)
        #expect(fixture.store.userFacingSessionID(for: design.id) == source.id)

        fixture.store.selectSession(design.id)
        #expect(fixture.store.selection == .session(source.id))
        fixture.store.noteTurnEnded(for: design.id)
        #expect(fixture.store.hasFinished(source.id))
        #expect(!fixture.store.hasFinished(design.id))
        fixture.store.hold(design.id, for: .open)
        #expect(!fixture.store.hasFinished(source.id))
        fixture.store.noteTurnEnded(for: design.id)
        #expect(!fixture.store.hasFinished(source.id))
        fixture.store.release(design.id, for: .open)
        fixture.store.noteTurnEnded(for: design.id)
        #expect(fixture.store.hasFinished(source.id))

        let restored = ProjectStore(storeURL: fixture.store.storeURL)
        #expect(restored.designSession(for: source.id)?.id == design.id)
        #expect(restored.designSession(for: source.id)?.codexSessionID == nil)
    }

    @Test func workspaceDesignKeepsEveryCheckout() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let attachedURL = fixture.root.appendingPathComponent("attached", isDirectory: true)
        try FileManager.default.createDirectory(at: attachedURL, withIntermediateDirectories: true)
        let attached = try #require(fixture.store.addProject(at: attachedURL))
        let workspace = try #require(fixture.store.addWorkspace(
            name: "Product",
            projectIDs: [fixture.project.id, attached.id],
            leadProjectID: fixture.project.id))
        let projects = [
            SessionProject(projectID: fixture.project.id,
                           worktreePath: "/tmp/design-lead", worktreeBranch: "lead"),
            SessionProject(projectID: attached.id,
                           worktreePath: "/tmp/design-attached", worktreeBranch: "attached"),
        ]
        let source = try #require(fixture.store.newSession(
            in: workspace.id, projects: projects, agent: .claudeCode))

        let design = try fixture.store.createDesignSession(for: source.id).get()

        #expect(design.workspaceID == workspace.id)
        #expect(design.sessionProjects == projects)
        #expect(fixture.store.workingDirectories(for: design)
            == ["/tmp/design-lead", "/tmp/design-attached"])
        #expect(fixture.store.sessions(in: workspace.id).map(\.id) == [source.id])
    }

    @Test func designArtifactIsPrivateToTheCompanionAndRemovedWithIt() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.store.newSession(
            in: fixture.project.id,
            worktreePath: "/tmp/code-station-owned-by-source",
            worktreeBranch: "code-station/source")
        let design = try fixture.store.createDesignSession(for: source.id).get()
        let artifact = try #require(fixture.store.designArtifactURL(for: design))
        try Data("<html>design</html>".utf8).write(to: artifact)

        let pending = try fixture.store.prepareSessionRemoval(design.id).get()

        #expect(pending.worktrees.isEmpty)
        if case .failure(let failure) = fixture.store.finishSessionRemoval(design.id) {
            Issue.record("Expected Design removal to succeed: \(failure.message)")
        }
        #expect(fixture.store.session(source.id) != nil)
        #expect(!FileManager.default.fileExists(atPath: artifact.path))
    }

    @Test func deletingTheSourceAlsoDeletesItsDesignConversation() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.store.newSession(in: fixture.project.id)
        let design = try fixture.store.createDesignSession(for: source.id).get()

        if case .failure(let failure) = fixture.store.removeSession(source.id) {
            Issue.record("Expected session removal to succeed: \(failure.message)")
        }
        #expect(fixture.store.session(source.id) == nil)
        #expect(fixture.store.session(design.id) == nil)
    }

    @Test func bothAgentsReceiveDesignAsAPrivilegedInstruction() throws {
        let artifact = URL(fileURLWithPath: "/tmp/code-station design/index.html")
        let prompt = SessionRunner.designSystemPrompt(artifactURL: artifact)

        let claude = SessionRunner.arguments(
            agent: .claudeCode,
            settings: SessionSettings(),
            defaults: SessionSettings(),
            additionalSystemPrompt: prompt)
        let claudePrompt = try #require(value(after: "--append-system-prompt", in: claude))
        #expect(claudePrompt.contains("You are working in Design mode"))
        #expect(claudePrompt.contains(artifact.path))

        let codex = SessionRunner.arguments(
            agent: .codex,
            settings: SessionSettings(),
            defaults: SessionSettings(),
            additionalSystemPrompt: prompt)
        let instruction = try #require(codex.first {
            $0.hasPrefix("developer_instructions=")
        })
        #expect(instruction.contains("Design mode"))
        #expect(instruction.contains("\\n"))
        #expect(!instruction.contains("\n"))
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }
}
