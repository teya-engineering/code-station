import CryptoKit
import Foundation

// What the working tree held at one moment, kept so the next moment can be compared
// against it.
//
// A call describes what it changed only when the agent used an edit tool. A command that
// wrote through the shell describes nothing at all, and under the permission mode that
// asks only about risky things, the shell is how most files get written. Git sees every
// write whatever made it, so what a call changed is worked out by recording the tree after
// the call and comparing it with the recording from before.
//
// The recording goes into an index of its own, named through GIT_INDEX_FILE. Nothing
// belonging to the checkout is touched: not its index, not HEAD, not a file in it. The
// index is kept between snapshots on purpose, since it carries the timestamps that let git
// skip every file that has not moved. Keeping it is the difference between a snapshot
// costing a few tens of milliseconds and rehashing the whole repository each time.
//
// The trees it writes are reachable from nothing, so git's own housekeeping collects them
// in its own time.
final class TreeSnapshots: @unchecked Sendable {
    static let shared = TreeSnapshots()

    // Past this, a change is a dependency install or a build that escaped .gitignore
    // rather than something anyone reads a line at a time. The row still says how much
    // moved, and the Changes view is where that much of it belongs.
    static let fileLimit = 12
    static let lineLimit = 400

    // A checkout where one snapshot costs this much is one where taking them after every
    // call would be felt. It stops being measured rather than slowing down the rest of the
    // session.
    static let slowSnapshot: TimeInterval = 2

    // Calls that cannot have written anything. Everything else is measured, since short of
    // looking there is no way to know what a command did.
    static let readOnlyTools: Set<String> = [
        "Read", "Grep", "Glob", "WebFetch", "WebSearch", "TodoWrite",
        // An agent's own calls arrive in the same stream and are measured one by one, so
        // the call that stands for the whole agent has nothing left to account for.
        "Task", "Agent", "Workflow",
    ]

    static func measures(_ toolName: String) -> Bool { !readOnlyTools.contains(toolName) }

    // Snapshots run one after another. They have to stay in the order the calls finished
    // in, or a change lands on the row of whichever call happened to be measured next, and
    // they have their own queue so they neither wait behind the sweep that keeps the
    // sidebar current nor hold up the Changes view.
    private let queue = DispatchQueue(label: "com.teya.code-station.git.snapshots",
                                      qos: .userInitiated)

    // Both only ever touched on that queue.
    private var checkouts: [String: Checkout] = [:]
    // Nil for a folder that is not in a repository at all, which is worth remembering so
    // git is not asked again after every call for the rest of the session.
    private var roots: [String: String?] = [:]

    private struct Checkout {
        let indexPath: String
        var tree: String?
        // Set once a snapshot has cost more than it is worth. Measuring then stops for
        // good rather than being reconsidered call by call.
        var isTooSlow = false
    }

    // MARK: - Taking a snapshot

    // Records where the tree stands without reporting on it, so the next call is measured
    // from now. Taken as a turn begins: whatever changed between turns belongs to whoever
    // changed it, not to the first call that happens to run.
    func baseline(at path: String, using git: GitInspector.GitTool) {
        queue.async { _ = self.take(at: path, using: git) }
    }

    // What changed in the checkout since the last snapshot. The answer comes back on the
    // main actor a beat after the call it belongs to has already been drawn, and is nil
    // when nothing changed, when the folder holds no repository, or when git could not say.
    func change(at path: String, using git: GitInspector.GitTool,
                then finish: @escaping @MainActor @Sendable (WrittenChange?) -> Void) {
        queue.async {
            let change = self.take(at: path, using: git)
            Task { @MainActor in finish(change) }
        }
    }

    private func take(at path: String, using git: GitInspector.GitTool) -> WrittenChange? {
        guard let root = root(of: path, using: git) else { return nil }
        var checkout = checkouts[root] ?? Checkout(indexPath: Self.indexPath(for: root))
        guard !checkout.isTooSlow else { return nil }
        defer { checkouts[root] = checkout }

        let started = Date()
        let url = URL(fileURLWithPath: root)
        let environment = ["GIT_INDEX_FILE": checkout.indexPath]

        // A brand new index knows nothing about the checkout, and filling it from the last
        // commit is far cheaper than letting the first `add` hash every file. A repository
        // with no commits yet has nothing to fill it from, which only costs one slow first
        // snapshot.
        if !FileManager.default.fileExists(atPath: checkout.indexPath) {
            _ = GitInspector.run(git, ["read-tree", "HEAD"], in: url, environment: environment)
        }
        guard GitInspector.run(git, ["add", "-A"], in: url, environment: environment).ok,
              case let written = GitInspector.run(git, ["write-tree"], in: url,
                                                  environment: environment),
              written.ok
        else { return nil }

        let tree = written.trimmedText
        guard !tree.isEmpty else { return nil }

        let cost = Date().timeIntervalSince(started)
        if cost > Self.slowSnapshot {
            checkout.isTooSlow = true
            SessionLog.note("tree snapshots off for \(root): took \(Int(cost * 1000))ms")
        }

        let previous = checkout.tree
        checkout.tree = tree
        // The first snapshot of a checkout has nothing to compare against, and an unmoved
        // tree means the call read rather than wrote, which is most of them.
        guard let previous, previous != tree else { return nil }
        return Self.change(from: previous, to: tree, in: url, using: git)
    }

    private static func change(from old: String, to new: String, in root: URL,
                               using git: GitInspector.GitTool) -> WrittenChange? {
        let counts = GitInspector.run(git, ["diff-tree", "-r", "--numstat", "-M", old, new],
                                      in: root)
        guard counts.ok else { return nil }

        var change = WrittenChange()
        for row in counts.text.split(separator: "\n") {
            let fields = row.split(separator: "\t")
            guard fields.count >= 3 else { continue }
            change.files += 1
            // A binary file is counted as "-" on both sides, which is honestly nothing to
            // add: no line of it changed, because it has no lines.
            change.added += Int(fields[0]) ?? 0
            change.removed += Int(fields[1]) ?? 0
        }
        guard change.files > 0 else { return nil }
        guard change.files <= fileLimit, change.added + change.removed <= lineLimit
        else { return change }

        let patch = GitInspector.run(git, ["diff-tree", "-r", "-p", "-M", "--no-color", old, new],
                                     in: root)
        if patch.ok, !patch.truncated { change.patch = patch.text }
        return change
    }

    // MARK: - Where the snapshots live

    private func root(of path: String, using git: GitInspector.GitTool) -> String? {
        if let known = roots[path] { return known }
        let url = URL(fileURLWithPath: path)
        let top = GitInspector.run(git, ["rev-parse", "--show-toplevel"], in: url)
        let text = top.trimmedText
        let root = top.ok && !text.isEmpty ? text : nil
        roots[path] = root
        return root
    }

    // One index per checkout, named after the path rather than kept in a table, so the
    // stat cache inside it survives a restart and the first snapshot of a session is as
    // cheap as the rest. The digest is only there to make a filename out of a path.
    private static func indexPath(for root: String) -> String {
        let digest = SHA256.hash(data: Data(root.utf8)).map { String(format: "%02x", $0) }
        return AppPaths.directory("tree-snapshots", backedUp: false)
            .appendingPathComponent(String(digest.joined().prefix(32)))
            .path
    }
}
