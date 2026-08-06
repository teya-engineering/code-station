import Foundation
import Observation

// The saved requests, kept as one JSON file next to the projects store.
@MainActor
@Observable
final class PostmanStore {
    private(set) var requests: [SavedRequest] = []
    var selectedID: UUID?

    let storeURL: URL

    var selected: SavedRequest? { requests.first { $0.id == selectedID } }

    init() {
        storeURL = ProcessInfo.processInfo.environment["CONDUCTOR_POSTMAN_STORE"]
            .map { URL(fileURLWithPath: $0) }
            ?? AppPaths.supportFile("postman.json", movedFrom: AppPaths.legacy("postman.json"))
        load()
    }

    // MARK: - Editing

    @discardableResult
    func add(_ request: SavedRequest = SavedRequest(name: "New request")) -> SavedRequest {
        requests.append(request)
        selectedID = request.id
        save()
        return request
    }

    func update(_ request: SavedRequest) {
        guard let i = requests.firstIndex(where: { $0.id == request.id }) else { return }
        guard requests[i] != request else { return }
        requests[i] = request
        scheduleSave()
    }

    func remove(_ id: UUID) {
        requests.removeAll { $0.id == id }
        if selectedID == id { selectedID = requests.first?.id }
        save()
    }

    func duplicate(_ id: UUID) {
        guard let source = requests.first(where: { $0.id == id }) else { return }
        var copy = source
        copy.id = UUID()
        copy.name = source.name + " copy"
        // Header ids have to be fresh too, or edits to the copy would land on both rows.
        copy.headers = source.headers.map { HeaderField(key: $0.key, value: $0.value, enabled: $0.enabled) }
        requests.append(copy)
        selectedID = copy.id
        save()
    }

    // MARK: - Persistence

    private var saveTask: Task<Void, Never>?

    // Editing a URL is one write per keystroke, so those are coalesced into one file
    // write the way the project store does it.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        saveTask?.cancel()
        saveTask = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(requests) else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL), !data.isEmpty,
              let saved = try? JSONDecoder().decode([SavedRequest].self, from: data) else {
            requests = Self.examples
            selectedID = requests.first?.id
            return
        }
        requests = saved
        selectedID = requests.first?.id
    }

    // An empty screen gives you nothing to copy, so a first run starts with the
    // orders dead letter endpoints already filled in.
    private static var examples: [SavedRequest] {
        let base = "https://api.{{env}}.example.com/orders-service/v1/internal/dlt"
        return [
            SavedRequest(name: "Fetch DLT messages from cache", method: .get, url: base + "/messages"),
            SavedRequest(name: "Start the DLT message consumer", method: .put, url: base + "/start"),
            SavedRequest(name: "Stop the DLT consumer", method: .post, url: base + "/stop")
        ]
    }
}
