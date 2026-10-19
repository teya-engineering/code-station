import CodeStationCore
import Foundation
import TerminalKit
import TerminalServices
import TerminalTranscript
import Testing
@testable import CodeStationTUI

// The real TUI app on a fake terminal, over an in-process station on a scratch store. A
// test seeds the store, starts the app, presses keys, resizes the terminal or lets the
// station move on, and reads the frame back as lines of styled text.
@MainActor
final class TUIHarness {
    let scratch = ScratchDirectory(prefix: "tui")
    let store: ProjectStore
    let runner: SessionRunner
    // The station the app is a client of, for seeding and reading it behind the app's back.
    let commands: StationCommands
    let terminal: FakeTerminal
    let handoffs = FakeHandoffRunner()
    // The shared preferences the station reads, as the GUI's settings write them: how
    // the sidebar tree is sorted and grouped.
    let preferences: UserDefaults
    private let preferencesSuite = "tui-preferences-\(UUID().uuidString)"
    // The TUI's own services, answered by the terminal as in `code-station tui`. The
    // station's runner reports to a host with nobody in front of it, as the daemon's
    // does, so whatever reaches the terminal came through the station.
    let host: TerminalHost
    // Commands the host ran to open something, such as `open` for a path.
    var launched: [[String]] { launches.commands }
    private let launches = LaunchLog()
    private(set) var exited = false
    // How far ahead of the real clock the app's clock runs, for a test that lets time
    // pass without waiting for it, such as the elapsed time of a running turn.
    var clockAhead: TimeInterval {
        get { clock.ahead }
        set { clock.ahead = newValue }
    }
    private let clock = TestClock()
    // The environment the TUI reads `$PAGER` and the like from.
    var environment: [String: String] = [:]
    private var app: TUIApp?
    private var lock: StationLock?
    private var upkeep: StationUpkeep?

    // A fake agent, written as a FixtureCLI script and standing in for every agent kind:
    // the test's own when it needs turns to run, and otherwise one that ends at once.
    // `installed` narrows the agents the script stands in for; the rest read as not
    // installed.
    init(size: TerminalSize = TerminalSize(cols: 80, rows: 24), agentScript: String? = nil,
         installed: [AgentKind] = AgentKind.allCases, promptSuggestions: Bool = false) throws {
        terminal = FakeTerminal(size: size)
        preferences = UserDefaults(suiteName: preferencesSuite)!
        store = ProjectStore(storeURL: scratch.path("projects.json"))
        let terminal = terminal, launches = launches
        host = TerminalHost(output: { terminal.write($0) }, environment: [:],
                            sound: { .off }, launch: { launches.commands.append($0) },
                            locate: { _ in nil })
        // With no script, an agent that ends at once, so nothing depends on which agents
        // this machine has on its PATH.
        let executable = scratch.path("agent-fixture")
        try FixtureCLI.write(agentScript ?? "exit 0", to: executable)
        let paths = Dictionary(uniqueKeysWithValues: installed.map { ($0, executable.path) })
        runner = SessionRunner(persistentAgentSessions: false, paths: paths,
                               automaticRecapsEnabled: { false },
                               automaticTitlesEnabled: { false },
                               promptSuggestionsEnabled: { promptSuggestions },
                               mcpConfiguration: StationCommands.mcpConfiguration(at: scratch.path("mcp.json")),
                               host: SilentHost())
        commands = StationCommands(store: store, runner: runner, refreshInterval: .milliseconds(50),
                                   preferences: preferences)
        commands.changesRefreshInterval = .milliseconds(200)
        // Trashed files are deleted, so tests leave nothing in the real Trash.
        commands.trash = FileTrash { try FileManager.default.removeItem(at: $0) }
        // Sign-ins are read from a scratch home folder, where nobody is signed in until a
        // test says so, and Copilot is never asked.
        commands.signIn = AgentSignIn(home: scratch.path("home"), copilot: { nil })
        // Tasks made from the TUI get their folders beside the index.
        commands.taskFolder = scratch.path("tasks")
        // A diagnosis reads its site file and MCP servers from the scratch folder, where
        // there are none until a test writes them.
        commands.diagnosis = DiagnosisSupport.live(mcpConfigURL: scratch.path("mcp.json"),
                                                   siteFiles: [scratch.path("site-defaults.json")])
    }

