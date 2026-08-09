import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct ShortcutStoreTests {
    @Test func startsWithTheLlamaShortcutWhenNoFileExists() {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ShortcutStore(storageURL: url)

        #expect(store.shortcuts == [.llama])
        #expect(store.shortcuts[0].command.contains("llama-server"))
        #expect(store.shortcuts[0].command.contains("--alias qwen25"))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func persistsAddsEditsAndRemovalOfTheDefault() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ShortcutStore(storageURL: url)

        let id = try #require(store.add(
            name: "  API server  ", command: "  ./gradlew bootRun  "))
        store.update(CommandShortcut(id: id, name: "Service", command: "./gradlew run"))
        store.remove(CommandShortcut.llama.id)

        let reloaded = ShortcutStore(storageURL: url)
        #expect(reloaded.shortcuts == [
            CommandShortcut(id: id, name: "Service", command: "./gradlew run")
        ])

        reloaded.remove(id)
        #expect(ShortcutStore(storageURL: url).shortcuts.isEmpty)
    }

    @Test func refusesToOverwriteAnUnreadableFile() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("not json".utf8)
        try original.write(to: url)

        let store = ShortcutStore(storageURL: url)
        #expect(store.loadError != nil)

        store.add(name: "Build", command: "swift build")

        #expect(store.saveError != nil)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func runsACommandAndCapturesBothOutputStreams() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ShortcutStore(storageURL: url)
        let id = try #require(store.add(
            name: "Output",
            command: "printf 'standard output'; printf 'error output' >&2"
        ))

        store.start(id)
        for _ in 0..<200 where store.state(id).isActive {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(store.state(id) == .finished)
        #expect(store.log(id).contains("standard output"))
        #expect(store.log(id).contains("error output"))
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcut-store-tests-\(UUID().uuidString)")
            .appendingPathComponent("shortcuts.json")
    }
}
