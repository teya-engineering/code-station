import AppKit
import SwiftUI

// The conversation page: the transcript, what hangs under it, and the cards that stand
// in for a sent review.
extension SessionView {
    private func revealFindMatch(in session: ChatSession, proxy: ScrollViewProxy) async {
        guard let match = transcriptFind.currentMatch else { return }
        transcriptPinnedToBottom = false
        transcriptWindow.reveal(match.messageID, in: session.messages)
        await Task.yield()
        guard !Task.isCancelled else { return }
        proxy.scrollTo(match.messageID, anchor: .center)

        // Folded thinking opens on a later pass, and its text only joins the find once it
        // has been drawn, so the match is looked for again until it is there.
        var attempts = 0
        while !transcriptFind.currentIsFullyDrawn, attempts < 10 {
            attempts += 1
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
        }
        // Opening folded text animates its height, so the match is still moving.
        if attempts > 0 { try? await Task.sleep(for: .milliseconds(220)) }
        guard !Task.isCancelled, let placed = transcriptFind.placeCurrent() else { return }
        placed.view.revealCentered(placed.range)
    }

    @ViewBuilder
    func conversation(session: ChatSession, project: Project) -> some View {
        if previews.isOpen, let preview = previews.selected {
            previewPage(preview, session: session)
        } else {
            conversationContent(session: session, project: project)
        }
    }

