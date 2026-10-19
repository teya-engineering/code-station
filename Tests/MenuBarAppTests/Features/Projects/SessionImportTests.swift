import Foundation
import Testing
@testable import MenuBarApp
@testable import CodeStationCore

// Lines in the shape Claude Code writes to ~/.claude/projects. Only the fields the import
// reads are filled in; the real files carry many more.
private enum History {
    static func line(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func prompt(_ text: String, cwd: String = "/work/app", at time: String = "2026-10-01T10:00:00.000Z",
                       extra: [String: Any] = [:]) -> String {
        line(["type": "user", "cwd": cwd, "sessionId": "s", "entrypoint": "cli",
              "gitBranch": "main", "timestamp": time,
              "message": ["role": "user", "content": text]].merging(extra) { $1 })
    }

    static func assistant(_ blocks: [[String: Any]], at time: String = "2026-10-01T10:00:05.000Z",
                          extra: [String: Any] = [:]) -> String {
        line(["type": "assistant", "cwd": "/work/app", "timestamp": time,
              "message": ["id": "msg_1", "role": "assistant", "content": blocks]].merging(extra) { $1 })
    }

    static func text(_ text: String) -> [String: Any] { ["type": "text", "text": text] }

    static func toolUse(_ id: String, _ name: String = "Bash") -> [String: Any] {
        ["type": "tool_use", "id": id, "name": name, "input": ["command": "ls"]]
    }

    static func toolResult(_ id: String, _ output: String, at time: String = "2026-10-01T10:00:06.000Z") -> String {
        line(["type": "user", "cwd": "/work/app", "timestamp": time,
              "message": ["role": "user",
                          "content": [["type": "tool_result", "tool_use_id": id, "content": output]]]])
    }
}

struct ClaudeTranscriptImportTests {
    @Test func promptsAndRepliesBecomeMessages() {
        let messages = ClaudeTranscriptImport.messages(fromLines: [
            History.prompt("list the files"),
            History.assistant([History.text("Looking.")]),
            History.assistant([History.toolUse("t1")]),
            History.toolResult("t1", "a.swift\nb.swift"),
            History.assistant([History.text("Two files.")]),
        ])

        #expect(messages.map(\.role) == [.user, .assistant])
        #expect(messages[0].text == "list the files")
        // The whole turn is one message, as the app keeps a turn it ran itself.
        #expect(messages[1].text == "Looking.\n\nTwo files.")
        #expect(messages[1].tools.count == 1)
        #expect(messages[1].tools[0].result == "a.swift\nb.swift")
        #expect(messages[1].tools[0].textOffset == "Looking.".count)
        #expect(messages[1].tools[0].finishedAt != nil)
    }

    @Test func aCallThatNeverReportedIsNotLeftRunning() {
        let messages = ClaudeTranscriptImport.messages(fromLines: [
            History.prompt("run it"),
            History.assistant([History.toolUse("t1")]),
            History.prompt("never mind", at: "2026-10-01T10:01:00.000Z"),
        ])

        #expect(messages.count == 3)
        #expect(messages[1].tools.first?.isRunning == false)
    }

    @Test func thinkingIsKeptInPlace() {
        let messages = ClaudeTranscriptImport.messages(fromLines: [
            History.prompt("why"),
            History.assistant([["type": "thinking", "thinking": "Let me see."], History.text("Because.")]),
        ])

        let thought = try! #require(messages.last?.thinking?.first)
        #expect(thought.text == "Let me see.")
        #expect(thought.textOffset == 0)
    }