    // Signs an agent in, as its CLI would leave its sign-in in the home folder.
    func signIn(_ agent: AgentKind, as email: String = "ada@example.com") throws {
        let home = scratch.path("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"),
                                                withIntermediateDirectories: true)
        switch agent {
        case .claudeCode:
            try Data(#"{"oauthAccount":{"emailAddress":"\#(email)"}}"#.utf8)
                .write(to: home.appendingPathComponent(".claude.json"))
        case .codex:
            try Data(#"{"OPENAI_API_KEY":"sk-test"}"#.utf8).write(to: home.appendingPathComponent(".codex/auth.json"))
        case .copilot:
            break
        }
    }

    // MARK: - Seeding

    // A project folder beside the index, so it goes when the scratch folder does. Files
    // given make it a git repository with them in its first commit.
    @discardableResult
    func addProject(_ name: String, committing files: [String: String]? = nil) throws -> Project {
        let folder = scratch.path(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let files {
            try git(["init", "-q", "-b", "main"], in: folder)
            try git(["config", "user.email", "t@example.com"], in: folder)
            try git(["config", "user.name", "Test"], in: folder)
            try git(["config", "commit.gpgsign", "false"], in: folder)
            for (path, contents) in files {
                try contents.write(to: folder.appendingPathComponent(path), atomically: true, encoding: .utf8)
            }
            try git(["add", "-A"], in: folder)
            try git(["commit", "-qm", "first"], in: folder)
        }
        return try #require(store.addProject(at: folder))
    }

    func git(_ arguments: [String], in folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed")
    }

    // A session whose last word came `ago` seconds before now, when a test orders by it.
    @discardableResult
    func addSession(_ title: String, in project: Project, agent: AgentKind = .claudeCode,
                    messages: [ChatMessage] = [], ago: TimeInterval? = nil) throws -> ChatSession {
        let session = try store.insertSession(in: project.id, seed: .init(agent: agent)).get()
        return seed(session, title: title, messages: messages, ago: ago)
    }

    @discardableResult
    func addSession(_ title: String, in workspace: ProjectWorkspace, ago: TimeInterval? = nil) throws -> ChatSession {
        let session = try store.insertSession(in: workspace.id,
                                              projects: workspace.projectIDs.map { SessionProject(projectID: $0) },
                                              seed: .init(agent: .claudeCode)).get()
        return seed(session, title: title, messages: [], ago: ago)
    }

    private func seed(_ session: ChatSession, title: String, messages: [ChatMessage],
                      ago: TimeInterval?) -> ChatSession {
        store.renameSession(session.id, to: title)
        for message in messages { store.append(message, to: session.id) }
        if let ago {
            store.append(ChatMessage(role: .assistant, text: "Done", date: Date().addingTimeInterval(-ago)),
                         to: session.id)
        }
        return session
    }

    // A workspace over the projects given, the first leading it.
    func addWorkspace(_ name: String, of projects: [Project]) throws -> ProjectWorkspace {
        try #require(store.addWorkspace(name: name, projectIDs: projects.map(\.id),
                                        leadProjectID: projects[0].id))
    }

    // A task, a project made for a reusable prompt, in a folder beside the index.
    @discardableResult
    func addTask(_ name: String) throws -> Project {
        try store.addTask(named: name, prompt: "Do the thing", in: scratch.path("tasks")).get()
    }

    // The host's background work, as the daemon runs it, with the orphaned worktrees of
    // the project named alpha given rather than looked for on disk. Pruning one records
    // its path in `pruned` rather than asking git, and it is not found again.
    func startUpkeep(orphans: [GitWorktree.Orphaned] = []) {
        let monitor = OrphanedWorktreeMonitor(
            discover: { @MainActor [weak self] projectPath, _ in
                projectPath.hasSuffix("/alpha") ? orphans.filter { !(self?.pruned.contains($0.path) ?? false) } : []
            },
            remove: { @MainActor [weak self] orphan in
                self?.pruned.append(orphan.path)
                return .success(())
            })
        let upkeep = StationUpkeep(station: commands, orphanedWorktrees: monitor, preferences: preferences,
                                   pace: StationUpkeep.Pace(schedules: .seconds(60), sweep: .milliseconds(50),
                                                            orphans: .milliseconds(50)))
        upkeep.start()
        self.upkeep = upkeep
    }

    // The orphaned worktrees pruned through the upkeep `startUpkeep` started.
    private(set) var pruned: [String] = []

    // An entry added to every row's actions menu, as a feature adds its own.
    func addRowAction(_ actions: @escaping @MainActor (SidebarView.Target) -> [MenuAction]) {
        app?.extraRowActions.append(actions)
    }

    // MARK: - Running

    // Starts the app the way `code-station tui` does, with the station's host answered by
    // the terminal, and waits for the first list to be drawn.
    // `client` stands in for the in-process client, such as a socket client of the
    // station, as a terminal attached to a daemon has. Without `settling`, it does not wait
    // for the first list, as for a host that does not answer.
    func start(over client: (any StationInterface)? = nil, settling: Bool = true) async throws {
        guard case .claimed(let claimed) = StationLock.claim(.tui, at: scratch.path("station.lock")) else {
            Issue.record("The scratch station lock could not be claimed.")
            return
        }
        lock = claimed
        let commands = commands
        let app = TUIApp(terminal: terminal, commands: client ?? commands.connect(), theme: TranscriptTheme.basic,
                         shutdown: {
                             commands.shutdown()
                             claimed.release()
                         },
                         exit: { [weak self] in self?.exited = true },
                         now: { [clock] in Date().addingTimeInterval(clock.ahead) })
        app.host = host
        app.handoff = handoffs
        app.environment = environment
        host.askForPath = { [weak app] prompt, message, start in
            await app?.askForPath(prompt: prompt, message: message, startingAt: start)
        }
        self.app = app
        app.start()
        if settling { await settle() }
    }

