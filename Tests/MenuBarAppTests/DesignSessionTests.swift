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

    @Test func designSplitKeepsBothPanesVisible() {
        #expect(DesignSplitLayout.conversationWidth(340, availableWidth: 900) == 340)
        #expect(DesignSplitLayout.conversationWidth(100, availableWidth: 900) == 280)
        #expect(DesignSplitLayout.conversationWidth(800, availableWidth: 900) == 579)
        #expect(DesignSplitLayout.conversationWidth(400, availableWidth: 500) == 249.5)
    }

    @Test func designModeUsesTheSessionConversationAndCheckout() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let design = fixture.store.newSession(
            in: fixture.project.id,
            worktreePath: "/tmp/code-station-shared-worktree",
            worktreeBranch: "code-station/design-test",
            agent: .codex,
            model: "gpt-5.6-terra",
            mode: .design)

        #expect(design.mode == .design)
        #expect(fixture.store.designConversation(for: design.id)?.id == design.id)
        #expect(fixture.store.isDesignMode(design))
        #expect(fixture.store.workingDirectories(for: design)
            == ["/tmp/code-station-shared-worktree"])
        #expect(fixture.store.sessions.map(\.id) == [design.id])
        #expect(fixture.store.userSessions.map(\.id) == [design.id])
        #expect(fixture.store.sidebarSessions.map(\.id) == [design.id])
        #expect(fixture.store.standaloneSessions(for: fixture.project.id).map(\.id) == [design.id])

        let restored = ProjectStore(storeURL: fixture.store.storeURL)
        #expect(restored.session(design.id)?.mode == .design)
        #expect(restored.designConversation(for: design.id)?.id == design.id)
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
        let design = try #require(fixture.store.newSession(
            in: workspace.id, projects: projects, agent: .claudeCode, mode: .design))

        #expect(design.mode == .design)
        #expect(design.workspaceID == workspace.id)
        #expect(design.sessionProjects == projects)
        #expect(fixture.store.workingDirectories(for: design)
            == ["/tmp/design-lead", "/tmp/design-attached"])
        #expect(fixture.store.sessions(in: workspace.id).map(\.id) == [design.id])
    }

    @Test func designArtifactIsPrivateToTheSessionAndRemovedWithIt() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let design = fixture.store.newSession(in: fixture.project.id, mode: .design)
        let artifact = try #require(fixture.store.designArtifactURL(for: design))
        try FileManager.default.createDirectory(
            at: artifact.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("<html>design</html>".utf8).write(to: artifact)

        let pending = try fixture.store.prepareSessionRemoval(design.id).get()

        #expect(pending.worktrees.isEmpty)
        if case .failure(let failure) = fixture.store.finishSessionRemoval(design.id) {
            Issue.record("Expected Design removal to succeed: \(failure.message)")
        }
        #expect(fixture.store.session(design.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: artifact.path))
    }

    @Test func sessionsWithoutAModeDecodeAsChat() throws {
        let id = UUID()
        let projectID = UUID()
        let data = Data("""
            {
              "id": "\(id.uuidString)",
              "projectID": "\(projectID.uuidString)"
            }
            """.utf8)

        let session = try JSONDecoder().decode(ChatSession.self, from: data)

        #expect(session.mode == .chat)
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
