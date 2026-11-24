import Observation

@MainActor
@Observable
final class PushReviewModel {
    enum Phase: Equatable {
        case loading, ready, pulling, pushing, failed, complete
    }

    private(set) var phase = Phase.loading
    private(set) var commits: [GitRemoteCommit] = []
    // What origin has that this branch does not. Pushing waits until these are pulled.
    private(set) var incoming: [GitRemoteCommit] = []
    // Origin already has a branch under this name, though this branch does not track it.
    private(set) var nameOnOrigin = false
    // What origin's branch holds that this branch does not. Pushing replaces that branch,
    // so these leave origin.
    private(set) var replaced: [GitRemoteCommit] = []
    // The replaced commits are this branch's own, from before an amend or a rebase.
    private(set) var rewrote = false
    @ObservationIgnored private var replacedTip: String?
    private(set) var errorTitle = ""
    private(set) var error = ""
    private(set) var pulled: [GitRemoteCommit] = []
    private(set) var stashConflict = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let read: () async -> GitPushPreview
    @ObservationIgnored private let pull: () async -> GitPullOutcome
    @ObservationIgnored private let push: (_ replacing: String?) async -> String?

    var isWorking: Bool { phase == .pulling || phase == .pushing }
    var behind: Int { incoming.count }

    init(read: @escaping () async -> GitPushPreview,
         pull: @escaping () async -> GitPullOutcome,
         push: @escaping (_ replacing: String?) async -> String?) {
        self.read = read
        self.pull = pull
        self.push = push
    }

    convenience init(root: String, hasUpstream: Bool) {
        self.init(read: { await GitActions.commitsToPush(hasUpstream: hasUpstream, at: root) },
                  pull: { await GitActions.pull(at: root) },
                  push: { await GitActions.push(hasUpstream: hasUpstream, replacing: $0, at: root) })
    }

    func load() async {
        guard !isWorking else { return }
        generation += 1
        let request = generation
        phase = .loading
        let result = await read()
        guard !Task.isCancelled, request == generation else { return }
        nameOnOrigin = false
        rewrote = false
        replaced = []
        replacedTip = nil
        switch result {
        case .commits(let commits):
            self.commits = commits
            incoming = []
            phase = .ready
        case .behindUpstream(let incoming, let commits):
            self.commits = commits
            self.incoming = incoming
            phase = .ready
        case .nameOnOrigin(let commits, let unrelated, let tip):
            self.commits = commits
            incoming = []
            nameOnOrigin = true
            replaced = unrelated
            replacedTip = unrelated.isEmpty ? nil : tip
            phase = .ready
        case .rewroteUpstream(let commits, let replaced, let tip):
            self.commits = commits
            incoming = []
            rewrote = true
            self.replaced = replaced
            replacedTip = tip
            phase = .ready
        case .failed(let error):
            fail("Could not check commits to push", error)
        }
    }

    func invalidate() { generation += 1 }

    // Once Git starts writing, let it finish even if another surface replaces the dialog.
    // The result belongs to this model and cannot reopen a dismissed dialog.
    @discardableResult
    func send() async -> Bool {
        guard phase == .ready else { return false }
        if behind > 0 {
            phase = .pulling
            switch await pull() {
            case .failed(let error):
                fail("Could not pull", error)
                return true
            case .updated(let commits): pulled = commits
            case .updatedWithStashConflict(let commits):
                pulled = commits
                stashConflict = true
            case .upToDate: break
            }
        }
        phase = .pushing
        if let error = await push(replacedTip) { fail("Could not push", error) }
        else { phase = .complete }
        return true
    }

    private func fail(_ title: String, _ message: String) {
        errorTitle = title
        error = message
        phase = .failed
    }
}
