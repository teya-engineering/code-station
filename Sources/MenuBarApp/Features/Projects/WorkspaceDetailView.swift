import AppKit
import SwiftUI

// One multi-project conversation. The structure carries the meaning: the lead project is
// the working directory and the others are indented under it, so nothing has to say in
// words which folder the agent will actually run in.
struct WorkspaceDetailView: View {
    let workspaceID: UUID

    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(TerminalStore.self) private var terminals
    @Environment(WorkingTreeWatch.self) private var workingTrees
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var creatingSession: ProjectWorkspace?
    @State private var terminalFocused = false
    // How each repository's checkout relates to the default branch and its remote, so
    // the rows can say which projects are on main and up to date. Filled in two passes:
    // the local refs first, then the same read again after a fetch.
    @State private var freshness: [UUID: GitFreshness.Report] = [:]
    // The repositories a requested fix - a branch switch, a pull - is still moving.
    // Their chips show the work instead of a verdict that is about to change.
    @State private var updating: Set<UUID> = []
    // The project row under the pointer. Only one row can be hovered, so the id is
    // enough and each row does not need state of its own.
    @State private var hoveredProjectID: UUID?
    @State private var note: String?
    @State private var notes = 0

    private var terminalScope: TerminalScope { .workspace(workspaceID) }