    // Waits until the frame shows what was asked of the station: the TUI reaches it
    // asynchronously, as it would a host on the far side of a socket. Generous, since
    // reading git (changes, branches) waits behind the rest of the process's git work.
    func settle() async {
        let settled = await waitUntil(timeout: .seconds(60)) { app?.isSettled ?? true }
        if !settled { Issue.record("The TUI was still waiting on the station.") }
    }

    // Lets the agents go and the terminal and lock go back, whatever the test decided. The
    // app is not quit: its quit sweep reaches every process the test process started.
    func tearDown() {
        upkeep?.stop()
        app?.stopFollowing()
        runner.stopAll()
        lock?.release()
        removeScratchDefaults(preferencesSuite)
    }

    // MARK: - Input

    // The keys one after another, as fast as a person could press them, then the station
    // work they started is waited for.
    func press(_ keys: Key...) async {
        for key in keys { terminal.send(.key(key)) }
        await settle()
    }

    // Each character as its own key press, as a person types.
    func type(_ text: String) async {
        for character in text { terminal.send(.key(.char(character, []))) }
        await settle()
    }

    func resize(cols: Int, rows: Int) {
        terminal.resize(to: TerminalSize(cols: cols, rows: rows))
    }

    // MARK: - The frame

    var frame: [VirtualScreen.Line] { terminal.screen.lines }

    // The frame as plain text, one string per row, for messages when an expectation fails.
    var text: String { frame.map(\.text).joined(separator: "\n") }

    func line(containing fragment: String) -> VirtualScreen.Line? {
        frame.first { $0.text.contains(fragment) }
    }

    func contains(_ fragment: String) -> Bool {
        line(containing: fragment) != nil
    }

    // MARK: - The regions

    // The column the sidebar's border runs down, from the top row to the bottom, while
    // the sidebar shows.
    var borderColumn: Int? {
        let rows = frame
        guard let first = rows.first else { return nil }
        return (0..<first.width).first { column in rows.allSatisfy { $0.character(at: column) == "│" } }
    }

    // The rows of the sidebar, left of its border.
    var sidebar: [VirtualScreen.Line] {
        guard let border = borderColumn else { return [] }
        return frame.map { $0.columns(0..<border) }
    }

    // The rows right of the sidebar: the top bar's, then the main pane's. The whole
    // frame when there is no sidebar.
    var main: [VirtualScreen.Line] {
        guard let border = borderColumn else { return frame }
        return frame.map { $0.columns((border + 1)..<$0.width) }
    }

    // The top bar's rows, over the main pane.
    var topBar: [VirtualScreen.Line] { Array(main.prefix(app?.topBarRows ?? 1)) }

    // The main pane alone, under the top bar.
    var mainPane: [VirtualScreen.Line] { Array(main.dropFirst(app?.topBarRows ?? 1)) }

    var topBarText: String { topBar.map(\.text).joined(separator: "\n") }

    var sidebarText: String { sidebar.map(\.text).joined(separator: "\n") }
    var mainText: String { main.map(\.text).joined(separator: "\n") }

    func sidebarLine(containing fragment: String) -> VirtualScreen.Line? {
        sidebar.first { $0.text.contains(fragment) }
    }

    func mainLine(containing fragment: String) -> VirtualScreen.Line? {
        main.first { $0.text.contains(fragment) }
    }

    // The sidebar row each fragment first shows on, top to bottom, for order checks.
    func sidebarRows(of fragments: [String]) -> [Int?] {
        let rows = sidebar
        return fragments.map { fragment in rows.firstIndex { $0.text.contains(fragment) } }
    }

    // Waits for the station to move the frame on, such as a turn ending or a list update.
    func waitFor(_ fragment: String, timeout: Duration = .seconds(30)) async -> Bool {
        await waitUntil(timeout: timeout) { contains(fragment) }
    }
}

@MainActor
private final class TestClock {
    var ahead: TimeInterval = 0
}

@MainActor
private final class LaunchLog {
    var commands: [[String]] = []
}

// Stands in for the editor, pager or shell the TUI hands the terminal to. It records what
// was asked for and answers with the exit status a test chose.
@MainActor
final class FakeHandoffRunner: HandoffRunner {
    private(set) var handoffs: [Handoff] = []
    var status: Int32 = 0
    // Called while the program would run, to look at what it was handed, such as a file
    // that goes once it exits.
    var whileRunning: ((Handoff) -> Void)?

    func run(_ handoff: Handoff) async -> Int32 {
        handoffs.append(handoff)
        whileRunning?(handoff)
        return status
    }
}
