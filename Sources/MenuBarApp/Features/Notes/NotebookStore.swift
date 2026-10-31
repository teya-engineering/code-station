import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class NotebookStore {
    private struct Archive: Codable {
        var version = 1
        var notes: [QuickNote]
        var selectedID: UUID?
    }

    private(set) var notes: [QuickNote] = []
    private(set) var selectedID: UUID?
    private(set) var loadError: String?
    private(set) var saveError: String?
    private(set) var saving = false
    private(set) var savedCount = 0
    let directory: URL
    @ObservationIgnored private let files: PersistentFileClient
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var dirty = false

    var storageURL: URL { directory.appendingPathComponent("notebook.json") }

    init(directory: URL? = nil, files: PersistentFileClient = .live) {
        self.directory = directory ?? AppPaths.support.appendingPathComponent("notebook")
        self.files = files
        do {
            if let data = try files.readIfPresent(storageURL) {
                let archive = try PersistentFile.makeDecoder(dates: .deferredToDate).decode(Archive.self, from: data)
                guard archive.version == 1, Set(archive.notes.map(\.id)).count == archive.notes.count else {
                    throw NotebookError("This notebook format cannot be read by this version of Code Station.")
                }
                notes = archive.notes
                selectedID = archive.selectedID
                savedCount = notes.count
            }
        } catch { loadError = PersistentFile.loadMessage(for: storageURL, error: error) }
    }

    func note(_ id: UUID?) -> QuickNote? { notes.first { $0.id == id } }

    func matching(_ query: String = "", pinnedOnly: Bool = false) -> [QuickNote] {
        notes.filter { (!pinnedOnly || $0.pinned) && $0.matches(query) }.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            if $0.editedAt != $1.editedAt { return $0.editedAt > $1.editedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    @discardableResult func create() -> UUID? {
        guard loadError == nil else { return nil }
        let note = QuickNote()
        notes.insert(note, at: 0)
        selectedID = note.id
        scheduleSave()
        return note.id
    }

    func select(_ id: UUID) {
        guard note(id) != nil, selectedID != id else { return }
        selectedID = id
        scheduleSave()
    }

    func update(_ id: UUID, _ change: (inout QuickNote) -> Void) {
        guard loadError == nil, let index = notes.firstIndex(where: { $0.id == id }) else { return }
        change(&notes[index])
        notes[index].editedAt = .now
        scheduleSave()
    }

    func togglePin(_ id: UUID) {
        guard loadError == nil, let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].pinned.toggle()
        scheduleSave()
    }

    @discardableResult func duplicate(_ id: UUID) -> UUID? {
        guard loadError == nil, var copy = note(id) else { return nil }
        copy.id = UUID()
        copy.title = copy.displayTitle + " (copy)"
        copy.pinned = false
        copy.createdAt = .now
        copy.editedAt = .now
        // Attachments are immutable, so copies can safely share their stored bytes.
        notes.insert(copy, at: 0)
        selectedID = copy.id
        scheduleSave()
        return copy.id
    }

    func attachmentURL(_ attachment: NoteAttachment) -> URL {
        directory.appendingPathComponent("attachments").appendingPathComponent(attachment.id.uuidString)
    }

    func attach(_ source: URL, to id: UUID) async throws {
        guard loadError == nil, note(id) != nil else { throw NotebookError("The note is not available.") }
        let destination = directory.appendingPathComponent("attachments")
        let attachment = try await Task.detached(priority: .userInitiated) {
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw NotebookError("Choose a file, rather than a folder.") }
            var attachment = NoteAttachment(name: source.lastPathComponent,
                                            byteCount: Int64(values.fileSize ?? 0),
                                            image: UTType(filenameExtension: source.pathExtension)?.conforms(to: .image) == true)
            attachment.name = attachment.name.isEmpty ? "Attachment" : attachment.name
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let copy = destination.appendingPathComponent(attachment.id.uuidString)
            do { try FileManager.default.copyItem(at: source, to: copy) }
            catch { try? FileManager.default.removeItem(at: copy); throw error }
            return attachment
        }.value
        update(id) { $0.attachments.append(attachment) }
        _ = flush()
    }

    func attachImage(_ data: Data, to id: UUID) async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("Pasted image.png")
        try data.write(to: source)
        try await attach(source, to: id)
    }

    private func scheduleSave() {
        dirty = true
        saving = true
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            _ = self?.flush()
        }
    }

    @discardableResult func flush() -> Bool {
        pendingSave?.cancel()
        pendingSave = nil
        saving = false
        guard loadError == nil else { return false }
        guard dirty else { return saveError == nil }
        do {
            let data = try PersistentFile.makeEncoder(dates: .deferredToDate).encode(Archive(notes: notes, selectedID: selectedID))
            try files.write(data, storageURL)
            savedCount = notes.count
            saveError = nil
            dirty = false
            return true
        } catch {
            saveError = PersistentFile.saveMessage(for: storageURL, error: error)
            return false
        }
    }
}

struct NotebookError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