    private func conversationContent(session: ChatSession, project: Project) -> some View {
        let blocked = !missingDirectories.isEmpty || !runner.catalog.isAvailable(session.agent)
        return VStack(spacing: 0) {
            if transcriptFind.isPresented {
                FindBar(placeholder: "Find in chat",
                        query: Binding(get: { transcriptFind.query },
                                       set: { transcriptFind.search($0, in: session.messages) }),
                        summary: transcriptFind.summary,
                        hasMatches: !transcriptFind.result.matches.isEmpty,
                        focused: $findFocused,
                        move: { transcriptFind.move(by: $0) },
                        close: closeFind)
                    // The field must be fully visible as soon as it takes focus.
                    .transition(.identity)
            }
            transcript(session, replies: !blocked)
            Divider().overlay(Theme.hairline)
            composer(session: session, project: project, blocked: blocked)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileDrop(enabled: !blocked, isTargeted: $fileDragOver) { dropped in
            runner.composer.attach(dropped, to: sessionID)
            composerFocused = true
        }
    }

    // Reply is offered only while the composer can take the quote and send it.
    private func transcript(_ session: ChatSession, replies: Bool) -> some View {
        let state = runner.state(sessionID)
        let projectPath = store.workingDirectory(for: session) ?? ""
        let shape = transcriptShape(session, state: state)
        let replyAction = replies ? TranscriptReply(sessionID: sessionID) { reply($0) } : nil

        return ScrollViewReader { proxy in
            ScrollView {
                let visibleMessages = transcriptWindow.visibleMessages(in: session.messages)
                transcriptContent(session, messages: visibleMessages, state: state,
                                  projectPath: projectPath) {
                    transcriptWindow.loadEarlier(totalCount: session.messages.count)
                    // Land on the oldest message the page just added, so the reader
                    // starts at the beginning of what they asked for and reads forward
                    // into what they had already.
                    guard let earliestID = transcriptWindow
                        .visibleMessages(in: session.messages).first?.id else { return }
                    Task {
                        await Task.yield()
                        proxy.scrollTo(earliestID, anchor: .top)
                    }
                }
                    .environment(\.transcriptSelection, transcriptSelection)
                    .environment(\.transcriptFind, transcriptFind)
                    .environment(\.transcriptReply, replyAction)
                    .environment(\.explorerRoots, explorerRoots(for: session))
                    .environment(\.switchAgentBack, switchAgentBack)
                    .padding(.horizontal, Space.xxxl)
                    .padding(.vertical, Space.xxl)
                    // Capped so prose keeps a readable line length, and centered so a
                    // wide window pads both sides instead of piling space on the right.
                    // Wider than a chat app's usual measure: diffs and tool output make
                    // better use of the room than paragraphs do.
                    .frame(maxWidth: 960, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    // Include the padding so the scroll target is the actual bottom.
                    .id(bottomAnchor)
                    .background {
                        TranscriptScrollObserver(pinnedToBottom: transcriptPinnedToBottom) { isAtBottom in
                            transcriptPinnedToBottom = isAtBottom
                        }
                    }
                    // Sits outside the padding so the margins count as page too: a press
                    // beside a paragraph puts the selection away just as one below it does.
                    .background(TranscriptSelectionClearing(selection: transcriptSelection))
                    // Message rows can settle after the first scroll when text wraps or
                    // an attachment gets its final size. Keep an opening transcript at
                    // its real end, then respect manual scrolling once it is visible.
                    .background(GeometryReader { geometry in
                        Color.clear.onChange(of: geometry.size.height, initial: true) {
                            guard (!opened && agentFocus == nil) || transcriptPinnedToBottom else { return }
                            Task { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
                        }
                    })
                    // The soft landing for anything new: a fresh row fades in and the
                    // rows above it glide up rather than jumping. Keyed on the shape of
                    // the transcript, not its text, so it plays once per whole arrival
                    // and never while a line is still being typed into.
                    .motion(Motion.reveal, value: shape.settled)
            }
            // Opening a transcript starts at the end, where the conversation is.
            .defaultScrollAnchor(.bottom)
            // The pane changes height under a transcript that is already there: the
            // composer grows a line, the terminal drawer opens, the window is resized.
            // The end of the content moves with it while the scroll view keeps its offset,
            // so a pinned transcript must be sent to the bottom again.
            .background(GeometryReader { geometry in
                Color.clear.onChange(of: geometry.size.height, initial: true) {
                    guard transcriptPinnedToBottom else { return }
                    Task { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
                }
            })
            // Held back until the scroll has landed, so the conversation arrives already
            // at its end instead of appearing and then jumping there.
            .opacity(opened ? 1 : 0)
            .accessibilityHidden(!opened)
            .onAppear {
                _ = handoffArrival.observe(runner.lastTurnEnding(sessionID), visible: false)
            }
            .onDisappear { arrivingEnding = nil }
            .onChange(of: runner.lastTurnEnding(sessionID)) { _, ending in
                guard handoffArrival.observe(ending, visible: opened && transcriptPinnedToBottom),
                      let ending, !runner.state(sessionID).isBusy,
                      let receipt = TurnReceipt(lastTurnIn: session.messages, projectPath: projectPath)
                else { return }
                arrivingEnding = ending.ended
                NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                    userInfo: [.announcement: receipt.spokenSummary(ending),
                               .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
            .task(id: sessionID) {
                if agentFocus == nil {
                    transcriptWindow.reset()
                    transcriptPinnedToBottom = true
                }
                // The conversation is read off the main actor, so the pane is on screen
                // before the messages are. Waiting here is what keeps that off screen:
                // it fades in once, already full and already at its end, rather than
                // arriving empty and filling in.
                await store.transcriptReady(sessionID)
                await Task.yield()
                if let agentFocus {
                    transcriptWindow.reveal(agentFocus.messageID, in: session.messages)
                    await Task.yield()
                    proxy.scrollTo(agentFocus.anchor, anchor: .top)
                } else {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
                withAnimation(reduceMotion ? nil : Motion.reveal) { opened = true }
            }
            .task(id: transcriptFind.jumpRequest) {
                await revealFindMatch(in: session, proxy: proxy)
            }
            .task(id: agentFocus?.requestID) {
                guard opened, let agentFocus else { return }
                // A tool anchor does not exist until its lazy message row is on screen.
                proxy.scrollTo(agentFocus.messageID, anchor: .top)
                await Task.yield()
                guard !Task.isCancelled else { return }
                if !TranscriptScrollTargetView.reveal(agentFocus.anchor) {
                    proxy.scrollTo(agentFocus.anchor, anchor: .top)
                }
            }
            // Anything new sends a pinned transcript to its end. A whole arrival - a row,
            // a finished line, a change of state - is worth a glide. A long line still
            // being typed into is followed in coarse chunks, each without one, so streaming
            // tokens do not each perform another scroll operation.
            .onChange(of: shape) { old, new in
                if new.state != old.state, new.state != .waiting { waitNoticeDismissed = false }
                scrollToBottom(proxy, animated: old.settled != new.settled)
            }
            .task(id: transcriptScrollRequest) {
                guard transcriptScrollRequest > 0 else { return }
                // The prompt and composer must finish updating before the scroll lands.
                await Task.yield()
                guard !Task.isCancelled else { return }
                scrollToBottom(proxy, animated: true)
            }
        }
    }

    // Not lazy, deliberately. A lazy stack decides what to build from where the scroll
    // view is looking, and when that offset stops being a valid one - the pane resizing
    // under a transcript sitting at the bottom, a message landing as the bottom anchor
    // is re-applied - it builds nothing at all and the transcript goes blank until it
    // is scrolled by hand. A turn is a handful of rows, and the tool rows inside one
    // are built eagerly anyway. Bounding the eager stack keeps large transcripts cheap
    // without bringing back the blank-pane bug, and keeps an opened tool card alive while
    // it remains in the loaded window.
    private func transcriptContent(_ session: ChatSession,
                                   messages: ArraySlice<ChatMessage>,
                                   state: SessionState, projectPath: String,
                                   loadEarlier: @escaping () -> Void) -> some View {
        let bubble = appSettings.userMessageStyle(for: session, in: store)
        let reviewRounds = runner.reviews.sentReviews(in: session.messages, sessionID: sessionID)
        let lineup = SecondOpinionLineup.reviewers(installed: runner.catalog.availableAgents,
                                                   author: session.agent)
        return VStack(alignment: .leading, spacing: Space.xl) {
            // Only for a session that has nothing to say yet, never for one whose
            // conversation is still being read in.
            if session.messages.isEmpty, !store.isTranscriptLoading(sessionID) {
                Text("Ask for a change. \(session.agent.title) runs in the project folder, so what it edits is your working tree.")
                    .font(Typography.body)
                    .foregroundStyle(.secondary)
                    .padding(.top, Space.md)
            }

            let hiddenCount = transcriptWindow.hiddenCount(totalCount: session.messages.count)
            if hiddenCount > 0 {
                LoadEarlierMessages(hiddenCount: hiddenCount, action: loadEarlier)
            }

            ForEach(messages) { message in
                if let round = reviewRounds.cards[message.id] {
                    reviewCard(round, session: session, working: state.isBusy, projectPath: projectPath)
                        .transition(.fadeIn)
                } else if !reviewRounds.hidden.contains(message.id) {
                MessageView(message: reviewRounds.cuts[message.id].map { message.cut(at: $0) } ?? message,
                            projectPath: projectPath,
                            textScale: appSettings.textSize.scale,
                            openChange: { path in
                                openChange(path, root: projectPath)
                            },
                            runInShell: { command in
                                runInShell(command, directory: projectPath)
                            },
                            showInExplorer: showInExplorer,
                            openPreview: openPreview,
                            promptMenu: promptMenu(for: message),
                            arriving: message.isArriving(sentAt: promptSentAt),
                            bubble: bubble,
                            timestamps: appSettings.transcriptTimestamps,
                            secondOpinion: SessionSecondOpinion.canJudge(message, in: session, state: state) ? { @MainActor in
                                askForSecondOpinion(session,
                                                    on: SessionSecondOpinion.answerSubject(message, in: session),
                                                    anchor: message.id)
                            } : nil,
                            showsFileReferences: !(state.isBusy && message.id == messages.last?.id))
                    // Every message is on screen now, and a streaming turn rewrites
                    // the last one many times a second. Without this, each of those
                    // redraws every message in the transcript, parsing its markdown
                    // again on the way.
                    .equatable()
                    .subjectRail(secondOpinion.railShows(message))
                    .environment(\.runningAgents, runner.runningAgents(sessionID))
                    .environment(\.previewsLocalServers, true)
                    .environment(\.activeTranscriptTools, runner.runningTools(sessionID))
                    .environment(\.agentTranscriptFocus, agentFocus)
                    .environment(\.askAgent, askAgent)
                    .transition(.fadeIn)
                }
                ForEach(opinions(after: message.id)) { opinion in
                    opinionCard(opinion, session: session)
                        .transition(.fadeIn)
                }
            }

            if !state.isBusy, let ending = runner.lastTurnEnding(sessionID),
               let receipt = TurnReceipt(lastTurnIn: session.messages, projectPath: projectPath) {
                TurnSeal(ending: ending, receipt: receipt,
                         reviewed: reviewedEnding == ending.ended,
                         arriving: arrivingEnding == ending.ended,
                         focusReview: focusHandoffReview,
                         review: runner.question(sessionID) == nil ? {
                             reviewingEnding = ending.ended
                             focusHandoffReview = false
                             Task { await openTurnChanges(ending, in: session) }
                         } : nil)
                    .id(ending.ended)
                    .transition(.identity)
            } else if runner.lastTurnEnding(sessionID) == nil {
                handoff(state: state)
            }

            pendingQuestion(projectPath: projectPath)
                .transition(.fadeIn)

            if showsThinking(state: state) {
                WorkingRow(since: runner.lastActivity(sessionID) ?? Date(),
                           sessionID: sessionID,
                           avatarName: session.agentAvatarName,
                           agentTitle: session.agent.title,
                           spinnerVerbs: runner.spinnerVerbs(sessionID),
                           completionActivity: runner.completionActivity(sessionID),
                           tasks: runner.backgroundTasks(sessionID),
                           waitingSince: runner.waitingSince(sessionID))
                    .transition(.fadeIn)
            }

            if state == .waiting, !waitNoticeDismissed,
               let waitingSince = runner.waitingSince(sessionID) {
                WaitingNotice(since: waitingSince,
                              tasks: runner.backgroundTasks(sessionID),
                              agentTitle: session.agent.title,
                              command: { session.shellCommand(for: $0) },
                              onKeepWaiting: {
                                  withAnimation(reduceMotion ? nil : Motion.leave) {
                                      waitNoticeDismissed = true
                                  }
                              },
                              onEnd: { runner.endWait(sessionID) })
                    .transition(dismissal)
            }

            if case .reconnecting(let message) = state {
                HStack(alignment: .top, spacing: Space.md) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text("Codex is reconnecting")
                            .fontWeight(.semibold)
                        Text(message)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .warningCard()
            }

            if state == .stalled {
                VStack(alignment: .leading, spacing: Space.md) {
                    HStack(alignment: .top, spacing: Space.md) {
                        Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            Text("Codex has stopped responding")
                                .fontWeight(.semibold)
                            Text("There has been no output for five minutes, with no command, question, or background task in progress. "
                                + "You can keep waiting, stop the turn, or retry it safely.")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: Space.md) {
                        Spacer(minLength: 0)
                        ActionButton(title: "Stop", tone: .outlined,
                                     height: ControlHeight.md, size: Typography.Size.detail) {
                            runner.stop(sessionID)
                        }
                        if runner.canRetryStalled(sessionID) {
                            ActionButton(title: "Retry turn", height: ControlHeight.md, size: Typography.Size.detail) {
                                runner.retryStalled(sessionID)
                            }
                        }
                    }
                }
                .warningCard()
            }

            TurnEndActions(sessionID: sessionID, agent: session.agent, state: state)
        }
        .environment(\.secondOpinionLineup, lineup)
        .modifier(SentPromptCommands(agent: session.agent,
                                     workingDirectories: store.workingDirectories(for: session),
                                     latestPromptID: session.messages.last(where: { $0.role == .user })?.id))
    }

    // What to do with what the turn left behind. It sits at the end of the conversation
    // because that is where the decision is made, and only once the agent has stopped:
    // reviewing a tree that is still being written to is not a review.
    @ViewBuilder private func handoff(state: SessionState) -> some View {
        let hasChanges = store.session(sessionID).map { session in
            store.workingDirectories(for: session)
                .compactMap { gitStats.snapshot(at: $0) }
                .contains { !$0.files.isEmpty }
        } ?? false
        if hasChanges, !state.isBusy, runner.question(sessionID) == nil {
            HStack(spacing: Space.md) {
                ActionButton(title: "Review changes") {
                    openChanges()
                }
                Spacer(minLength: 0)
            }
            .transition(.fadeIn)
        }
    }

    private func reviewCard(_ round: ReviewRound, session: ChatSession, working: Bool,
                            projectPath: String) -> some View {
        let installed = runner.catalog.availableAgents
        let checker = installed.first { $0 != session.agent } ?? installed.first
        let reviews = runner.reviews
        let directories = store.workingDirectories(for: session)
        let names = Dictionary(directories.map { ($0, ($0 as NSString).lastPathComponent) },
                               uniquingKeysWith: { first, _ in first })
        return ReviewCard(
            round: round, agent: session.agent, working: working, checker: checker,
            projectPath: projectPath, textScale: appSettings.textSize.scale,
            fileName: { ($0.path as NSString).lastPathComponent },
            openInChanges: {
                changesNavigation.showingHistory = false
                openChanges()
            },
            reply: { comment, text in
                Task {
                    guard let prompt = await reviews.reply(text, to: comment.id, round: round.id, in: sessionID,
                                                           projectNames: names) else { return }
                    runner.send(prompt, sessionID: sessionID)
                }
            },
            resolve: { reviews.resolve($0.id, round: round.id, in: sessionID) },
            reopen: { reviews.reopen($0.id, round: round.id, in: sessionID) },
            showInDiff: { comment in
                reviews.markRead(comment.id, in: sessionID)
                changesNavigation.showingHistory = false
                changesNavigation.focusedComment = comment.id
                openChange(comment.path, root: comment.root)
            },
            reviewWhatChanged: openChanges,
            checkFixes: {
                guard SessionSecondOpinion.checkFixes(round, checker: checker, session: session,
                                                      runner: runner) else { return }
                changesNavigation.showingHistory = false
                openChanges()
            })
            // Answers read here are read: the thread is open in front of the person.
            .onChange(of: round.unread, initial: true) { _, unread in
                for id in unread { reviews.markRead(id, in: sessionID) }
            }
            // A round whose turn ended while nothing was watching, or before the app was
            // last quit, is settled as soon as it is seen.
            .task(id: "\(round.id)-\(working)") {
                guard !working, !round.isSettled else { return }
                let reply = store.session(sessionID).flatMap { ReviewAnswers.reply(to: round.prompt, in: $0.messages) }
                await reviews.turnEnded(sessionID, prompt: round.prompt, reply: reply)
            }
    }

    // A turn that committed its work leaves nothing in the working tree, so its review is
    // the range of commits it made instead. Uncommitted work anywhere keeps the review on
    // the working tree, where it can be commented on and committed.
    private func openTurnChanges(_ ending: TurnEnding, in session: ChatSession) async {
        let committed = await GitInspector.turnCommits(roots: store.workingDirectories(for: session),
                                                       startHeads: ending.startHeads)
        guard reviewingEnding == ending.ended else { return }
        guard let committed else {
            changesNavigation.showingHistory = false
            openChanges()
            return
        }
        let history = changesNavigation.history(for: committed.root)
        history.select(committed.head)
        history.parent = committed.start
        changesNavigation.showingHistory = true
        selectWorkspaceRoot(committed.root, in: session)
        openChanges()
    }

    // The picked-out text goes into the draft as a quote and the caret waits below it,
    // so the answer to it is the next thing typed.
    private func reply(_ text: String) {
        runner.composer.editDraft(sessionID) { $0.text = ReplyQuote.appending(text, to: $0.text) }
        transcriptSelection.clear()
        composerFocused = true
    }

    private func previewPage(_ preview: LocalServerPreview, session: ChatSession) -> some View {
        let projectPath = store.workingDirectory(for: session) ?? ""
        return LocalServerPreviewPage(previews: previews, preview: preview, session: session,
                                      placeholder: placeholder(state: runner.state(sessionID), agent: session.agent),
                                      openPreview: openPreview,
                                      openChange: { path in
                                          openChange(path, root: projectPath)
                                      },
                                      runInShell: { command in
                                          runInShell(command, directory: projectPath)
                                      },
                                      showInExplorer: showInExplorer,
                                      pageFocused: $previewFocused,
                                      addressFocused: $previewAddressFocused,
                                      onClose: closePreview)
            .environment(\.explorerRoots, explorerRoots(for: session))
    }

    // The right-click menu on one of the user's own prompts. Only prompts that recorded
    // a checkpoint have one - they are the points the conversation can go back to. The
    // entries are built when the menu opens, so a turn starting or ending in the
    // meantime is reflected.
    private func promptMenu(for message: ChatMessage) -> (() -> [MenuEntry])? {
        guard message.role == .user, message.checkpoint != nil else { return nil }
        let store = store
        let runner = runner
        let sessionID = sessionID
        return {
            var actions: [MenuEntry] = []
            if runner.canRewind(to: message.id, sessionID: sessionID) {
                actions.append(.item(
                    "Rewind to here",
                    icon: "arrow.uturn.backward",
                    subtitle: "Discards this prompt and everything after it. The prompt returns to the composer.") {
                    runner.rewind(to: message.id, sessionID: sessionID)
                })
            }
            if store.canForkSession(sessionID, before: message.id) {
                actions.append(.item(
                    "Fork from here",
                    icon: "arrow.triangle.branch",
                    subtitle: "Starts a new session that carries the conversation up to this point.") {
                    guard let fork = store.forkSession(sessionID, before: message.id) else { return }
                    runner.composer.editDraft(fork.id) { draft in
                        draft.text = message.text
                        draft.attachments = (message.attachments ?? []).map {
                            Attachment(url: URL(fileURLWithPath: $0))
                        }
                    }
                })
            }
            let copy = MenuEntry.item("Copy prompt", icon: "doc.on.doc") {
                Pasteboard.copy(message.text)
            }
            guard !actions.isEmpty else { return [copy] }
            return actions + [.separator, copy]
        }
    }

    // Whatever the agent is waiting on sits under the transcript, where the next thing to
    // happen belongs. The turn is parked until it is answered.
    @ViewBuilder private func pendingQuestion(projectPath: String) -> some View {
        if let request = runner.question(sessionID) {
            let session = store.session(sessionID)
            PermissionCard(request: request,
                           workingDirectories: session.map(store.workingDirectories(for:)) ?? [],
                           projectPath: projectPath,
                           secondOpinion: session.map { session in
                               { askForSecondOpinion(session, on: SessionSecondOpinion.planSubject(request, in: session),
                                                     anchor: session.messages.last(where: { !$0.isEmpty })?.id) }
                           }) { answer in
                runner.answer(request, with: answer, sessionID: sessionID)
            }
            .subjectRail(secondOpinion.ask?.stop == .answer
                         && secondOpinion.ask?.chatSubject?.id == SessionSecondOpinion.planID(request))
            .id(request.id)
            if let session, let opinion = runner.opinions.opinion(on: SessionSecondOpinion.planID(request),
                                                                 in: sessionID) {
                opinionCard(opinion, session: session)
                    .transition(.fadeIn)
            }
        }
    }

    // A running turn shows the row for as long as it runs, whatever the transcript looks
    // like. A message holds what the model said and the calls it then made, so anything
    // keyed off its text goes dark the moment the model speaks and stays dark for the rest
    // of the turn - which is also when the silence counter is worth the most.
    private func showsThinking(state: SessionState) -> Bool {
        // A parked turn is waiting on the person, not working.
        return switch state {
        case .reconnecting, .stalled:
            false
        default:
            state.isBusy && runner.question(sessionID) == nil
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard transcriptPinnedToBottom else { return }
        // Animating every streamed token makes the transcript jitter, so only whole
        // arrivals - a message, a tool row, a finished line - are worth animating.
        if animated, !reduceMotion {
            withAnimation(Motion.reveal, completionCriteria: .removed) {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            } completion: {
                // The composer and rows can change size while the scroll is moving.
                guard transcriptPinnedToBottom else { return }
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
    }

    // What the transcript is made of, coarsely: how many rows there are, how many lines
    // the streaming message has settled, and the state around them. Tokens landing inside
    // a line change the text but not this, which is what keeps the animation to one beat
    // per addition. The chunk count is the one part that moves with the text, in coarse
    // steps, so a long line can be followed without every token asking for a scroll.
    private struct TranscriptShape: Equatable {
        var messages: Int
        var tools: Int
        var thoughts: Int
        var lines: Int
        var state: SessionState
        var question: String?
        var chunks: Int

        // The shape with the chunk count set aside: what has changed when something whole
        // arrives, and what the transcript's animation is keyed on.
        var settled: TranscriptShape {
            var shape = self
            shape.chunks = 0
            return shape
        }
    }

    private func transcriptShape(_ session: ChatSession, state: SessionState) -> TranscriptShape {
        let text = session.messages.last?.text ?? ""
        return TranscriptShape(messages: session.messages.count,
                               tools: session.messages.last?.tools.count ?? 0,
                               thoughts: session.messages.last?.thinking?.count ?? 0,
                               lines: newlineCount(text),
                               state: state,
                               question: runner.question(sessionID)?.id,
                               chunks: text.utf8.count / 120)
    }

    private func newlineCount(_ text: String) -> Int {
        var count = 0
        for byte in text.utf8 where byte == UInt8(ascii: "\n") { count += 1 }
        return count
    }
}

extension SessionView {
    // The way back from an agent switch marker. It reviews the switch like any other, and
    // is held while a turn runs for the same reason the agent chip is.
    var switchAgentBack: SwitchAgentBack {
        SwitchAgentBack(available: !runner.state(sessionID).isBusy) { [store, runner, dialogs, sessionID] agent in
            AgentSwitchDialog.open(agent, in: sessionID, store: store, runner: runner, dialogs: dialogs)
        }
    }
}

struct SwitchAgentBack {
    let available: Bool
    let action: @MainActor (AgentKind) -> Void
}

extension EnvironmentValues {
    @Entry var switchAgentBack: SwitchAgentBack? = nil
}
