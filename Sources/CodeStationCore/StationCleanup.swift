import Foundation

// Repairing and tidying the station, as the GUI's warning strip and the two cleanup
// strips at the foot of its sidebar do it: rebuild a session's lost worktree, prune the
// worktrees no session owns (found by the host's upkeep), and review the sessions past
// the shared age with what deleting each would cost, then delete the ones chosen. Each
// is read first and done once the person confirms, as the GUI asks with a Dialog.
extension StationCommands {

    // MARK: - Rebuild

    // What rebuilding the session's lost checkouts would do, worked out by asking git
    // where each one's commits are, for the front end to ask with. Refused when nothing
    // is lost, or git cannot say.
    public func readRebuild(_ sessionID: String) async throws(StationRefusal) -> RemoteImpact {
        let plan = try await rebuildPlan(sessionID)
        return RemoteImpact(title: plan.count == 1 ? "Rebuild the missing folder?" : "Rebuild the missing folders?",
                            message: SessionLifecycle.rebuildMessage(for: plan), rows: [], action: "Rebuild")
    }

    // Puts the lost checkouts back from where git says their commits are. The session's
    // record is left alone: it was right all along.
    public func rebuild(_ sessionID: String) async throws(StationRefusal) {
        try admitTurn()
        let plan = try await rebuildPlan(sessionID)
        if case .failure(let failure) = await SessionLifecycle.rebuild(plan, worktrees: worktrees) {
            throw StationRefusal("\(failure.title). \(failure.message)")
        }
    }

    private func rebuildPlan(_ sessionID: String) async throws(StationRefusal) -> [PlannedRebuild] {
        guard let id = UUID(uuidString: sessionID), let session = store.session(id) else { throw .noSession }
        let checkouts = SessionLifecycle.rebuildableCheckouts(of: session, in: store)
        guard !checkouts.isEmpty else { throw StationRefusal("Nothing in this session needs rebuilding.") }
        let plan = await SessionLifecycle.planRebuild(checkouts)
        guard !plan.isEmpty else {
            throw StationRefusal("Nothing here can be rebuilt. Git could not be asked which branch these folders were on.")
        }
        return plan
    }

    // MARK: - Orphaned worktrees

    // The worktrees the host's upkeep found with no session, as its strip counts them.
    // None on a host that does not look after worktrees.
    public func readOrphanedWorktrees() -> [RemoteOrphanedWorktree] {
        (upkeep?.orphanedWorktrees.worktrees ?? []).map(RemoteOrphanedWorktree.init)
    }

    // Prunes the orphans named that are still orphans, once the person has read them.
    // A removal git refuses is refused with git's reason; the others still go.
    public func pruneOrphanedWorktrees(paths: [String]) async throws(StationRefusal) {
        try admitTurn()
        guard let upkeep else { throw StationRefusal("This host does not look after worktrees.") }
        let named = Set(paths)
        let chosen = upkeep.orphanedWorktrees.worktrees.filter { named.contains($0.path) }
        guard !chosen.isEmpty else { throw StationRefusal("Those worktrees are no longer orphaned.") }
        let result = await upkeep.orphanedWorktrees.prune(chosen, in: store)
        guard result.failures.isEmpty else {
            throw StationRefusal(result.failures.map(\.message).joined(separator: "\n"))
        }
    }

    // MARK: - Old sessions

    // The sessions past the shared age and not running, by project, each with what
    // deleting it costs as git answers now. A snoozed project is listed with its snooze.
    public func readOldSessions() async -> RemoteOldSessions {
        let days = Preferences.oldSessionDays(in: preferences)
        var order: [UUID] = []
        var rows: [UUID: [RemoteOldSessions.Session]] = [:]
        var ticked = 0
        for session in OldSessions.reviewable(days: days, store: store, runner: runner) {
            let worktrees = store.checkoutProjects(for: session).compactMap(\.worktreePath)
            let cost = await SessionCost.settledCost(worktrees: worktrees, design: store.designCost(for: session))
            let tick = cost.losesNothing && ticked < OldSessions.preselectLimit
            if tick { ticked += 1 }
            if rows[session.projectID] == nil { order.append(session.projectID) }
            rows[session.projectID, default: []].append(RemoteOldSessions.Session(
                session: session, worktrees: worktrees, cost: cost, isTicked: tick))
        }
        let groups = order.map { projectID in
            let project = store.project(projectID)
            let snooze = project?.snoozedUntil
            return RemoteOldSessions.Group(projectID: projectID.uuidString,
                                           name: project?.name ?? "Unknown project",
                                           sessions: rows[projectID] ?? [],
                                           snoozedUntil: ProjectSnooze.isActive(snooze) ? snooze : nil)
        }
        return RemoteOldSessions(days: days, groups: groups)
    }

