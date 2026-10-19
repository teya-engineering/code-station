import Foundation
import Testing
@testable import CodeStationCore

// Answering what the agent asks back through the station commands façade: a tool waiting
// for permission (allow once, allow always, deny) and a question with options. The fake
// Claude CLI parks its turn on a control request and checks the answer line it is sent,
// as the real CLI reads it. The recording host hears needs-input the moment the request
// arrives, as the GUI's notifier does.
@MainActor
struct StationPermissionTests {

    private static let questionRequest = #"{"type":"control_request","request_id":"q1","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[{"question":"Which database?","header":"Storage","multiSelect":false,"options":[{"label":"SQLite","description":"A file"},{"label":"Postgres","description":"A server"}]},{"question":"Which features?","header":"Features","multiSelect":true,"options":[{"label":"Search","description":""},{"label":"Sync","description":""}]}]}}}"#

    private static let writeRequest = #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Write","input":{"file_path":"/tmp/p/hello.txt","content":"hi"},"tool_use_id":"toolu_1"}}"#

    // Allowing once lets the parked call run, the open session and the list both stop
    // asking, and the host hears the request, its notice taken back, then the turn end.
    @Test(arguments: StationImplementation.allCases)
    func allowingOnceLetsTheAgentCarryOn(_ kind: StationImplementation) async throws {
        let host = RecordingHost()
        let fixture = try RunnerHarness(agent: .claudeCode, script: """
        IFS= read -r input
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
        printf '%s\\n' '\(Self.writeRequest)'
        IFS= read -r answer
        case "$answer" in *'"behavior":"allow"'*) ;; *) exit 7 ;; esac
        case "$answer" in *updatedPermissions*) exit 8 ;; esac
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Wrote it."}]}}'
        """, host: host)
        defer { fixture.tearDown() }
        let session = try await Opened(fixture, kind)

        try await session.commands.sendPrompt(session.id, prompt: "Write hello")

        #expect(await waitUntil { session.log.mirror?.permission != nil })
        let permission = try #require(session.log.mirror?.permission)
        #expect(permission.id == "r1")
        #expect(permission.kind == "permission")
        #expect(permission.toolName == "Write")
        #expect(host.events == [.needsInput(fixture.session.id, requestID: "r1")])

        try await session.commands.answerPermission(session.id, requestID: "r1", answer: .allowOnce)

        #expect(await waitUntil { session.log.mirror?.header.isBusy == false })
        #expect(session.log.mirror?.permission == nil)
        #expect(session.log.mirror?.messages.last?.text.hasSuffix("Wrote it.") == true)
        #expect(host.events == [.needsInput(fixture.session.id, requestID: "r1"), .clear(fixture.session.id),
                                .sound, .turnEnded(fixture.session.id, failure: nil)])
    }

    // Allowing always hands the CLI back the rule it offered, so it stops asking. The
    // open session names what "always" means before it is chosen.
    @Test(arguments: StationImplementation.allCases)
    func allowingAlwaysHandsBackTheRuleTheAgentOffered(_ kind: StationImplementation) async throws {
        let host = RecordingHost()
        let fixture = try RunnerHarness(agent: .claudeCode, script: """
        IFS= read -r input
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
        printf '%s\\n' '{"type":"control_request","request_id":"r2","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"swift build"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"swift build"}],"behavior":"allow","destination":"localSettings"}]}}'
        IFS= read -r answer
        case "$answer" in *'"behavior":"allow"'*) ;; *) exit 7 ;; esac
        case "$answer" in *'"updatedPermissions"'*) ;; *) exit 8 ;; esac
        case "$answer" in *'"ruleContent":"swift build"'*) ;; *) exit 9 ;; esac
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Built."}]}}'
        """, host: host)
        defer { fixture.tearDown() }
        let session = try await Opened(fixture, kind)

        try await session.commands.sendPrompt(session.id, prompt: "Build it")

        #expect(await waitUntil { session.log.mirror?.permission != nil })
        let permission = try #require(session.log.mirror?.permission)
        #expect(permission.subject == "swift build")
        #expect(permission.alwaysTitle == "Always allow Bash")

        try await session.commands.answerPermission(session.id, requestID: "r2", answer: .allowAlways)

        #expect(await waitUntil { session.log.mirror?.header.isBusy == false })
        #expect(session.log.mirror?.messages.last?.text.hasSuffix("Built.") == true)
        #expect(host.endings.map(\.failure) == [nil])
    }

    // Denying refuses the call and the agent carries on without it. A reason given with
    // the denial reaches the agent as the next prompt.
    @Test(arguments: StationImplementation.allCases)
    func denyingRefusesTheCallAndPassesTheReasonOn(_ kind: StationImplementation) async throws {
        let host = RecordingHost()
        let fixture = try RunnerHarness(agent: .claudeCode, script: """
        IFS= read -r input
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
        case "$input" in
          *"Use a scratch file"*)
            printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Using a scratch file."}]}}'
            exit 0 ;;
        esac
        printf '%s\\n' '\(Self.writeRequest)'
        IFS= read -r answer
        case "$answer" in *'"behavior":"deny"'*) ;; *) exit 7 ;; esac
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Left it alone."}]}}'
        """, host: host)
        defer { fixture.tearDown() }
        let session = try await Opened(fixture, kind)

        try await session.commands.sendPrompt(session.id, prompt: "Write hello")
        #expect(await waitUntil { session.log.mirror?.permission != nil })

        try await session.commands.answerPermission(session.id, requestID: "r1", answer: .deny,
                                              reason: "  Use a scratch file  ")

        #expect(await waitUntil {
            session.log.mirror?.header.isBusy == false
                && session.log.mirror?.messages.last?.text == "Using a scratch file."
        })
        let texts = session.log.mirror?.messages.map(\.text) ?? []
        #expect(texts.contains { $0.hasSuffix("Left it alone.") })
        #expect(texts.contains("Use a scratch file"))
        #expect(session.log.mirror?.permission == nil)
        #expect(host.events.first == .needsInput(fixture.session.id, requestID: "r1"))
        #expect(host.events.contains(.clear(fixture.session.id)))
    }

    // A question is answered with one answer per question, keyed by its text. The
    // answers go back inside the tool's input, the transcript records them, and the
    // agent carries on.
    @Test(arguments: StationImplementation.allCases)
    func answeringAQuestionLetsTheAgentCarryOn(_ kind: StationImplementation) async throws {
        let host = RecordingHost()
        let fixture = try RunnerHarness(agent: .claudeCode, script: """
        IFS= read -r input
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
        printf '%s\\n' '\(Self.questionRequest)'
        IFS= read -r answer
        case "$answer" in *'"Which database?":"SQLite"'*) ;; *) exit 7 ;; esac
        case "$answer" in *'"Which features?":"Search, Sync"'*) ;; *) exit 8 ;; esac
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"SQLite it is."}]}}'
        """, host: host)
        defer { fixture.tearDown() }
        let session = try await Opened(fixture, kind)

        try await session.commands.sendPrompt(session.id, prompt: "Set up storage")

        #expect(await waitUntil { session.log.mirror?.permission != nil })
        let question = try #require(session.log.mirror?.permission)
        #expect(question.kind == "question")
        #expect(question.questions.map(\.text) == ["Which database?", "Which features?"])
        #expect(question.questions.map(\.multiSelect) == [false, true])
        #expect(question.questions.first?.options.map(\.label) == ["SQLite", "Postgres"])
        #expect(host.events == [.needsInput(fixture.session.id, requestID: "q1")])

        try await session.commands.answerPermission(session.id, requestID: "q1", answer: .answers,
                                              answers: ["Which database?": "SQLite",
                                                        "Which features?": "Search, Sync"])

        #expect(await waitUntil { session.log.mirror?.header.isBusy == false })
        let texts = session.log.mirror?.messages.map(\.text) ?? []
        #expect(texts.contains { $0.contains("Which database?\n→ SQLite") })
        #expect(texts.last?.hasSuffix("SQLite it is.") == true)
        #expect(host.events == [.needsInput(fixture.session.id, requestID: "q1"), .clear(fixture.session.id),
                                .sound, .turnEnded(fixture.session.id, failure: nil)])
    }

    // Skipping a question is a denial, as the GUI's Skip is.
    @Test(arguments: StationImplementation.allCases)
    func aQuestionCanBeSkipped(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: """
        IFS= read -r input
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
        printf '%s\\n' '\(Self.questionRequest)'
        IFS= read -r answer
        case "$answer" in *'"behavior":"deny"'*) ;; *) exit 7 ;; esac
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"I will pick."}]}}'
        """, host: RecordingHost())
        defer { fixture.tearDown() }
        let session = try await Opened(fixture, kind)

        try await session.commands.sendPrompt(session.id, prompt: "Set up storage")
        #expect(await waitUntil { session.log.mirror?.permission != nil })
        try await session.commands.answerPermission(session.id, requestID: "q1", answer: .deny)

        #expect(await waitUntil { session.log.mirror?.header.isBusy == false })
        #expect(session.log.mirror?.messages.last?.text.hasSuffix("I will pick.") == true)
    }

    // An answer that does not fit what is being asked is turned down in words a front end
    // shows as they are, and the request keeps waiting.
    @Test(arguments: StationImplementation.allCases)
    func answersThatDoNotFitAreRefused(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: """
        IFS= read -r input
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
        case "$input" in
          *"question"*) printf '%s\\n' '\(Self.questionRequest)' ;;
          *) printf '%s\\n' '\(Self.writeRequest)' ;;
        esac
        IFS= read -r answer
        """, host: RecordingHost())
        defer { fixture.tearDown() }
        let session = try await Opened(fixture, kind)
        let commands = session.commands
        let id = session.id

        await #expect(throws: StationRefusal("That question is no longer waiting for an answer.")) {
            try await commands.answerPermission(id, requestID: "r1", answer: .allowOnce)
        }
        try await commands.sendPrompt(id, prompt: "permission please")
        #expect(await waitUntil { session.log.mirror?.permission?.id == "r1" })

        await #expect(throws: StationRefusal("That session is no longer available.")) {
            try await commands.answerPermission(UUID().uuidString, requestID: "r1", answer: .allowOnce)
        }
        await #expect(throws: StationRefusal("That question is no longer waiting for an answer.")) {
            try await commands.answerPermission(id, requestID: "r0", answer: .allowOnce)
        }
        // The Write call offered no rule, so there is no "always" to choose.
        await #expect(throws: StationRefusal("That answer is not valid for this question.")) {
            try await commands.answerPermission(id, requestID: "r1", answer: .allowAlways)
        }
        await #expect(throws: StationRefusal("That answer is not valid for this question.")) {
            try await commands.answerPermission(id, requestID: "r1", answer: .answers, answers: ["x": "y"])
        }
        #expect(fixture.runner.question(fixture.session.id)?.id == "r1")

        try await commands.stopTurn(id)
        #expect(await waitUntil { session.log.mirror?.header.isBusy == false })
        try await commands.sendPrompt(id, prompt: "a question please")
        #expect(await waitUntil { session.log.mirror?.permission?.id == "q1" })

        await #expect(throws: StationRefusal("That answer is not valid for this question.")) {
            try await commands.answerPermission(id, requestID: "q1", answer: .allowOnce)
        }
        await #expect(throws: StationRefusal("Answer every question first.")) {
            try await commands.answerPermission(id, requestID: "q1", answer: .answers,
                                          answers: ["Which database?": "SQLite", "Which features?": "  "])
        }
        #expect(fixture.runner.question(fixture.session.id)?.id == "q1")

        let kinds: [RemoteCommand.Answer] = [.allowOnce, .allowAlways, .deny, .answers]
        let decoded = try JSONDecoder().decode([RemoteCommand.Answer].self,
                                               from: JSONEncoder().encode(kinds))
        #expect(decoded == kinds)
    }

    // A session waiting on the person says what it is waiting for on its row, so a list
    // can tell it from one that has only finished.
    @Test(arguments: StationImplementation.allCases)
    func aWaitingSessionSaysSoOnItsRow(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: """
        IFS= read -r input
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
        printf '%s\\n' '\(Self.writeRequest)'
        IFS= read -r answer
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Wrote it."}]}}'
        """, host: RecordingHost())
        defer { fixture.tearDown() }
        let station = StationCommands(store: fixture.store, runner: fixture.runner)
        let commands = kind.connect(to: station)
        let id = fixture.session.id.uuidString
        #expect(try await commands.listDirectory().projects.first?.sessions.first?.needsInput == nil)

        try await commands.sendPrompt(id, prompt: "Write hello")

        #expect(await eventually { try await commands.listDirectory().projects.first?.sessions.first?.needsInput != nil })
        let row = try #require(try await commands.listDirectory().projects.first?.sessions.first)
        #expect(row.needsInput == "permission")
        #expect(row.state == "NEEDS YOU")

        try await commands.answerPermission(id, requestID: "r1", answer: .allowOnce)
        #expect(await waitUntil { fixture.runner.state(fixture.session.id) == .idle })
        let after = try #require(try await commands.listDirectory().projects.first?.sessions.first)
        #expect(after.needsInput == nil)
        // Finished and unread still asks for the person, but no longer for an answer.
        #expect(after.state == "NEEDS YOU")
    }

    // A row can speak for the session's Design companion. When the companion is the one
    // waiting, the row says so, and opening the row's conversation lands in the companion
    // with its request, ready to answer, as the phone's Design conversation does.
    @Test(arguments: StationImplementation.allCases)
    func aWaitingDesignCompanionIsOpenedFromItsRowAndAnswered(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: """
        IFS= read -r input
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-design"}'
        printf '%s\\n' '\(Self.writeRequest)'
        IFS= read -r answer
        case "$answer" in *'"behavior":"allow"'*) ;; *) exit 7 ;; esac
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Drew it."}]}}'
        """, host: RecordingHost())
        defer { fixture.tearDown() }
        fixture.store.append(ChatMessage(role: .assistant, text: "Main conversation",
                                         date: Date(timeIntervalSince1970: 1_000)), to: fixture.session.id)
        let companion = try fixture.store.startDesign(for: fixture.session.id).get()
        let station = StationCommands(store: fixture.store, runner: fixture.runner,
                                      refreshInterval: .milliseconds(50))
        let commands = kind.connect(to: station)
        fixture.runner.send("Sketch the screen", sessionID: companion.id, store: fixture.store)

        #expect(await eventually { try await commands.listDirectory().projects.first?.sessions.first?.needsInput != nil })
        let row = try #require(try await commands.listDirectory().projects.first?.sessions.first)
        #expect(row.id == fixture.session.id.uuidString)
        #expect(row.conversation == .design)
        #expect(row.needsInput == "permission")

        // The main conversation has nothing to answer.
        let main = try #require(try await commands.openSession(row.id))
        #expect(main.snapshot.conversation == .main)
        #expect(main.snapshot.permission == nil)
        #expect(main.snapshot.messages.map(\.text) == ["Main conversation"])
        await commands.closeSession(main.snapshot.sessionID)

        let design = try #require(try await commands.openSession(row.id, conversation: row.conversation))
        #expect(design.snapshot.conversation == .design)
        #expect(design.snapshot.permission?.id == "r1")
        #expect(design.snapshot.messages.first?.text == "Sketch the screen")
        let log = PermissionLog()
        log.mirror = RemoteTranscript(design.snapshot)
        let reader = Task { @MainActor in
            for await event in design.events { log.mirror?.apply(event) }
        }
        defer { reader.cancel() }

        // Every later command addresses the conversation by the id its snapshot names.
        try await commands.answerPermission(design.snapshot.sessionID, requestID: "r1", answer: .allowOnce)

        #expect(await waitUntil { log.mirror?.messages.last?.text.hasSuffix("Drew it.") == true })
        #expect(log.mirror?.permission == nil)
        #expect(try await commands.listDirectory().projects.first?.sessions.first?.needsInput == nil)
        // A session with no Design conversation has none to open.
        let other = try fixture.store.insertSession(in: fixture.session.projectID, seed: .init(agent: .claudeCode)).get()
        #expect(try await commands.openSession(other.id.uuidString, conversation: .design) == nil)
    }
}

// A session opened through a client of a station on the fixture's store and runner, with a reader's
// copy kept up to date from its events.
@MainActor
private final class Opened {
    let commands: any StationInterface
    let id: String
    let log = PermissionLog()
    private var reader: Task<Void, Never>?

    init(_ fixture: RunnerHarness, _ kind: StationImplementation) async throws {
        commands = kind.connect(to: StationCommands(store: fixture.store, runner: fixture.runner,
                                                    refreshInterval: .milliseconds(50)))
        id = fixture.session.id.uuidString
        let opened = try #require(try await commands.openSession(id))
        log.mirror = RemoteTranscript(opened.snapshot)
        let log = log
        reader = Task { @MainActor in
            for await event in opened.events { log.mirror?.apply(event) }
        }
    }

    deinit { reader?.cancel() }
}

@MainActor
private final class PermissionLog {
    var mirror: RemoteTranscript?
}
