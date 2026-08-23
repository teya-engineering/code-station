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
        #expect(fixture.store.designFilesURL(for: design) == artifact.deletingLastPathComponent())
        #expect(!fixture.store.hasDesignArtifacts(for: design))
        try FileManager.default.createDirectory(
            at: artifact.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("<html>design</html>".utf8).write(to: artifact)
        #expect(fixture.store.hasDesignArtifacts(for: design))

        let pending = try fixture.store.prepareSessionRemoval(design.id).get()

        #expect(pending.worktrees.isEmpty)
        if case .failure(let failure) = fixture.store.finishSessionRemoval(design.id) {
            Issue.record("Expected Design removal to succeed: \(failure.message)")
        }
        #expect(fixture.store.session(design.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: artifact.path))
    }

    @Test func approvedRevisionPreservesScreensHandoffAndSourceRevision() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let design = fixture.store.newSession(in: fixture.project.id, mode: .design)
        let directory = try writeDesign(for: design, in: fixture.store,
                                        html: "<html>First</html>")
        try Data("""
            {"screens":[
              {"id":"home","title":"Home","path":"index.html","width":1440,"height":900},
              {"id":"details","title":"Details","path":"details.html"}
            ]}
            """.utf8).write(to: directory.appendingPathComponent("design.json"))
        try Data("<html>Details</html>".utf8)
            .write(to: directory.appendingPathComponent("details.html"))
        try Data("# Exact handoff".utf8)
            .write(to: directory.appendingPathComponent("handoff.md"))

        let revision = try fixture.store.approveDesign(
            design.id,
            screenshot: Data("preview".utf8),
            sourceRevisions: [fixture.project.id.uuidString: "abc123"])
            .get()
        let materials = DesignArtifacts.materialsDirectory(
            revision, designDirectory: fixture.store.designDirectory(for: design))

        #expect(revision.number == 1)
        #expect(revision.sourceRevisions[fixture.project.id.uuidString] == "abc123")
        #expect(revision.screens.map(\.title) == ["Home", "Details"])
        #expect(try String(contentsOf: materials.appendingPathComponent("index.html"),
                           encoding: .utf8) == "<html>First</html>")
        #expect(try String(contentsOf: materials.appendingPathComponent("handoff.md"),
                           encoding: .utf8) == "# Exact handoff")
        #expect(try Data(contentsOf: DesignArtifacts.previewURL(
            revision, designDirectory: fixture.store.designDirectory(for: design)))
            == Data("preview".utf8))

        let restored = ProjectStore(storeURL: fixture.store.storeURL)
        #expect(restored.session(design.id)?.approvedDesignRevisionID == revision.id)
        #expect(restored.session(design.id)?.designRevisions.map(\.id) == [revision.id])
        #expect(restored.session(design.id)?.designRevisions.first?.screens == revision.screens)
    }

    @Test func implementationPhaseKeepsTheDesignButUsesChatConversation() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let design = fixture.store.newSession(in: fixture.project.id, mode: .design)
        _ = try writeDesign(for: design, in: fixture.store, html: "<html>Approved</html>")
        let revision = try fixture.store.approveDesign(
            design.id, screenshot: nil, sourceRevisions: [:]).get()

        try fixture.store.beginImplementation(design.id, revisionID: revision.id).get()
        let implementing = try #require(fixture.store.session(design.id))

        #expect(implementing.mode == .design)
        #expect(implementing.designPhase == .implementing)
        #expect(implementing.isImplementingDesign)
        #expect(fixture.store.designConversation(for: design.id) == nil)
        #expect(fixture.store.isDesignMode(implementing))
        #expect(fixture.store.designFilesURL(for: implementing) != nil)
        let handoff = try #require(fixture.store
            .implementationReferenceAttachments(for: implementing)
            .first { $0.name == "handoff.md" })
        let handoffText = try String(contentsOf: handoff.url, encoding: .utf8)
        #expect(handoffText.contains("scoped change to the existing product"))
        #expect(handoffText.contains("Anything omitted from the Design remains unchanged"))

        let restored = ProjectStore(storeURL: fixture.store.storeURL)
        #expect(restored.session(design.id)?.designPhase == .implementing)
        #expect(restored.designFilesURL(for: try #require(restored.session(design.id))) != nil)
    }

    @Test func linkedCodingSessionKeepsAnImmutableReferenceAndReceivesUpdates() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let design = fixture.store.newSession(in: fixture.project.id, mode: .design)
        let directory = try writeDesign(for: design, in: fixture.store,
                                        html: "<html>Version one</html>")
        let first = try fixture.store.approveDesign(
            design.id, screenshot: Data("one".utf8), sourceRevisions: [:]).get()
        let coding = fixture.store.newSession(in: fixture.project.id, mode: .chat)

        try fixture.store.linkImplementation(
            coding.id, to: design.id, revisionID: first.id).get()
        var linked = try #require(fixture.store.session(coding.id))
        let reference = try #require(fixture.store.designReferenceDirectory(for: linked))
        #expect(try String(contentsOf: reference.appendingPathComponent("index.html"),
                           encoding: .utf8) == "<html>Version one</html>")
        #expect(!fixture.store.designHasUpdated(for: linked))

        try Data("<html>Version two</html>".utf8)
            .write(to: directory.appendingPathComponent("index.html"), options: .atomic)
        let second = try fixture.store.approveDesign(
            design.id, screenshot: Data("two".utf8), sourceRevisions: [:]).get()
        linked = try #require(fixture.store.session(coding.id))
        #expect(fixture.store.designHasUpdated(for: linked))
        #expect(try String(contentsOf: reference.appendingPathComponent("index.html"),
                           encoding: .utf8) == "<html>Version one</html>")

        let synced = try fixture.store.syncDesignReference(for: coding.id).get()
        linked = try #require(fixture.store.session(coding.id))
        #expect(synced.id == second.id)
        #expect(!fixture.store.designHasUpdated(for: linked))
        #expect(try String(contentsOf: reference.appendingPathComponent("index.html"),
                           encoding: .utf8) == "<html>Version two</html>")

        try fixture.store.removeSession(design.id).get()
        linked = try #require(fixture.store.session(coding.id))
        #expect(fixture.store.isDesignMode(linked))
        #expect(fixture.store.implementationDesignDirectory(for: linked) == reference)
        #expect(FileManager.default.fileExists(atPath: reference.path))

        let codingArtifacts = fixture.store.designDirectory(for: linked)
        try fixture.store.removeSession(coding.id).get()
        #expect(!FileManager.default.fileExists(atPath: codingArtifacts.path))
    }

    @Test func savedRevisionCanBecomeTheNextLiveDirection() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let design = fixture.store.newSession(in: fixture.project.id, mode: .design)
        let directory = try writeDesign(for: design, in: fixture.store,
                                        html: "<html>Keep me</html>")
        let first = try fixture.store.approveDesign(
            design.id, screenshot: nil, sourceRevisions: [:]).get()
        try Data("<html>Discard me</html>".utf8)
            .write(to: directory.appendingPathComponent("index.html"), options: .atomic)

        try fixture.store.restoreDesignRevision(first.id, for: design.id).get()

        #expect(try String(contentsOf: directory.appendingPathComponent("index.html"),
                           encoding: .utf8) == "<html>Keep me</html>")
        #expect(fixture.store.session(design.id)?.designPhase == .designing)
    }

    @Test func manifestRejectsMissingAndEscapingScreens() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("design-manifest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<html>Canvas</html>".utf8)
            .write(to: root.appendingPathComponent("index.html"))
        try Data("""
            {"screens":[
              {"id":"safe","title":"Safe","path":"index.html"},
              {"id":"missing","title":"Missing","path":"missing.html"},
              {"id":"escape","title":"Escape","path":"../outside.html"}
            ]}
            """.utf8).write(to: root.appendingPathComponent("design.json"))

        let manifest = DesignManifest.read(from: root)

        #expect(manifest.screens == [DesignScreen(
            id: "safe", title: "Safe", path: "index.html")])
    }

    @Test func artifactRevisionTracksSupportingFileChanges() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("design-revision-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<html></html>".utf8).write(to: root.appendingPathComponent("index.html"))
        let asset = root.appendingPathComponent("hero.png")
        try Data("one".utf8).write(to: asset)
        let first = DesignArtifactRevision.read(root)

        try Data("longer image".utf8).write(to: asset, options: .atomic)
        let second = DesignArtifactRevision.read(root)

        #expect(first != second)
    }

    @Test func designMaterialsExportAtTheRootOfAZipArchive() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("code-station-design-export-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let materials = root.appendingPathComponent("materials", isDirectory: true)
        let assets = materials.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data("<html>Design</html>".utf8)
            .write(to: materials.appendingPathComponent("index.html"))
        try Data("image".utf8).write(to: assets.appendingPathComponent("hero.png"))

        let archive = root.appendingPathComponent("materials.zip")
        try await DesignMaterialExporter.export(materialsAt: materials, to: archive)

        let extracted = root.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        let output = try await CommandRunner.run(
            executable: "/usr/bin/ditto",
            arguments: ["-x", "-k", archive.path, extracted.path],
            timeout: .seconds(10))
        #expect(output.succeeded)
        #expect(try String(contentsOf: extracted.appendingPathComponent("index.html"),
                           encoding: .utf8) == "<html>Design</html>")
        #expect(try String(contentsOf: extracted.appendingPathComponent("assets/hero.png"),
                           encoding: .utf8) == "image")
        #expect(!FileManager.default.fileExists(
            atPath: extracted.appendingPathComponent("materials/index.html").path))
        #expect(!FileManager.default.fileExists(
            atPath: extracted.appendingPathComponent("__MACOSX").path))
    }

    @Test func designMaterialArchiveNameIsPortable() {
        let name = DesignMaterialExporter.suggestedFileName(
            projectName: "Checkout/API", sessionTitle: "Landing:\nFirst pass")

        #expect(name == "Checkout API - Landing First pass - Design materials.zip")
    }

    @Test func emptyDesignMaterialDirectoryCannotBeExported() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("code-station-empty-design-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        do {
            try await DesignMaterialExporter.export(
                materialsAt: root, to: root.appendingPathComponent("materials.zip"))
            Issue.record("Expected an empty Design folder not to be exported")
        } catch let error as DesignMaterialExporter.ExportError {
            #expect(error == .noMaterials)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
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

        #expect(prompt.contains("scoped change from the existing product"))

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

    @Test func implementationReceivesItsReferenceAsAPrivilegedInstruction() throws {
        let reference = URL(fileURLWithPath: "/tmp/approved design")
        let prompt = SessionRunner.implementationSystemPrompt(referenceURL: reference)

        #expect(prompt.contains("implementing an approved Design"))
        #expect(prompt.contains(reference.path))
        #expect(prompt.contains("scoped change to the existing product"))
        #expect(prompt.contains("Anything omitted from the Design remains unchanged"))
        #expect(prompt.contains("Prefer the smallest coherent change"))
        #expect(prompt.contains("Keep the reference files unchanged"))
    }

    private func writeDesign(for session: ChatSession, in store: ProjectStore,
                             html: String) throws -> URL {
        let artifact = try #require(store.designArtifactURL(for: session))
        let directory = artifact.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(html.utf8).write(to: artifact)
        return directory
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }
}
