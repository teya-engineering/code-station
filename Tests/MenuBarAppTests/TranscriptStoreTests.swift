import Foundation
import Testing
@testable import MenuBarApp

// Where a conversation lives and when it is in memory. A session the app is not showing
// has to cost nothing but its record, and still be able to say what it did - so what the
// sidebar reads is checked after the conversation has gone, not just before.
@MainActor
struct TranscriptStoreTests {

    private func makeStore() -> ProjectStore {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("code-station-tests-\(UUID().uuidString).json").path
        setenv("CODE_STATION_STORE", path, 1)
        return ProjectStore()
    }

    private func project(in store: ProjectStore) -> Project {
        store.addProject(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("project-\(UUID().uuidString)"))!
    }

    // An edit of one line into another, which is the +1 -1 the sidebar counts.
    private func edit(id: String = UUID().uuidString, result: String? = "ok") -> ToolUse {
        ToolUse(id: id,
                name: "Edit",
                input: #"{"file_path":"/tmp/x.swift","old_string":"one\ntwo","new_string":"one\nthree"}"#,
                result: result)
    }

    @Test func sessionsPersistTheirAgentAndInitialModel() throws {
        let store = makeStore()
        let session = store.newSession(in: project(in: store).id,
                                       agent: .codex,
                                       model: "gpt-5.6-terra")

        #expect(session.agent == .codex)
        #expect(session.settings?.model == "gpt-5.6-terra")
        #expect(store.save())

        let loaded = try #require(ProjectStore(storeURL: store.storeURL).session(session.id))
        #expect(loaded.agent == .codex)
        #expect(loaded.settings?.model == "gpt-5.6-terra")
    }

    @Test func aStartedSessionCanChangeItsModelWithoutChangingAgent() throws {
        let store = makeStore()
        let session = store.newSession(in: project(in: store).id,
                                       agent: .codex,
                                       model: "gpt-5.6-terra")
        store.setSettings(SessionSettings(model: "gpt-5.6-sol"), for: session.id)
        #expect(store.session(session.id)?.settings?.model == "gpt-5.6-sol")

        store.append(ChatMessage(role: .user, text: "Start working"), to: session.id)
        store.setSettings(SessionSettings(model: "gpt-5.6-terra", effort: "high"),
                          for: session.id)

        let started = try #require(store.session(session.id))
        #expect(started.hasStarted)
        #expect(started.agent == .codex)
        #expect(started.settings?.model == "gpt-5.6-terra")
        #expect(started.settings?.effort == "high")
    }

    @Test func sessionsWrittenBeforeAgentPinningRecoverCodexFromTheirResumeID() throws {
        let projectID = UUID()
        let sessionID = UUID()
        let data = Data("""
        {
          "id": "\(sessionID.uuidString)",
          "projectID": "\(projectID.uuidString)",
          "codexSessionID": "thread-1"
        }
        """.utf8)

        let session = try JSONDecoder().decode(ChatSession.self, from: data)

        #expect(session.agent == .codex)
        #expect(session.hasStarted)
    }

    private func indexJSON(_ store: ProjectStore) -> String {
        (try? String(contentsOf: store.storeURL, encoding: .utf8)) ?? ""
    }

    private func transcriptFile(_ store: ProjectStore, _ sessionID: UUID) -> URL {
        store.transcriptsURL.appendingPathComponent("\(sessionID.uuidString).json")
    }

    @Test func writesTheConversationBesideTheIndexRatherThanInIt() {
        let store = makeStore()
        let session = store.newSession(in: project(in: store).id)
        store.append(ChatMessage(role: .assistant, text: "the body of the reply"), to: session.id)
        store.save()

        let index = indexJSON(store)
        #expect(!index.contains("the body of the reply"))
        #expect(!index.contains("\"messages\""))
        let written = try? String(contentsOf: transcriptFile(store, session.id), encoding: .utf8)
        #expect(written?.contains("the body of the reply") == true)
    }

