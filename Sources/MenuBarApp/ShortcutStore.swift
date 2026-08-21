import Foundation
import Observation

// A saved command and the scope that decides where it runs. The Mac's own commands run
// from home. A project's commands and the Mac commands shared with every project run in
// whichever worktree is in front of you, which is what makes "run the tests" mean this
// session's tests rather than the ones in the folder the branch came from.
struct CommandShortcut: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var command: String
    // The project this shortcut is filed under, and nil for the ones that belong to the
    // Mac rather than to any checkout.
    var projectID: UUID?
    // A Mac shortcut can also be offered by every project. It stays on the Mac's list so
    // there is still one place to edit or remove it.
    var availableInAllProjects: Bool

    init(id: UUID = UUID(), name: String, command: String, projectID: UUID? = nil,
         availableInAllProjects: Bool = false) {
        self.id = id
        self.name = name
        self.command = command
        self.projectID = availableInAllProjects ? nil : projectID
        self.availableInAllProjects = availableInAllProjects
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, command, projectID, availableInAllProjects
    }

    // Shortcuts saved before they could belong to a project are the Mac's own. Shortcuts
    // saved before sharing was added remain private to that list.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try container.decode(UUID.self, forKey: .id),
                  name: try container.decode(String.self, forKey: .name),
                  command: try container.decode(String.self, forKey: .command),
                  projectID: try container.decodeIfPresent(UUID.self, forKey: .projectID),
                  availableInAllProjects: try container.decodeIfPresent(
                    Bool.self, forKey: .availableInAllProjects) ?? false)
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
    let shortcutID: CommandShortcut.ID
    let directory: String

    init(_ shortcutID: CommandShortcut.ID, in directory: String) {
        self.shortcutID = shortcutID
        self.directory = directory
    }
}

// One shortcut as it is offered in a group of projects. Shared shortcuts have no project
// of their own, so the project records the checkout they will run in.
struct ShortcutPlacement: Identifiable, Equatable, Sendable {
    let shortcut: CommandShortcut
    let projectID: UUID

    var id: CommandShortcut.ID { shortcut.id }
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

