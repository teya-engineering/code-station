import Foundation
import Testing
@testable import CodeStationCore

@MainActor
struct AgentSessionRunnerTests {
    @Test(arguments: [AgentKind.codex, .copilot])
    func keepsTheConversationOpenForFollowUpsAndEndsItsTasks(agent: AgentKind) async throws {
        let fixture = try fixture(agent)
        defer { fixture.tearDown() }
        fixture.runner.send("Start a timer", sessionID: fixture.session.id, store: fixture.store)
        #expect(await waitUntil { fixture.runner.state(fixture.session.id) == .waiting })
        #expect(fixture.runner.backgroundTasks(fixture.session.id).count == 2)
        let since = try #require(fixture.runner.waitingSince(fixture.session.id))
        #expect(await waitUntil { FileManager.default.fileExists(atPath: fixture.scratch.path("polled").path) })
        #expect(fixture.runner.waitingSince(fixture.session.id) == since)
        fixture.runner.send("Continue here", sessionID: fixture.session.id, store: fixture.store)
        #expect(await waitUntil {
            fixture.store.transcript(of: fixture.session.id).contains { $0.text.contains("Follow-up received") }
                && fixture.runner.state(fixture.session.id) == .waiting
        })
        #expect(fixture.store.session(fixture.session.id)?.agentSessionID(for: agent) == "session")
        fixture.runner.endWait(fixture.session.id)
        #expect(await waitUntil { fixture.runner.state(fixture.session.id) == .idle })
        #expect(fixture.runner.backgroundTasks(fixture.session.id).isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.scratch.path("cancelled").path))
    }

    @Test(arguments: [AgentKind.codex, .copilot])
    func updatesTheTaskListAndFinishesNaturally(agent: AgentKind) async throws {
        let fixture = try fixture(agent)
        defer { fixture.tearDown() }
        fixture.runner.send("Start timers", sessionID: fixture.session.id, store: fixture.store)
        #expect(await waitUntil { fixture.runner.state(fixture.session.id) == .waiting })
        let since = fixture.runner.waitingSince(fixture.session.id)
        try Data().write(to: fixture.scratch.path("drop"))
        #expect(await waitUntil { fixture.runner.backgroundTasks(fixture.session.id).count == 1 })
        #expect(fixture.runner.waitingSince(fixture.session.id) == since)
        try Data().write(to: fixture.scratch.path("done"))
        #expect(await waitUntil { fixture.runner.state(fixture.session.id) == .idle })
        #expect(fixture.runner.waitingSince(fixture.session.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.scratch.path("cancelled").path))
    }

    private func fixture(_ agent: AgentKind) throws -> RunnerHarness {
        let python = try #require(ExecutableSearch.resolve("python3"))
        let fixture = try RunnerHarness(agent: agent, script: "exec '\(python)' -u \"$folder/server.py\" \"$folder\" \(agent == .codex ? "codex" : "copilot")",
                                        persistentAgentSessions: true)
        try Data(Self.server.utf8).write(to: fixture.scratch.path("server.py"))
        return fixture
    }

    private static let server = #"""
    import sys, json, pathlib
    folder = pathlib.Path(sys.argv[1])
    codex = sys.argv[2] == 'codex'
    sends = 0
    polls = 0
    stopped = False
    def send(obj):
        body = json.dumps(obj).encode()
        sys.stdout.buffer.write(body + b'\n' if codex else b'Content-Length: ' + str(len(body)).encode() + b'\r\n\r\n' + body)
        sys.stdout.buffer.flush()
    def event(name, data):
        send({'method': name, 'params': data} if codex else {'method': 'session.event', 'params': {'sessionId': 'session', 'event': {'type': name, 'data': data}}})
    while True:
        line = sys.stdin.buffer.readline()
        if not line: break
        if codex:
            message = json.loads(line)
        else:
            length = int(line.split(b':')[1].strip())
            sys.stdin.buffer.readline()
            message = json.loads(sys.stdin.buffer.read(length))
        method = message.get('method')
        if 'id' not in message: continue
        result = {}
        if method in ['thread/start', 'thread/resume']:
            result = {'thread': {'id': 'session'}}
        elif method in ['session.create', 'session.resume']:
            result = {'sessionId': 'session'}
        elif method == 'session.permissions.configure':
            result = {'success': True}
        elif method in ['thread/backgroundTerminals/list', 'session.tasks.list']:
            polls += 1
            if polls > 1: (folder / 'polled').touch()
            ids = [] if stopped or (folder / 'done').exists() else ['one'] if (folder / 'drop').exists() else ['one', 'two']
            tasks = [{'processId': i, 'itemId': 'cmd-' + i, 'command': 'sleep 600'} if codex else {'id': i, 'type': 'shell', 'status': 'running', 'description': 'Preview timer', 'command': 'sleep 600'} for i in ids]
            result = {'data' if codex else 'tasks': tasks}
        elif method in ['thread/backgroundTerminals/clean', 'session.tasks.cancel', 'session.abort']:
            stopped = True
            (folder / 'cancelled').touch()
            result = {'cancelled': True}
        send({'id': message['id'], 'result': result})
        if method in ['turn/start', 'session.send']:
            sends += 1
            text = 'Timer started' if sends == 1 else 'Follow-up received'
            if codex:
                event('turn/started', {'threadId': 'session', 'turn': {'id': str(sends)}})
                event('item/completed', {'threadId': 'session', 'item': {'id': str(sends), 'type': 'agentMessage', 'text': text}})
                event('turn/completed', {'threadId': 'session', 'turn': {'status': 'completed'}})
            else:
                event('assistant.turn_start', {'turnId': str(sends)})
                event('assistant.message', {'content': text})
                event('assistant.idle', {})
    """#
}
