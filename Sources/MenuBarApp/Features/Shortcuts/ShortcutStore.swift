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

    init(id: UUID = UUID(), name: String, text: String, kind: ShortcutKind = .command,
         icon: String? = nil, projectID: UUID? = nil, availableInAllProjects: Bool = false) {
        self.id = id
        self.name = name
        self.text = text
        self.kind = kind
        self.icon = ShortcutIcon.resolve(icon)
        self.projectID = availableInAllProjects ? nil : projectID
        self.availableInAllProjects = availableInAllProjects || projectID == nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, icon, projectID, availableInAllProjects
        case text = "command"
    }

    // Records without a kind are commands. Ownerless records join the global library;
    // project ownership, text and icons survive that migration.
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

    // The orders are keyed by the UUID string, because a dictionary with UUID keys is
    // written to JSON as a flat list of keys and values rather than as an object.
    private struct Persisted: Codable {
        var shortcuts: [Shortcut]
        var importedSiteShortcutIDs: [UUID]?
        var projectOrders: [String: [UUID]]?
        var sessionOrders: [String: [UUID]]?
        // Files written before order decided the button could star shortcuts to keep them
        // on top. Stars are read once, turned into order, and never written again.
        var starred: Set<UUID> = []

        private struct Star: Decodable {
            let id: UUID
            let favorite: Bool?
        }

        enum CodingKeys: String, CodingKey {
            case shortcuts, importedSiteShortcutIDs, projectOrders, sessionOrders
        }

        init(shortcuts: [Shortcut], importedSiteShortcutIDs: [UUID],
             projectOrders: [UUID: [UUID]], sessionOrders: [UUID: [UUID]]) {
            self.shortcuts = shortcuts
            self.importedSiteShortcutIDs = importedSiteShortcutIDs
            self.projectOrders = projectOrders.isEmpty ? nil : Self.encode(projectOrders)
            self.sessionOrders = sessionOrders.isEmpty ? nil : Self.encode(sessionOrders)
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            shortcuts = try container.decode([Shortcut].self, forKey: .shortcuts)
            starred = Set(try container.decode([Star].self, forKey: .shortcuts)
                .filter { $0.favorite == true }.map(\.id))
            importedSiteShortcutIDs = try container.decodeIfPresent([UUID].self,
                                                                    forKey: .importedSiteShortcutIDs)
            projectOrders = try container.decodeIfPresent([String: [UUID]].self, forKey: .projectOrders)
            sessionOrders = try container.decodeIfPresent([String: [UUID]].self, forKey: .sessionOrders)
        }

        static func encode(_ orders: [UUID: [UUID]]) -> [String: [UUID]] {
            Dictionary(uniqueKeysWithValues: orders.map { ($0.key.uuidString, $0.value) })
        }

        static func decode(_ orders: [String: [UUID]]?) -> [UUID: [UUID]] {
            var decoded: [UUID: [UUID]] = [:]
            for (key, value) in orders ?? [:] {
                if let id = UUID(uuidString: key) { decoded[id] = value }
            }
            return decoded
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
    // Which run each screen has its output open on. It is kept here rather than in the
    // view because a pane is thrown away and built again every time the sidebar moves,
    // and a command started before switching away is the one most worth coming back to.
    private var openOutput: [ShortcutScope: ShortcutRun] = [:]
    // A project or a session can keep its own order of the shortcuts it shows. Without
    // one, it follows the order of the saved list, which is the order set in Settings.
    private(set) var projectOrders: [UUID: [Shortcut.ID]] = [:]
    private(set) var sessionOrders: [UUID: [Shortcut.ID]] = [:]
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
    // order of the saved list, which only changes when the reader drags a shortcut.
    var macShortcuts: [Shortcut] {
        shortcuts.filter { $0.projectID == nil }
    }

    func libraryShortcuts(query: String = "", kind: ShortcutKind? = nil) -> [Shortcut] {
        macShortcuts.filter { Self.matches($0, query: query, kind: kind) }
    }

    static func matches(_ shortcut: Shortcut, query: String, kind: ShortcutKind?) -> Bool {
        (kind == nil || shortcut.kind == kind)
            && (query.isBlank || (shortcut.name + " " + shortcut.text).localizedStandardContains(query.trimmed))
    }

    var siteConfigurationShortcuts: [SiteDefaults.ShortcutEntry] {
        shortcuts.compactMap { shortcut in
            guard shortcut.kind == .command, importedSiteShortcutIDs.contains(shortcut.id) else { return nil }
            return SiteDefaults.ShortcutEntry(name: shortcut.name, command: shortcut.text,
                                              icon: shortcut.icon)
        }
    }

    func shortcuts(for projectID: UUID) -> [Shortcut] {
        Self.ordering(shortcuts.filter {
            $0.projectID == projectID || ($0.projectID == nil && $0.availableInAllProjects)
        }, by: projectOrders[projectID])
    }

    // A shared shortcut is available through every project, but a workspace should only
    // show one chip for it. The first project is the workspace lead, so it also supplies
    // the checkout where that single chip runs.
    func shortcuts(for projectIDs: [UUID], session sessionID: UUID? = nil) -> [ShortcutPlacement] {
        var seen: Set<Shortcut.ID> = []
        let placements = projectIDs.flatMap { projectID in
            shortcuts(for: projectID).compactMap { shortcut -> ShortcutPlacement? in
                guard seen.insert(shortcut.id).inserted else { return nil }
                return ShortcutPlacement(shortcut: shortcut, projectID: projectID)
            }
        }
        return Self.ordering(placements, by: sessionID.flatMap { sessionOrders[$0] })
    }

    // MARK: - Order

    // The ones the saved order names come first, in that order. Anything it does not name,
    // such as a shortcut added after the order was set, follows in its default place.
    static func ordering<Item: Identifiable>(_ items: [Item], by order: [Item.ID]?) -> [Item] {
        guard let order, !order.isEmpty else { return items }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let named = items.filter { rank[$0.id] != nil }.sorted { rank[$0.id]! < rank[$1.id]! }
        return named + items.filter { rank[$0.id] == nil }
    }

    // Puts one id at a position in the list, counted as if it had already been taken out.
    // A position past either end is held to that end, and an id that is missing leaves
    // the list as it was.
    static func moving<ID: Equatable>(_ id: ID, to position: Int, in ids: [ID]) -> [ID] {
        guard let from = ids.firstIndex(of: id) else { return ids }
        var moved = ids
        moved.remove(at: from)
        moved.insert(id, at: min(max(position, 0), moved.count))
        return moved
    }

    func hasOwnOrder(_ scope: ShortcutScope) -> Bool {
        switch scope {
        case .project(let id): projectOrders[id] != nil
        case .session(let id): sessionOrders[id] != nil
        }
    }

    // Reorders the saved list itself, which is the default every project and session
    // follows until it is given an order of its own. The position counts over the
    // shortcuts Settings shows. Project shortcuts keep their places in the saved list,
    // so only the slots the shared ones hold are shuffled.
    @discardableResult
    func moveInLibrary(_ id: Shortcut.ID, to position: Int) -> Bool {
        let shown = macShortcuts.map(\.id)
        let ids = Self.moving(id, to: position, in: shown)
        guard ids != shown else { return false }
        let previous = shortcuts
        let byID = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.id, $0) })
        var next = ids.makeIterator()
        shortcuts = shortcuts.map { shortcut in
            guard shortcut.projectID == nil, let id = next.next(), let moved = byID[id] else { return shortcut }
            return moved
        }
        guard save() else {
            shortcuts = previous
            return false
        }
        return true
    }

    // Gives a project or session its own order. The caller passes every id the screen
    // shows in the order it shows them, so the move is made on what the reader sees.
    @discardableResult
    func move(_ id: Shortcut.ID, to position: Int,
              in shown: [Shortcut.ID], for scope: ShortcutScope) -> Bool {
        let ids = Self.moving(id, to: position, in: shown)
        guard ids != shown else { return false }
        return setOrder(ids, for: scope)
    }

    // A session's order becomes its project's, so every session of the project that has
    // no order of its own follows it.
    @discardableResult
    func keepSessionOrder(_ sessionID: UUID, for projectID: UUID) -> Bool {
        guard let order = sessionOrders[sessionID] else { return false }
        let previous = (projectOrders, sessionOrders)
        projectOrders[projectID] = order
        sessionOrders[sessionID] = nil
        guard save() else {
            (projectOrders, sessionOrders) = previous
            return false
        }
        return true
    }

    var hasOwnOrders: Bool { !projectOrders.isEmpty || !sessionOrders.isEmpty }

    // Every project and session goes back to the saved order, which Settings shows.
    @discardableResult
    func clearOwnOrders() -> Bool {
        guard hasOwnOrders else { return true }
        let previous = (projectOrders, sessionOrders)
        projectOrders = [:]
        sessionOrders = [:]
        guard save() else {
            (projectOrders, sessionOrders) = previous
            return false
        }
        return true
    }

    @discardableResult
    func resetOrder(for scope: ShortcutScope) -> Bool {
        guard hasOwnOrder(scope) else { return true }
        return setOrder(nil, for: scope)
    }

    @discardableResult
    private func setOrder(_ ids: [Shortcut.ID]?, for scope: ShortcutScope) -> Bool {
        let previous = (projectOrders, sessionOrders)
        switch scope {
        case .project(let id): projectOrders[id] = ids
        case .session(let id): sessionOrders[id] = ids
        }
        guard save() else {
            (projectOrders, sessionOrders) = previous
            return false
        }
        return true
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
        if hasOwnOrder(scope) { setOrder(nil, for: scope) }
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
        if let orders = persisted.projectOrders {
            var remapped: [String: [UUID]] = [:]
            for (key, order) in orders {
                let replacement = UUID(uuidString: key).flatMap { ids[$0] }
                remapped[replacement?.uuidString ?? key] = order
            }
            persisted.projectOrders = remapped
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
            projectOrders = [:]
            sessionOrders = [:]
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
            // Starred shortcuts used to sit above the rest, so they lead the order now.
            let starred = persisted.starred
            shortcuts = persisted.shortcuts.filter { starred.contains($0.id) }
                + persisted.shortcuts.filter { !starred.contains($0.id) }
            importedSiteShortcutIDs = Set(persisted.importedSiteShortcutIDs
                ?? siteDefaults.startingShortcuts.map(\.id))
            projectOrders = Persisted.decode(persisted.projectOrders)
            sessionOrders = Persisted.decode(persisted.sessionOrders)
            loadError = nil
            saveError = nil
            if !starred.isEmpty { save() }
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
                Persisted(shortcuts: shortcuts, importedSiteShortcutIDs: importedIDs,
                          projectOrders: projectOrders, sessionOrders: sessionOrders),
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
