import AppKit
import SwiftUI

// Where a second opinion is asked for and shown in the session pane. What an ask is
// about and the requests it sends live in `SessionSecondOpinion`.
extension SessionView {
    // Cards joined to a message. The one on a plan still waiting sits under the plan.
    func opinions(after messageID: UUID) -> [ChatOpinion] {
        let pending = runner.question(sessionID).map(SessionSecondOpinion.planID)
        return runner.opinions.opinions(sessionID).filter { $0.anchor == messageID && $0.subject.id != pending }
    }

    // The header's one control for a second opinion, on every tab. It shows the review
    // that belongs to the page in view: the design's on the canvas, the changes' anywhere
    // else, since a card under an answer already shows its own.
    func secondOpinionButton(_ session: ChatSession) -> some View {
        let installed = runner.catalog.availableAgents
        return Group {
            if let design = shownDesign(session) {
                let opinion = runner.designOpinions.opinion(design.id)
                SecondOpinionLineupButton(author: design.agent, installed: installed,
                                          canReview: hasOpinionSubject(session),
                                          proposal: {
                                              secondOpinion.headerProposal(session, screen: opinionScreen(session),
                                                                           runner: runner, gitStats: gitStats)
                                          },
                                          runs: opinion?.runs ?? [], status: opinion?.status ?? .ask,
                                          ask: { toggleHeaderAsk(session) },
                                          // The notes already sit in their panel beside the canvas.
                                          open: {})
            } else {
                let status = SecondOpinionStatus(reviews: runner.reviews, sessionID: session.id)
                SecondOpinionLineupButton(author: session.agent, installed: installed,
                                          canReview: hasOpinionSubject(session),
                                          proposal: {
                                              secondOpinion.headerProposal(session, screen: opinionScreen(session),
                                                                           runner: runner, gitStats: gitStats)
                                          },
                                          runs: runner.reviews.runs(session.id),
                                          status: status,
                                          ask: { toggleHeaderAsk(session) },
                                          open: { openHeaderRun(status) })
            }
        }
        .anchorsSecondOpinion { headerOpinionFrame = $0 }
    }

    // While the reviewers read, the control opens their lanes under it. Once there are
    // findings, it takes the person to them.
    private func openHeaderRun(_ status: SecondOpinionStatus) {
        switch status {
        case .reviewing, .failed, .settled(0, 0):
            secondOpinion.ask = nil
            secondOpinion.lanesOpen.toggle()
        case .ask, .ready, .settled:
            secondOpinion.lanesOpen = false
            tab = .changes
            changesNavigation.secondOpinionRequest = .open
        }
    }

    // A second click on the control puts its card away.
    private func toggleHeaderAsk(_ session: ChatSession) {
        if let ask = secondOpinion.ask, ask.anchor == nil {
            secondOpinion.close()
        } else {
            askForSecondOpinion(session)
        }
    }

    // The design on screen right now, whose notes the canvas shows.
    private func shownDesign(_ session: ChatSession) -> ChatSession? {
        let design = switch tab {
        case .design: store.designSession(for: session.id)
        case .conversation where session.isActivelyDesigning: session
        default: nil as ChatSession?
        }
        guard let design, hasDesignFiles(design, of: session) else { return nil }
        return design
    }

    private func reviewableDesign(_ session: ChatSession) -> ChatSession? {
        store.designConversation(for: session.id).flatMap { hasDesignFiles($0, of: session) ? $0 : nil }
    }

    private func hasOpinionSubject(_ session: ChatSession) -> Bool {
        SessionSecondOpinion.latestAnswer(in: session, state: runner.state(session.id)) != nil
            || workingTreeChanges(session) != nil || reviewableDesign(session) != nil
            || (tab == .changes && !store.workingDirectories(for: session).isEmpty)
            || store.workingDirectories(for: session).contains { root in
                changesNavigation.snapshots[root].map { $0.comparedToRemote && !$0.files.isEmpty } == true
            }
    }

    // What this pane has in view that an ask can start from.
    private func opinionScreen(_ session: ChatSession) -> SessionSecondOpinion.Screen {
        SessionSecondOpinion.Screen(selectedChange: tab == .changes ? selectedChange(session) : nil,
                                    design: reviewableDesign(session),
                                    showsDesign: shownDesign(session) != nil,
                                    compared: changesNavigation.snapshots,
                                    compareRefs: changesNavigation.compareRefs,
                                    headRoots: changesNavigation.lastCommitCompares,
                                    showsChanges: tab == .changes)
    }

    func askForSecondOpinion(_ session: ChatSession, on picked: ChatSecondOpinion.Subject? = nil,
                             anchor: UUID? = nil) {
        guard secondOpinion.open(session, on: picked, anchor: anchor,
                                 screen: opinionScreen(session), runner: runner, gitStats: gitStats)
        else { return }
        // Return should ask, not send whatever is in the composer.
        composerFocused = false
    }

