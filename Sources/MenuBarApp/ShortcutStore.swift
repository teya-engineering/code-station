import Foundation
import Observation

// What picking a shortcut does. A command is handed to zsh in a folder and its output is
// captured; a prompt is sent to the agent in the session you are looking at, exactly as
// though you had typed it into the composer.
enum ShortcutKind: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
    case command
    case prompt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .command: "Command"
        case .prompt: "Prompt"
        }
    }

    // What the saved text is, for the places that have to name the field rather than the
    // shortcut: the editor caption, the site configuration form, the error a bad file
    // gets back.
    var payloadName: String {
        switch self {
        case .command: "command"
        case .prompt: "prompt"
        }
    }
}

// A saved shortcut and the scope that decides where it lands. The Mac's own commands run
// from home. A project's commands and the Mac commands shared with every project run in
// whichever worktree is in front of you, which is what makes "run the tests" mean this
// session's tests rather than the ones in the folder the branch came from. A prompt has
// no folder: it goes to the session you are looking at.
struct Shortcut: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    // The shell command to run, or the prompt to send.
    var text: String
    var kind: ShortcutKind
    // An SF Symbol drawn beside the name, and nil for a shortcut that goes by its name
    // alone. Only a symbol the system can render is kept, so a file naming one this
    // build does not have leaves the shortcut without an icon rather than with a gap.
    var icon: String?
    // The project this shortcut is filed under, and nil for the ones that belong to the
    // Mac rather than to any checkout.
    var projectID: UUID?
    // A Mac shortcut can also be offered by every project. It stays on the Mac's list so
    // there is still one place to edit or remove it.
    var availableInAllProjects: Bool

    init(id: UUID = UUID(), name: String, text: String, kind: ShortcutKind = .command,
         icon: String? = nil, projectID: UUID? = nil, availableInAllProjects: Bool = false) {
        self.id = id
        self.name = name
        self.text = text
        self.kind = kind
        self.icon = ShortcutIcon.resolve(icon)
        self.projectID = availableInAllProjects ? nil : projectID
        self.availableInAllProjects = availableInAllProjects
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, icon, projectID, availableInAllProjects
        // Saved files call the payload "command" from when running one was all a shortcut
        // could do. Renaming the key would lose every shortcut already on disk.
        case text = "command"
    }

    // Shortcuts saved before they could belong to a project are the Mac's own. Shortcuts
    // saved before sharing was added remain private to that list, ones saved before icons
    // go by their name, and ones saved before a shortcut could be a prompt are commands.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try container.decode(UUID.self, forKey: .id),
                  name: try container.decode(String.self, forKey: .name),
                  text: try container.decode(String.self, forKey: .text),
                  kind: try container.decodeIfPresent(ShortcutKind.self, forKey: .kind) ?? .command,
                  icon: try container.decodeIfPresent(String.self, forKey: .icon),
                  projectID: try container.decodeIfPresent(UUID.self, forKey: .projectID),
                  availableInAllProjects: try container.decodeIfPresent(
                    Bool.self, forKey: .availableInAllProjects) ?? false)
    }

    // The glyph drawn beside the name wherever this shortcut is offered. A prompt is
    // offered on a rail of icons with no room for a name, so it always has one. A shared
    // command with no icon of its own falls back to the globe, since being offered by
    // every project is the one thing about a shortcut the name alone cannot say.
    var glyph: String? {
        if let icon { return icon }
        if kind == .prompt { return "sparkles" }
        return availableInAllProjects ? "globe" : nil
    }

    // The folder this run happens in. A project shortcut or a shared Mac shortcut falls
    // back to the checkout, which is what it means for a project with nothing open:
    // there is no worktree in front of you, so the folder the worktrees come from is the
    // honest answer.
    func directory(projectPath: String?, workspacePath: String? = nil) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard projectID != nil || availableInAllProjects else { return home }
        return workspacePath ?? projectPath ?? home
    }
}

