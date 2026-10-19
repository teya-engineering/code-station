import Foundation
import Observation
import Synchronization

// Mac commands run from home. Project commands and shared Mac commands run in the
// active worktree, so they apply to the branch the reader is working on.
public struct Shortcut: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var text: String
    // An SF Symbol drawn beside the name, and nil for a shortcut that goes by its name
    // alone. Only a symbol the system can render is kept, so a file naming one this
    // build does not have leaves the shortcut without an icon rather than with a gap.
    public var icon: String?
    // The project this shortcut is filed under, and nil for the ones that belong to the
    // Mac rather than to any checkout.
    public var projectID: UUID?
    // A Mac shortcut can also be offered by every project. It stays on the Mac's list so
    // there is still one place to edit or remove it.
    public var availableInAllProjects: Bool
    public var favorite: Bool

    public init(id: UUID = UUID(), name: String, text: String,
         icon: String? = nil, projectID: UUID? = nil, availableInAllProjects: Bool = false,
         favorite: Bool = false) {
        self.id = id
        self.name = name
        self.text = text
        self.icon = ShortcutSymbols.resolve(icon)
        self.projectID = availableInAllProjects ? nil : projectID
        self.availableInAllProjects = availableInAllProjects
        self.favorite = favorite
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, icon, projectID, availableInAllProjects, favorite
        case text = "command"
    }

    // Shortcuts saved before they could belong to a project are the Mac's own. Shortcuts
    // saved before sharing was added remain private to that list, ones saved before icons
    // go by their name. Favorites are opt-in.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try container.decode(UUID.self, forKey: .id),
                  name: try container.decode(String.self, forKey: .name),
                  text: try container.decode(String.self, forKey: .text),
                  icon: try container.decodeIfPresent(String.self, forKey: .icon),
                  projectID: try container.decodeIfPresent(UUID.self, forKey: .projectID),
                  availableInAllProjects: try container.decodeIfPresent(
                    Bool.self, forKey: .availableInAllProjects) ?? false,
                  favorite: try container.decodeIfPresent(Bool.self, forKey: .favorite) ?? false)
    }

    // A shared command with no icon falls back to the globe to show its wider scope.
    public var glyph: String? {
        if let icon { return icon }
        return availableInAllProjects ? "globe" : nil
    }

    // The folder this run happens in. A project shortcut or a shared Mac shortcut falls
    // back to the checkout, which is what it means for a project with nothing open:
    // there is no worktree in front of you, so the folder the worktrees come from is the
    // honest answer.
    public func directory(projectPath: String?, workspacePath: String? = nil) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard projectID != nil || availableInAllProjects else { return home }
        return workspacePath ?? projectPath ?? home
    }
}

// One shortcut in one folder. The same project shortcut can be running in two worktrees
// at once, and each of those runs has its own state and its own output, so a run is only
// identified by both together.
public struct ShortcutRun: Hashable, Sendable {
    public let shortcutID: Shortcut.ID
    public let directory: String

    public init(_ shortcutID: Shortcut.ID, in directory: String) {
        self.shortcutID = shortcutID
        self.directory = directory
    }
}

// The screen an output drawer is docked on. A project overview and each session in it are
// separate screens, so each one remembers the run it is showing.
public enum ShortcutScope: Hashable, Sendable {
    case project(UUID)
    case session(UUID)

    // A workspace screen has no shortcut chips, so nothing is ever filed under one.
    public init?(_ owner: RemovedOwner) {
        switch owner {
        case .project(let id): self = .project(id)
        case .session(let id): self = .session(id)
        case .workspace: return nil
        }
    }
}

// One shortcut as it is offered in a group of projects. Shared shortcuts have no project
// of their own, so the project records the checkout they will run in.
public struct ShortcutPlacement: Identifiable, Equatable, Sendable {
    public let shortcut: Shortcut
    public let projectID: UUID

    public var id: Shortcut.ID { shortcut.id }
}

