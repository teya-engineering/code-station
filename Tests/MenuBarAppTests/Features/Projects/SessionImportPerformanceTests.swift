import Foundation
import Testing
@testable import MenuBarApp
@testable import CodeStationCore

struct SessionImportCatalogPerformanceTests {
    @Test func concurrentChecksShareOneAgentListingAndReuseIt() async throws {
        actor Calls {
            var count = 0
            func record() { count += 1 }
        }
        let scratch = ScratchDirectory(prefix: "import-coalescing")
        try FileManager.default.createDirectory(at: scratch.path("sessions"), withIntermediateDirectories: true)
        let calls = Calls()
        let catalog = SessionHistoryCatalog { _, _, _ in
            await calls.record()
            try await Task.sleep(for: .milliseconds(50))
            return []
        }
        let roots: [AgentKind: URL] = [.codex: scratch.url]
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { _ = await catalog.sessions(in: "/work/app", roots: roots) }
            }
        }
        _ = await catalog.sessions(in: "/work/app", roots: roots)
        #expect(await calls.count == 1)
        _ = await catalog.sessions(in: "/work/app", roots: roots, force: true)
        #expect(await calls.count == 2)
    }

    @Test func onlyReadsMatchingProjectAndReusesUnchangedFiles() async throws {
        let scratch = ScratchDirectory(prefix: "import-cache")
        let folder = scratch.url.appendingPathComponent("-work-app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("one.jsonl")
        let lines = """
        {"type":"user","cwd":"/work/app","timestamp":"2026-10-01T10:00:00Z","message":{"content":"Hello"}}
        {"type":"assistant","timestamp":"2026-10-01T10:00:01Z","message":{"content":[{"type":"text","text":"Hi"}]}}
        """
        try lines.write(to: file, atomically: true, encoding: .utf8)
        let elsewhere = scratch.url.appendingPathComponent("-work-other")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try lines.write(to: elsewhere.appendingPathComponent("ignored.jsonl"), atomically: true, encoding: .utf8)
        let catalog = SessionHistoryCatalog()
        let roots: [AgentKind: URL] = [.claudeCode: scratch.url]

        #expect(await catalog.sessions(in: "/work/app", roots: roots).candidates.count == 1)
        #expect(await catalog.fileReads == 1)
        #expect(await catalog.sessions(in: "/work/app", roots: roots, force: true).candidates.count == 1)
        #expect(await catalog.fileReads == 1)

        try (lines + "\n{\"type\":\"custom-title\",\"customTitle\":\"Renamed\"}\n")
            .write(to: file, atomically: true, encoding: .utf8)
        #expect(await catalog.sessions(in: "/work/app", roots: roots, force: true)
            .candidates.first?.title == "Renamed")
        #expect(await catalog.fileReads == 2)
        try FileManager.default.removeItem(at: file)
        #expect(await catalog.sessions(in: "/work/app", roots: roots, force: true).candidates.isEmpty)
    }
}

@MainActor
struct SessionImportMemoryTests {
    @Test func duplicateDetectionLeavesClosedTranscriptsUnloaded() async throws {
        let (store, scratch) = TestStore.make()
        defer { withExtendedLifetime(scratch) {} }
        let project = try TestStore.project(in: store)
        let session = store.newSession(in: project.id)
        var message = ChatMessage(role: .user, text: "Earlier")
        message.checkpoint = ConversationCheckpoint(agent: .claudeCode, claudeSessionID: "earlier", codexSessionID: nil)
        store.append(message, to: session.id)
        store.selectProject(project.id)
        #expect(store.save())
        let reopened = ProjectStore(storeURL: store.storeURL)

        #expect(await reopened.knownAgentSessionIDs(inProject: project.id).contains("claude:earlier"))
        #expect(!reopened.isTranscriptLoaded(session.id))
    }

    @Test func olderIndexesAreBackfilledWithoutHoldingTheirTranscripts() async throws {
        let (store, scratch) = TestStore.make()
        defer { withExtendedLifetime(scratch) {} }
        let project = try TestStore.project(in: store)
        let session = store.newSession(in: project.id)
        var message = ChatMessage(role: .user, text: "Earlier")
        message.checkpoint = ConversationCheckpoint(agent: .claudeCode, claudeSessionID: "old", codexSessionID: nil)
        store.append(message, to: session.id)
        store.selectProject(project.id)
        #expect(store.save())
        var saved = try JSONSerialization.jsonObject(with: Data(contentsOf: store.storeURL)) as! [String: Any]
        var sessions = saved["sessions"] as! [[String: Any]]
        for i in sessions.indices { sessions[i].removeValue(forKey: "knownAgentSessionIDs") }
        saved["sessions"] = sessions
        try JSONSerialization.data(withJSONObject: saved).write(to: store.storeURL)
        let reopened = ProjectStore(storeURL: store.storeURL)

        #expect(await reopened.knownAgentSessionIDs(inProject: project.id).contains("claude:old"))
        #expect(!reopened.isTranscriptLoaded(session.id))
        #expect(reopened.save())
        let again = ProjectStore(storeURL: store.storeURL)
        #expect(again.session(session.id)?.knownAgentSessionIDs == ["claude:old"])
    }
}
