import AppKit
import SwiftUI

// The two decks at the top of the session pane: who the session is and what it is doing,
// then where to go and what to open beside it.
extension SessionView {
    // What the identity deck gives up to fit the pane. Nothing here drops an action: the
    // rail on the deck below is where every one of them lives.
    private enum HeaderFit {
        // The branch at the width a name deserves.
        case whole
        // The branch cut back to a stub.
        case folded
    }

    // The first deck stands taller than the second: it carries the identity tile and the
    // state pill, and it is the band a reader lands on first.
    private static let identityDeckHeight: CGFloat = 58

    // A 34pt tab needs a deck taller than a thin strip would be. The extra height buys
    // destinations that are readable without being pointed at.
    private static let destinationDeckHeight: CGFloat = 40

    // How much of the session title the row is fitted around. The title truncates by
    // design, so its full length says nothing about whether the rest fits; this is the
    // stub worth keeping, and the readings give way rather than cut into it.
    private static let titleRoom: CGFloat = 110

    // How wide the branch is allowed to grow on each fit.
    private static let branchRoom: CGFloat = 210

    private static let foldedBranchRoom: CGFloat = 130

    // The first deck names the session and says what it is doing: the container's icon
    // and name, the title it was given, then the state and the branch it is on.
    // Nothing on it navigates. Where to go is the deck under it, which
    // holds every destination and every panel this pane can open.
    func identityDeck(session: ChatSession, project: Project) -> some View {
        // The pane draws the first of these that fits. What the readings ask for is
        // measured rather than guessed at a width chosen in advance, so a longer branch
        // or a longer project name gives something up on its own instead of running off
        // the right edge of the pane.
        ViewThatFits(in: .horizontal) {
            identityRow(session: session, project: project, fit: .whole)
            identityRow(session: session, project: project, fit: .folded)
        }
    }

