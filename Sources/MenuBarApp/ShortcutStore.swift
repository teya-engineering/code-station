import Foundation
import Observation

struct CommandShortcut: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var command: String

    init(id: UUID = UUID(), name: String, command: String) {
        self.id = id
        self.name = name
        self.command = command
    }

    static let llama = CommandShortcut(
        id: UUID(uuidString: "7D204CF7-5DC0-4EDF-AE11-5442E04BA276")!,
        name: "Qwen 2.5 7B Instruct",
        command: "llama-server -m \"$HOME/models/qwen2.5-7b/Qwen2.5-7B-Instruct-Q4_K_M.gguf\" --host 0.0.0.0 --port 8092 -ngl 99 -c 32768 --jinja --alias qwen25"
    )
}

@MainActor
@Observable
final class ShortcutStore {
    enum State: Equatable {
        case stopped
        case running
        case finished
        case failed(String)

        var isActive: Bool { self == .running }
    }

    private struct Persisted: Codable {
        var shortcuts: [CommandShortcut]
    }

    private struct InvalidFile: LocalizedError {
        var errorDescription: String? {
            "Each shortcut needs a unique ID, a name, and a command."
        }
    }

    private(set) var shortcuts: [CommandShortcut] = [.llama]
    private(set) var states: [CommandShortcut.ID: State] = [:]
    private(set) var logs: [CommandShortcut.ID: String] = [:]
    private(set) var loadError: String?
    private(set) var saveError: String?

    let storageURL: URL
    private let files: PersistentFileClient
    @ObservationIgnored private var tasks: [CommandShortcut.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var runTokens: [CommandShortcut.ID: UUID] = [:]

    init(storageURL: URL? = nil, files: PersistentFileClient = .live) {
        self.storageURL = storageURL ?? AppPaths.supportFile("shortcuts.json")
        self.files = files
        load()
    }

    var runningCount: Int {
        shortcuts.count { state($0.id).isActive }
    }

    var failureCount: Int {
        shortcuts.count {
            if case .failed = state($0.id) { true } else { false }
        }
    }

    func state(_ id: CommandShortcut.ID) -> State {
        states[id] ?? .stopped
    }

    func log(_ id: CommandShortcut.ID) -> String {
        logs[id] ?? ""
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
            shortcuts = [.llama]
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
    func add(name: String, command: String) -> CommandShortcut.ID? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !command.isEmpty else { return nil }
        let shortcut = CommandShortcut(
            name: name,
            command: command
        )
        shortcuts.append(shortcut)
        save()
        return shortcut.id
    }

    func update(_ shortcut: CommandShortcut) {
        let name = shortcut.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = shortcut.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !command.isEmpty,
              !state(shortcut.id).isActive,
              let index = shortcuts.firstIndex(where: { $0.id == shortcut.id }) else { return }
        shortcuts[index] = CommandShortcut(
            id: shortcut.id,
            name: name,
            command: command
        )
        save()
    }

    func remove(_ id: CommandShortcut.ID) {
        stop(id)
        shortcuts.removeAll { $0.id == id }
        states[id] = nil
        logs[id] = nil
        runTokens[id] = nil
        save()
    }

    // MARK: - Running

    func start(_ id: CommandShortcut.ID) {
        guard !state(id).isActive,
              let shortcut = shortcuts.first(where: { $0.id == id }) else { return }

        let token = UUID()
        runTokens[id] = token
        logs[id] = ""
        states[id] = .running

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ProcessManager.searchPath
        let store = self
        let task = Task {
            do {
                let result = try await CommandRunner.run(
                    executable: "/bin/zsh",
                    arguments: ["-lc", shortcut.command],
                    currentDirectory: FileManager.default.homeDirectoryForCurrentUser,
                    environment: environment,
                    outputChunkHandler: { data in
                        Task { @MainActor in store.append(data, to: id, token: token) }
                    },
                    errorOutputChunkHandler: { data in
                        Task { @MainActor in store.append(data, to: id, token: token) }
                    },
                    timeout: nil
                )
                store.finished(id, token: token, status: result.status)
            } catch let error as CommandRunner.RunError {
                store.failed(id, token: token, error: error)
            } catch {
                store.failed(id, token: token, message: error.localizedDescription)
            }
        }
        tasks[id] = task
    }

    func stop(_ id: CommandShortcut.ID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        runTokens[id] = nil
        states[id] = .stopped
    }

    func stopAll() {
        for id in Array(tasks.keys) { stop(id) }
    }

    func clearLog(_ id: CommandShortcut.ID) {
        logs[id] = ""
    }

    // MARK: - Private

    private func finished(_ id: CommandShortcut.ID, token: UUID, status: Int32) {
        guard runTokens[id] == token else { return }
        tasks[id] = nil
        states[id] = status == 0
            ? .finished
            : .failed("Exited with code \(status). See output below.")
    }

    private func failed(_ id: CommandShortcut.ID, token: UUID, error: CommandRunner.RunError) {
        guard runTokens[id] == token else { return }
        tasks[id] = nil
        if error == .cancelled {
            states[id] = .stopped
        } else {
            states[id] = .failed(error.localizedDescription)
        }
    }

    private func failed(_ id: CommandShortcut.ID, token: UUID, message: String) {
        guard runTokens[id] == token else { return }
        tasks[id] = nil
        states[id] = .failed(message)
    }

    private func append(_ data: Data, to id: CommandShortcut.ID, token: UUID) {
        guard runTokens[id] == token else { return }
        var current = (logs[id] ?? "") + String(decoding: data, as: UTF8.self)
        if current.count > 20_000 { current = String(current.suffix(20_000)) }
        logs[id] = current
    }
}