@MainActor
@Observable
public final class ShortcutStore {
    public enum State: Equatable, Sendable {
        case stopped
        case running(since: Date)
        case finished(at: Date)
        // The exit code is kept apart from the message because a chip has room for the
        // code and nothing else, while the output pane wants the sentence.
        case failed(String, status: Int32? = nil, at: Date)

        public var isActive: Bool {
            if case .running = self { true } else { false }
        }

        public var isFailure: Bool {
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
            shortcuts = try container.decode([CommandShortcutRecord<Shortcut>].self,
                                              forKey: .shortcuts).compactMap(\.value)
            importedSiteShortcutIDs = try container.decodeIfPresent([UUID].self,
                                                                    forKey: .importedSiteShortcutIDs)
        }
    }

    private struct InvalidFile: LocalizedError {
        var errorDescription: String? {
            "Each shortcut needs a unique ID, a name, and a command."
        }
    }

    public private(set) var shortcuts: [Shortcut] = []
    public private(set) var states: [ShortcutRun: State] = [:]
    public private(set) var logs: [ShortcutRun: String] = [:]
    // How long each run's last finish took. Kept beside the state rather than inside it,
    // so a state can still be compared and matched on without the timing in the way.
    public private(set) var durations: [ShortcutRun: TimeInterval] = [:]
    // The command each screen ran last, which is what its Run button offers again. It is
    // here rather than in the view for the same reason the open output is.
    private var lastStarted: [ShortcutScope: Shortcut.ID] = [:]
    // Which run each screen has its output open on. It is kept here rather than in the
    // view because a pane is thrown away and built again every time the sidebar moves,
    // and a command started before switching away is the one most worth coming back to.
    private var openOutput: [ShortcutScope: ShortcutRun] = [:]
    public private(set) var loadError: String?
    public private(set) var saveError: String?
    private var importedSiteShortcutIDs: Set<UUID> = []

    public let storageURL: URL
    @ObservationIgnored private var tasks: [ShortcutRun: Task<Void, Never>] = [:]
    @ObservationIgnored private var runTokens: [ShortcutRun: UUID] = [:]

    // `startingShortcuts` are what a first run starts with: the site configuration's, in
    // the GUI (see its `SiteDefaults`), and none for a host that has no site file to read.
    // A saved collection always wins over them.
    public init(storageURL: URL?, startingShortcuts: [Shortcut]) {
        self.storageURL = storageURL ?? Self.standardURL
        shortcuts = startingShortcuts
        importedSiteShortcutIDs = Set(startingShortcuts.map(\.id))
        load(startingShortcuts: startingShortcuts)
    }

    // Where the GUI has always kept them, which every host reads.
    public static var standardURL: URL { AppPaths.supportFile("shortcuts.json") }