    var body: some View {
        if let workspace = store.workspace(workspaceID) {
            VStack(spacing: 0) {
                header(workspace)
                statusStrip(workspace)
                content(workspace)
                if terminals.isOpen(terminalScope), let lead = store.project(workspace.leadProjectID) {
                    TerminalDrawer(scope: terminalScope,
                                   directory: lead.path,
                                   focusTerminal: $terminalFocused)
                        .transition(.drawer(from: .bottom, reduceMotion: reduceMotion))
                }
            }
            .background(Theme.background)
            .overlay(alignment: .topTrailing) {
                ZStack {
                    if let note {
                        HeaderNote(icon: "arrow.up.forward.app", text: note)
                            .padding(.top, Theme.headerHeight + 8).padding(.trailing, Space.xxxl)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -6)))
                    }
                }
                .motion(Motion.reveal, value: note)
            }
            .task(id: workspace.projectIDs) { await checkFreshness(workspace) }
            .task(id: workspace.projectIDs) { await watchWorkingTrees(workspace) }
            .sheet(item: $creatingSession) { workspace in
                NewWorkspaceSessionView(workspace: workspace) { choice in
                    startSession(choice, in: workspace)
                }
                .appOverlays()
            }
        } else {
            PaneMessage(icon: "square.stack.3d.up.slash",
                        title: "This workspace is gone",
                        detail: "Choose another workspace or project from the sidebar.")
        }
    }

    // MARK: - Header

    // The same two rows every screen has: the name on its own up here, and what the
    // workspace is in - which folder the agent runs in, how its checkouts are doing -
    // on the strip under it.
    private func header(_ workspace: ProjectWorkspace) -> some View {
        HStack(spacing: Space.lg) {
            Button { store.changeSidebarAvatar(forWorkspace: workspace.id) } label: {
                SidebarIdentityTile(
                    avatar: workspace.sidebarAvatar,
                    name: workspace.name,
                    tint: Theme.workspaceTint,
                    stacked: true)
                    .contentShape(RoundedRectangle(cornerRadius: Radius.control))
            }
            .buttonStyle(.plain)
            .hoverLift(amount: Motion.smallLift)
            .accessibilityLabel("Change \(workspace.name) icon")
            .appTooltip("Change icon")

            // The title only reads the name. Renaming lives in the sidebar row's
            // context menu, the same place projects and sessions are renamed.
            Text(workspace.name)
                .font(Typography.title)
                .lineLimit(1)

            Spacer(minLength: 12)

            HStack(spacing: Space.lg) {
                // Both shells land in the lead project, the same folder the drawer uses.
                TerminalToggle(isOpen: terminals.isOpen(terminalScope),
                               directory: store.project(workspace.leadProjectID)?.path ?? "") {
                    toggleTerminal(workspace)
                }
                .disabled(hasMissingProjects(workspace))
                .environment(\.showExternalNote, ExternalNote { text, _ in showNote(text) })
                .opacity(hasMissingProjects(workspace) ? 0.4 : 1)

                ActionButton(title: "New session", tone: .green, size: Typography.Size.detail) {
                    creatingSession = workspace
                }
                .disabled(hasMissingProjects(workspace))
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
        .padding(.horizontal, Space.xxxl)
        .headerBand()
    }

    // MARK: - Status strip

    // What a workspace is, in the order the questions come: how many repositories it
    // groups, which of them the agent actually runs in, and whether those checkouts are
    // where they should be. The verdict is the same one the rows below wear, gathered
    // into a single word so the page does not have to be scanned to learn that one
    // repository has drifted.
    //
    // Every reading here keeps its full width, so together they can be wider than the
    // window. When they do not fit, the strip drops readings from the right instead of
    // pushing the page wider than the window. What it drops is also on the rows
    // below: each row has its own chips and a Reveal in Finder item in its menu.
    private func statusStrip(_ workspace: ProjectWorkspace) -> some View {
        let lead = store.project(workspace.leadProjectID)
        return ViewThatFits(in: .horizontal) {
            statusReadings(workspace, lead: lead, verdicts: true, revealLink: true)
            statusReadings(workspace, lead: lead, verdicts: true, revealLink: false)
            statusReadings(workspace, lead: lead, verdicts: false, revealLink: false)
        }
        .statusBand(padding: 24)
    }

    private func statusReadings(_ workspace: ProjectWorkspace, lead: Project?,
                                verdicts: Bool, revealLink: Bool) -> some View {
        HStack(spacing: Space.lg) {
            StatusCaps(text: "WORKSPACE · \(workspace.projectIDs.count) PROJECTS",
                       tint: Theme.workspaceTint.ink)
            StatusRule()
            if let lead { leadTag(lead) }
            if verdicts {
                freshnessVerdict(workspace)
                uncommittedVerdict(workspace)
            }

            Spacer(minLength: 12)

            if revealLink, let lead {
                InlineLink(title: "Reveal lead in Finder", size: Typography.Size.detail) { reveal(lead) }
                    .fixedSize()
                    .layoutPriority(1)
            }
        }
    }

    // The lead project reads as a path into it rather than as a label: it is the folder
    // every session here starts in, and it is the one row on this screen worth leaving
    // for.
    private func leadTag(_ project: Project) -> some View {
        let branch = freshness[project.id]?.currentBranch
        return Button { open(project) } label: {
            HStack(spacing: Space.sm) {
                ProjectDot(tint: Theme.projectTint(for: project.name), size: 7)
                Text(project.name)
                    .font(Typography.data.weight(.semibold))
                    .lineLimit(1)
                    .layoutPriority(1)
                if let branch {
                    StatusDot()
                    StatusValue(text: branch, truncation: .middle)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverLift()
        .appTooltip("\(project.name) is the working directory here. Open it.")
    }

    // One word for the whole workspace: what the chips on the rows below add up to.
    @ViewBuilder private func freshnessVerdict(_ workspace: ProjectWorkspace) -> some View {
        let repositories = workspace.projectIDs.compactMap(store.project).filter(\.isGitRepository)
        let reports = repositories.compactMap { freshness[$0.id] }
        if !updating.isEmpty {
            StatusCaps(text: "UPDATING…")
        } else if reports.count == repositories.count, !reports.isEmpty {
            let stale = reports.count(where: \.isStale)
            StatusCaps(text: stale == 0
                           ? "ALL UP TO DATE"
                           : "\(stale) OF \(reports.count) NOT UP TO DATE",
                       tint: stale == 0 ? Theme.addition : Theme.attentionText)
                .appTooltip(stale == 0
                            ? "Every repository is on its default branch at the latest revision."
                            : "Open the rows below to switch branch or pull.")
        }
    }

    // Dirtiness is a separate question from freshness, so it gets a reading of its own:
    // a workspace can be on the latest revision everywhere and still hold work no
    // worktree session would carry. Nothing shows when every folder is clean, which is
    // the usual case and not worth a word.
    @ViewBuilder private func uncommittedVerdict(_ workspace: ProjectWorkspace) -> some View {
        let dirty = workspace.projectIDs.compactMap(store.project)
            .filter(\.isGitRepository)
            .count { workingTrees.isDirty($0.path) }
        if dirty > 0 {
            StatusDot()
            StatusCaps(text: "\(dirty) WITH UNCOMMITTED WORK", tint: Theme.attentionText)
                .appTooltip("The rows below say which. A worktree session starts from the last commit, so this work stays in the project folder.")
        }
    }

    // MARK: - Body

    private func content(_ workspace: ProjectWorkspace) -> some View {
        let sessions = store.sessions(in: workspace.id)

        return ScrollView {
            VStack(alignment: .leading, spacing: Space.xxl) {
                if hasMissingProjects(workspace) { missingFolders(workspace) }
                projects(workspace)
                sessionList(workspace, sessions: sessions)
                removal(workspace, sessions: sessions)
            }
            .padding(Space.xxxl)
        }
    }

    private func projects(_ workspace: ProjectWorkspace) -> some View {
        let lead = store.project(workspace.leadProjectID)
        let attached = workspace.projectIDs
            .filter { $0 != workspace.leadProjectID }
            .compactMap(store.project)

        return VStack(alignment: .leading, spacing: Space.lg) {
            SectionRule(title: "PROJECTS") {
                Text("The lead project is the working directory. Defaults can still be changed per session.")
                    .font(Typography.detail)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: Space.lg) {
                if let lead { leadRow(lead, workspace: workspace) }

                VStack(alignment: .leading, spacing: Space.md) {
                    Text("ATTACHED TO THE SAME CONVERSATION")
                        .font(Typography.caps)
                        .kerning(1.2)
                        .foregroundStyle(.tertiary)
                    ForEach(attached) { project in
                        attachedRow(project, workspace: workspace)
                            .transition(.fold)
                    }
                    addProjectRow(workspace)
                }
                .motion(Motion.reveal, value: workspace.projectIDs)
                .padding(.leading, Space.xl)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Theme.border).frame(width: 1.5)
                }
                .padding(.leading, Space.xl)
            }
            .padding(Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.floating).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.floating)
                .stroke(Theme.accent.opacity(0.45), lineWidth: 1.4))
        }
    }

    private func leadRow(_ project: Project, workspace: ProjectWorkspace) -> some View {
        HStack(spacing: Space.lg) {
            ProjectTileView(name: project.name,
                            tint: Theme.projectTint(for: project.name),
                            side: 36)

            VStack(alignment: .leading, spacing: Space.xs) {
                nameLine(project, workspace: workspace, spacing: Space.md, isLead: true) {
                    Text(project.name)
                        .font(Typography.title)
                        .lineLimit(1)
                }
                Text(summary(project, workspace: workspace))
                    .font(Typography.data)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            checkoutControl(project, workspace: workspace, height: ControlHeight.md)
            GlyphButton(icon: "ellipsis")
                .appMenu { projectMenu(project, workspace: workspace, isLead: true) }
        }
        // The hover fill wants room around the row, but the row's place in the card is
        // set by the card's own padding, so the inset is given straight back.
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .background(RoundedRectangle(cornerRadius: Radius.card)
            .fill(hoveredProjectID == project.id ? Theme.field : .clear))
        .contentShape(RoundedRectangle(cornerRadius: Radius.card))
        .onTapGesture { open(project) }
        .motion(Motion.hover, value: hoveredProjectID)
        .onPointerHover { hovering(project, $0) }
        .appTooltip("Open \(project.name)")
        .padding(.horizontal, -11)
        .padding(.vertical, -9)
    }

    private func attachedRow(_ project: Project, workspace: ProjectWorkspace) -> some View {
        HStack(spacing: Space.lg) {
            ProjectTileView(name: project.name,
                            tint: Theme.projectTint(for: project.name),
                            side: 30)

            VStack(alignment: .leading, spacing: Space.xxs) {
                nameLine(project, workspace: workspace, spacing: Space.sm, isLead: false) {
                    Text(project.name)
                        .font(Typography.body.weight(.semibold))
                        .lineLimit(1)
                }
                Text(summary(project, workspace: workspace))
                    .font(Typography.data)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            checkoutControl(project, workspace: workspace, height: 28)
            InlineLink(title: "Make lead", size: Typography.Size.detail) {
                store.setLeadProject(project.id, inWorkspace: workspace.id)
            }
            GlyphButton(icon: "xmark", side: ControlHeight.md) {
                store.removeProject(project.id, fromWorkspace: workspace.id)
            }
            .disabled(workspace.projectIDs.count <= 2)
            .opacity(workspace.projectIDs.count <= 2 ? 0.35 : 1)
            .appTooltip(workspace.projectIDs.count <= 2
                        ? "A workspace needs at least two projects"
                        : "Remove from workspace")
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.lg)
        .background(RoundedRectangle(cornerRadius: Radius.card)
            .fill(hoveredProjectID == project.id ? Theme.field : Theme.sunken))
        .contentShape(RoundedRectangle(cornerRadius: Radius.card))
        .onTapGesture { open(project) }
        .motion(Motion.hover, value: hoveredProjectID)
        .onPointerHover { hovering(project, $0) }
        .appTooltip("Open \(project.name)")
    }

    // The chips keep their full width, so in a narrow pane they are dropped from the end
    // rather than pushing the page wider than the window. The lead chip goes first, since
    // the indent already says which project leads. A missing folder is always shown.
    private func nameLine<Name: View>(_ project: Project, workspace: ProjectWorkspace,
                                      spacing: CGFloat, isLead: Bool,
                                      @ViewBuilder name: () -> Name) -> some View {
        let name = name()
        let missing = store.isMissing(project)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: spacing) {
                name
                if isLead {
                    MonoChip(text: "LEAD · WORKING DIRECTORY", size: Typography.Size.micro, tint: Theme.accent)
                }
                if missing { MonoChip(text: "MISSING", size: Typography.Size.micro, tint: Theme.deletion) }
                freshnessChip(project)
                uncommittedChip(project, workspace: workspace)
            }
            HStack(spacing: spacing) {
                name
                if missing { MonoChip(text: "MISSING", size: Typography.Size.micro, tint: Theme.deletion) }
                freshnessChip(project)
                uncommittedChip(project, workspace: workspace)
            }
            HStack(spacing: spacing) {
                name
                if missing { MonoChip(text: "MISSING", size: Typography.Size.micro, tint: Theme.deletion) }
                freshnessChip(project)
            }
            HStack(spacing: spacing) {
                name
                if missing { MonoChip(text: "MISSING", size: Typography.Size.micro, tint: Theme.deletion) }
            }
        }
    }

    private func hovering(_ project: Project, _ isInside: Bool) {
        if isInside {
            hoveredProjectID = project.id
        } else if hoveredProjectID == project.id {
            hoveredProjectID = nil
        }
    }

    // Leaving a workspace for one of its projects means leaving the rail's place in the
    // list as well, so the project screen opens with its row scrolled into view.
    private func open(_ project: Project) {
        store.selectProject(project.id, revealingInSidebar: true)
    }

    // Answers "is this project on main and up to date?" at a glance, next to the name.
    // Nothing shows until the first report lands, so a repository never wears a verdict
    // that is really just "still reading". The tooltip carries the full sentence.
    // A chip that has something to complain about opens a menu offering the fix.
    @ViewBuilder private func freshnessChip(_ project: Project) -> some View {
        if updating.contains(project.id) {
            HStack(spacing: Space.xs) {
                LoopSpinner(size: 10)
                Text("UPDATING…")
                    .font(Typography.caps)
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
            }
            .transition(.fadeIn)
        } else if let report = freshness[project.id] {
            Group {
                if !report.onDefaultBranch, let expected = report.defaultBranch {
                    MonoChip(text: "NOT ON \(expected.uppercased())", size: Typography.Size.micro,
                             tint: Theme.attention)
                        .hoverLift()
                        .appMenu { freshenMenu(project, report: report) }
                } else if report.behind > 0 {
                    MonoChip(text: "\(report.behind) BEHIND", size: Typography.Size.micro, tint: Theme.attention)
                        .hoverLift()
                        .appMenu { freshenMenu(project, report: report) }
                } else {
                    MonoChip(text: "UP TO DATE", size: Typography.Size.micro, tint: Theme.addition)
                }
            }
            .appTooltip(report.isStale
                        ? report.explanation + " Click to bring the checkout up to date."
                        : report.explanation)
            .transition(.fadeIn)
        }
    }

    // The other half of "what state is this checkout in": the chip beside it is about the
    // branch, this one is about the folder. It belongs next to the name because a worktree
    // session starts from the last commit, so work waiting here is work that session will
    // not see, and that is worth knowing before one is started rather than while it is.
    @ViewBuilder private func uncommittedChip(_ project: Project,
                                              workspace: ProjectWorkspace) -> some View {
        let count = workingTrees.uncommittedFileCount(at: project.path)
        Group {
            if count > 0 {
                MonoChip(text: counted(count, "UNCOMMITTED FILE", plural: "UNCOMMITTED FILES"),
                         size: Typography.Size.micro, tint: Theme.attention)
                    .appTooltip(workspace.worktreeProjectIDs.contains(project.id)
                                ? "\(counted(count, "file")) changed in the project folder. A worktree session starts from the last commit, so this work stays behind."
                                : "\(counted(count, "file")) changed in the project folder. Sessions here run in it, so they start with this work in place.")
            }
        }
    }

    private func freshenMenu(_ project: Project, report: GitFreshness.Report) -> [MenuEntry] {
        guard let branch = report.defaultBranch else { return [] }
        if !report.onDefaultBranch {
            return [.item(report.remoteRef == nil
                              ? "Switch to \(branch)"
                              : "Switch to \(branch) and pull",
                          subtitle: "Uncommitted changes stay in place; git stops if they conflict.") {
                freshen(project, report: report)
            }]
        }
        return [.item("Pull \(counted(report.behind, "commit"))",
                      subtitle: "Fast-forward pull from \(report.remoteRef ?? "origin").") {
            freshen(project, report: report)
        }]
    }

    // Fixes what the chip complains about: the checkout ends up on the default branch at
    // its latest revision. The pull runs even when the old report counted no commits,
    // because the local default branch can trail its remote even when the branch just
    // left did not. Whatever git refuses is shown in its own words, and the chip re-reads
    // the repository either way.
    private func freshen(_ project: Project, report: GitFreshness.Report) {
        guard updating.insert(project.id).inserted else { return }
        Task {
            var error: String?
            if let branch = report.defaultBranch {
                error = report.remoteRef == nil
                    ? await GitActions.switchBranch(branch, at: project.path)
                    : await GitActions.updateCheckout(to: branch, at: project.path)
            }
            let fresh = await GitFreshness.check(at: project.path, fetch: false)
            withAnimation(reduceMotion ? nil : Motion.reveal) {
                if let fresh { freshness[project.id] = fresh }
                updating.remove(project.id)
            }
            if let error {
                dialogs.show(.notice("Could not update \(project.name)", message: error))
            }
        }
    }

    private func checkFreshness(_ workspace: ProjectWorkspace) async {
        let repositories = workspace.projectIDs.compactMap(store.project)
            .filter(\.isGitRepository)
            .map { (id: $0.id, path: $0.path) }
        for fetch in [false, true] {
            // These land on their own after the page opens, so they arrive without motion.
            await GitFreshness.checkAll(repositories, fetch: fetch) { id, report in
                freshness[id] = report
            }
        }
    }

    // Freshness is read once when the page opens, but dirtiness changes under the page:
    // a commit in a terminal, a session writing files. So the folders are re-read for as
    // long as the page is up, at the same slow rate the sidebar uses.
    private func watchWorkingTrees(_ workspace: ProjectWorkspace) async {
        let folders = Set(workspace.projectIDs.compactMap(store.project)
            .filter(\.isGitRepository)
            .map(\.path))
        while !Task.isCancelled {
            workingTrees.refresh(folders)
            try? await Task.sleep(for: WorkingTreeWatch.interval)
        }
    }

    // One control rather than two competing buttons: the current mode is the label, and
    // the other is a menu away. A plain folder has no choice to offer, so it says so.
    @ViewBuilder private func checkoutControl(_ project: Project, workspace: ProjectWorkspace,
                                              height: CGFloat) -> some View {
        if project.isGitRepository {
            let worktree = workspace.worktreeProjectIDs.contains(project.id)
            ActionButton(title: worktree ? "Worktree" : "Project folder",
                         tone: .sunken, height: height, size: Typography.Size.detail, disclosure: true)
                .appMenu {
                    [.item("Worktree", checked: worktree,
                           subtitle: "A checkout of its own for each session.") {
                        store.setUsesWorktree(true, for: project.id, inWorkspace: workspace.id)
                    },
                     .item("Project folder", checked: !worktree,
                           subtitle: "Work directly in the folder as it is checked out.") {
                        store.setUsesWorktree(false, for: project.id, inWorkspace: workspace.id)
                    }]
                }
        } else {
            Text("Project folder")
                .font(Typography.label)
                .foregroundStyle(.tertiary)
                .frame(height: height)
                .appTooltip("Not a git repository, so there are no worktrees to make.")
        }
    }

    private func addProjectRow(_ workspace: ProjectWorkspace) -> some View {
        HStack(spacing: Space.md) {
            Text("+ Add project")
                .font(Typography.body.weight(.semibold))
                .foregroundStyle(Theme.accent)
            Text("from your projects, or attach a folder…")
                .font(Typography.data)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .overlay(RoundedRectangle(cornerRadius: Radius.card)
            .stroke(Theme.border, lineWidth: 1.2))
        .contentShape(RoundedRectangle(cornerRadius: Radius.card))
        .hoverFill(cornerRadius: Radius.card)
        .appMenu { addMenu(workspace) }
    }

    private func addMenu(_ workspace: ProjectWorkspace) -> [MenuEntry] {
        let projects = attachableProjects(workspace)
        let projectItems = projects.map { project in
            MenuItem(label: project.name, icon: "folder", subtitle: project.collapsedPath,
                     handler: {
                         store.addProject(project.id, toWorkspace: workspace.id)
                     })
        }

        var entries: [MenuEntry] = []
        if !projectItems.isEmpty {
            entries.append(.searchable(projectItems,
                                       prompt: "Filter projects by name or path",
                                       noResults: "No project matches this filter."))
            entries.append(.separator)
        }
        entries.append(.item("Attach a folder…", icon: "folder.badge.plus") {
            addFolder(to: workspace)
        })
        return entries
    }

    private func projectMenu(_ project: Project, workspace: ProjectWorkspace,
                             isLead: Bool) -> [MenuEntry] {
        var entries: [MenuEntry] = [
            .item("Open project") { open(project) },
            .item("Reveal in Finder") { reveal(project) }
        ]
        if !isLead {
            entries.append(.item("Make lead") {
                store.setLeadProject(project.id, inWorkspace: workspace.id)
            })
        }
        if workspace.projectIDs.count > 2 {
            entries.append(.separator)
            entries.append(.item("Remove from workspace", kind: .destructive) {
                store.removeProject(project.id, fromWorkspace: workspace.id)
            })
        }
        return entries
    }

    // MARK: - Sessions

    private func sessionList(_ workspace: ProjectWorkspace,
                             sessions: [ChatSession]) -> some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            SectionRule(title: "SESSIONS · \(sessions.count)") {
                if !sessions.isEmpty {
                    Text(sessions.map { tone($0) }.tally)
                        .font(Font.mono(Typography.Size.micro))
                        .kerning(0.6)
                        .foregroundStyle(.tertiary)
                }
            }

            if sessions.isEmpty {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("No sessions yet")
                        .font(Typography.body.weight(.semibold))
                    Text("The checkout choices above are what the first session will start with.")
                        .font(Typography.body)
                        .foregroundStyle(.secondary)
                }
                .padding(Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.floating).fill(Theme.sunken))
                .overlay(RoundedRectangle(cornerRadius: Radius.floating)
                    .stroke(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            } else {
                LazyVStack(spacing: Space.md) {
                    ForEach(sessions) { session in
                        SessionRow(session: session,
                                   tone: tone(session),
                                   branch: nil,
                                   activity: SessionActivity.line(for: session, store: store,
                                                                  runner: runner),
                                   detail: .repositories(repositories(session)),
                                   onOpen: { store.selectSession(session.id) },
                                   menu: { sessionMenu(session) })
                    }
                }
            }
        }
    }

    // The row shows a compact repository summary. It keeps the mode on each value so the
    // full mapping remains available when a workspace mixes worktrees and plain folders.
    private func repositories(_ session: ChatSession) -> [SessionRow.Repository] {
        store.checkoutProjects(for: session).compactMap { checkout in
            guard let project = store.project(checkout.projectID) else { return nil }
            return SessionRow.Repository(
                id: project.id,
                name: project.name.lowercased(),
                usesWorktree: checkout.worktreePath != nil,
                tint: Theme.projectTint(for: project.name))
        }
    }

    private func tone(_ session: ChatSession) -> SessionTone {
        SessionTone(session.id, store: store, runner: runner)
    }

    private func sessionMenu(_ session: ChatSession) -> [MenuEntry] {
        [
            .item("Open session") { store.selectSession(session.id) },
            SessionTitle.menuEntry(for: session.id, runner: runner, store: store),
            .item(session.isPinned ? "Unpin" : "Pin",
                  icon: session.isPinned ? "pin.slash" : "pin") {
                store.setPinned(!session.isPinned, forSession: session.id)
            },
            SessionUnread.menuEntry(for: session.id, store: store),
            .separator,
            .item("Delete session", kind: .destructive) { confirmRemove(session) }
        ]
    }

    private func confirmRemove(_ session: ChatSession) {
        SessionRemoval.confirm(session, in: store, runner: runner,
                               workingTrees: workingTrees, dialogs: dialogs)
    }

    // MARK: - Footer

    // The way out of a workspace, at the end of the page rather than in the header, so it
    // is never the button next to the one that starts work.
    private func removal(_ workspace: ProjectWorkspace,
                         sessions: [ChatSession]) -> some View {
        let projects = workspace.projectIDs.count
        return FooterStrip(
            title: "Delete this workspace",
            detail: "\(counted(sessions.count, "session")) and their worktrees go with it · its \(projects) projects stay") {
            ActionButton(title: "Delete workspace", tone: .danger, size: Typography.Size.detail) {
                WorkspaceRemoval.confirm(workspace, in: store, runner: runner, dialogs: dialogs)
            }
        }
    }

    // MARK: - Helpers

    private func summary(_ project: Project, workspace: ProjectWorkspace) -> String {
        var parts = [project.collapsedPath]
        if let branch = GitHead.branch(at: project.path) { parts.append(branch) }
        return parts.joined(separator: " · ")
    }

    private func toggleTerminal(_ workspace: ProjectWorkspace) {
        guard let lead = store.project(workspace.leadProjectID) else { return }
        let opening = !terminals.isOpen(terminalScope)
        terminals.setOpen(opening, for: terminalScope, directory: lead.path)
        terminalFocused = opening
    }

    private func missingFolders(_ workspace: ProjectWorkspace) -> some View {
        let names = workspace.projectIDs.compactMap(store.project).filter(store.isMissing).map(\.name)
        return HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Folder not found for \(names.joined(separator: ", ")). Restore it or remove it from the workspace before starting a session.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .warningCard()
    }

    private func attachableProjects(_ workspace: ProjectWorkspace) -> [Project] {
        store.regularProjects.filter { !workspace.projectIDs.contains($0.id) }
    }

    private func addFolder(to workspace: ProjectWorkspace) {
        guard let url = FilePicker.chooseFolder(
            prompt: "Add Folder",
            message: "Pick a folder to add to this workspace.") else { return }
        let added = store.addProject(at: url)
        guard let id = added?.id ?? store.selectedProjectID else { return }
        store.addProject(id, toWorkspace: workspace.id)
        store.selectWorkspace(workspace.id)
    }

    private func reveal(_ project: Project) {
        NSWorkspace.shared.activateFileViewerSelecting([project.url])
        showNote("Showed \(project.name) in Finder")
    }

    // A second note keeps the line up rather than letting the first one's timer take it
    // down early.
    private func showNote(_ text: String) {
        notes += 1
        let shown = notes
        note = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.4))
            if notes == shown { note = nil }
        }
    }

    private func hasMissingProjects(_ workspace: ProjectWorkspace) -> Bool {
        workspace.projectIDs.compactMap(store.project).contains(where: store.isMissing)
    }

    private func startSession(_ choice: WorkspaceSessionChoice,
                              in workspace: ProjectWorkspace) {
        Task {
            switch await SessionLifecycle.createWorkspaceSession(
                choice, in: workspace, store: store, composer: runner.composer) {
            case .success:
                break
            case .failure(let failure):
                dialogs.show(.notice(failure.title, message: failure.message))
            }
        }
    }
}
