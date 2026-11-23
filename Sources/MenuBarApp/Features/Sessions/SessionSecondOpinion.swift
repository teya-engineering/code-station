import Foundation
import Observation

// A second opinion asked from a session's pane: the ask card while it is open, the lanes
// under the header control, and the requests an ask turns into. The pane lays these out
// and chooses the page that shows the result, since only it knows its tabs.
@MainActor
@Observable
final class SessionSecondOpinion {
    // What the ask card was opened on, and what it will start from.
    struct Ask: Equatable {
        var id = UUID()
        var facts: SecondOpinionAskFacts
        var stop: SecondOpinionStop
        // Where the control that opened it sits. Nil for the header, which is tracked
        // on its own since it never moves.
        var anchor: CGRect?
        // The plan or answer the card asks about, and the message its card goes under.
        var chatSubject: ChatSecondOpinion.Subject?
        var chatAnchor: UUID?
    }

    // What the pane has in view that an ask can start from.
    struct Screen {
        // The file picked on the Changes screen, while that screen is in view.
        var selectedChange: (root: String, path: String)?
        // The session's Design, when it has files to review.
        var design: ChatSession?
        // The page in view is the Design's canvas.
        var showsDesign = false
        // What the Changes screen last read for each project root, which holds the
        // branch's changes from its base while that screen compares with one.
        var compared: [String: GitSnapshot] = [:]
    }

    // The reviewers last asked from this session, whatever they were asked about.
    var lineup: [SecondOpinion.Reviewer]?
    // The ask card while it is open, and where the control that opened it sits.
    var ask: Ask?
    var anchor: CGRect?
    var lanesOpen = false
    private(set) var sinceReviewFiles: Set<String>?

    // MARK: - Subjects

    static func planID(_ request: PermissionRequest) -> String { "plan:" + request.id }

    // The plan waiting on an answer, judged against the request that led to it.
    static func planSubject(_ request: PermissionRequest, in session: ChatSession) -> ChatSecondOpinion.Subject {
        ChatSecondOpinion.Subject(kind: .plan, id: planID(request), text: request.subject,
                                  request: session.messages.last(where: { $0.role == .user })?.text ?? "")
    }

    static func answerSubject(_ message: ChatMessage, in session: ChatSession) -> ChatSecondOpinion.Subject {
        let index = session.messages.firstIndex { $0.id == message.id } ?? session.messages.endIndex
        let asked = session.messages[..<index].last { $0.role == .user }?.text ?? ""
        return ChatSecondOpinion.Subject(kind: .answer, id: "answer:" + message.id.uuidString,
                                         text: message.text, request: asked)
    }

    // The whole conversation as one subject, judged against everything the person asked.
    static func conversationSubject(_ session: ChatSession, state: SessionState) -> ChatSecondOpinion.Subject? {
        guard let latest = latestAnswer(in: session, state: state) else { return nil }
        let asked = session.messages.filter { $0.role == .user && !$0.text.isBlank }.map(\.text.trimmed)
        return ChatSecondOpinion.Subject(kind: .conversation, id: "conversation:" + latest.id.uuidString,
                                         text: SideQuestion.recentChat(session.messages),
                                         request: asked.joined(separator: "\n\n"))
    }

    // An answer can be judged once it is whole: not while its turn is still writing it.
    static func canJudge(_ message: ChatMessage, in session: ChatSession, state: SessionState) -> Bool {
        guard message.role == .assistant, !message.text.isBlank else { return false }
        return !(state.isBusy && session.messages.last?.id == message.id)
    }

    static func latestAnswer(in session: ChatSession, state: SessionState) -> ChatMessage? {
        session.messages.last { canJudge($0, in: session, state: state) }
    }

    // MARK: - The ask card

