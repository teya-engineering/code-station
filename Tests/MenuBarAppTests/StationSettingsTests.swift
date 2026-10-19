import Foundation
import Testing
@testable import CodeStationCore

// Part of the station contract (see StationContract.swift): the settings that matter
// outside the GUI, read from and written to the shared station preferences the GUI's
// Settings window reads; each agent's readiness, with the command that fixes it; the
// session log; and whether an update to the app is waiting.
@MainActor
struct StationSettingsTests {

    // Every setting reads what the shared preferences hold, as the GUI's Settings wrote it.
    @Test(arguments: StationImplementation.allCases)
    func eachSettingReadsTheSharedPreferences(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-settings")
        let preferences = try Self.preferences()
        Preferences.setAgent(.codex, in: preferences)
        Preferences.setSessionDefaults(SessionSettings(model: "opus", effort: "high", permissionMode: .manual),
                                       for: .claudeCode, in: preferences)
        Preferences.setSessionDefaults(SessionSettings(codexSandboxMode: .fullAccess),
                                       for: .codex, in: preferences)
        Preferences.setSessionDefaults(SessionSettings(copilotAccessMode: .fullAccess),
                                       for: .copilot, in: preferences)
        Preferences.setSessionFinishedSound(.ping, in: preferences)
        Preferences.setSessionMemoryLimit(.fourGB, in: preferences)
        Preferences.setOldSessionDays(7, in: preferences)
        Preferences.setOldSessionCleanupPolicy(.review, in: preferences)
        preferences.set(6, forKey: "sidebarSessionLimit")
        Preferences.setProjectSort(.lastUsed, in: preferences)
        Preferences.setProjectGrouping(.kind, in: preferences)
        let station = Self.station(in: scratch, preferences: preferences)
        let commands = kind.connect(to: station)

        let settings = try await commands.readSettings()

        let values = Dictionary(uniqueKeysWithValues: settings.sections.flatMap(\.settings).map { ($0.id, $0.value) })
        #expect(values == [
            "agent": "codex",
            "claude.model": "opus", "claude.effort": "high", "claude.permissionMode": "manual",
            "codex.model": "", "codex.effort": "", "codex.sandbox": "danger-full-access",
            "copilot.model": "", "copilot.effort": "", "copilot.access": "full-access",
            "sound": "Ping", "memoryLimit": "4",
            "oldSessions.days": "7", "oldSessions.policy": "review",
            "sidebar.sessionsShown": "6", "sidebar.sort": "lastUsed", "sidebar.grouping": "kind",
        ])
        #expect(settings.setting("sound")?.valueTitle == "Ping")
        #expect(settings.setting("claude.permissionMode")?.valueTitle == "Ask about everything")
        #expect(settings.setting("sidebar.grouping")?.valueTitle == "By type")
        #expect(settings.setting("codex.model")?.valueTitle == "Default")
    }

    // With nothing saved, each setting reads the default the GUI starts on.
    @Test(arguments: StationImplementation.allCases)
    func untouchedSettingsReadTheGUIsDefaults(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-settings")
        let commands = kind.connect(to: Self.station(in: scratch, preferences: try Self.preferences()))

        let settings = try await commands.readSettings()

        #expect(settings.setting("agent")?.value == "claude")
        #expect(settings.setting("claude.permissionMode")?.value == "acceptEdits")
        #expect(settings.setting("codex.sandbox")?.value == "workspace-write")
        #expect(settings.setting("sound")?.value == "Glass")
        #expect(settings.setting("memoryLimit")?.valueTitle == "Automatic")
        #expect(settings.setting("oldSessions.days")?.valueTitle == "3 days")
        #expect(settings.setting("oldSessions.policy")?.value == "deleteAll")
        #expect(settings.setting("sidebar.sessionsShown")?.value == "4")
        #expect(settings.setting("sidebar.sessionsShown")?.choices.map(\.value)
                == ["2", "3", "4", "5", "6", "7", "8", "9", "10"])
        #expect(settings.setting("sidebar.sort")?.value == "name")
        #expect(settings.setting("sidebar.grouping")?.value == "flat")
    }

    // Changing a setting writes the shared preferences, where the GUI reads it, and
    // answers with the settings as they now stand.
    @Test(arguments: StationImplementation.allCases)
    func changingEachSettingWritesTheSharedPreferences(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-settings")
        let preferences = try Self.preferences()
        let station = Self.station(in: scratch, preferences: preferences)
        let commands = kind.connect(to: station)

        let changes: [(String, String)] = [
            ("agent", "codex"),
            ("claude.model", "sonnet"), ("claude.effort", "low"), ("claude.permissionMode", "auto"),
            ("codex.sandbox", "approve-for-me"), ("copilot.access", "full-access"),
            ("sound", "off"), ("memoryLimit", "2"),
            ("oldSessions.days", "14"), ("oldSessions.policy", "deleteSafe"),
            ("sidebar.sessionsShown", "8"), ("sidebar.sort", "lastUsed"), ("sidebar.grouping", "kind"),
        ]
        var answered: RemoteSettings?
        for (id, value) in changes {
            answered = try await commands.changeSetting(id, to: value)
            #expect(answered?.setting(id)?.value == value, "\(id)")
        }

        #expect(Preferences.agent(in: preferences) == .codex)
        let claude = Preferences.sessionDefaults(for: .claudeCode, in: preferences)
        #expect(claude.model == "sonnet")
        #expect(claude.effort == "low")
        #expect(claude.permissionMode == .auto)
        #expect(Preferences.sessionDefaults(for: .codex, in: preferences).codexSandboxMode == .approveForMe)
        #expect(Preferences.sessionDefaults(for: .copilot, in: preferences).copilotAccessMode == .fullAccess)
        #expect(Preferences.sessionFinishedSound(in: preferences) == .off)
        #expect(Preferences.sessionMemoryLimit(in: preferences) == .twoGB)
        #expect(Preferences.oldSessionDays(in: preferences) == 14)
        #expect(Preferences.oldSessionCleanupPolicy(in: preferences) == .deleteSafe)
        #expect(preferences.integer(forKey: "sidebarSessionLimit") == 8)
        #expect(Preferences.projectSort(in: preferences) == .lastUsed)
        #expect(Preferences.projectGrouping(in: preferences) == .kind)
        // New sessions follow the new defaults at once, without a restart.
        #expect(station.runner.agent == .codex)
        #expect(station.runner.defaults(for: .claudeCode).model == "sonnet")
        #expect(try await commands.sessionOptions().defaultAgent == .codex)
        // A change of arrangement reaches the directory.
        let arrangement = try await commands.listDirectory().arrangement
        #expect(arrangement?.sort == .lastUsed)
        #expect(arrangement?.grouping == .kind)
        #expect(arrangement?.sessionLimit == 8)
    }

    // The GUI's Settings change the shared preferences behind the host's back. A new
    // session from a client starts on what they say now, not on what the host read when
    // it started.
    @Test(arguments: StationImplementation.allCases)
    func newSessionsFollowDefaultsChangedElsewhere(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-settings")
        let preferences = try Self.preferences()
        let station = Self.station(in: scratch, preferences: preferences)
        try FileManager.default.createDirectory(at: scratch.path("alpha"), withIntermediateDirectories: true)
        let project = try #require(station.store.addProject(at: scratch.path("alpha")))
        let commands = kind.connect(to: station)
        #expect(try await commands.sessionOptions().defaultAgent == .claudeCode)

        Preferences.setAgent(.codex, in: preferences)
        Preferences.setSessionDefaults(SessionSettings(model: "sonnet"), for: .claudeCode, in: preferences)

        let options = try await commands.sessionOptions()
        #expect(options.defaultAgent == .codex)
        #expect(options.agents.first { $0.agent == .claudeCode }?.defaultModel == "sonnet")
        let id = try await commands.createSession(RemoteNewSession(projectID: project.id.uuidString, agent: .codex,
                                                                   model: nil, worktree: false))
        #expect(station.store.session(try #require(UUID(uuidString: id)))?.agent == .codex)
        #expect(station.runner.agent == .codex)
        #expect(station.runner.defaults(for: .claudeCode).model == "sonnet")
    }

    // A value a setting does not offer, or a setting that does not exist, is refused and
    // nothing is written.
    @Test(arguments: StationImplementation.allCases)
    func aValueASettingDoesNotOfferIsRefused(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-settings")
        let preferences = try Self.preferences()
        let commands = kind.connect(to: Self.station(in: scratch, preferences: preferences))

        await #expect(throws: StationRefusal.self) { _ = try await commands.changeSetting("sound", to: "Klaxon") }
        await #expect(throws: StationRefusal.self) { _ = try await commands.changeSetting("oldSessions.days", to: "0") }
        await #expect(throws: StationRefusal.self) { _ = try await commands.changeSetting("theme", to: "dark") }
        #expect(preferences.object(forKey: "sessionFinishedSound") == nil)
        #expect(preferences.object(forKey: "oldSessionDays") == nil)
    }

    // Each agent says whether it is installed and signed in, and how to fix it when not.
    @Test(arguments: StationImplementation.allCases)
    func eachAgentSaysWhetherItIsReadyAndHowToFixIt(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-settings")
        let home = scratch.path("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data(#"{"oauthAccount":{"emailAddress":"ada@example.com","displayName":"Ada"}}"#.utf8)
            .write(to: home.appendingPathComponent(".claude.json"))
        let station = Self.station(in: scratch, preferences: try Self.preferences(), home: home)
        let commands = kind.connect(to: station)

        let agents = try await commands.readSettings().agents

        let claude = try #require(agents.first { $0.agent == .claudeCode })
        #expect(claude.installed)
        #expect(claude.signedIn == true)
        #expect(claude.account == "Ada · ada@example.com")
        #expect(claude.problem == nil)
        let codex = try #require(agents.first { $0.agent == .codex })
        #expect(codex.installed)
        #expect(codex.signedIn == false)
        #expect(codex.problem == "Codex is not signed in.")
        #expect(codex.fix == "codex login")
        let copilot = try #require(agents.first { $0.agent == .copilot })
        #expect(!copilot.installed)
        #expect(copilot.problem == "Copilot is not installed.")
        #expect(copilot.fix == "npm install -g @github/copilot")
    }

    // A session's log is its own lines from the shared log file, newest last.
    @Test(arguments: StationImplementation.allCases)
    func aSessionsLogHoldsOnlyItsOwnLines(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-settings")
        let store = ProjectStore(storeURL: scratch.path("projects.json"))
        let folder = scratch.path("alpha")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try #require(store.addProject(at: folder))
        let mine = try store.insertSession(in: project.id, seed: .init(agent: .claudeCode)).get()
        let other = try store.insertSession(in: project.id, seed: .init(agent: .claudeCode)).get()
        let marker = UUID().uuidString
        SessionLog.note("mine \(marker) first", session: mine.id)
        SessionLog.note("other \(marker)", session: other.id)
        SessionLog.note("mine \(marker) second", session: mine.id)
        let station = StationCommands(store: store, runner: Self.runner(), preferences: try Self.preferences())
        let commands = kind.connect(to: station)

        let log = try await commands.readLog(mine.id.uuidString)

        let lines = log.text.split(separator: "\n").filter { $0.contains(marker) }
        #expect(lines.count == 2)
        #expect(lines.first?.hasSuffix("mine \(marker) first") == true)
        #expect(lines.last?.hasSuffix("mine \(marker) second") == true)
        await #expect(throws: StationRefusal.self) { _ = try await commands.readLog(UUID().uuidString) }
    }

    // A newer release the GUI found and cached is an update waiting; the one installed,
    // or an older one, is not.
    @Test(arguments: StationImplementation.allCases)
    func aNewerCachedReleaseIsAnUpdateWaiting(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-settings")
        let preferences = try Self.preferences()
        preferences.set(Data(#"{"version":"2.4.0","pageURL":"https://example.com/r/2.4.0"}"#.utf8),
                        forKey: "cachedAppUpdateRelease")
        let station = Self.station(in: scratch, preferences: preferences)
        station.installedVersion = "2.3.1"
        let commands = kind.connect(to: station)

        #expect(try await commands.readSettings().update
                == RemoteAppUpdate(version: "2.4.0", installed: "2.3.1", page: "https://example.com/r/2.4.0"))
        station.installedVersion = "2.4.0"
        #expect(try await commands.readSettings().update == nil)
        station.installedVersion = nil
        #expect(try await commands.readSettings().update == nil)
    }

    // MARK: - Helpers

    static func preferences() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "station-settings-\(UUID().uuidString)"))
    }

    static func runner() -> SessionRunner {
        SessionRunner(paths: [.claudeCode: "/usr/bin/true", .codex: "/usr/bin/true"],
                      host: RecordingHost())
    }

    static func station(in scratch: ScratchDirectory, preferences: UserDefaults,
                        home: URL? = nil) -> StationCommands {
        let station = StationCommands(store: ProjectStore(storeURL: scratch.path("projects.json")),
                                      runner: runner(), preferences: preferences)
        station.signIn = AgentSignIn(home: home ?? scratch.path("empty-home"), copilot: { nil })
        return station
    }
}
