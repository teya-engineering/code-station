import CryptoKit
import Foundation
import Observation

// A changed file the reviewer has ticked off as read. The tick is on one version of the
// file's content, so it lasts while that content does: the agent editing the file again
// makes a new version, and the file asks to be looked at once more.

enum ViewedState: Equatable {
    case notViewed
    case viewed
    // An earlier version was ticked off, at this time, and the agent has changed it since.
    case edited(since: Date)

    var isViewed: Bool { self == .viewed }

    var isEdited: Bool {
        if case .edited = self { return true }
        return false
    }

    // What a screen reader says after the file's name.
    var spoken: String {
        switch self {
        case .notViewed: "Not viewed"
        case .viewed: "Viewed"
        case .edited: "Edited since you viewed it"
        }
    }
}

enum FileVersion {
    // A deleted file has no content, and stays the same deletion until it comes back.
    static let deleted = "deleted"
    // Past this a file is named by its size and age instead of read whole on every refresh.
    static let readLimit = 32 << 20

    // Git's own id for the content, so a version seen on disk is the same version as the
    // blob a later commit stores, and a file committed as it was read is still read.
    static func blobID(_ data: Data) -> String {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(data.count)\0".utf8))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // What each changed file holds on disk now, keyed by its path.
    static func onDisk(_ files: [GitChange], root: String) async -> [String: String] {
        let rootURL = URL(fileURLWithPath: root)
        return await GitInspector.offMain {
            var versions: [String: String] = [:]
            for file in files {
                versions[file.path] = version(of: file, in: rootURL)
            }
            return versions
        }
    }

    private static func version(of file: GitChange, in root: URL) -> String {
        guard file.kind != .deleted else { return deleted }
        let url = root.appendingPathComponent(file.path)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return deleted
        }
        let size = values.fileSize ?? 0
        if size > readLimit {
            let age = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            return "large:\(size):\(Int(age))"
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return deleted }
        return blobID(data)
    }

    // The text of a version read from disk now, for finding the lines added after it was
    // viewed. Nil for anything that is not plain text or is too big to keep.
    static func text(at path: String, root: String) async -> (version: String, text: String)? {
        let url = URL(fileURLWithPath: root).appendingPathComponent(path)
        return await GitInspector.offMain(lane: .interactive) {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  data.count <= ViewedFileStore.textLimit,
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return (blobID(data), text)
        }
    }
}

enum ViewedLines {
    // Past this many lines the comparison is skipped rather than made to wait on.
    static let limit = 40_000

    // The lines of the current text, numbered from 1, that were not in the text viewed.
    static func added(since viewed: String, in current: String) -> Set<Int> {
        let before = viewed.components(separatedBy: "\n")
        let after = current.components(separatedBy: "\n")
        guard before.count + after.count <= limit else { return [] }
        var added = Set<Int>()
        for change in after.difference(from: before) {
            if case .insert(let offset, _, _) = change { added.insert(offset + 1) }
        }
        return added
    }

    // The lines of the version the diff compares with that the text viewed still held and
    // the current text has lost, numbered as the diff numbers its removed lines. A line
    // already gone when the file was viewed was read as removed, so it is left out.
    static func removed(since viewed: String, in current: String, base: String) -> Set<Int> {
        let original = base.components(separatedBy: "\n")
        let before = viewed.components(separatedBy: "\n")
        let after = current.components(separatedBy: "\n")
        guard original.count + before.count <= limit, original.count + after.count <= limit else { return [] }
        return removals(after.difference(from: original)).subtracting(removals(before.difference(from: original)))
    }

    private static func removals(_ difference: CollectionDifference<String>) -> Set<Int> {
        var removed = Set<Int>()
        for change in difference {
            if case .remove(let offset, _, _) = change { removed.insert(offset + 1) }
        }
        return removed
    }

    // The keys of the diff's lines that changed after the version viewed: added lines by
    // their new number, removed ones by their old. That is how the diff views name a line.
    static func freshKeys(added: Set<Int>, removed: Set<Int> = [], in lines: [DiffLine]) -> Set<String> {
        guard !added.isEmpty || !removed.isEmpty else { return [] }
        let kinds = Dictionary(lines.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
        return Set(NumberedDiffLine.lines(lines)
            .filter { line in
                switch (line.side, kinds[line.id]) {
                case (.new, .addition): added.contains(line.number)
                case (.old, .deletion): removed.contains(line.number)
                default: false
                }
            }
            .map { DiffComments.key($0.anchor) })
    }
}

struct ViewedMark: Codable, Equatable, Sendable {
    var version: String
    var at: Date
}

// How far through the changed files the reviewer is, for the progress ring and the
// line in the turn's footer.
struct ViewedTally: Equatable {
    var viewed: Int
    var total: Int
    // The files of one commit, which the footer says so it is not read as the whole change.
    var inCommit = false

    var left: Int { total - viewed }
    var isDone: Bool { total > 0 && viewed == total }
    var label: String { isDone ? "All \(total) viewed" : "\(viewed) of \(total) viewed" }
    var footnote: String {
        let place = inCommit ? " in this commit" : ""
        return left == 0 ? "All \(counted(total, "file"))\(place) viewed" : "\(counted(left, "file"))\(place) not viewed yet"
    }
}

// Every session's viewed files. Kept on disk with the review, so a file ticked off before
// quitting is still ticked off after. The text of each version viewed is kept beside it,
// so the lines the agent adds later can be picked out.
@MainActor
@Observable
final class ViewedFileStore {
    // A file whose text is bigger than this is still ticked off, but its new lines are not
    // picked out, so a generated file cannot fill the disk.
    nonisolated static let textLimit = 1 << 20
    // The versions remembered for one file. A file read in a few commits and then on disk
    // keeps each of them, so reading an old commit does not untick the newest.
    static let keptVersions = 8