    private func identityRow(session: ChatSession, project: Project,
                             fit: HeaderFit) -> some View {
        let workspace = session.workspaceID.flatMap(store.workspace)
        let container = workspace?.name ?? project.name
        let context = session.usage?.contextFraction(for: session.agent)
        let tone = SessionTone(sessionID, store: store, runner: runner)
        return HStack(spacing: Space.md) {
            HStack(spacing: Space.md) {
                // These are only labels, so a click on them reaches the band under them,
                // which acts as the window's title bar.
                Group {
                    if let workspace {
                        SidebarIdentityTile(
                            avatar: workspace.sidebarAvatar,
                            name: workspace.name,
                            tint: Theme.workspaceTint,
                            stacked: true)
                    } else {
                        SidebarIdentityTile(
                            avatar: project.sidebarAvatar,
                            name: project.name,
                            tint: Theme.projectTint(for: project.name),
                            dashed: project.kind == .adHoc)
                    }
                    // The durable name reads as the heading, in the same family as everything
                    // else on the deck. It holds its width while there is any title left to
                    // give up, and is only cut short once the title is gone.
                    Text(container)
                        .font(Typography.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    Text("/")
                        .font(Typography.data)
                        .foregroundStyle(.tertiary)
                    if session.isTroubleshooting {
                        MonoChip(text: "TROUBLESHOOT", size: Typography.Size.micro, tint: Theme.secret)
                    }
                }
                .allowsHitTesting(false)
                SessionHeaderTitle(title: session.title, idealWidth: Self.titleRoom,
                                   draft: $titleDraft) { name in
                    store.renameSession(session.id, to: name)
                }
            }

            Spacer(minLength: 12)

            // A row splits its width between the children rather than handing each one
            // what it asks for, so the readings could be offered less than they need and
            // truncate. Holding them at their natural width makes the title give way.
            readings(session: session, fit: fit)
                .layoutPriority(1)
        }
        .padding(.horizontal, Space.xxl)
        // The window reading closes the band the same way the rule does, so it is drawn
        // with it and stays behind anything the band opens.
        .headerBand(height: Self.identityDeckHeight) {
            if let context {
                ContextHairline(fraction: context, animated: tone == .running)
            }
        }
    }

    // The session's state and branch as one pill, with the other details behind it.
    private func readings(session: ChatSession, fit: HeaderFit) -> some View {
        let facts = SessionFacts(
            session: session, snapshots: treeSnapshots(session),
            reviews: pullRequestReviews.loaded[session.id] ?? [],
            modelTitle: { runner.catalog.modelTitle($0) },
            showsCost: appSettings.showsCost(for: session.agent))
        let tone = SessionTone(sessionID, store: store, runner: runner)
        // The deck stands for both of a session's conversations, so a Design turn is what
        // it counts while Design is the side running.
        let live = LiveConversation.of(sessionID, store: store, runner: runner) ?? session
        return HStack(spacing: Space.md) {
            SessionAgentIndicator(session: session) { target in
                tab = .conversation
                previews.hide()
                transcriptWindow.reveal(target.messageID, in: session.messages)
                transcriptPinnedToBottom = false
                agentFocus = target
            }
            SessionFactsChip(
                facts: facts,
                state: sessionState(tone: tone, conversation: live,
                                    isTroubleshooting: session.isTroubleshooting),
                sessionID: session.id,
                repositoryCount: store.workingDirectories(for: session).count,
                maxWidth: fit == .whole ? Self.branchRoom : Self.foldedBranchRoom,
                showsBranch: tab != .changes,
                openChanges: openChanges,
                contextActions: contextActions,
                usageTooltip: {
                    guard let usage = session.usage else { return Tooltip(title: "") }
                    return usageTooltip(usage, agent: session.agent,
                                        clearable: !contextActions().isEmpty)
                },
                attachProject: session.workspaceID != nil
                    || store.project(session.projectID)?.kind == .project
                    ? { attachingProject = true } : nil,
                attachDisabled: runner.state(sessionID).isBusy || runner.isBeingRemoved(sessionID),
                showNote: { showRailNote($0) })
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // What the rail gives up as the pane narrows, in the order it is worth giving up:
    // words first, then the session's actions fold behind one button. The dock never
    // folds, since it holds the panels reached for most.
    private enum RailFit {
        case wide
        case medium
        case narrow
    }

    // The second deck: where to go on the left, what to open beside where you already are
    // on the right. The gap between the two stands in for a rule under the tabs.
    func destinationDeck(session: ChatSession, project: Project,
                                 recap: SessionRecap?, tabs: [HeaderTab]) -> some View {
        ViewThatFits(in: .horizontal) {
            destinationRow(session: session, project: project, recap: recap, tabs: tabs, fit: .wide)
            destinationRow(session: session, project: project, recap: recap, tabs: tabs, fit: .medium)
            destinationRow(session: session, project: project, recap: recap, tabs: tabs, fit: .narrow)
            // Even the folded rail can leave too little room for every tab label.
            destinationRow(session: session, project: project, recap: recap, tabs: tabs, fit: .narrow,
                           scrollsTabs: true)
        }
        .overlay(alignment: .topTrailing) {
            recapCard(recap)
        }
        .motion(recapState.isOpen ? Motion.reveal : Motion.leave, value: recapState.isOpen)
    }

    private func destinationRow(session: ChatSession, project: Project,
                                recap: SessionRecap?, tabs: [HeaderTab], fit: RailFit,
                                scrollsTabs: Bool = false) -> some View {
        HStack(spacing: Space.md) {
            HeaderTabDeck(tabs: tabs,
                          height: Self.destinationDeckHeight,
                          scrollable: scrollsTabs)
            Spacer(minLength: 12)
            rail(session: session, project: project, recap: recap, fit: fit)
        }
        // The deck's own tabs carry the inset that lines their words up with the name on
        // the band above; the rail's buttons carry theirs inside the glyph's seat.
        .padding(.leading, Space.md)
        .padding(.trailing, Space.lg)
        .headerBand(Theme.statusBand, height: Self.destinationDeckHeight)
    }

    // What the pane can open beside where you already are, then what the session itself
    // offers. The dock holds what is reached for most and never folds; the actions use
    // words, so the two groups read as different kinds of thing without a hover.
    private func rail(session: ChatSession, project: Project, recap: SessionRecap?,
                      fit: RailFit) -> some View {
        HStack(spacing: Space.md) {
            switch tab {
            case .changes where workingTreeChanges(session) != nil:
                askWholeChangeButton
                    .transition(.opacity)
            case .explorer:
                explorerActions
                    .transition(.opacity)
            default:
                EmptyView()
            }
            dock(session: session, project: project, showsWords: fit == .wide)
            if hasUtilities(session) {
                HeaderRailDivider()
                if fit == .narrow {
                    utilitiesOverflow(session: session, project: project)
                } else {
                    utilities(session: session, project: project, recap: recap,
                              showsWords: fit == .wide)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .motion(Motion.reveal, value: tab)
        .overlay(alignment: .topTrailing) {
            if let text = railNote.text {
                HeaderNote(icon: railNote.icon, text: text)
                    .offset(y: Self.destinationDeckHeight + 2)
                    .transition(reduceMotion
                                ? .opacity
                                : .opacity.combined(with: .offset(y: -6)))
            }
        }
        .motion(Motion.reveal, value: railNote.text)
    }

    // None of these sends you anywhere: they open something beside the pane and leave
    // what you were reading where it was. Keeping them off the tab deck is what gives the
    // gap between the two its meaning - inside the deck you choose where to be, outside
    // it you open something next to where you already are. Preview is the exception, as
    // it puts the running app in the conversation's place.
    //
    // The second opinion leads on every tab. It is the one seat that grows while it
    // works, and the rail keeps to the trailing edge, so the seats after it stay still.
    // Most panels open beside the chat, so only the chat has the whole dock. The terminal
    // opens under any tab, so it stays where files are being looked at.
    private func dock(session: ChatSession, project: Project, showsWords: Bool) -> some View {
        HeaderRailDock {
            secondOpinionButton(session)
            switch tab {
            case .conversation:
                previewSeat(session, showsWord: showsWords)
                    .transition(.opacity)
                terminalSeat(session: session, project: project, showsWord: showsWords)
                findSeat(session, showsWord: showsWords)
                    .transition(.opacity)
            case .design, .troubleshoot, .evidence, .changes, .explorer:
                terminalSeat(session: session, project: project, showsWord: showsWords)
            case .reviews:
                EmptyView()
            }
        }
    }

    // The glyph toggles the drawer; the other ways to reach a shell sit behind the
    // chevron, so the most common one is a single click.
    private func terminalSeat(session: ChatSession, project: Project,
                              showsWord: Bool) -> some View {
        let directory = session.worktreePath ?? project.path
        let terminalOpen = terminals.isOpen(terminalScope)
        return HeaderDockSeat(
            icon: "terminal",
            word: "Terminal",
            isOpen: terminalOpen,
            showsWord: showsWord,
            keys: keyBindings.keys(for: .terminal)?.parts ?? [],
            detail: "A shell under the pane, in this session's folder",
            options: .init(label: "Other ways to open a shell") {
                terminalOptions(isOpen: terminalOpen, directory: directory)
            }) {
                toggleTerminal(directory: directory)
            }
    }

    // A question about the whole change has no file or line to start from, so it is asked
    // from here, and its card hangs under this button over the diff.
    private var askWholeChangeButton: some View {
        let asking = changesNavigation.askingWholeChange
        let unread = !asking && WholeChangeThreads.hasUnreadAnswer(runner.reviews.questions(sessionID),
                                                                   seen: changesNavigation.wholeChangeSeen)
        return HeaderRailButton(icon: "questionmark.bubble",
                                state: asking ? .open : .rest,
                                badge: unread,
                                label: asking ? "Put away the questions" : "Ask about the whole change",
                                hint: asking ? "Esc does the same" : unread ? "An answer is waiting" : "Shift-? opens it here, over the diff") {
            if asking { changesNavigation.citation = nil }
            changesNavigation.setAskingWholeChange(!asking)
        }
        .motion(Motion.pop, value: unread)
        .onCentreChange { changesNavigation.askOrigin = $0 }
        .accessibilityAddTraits(asking ? .isSelected : [])
        .accessibilityValue(unread ? "An answer is waiting" : "")
        .accessibilityFocused($askButtonFocused)
        .onChange(of: asking) { _, open in
            if !open { askButtonFocused = true }
        }
    }

    // Find stays one click away. Everything else done to the tree sits behind the menu,
    // which is the only place those actions live.
    private var explorerActions: some View {
        HStack(spacing: Space.xxs) {
            HeaderRailButton(icon: "magnifyingglass", label: "Find files or text",
                             hint: "Shift twice for files, Ctrl+H for text") {
                explorerCommand = .find(nil)
            }
            HeaderRailMenuButton(icon: "ellipsis", label: "File actions",
                                 hint: "New, hidden files, collapse, refresh")
                .appMenu { explorerMenu }
        }
    }

    private var explorerMenu: [MenuEntry] {
        let open = explorerOpenFolders
        return [.item("New file", icon: "doc.badge.plus") { explorerCommand = .newFile },
                .item("New folder", icon: "folder.badge.plus") { explorerCommand = .newFolder },
                .separator,
                .item("Show hidden files", icon: explorerShowsHidden ? "eye" : "eye.slash",
                      checked: explorerShowsHidden) { explorerCommand = .toggleHidden },
                .item("Collapse folders", icon: "rectangle.compress.vertical",
                      detail: open == 0 ? "All closed" : "\(open) open",
                      disabled: open == 0) { explorerCommand = .collapseFolders },
                .item("Refresh files", icon: "arrow.clockwise") { explorerCommand = .refresh }]
    }

    private func terminalOptions(isOpen: Bool, directory: String) -> [MenuEntry] {
        terminalEntries(isOpen: isOpen,
                        toggle: { toggleTerminal(directory: directory) },
                        directory: directory,
                        note: { text, icon in showRailNote(text, icon: icon) })
            + [.separator,
               .item("Copy cd command", icon: "doc.on.doc",
                     subtitle: "cd \(directory.shellQuoted)", monospacedSubtitle: true) {
                   Pasteboard.copy("cd \(directory.shellQuoted)")
                   showRailNote("Copied the cd command")
               }]
    }

    // Find has nothing to search while a Design or a running app is on screen. It stays in
    // the dock, greyed out, so the seats beside it do not shift when either comes or goes.
    private func findSeat(_ session: ChatSession, showsWord: Bool) -> some View {
        let isOpen = tab == .conversation && transcriptFind.isPresented
        return HeaderDockSeat(icon: "magnifyingglass",
                              word: "Find",
                              isOpen: isOpen,
                              showsWord: showsWord,
                              keys: keyBindings.keys(for: .findInConversation)?.parts ?? [],
                              detail: "Search this conversation") {
            if isOpen {
                closeFind()
            } else {
                tab = .conversation
                transcriptFind.open(in: currentMessages)
                $findFocused.request()
            }
        }
        .disabled(session.isActivelyDesigning || previews.isOpen)
    }

    // Placed first: the rail keeps to the trailing edge, so the other seats do not move.
    // It shows before the agent links an app, so any address can be typed in, but stays
    // faint until there is an app to show.
    @ViewBuilder
    private func previewSeat(_ session: ChatSession, showsWord: Bool) -> some View {
        if !session.isActivelyDesigning && appSettings.shows(.preview) {
            let address = previews.selected.flatMap { $0.isBlank ? nil : $0.address }
                ?? linkedApp.address
            let isOpen = tab == .conversation && previews.isOpen
            let pages = previews.pages.count
            HeaderDockSeat(icon: "globe",
                           word: "Preview",
                           isOpen: isOpen,
                           count: pages > 1 ? pages : nil,
                           showsWord: showsWord,
                           detail: address.map { "The running app at \(LocalServerPreview.label(for: $0))" }
                               ?? "Open a running app by its address",
                           isDimmed: address == nil && previews.pages.isEmpty) {
                if isOpen {
                    closePreview()
                } else {
                    tab = .conversation
                    if !previews.pages.isEmpty {
                        previews.show()
                    } else if let address {
                        previews.open(address)
                    } else {
                        previews.openBlank()
                    }
                }
            }
        }
    }

    // Actions for the session as a whole stay together at the end of the rail.
    private func utilities(session: ChatSession, project: Project,
                           recap: SessionRecap?, showsWords: Bool) -> some View {
        HStack(spacing: Space.sm) {
            if let worktreePath = session.worktreePath, let app = WorktreeOpener.current {
                openInButton(path: worktreePath, app: app, showsWord: showsWords)
            }
            if showsDesignMaterialExport(session) {
                designMaterialExportButton(session: session, project: project)
            }
            if showsRecap {
                let recapping = runner.isRecapping(visibleConversationID)
                SessionRecapControl(
                    recap: recap,
                    regenerating: recapping,
                    canRegenerate: runner.canRecap(visibleConversationID),
                    isOpen: recapState.isOpen,
                    needsAttention: recapState.needsAttention,
                    toggle: toggleRecap)
            }
        }
    }

    // Says where the folder goes rather than showing a glyph that only ever meant Finder.
    // The chevron picks another app, and the pick is kept for next time.
    private func openInButton(path: String, app: WorktreeApp, showsWord: Bool) -> some View {
        HeaderSplitButton(
            image: WorktreeOpener.icon(for: app),
            word: "Open in \(app.name)",
            showsWord: showsWord,
            menuLabel: "Choose where to open",
            tooltip: {
                Tooltip(title: "Open worktree in \(app.name)", subtitle: path.abbreviatedPath)
            },
            action: { openWorktree(path, in: app) },
            refresh: { WorktreeOpener.refresh() },
            entries: { openInEntries(path: path, current: app) })
    }

    private func openInEntries(path: String, current: WorktreeApp) -> [MenuEntry] {
        WorktreeOpener.apps.map { app in
            .item(app.name, image: WorktreeOpener.icon(for: app), imageShape: .tile,
                  checked: app == current) {
                WorktreeOpener.choose(app)
                openWorktree(path, in: app)
            }
        } + [
            .separator,
            .item("Copy path", icon: "doc.on.doc") {
                Pasteboard.copy(path)
                showRailNote("Copied the worktree path")
            },
        ]
    }

    private func openWorktree(_ path: String, in app: WorktreeApp) {
        WorktreeOpener.open(path, in: app)
        showRailNote("Opened the worktree in \(app.name)")
    }

    // The same actions behind one button, for a window too narrow to hold the rail. The
    // utilities fold before the dock and the tab deck do: they are the group you reach
    // for least often, and the only one whose words survive being put in a menu.
    private func utilitiesOverflow(session: ChatSession, project: Project) -> some View {
        HeaderRailButton(icon: "ellipsis",
                         badge: recapState.needsAttention,
                         label: "More session actions")
            .appMenu(refreshOnOpen: { WorktreeOpener.refresh() }) {
                utilityEntries(session: session, project: project)
            }
    }

    private func utilityEntries(session: ChatSession, project: Project) -> [MenuEntry] {
        var entries: [MenuEntry] = []
        if let worktreePath = session.worktreePath, let current = WorktreeOpener.current {
            // Finder stays one click away whichever app was picked.
            var apps = [current]
            if current.bundleID != WorktreeOpener.finderID,
               let finder = WorktreeOpener.apps.first(where: { $0.bundleID == WorktreeOpener.finderID }) {
                apps.append(finder)
            }
            for app in apps {
                entries.append(.item("Open in \(app.name)", image: WorktreeOpener.icon(for: app),
                                     imageShape: .tile) {
                    openWorktree(worktreePath, in: app)
                })
            }
        }
        if showsDesignMaterialExport(session) {
            entries.append(.item("Export Design materials", icon: "doc.zipper") {
                exportDesignMaterials(session: session, project: project)
            })
        }
        if showsRecap {
            entries.append(.item("Session recap", icon: "lightbulb",
                                 showsUpdate: recapState.needsAttention, action: toggleRecap))
        }
        return entries
    }

    private func hasUtilities(_ session: ChatSession) -> Bool {
        (session.worktreePath != nil && WorktreeOpener.current != nil)
            || showsDesignMaterialExport(session) || showsRecap
    }

    // A design session is recapped through the conversation it belongs to, so what the
    // rail offers follows the transcript on screen rather than the session it was opened
    // from.
    private var showsRecap: Bool {
        store.session(visibleConversationID)?.hasAgentConversation == true
    }

    private func showsDesignMaterialExport(_ session: ChatSession) -> Bool {
        isDesignTabSelected(for: session) && hasDesignFiles(session, of: session)
    }

    // The card hangs off the rail rather than off the button that opens it: it is wider
    // than any of them, and the button it belongs to may have folded into the overflow.
    @ViewBuilder
    private func recapCard(_ recap: SessionRecap?) -> some View {
        if let recap, recapState.isOpen {
            SessionRecapView(
                recap: recap,
                regenerating: runner.isRecapping(visibleConversationID),
                regenerate: generateRecap,
                close: closeRecap)
                .padding(.trailing, Space.xxl)
                .offset(y: Self.destinationDeckHeight + 7)
                .transition(recapState.shown == .arrivingUnasked
                            ? .identity : .popover(reduceMotion: reduceMotion))
                .onAppear { recapState.landed() }
        }
    }

    // The deck in the order it is reached by ⌘1 through ⌘5: first what the agent is being
    // set to do, then what it did to the working tree.
    //
    // A session settles into one kind of work with its first prompt. A diagnosis takes
    // over the conversation, so its findings are read under its own name and Chat and
    // Design go. A chat or a design leaves no room for a diagnosis brief, so the
    // Troubleshoot form goes. A tab already open stays, so the pane is never left
    // without its tab.
    func headerTabs(for session: ChatSession) -> [HeaderTab] {
        if session.isTroubleshooting {
            var tabs = [HeaderTab(label: "Troubleshoot", icon: "stethoscope",
                                  selected: tab == .conversation) {
                tab = .conversation
            }]
            if tab == .design { tabs.append(designTab(session)) }
            tabs.append(evidenceTab(session))
            return tabs + trailingTabs(session)
        }
        var tabs: [HeaderTab] = [
            destination(session.isActivelyDesigning
                            ? "Design"
                            : (session.isImplementingDesign ? "Build" : "Chat"),
                        icon: "bubble.left.and.bubble.right",
                        value: .conversation)
        ]
        if session.isActivelyDesigning {
            tabs[0].hasContent = hasDesignFiles(session, of: session)
        } else {
            tabs.append(designTab(session))
        }
        let started = session.hasStarted || store.designSession(for: session.id)?.hasStarted == true
        if !started || tab == .troubleshoot {
            tabs.append(destination("Troubleshoot", icon: "stethoscope", value: .troubleshoot))
        }
        if tab == .evidence { tabs.append(evidenceTab(session)) }
        return tabs + trailingTabs(session)
    }

    private func evidenceTab(_ session: ChatSession) -> HeaderTab {
        var evidence = destination("Evidence", icon: "point.3.connected.trianglepath.dotted",
                                   value: .evidence)
        evidence.hasContent = TroubleshootEvidence.count(in: session.messages) > 0
        return evidence
    }

    private func designTab(_ session: ChatSession) -> HeaderTab {
        HeaderTab(
            label: "Design",
            icon: "paintbrush.pointed",
            selected: tab == .design,
            hasContent: hasDesignFiles(session, of: session),
            activate: { openDesign(for: session) })
    }

    private func trailingTabs(_ session: ChatSession) -> [HeaderTab] {
        var tabs = [changesTab(session)]
        tabs.append(destination("Explorer", icon: "folder", value: .explorer))
        // Reviews come from a pull request, so without one there is nothing to go to. A
        // tab already open stays, so the pane is never left without its tab.
        if !session.pullRequests.isEmpty || tab == .reviews {
            var reviewsTab = destination("Reviews", icon: "text.bubble", value: .reviews)
            let waiting = pullRequestReviews.waitingCount(session.id)
            reviewsTab.count = waiting > 0 ? waiting : nil
            tabs.append(reviewsTab)
        }
        return tabs
    }

    private func destination(_ label: String, icon: String, value: Tab) -> HeaderTab {
        HeaderTab(label: label, icon: icon, selected: tab == value) {
            tab = value
        }
    }

    private func changesTab(_ session: ChatSession) -> HeaderTab {
        var changes = destination("Changes", icon: "plusminus", value: .changes)
        let tree = workingTreeChanges(session)
        changes.hasContent = tree != nil
        // A file count of zero means git has not answered yet and the transcript's
        // running total is standing in.
        changes.lineCounts = tree.map {
            HeaderTabLineCounts(added: $0.added, removed: $0.removed, provisional: $0.files == 0)
        }
        return changes
    }

    private func designMaterialExportButton(session: ChatSession, project: Project) -> some View {
        let label = exportingDesignMaterials
            ? "Exporting Design materials"
            : "Export Design materials as a ZIP file"
        return HeaderRailButton(
            icon: exportingDesignMaterials ? "hourglass" : "doc.zipper",
            state: exportingDesignMaterials ? .working : .rest,
            label: label,
            action: exportingDesignMaterials
                ? nil
                : { exportDesignMaterials(session: session, project: project) })
    }

    private func exportDesignMaterials(session: ChatSession, project: Project) {
        guard let materialsURL = store.designFilesURL(for: session),
              store.hasDesignArtifacts(for: session) else {
            dialogs.show(.notice("Nothing to export yet",
                                 message: "Create a Design first, then export its HTML and supporting files."))
            return
        }

        guard let destination = FilePicker.saveFile(
            suggestedName: DesignMaterialExporter.suggestedFileName(
                projectName: project.name, sessionTitle: session.title),
            prompt: "Export",
            message: "Export the Design materials as a ZIP file.",
            types: [.zip]) else { return }

        exportingDesignMaterials = true
        Task {
            defer { exportingDesignMaterials = false }
            do {
                try await DesignMaterialExporter.export(
                    materialsAt: materialsURL, to: destination)
            } catch {
                dialogs.show(.notice("Could not export Design materials",
                                     message: error.localizedDescription))
            }
        }
    }

    private func generateRecap() {
        recapState.requested = runner.recap(visibleConversationID)
    }

    private func toggleRecap() {
        guard store.recap(for: sessionID) != nil else {
            generateRecap()
            return
        }
        withAnimation(reduceMotion ? nil : recapState.isOpen ? Motion.leave : Motion.reveal) {
            recapState.toggle()
        }
    }

    func closeRecap() {
        withAnimation(reduceMotion ? nil : Motion.leave) {
            recapState.close()
        }
    }

    // The percentage says how much of the window is in use but not where it went, and the
    // split is rarely what it looks like: cache reads run an order of magnitude ahead.
    private func usageTooltip(_ usage: SessionUsage, agent: AgentKind,
                              clearable: Bool) -> Tooltip {
        var rows: [Tooltip.Row] = []
        for (label, count) in [("Input", usage.inputTokens),
                               ("Output", usage.outputTokens),
                               ("Cache read", usage.cacheReadTokens),
                               ("Cache write", usage.cacheWriteTokens)] where count > 0 {
            rows.append(Tooltip.Row(label: label, value: formattedTokens(count)))
        }
        if usage.contextWindow > 0 {
            rows.append(Tooltip.Row(
                label: agent.asksPermissions ? "Context" : "Window",
                value: "\(formattedTokens(usage.contextTokens)) of \(formattedTokens(usage.contextWindow))"))
        }
        // Codex and Copilot report no cost, so a zero here means "unknown" rather than free.
        if appSettings.showsCost(for: agent), usage.costUSD > 0 {
            rows.append(Tooltip.Row(label: "Spent", value: Money.short(usage.costUSD)))
        }
        let turns = counted(usage.turns, "turn")
        let note = if !agent.asksPermissions {
            clearable
                ? "Current model window after the latest model call. \(agent.title) compacts it automatically as it fills. Click for options."
                : "Current model window after the latest model call. \(agent.title) compacts it automatically as it fills."
        } else {
            clearable
                ? "Context in use after the last turn. Click for options."
                : "Context in use after the last turn."
        }
        return Tooltip(title: "Session usage",
                       subtitle: usage.model(for: agent).map { "\($0) · \(turns)" } ?? turns,
                       note: note,
                       rows: rows)
    }
}
