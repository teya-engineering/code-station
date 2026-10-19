import Foundation

// A session's changes kept live, and what the Changes screen does with them: commit
// every change or a chosen set of files with a message, and discard a file's changes.
// The commands address one checkout of the session by its path, as `RemoteCheckout`
// names it, and files by the paths the changes list shows; both are checked against what
// git says now, so a stale list cannot reach a folder the session does not work in, or
// a file that is no longer changed.
extension StationCommands {
    // MARK: - Live changes

    // The session's changes now, then again each time git answers differently: the agent
    // edited a file, or a commit or discard went through. Git is asked every
    // `changesRefreshInterval`, and at once after a commit or discard made here. An
    // unchanged answer is never sent twice in a row. The stream ends when the session goes
    // away or the reader stops iterating.
    public func changesUpdates(_ sessionID: String) -> AsyncStream<RemoteChanges> {
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteChanges.self,
                                                            bufferingPolicy: .bufferingNewest(1))
        let watch = ChangesWatch(continuation: continuation)
        changesWatches[ObjectIdentifier(watch)] = watch
        watch.reader = Task { @MainActor [weak self, weak watch] in
            while !Task.isCancelled {
                guard let self, let watch, !watch.stopped else { return }
                let forced = watch.nudged
                watch.nudged = false
                guard let id = UUID(uuidString: sessionID), let session = self.store.session(id) else {
                    watch.stop()
                    return
                }
                // One cheap look at each tree first; the diffs are read only when it moved.
                let look = await StationTreeLook.take(self.changesCheckouts(of: session).map(\.path))
                if forced || look != watch.look {
                    guard let changes = await self.readChanges(sessionID) else {
                        watch.stop()
                        return
                    }
                    watch.look = look
                    watch.send(changes)
                }
                // A commit made while git was being asked is read again straight away.
                guard !watch.nudged else { continue }
                let nap = Task<Void, Never> { [interval = self.changesRefreshInterval] in
                    try? await Task.sleep(for: interval)
                }
                watch.nap = nap
                await nap.value
            }
        }
        continuation.onTermination = { _ in
            Task { @MainActor [weak self] in
                watch.stop()
                self?.changesWatches[ObjectIdentifier(watch)] = nil
            }
        }
        return stream
    }

    // Every live changes subscription asks git again now.
    func nudgeChangesWatches() {
        for watch in changesWatches.values { watch.nudge() }
    }

    // MARK: - Commit

    // Commits in one checkout of the session, with `message`: every change there when
    // `paths` is nil, as the GUI's commit with every file ticked, or only the files named,
    // leaving the rest of the tree alone, index included.
    public func commitChanges(_ sessionID: String, checkout: String, message: String,
                              paths: [String]?) async throws(StationRefusal) {
        let text = message.trimmed
        guard !text.isEmpty else { throw StationRefusal("Write a commit message first.") }
        let snapshot = try await changedTree(sessionID, checkout: checkout)
        guard !snapshot.files.isEmpty else { throw StationRefusal("There is nothing to commit.") }
        let error: String?
        if let paths {
            let files = try chosen(paths, in: snapshot)
            error = await GitActions.commitSelected(message: text, files: files, at: snapshot.root)
        } else {
            error = await GitActions.commitAll(message: text, at: snapshot.root)
        }
        nudgeChangesWatches()
        if let error { throw StationRefusal(error.trimmed) }
    }

    // MARK: - Discard

    // Throws away the uncommitted work in the files named, in one checkout of the
    // session: a tracked file goes back to the last commit, and one git has never seen is
    // moved to the Trash. Nothing on the screen can undo it, so a front end asks first.
    public func discardChanges(_ sessionID: String, checkout: String,
                               paths: [String]) async throws(StationRefusal) {
        let snapshot = try await changedTree(sessionID, checkout: checkout)
        let files = try chosen(paths, in: snapshot)
        let error = await GitActions.discard(files, at: snapshot.root, trash: trash)
        nudgeChangesWatches()
        if let error { throw StationRefusal(error.trimmed) }
    }

    // MARK: - Checking what is asked for

    // The checkouts a session works in, lead first, as its changes list them.
    func changesCheckouts(of session: ChatSession) -> [StationChangesReader.Checkout] {
        store.checkoutProjects(for: session).compactMap { checkout in
            guard let project = store.project(checkout.projectID) else { return nil }
            return StationChangesReader.Checkout(project: project.name,
                                                 path: checkout.worktreePath ?? project.path,
                                                 isWorktree: checkout.worktreePath != nil)
        }
    }

    // What git says now about one checkout of the session, which has to be one it works
    // in and a repository git can read.
    private func changedTree(_ sessionID: String, checkout: String) async throws(StationRefusal) -> GitSnapshot {
        guard let id = UUID(uuidString: sessionID), let session = store.session(id) else {
            throw .noSession
        }
        guard changesCheckouts(of: session).contains(where: { $0.path == checkout }) else {
            throw StationRefusal("This session does not work in \(checkout).")
        }
        let snapshot = await GitInspector.snapshot(at: checkout, lane: .interactive,
                                                   comparingToLastCommit: true)
        switch snapshot.state {
        case .ready: return snapshot
        case .notARepo: throw StationRefusal("\(checkout) is not a git repository.")
        case .missingFolder: throw StationRefusal("\(checkout) is no longer there.")
        case .gitMissing: throw StationRefusal("Could not find git on PATH.")
        case .failed(let message): throw StationRefusal(message)
        }
    }

    // The changed files named, in the order git lists them. A file no longer changed is
    // refused rather than skipped, so nothing goes ahead on a list that has moved on.
    private func chosen(_ paths: [String], in snapshot: GitSnapshot) throws(StationRefusal) -> [GitChange] {
        guard !paths.isEmpty else { throw StationRefusal("Choose at least one file.") }
        let wanted = Set(paths)
        let files = snapshot.files.filter { wanted.contains($0.path) }
        if let gone = paths.first(where: { path in !files.contains { $0.path == path } }) {
            throw StationRefusal("\(gone) has no changes any more.")
        }
        return files
    }
}

