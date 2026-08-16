import Foundation
import Observation

// The saved requests, kept as one JSON file next to the projects store.
@MainActor
@Observable
final class DispatchStore {
    static let minimumResponseHeight: CGFloat = 120

    private(set) var requests: [SavedRequest] = []
    private(set) var folders: [RequestFolder] = []
    var selectedID: UUID?
    private var expandedFolderIDs: Set<UUID> = []

    // One height for the whole tool, so the pane keeps its size across requests.
    // It lives here rather than in the view, which is remade on every selection.
    var responseHeight: CGFloat = 230

    let storeURL: URL
    private(set) var loadError: String?
    private(set) var saveError: String?

    var selected: SavedRequest? { requests.first { $0.id == selectedID } }

    init(storeURL: URL? = nil) {
        self.storeURL = storeURL ?? Self.defaultStoreURL()
        load()
    }

    func applySiteDefaults(_ defaults: SiteDefaults) {
        guard !FileManager.default.fileExists(atPath: storeURL.path) else { return }
        folders = [.default]
        requests = defaults.dispatchRequests.map { request in
            var request = request
            request.folderID = RequestFolder.defaultID
            return request
        }
    }

    private static func defaultStoreURL() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["CONDUCTOR_DISPATCH_STORE"]
            ?? environment["CONDUCTOR_POSTMAN_STORE"] {
            return URL(fileURLWithPath: path)
        }
        return AppPaths.supportFile("dispatch.json", moving: [
            AppPaths.support.appendingPathComponent("postman.json"),
            AppPaths.legacy("dispatch.json"),
            AppPaths.legacy("postman.json")
        ])
    }

    // MARK: - Editing

    @discardableResult
    func add(_ request: SavedRequest = SavedRequest(name: "New request"),
             to folderID: UUID? = nil) -> SavedRequest {
        var request = request
        let folderID = validFolderID(folderID)
        request.folderID = folderID
        requests.append(request)
        selectedID = request.id
        expandedFolderIDs.insert(folderID)
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
        if selectedID == id { selectedID = nil }
        save()
    }

    // Answers with the copy's id, since a request's password is not kept here and the
    // caller has to carry it over itself.
    @discardableResult
    func duplicate(_ id: UUID) -> UUID? {
        guard let source = requests.first(where: { $0.id == id }) else { return nil }
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
        return copy.id
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
        guard id != RequestFolder.defaultID,
              !name.isEmpty,
              let index = folders.firstIndex(where: { $0.id == id }) else { return }
        guard folders[index].name != name else { return }
        folders[index].name = name
        scheduleSave()
    }

    func removeFolder(_ id: UUID) {
        guard id != RequestFolder.defaultID,
              folders.contains(where: { $0.id == id }) else { return }
        let hadRequests = requests.contains { $0.folderID == id }
        folders.removeAll { $0.id == id }
        requests = requests.map { request in
            guard request.folderID == id else { return request }
            var request = request
            request.folderID = RequestFolder.defaultID
            return request
        }
        // The rescued requests land in Default, so open it rather than let them look lost.
        if hadRequests {
            expandedFolderIDs.insert(RequestFolder.defaultID)
        }
        expandedFolderIDs.remove(id)
        save()
    }

    func move(_ requestID: UUID, to folderID: UUID?) {
        guard let index = requests.firstIndex(where: { $0.id == requestID }) else { return }
        let folderID = validFolderID(folderID)
        guard requests[index].folderID != folderID else { return }
        requests[index].folderID = folderID
        expandedFolderIDs.insert(folderID)
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
        scheduleSave()
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

    @discardableResult
    func save() -> Bool {
        saveTask?.cancel()
        saveTask = nil
        guard loadError == nil else {
            saveError = "Changes were not saved because the existing request file could not be loaded."
            return false
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            // Written in folder order rather than set order, so a save that changes
            // nothing writes the same bytes every time.
            let openFolderIDs = folders.map(\.id).filter(expandedFolderIDs.contains)
            let data = try encoder.encode(SavedRequestCollection(folders: folders,
                                                                  requests: requests,
                                                                  expandedFolderIDs: openFolderIDs))
            try PersistentFile.write(data, to: storeURL)
            saveError = nil
            return true
        } catch {
            saveError = PersistentFile.saveMessage(for: storeURL, error: error)
            return false
        }
    }

    private func load() {
        let data: Data?
        do {
            data = try PersistentFile.readIfPresent(storeURL)
        } catch {
            loadError = PersistentFile.loadMessage(for: storeURL, error: error)
            folders = [.default]
            requests = []
            return
        }

        guard let data else {
            loadError = nil
            folders = [.default]
            requests = Self.examples.map { request in
                var request = request
                request.folderID = RequestFolder.defaultID
                return request
            }
            return
        }

        let decoder = JSONDecoder()
        var openFolderIDs: [UUID] = []
        if let saved = try? decoder.decode(SavedRequestCollection.self, from: data) {
            folders = saved.folders
            requests = saved.requests
            openFolderIDs = saved.expandedFolderIDs
        } else if let saved = try? decoder.decode([SavedRequest].self, from: data) {
            folders = []
            requests = saved
        } else {
            loadError = "The request file at \(storeURL.path) could not be parsed. Fix or remove it before saving changes."
            folders = [.default]
            requests = []
            return
        }
        loadError = nil

        if !folders.contains(where: \.isDefault) {
            folders.insert(.default, at: 0)
        }
        let folderIDs = Set(folders.map(\.id))
        requests = requests.map { request in
            guard let folderID = request.folderID, folderIDs.contains(folderID) else {
                var request = request
                request.folderID = RequestFolder.defaultID
                return request
            }
            return request
        }
        // Folders open closed. Only the ones the user left open come back open, and a
        // folder that has since been deleted is dropped.
        expandedFolderIDs = Set(openFolderIDs).intersection(folderIDs)
    }

    private func validFolderID(_ folderID: UUID?) -> UUID {
        guard let folderID, folders.contains(where: { $0.id == folderID }) else {
            return RequestFolder.defaultID
        }
        return folderID
    }

    // An empty screen gives you nothing to copy, so a first run starts with whatever
    // calls the site file lists.
    private static var examples: [SavedRequest] { SiteDefaults.current.dispatchRequests }
}
