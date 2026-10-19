import CoreServices
import Foundation
import Observation

// Which folders hold work that git does not have yet. Sessions edit real files, either
// in the project folder or in a worktree of their own, and deleting a session takes its
// worktree with it, so the sidebar has to be able to say "there is something here to
// lose" without the session being opened.
//
// The answers are kept here rather than read where they are drawn: a row redraws far too
// often to run git, and git is far too slow to run on the main thread.
//
// Most trees in the sidebar sit untouched for hours, so git only runs again for a tree
// the file system says has changed. A linked worktree keeps its index and HEAD in the
// main repository's git folder, outside the tree, so that folder is watched as well, or
// a commit made in a terminal would go unseen. Events can still go missing, so a tree is
// also read again whenever its watch starts over, and whenever an agent ends a turn in it,
// since that is when agents commit.
@MainActor
@Observable
public final class WorkingTreeWatch {
    // How often callers ask. Asking is cheap: only a tree that changed is read again.
    public static let interval: Duration = .seconds(30)
    // The file system can drop events under load, so a tree is read again after this long
    // even when nothing was reported for it.
    static let recheckAfter: Duration = .seconds(600)
    // A tree that no caller has asked about for this long stops being watched.
    static let forgetAfter: Duration = .seconds(120)

    public typealias Inspector = @Sendable (String) async -> Int

    private struct WatchedTree {
        // Where the file system reports changes, which is not always the path we were
        // given: a temporary folder under /var is really under /private/var.
        let realPaths: [String]
        var lastRequested: ContinuousClock.Instant
        var lastInspected: ContinuousClock.Instant?
        var changed = true
    }

    private var uncommittedFiles: [String: Int] = [:]
    private var inspected: Set<String> = []
    @ObservationIgnored private var running: Set<String> = []
    @ObservationIgnored private var trees: [String: WatchedTree] = [:]
    @ObservationIgnored private var events: FileEvents?
    @ObservationIgnored private let inspect: Inspector

    public init(inspect: @escaping Inspector = { await GitInspector.uncommittedFileCount(at: $0) }) {
        self.inspect = inspect
    }

    public func isDirty(_ path: String) -> Bool {
        uncommittedFileCount(at: path) > 0
    }

    public func uncommittedFileCount(at path: String) -> Int {
        uncommittedFiles[Self.normalized(path)] ?? 0
    }

    public func hasInspected(_ path: String) -> Bool {
        inspected.contains(Self.normalized(path))
    }

    public func refresh(_ paths: some Collection<String>) {
        let now = ContinuousClock.now
        let requested = Set(paths.map(Self.normalized))

        var watchedPathsChanged = false
        for path in requested {
            if trees[path] == nil {
                trees[path] = WatchedTree(realPaths: Self.realPaths(of: path), lastRequested: now)
                watchedPathsChanged = true
            } else {
                trees[path]?.lastRequested = now
            }
        }
        let forgotten = trees.filter { now - $0.value.lastRequested > Self.forgetAfter }.keys
        for path in forgotten { trees.removeValue(forKey: path) }
        if watchedPathsChanged || !forgotten.isEmpty { restartEvents() }

        let pending = requested.filter { path in
            guard !running.contains(path), let tree = trees[path] else { return false }
            let due = tree.changed
                || tree.lastInspected.map { now - $0 > Self.recheckAfter } ?? true
            guard due else { return false }
            running.insert(path)
            // Cleared before git runs, so a change made while it runs marks the tree again.
            trees[path]?.changed = false
            return true
        }
        guard !pending.isEmpty else { return }

        Task {
            for path in pending {
                let result = await inspect(path)
                running.remove(path)
                inspected.insert(path)
                trees[path]?.lastInspected = .now
                if result > 0 {
                    if uncommittedFiles[path] != result { uncommittedFiles[path] = result }
                } else if uncommittedFiles[path] != nil {
                    uncommittedFiles.removeValue(forKey: path)
                }
            }
        }
    }

    // An answer git already gave elsewhere, such as an open session's full snapshot, so
    // the same tree is not asked about twice. Only a count that changes is written.
    public func record(_ count: Int, at path: String) {
        let path = Self.normalized(path)
        if !inspected.contains(path) { inspected.insert(path) }
        if count > 0 {
            if uncommittedFiles[path] != count { uncommittedFiles[path] = count }
        } else if uncommittedFiles[path] != nil {
            uncommittedFiles.removeValue(forKey: path)
        }
    }

    // Reads the trees again now rather than on the next pass. Only trees a caller already
    // asked about are read: the rest have nothing on screen to update.
    public func noteChanged(_ paths: some Collection<String>) {
        let watched = paths.map(Self.normalized).filter { trees[$0] != nil }
        for path in watched { trees[path]?.changed = true }
        if !watched.isEmpty { refresh(watched) }
    }

    private func restartEvents() {
        events = nil
        // A stream drops the events it has not handed over yet when it is released, and
        // the new one only sees what happens after it starts.
        for path in trees.keys { trees[path]?.changed = true }
        let paths = trees.values.flatMap(\.realPaths)
        guard !paths.isEmpty else { return }
        events = FileEvents(paths: paths) { [weak self] changed, rescan in
            self?.noticeChanges(changed, rescan: rescan)
        }
    }

    private func noticeChanges(_ changed: [String], rescan: Bool) {
        for (path, tree) in trees {
            let touched = rescan || changed.contains { changedPath in
                tree.realPaths.contains { changedPath == $0 || changedPath.hasPrefix($0 + "/") }
            }
            if touched { trees[path]?.changed = true }
        }
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    // The tree itself and, for a linked worktree, its own folder inside the main
    // repository's .git, which the tree's .git file points at.
    private static func realPaths(of path: String) -> [String] {
        let root = realPath(path)
        var paths = [root]
        let pointer = URL(fileURLWithPath: root).appendingPathComponent(".git")
        if let text = try? String(contentsOf: pointer, encoding: .utf8),
           text.hasPrefix("gitdir:") {
            let target = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            let gitDir = target.hasPrefix("/")
                ? URL(fileURLWithPath: target)
                : URL(fileURLWithPath: root).appendingPathComponent(target)
            paths.append(realPath(gitDir.standardizedFileURL.path))
        }
        return paths
    }

    // realpath rather than URL.resolvingSymlinksInPath, which turns /private/var back into
    // /var and so would never match the paths the file system reports.
    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

// One FSEvents stream over a set of folders, delivered on the main queue. It stops when
// released. The stream only ever calls back on the main queue, which is what makes
// handing it across in the C callback safe.
private final class FileEvents: @unchecked Sendable {
    typealias Handler = @MainActor (_ changed: [String], _ rescan: Bool) -> Void

    private var stream: FSEventStreamRef?
    private let handler: Handler

    init(paths: [String], handler: @escaping Handler) {
        self.handler = handler
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let events = Unmanaged<FileEvents>.fromOpaque(info).takeUnretainedValue()
            let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
            // Dropped or coalesced events, or a watched folder that moved or went away,
            // say nothing reliable about which tree changed, so every tree is read again.
            let rescanFlags = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs
                    | kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped
                    | kFSEventStreamEventFlagRootChanged)
            let rescan = UnsafeBufferPointer(start: eventFlags, count: count)
                .contains { $0 & rescanFlags != 0 }
            MainActor.assumeIsolated { events.handler(paths, rescan) }
        }
        stream = FSEventStreamCreate(
            nil, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot))
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