    @Test func letsGoOfAConversationOnceNothingIsLookingAtIt() {
        let store = makeStore()
        let project = project(in: store)
        let first = store.newSession(in: project.id)
        store.append(ChatMessage(role: .user, text: "hello there"), to: first.id)

        let second = store.newSession(in: project.id)
        store.selection = .session(second.id)
        // Closing a session does not stop to write it, so the messages go once the write
        // they owe has landed rather than inside the click that closed them.
        #expect(store.save())

        #expect(!store.isTranscriptLoaded(first.id))
        #expect(store.session(first.id)?.messages.isEmpty == true)
        // Gone from memory, not lost: asking for it reads it back.
        #expect(store.transcript(of: first.id).first?.text == "hello there")
    }

    @Test func selectingAProjectClosesTheOpenSession() {
        let store = makeStore()
        let project = project(in: store)
        let session = store.newSession(in: project.id)

        store.selectProject(project.id)

        #expect(store.selection == nil)
        #expect(store.selectedProjectID == project.id)
        #expect(store.sessions.count == 1)
        #expect(!store.isTranscriptLoaded(session.id))
    }

    @Test func selectingHomeClosesTheOpenSessionWithoutForgettingItsProject() {
        let store = makeStore()
        let project = project(in: store)
        let session = store.newSession(in: project.id)

        store.selectHome()

        #expect(store.selection == .home)
        #expect(store.selectedProjectID == project.id)
        #expect(!store.isTranscriptLoaded(session.id))
    }

    // Whatever streamed in last has to reach the disk before the messages are dropped,
    // debounce or no debounce. Encoding a conversation is too much to put inside the
    // click that closed it, so the messages wait in memory for the write instead.
    @Test func keepsWhatIsPendingUntilItHasBeenWritten() {
        let store = makeStore()
        let session = store.newSession(in: project(in: store).id)
        store.append(ChatMessage(role: .assistant, text: "half a reply"), to: session.id)

        store.selectHome()
        #expect(store.isTranscriptLoaded(session.id))

        #expect(store.save())

        let written = try? String(contentsOf: transcriptFile(store, session.id), encoding: .utf8)
        #expect(written?.contains("half a reply") == true)
        #expect(!store.isTranscriptLoaded(session.id))
    }

    // Opening a session reads its conversation off the main actor, so the click that
    // opened it returns before the messages are there.
    @Test func readsAnOpenedConversationWithoutBlockingTheClick() async {
        let store = makeStore()
        let project = project(in: store)
        let session = store.newSession(in: project.id)
        store.append(ChatMessage(role: .user, text: "hello there"), to: session.id)
        store.selection = .session(store.newSession(in: project.id).id)
        #expect(store.save())
        #expect(!store.isTranscriptLoaded(session.id))

        store.selection = .session(session.id)

        #expect(store.isTranscriptLoading(session.id))
        #expect(store.session(session.id)?.messages.isEmpty == true)

        await store.transcriptReady(session.id)

        #expect(!store.isTranscriptLoading(session.id))
        #expect(store.session(session.id)?.messages.first?.text == "hello there")
    }

    // The sidebar draws every session, including the ones whose conversation is not in
    // memory, so everything it reads has to outlive the transcript.
    @Test func keepsWhatTheSidebarShowsAfterTheConversationGoes() {
        let store = makeStore()
        let project = project(in: store)
        let session = store.newSession(in: project.id)
        let sent = Date(timeIntervalSince1970: 1_800_000_000)
        store.append(ChatMessage(role: .assistant, text: "", tools: [edit()], date: sent),
                     to: session.id)

        store.selection = .session(store.newSession(in: project.id).id)
        #expect(store.save())

        let summary = store.session(session.id)?.summary
        #expect(summary?.added == 1)
        #expect(summary?.removed == 1)
        #expect(summary?.lastTool == "Edit · /tmp/x.swift")
        #expect(store.session(session.id)?.lastActivity == sent)
    }

