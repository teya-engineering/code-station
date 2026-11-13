import Foundation
import Observation
import Synchronization

enum ShortcutKind: String, Codable, CaseIterable, Sendable {
    case command
    case prompt

    var title: String { self == .command ? "Command" : "Prompt" }
    var icon: String { self == .command ? "terminal" : "text.quote" }
}

struct Shortcut: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var text: String
    var kind: ShortcutKind
    // An SF Symbol drawn beside the name, and nil for a shortcut that goes by its name
    // alone. Only a symbol the system can render is kept, so a file naming one this
    // build does not have leaves the shortcut without an icon rather than with a gap.
    var icon: String?
    // A nil owner makes the shortcut available in every project.
    var projectID: UUID?
    var availableInAllProjects: Bool
    var favorite: Bool

    init(id: UUID = UUID(), name: String, text: String, kind: ShortcutKind = .command,
         icon: String? = nil, projectID: UUID? = nil, availableInAllProjects: Bool = false,
         favorite: Bool = false) {
        self.id = id
        self.name = name
        self.text = text
        self.kind = kind
        self.icon = ShortcutIcon.resolve(icon)
        self.projectID = availableInAllProjects ? nil : projectID
        self.availableInAllProjects = availableInAllProjects || projectID == nil
        self.favorite = favorite
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, icon, projectID, availableInAllProjects, favorite
        case text = "command"
    }

    // Records without a kind are commands. Ownerless records join the global library;
    // project ownership, text, icons and favorites survive that migration.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try container.decode(UUID.self, forKey: .id),
                  name: try container.decode(String.self, forKey: .name),
                  text: try container.decode(String.self, forKey: .text),
                  kind: try container.decodeIfPresent(ShortcutKind.self, forKey: .kind) ?? .command,
                  icon: try container.decodeIfPresent(String.self, forKey: .icon),
                  projectID: try container.decodeIfPresent(UUID.self, forKey: .projectID),
                  availableInAllProjects: try container.decodeIfPresent(
                    Bool.self, forKey: .availableInAllProjects) ?? false,
                  favorite: try container.decodeIfPresent(Bool.self, forKey: .favorite) ?? false)
    }

    // A shared command with no icon falls back to the globe to show its wider scope.
    var glyph: String? {
        if let icon { return icon }
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

        enum CodingKeys: String, CodingKey {
            case shortcuts, importedSiteShortcutIDs
        }

        init(shortcuts: [Shortcut], importedSiteShortcutIDs: [UUID]) {
            self.shortcuts = shortcuts
            self.importedSiteShortcutIDs = importedSiteShortcutIDs
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            shortcuts = try container.decode([Shortcut].self, forKey: .shortcuts)
            importedSiteShortcutIDs = try container.decodeIfPresent([UUID].self,
                                                                    forKey: .importedSiteShortcutIDs)
        }
    }

    private struct InvalidFile: LocalizedError {
        var errorDescription: String? {
            "Each shortcut needs a unique ID, a name, and command or prompt text."
        }
    }

    private(set) var shortcuts: [Shortcut] = SiteDefaults.current.startingShortcuts
    private(set) var states: [ShortcutRun: State] = [:]
    private(set) var logs: [ShortcutRun: String] = [:]
    // How long each run's last finish took. Kept beside the state rather than inside it,
    // so a state can still be compared and matched on without the timing in the way.
    private(set) var durations: [ShortcutRun: TimeInterval] = [:]
    // The command each screen ran last, which is what its Run button offers again. It is
    // here rather than in the view for the same reason the open output is.
    private var lastStarted: [ShortcutScope: Shortcut.ID] = [:]
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

    func libraryShortcuts(query: String = "", kind: ShortcutKind? = nil) -> [Shortcut] {
        let matches = macShortcuts.filter {
            (kind == nil || $0.kind == kind)
                && (query.isBlank || ($0.name + " " + $0.text).localizedStandardContains(query.trimmed))
        }
        return matches.filter(\.favorite) + matches.filter { !$0.favorite }
    }

    @discardableResult
    func toggleFavorite(_ id: Shortcut.ID) -> Bool {
        guard let index = shortcuts.firstIndex(where: { $0.id == id }) else { return false }
        shortcuts[index].favorite.toggle()
        guard save() else {
            shortcuts[index].favorite.toggle()
            return false
        }
        return true
    }

    var siteConfigurationShortcuts: [SiteDefaults.ShortcutEntry] {
        shortcuts.compactMap { shortcut in
            guard shortcut.kind == .command, importedSiteShortcutIDs.contains(shortcut.id) else { return nil }
            return SiteDefaults.ShortcutEntry(name: shortcut.name, command: shortcut.text,
                                              icon: shortcut.icon)
        }
    }

    func shortcuts(for projectID: UUID) -> [Shortcut] {
        shortcuts.filter {
            $0.projectID == projectID || ($0.projectID == nil && $0.availableInAllProjects)
        }
    }

    // A shared shortcut is available through every project, but a workspace should only
    // show one chip for it. The first project is the workspace lead, so it also supplies
    // the checkout where that single chip runs.
    func shortcuts(for projectIDs: [UUID]) -> [ShortcutPlacement] {
        var seen: Set<Shortcut.ID> = []
        return projectIDs.flatMap { projectID in
            shortcuts(for: projectID).compactMap { shortcut in
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

    func duration(_ run: ShortcutRun) -> TimeInterval? {
        durations[run]
    }

    // A run is given a log the moment it starts, so a stopped run that has a log was
    // started and then called off, and one without has never been run here at all.
    func hasStarted(_ run: ShortcutRun) -> Bool {
        logs[run] != nil
    }

    func lastStarted(for scope: ShortcutScope) -> Shortcut.ID? {
        lastStarted[scope]
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
        lastStarted[scope] = nil
    }

    // MARK: - Persistence

    nonisolated static func remappingProjects(in data: Data, using ids: [UUID: UUID]) throws -> Data {
        guard ids.contains(where: { $0.key != $0.value }) else { return data }
        var persisted = try PersistentFile.makeDecoder().decode(Persisted.self, from: data)
        for index in persisted.shortcuts.indices {
            if let projectID = persisted.shortcuts[index].projectID, let replacement = ids[projectID] {
                persisted.shortcuts[index].projectID = replacement
            }
        }
        return try PersistentFile.makeEncoder().encode(persisted)
    }

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
    func saveShortcut(_ shortcut: Shortcut) -> Bool {
        guard !shortcut.name.isBlank, !shortcut.text.isBlank,
              !isRunningAnywhere(shortcut.id) else { return false }
        let previous = shortcuts
        var saved = shortcut
        saved.name = saved.name.trimmed
        if saved.kind == .command { saved.text = saved.text.trimmed }
        saved.icon = ShortcutIcon.resolve(saved.icon)
        if saved.availableInAllProjects { saved.projectID = nil }
        if saved.projectID == nil { saved.availableInAllProjects = true }
        if let index = shortcuts.firstIndex(where: { $0.id == saved.id }) {
            // Stars save independently of an open editor's draft.
            saved.favorite = shortcuts[index].favorite
            shortcuts[index] = saved
        } else {
            shortcuts.append(saved)
        }
        guard save() else {
            shortcuts = previous
            return false
        }
        if let old = previous.first(where: { $0.id == saved.id }),
           old.text != saved.text || old.kind != saved.kind {
            forgetRuns(of: saved.id)
        }
        if saved.kind == .prompt {
            lastStarted = lastStarted.filter { $0.value != saved.id }
        }
        return true
    }

    @discardableResult
    func add(name: String, text: String, kind: ShortcutKind = .command,
             icon: String? = nil, projectID: UUID? = nil,
             availableInAllProjects: Bool = false) -> Shortcut.ID? {
        let name = name.trimmed
        guard !name.isEmpty, !text.isBlank else { return nil }
        let shortcut = Shortcut(
            name: name,
            text: text,
            kind: kind,
            icon: icon,
            projectID: projectID,
            availableInAllProjects: availableInAllProjects
        )
        return saveShortcut(shortcut) ? shortcut.id : nil
    }

    func update(_ shortcut: Shortcut) {
        guard shortcuts.contains(where: { $0.id == shortcut.id }) else { return }
        saveShortcut(shortcut)
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

    func start(_ run: ShortcutRun, for scope: ShortcutScope? = nil) {
        guard !state(run).isActive, let shortcut = shortcut(run.shortcutID),
              shortcut.kind == .command else { return }
        if let scope { lastStarted[scope] = run.shortcutID }

        let token = UUID()
        runTokens[run] = token
        logs[run] = ""
        states[run] = .running(since: Date())

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ProcessManager.searchPath
        let store = self
        let outputDecoder = Mutex(UTF8StreamDecoder())
        let errorDecoder = Mutex(UTF8StreamDecoder())
        let task = Task {
            defer {
                let tail = outputDecoder.withLock { $0.finish() } + errorDecoder.withLock { $0.finish() }
                store.append(tail, to: run, token: token)
            }
            do {
                let result = try await CommandRunner.run(
                    executable: "/bin/zsh",
                    arguments: ["-lc", shortcut.text],
                    currentDirectory: URL(fileURLWithPath: run.directory),
                    environment: environment,
                    outputChunkHandler: { data in
                        let text = outputDecoder.withLock { $0.append(data) }
                        Task { @MainActor in store.append(text, to: run, token: token) }
                    },
                    errorOutputChunkHandler: { data in
                        let text = errorDecoder.withLock { $0.append(data) }
                        Task { @MainActor in store.append(text, to: run, token: token) }
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
        for run in durations.keys where run.shortcutID == id { durations[run] = nil }
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
        recordDuration(of: run)
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
            recordDuration(of: run)
            states[run] = .failed(error.localizedDescription, at: Date())
        }
    }

    private func failed(_ run: ShortcutRun, token: UUID, message: String) {
        guard runTokens[run] == token else { return }
        tasks[run] = nil
        recordDuration(of: run)
        states[run] = .failed(message, at: Date())
    }

    private func recordDuration(of run: ShortcutRun) {
        guard case .running(let since) = state(run) else { return }
        durations[run] = Date().timeIntervalSince(since)
    }

    private func append(_ text: String, to run: ShortcutRun, token: UUID) {
        guard runTokens[run] == token, !text.isEmpty else { return }
        var current = (logs[run] ?? "") + text
        if current.count > 20_000 { current = String(current.suffix(20_000)) }
        logs[run] = current
    }
}