    @Test func bookkeepingAndSubagentsStayOut() {
        let messages = ClaudeTranscriptImport.messages(fromLines: [
            History.prompt("<local-command-caveat>Caveat</local-command-caveat>", extra: ["isMeta": true]),
            History.prompt("Base directory for this skill: …", extra: ["isMeta": true]),
            History.prompt("<local-command-stdout>done</local-command-stdout>"),
            History.prompt("subagent prompt", extra: ["isSidechain": true]),
            History.assistant([History.text("subagent reply")], extra: ["isSidechain": true]),
            History.line(["type": "file-history-snapshot", "messageId": "x"]),
            History.line(["type": "attachment", "attachment": ["type": "instructions"]]),
            History.prompt("the real question"),
        ])

        #expect(messages.map(\.text) == ["the real question"])
    }

    @Test func slashCommandsReadAsTyped() {
        let messages = ClaudeTranscriptImport.messages(fromLines: [
            History.prompt("<command-name>/rename</command-name>\n<command-message>rename</command-message>\n<command-args>notes</command-args>"),
        ])

        #expect(messages.first?.text == "/rename notes")
    }

    @Test func interruptionsAndCompactionsAreNoted() {
        let messages = ClaudeTranscriptImport.messages(fromLines: [
            History.prompt("go"),
            History.assistant([History.text("Starting.")]),
            History.prompt("[Request interrupted by user for tool use]"),
            History.line(["type": "system", "subtype": "compact_boundary",
                          "timestamp": "2026-10-01T11:00:00.000Z"]),
            History.prompt("summary of the earlier conversation", extra: ["isCompactSummary": true]),
        ])

        #expect(messages.map(\.role) == [.user, .assistant, .system, .system])
        #expect(messages[2].text == "Interrupted.")
    }

    @Test func realTimesAreKept() throws {
        let messages = ClaudeTranscriptImport.messages(fromLines: [
            History.prompt("hello", at: "2026-10-01T10:00:00.250Z"),
        ])

        let date = try #require(messages.first?.date)
        #expect(abs(date.timeIntervalSince1970 - 1_790_848_800.25) < 0.001)
    }
}

struct ClaudeSessionCatalogTests {
    private let scratch = ScratchDirectory(prefix: "claude-history")