    // A closed session is usually opened again, and building the diff of every edit in it
    // is the expensive half of drawing one. What was built to draw it stays behind.
    @Test func keepsToolPresentationsAfterTheConversationGoes() {
        let store = makeStore()
        let project = project(in: store)
        let session = store.newSession(in: project.id)
        let callID = "kept-\(UUID().uuidString)"
        store.append(ChatMessage(role: .assistant, tools: [edit(id: callID)]), to: session.id)

        store.selection = .session(store.newSession(in: project.id).id)
        #expect(store.save())
        #expect(!store.isTranscriptLoaded(session.id))

        // The same call id carrying nothing: a rebuilt presentation would have no file to
        // name, a kept one still says what the call did.
        let again = ToolPresentationCache.presentation(
            for: ToolUse(id: callID, name: "Edit", input: "{}", result: "ok"),
            projectPath: project.path)
        #expect(again.argument == "/tmp/x.swift")
        #expect(again.added == 1)
    }

    @Test func sidebarCopyTracksMetadataWithoutCarryingTheTranscript() throws {
        let store = makeStore()
        let session = store.newSession(in: project(in: store).id)
        store.append(ChatMessage(role: .user, text: "Investigate CPU usage"), to: session.id)
        store.append(ChatMessage(role: .assistant, tools: [edit()]), to: session.id)
        #expect(store.save())

        let sidebarSession = try #require(store.sidebarSession(session.id))
        #expect(sidebarSession.title == "Investigate CPU usage")
        #expect(sidebarSession.summary.added == 1)
        #expect(sidebarSession.messages.isEmpty)
        #expect(!sidebarSession.transcriptLoaded)
    }

    @Test func askingInAnOlderSessionMovesItAheadOfNewerSessions() throws {
        let store = makeStore()
        let project = project(in: store)
        let older = store.newSession(in: project.id)
        let newer = store.newSession(in: project.id)
        let sent = Date().addingTimeInterval(60)

        store.append(ChatMessage(role: .user, text: "Make another change", date: sent),
                     to: older.id)

        #expect(store.standaloneSessions(for: project.id).map(\.id) == [older.id, newer.id])
        #expect(try #require(store.sidebarSession(older.id)).lastActivity == sent)
    }

    @Test func derivesSidebarSummaryAwayFromTheMainActor() async {
        let sent = Date(timeIntervalSince1970: 1_800_000_000)
        let messages = [ChatMessage(role: .assistant, text: "", tools: [edit()], date: sent)]

        let summary = await Task.detached {
            SessionSummary.of(messages, projectPath: "/tmp")
        }.value

        #expect(summary.added == 1)
        #expect(summary.removed == 1)
        #expect(summary.lastTool == "Edit · x.swift")
        #expect(summary.lastMessageAt == sent)
    }