// One shortcut in one folder. The same project shortcut can be running in two worktrees
// at once, and each of those runs has its own state and its own output, so a run is only
// identified by both together.
struct ShortcutRun: Hashable, Sendable {
    let shortcutID: Shortcut.ID
    let directory: String

    init(_ shortcutID: Shortcut.ID, in directory: String) {
        self.shortcutID = shortcutID
        self.directory = directory
    }
}

// The screen an output drawer is docked on. A project overview and each session in it are
// separate screens, so each one remembers the run it is showing.
enum ShortcutScope: Hashable {
    case project(UUID)
    case session(UUID)

    // A workspace screen has no shortcut chips, so nothing is ever filed under one.
    init?(_ owner: RemovedOwner) {
        switch owner {
        case .project(let id): self = .project(id)
        case .session(let id): self = .session(id)
        case .workspace: return nil
        }
    }
}

// One shortcut as it is offered in a group of projects. Shared shortcuts have no project
// of their own, so the project records the checkout they will run in.
struct ShortcutPlacement: Identifiable, Equatable, Sendable {
    let shortcut: Shortcut
    let projectID: UUID

    var id: Shortcut.ID { shortcut.id }
}

@MainActor
@Observable
final class ShortcutStore {
    enum State: Equatable {
        case stopped
        case running(since: Date)
        case finished(at: Date)
        // The exit code is kept apart from the message because a chip has room for the
        // code and nothing else, while the output pane wants the sentence.
        case failed(String, status: Int32? = nil, at: Date)

        var isActive: Bool {
            if case .running = self { true } else { false }
        }

        var isFailure: Bool {
            if case .failed = self { true } else { false }
        }
    }

    private struct Persisted: Codable {
        var shortcuts: [Shortcut]
        var importedSiteShortcutIDs: [UUID]?
    }

    private struct InvalidFile: LocalizedError {
        var errorDescription: String? {
            "Each shortcut needs a unique ID, a name, and a command or prompt."
        }
    }

    private(set) var shortcuts: [Shortcut] = SiteDefaults.current.startingShortcuts
    private(set) var states: [ShortcutRun: State] = [:]
    private(set) var logs: [ShortcutRun: String] = [:]
    // Which run each screen has its output open on. It is kept here rather than in the
    // view because a pane is thrown away and built again every time the sidebar moves,
    // and a command started before switching away is the one most worth coming back to.
    private var openOutput: [ShortcutScope: ShortcutRun] = [:]
    private(set) var loadError: String?
    private(set) var saveError: String?
    private var importedSiteShortcutIDs = Set(SiteDefaults.current.startingShortcuts.map(\.id))

    let storageURL: URL
    @ObservationIgnored private var tasks: [ShortcutRun: Task<Void, Never>] = [:]
    @ObservationIgnored private var runTokens: [ShortcutRun: UUID] = [:]

    init(storageURL: URL? = nil, siteDefaults: SiteDefaults = .current) {
        self.storageURL = storageURL ?? AppPaths.supportFile("shortcuts.json")
        shortcuts = siteDefaults.startingShortcuts
        importedSiteShortcutIDs = Set(siteDefaults.startingShortcuts.map(\.id))
        load(siteDefaults: siteDefaults)
    }

    func applySiteDefaults(_ defaults: SiteDefaults) {
        let siteShortcuts = defaults.startingShortcuts
        // Unsaved shortcuts came from the previously loaded site file. Once the user has
        // a saved collection, imports merge into it instead of replacing personal commands.
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            shortcuts = siteShortcuts
            importedSiteShortcutIDs = Set(siteShortcuts.map(\.id))
            save()
            return
        }