    private func write(_ lines: [String], id: String = UUID().uuidString,
                       folder: String = "-work-app") throws -> String {
        let directory = scratch.url.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n")
            .write(to: directory.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
        return id
    }

    @Test func findsSessionsThatRanInTheFolder() throws {
        let id = try write([
            History.prompt("first question"),
            History.line(["type": "ai-title", "aiTitle": "Fix the build", "sessionId": "s"]),
            History.assistant([History.text("ok")], at: "2026-10-02T09:00:00.000Z"),
        ])

        let found = ClaudeSessionCatalog.sessions(in: "/work/app", root: scratch.url)

        #expect(found.map(\.sessionID) == [id])
        #expect(found.first?.displayTitle == "Fix the build")
        #expect(found.first?.firstPrompt == "first question")
        #expect(found.first?.gitBranch == "main")
        #expect(found.first?.lastActivity == ClaudeTranscriptImport.date("2026-10-02T09:00:00.000Z"))
    }

    @Test func aRenameWinsOverTheGeneratedTitle() throws {
        try write([
            History.line(["type": "custom-title", "customTitle": "my name", "sessionId": "s"]),
            History.prompt("question"),
            History.line(["type": "ai-title", "aiTitle": "Generated", "sessionId": "s"]),
            History.assistant([History.text("ok")]),
        ])

        #expect(ClaudeSessionCatalog.sessions(in: "/work/app", root: scratch.url).first?.displayTitle == "my name")
    }

    @Test func otherFoldersAndSubfoldersAreLeftOut() throws {
        try write([History.prompt("elsewhere", cwd: "/work/other"), History.assistant([History.text("ok")])],
                  folder: "-work-other")
        try write([History.prompt("deeper", cwd: "/work/app/Sources"), History.assistant([History.text("ok")])],
                  folder: "-work-app-Sources")

        #expect(ClaudeSessionCatalog.sessions(in: "/work/app", root: scratch.url).isEmpty)
    }

    @Test func aSessionClaudeNeverAnsweredIsLeftOut() throws {
        try write([History.prompt("<command-name>/resume</command-name>")])

        #expect(ClaudeSessionCatalog.sessions(in: "/work/app", root: scratch.url).isEmpty)
    }

    @Test func conversationsTheAppAlreadyHoldsAreLeftOut() throws {
        let kept = try write([History.prompt("new one"), History.assistant([History.text("ok")])])
        let known = try write([History.prompt("already here"), History.assistant([History.text("ok")])])

        let found = ClaudeSessionCatalog.sessions(in: "/work/app", excluding: ["claude:" + known], root: scratch.url)

        #expect(found.map(\.sessionID) == [kept])
    }

    @Test func scriptedRunsAndEmptyFilesAreLeftOut() throws {
        try write([History.prompt("from a script", extra: ["entrypoint": "sdk-cli"]),
                   History.assistant([History.text("ok")])])
        try write([History.line(["type": "mode", "mode": "normal", "cwd": "/work/app"])])
        try write([])

        #expect(ClaudeSessionCatalog.sessions(in: "/work/app", root: scratch.url).isEmpty)
    }

    @Test func newestComeFirst() throws {
        let old = try write([History.prompt("old", at: "2026-09-01T10:00:00.000Z"),
                             History.assistant([History.text("ok")], at: "2026-09-01T10:00:05.000Z")])
        let new = try write([History.prompt("new", at: "2026-10-01T10:00:00.000Z"),
                             History.assistant([History.text("ok")], at: "2026-10-01T10:00:05.000Z")])

        #expect(ClaudeSessionCatalog.sessions(in: "/work/app", root: scratch.url).map(\.sessionID) == [new, old])
    }

    @Test func aPickedClaudeFolderPointsAtItsHistory() throws {
        let claude = scratch.url.appendingPathComponent(".claude", isDirectory: true)
        let projects = claude.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)

        #expect(ClaudeSessionCatalog.historyFolder(from: claude).path == projects.path)
        #expect(ClaudeSessionCatalog.historyFolder(from: projects).path == projects.path)
    }
}

@MainActor
struct ImportedSessionStoreTests {
    private let store: ProjectStore
    private let scratch: ScratchDirectory

    init() {
        (store, scratch) = TestStore.make()
    }

    private func candidate(_ id: String, title: String? = "Imported", cwd: String) -> ExternalSessionCandidate {
        ExternalSessionCandidate(sessionID: id, file: URL(fileURLWithPath: "/dev/null"), cwd: cwd,
                               title: title, firstPrompt: "hello there",
                               startedAt: Date(timeIntervalSince1970: 1_000),
                               lastActivity: Date(timeIntervalSince1970: 2_000),
                               gitBranch: "main", bytes: 10)
    }

    @Test func importedSessionsResumeTheirConversationAndSurviveARelaunch() async throws {
        let project = try TestStore.project(in: store)
        let messages = [ChatMessage(role: .user, text: "hello there", date: Date(timeIntervalSince1970: 1_000)),
                        ChatMessage(role: .assistant, text: "hi", date: Date(timeIntervalSince1970: 2_000))]

        let made = try await store.importSession(
            .init(candidate: candidate("claude-abc", cwd: project.path), messages: messages),
            into: project.id).get()

        let id = made.id
        #expect(!store.isTranscriptLoaded(id))
        let reopened = ProjectStore(storeURL: store.storeURL)
        let session = try #require(reopened.session(id))
        #expect(session.agent == .claudeCode)
        #expect(session.claudeSessionID == "claude-abc")
        #expect(session.title == "Imported")
        #expect(session.createdAt == Date(timeIntervalSince1970: 1_000))
        #expect(reopened.transcript(of: id).map(\.text) == ["hello there", "hi"])
        // Nothing imported can be wound back to: the app never checkpointed it.
        #expect(reopened.transcript(of: id).allSatisfy { $0.checkpoint == nil })
    }