        // When this state was reached, for the runs that have finished one way or the
        // other. Nil while nothing has been run, which is when there is no age to show.
        var since: Date? {
            switch self {
            case .stopped: nil
            case .running(let date), .finished(let date), .failed(_, _, let date): date
            }
        }
    }

    private struct Persisted: Codable {
        var shortcuts: [CommandShortcut]
    }

    private struct InvalidFile: LocalizedError {
        var errorDescription: String? {
            "Each shortcut needs a unique ID, a name, and a command."
        }
    }

    private(set) var shortcuts: [CommandShortcut] = SiteDefaults.current.commandShortcuts
    private(set) var states: [ShortcutRun: State] = [:]
    private(set) var logs: [ShortcutRun: String] = [:]
    private(set) var loadError: String?
    private(set) var saveError: String?

    let storageURL: URL
    private let files: PersistentFileClient
    @ObservationIgnored private var tasks: [ShortcutRun: Task<Void, Never>] = [:]
    @ObservationIgnored private var runTokens: [ShortcutRun: UUID] = [:]

    init(storageURL: URL? = nil, files: PersistentFileClient = .live) {
        self.storageURL = storageURL ?? AppPaths.supportFile("shortcuts.json")
        self.files = files
        load()
    }

    func applySiteDefaults(_ defaults: SiteDefaults) {
        let siteShortcuts = defaults.commandShortcuts
        // Unsaved shortcuts came from the previously loaded site file. Once the user has
        // a saved collection, imports merge into it instead of replacing personal commands.
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            shortcuts = siteShortcuts
            save()
            return
        }

        var savedIDs = Set(shortcuts.map(\.id))
        var added = false
        for shortcut in siteShortcuts where savedIDs.insert(shortcut.id).inserted {
            shortcuts.append(shortcut)
            added = true
        }
        guard added else { return }
        save()
    }

    // Counted over the shortcuts the asking screen shows rather than over every saved
    // shortcut. A shared shortcut can have a separate run in each folder, and each active
    // run counts because each is a command the reader may need to stop.
    func runningCount(of shortcuts: [CommandShortcut]) -> Int {
        count(over: shortcuts, where: \.isActive)
    }

    func failureCount(of shortcuts: [CommandShortcut]) -> Int {
        count(over: shortcuts, where: \.isFailure)
    }

    private func count(over shortcuts: [CommandShortcut],
                       where matches: (State) -> Bool) -> Int {
        let ids = Set(shortcuts.map(\.id))
        return states.count { ids.contains($0.key.shortcutID) && matches($0.value) }
    }

    func shortcut(_ id: CommandShortcut.ID) -> CommandShortcut? {
        shortcuts.first { $0.id == id }
    }

    // The ones filed under the Mac, and the ones available to one project. Both keep the
    // order they were added in, so a list never reshuffles itself under the reader.
    var macShortcuts: [CommandShortcut] {
        shortcuts.filter { $0.projectID == nil }
    }

    func shortcuts(for projectID: UUID) -> [CommandShortcut] {
        shortcuts.filter {
            $0.projectID == projectID
                || ($0.projectID == nil && $0.availableInAllProjects)
        }
    }

    // A shared shortcut is available through every project, but a workspace should only
    // show one chip for it. The first project is the workspace lead, so it also supplies
    // the checkout where that single chip runs.
    func shortcuts(for projectIDs: [UUID]) -> [ShortcutPlacement] {
        var seen: Set<CommandShortcut.ID> = []
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

    // MARK: - Persistence

    func load() {
        let data: Data?
        do {
            data = try files.readIfPresent(storageURL)
        } catch {
            loadError = PersistentFile.loadMessage(for: storageURL, error: error)
            return
        }

        guard let data else {
            shortcuts = SiteDefaults.current.commandShortcuts
            loadError = nil
            saveError = nil
            return
        }

        do {
            let persisted = try JSONDecoder().decode(Persisted.self, from: data)
            let ids = Set(persisted.shortcuts.map(\.id))
            guard ids.count == persisted.shortcuts.count,
                  persisted.shortcuts.allSatisfy({
                      !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          && !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  }) else {
                throw InvalidFile()
            }
            shortcuts = persisted.shortcuts
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

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(Persisted(shortcuts: shortcuts))
            try files.write(data, storageURL)
            saveError = nil
            return true
        } catch {
            saveError = PersistentFile.saveMessage(for: storageURL, error: error)
            return false
        }
    }

    // MARK: - Mutations

    @discardableResult
    func add(name: String, command: String, projectID: UUID? = nil,
             availableInAllProjects: Bool = false) -> CommandShortcut.ID? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !command.isEmpty else { return nil }
        let shortcut = CommandShortcut(
            name: name,
            command: command,
            projectID: projectID,
            availableInAllProjects: availableInAllProjects
        )
        shortcuts.append(shortcut)
        save()
        return shortcut.id
    }

    func update(_ shortcut: CommandShortcut) {
        let name = shortcut.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = shortcut.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !command.isEmpty,
              !isRunningAnywhere(shortcut.id),
              let index = shortcuts.firstIndex(where: { $0.id == shortcut.id }) else { return }
        shortcuts[index] = CommandShortcut(
            id: shortcut.id,
            name: name,
            command: command,
            projectID: shortcut.projectID,
            availableInAllProjects: shortcut.availableInAllProjects
        )
        // The state and output on screen belong to the command that was there before,
        // so they stop meaning anything the moment it is rewritten.
        forgetRuns(of: shortcut.id)
        save()
    }

    func remove(_ id: CommandShortcut.ID) {
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

    func isRunningAnywhere(_ id: CommandShortcut.ID) -> Bool {
        states.contains { $0.key.shortcutID == id && $0.value.isActive }
    }

    // MARK: - Running

    func start(_ run: ShortcutRun) {
        guard !state(run).isActive, let shortcut = shortcut(run.shortcutID) else { return }

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
                    arguments: ["-lc", shortcut.command],
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

    private func stopEveryRun(of id: CommandShortcut.ID) {
        for run in tasks.keys where run.shortcutID == id { stop(run) }
    }

    private func forgetRuns(of id: CommandShortcut.ID) {
        for run in states.keys where run.shortcutID == id { states[run] = nil }
        for run in logs.keys where run.shortcutID == id { logs[run] = nil }
        for run in runTokens.keys where run.shortcutID == id { runTokens[run] = nil }
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