// One reader's live changes: the last copy it was sent, so an unchanged one is not sent
// again, the read that keeps asking git, and the pause between reads, which a commit or
// discard cuts short.
@MainActor
final class ChangesWatch {
    let continuation: AsyncStream<RemoteChanges>.Continuation
    var reader: Task<Void, Never>?
    var nap: Task<Void, Never>?
    // What the trees looked like when the changes were last read.
    var look: [StationTreeLook]?
    // Whether git should be asked again before the next pause.
    var nudged = false
    private var last: RemoteChanges?
    private(set) var stopped = false

    init(continuation: AsyncStream<RemoteChanges>.Continuation) {
        self.continuation = continuation
    }

    func send(_ changes: RemoteChanges) {
        guard !stopped, changes != last else { return }
        last = changes
        continuation.yield(changes)
    }

    func nudge() {
        nudged = true
        nap?.cancel()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        reader?.cancel()
        nap?.cancel()
        continuation.finish()
    }
}

// A cheap look at one tree, to tell whether its changes need reading again: git's short
// status with the branch and HEAD (one git call), and when each changed file was last
// written, so an edit that leaves the line counts alone still counts.
struct StationTreeLook: Equatable, Sendable {
    let status: String
    let written: [String: Date]

    @MainActor
    static func take(_ paths: [String]) async -> [StationTreeLook] {
        guard let tool = GitInspector.tool() else { return [] }
        var looks: [StationTreeLook] = []
        for path in paths {
            looks.append(await GitInspector.offMain(lane: .background) { take(path, tool: tool) })
        }
        return looks
    }

    private static func take(_ path: String, tool: GitInspector.GitTool) -> StationTreeLook {
        let url = URL(fileURLWithPath: path)
        let output = GitInspector.run(tool, ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"],
                                      in: url)
        guard output.status == 0 else { return StationTreeLook(status: output.errorText, written: [:]) }
        var written: [String: Date] = [:]
        var fields = output.text.split(separator: "\0", omittingEmptySubsequences: true)[...]
        while let field = fields.popFirst() {
            let changed: Substring?
            switch field.first {
            case "1": changed = field.split(separator: " ", maxSplits: 8).last
            case "2":
                changed = field.split(separator: " ", maxSplits: 9).last
                // The original path follows as a field of its own.
                _ = fields.popFirst()
            case "u": changed = field.split(separator: " ", maxSplits: 10).last
            case "?": changed = field.dropFirst(2)
            default: changed = nil
            }
            guard let changed else { continue }
            let file = url.appendingPathComponent(String(changed)).path
            let attributes = try? FileManager.default.attributesOfItem(atPath: file)
            written[String(changed)] = attributes?[.modificationDate] as? Date ?? .distantPast
        }
        return StationTreeLook(status: output.text, written: written)
    }
}
