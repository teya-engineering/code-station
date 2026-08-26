import Foundation
import SwiftUI

// Which folders hold work that git does not have yet. Sessions edit real files, either
// in the project folder or in a worktree of their own, and deleting a session takes its
// worktree with it, so the sidebar has to be able to say "there is something here to
// lose" without the session being opened.
//
// The answers are kept here rather than read where they are drawn: a row redraws far too
// often to run git, and git is far too slow to run on the main thread.
@MainActor
@Observable
final class WorkingTreeWatch {
    // Status is deliberately less immediate than the open changes view. This monitor
    // only backs a small safety mark in the sidebar, so a lower rate avoids repeatedly
    // walking every visible repository while still noticing terminal commits promptly.
    static let interval: Duration = .seconds(30)

    typealias Inspector = @Sendable (String) async -> Int

    private var uncommittedFiles: [String: Int] = [:]
    private var inspected: Set<String> = []
    @ObservationIgnored private var running: Set<String> = []
    @ObservationIgnored private let inspect: Inspector

    init(inspect: @escaping Inspector = { await GitInspector.uncommittedFileCount(at: $0) }) {
        self.inspect = inspect
    }

    func isDirty(_ path: String) -> Bool {
        uncommittedFileCount(at: path) > 0
    }

    func uncommittedFileCount(at path: String) -> Int {
        uncommittedFiles[Self.normalized(path)] ?? 0
    }

    func hasInspected(_ path: String) -> Bool {
        inspected.contains(Self.normalized(path))
    }

    func refresh(_ paths: some Collection<String>) {
        let pending = Set(paths.map(Self.normalized)).filter { path in
            guard !running.contains(path) else { return false }
            running.insert(path)
            return true
        }
        guard !pending.isEmpty else { return }

        Task {
            for path in pending {
                let result = await inspect(path)
                running.remove(path)
                inspected.insert(path)
                if result > 0 {
                    if uncommittedFiles[path] != result { uncommittedFiles[path] = result }
                } else if uncommittedFiles[path] != nil {
                    uncommittedFiles.removeValue(forKey: path)
                }
            }
        }
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