    // Deletes the old sessions chosen, through the same lifecycle as a deletion by hand.
    // A session that is not old, is running or is held back by a snooze is refused
    // before anything goes.
    public func deleteOldSessions(_ sessionIDs: [String]) async throws(StationRefusal) {
        try admitTurn()
        let days = Preferences.oldSessionDays(in: preferences)
        let reviewable = Set(OldSessions.reviewable(days: days, store: store, runner: runner).map(\.id))
        var chosen: [ChatSession] = []
        for sessionID in sessionIDs {
            guard let id = UUID(uuidString: sessionID), let session = store.session(id) else { throw .noSession }
            guard reviewable.contains(id) else {
                throw StationRefusal("\(session.title) is not older than \(counted(days, "day")).")
            }
            guard !ProjectSnooze.isActive(store.snoozeDeadline(for: session)) else {
                throw StationRefusal("\(session.title)'s project is snoozed.")
            }
            chosen.append(session)
        }
        var failures: [SessionLifecycle.Failure] = []
        for session in chosen {
            if case .failure(let failure) = await SessionLifecycle.remove(session, from: store, runner: runner,
                                                                          worktrees: worktrees) {
                failures.append(failure)
            }
        }
        guard failures.isEmpty else {
            throw StationRefusal(failures.count == 1 ? "\(failures[0].title). \(failures[0].message)"
                                 : "Could not delete some sessions. " + failures.map(\.message).joined(separator: "\n"))
        }
    }
}

// A worktree no saved session owns, as the orphaned-worktrees strip offers to prune it.
public struct RemoteOrphanedWorktree: Codable, Equatable, Sendable {
    public let projectName: String
    public let path: String
    public let branch: String?
    public let bytes: Int64

    public init(projectName: String, path: String, branch: String?, bytes: Int64) {
        self.projectName = projectName
        self.path = path
        self.branch = branch
        self.bytes = bytes
    }

    init(_ worktree: OrphanedWorktree) {
        self.init(projectName: worktree.projectName, path: worktree.path, branch: worktree.branch,
                  bytes: worktree.allocatedBytes)
    }

    // "4 KB", or "No disk usage".
    public var size: String {
        bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : "No disk usage"
    }

    // What pruning them takes, every one named with its place and size, as the GUI's
    // confirmation lists them.
    public static func pruneImpact(_ worktrees: [RemoteOrphanedWorktree]) -> RemoteImpact {
        RemoteImpact(title: "Prune \(counted(worktrees.count, "orphaned worktree"))?",
                     message: "These checkouts have no session. Branches are kept when they have unmerged commits.",
                     rows: worktrees.map {
                         .init(title: "\($0.projectName) · \($0.branch ?? "Detached HEAD")",
                               detail: "\($0.path) · \($0.size)")
                     },
                     warning: "Any uncommitted changes in them will be lost.",
                     action: "Prune all")
    }
}

// The old-sessions review, as the GUI's sheet shows it: the shared age, and the sessions
// past it by project, each with what deleting it costs.
public struct RemoteOldSessions: Codable, Equatable, Sendable {
    // How a row's cost reads: nothing but history (grey), files that can be made again
    // (amber), or work that goes with it (red).
    public enum Tone: String, Codable, Sendable {
        case quiet, files, loss
    }

