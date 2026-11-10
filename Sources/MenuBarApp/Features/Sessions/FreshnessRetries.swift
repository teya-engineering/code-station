import SwiftUI

// Fetches the user asked to run again after the first pass failed, one per project. Both
// new-session sheets keep one of these, so a retry behaves the same in each: it waits
// longer when origin was only slow, it can be stopped, and a fetch that gets through
// says so for a moment before the notice goes.
@MainActor @Observable
final class FreshnessRetries {
    struct Attempt: Equatable {
        let started: Date
        let wait: TimeInterval
    }

    // How long the line saying origin was reached stays before it folds away.
    static let reachedHold: Duration = .seconds(2.5)

    private(set) var attempts: [UUID: Attempt] = [:]
    // Projects whose retry just got through.
    private(set) var reached: Set<UUID> = []
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    var isEmpty: Bool { attempts.isEmpty }

    // `onReport` gets the new report, failed or not. A stopped retry sends nothing, so
    // the card keeps the failure it had and the next retry waits just as long.
    func start(_ id: UUID, path: String, after report: GitFreshness.Report,
               onReport: @escaping @MainActor (GitFreshness.Report) -> Void) {
        guard attempts[id] == nil else { return }
        let wait = report.retryWait
        attempts[id] = Attempt(started: .now, wait: wait)
        reached.remove(id)
        tasks[id] = Task { [weak self] in
            let result = await GitFreshness.check(at: path, fetch: true, timeout: wait)
            guard !Task.isCancelled, let self else { return }
            attempts[id] = nil
            tasks[id] = nil
            guard let result else { return }
            onReport(result)
            guard result.fetched else { return }
            reached.insert(id)
            try? await Task.sleep(for: Self.reachedHold)
            reached.remove(id)
        }
    }

    func stop(_ id: UUID) {
        tasks.removeValue(forKey: id)?.cancel()
        attempts[id] = nil
        reached.remove(id)
    }

    func stopAll() {
        for id in Array(tasks.keys) { stop(id) }
        reached.removeAll()
    }
}