    public func applySiteShortcuts(_ siteShortcuts: [Shortcut]) {
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
    public func resetSiteShortcuts(to siteShortcuts: [Shortcut]) {
        let removed = importedSiteShortcutIDs
        for id in removed { stopEveryRun(of: id) }
        shortcuts.removeAll { removed.contains($0.id) }
        for id in removed { forgetRuns(of: id) }

        importedSiteShortcutIDs = Set(siteShortcuts.map(\.id))
        shortcuts.append(contentsOf: siteShortcuts)
        save()
    }

    // Counted over the shortcuts the asking screen shows rather than over every saved
    // shortcut. A shared shortcut can have a separate run in each folder, and each active
    // run counts because each is a command the reader may need to stop.
    public func runningCount(of shortcuts: [Shortcut]) -> Int {
        count(over: shortcuts, where: \.isActive)
    }

    public func failureCount(of shortcuts: [Shortcut]) -> Int {
        count(over: shortcuts, where: \.isFailure)
    }

    private func count(over shortcuts: [Shortcut],
                       where matches: (State) -> Bool) -> Int {
        let ids = Set(shortcuts.map(\.id))
        return states.count { ids.contains($0.key.shortcutID) && matches($0.value) }
    }

    public func shortcut(_ id: Shortcut.ID) -> Shortcut? {
        shortcuts.first { $0.id == id }
    }

    // The ones filed under the Mac, and the ones available to one project. Both keep the
    // order they were added in, so a list never reshuffles itself under the reader.
    public var macShortcuts: [Shortcut] {
        shortcuts.filter { $0.projectID == nil }
    }

    public func libraryShortcuts(query: String = "") -> [Shortcut] {
        let matches = macShortcuts.filter {
            query.isBlank || ($0.name + " " + $0.text).localizedStandardContains(query.trimmed)
        }
        return matches.filter(\.favorite) + matches.filter { !$0.favorite }
    }

    @discardableResult
    public func toggleFavorite(_ id: Shortcut.ID) -> Bool {
        guard let index = shortcuts.firstIndex(where: { $0.id == id }) else { return false }
        shortcuts[index].favorite.toggle()
        guard save() else {
            shortcuts[index].favorite.toggle()
            return false
        }
        return true
    }

    // The ones that came from the site configuration, which the GUI writes back to it.
    public var siteShortcuts: [Shortcut] {
        shortcuts.filter { importedSiteShortcutIDs.contains($0.id) }
    }

    public func shortcuts(for projectID: UUID) -> [Shortcut] {
        shortcuts.filter {
            $0.projectID == projectID || ($0.projectID == nil && $0.availableInAllProjects)
        }
    }

    // A shared shortcut is available through every project, but a workspace should only
    // show one chip for it. The first project is the workspace lead, so it also supplies
    // the checkout where that single chip runs.
    public func shortcuts(for projectIDs: [UUID]) -> [ShortcutPlacement] {
        var seen: Set<Shortcut.ID> = []
        return projectIDs.flatMap { projectID in
            shortcuts(for: projectID).compactMap { shortcut in
                guard seen.insert(shortcut.id).inserted else { return nil }
                return ShortcutPlacement(shortcut: shortcut, projectID: projectID)
            }
        }
    }

    public func state(_ run: ShortcutRun) -> State {
        states[run] ?? .stopped
    }

    public func log(_ run: ShortcutRun) -> String {
        logs[run] ?? ""
    }

    public func duration(_ run: ShortcutRun) -> TimeInterval? {
        durations[run]
    }

    // A run is given a log the moment it starts, so a stopped run that has a log was
    // started and then called off, and one without has never been run here at all.
    public func hasStarted(_ run: ShortcutRun) -> Bool {
        logs[run] != nil
    }

    public func lastStarted(for scope: ShortcutScope) -> Shortcut.ID? {
        lastStarted[scope]
    }

    // MARK: - The output drawer

    public func output(for scope: ShortcutScope) -> ShortcutRun? {
        openOutput[scope]
    }

    public func showOutput(_ run: ShortcutRun?, for scope: ShortcutScope) {
        openOutput[scope] = run
    }

    // A deleted project or session leaves nothing that can reach its drawer again.
    public func discard(_ scope: ShortcutScope) {
        openOutput[scope] = nil
        lastStarted[scope] = nil
    }

    // MARK: - Persistence

    // A file that cannot be read and one that cannot be understood are told apart, since
    // the first is about permissions and the second about what is in it.
    public func load(startingShortcuts: [Shortcut]) {
        let data: Data?
        do {
            data = try PersistentFile.readIfPresent(storageURL)
        } catch {
            loadError = PersistentFile.loadMessage(for: storageURL, error: error)
            return
        }

        guard let data else {
            shortcuts = startingShortcuts
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
                ?? startingShortcuts.map(\.id))
            loadError = nil
            saveError = nil
        } catch {
            loadError = PersistentFile.decodeMessage(for: storageURL, error: error)
        }
    }