    // Everything the ask can be about, read from the session as it stands.
    static func facts(_ session: ChatSession, picked: ChatSecondOpinion.Subject?,
                      origin: SecondOpinionOrigin, file: (root: String, path: String)?,
                      screen: Screen, runner: SessionRunner, gitStats: GitStatsCache)
        -> (facts: SecondOpinionAskFacts, chatSubject: ChatSecondOpinion.Subject?) {
        let store = runner.store
        // A plan waiting on an answer comes before the last answer.
        let latest = picked == nil ? latestAnswer(in: session, state: runner.state(session.id)) : nil
        let pendingPlan = picked == nil && origin == .header
            ? runner.question(session.id).map { planSubject($0, in: session) } : nil
        let chatSubject = picked ?? pendingPlan ?? latest.map { answerSubject($0, in: session) }

        var facts = SecondOpinionAskFacts(origin: origin)
        facts.answer = chatSubject.map { .init(subject: $0, picked: picked != nil) }
        func files(_ snapshot: GitSnapshot, root: String) -> [SecondOpinionAskFacts.File] {
            snapshot.files.map { change in
                .init(root: snapshot.root.isEmpty ? root : snapshot.root, path: change.path,
                      added: change.added ?? 0, removed: change.removed ?? 0)
            }
        }
        // A project the Changes screen does not compare with a base adds its uncommitted
        // files to the branch, the way a run reads it.
        var branchFiles: [SecondOpinionAskFacts.File] = []
        var bases: [String] = []
        for root in store.workingDirectories(for: session) {
            let uncommitted = gitStats.snapshot(at: root).map { files($0, root: root) }
            facts.files += uncommitted ?? []
            if let compared = screen.compared[root], compared.comparedToRemote, let base = compared.remoteBase {
                bases.append(base.ref)
                branchFiles += files(compared, root: root)
            } else {
                branchFiles += uncommitted ?? []
            }
        }
        if !bases.isEmpty && branchFiles != facts.files {
            facts.branch = .init(base: Set(bases).count == 1 ? bases[0] : "each project's base", files: branchFiles)
        }
        let pickable = facts.branch?.files ?? facts.files
        if let file {
            facts.file = pickable.first { $0.path == file.path && ($0.root == file.root || pickable.count(where: { $0.path == file.path }) == 1) }
        } else if let picked = screen.selectedChange {
            facts.file = pickable.first { $0.path == picked.path }
        }
        facts.canReadSince = runner.reviews.latestTrees(session.id) != nil
        if let design = screen.design,
           let directory = store.designArtifactURL(for: design)?.deletingLastPathComponent() {
            facts.designScreens = DesignManifest.read(from: directory).screens.map(\.title)
        }
        facts.turns = session.messages.compactMap { message in
            guard message.role == .user || message.role == .assistant, !message.text.isBlank else { return nil }
            return .init(fromPerson: message.role == .user, text: message.text)
        }
        facts.showsDesign = screen.showsDesign
        return (facts, chatSubject)
    }

    // The sentence the header's tooltip says a click will propose.
    func headerProposal(_ session: ChatSession, screen: Screen, runner: SessionRunner,
                        gitStats: GitStatsCache) -> String {
        let built = Self.facts(session, picked: nil, origin: .header, file: nil, screen: screen,
                               runner: runner, gitStats: gitStats)
        let installed = runner.catalog.availableAgents
        var seen = Set<AgentKind>()
        let reviewers = (lineup ?? Preferences.secondOpinionLineup()).map(\.agent)
            .filter { installed.contains($0) && seen.insert($0).inserted }
        return SecondOpinionAsk.proposal(SecondOpinionAsk.initialStop(built.facts), facts: built.facts,
                                         reviewers: reviewers)
    }

    // Opens the ask card on whatever the session can be judged on. A plan or answer the
    // person pointed at, or a file, comes in already picked; from the header, the pick
    // follows where the work stands. Each subject is then asked where its results land.
    // False when the session has nothing to judge, and the card stays shut.
    func open(_ session: ChatSession, on picked: ChatSecondOpinion.Subject?, anchor: UUID?,
              origin: SecondOpinionOrigin?, file: (root: String, path: String)?,
              screen: Screen, runner: SessionRunner, gitStats: GitStatsCache) -> Bool {
        // Asking again about the whole conversation starts from it, with the latest answer.
        let wholeConversation = picked?.kind == .conversation
        let picked = wholeConversation ? nil : picked
        let origin = origin ?? (picked != nil ? .answer : .header)
        let built = Self.facts(session, picked: picked, origin: origin, file: file, screen: screen,
                               runner: runner, gitStats: gitStats)
        guard var stop = SecondOpinionAsk.initialStop(built.facts) else { return false }
        if wholeConversation, SecondOpinionAsk.stops(built.facts).contains(.conversation) { stop = .conversation }
        lanesOpen = false
        // The header tracks its own place; anything else was recorded as it was pressed.
        let pressed = origin == .header ? nil : self.anchor
        self.anchor = nil
        ask = Ask(facts: built.facts, stop: stop, anchor: pressed,
                  chatSubject: built.chatSubject,
                  chatAnchor: picked != nil
                      ? anchor : Self.latestAnswer(in: session, state: runner.state(session.id))?.id)
        return true
    }

    // Written only when something is open, so putting away what is already away does not
    // redraw the pane.
    func close() {
        if ask != nil { ask = nil }
        if lanesOpen { lanesOpen = false }
    }

    // Marks the subject in the transcript while the card is open: the answer it reads,
    // or every message when it reads the whole conversation.
    func railShows(_ message: ChatMessage) -> Bool {
        guard let ask else { return false }
        switch ask.stop {
        case .answer: return ask.chatSubject?.kind == .answer && ask.chatAnchor == message.id
        case .conversation: return (message.role == .user || message.role == .assistant) && !message.text.isBlank
        default: return false
        }
    }