        var savedIDs = Set(shortcuts.map(\.id))
        var added = false
        for shortcut in siteShortcuts {
            importedSiteShortcutIDs.insert(shortcut.id)
            if savedIDs.insert(shortcut.id).inserted {
                shortcuts.append(shortcut)
                added = true
            }
        }
        if added { save() }
    }

    // Site shortcuts have stable IDs derived from their contents, which lets a reset
    // replace only that collection and preserve personal and project shortcuts.
    func resetSiteShortcuts(to defaults: SiteDefaults) {
        let removed = importedSiteShortcutIDs
        for id in removed { stopEveryRun(of: id) }
        shortcuts.removeAll { removed.contains($0.id) }
        for id in removed { forgetRuns(of: id) }

        let siteShortcuts = defaults.startingShortcuts
        importedSiteShortcutIDs = Set(siteShortcuts.map(\.id))
        shortcuts.append(contentsOf: siteShortcuts)
        save()
    }

    // Counted over the shortcuts the asking screen shows rather than over every saved
    // shortcut. A shared shortcut can have a separate run in each folder, and each active
    // run counts because each is a command the reader may need to stop.
    func runningCount(of shortcuts: [Shortcut]) -> Int {
        count(over: shortcuts, where: \.isActive)
    }

    func failureCount(of shortcuts: [Shortcut]) -> Int {
        count(over: shortcuts, where: \.isFailure)
    }

    private func count(over shortcuts: [Shortcut],
                       where matches: (State) -> Bool) -> Int {
        let ids = Set(shortcuts.map(\.id))
        return states.count { ids.contains($0.key.shortcutID) && matches($0.value) }
    }

    func shortcut(_ id: Shortcut.ID) -> Shortcut? {
        shortcuts.first { $0.id == id }
    }

    // The ones filed under the Mac, and the ones available to one project. Both keep the
    // order they were added in, so a list never reshuffles itself under the reader.
    var macShortcuts: [Shortcut] {
        shortcuts.filter { $0.projectID == nil }
    }

    var siteConfigurationShortcuts: [SiteDefaults.ShortcutEntry] {
        shortcuts.compactMap { shortcut in
            guard importedSiteShortcutIDs.contains(shortcut.id) else { return nil }
            return SiteDefaults.ShortcutEntry(name: shortcut.name, command: shortcut.text,
                                              icon: shortcut.icon,
                                              kind: shortcut.kind == .command ? nil : shortcut.kind)
        }
    }

    // Narrowed by kind wherever a screen can only offer one of them: a chip strip runs
    // commands and has nowhere to put a prompt, and the prompt rail is the other way
    // round.
    func shortcuts(for projectID: UUID, kind: ShortcutKind? = nil) -> [Shortcut] {
        shortcuts.filter {
            ($0.projectID == projectID
                || ($0.projectID == nil && $0.availableInAllProjects))
                && (kind == nil || $0.kind == kind)
        }
    }

    // A shared shortcut is available through every project, but a workspace should only
    // show one chip for it. The first project is the workspace lead, so it also supplies
    // the checkout where that single chip runs.
    func shortcuts(for projectIDs: [UUID], kind: ShortcutKind? = nil) -> [ShortcutPlacement] {
        var seen: Set<Shortcut.ID> = []
        return projectIDs.flatMap { projectID in
            shortcuts(for: projectID, kind: kind).compactMap { shortcut in
                guard seen.insert(shortcut.id).inserted else { return nil }
                return ShortcutPlacement(shortcut: shortcut, projectID: projectID)
            }
        }
    }

    func state(_ run: ShortcutRun) -> State {
        states[run] ?? .stopped
    }

    func log(_ run: ShortcutRun) -> String {
        logs[run] ?? ""
    }

    // MARK: - The output drawer

    func output(for scope: ShortcutScope) -> ShortcutRun? {
        openOutput[scope]
    }

    func showOutput(_ run: ShortcutRun?, for scope: ShortcutScope) {
        openOutput[scope] = run
    }

    // A deleted project or session leaves nothing that can reach its drawer again.
    func discard(_ scope: ShortcutScope) {
        openOutput[scope] = nil
    }

    // MARK: - Persistence

    // A file that cannot be read and one that cannot be understood are told apart, since
    // the first is about permissions and the second about what is in it.
    func load(siteDefaults: SiteDefaults = .current) {
        let data: Data?
        do {
            data = try PersistentFile.readIfPresent(storageURL)
        } catch {
            loadError = PersistentFile.loadMessage(for: storageURL, error: error)
            return
        }

        guard let data else {
            shortcuts = siteDefaults.startingShortcuts
            importedSiteShortcutIDs = Set(shortcuts.map(\.id))
            loadError = nil
            saveError = nil
            return
        }

        do {
            let persisted = try PersistentFile.makeDecoder().decode(Persisted.self, from: data)
            let ids = Set(persisted.shortcuts.map(\.id))
            guard ids.count == persisted.shortcuts.count,
                  persisted.shortcuts.allSatisfy({ !$0.name.isBlank && !$0.text.isBlank }) else {
                throw InvalidFile()
            }
            shortcuts = persisted.shortcuts
            importedSiteShortcutIDs = Set(persisted.importedSiteShortcutIDs
                ?? siteDefaults.startingShortcuts.map(\.id))
            loadError = nil
            saveError = nil
        } catch {
            loadError = PersistentFile.decodeMessage(for: storageURL, error: error)
        }
    }

    @discardableResult
    func save() -> Bool {
        guard loadError == nil else {
            saveError = "Changes were not saved because the existing shortcuts file could not be loaded."
            return false
        }

        do {
            let importedIDs = importedSiteShortcutIDs.sorted { $0.uuidString < $1.uuidString }
            try PersistentFile.saveJSON(
                Persisted(shortcuts: shortcuts, importedSiteShortcutIDs: importedIDs),
                to: storageURL)
            saveError = nil
            return true
        } catch {
            saveError = PersistentFile.saveMessage(for: storageURL, error: error)
            return false
        }
    }

    // MARK: - Mutations

    @discardableResult
    func add(name: String, text: String, kind: ShortcutKind = .command,
             icon: String? = nil, projectID: UUID? = nil,
             availableInAllProjects: Bool = false) -> Shortcut.ID? {
        let name = name.trimmed
        let text = text.trimmed
        guard !name.isEmpty, !text.isEmpty else { return nil }
        let shortcut = Shortcut(
            name: name,
            text: text,
            kind: kind,
            icon: icon,
            projectID: projectID,
            availableInAllProjects: availableInAllProjects
        )
        shortcuts.append(shortcut)
        save()
        return shortcut.id
    }

    func update(_ shortcut: Shortcut) {
        let name = shortcut.name.trimmed
        let text = shortcut.text.trimmed
        guard !name.isEmpty, !text.isEmpty,
              !isRunningAnywhere(shortcut.id),
              let index = shortcuts.firstIndex(where: { $0.id == shortcut.id }) else { return }
        let rewritten = text != shortcuts[index].text || shortcut.kind != shortcuts[index].kind
        shortcuts[index] = Shortcut(
            id: shortcut.id,
            name: name,
            text: text,
            kind: shortcut.kind,
            icon: shortcut.icon,
            projectID: shortcut.projectID,
            availableInAllProjects: shortcut.availableInAllProjects
        )
        // The state and output on screen belong to the command that was there before, so
        // they stop meaning anything the moment it is rewritten. Renaming a shortcut or
        // giving it an icon leaves the same command, and the last run still describes it.
        if rewritten { forgetRuns(of: shortcut.id) }
        save()
    }

    func remove(_ id: Shortcut.ID) {
        stopEveryRun(of: id)
        shortcuts.removeAll { $0.id == id }
        forgetRuns(of: id)
        save()
    }

    // Every shortcut a project owns goes with it, so removing a project does not leave
    // commands filed under a name nothing can show. Shared shortcuts belong to the Mac
    // and must remain available to the other projects.
    func removeAll(ownedBy projectID: UUID) {
        let owned = shortcuts.filter { $0.projectID == projectID }
        for shortcut in owned {
            remove(shortcut.id)
        }
    }

    func isRunningAnywhere(_ id: Shortcut.ID) -> Bool {
        states.contains { $0.key.shortcutID == id && $0.value.isActive }
    }

    // MARK: - Running

    // Only a command has anything to run. A prompt is sent by the session rail, which
    // has the conversation to send it to; nothing here can reach one.
    func start(_ run: ShortcutRun) {
        guard !state(run).isActive, let shortcut = shortcut(run.shortcutID),
              shortcut.kind == .command else { return }

        let token = UUID()
        runTokens[run] = token
        logs[run] = ""
        states[run] = .running(since: Date())

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ProcessManager.searchPath
        let store = self
        let task = Task {
            do {
                let result = try await CommandRunner.run(
                    executable: "/bin/zsh",
                    arguments: ["-lc", shortcut.text],
                    currentDirectory: URL(fileURLWithPath: run.directory),
                    environment: environment,
                    outputChunkHandler: { data in
                        Task { @MainActor in store.append(data, to: run, token: token) }
                    },
                    errorOutputChunkHandler: { data in
                        Task { @MainActor in store.append(data, to: run, token: token) }
                    },
                    timeout: nil
                )
                store.finished(run, token: token, status: result.status)
            } catch let error as CommandRunner.RunError {
                store.failed(run, token: token, error: error)
            } catch {
                store.failed(run, token: token, message: error.localizedDescription)
            }
        }
        tasks[run] = task
    }

    func stop(_ run: ShortcutRun) {
        tasks[run]?.cancel()
        tasks[run] = nil
        runTokens[run] = nil
        states[run] = .stopped
    }

    func stopAll() {
        for run in Array(tasks.keys) { stop(run) }
    }

    func clearLog(_ run: ShortcutRun) {
        logs[run] = ""
    }

    // MARK: - Private

    private func stopEveryRun(of id: Shortcut.ID) {
        for run in tasks.keys where run.shortcutID == id { stop(run) }
    }

    private func forgetRuns(of id: Shortcut.ID) {
        for run in states.keys where run.shortcutID == id { states[run] = nil }
        for run in logs.keys where run.shortcutID == id { logs[run] = nil }
        for run in runTokens.keys where run.shortcutID == id { runTokens[run] = nil }
        // Every screen showing one of these runs loses it, not just the one the reader
        // was on: the drawer has nothing left to report.
        for scope in openOutput.keys where openOutput[scope]?.shortcutID == id {
            openOutput[scope] = nil
        }
    }

    private func finished(_ run: ShortcutRun, token: UUID, status: Int32) {
        guard runTokens[run] == token else { return }
        tasks[run] = nil
        states[run] = status == 0
            ? .finished(at: Date())
            : .failed("Exited with code \(status). See output below.",
                      status: status, at: Date())
    }

    private func failed(_ run: ShortcutRun, token: UUID, error: CommandRunner.RunError) {
        guard runTokens[run] == token else { return }
        tasks[run] = nil
        if error == .cancelled {
            states[run] = .stopped
        } else {
            states[run] = .failed(error.localizedDescription, at: Date())
        }
    }

    private func failed(_ run: ShortcutRun, token: UUID, message: String) {
        guard runTokens[run] == token else { return }
        tasks[run] = nil
        states[run] = .failed(message, at: Date())
    }

    private func append(_ data: Data, to run: ShortcutRun, token: UUID) {
        guard runTokens[run] == token else { return }
        var current = (logs[run] ?? "") + String(decoding: data, as: UTF8.self)
        if current.count > 20_000 { current = String(current.suffix(20_000)) }
        logs[run] = current
    }
}