    @discardableResult
    public func save() -> Bool {
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
    public func saveShortcut(_ shortcut: Shortcut) -> Bool {
        guard !shortcut.name.isBlank, !shortcut.text.isBlank,
              !isRunningAnywhere(shortcut.id) else { return false }
        let previous = shortcuts
        var saved = shortcut
        saved.name = saved.name.trimmed
        saved.text = saved.text.trimmed
        saved.icon = ShortcutSymbols.resolve(saved.icon)
        if saved.availableInAllProjects { saved.projectID = nil }
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
           old.text != saved.text {
            forgetRuns(of: saved.id)
        }
        return true
    }

    @discardableResult
    public func add(name: String, text: String,
             icon: String? = nil, projectID: UUID? = nil,
             availableInAllProjects: Bool = false) -> Shortcut.ID? {
        let name = name.trimmed
        let text = text.trimmed
        guard !name.isEmpty, !text.isEmpty else { return nil }
        let shortcut = Shortcut(
            name: name,
            text: text,
            icon: icon,
            projectID: projectID,
            availableInAllProjects: availableInAllProjects
        )
        shortcuts.append(shortcut)
        save()
        return shortcut.id
    }

    public func update(_ shortcut: Shortcut) {
        guard shortcuts.contains(where: { $0.id == shortcut.id }) else { return }
        saveShortcut(shortcut)
    }

    public func remove(_ id: Shortcut.ID) {
        stopEveryRun(of: id)
        shortcuts.removeAll { $0.id == id }
        forgetRuns(of: id)
        save()
    }

    // Every shortcut a project owns goes with it, so removing a project does not leave
    // commands filed under a name nothing can show. Shared shortcuts belong to the Mac
    // and must remain available to the other projects.
    public func removeAll(ownedBy projectID: UUID) {
        let owned = shortcuts.filter { $0.projectID == projectID }
        for shortcut in owned {
            remove(shortcut.id)
        }
    }

    public var isRunningAny: Bool {
        states.values.contains(where: \.isActive)
    }

    public func isRunningAnywhere(_ id: Shortcut.ID) -> Bool {
        states.contains { $0.key.shortcutID == id && $0.value.isActive }
    }

    // MARK: - Running

    public func start(_ run: ShortcutRun, for scope: ShortcutScope? = nil) {
        guard !state(run).isActive, let shortcut = shortcut(run.shortcutID) else { return }
        if let scope { lastStarted[scope] = run.shortcutID }

        let token = UUID()
        runTokens[run] = token
        logs[run] = ""
        states[run] = .running(since: Date())

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ExecutableSearch.searchPath
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

    public func stop(_ run: ShortcutRun) {
        tasks[run]?.cancel()
        tasks[run] = nil
        runTokens[run] = nil
        states[run] = .stopped
    }

    public func stopAll() {
        for run in Array(tasks.keys) { stop(run) }
    }

    public func clearLog(_ run: ShortcutRun) {
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

    private func append(_ data: Data, to run: ShortcutRun, token: UUID) {
        guard runTokens[run] == token else { return }
        var current = (logs[run] ?? "") + String(decoding: data, as: UTF8.self)
        if current.count > 20_000 { current = String(current.suffix(20_000)) }
        logs[run] = current
    }
}

// Whether a symbol name can be drawn. The core draws nothing, so it keeps every name it is
// given; the GUI installs AppKit's answer (see its `ShortcutIcon`), so a name this build
// cannot draw is dropped as a shortcut is read or saved, rather than drawn as a gap.
public enum ShortcutSymbols {
    private static let check = Mutex<(@Sendable (String) -> Bool)?>(nil)

    public static func install(_ isDrawable: @escaping @Sendable (String) -> Bool) {
        check.withLock { $0 = isDrawable }
    }

    public static func resolve(_ symbol: String?) -> String? {
        guard let symbol = symbol?.trimmed, !symbol.isEmpty else { return nil }
        let isDrawable = check.withLock { $0 }
        return isDrawable?(symbol) ?? true ? symbol : nil
    }
}