    private(set) var loadError: String?
    private(set) var saveError: String?
    // Session, then file (git root, a slash and the path), then the versions ticked off,
    // oldest first.
    private var marks: [UUID: [String: [ViewedMark]]] = [:]
    @ObservationIgnored private let url: URL?
    @ObservationIgnored private let textsURL: URL?
    @ObservationIgnored private let files: PersistentFileClient
    @ObservationIgnored private var texts: [String: String] = [:]
    @ObservationIgnored private var saver: DebouncedSaver?

    init(url: URL?, files: PersistentFileClient = .live) {
        self.url = url
        self.files = files
        textsURL = url.map { $0.deletingPathExtension().appendingPathExtension("texts") }
        if let url {
            do {
                if let data = try files.readIfPresent(url) {
                    marks = try PersistentFile.makeDecoder().decode([UUID: [String: [ViewedMark]]].self, from: data)
                }
            } catch let error as DecodingError {
                loadError = PersistentFile.decodeMessage(for: url, error: error)
            } catch {
                loadError = PersistentFile.loadMessage(for: url, error: error)
            }
        }
        saver = DebouncedSaver { [weak self] in self?.save() }
    }

    // The same key the file's comments are kept under: its git root, a slash and the path.
    static func key(root: String, path: String) -> String { root + "/" + path }

    func state(_ key: String, version: String?, in session: UUID) -> ViewedState {
        guard let version, let list = marks[session]?[key], let last = list.last else { return .notViewed }
        return list.contains { $0.version == version } ? .viewed : .edited(since: last.at)
    }

    // The newest version ticked off, which new lines are measured from.
    func latest(_ key: String, in session: UUID) -> ViewedMark? { marks[session]?[key]?.last }

    func hasMarks(_ session: UUID) -> Bool { !(marks[session]?.isEmpty ?? true) }

    // Every tick in a session, to put back if clearing them was a slip.
    func marks(in session: UUID) -> [String: [ViewedMark]] { marks[session] ?? [:] }

    func restore(_ restored: [String: [ViewedMark]], in session: UUID) {
        marks[session] = restored.isEmpty ? nil : restored
        changed()
    }

    func mark(_ key: String, version: String, text: String? = nil, in session: UUID, at date: Date = Date()) {
        var list = marks[session]?[key] ?? []
        list.removeAll { $0.version == version }
        list.append(ViewedMark(version: version, at: date))
        if list.count > Self.keptVersions { list.removeFirst(list.count - Self.keptVersions) }
        marks[session, default: [:]][key] = list
        if let text, text.utf8.count <= Self.textLimit { keepText(text, for: version) }
        changed()
    }

    func unmark(_ key: String, version: String, in session: UUID) {
        guard var list = marks[session]?[key] else { return }
        list.removeAll { $0.version == version }
        marks[session]?[key] = list.isEmpty ? nil : list
        if marks[session]?.isEmpty == true { marks[session] = nil }
        changed()
    }

    func clear(_ session: UUID) {
        guard marks[session] != nil else { return }
        marks[session] = nil
        changed()
    }

    // The session is gone, so are its ticks.
    func remove(_ session: UUID) { clear(session) }

    // The text of a version viewed, if it was kept.
    func text(of version: String) -> String? {
        if let text = texts[version] { return text }
        guard let location = textLocation(version),
              let data = try? files.readIfPresent(location),
              let text = String(data: data, encoding: .utf8) else { return nil }
        texts[version] = text
        return text
    }

    @discardableResult
    func flush() -> Bool {
        if saver?.isPending == true { saver?.flush() }
        else if saveError != nil { save() }
        return loadError == nil && saveError == nil
    }

    private func textLocation(_ version: String) -> URL? {
        // Only a blob id names a file; anything else is not a name to put on disk.
        guard version.count == 40, version.allSatisfy(\.isHexDigit) else { return nil }
        return textsURL?.appendingPathComponent(version)
    }

    // Keeps the text of a version already ticked off. The text is read after the tick, so
    // the click answers at once; one that arrives after the tick was taken back is dropped.
    func keep(_ text: String, for version: String) {
        let ticked = marks.values.contains { $0.values.contains { $0.contains { $0.version == version } } }
        guard ticked, text.utf8.count <= Self.textLimit else { return }
        keepText(text, for: version)
    }

    private func keepText(_ text: String, for version: String) {
        texts[version] = text
        guard let location = textLocation(version) else { return }
        try? files.write(Data(text.utf8), location)
    }

    private func changed() {
        prune()
        saver?.schedule()
    }

    // Drops the kept texts of versions no session remembers any more.
    private func prune() {
        let kept = Set(marks.values.flatMap { $0.values.flatMap { $0.map(\.version) } })
        for version in texts.keys where !kept.contains(version) {
            texts[version] = nil
            if let location = textLocation(version) { try? files.removeIfPresent(location) }
        }
        guard let textsURL,
              let stored = try? FileManager.default.contentsOfDirectory(atPath: textsURL.path) else { return }
        for name in stored where !kept.contains(name) {
            try? files.removeIfPresent(textsURL.appendingPathComponent(name))
        }
    }

    private func save() {
        guard let url else { return }
        guard loadError == nil else {
            saveError = "Viewed files were not saved because the existing file could not be loaded."
            return
        }
        do {
            if marks.isEmpty { try files.removeIfPresent(url) }
            else { try files.write(PersistentFile.makeEncoder().encode(marks), url) }
            saveError = nil
        } catch {
            saveError = "Viewed files could not be saved: \(error.localizedDescription)"
            SessionLog.note("could not save viewed files: \(error.localizedDescription)")
        }
    }
}
