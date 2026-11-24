import Foundation

// The branch a folder has checked out, read straight from .git/HEAD instead of by running
// git: sidebar rows redraw often and none of them are worth a process. The answer is held
// for a moment so a burst of redraws costs a single read.
@MainActor
enum GitHead {
    private static var cache: [String: (branch: String?, readAt: Date)] = [:]
    private static let ttl: TimeInterval = 5

    static func branch(at path: String) -> String? {
        if let hit = cache[path], Date().timeIntervalSince(hit.readAt) < ttl { return hit.branch }
        let branch = read(path)
        cache[path] = (branch, Date())
        return branch
    }

    // A detached head holds a sha rather than a ref, which is nothing a row can use.
    private static func read(_ path: String) -> String? {
        guard let head = try? String(contentsOfFile: gitDirectory(of: path) + "/HEAD", encoding: .utf8) else { return nil }
        let reference = "ref: refs/heads/"
        let line = head.trimmed
        guard line.hasPrefix(reference) else { return nil }
        return String(line.dropFirst(reference.count))
    }

    // In a linked worktree or a submodule, .git is a file that points at the real git
    // directory, and a submodule's pointer is relative to the checkout.
    private static func gitDirectory(of path: String) -> String {
        let dotGit = path + "/.git"
        guard let pointer = try? String(contentsOfFile: dotGit, encoding: .utf8) else { return dotGit }
        let prefix = "gitdir:"
        let line = pointer.trimmed
        guard line.hasPrefix(prefix) else { return dotGit }
        let target = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return target.hasPrefix("/") ? target : path + "/" + target
    }
}