    // What changed after the last review, so the preview lights only those files.
    func readSinceReviewFiles(reviews: ReviewCommentStore, sessionID: UUID) async {
        if sinceReviewFiles != nil { sinceReviewFiles = nil }
        guard let ask, ask.facts.canReadSince,
              let trees = reviews.latestTrees(sessionID) else { return }
        var ids = Set<String>()
        for (root, tree) in trees {
            guard let changed = await TreeSnapshots.shared.patch(since: tree, at: root) else { continue }
            for patch in SecondOpinion.split(changed.text, root: changed.root) {
                ids.insert(SecondOpinionAskFacts.File(root: patch.root, path: patch.path, added: 0, removed: 0).id)
            }
        }
        guard !Task.isCancelled else { return }
        sinceReviewFiles = ids
    }

    // MARK: - Requests

    // Sends what the card settled on to where that kind of subject is reviewed: an answer
    // or the conversation to the chat's reviewers, a Design to the Design's, and the
    // working tree to the Changes screen, which starts the run itself once it picks the
    // request up. False when the subject is no longer there to review.
    static func start(_ choice: SecondOpinionAskChoice, ask: Ask, session: ChatSession,
                      design: ChatSession?, installed: [AgentKind],
                      navigation: ChangesNavigationMemory, runner: SessionRunner) -> Bool {
        let store = runner.store
        let executables = Dictionary(uniqueKeysWithValues: installed.compactMap { agent in
            runner.catalog.executable(for: agent).map { (agent, $0) }
        })
        let servers = reviewerServers(session, usesServers: choice.usesServers)
        switch choice.stop {
        case .answer, .conversation:
            let state = runner.state(session.id)
            let subject: ChatSecondOpinion.Subject? = choice.stop == .conversation
                ? conversationSubject(session, state: state)
                : ask.chatSubject
            guard let subject else { return false }
            runner.opinions.ask(
                ChatSecondOpinion.Request(subject: subject, focus: choice.chatFocus, note: choice.note,
                                          reading: choice.chatReading,
                                          conversation: choice.chatReading.conversation
                                            ? SideQuestion.recentChat(session.messages) : "",
                                          directories: store.workingDirectories(for: session),
                                          executable: "", servers: servers),
                reviewers: choice.lineup, executables: executables,
                anchor: choice.stop == .conversation
                    ? latestAnswer(in: session, state: state)?.id : ask.chatAnchor,
                in: session.id)
        case .file, .sinceReview, .uncommitted, .branch:
            navigation.secondOpinionFocus = choice.changesFocus
            navigation.secondOpinionNote = choice.note
            navigation.secondOpinionServers = servers
            navigation.secondOpinionScope = switch choice.stop {
            case .file: .file
            case .sinceReview: .sinceReview
            case .branch: .branch
            default: .all
            }
            navigation.secondOpinionRequest = .ask(choice.lineup)
        case .design:
            guard let design,
                  let designDirectory = store.designArtifactURL(for: design)?.deletingLastPathComponent()
            else { return false }
            let screens = DesignManifest.read(from: designDirectory).screens
            let shots = FileManager.default.temporaryDirectory
                .appendingPathComponent("code-station-design-review-\(UUID().uuidString)", isDirectory: true)
            let asked = design.messages.filter { $0.role == .user }.suffix(3).reversed()
                .map(\.text).joined(separator: "\n\n")
            runner.designOpinions.ask(
                DesignSecondOpinion.Request(focus: choice.designFocus, note: choice.note, reading: choice.designReading,
                                            designDirectory: designDirectory.path, shotsDirectory: shots.path,
                                            shots: [], asked: asked,
                                            conversation: choice.designReading.conversation
                                                ? SideQuestion.recentChat(design.messages) : "",
                                            executable: "", servers: servers),
                screens: screens, reviewers: choice.lineup, executables: executables, in: design.id)
        }
        return true
    }

    // Has another agent read what changed since a review round went. False when that
    // agent is not installed, and nothing starts.
    static func checkFixes(_ round: ReviewRound, checker: AgentKind?, session: ChatSession,
                           runner: SessionRunner) -> Bool {
        guard let checker, let executable = runner.catalog.executable(for: checker) else { return false }
        let store = runner.store
        let repositories = store.workingDirectories(for: session).map {
            ReviewRepository(root: $0, name: ($0 as NSString).lastPathComponent)
        }
        let defaults = Preferences.secondOpinionDefaults()
        let seat = defaults.seats.first { $0.reviewer.agent == checker }?.reviewer
            ?? SecondOpinion.Reviewer(agent: checker)
        runner.reviews.startSecondOpinion(session.id, reviewer: seat, request: SecondOpinionRequest(
            focus: SecondOpinion.Focus.allCases.filter(defaults.changesFocus.contains),
            scope: .sinceReview(trees: round.trees), repositories: repositories, executable: executable,
            servers: store.session(session.id).flatMap {
                reviewerServers($0, usesServers: defaults.usesServers)
            }))
        return true
    }

    // The MCP servers the session's reviewers get, when the ask lets them use any.
    static func reviewerServers(_ session: ChatSession, usesServers: Bool) -> SecondOpinion.ServerAccess? {
        guard usesServers else { return nil }
        return .session(session.settings, claudeServers: SecondOpinion.claudeServers(),
                        codexServers: SecondOpinion.codexServers())
    }
}