    @Test func transcriptWindowAddsEarlierMessagesInBoundedPages() {
        let messages = (0..<8).map { ChatMessage(role: .user, text: "\($0)") }
        var window = TranscriptWindow(openingPage: 3, step: 3)

        #expect(window.visibleMessages(in: messages).map(\.text) == ["5", "6", "7"])
        #expect(window.hiddenCount(totalCount: messages.count) == 5)

        window.loadEarlier(totalCount: messages.count)
        #expect(window.visibleMessages(in: messages).map(\.text) == ["2", "3", "4", "5", "6", "7"])
        #expect(window.hiddenCount(totalCount: messages.count) == 2)

        window.loadEarlier(totalCount: messages.count)
        #expect(window.visibleMessages(in: messages).map(\.text)
            == ["0", "1", "2", "3", "4", "5", "6", "7"])
        #expect(window.hiddenCount(totalCount: messages.count) == 0)
    }

    // Opening is paid before anything is on screen, reading back is asked for, so the
    // second page is not held to the size of the first.
    @Test func transcriptWindowReadsBackInLargerPagesThanItOpensWith() {
        var window = TranscriptWindow(openingPage: 2, step: 6)

        #expect(window.visibleCount == 2)

        window.loadEarlier(totalCount: 20)

        #expect(window.visibleCount == 8)
    }

    @Test func transcriptWindowResetsWhenAViewChangesSessions() {
        var window = TranscriptWindow(openingPage: 2, step: 2)
        window.loadEarlier(totalCount: 5)
        #expect(window.visibleCount == 4)

        window.reset()

        #expect(window.visibleCount == 2)
    }

    // A turn runs in a session nobody has open, and the reply has to land somewhere.
    @Test func holdsAConversationThatIsStillBeingWrittenTo() {
        let store = makeStore()
        let project = project(in: store)
        let running = store.newSession(in: project.id)
        store.hold(running.id, for: .running)

        store.selection = .session(store.newSession(in: project.id).id)
        #expect(store.isTranscriptLoaded(running.id))

        store.release(running.id, for: .running)
        #expect(!store.isTranscriptLoaded(running.id))
    }

    // The same reason twice is one hold: a queued prompt starting while the session is
    // already running must not leave a hold behind that nothing gives back.
    @Test func countsAReasonOnceHoweverOftenItIsGiven() {
        let store = makeStore()
        let session = store.newSession(in: project(in: store).id)
        store.hold(session.id, for: .running)
        store.hold(session.id, for: .running)
        store.selection = nil

        store.release(session.id, for: .running)
        #expect(!store.isTranscriptLoaded(session.id))
    }

    @Test func deletingASessionTakesItsConversationWithIt() {
        let store = makeStore()
        let session = store.newSession(in: project(in: store).id)
        store.append(ChatMessage(role: .user, text: "hello there"), to: session.id)
        store.save()
        let file = transcriptFile(store, session.id)
        #expect(FileManager.default.fileExists(atPath: file.path))

        store.removeSession(session.id)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func removingAProjectTakesTheConversationsOfEverySessionInIt() {
        let store = makeStore()
        let project = project(in: store)
        let session = store.newSession(in: project.id)
        store.append(ChatMessage(role: .user, text: "hello there"), to: session.id)
        store.save()

        store.removeProject(project.id)
        #expect(!FileManager.default.fileExists(atPath: transcriptFile(store, session.id).path))
    }

    @Test func workspaceSessionsKeepAnOrderedSnapshotOfTheirDirectories() throws {
        let store = makeStore()
        let api = project(in: store)
        let web = project(in: store)
        let workspace = try #require(store.addWorkspace(name: "Checkout",
                                                        projectIDs: [web.id, api.id],
                                                        leadProjectID: api.id))
        let session = try #require(store.newSession(
            in: workspace.id,
            projects: [
                SessionProject(projectID: api.id, worktreePath: "/work/api", worktreeBranch: "code-station/1"),
                SessionProject(projectID: web.id, worktreePath: nil, worktreeBranch: nil),
            ],
            agentAvatarName: AgentAvatarSelection.nonBotName))

        #expect(session.projectID == api.id)
        #expect(session.agentAvatarName == AgentAvatarSelection.nonBotName)
        #expect(store.workingDirectories(for: session) == ["/work/api", web.path])
        #expect(store.gitMetadataDirectories(for: session) == [api.path + "/.git"])
        #expect(store.standaloneSessions(for: api.id).isEmpty)
        #expect(store.sessions(in: workspace.id).map(\.id) == [session.id])
    }

    @Test func workspacesSurviveAnIndexRoundTrip() throws {
        let store = makeStore()
        let first = project(in: store)
        let second = project(in: store)
        let workspace = try #require(store.addWorkspace(name: "Payments",
                                                        projectIDs: [first.id, second.id],
                                                        leadProjectID: second.id))
        store.save()

        let loaded = ProjectStore()

        #expect(loaded.workspace(workspace.id)?.name == "Payments")
        #expect(loaded.workspace(workspace.id)?.projectIDs == [second.id, first.id])
        #expect(loaded.workspace(workspace.id)?.leadProjectID == second.id)
    }

    @Test func removingAnAttachedProjectRemovesSessionsThatUseIt() throws {
        let store = makeStore()
        let first = project(in: store)
        let second = project(in: store)
        let workspace = try #require(store.addWorkspace(name: "Checkout",
                                                        projectIDs: [first.id, second.id],
                                                        leadProjectID: first.id))
        let session = try #require(store.newSession(
            in: workspace.id,
            projects: [SessionProject(projectID: first.id, worktreePath: nil,
                                      worktreeBranch: nil),
                       SessionProject(projectID: second.id, worktreePath: nil,
                                      worktreeBranch: nil)]))

        store.removeProject(second.id)

        #expect(store.session(session.id) == nil)
        #expect(store.workspace(workspace.id) == nil)
    }

    // MARK: - Answering mid-turn

    // A turn writes everything it says into the message it opened with, so an answer
    // appended while it runs would sit under every call the answer led to. The reply is
    // split around it instead: what came before stays put, what comes after goes into a
    // message of its own that is genuinely later in the conversation.
    @Test func splitsTheReplyAroundAnAnswerGivenWhileItRuns() {
        let store = makeStore()
        let session = store.newSession(in: project(in: store).id)
        store.append(ChatMessage(role: .user, text: "do the thing"), to: session.id)
        var reply = ChatMessage(role: .assistant, text: "Looking into it")
        reply.tools = [edit()]
        store.append(reply, to: session.id)

        let carriesOn = store.recordAnswer("Full split", in: session.id, continuing: reply.id)

        let messages = store.transcript(of: session.id)
        #expect(messages.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(messages[1].id == reply.id)
        #expect(messages[2].text == "Full split")
        #expect(messages[3].id == carriesOn)

        // Whatever the turn does next lands after the answer rather than above it.
        store.updateMessage(carriesOn!, in: session.id) { $0.text = "carrying on" }
        #expect(store.transcript(of: session.id).last?.text == "carrying on")
    }

    // The question can arrive before the turn has said anything, and an empty half of a
    // reply above the answer is just a gap.
    @Test func dropsAnEmptyReplyRatherThanLeavingItAboveTheAnswer() {
        let store = makeStore()
        let session = store.newSession(in: project(in: store).id)
        let opened = ChatMessage(role: .assistant)
        store.append(opened, to: session.id)

        _ = store.recordAnswer("Full split", in: session.id, continuing: opened.id)

        let messages = store.transcript(of: session.id)
        #expect(messages.map(\.role) == [.user, .assistant])
        #expect(!messages.contains { $0.id == opened.id })
    }

    // MARK: - Legacy inline transcripts

    // Legacy stores can hold conversations inline without summaries. Loading one splits
    // the conversations into their own files and derives the missing summaries.
    @Test func movesConversationsOutOfAFileThatKeptThemInline() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("code-station-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("projects.json")

        let projectID = UUID(), sessionID = UUID()
        let legacy = """
        {
          "projects": [{"id": "\(projectID.uuidString)", "name": "app", "path": "/tmp/app"}],
          "sessions": [{
            "id": "\(sessionID.uuidString)",
            "projectID": "\(projectID.uuidString)",
            "title": "an older conversation",
            "createdAt": "2024-01-01T00:00:00Z",
            "messages": [{
              "id": "\(UUID().uuidString)",
              "role": "assistant",
              "text": "said something",
              "date": "2024-01-02T00:00:00Z",
              "tools": [{
                "id": "call-1",
                "name": "Edit",
                "isError": false,
                "input": "{\\"file_path\\":\\"/tmp/app/x.swift\\",\\"old_string\\":\\"one\\\\ntwo\\",\\"new_string\\":\\"one\\\\nthree\\"}",
                "result": "ok"
              }]
            }]
          }]
        }
        """
        try legacy.write(to: path, atomically: true, encoding: .utf8)
        setenv("CODE_STATION_STORE", path.path, 1)

        let store = ProjectStore()

        // Read once, then out of memory like any other conversation nobody is holding.
        #expect(!store.isTranscriptLoaded(sessionID))
        #expect(store.transcript(of: sessionID).first?.text == "said something")

        // The index it rewrites no longer carries any of it, and says what the sidebar
        // would otherwise have had to open the conversation to find out.
        let index = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        #expect(!index.contains("said something"))
        let summary = store.session(sessionID)?.summary
        #expect(summary?.added == 1)
        #expect(summary?.removed == 1)
        #expect(summary?.lastTool == "Edit · x.swift")
        #expect(store.session(sessionID)?.lastActivity
            == ISO8601DateFormatter().date(from: "2024-01-02T00:00:00Z"))
    }
}