    @Test func anUntitledSessionIsNamedAfterItsFirstPrompt() async throws {
        let project = try TestStore.project(in: store)
        let made = try await store.importSession(
            .init(candidate: candidate("c1", title: nil, cwd: project.path),
                   messages: [ChatMessage(role: .user, text: "fix the login page")]),
            into: project.id).get()

        #expect(made.title == "fix the login page")
    }

    @Test func conversationsAlreadyInTheAppAreKnown() async throws {
        let project = try TestStore.project(in: store)
        let session = store.newSession(in: project.id)
        store.setAgentSessionID("current", agent: .claudeCode, for: session.id)
        var prompt = ChatMessage(role: .user, text: "earlier")
        prompt.checkpoint = ConversationCheckpoint(agent: .claudeCode, claudeSessionID: "before",
                                                   codexSessionID: nil)
        store.append(prompt, to: session.id)

        #expect(await store.knownAgentSessionIDs(inProject: project.id) == ["claude:current", "claude:before"])
    }

    @Test func importingWritesTheTranscriptAndIndexOffTheMainThread() async throws {
        let project = try TestStore.project(in: store)
        var files = PersistentFileClient.live
        files.write = { data, url in
            #expect(!Thread.isMainThread)
            try PersistentFile.write(data, to: url)
        }
        let importing = ProjectStore(preferences: scratch.preferences.store, storeURL: store.storeURL, files: files)
        let item = ProjectStore.SessionImport(candidate: candidate("background", cwd: project.path),
            messages: [ChatMessage(role: .user, text: "Import me")])
        let made = try await importing.importSession(item, into: project.id).get()
        #expect(!importing.isTranscriptLoaded(made.id))
        #expect(ProjectStore(storeURL: store.storeURL).session(made.id) != nil)
    }

    @Test func failedIndexWriteLeavesTheImportAvailableForRetry() async throws {
        let project = try TestStore.project(in: store)
        let index = store.storeURL
        let before = try Data(contentsOf: index)
        var files = PersistentFileClient.live
        files.write = { data, url in
            if url == index { throw CocoaError(.fileWriteNoPermission) }
            try PersistentFile.write(data, to: url)
        }
        let importing = ProjectStore(preferences: scratch.preferences.store, storeURL: index, files: files)
        let item = ProjectStore.SessionImport(candidate: candidate("retry", cwd: project.path),
            messages: [ChatMessage(role: .user, text: "Keep this")])
        guard case .failure(let failure) = await importing.importSession(item, into: project.id) else {
            Issue.record("The failed index write must fail the import")
            return
        }
        #expect(failure.localizedDescription == failure.message)
        #expect(importing.sessions.isEmpty)
        #expect(await importing.knownAgentSessionIDs(inProject: project.id).isEmpty)
        #expect(try Data(contentsOf: index) == before)
        #expect(try FileManager.default.contentsOfDirectory(at: importing.transcriptsURL,
                                                            includingPropertiesForKeys: nil).isEmpty)
        let reopened = ProjectStore(preferences: scratch.preferences.store, storeURL: index)
        let made = try await reopened.importSession(item, into: project.id).get()
        #expect(reopened.transcript(of: made.id).first?.text == "Keep this")
    }

    @Test func aForkKeepsTheImportedClaudeHistoryDirectory() async throws {
        let project = try TestStore.project(in: store)
        let made = try await store.importSession(.init(candidate: candidate("original", cwd: project.path),
            messages: [ChatMessage(role: .user, text: "Start")]), into: project.id).get()
        var prompt = ChatMessage(role: .user, text: "Continue")
        prompt.checkpoint = ConversationCheckpoint(agent: .claudeCode, claudeSessionID: "original", codexSessionID: nil)
        store.append(prompt, to: made.id)
        let fork = try #require(store.forkSession(made.id, before: prompt.id))
        #expect(fork.importedOrigin == made.importedOrigin)
        #expect(fork.knownAgentSessionIDs == made.knownAgentSessionIDs)
    }
}