    // The ask card and the lanes panel, hung off the controls that open them. A click
    // anywhere else puts them away, the way a menu goes.
    @ViewBuilder
    func opinionLayer(_ session: ChatSession) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if secondOpinion.ask != nil || secondOpinion.lanesOpen {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { secondOpinion.close() }
                        .accessibilityHidden(true)
                }
                if let ask = secondOpinion.ask {
                    let anchor = ask.anchor ?? headerOpinionFrame
                    opinionCard(ask, session: session, maxHeight: max(0, proxy.size.height - Space.md * 2))
                        .frame(width: min(SecondOpinionAskCard.width, max(0, proxy.size.width - Space.md * 2)))
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { opinionCardSize = $0 }
                        .offset(Self.place(opinionCardSize, under: anchor, in: proxy.size,
                                           trailing: ask.anchor == nil))
                        .transition(.popover(reduceMotion: reduceMotion))
                        .id(ask.id)
                }
                if secondOpinion.lanesOpen {
                    SecondOpinionLanesPanel(reviews: runner.reviews, sessionID: session.id,
                                            lookAt: {
                                                secondOpinion.close()
                                                tab = .changes
                                                changesNavigation.secondOpinionRequest = .open
                                            },
                                            close: { secondOpinion.close() })
                        .offset(Self.place(CGSize(width: SecondOpinionLanesPanel.width, height: 0),
                                           under: headerOpinionFrame, in: proxy.size, trailing: true))
                        .transition(.popover(reduceMotion: reduceMotion))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .motion(secondOpinion.ask == nil ? Motion.leave : Motion.arrive, value: secondOpinion.ask?.id)
        .motion(secondOpinion.lanesOpen ? Motion.arrive : Motion.leave, value: secondOpinion.lanesOpen)
    }

    // Under the control when the card fits there, over it when it does not, and always
    // inside the pane. From the header it lines up with the control's trailing edge, since
    // the control sits near the right of the window.
    static func place(_ size: CGSize, under anchor: CGRect, in bounds: CGSize, trailing: Bool) -> CGSize {
        let margin = Space.md
        var x = trailing ? anchor.maxX - size.width : anchor.minX - Space.sm
        x = min(max(margin, x), max(margin, bounds.width - size.width - margin))
        var y = anchor.maxY + Space.sm
        if y + size.height > bounds.height - margin {
            y = max(margin, anchor.minY - Space.sm - size.height)
        }
        return CGSize(width: x, height: y)
    }

    private func opinionCard(_ ask: SessionSecondOpinion.Ask, session: ChatSession, maxHeight: CGFloat) -> some View {
        let installed = runner.catalog.availableAgents
        let author = runner.author(of: session)
        let defaults = Preferences.secondOpinionDefaults()
        return SecondOpinionAskCard(
            facts: ask.facts,
            stop: Binding(get: { secondOpinion.ask?.stop ?? ask.stop }, set: { secondOpinion.ask?.stop = $0 }),
            author: author, installed: installed,
            running: Set(runner.reviews.runs(session.id).filter(\.isRunning).map(\.reviewer)),
            lineup: secondOpinion.lineup ?? defaults.lineup.filter { installed.contains($0.agent) },
            defaults: defaults,
            maxHeight: maxHeight,
            ask: { choice in
                secondOpinion.lineup = choice.lineup
                secondOpinion.close()
                startSecondOpinion(choice, ask: ask, session: session, installed: installed)
            },
            close: { secondOpinion.close() })
    }

    // The request is built and sent by the model. The page its results land on is opened
    // here, since the tabs are this pane's.
    private func startSecondOpinion(_ choice: SecondOpinionAskChoice, ask: SessionSecondOpinion.Ask,
                                    session: ChatSession, installed: [AgentKind]) {
        guard SessionSecondOpinion.start(choice, ask: ask, session: session,
                                         design: reviewableDesign(session), installed: installed,
                                         navigation: changesNavigation, runner: runner) else { return }
        switch choice.stop {
        case .answer, .conversation:
            if tab != .conversation { tab = .conversation }
        case .file, .sinceReview, .uncommitted, .branch:
            // The Changes screen starts the run; its progress shows on the header control.
            tab = .changes
        case .design:
            if shownDesign(session) == nil {
                tab = session.isActivelyDesigning ? .conversation : .design
            }
        }
    }

    // The file picked on the Changes screen.
    private func selectedChange(_ session: ChatSession) -> (root: String, path: String)? {
        let root = directory(for: selectedProjectID ?? session.projectID, in: session)
            ?? store.workingDirectories(for: session).first
        guard let root, let id = changesNavigation.selections[root]?.activeID,
              let file = (changesNavigation.snapshots[root] ?? gitStats.snapshot(at: root))?.files
                  .first(where: { $0.id == id }) else { return nil }
        return (root, file.path)
    }

    func opinionCard(_ opinion: ChatOpinion, session: ChatSession) -> some View {
        let pending = runner.question(sessionID).flatMap { SessionSecondOpinion.planID($0) == opinion.subject.id ? $0 : nil }
        let opinions = runner.opinions
        return ChatOpinionCard(
            opinion: opinion, authorTitle: session.agent.title, planPending: pending != nil,
            toggle: { opinions.toggle($0, of: opinion.id, in: sessionID) },
            send: {
                let names = Array(NSOrderedSet(array: opinion.lanes.map(\.reviewer.agent.title))) as? [String] ?? []
                let text = ChatSecondOpinion.feedback(opinion.ticked, subject: opinion.subject,
                                                      names: names.joined(separator: " and "))
                // A plan still waiting goes back as its answer, so the agent keeps
                // planning with the points in mind rather than being told no.
                if let pending {
                    runner.answer(pending, with: .revise(text), sessionID: sessionID)
                } else {
                    runner.send(text, sessionID: sessionID)
                }
                opinions.markSent(opinion.id, count: opinion.ticked.count, in: sessionID)
            },
            approve: {
                guard let pending else { return }
                runner.answer(pending, with: .allowOnce, sessionID: sessionID)
            },
            askAgain: {
                askForSecondOpinion(session, on: opinion.subject, anchor: opinion.anchor)
            },
            retry: { seat in
                guard let executable = runner.catalog.executable(for: seat.agent) else { return }
                opinions.retry(seat, of: opinion.id, executable: executable, in: sessionID)
            },
            stop: { opinions.stop($0, of: opinion.id, in: sessionID) },
            dismiss: { opinions.dismiss(opinion.id, in: sessionID) })
    }
}
