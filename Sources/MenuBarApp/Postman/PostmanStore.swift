import Foundation
import Observation

// The saved requests, kept as one JSON file next to the projects store.
@MainActor
@Observable
final class PostmanStore {
    static let minimumResponseHeight: CGFloat = 120

    private(set) var requests: [SavedRequest] = []
    private(set) var folders: [RequestFolder] = []
    var selectedID: UUID?
    private var expandedFolderIDs: Set<UUID> = []

    // One height for the whole tool, so the pane keeps its size across requests.
    // It lives here rather than in the view, which is remade on every selection.
    var responseHeight: CGFloat = 230

    let storeURL: URL

    var selected: SavedRequest? { requests.first { $0.id == selectedID } }

    init(storeURL: URL? = nil) {
        self.storeURL = storeURL
            ?? ProcessInfo.processInfo.environment["CONDUCTOR_POSTMAN_STORE"]
                .map { URL(fileURLWithPath: $0) }
            ?? AppPaths.supportFile("postman.json", movedFrom: AppPaths.legacy("postman.json"))
        load()
    }

    // MARK: - Editing

    @discardableResult
    func add(_ request: SavedRequest = SavedRequest(name: "New request"),
             to folderID: UUID? = nil) -> SavedRequest {
        var request = request
        request.folderID = folderID.flatMap { id in folders.contains { $0.id == id } ? id : nil }
        requests.append(request)
        selectedID = request.id
        if let folderID = request.folderID { expandedFolderIDs.insert(folderID) }
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
        // Row ids have to be fresh too, or edits to the copy would land on both rows.
        let fresh = { (rows: [HeaderField]) in
            rows.map { HeaderField(key: $0.key, value: $0.value, enabled: $0.enabled) }
        }
        copy.headers = fresh(source.headers)
        copy.queryParams = fresh(source.queryParams)
        copy.pathParams = fresh(source.pathParams)
        requests.append(copy)
        selectedID = copy.id
        save()
    }

    @discardableResult
    func addFolder(named name: String = "New folder") -> RequestFolder {
        let folder = RequestFolder(name: name)
        folders.append(folder)
        expandedFolderIDs.insert(folder.id)
        save()
        return folder
    }

    func renameFolder(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = folders.firstIndex(where: { $0.id == id }) else { return }
        guard folders[index].name != name else { return }
        folders[index].name = name
        scheduleSave()
    }

    func removeFolder(_ id: UUID) {
        guard folders.contains(where: { $0.id == id }) else { return }
        folders.removeAll { $0.id == id }
        requests = requests.map { request in
            guard request.folderID == id else { return request }
            var request = request
            request.folderID = nil
            return request
        }
        expandedFolderIDs.remove(id)
        save()
    }

    func move(_ requestID: UUID, to folderID: UUID?) {
        guard let index = requests.firstIndex(where: { $0.id == requestID }) else { return }
        guard folderID == nil || folders.contains(where: { $0.id == folderID }) else { return }
        guard requests[index].folderID != folderID else { return }
        requests[index].folderID = folderID
        if let folderID { expandedFolderIDs.insert(folderID) }
        save()
    }

    func requests(in folderID: UUID?) -> [SavedRequest] {
        requests.filter { $0.folderID == folderID }
    }

    func requestCount(in folderID: UUID) -> Int {
        requests(in: folderID).count
    }

    func isExpanded(_ folderID: UUID) -> Bool {
        expandedFolderIDs.contains(folderID)
    }

    func toggleFolder(_ folderID: UUID) {
        guard folders.contains(where: { $0.id == folderID }) else { return }
        if expandedFolderIDs.contains(folderID) {
            expandedFolderIDs.remove(folderID)
        } else {
            expandedFolderIDs.insert(folderID)
        }
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
        guard let data = try? encoder.encode(SavedRequestCollection(folders: folders,
                                                                      requests: requests)) else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL), !data.isEmpty else {
            requests = Self.examples
            selectedID = requests.first?.id
            return
        }

        let decoder = JSONDecoder()
        if let saved = try? decoder.decode(SavedRequestCollection.self, from: data) {
            folders = saved.folders
            requests = saved.requests
        } else if let saved = try? decoder.decode([SavedRequest].self, from: data) {
            folders = []
            requests = saved
        } else {
            requests = Self.examples
            selectedID = requests.first?.id
            return
        }

        let folderIDs = Set(folders.map(\.id))
        requests = requests.map { request in
            guard let folderID = request.folderID, !folderIDs.contains(folderID) else { return request }
            var request = request
            request.folderID = nil
            return request
        }
        expandedFolderIDs = folderIDs
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