    public struct Session: Codable, Equatable, Sendable {
        public let id: String
        public let title: String
        // "last turn 9 days ago · 4 turns · ⑂ code-station/x · clean"
        public let detail: String
        // "history only", "would lose work", …
        public let cost: String
        public let tone: Tone
        public let hasWorktree: Bool
        // Whether it can be ticked: git has answered for its worktree.
        public let canSelect: Bool
        public let losesWork: Bool
        // Costs nothing but the conversation, which is what may arrive ticked.
        public let losesNothing: Bool
        public let unbuiltDesign: Bool
        public let dirtyWorktree: Bool
        // Ticked for the person: costs nothing but history, within the first fifty.
        public let isTicked: Bool

        public init(id: String, title: String, detail: String, cost: String, tone: Tone, hasWorktree: Bool,
                    canSelect: Bool, losesWork: Bool, losesNothing: Bool, unbuiltDesign: Bool, dirtyWorktree: Bool, isTicked: Bool) {
            self.id = id
            self.title = title
            self.detail = detail
            self.cost = cost
            self.tone = tone
            self.hasWorktree = hasWorktree
            self.canSelect = canSelect
            self.losesWork = losesWork
            self.losesNothing = losesNothing
            self.unbuiltDesign = unbuiltDesign
            self.dirtyWorktree = dirtyWorktree
            self.isTicked = isTicked
        }

        init(session: ChatSession, worktrees: [String], cost: SessionRemovalCost, isTicked: Bool) {
            let tone: Tone = if !cost.canSelect { cost.worktree == .checking ? .quiet : .loss }
                else if cost.losesWork { .loss }
                else if cost.removesFiles { .files }
                else { .quiet }
            self.init(id: session.id.uuidString, title: session.title,
                      detail: OldSessions.detail(of: session, worktrees: worktrees, cost: cost),
                      cost: cost.label, tone: tone, hasWorktree: !worktrees.isEmpty, canSelect: cost.canSelect,
                      losesWork: cost.losesWork, losesNothing: cost.losesNothing, unbuiltDesign: cost.design == .unimplemented,
                      dirtyWorktree: cost.worktree.losesWork, isTicked: isTicked)
        }
    }

    public struct Group: Codable, Equatable, Sendable {
        public let projectID: String
        public let name: String
        public let sessions: [Session]
        // While its cleanup is snoozed; its sessions are out of reach until then.
        public let snoozedUntil: Date?

        public init(projectID: String, name: String, sessions: [Session], snoozedUntil: Date?) {
            self.projectID = projectID
            self.name = name
            self.sessions = sessions
            self.snoozedUntil = snoozedUntil
        }

        public var isSnoozed: Bool { snoozedUntil != nil }
    }

    public let days: Int
    public let groups: [Group]

    public init(days: Int, groups: [Group]) {
        self.days = days
        self.groups = groups
    }

    // The sessions a deletion can reach: a snoozed project's are out of it.
    public var awakeSessions: [Session] { groups.filter { !$0.isSnoozed }.flatMap(\.sessions) }

    // The cards under the list, as the GUI's sheet puts them: the ticking cap, then what
    // deleting would cost, then a list that is all snoozed.
    public var notices: [String] {
        var notices: [String] = []
        if groups.flatMap(\.sessions).count(where: \.losesNothing) > OldSessions.preselectLimit {
            notices.append(OldSessions.preselectNotice())
        }
        let awake = awakeSessions
        let designs = awake.count(where: \.unbuiltDesign)
        if designs > 0 { notices.append(OldSessions.unbuiltDesignCost(designs)) }
        let dirty = awake.count(where: \.dirtyWorktree)
        if dirty > 0 { notices.append(OldSessions.dirtyWorktreeCost(dirty)) }
        if !groups.isEmpty, groups.allSatisfy(\.isSnoozed) { notices.append(OldSessions.everythingSnoozedNotice) }
        return notices
    }

    // The second question for chosen sessions holding saved work, or nil when they cost
    // nothing but history.
    public static func deletionImpact(of chosen: [Session]) -> RemoteImpact? {
        OldSessions.savedWorkImpact(sessions: chosen.count,
                                    unbuiltDesigns: chosen.count(where: \.unbuiltDesign),
                                    dirtyWorktrees: chosen.count(where: \.dirtyWorktree),
                                    action: OldSessions.deleteLabel(chosen.count))
    }
}
