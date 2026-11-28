import SwiftUI

// Adds one more project to a session. The top of the sheet shows the session's lineup:
// the lead project, and an empty seat beside it. Picking a project from the list puts
// it in the seat, and the list gives way to how that project should be checked out.
struct AttachProjectSheet: View {
    let sessionID: UUID
    let onAttached: (_ project: Project, _ newWorkspace: String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let longestWait: Duration = .seconds(12)
    nonisolated private static let space = "attach-project"
    private static let tileSide = ControlHeight.lg
    private static let seatHeight = tileSide + Space.lg * 2
    private static let linkWidth = Space.xxl * 2
    private static let rowHeight = ControlHeight.xl + Space.md
    // Five rows and half of the next, so the half row also says there is more.
    private static let listHeight = rowHeight * 5.5

    @State private var projectID: UUID?
    @State private var useWorktree = false
    @State private var freshness: GitFreshness.Report?
    @State private var startPoint: SessionStartPoint = .currentCheckout
    @State private var startPointWasChosen = false
    @State private var carryChanges = false
    @State private var updateDefaultBranch = false
    @State private var activeFetches = 0
    @State private var gaveUpWaiting = false
    @State private var retries = FreshnessRetries()
    @State private var working: String?
    @State private var canFork = false

    @State private var query = ""
    // The row Return will pick, moved by the arrow keys and by the pointer.
    @State private var cursor = 0
    // Counts moves made with the keys, so only those scroll the list.
    @State private var keyMoves = 0
    // The branch each folder is on, read from disk without a fetch.
    @State private var branches: [UUID: String] = [:]
    @State private var frames = TileFrames()
    @State private var flight: Flight?
    // The picked tile has reached its seat, so the lineup can count it.
    @State private var landed = false
    @State private var landings = 0
    // Counts clicks on the dead Attach button, so each one plays the hint in again.
    @State private var blockedClicks = 0
    @State private var stage = 0
    @State private var stages = 1
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SheetTitle("Attach project", icon: "plus.rectangle.on.folder")
                .padding(.horizontal, Space.pane)
                .headerBand()
            readings

            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    deck
                    if let project {
                        setUp(project).transition(.fadeIn)
                    } else if attachableProjects.isEmpty {
                        Text("Every project is already in this session.")
                            .font(Typography.detail)
                            .foregroundStyle(.secondary)
                    } else {
                        chooser.transition(.fadeIn)
                    }
                }
                .padding(Space.pane)
                .motion(Motion.reveal, value: projectID)
            }
            .scrollCap(ScrollCap.tall)

            SheetFooter(primary: SheetAction(title: working == nil ? "Attach" : "Attaching",
                                             enabled: canAttach, shortcut: .defaultAction, hint: "⏎",
                                             blockedReason: blockedReason,
                                             onBlockedClick: blockedClick, action: attach),
                        dismissTone: .outlined, primaryLast: true, dismiss: { dismiss() }) {
                HStack(spacing: Space.md) {
                    if waitingOn != nil { LoopSpinner() }
                    Text(waitingOn ?? note)
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                        .washes(on: blockedClicks, colour: Theme.attention, strength: 0.3)
                }
                .motion(Motion.reveal, value: waitingOn ?? note)
            }
            .overlay(alignment: .topLeading) { progressLine }
        }
        .coordinateSpace(.named(Self.space))
        .overlay {
            if let flight, let project {
                FlightView(flight: flight, onLanded: land) {
                    ProjectTileView(name: project.name, tint: Theme.projectTint(for: project.name),
                                    side: flight.from.width)
                }
                .id(flight.id)
            }
        }
        .frame(width: FormMetrics.sheetWidth)
        .background(Theme.background)
        .disabled(working != nil)
        .interactiveDismissDisabled(working != nil)
        .onAppear {
            canFork = store.transcript(of: sessionID).contains {
                store.canForkSession(sessionID, before: $0.id)
            }
        }
        .onDisappear { retries.stopAll() }
        .onChange(of: query) { _, _ in cursor = 0 }
        .onChange(of: blockedReason) { _, reason in
            AccessibilityNotification.Announcement(reason ?? note).post()
        }
        .task { await readBranches() }
        .task(id: projectID) { await check() }
        .task(id: projectID) {
            guard (try? await Task.sleep(for: Self.longestWait)) != nil else { return }
            gaveUpWaiting = true
        }
    }

    // MARK: - Readings

    // What the session is and what it will be after the attach. The count and the
    // workspace change in place as the picked tile lands, each under a short wash.
    private var readings: some View {
        HStack(spacing: Space.md) {
            StatusCaps(text: "SESSION")
            StatusValue(text: session?.title ?? "", tint: .primary)
            StatusRule()
            StatusCaps(text: "PROJECTS")
            StatusValue(text: "\(projectCount)", tint: .primary)
                .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(projectCount)))
                .fixedSize()
                .washes(on: projectCount)
            StatusRule()
            StatusCaps(text: "WORKSPACE")
            StatusValue(text: workspaceReading, tint: .primary, truncation: .middle)
                .contentTransition(.opacity)
                .washes(on: workspaceReading)
            Spacer(minLength: 0)
        }
        .motion(Motion.control, value: projectCount)
        .accessibilityElement(children: .combine)
        .statusBand(padding: Space.pane)
    }

    private var seated: Project? { landed ? project : nil }

    private var projectCount: Int {
        (session.map { store.checkoutProjects(for: $0).count } ?? 0) + (seated == nil ? 0 : 1)
    }

    private var workspaceReading: String {
        if let workspace { return workspace.name }
        if seated != nil, let newWorkspaceName { return newWorkspaceName }
        return "none yet"
    }

    // MARK: - Lineup

    private var lead: Project? { session.flatMap { store.project($0.projectID) } }

    private var leadBranch: String? {
        guard let session, let lead else { return nil }
        return store.checkoutProjects(for: session).first?.worktreeBranch ?? branches[lead.id]
    }

    // The lead project, a line, and the seat the pick lands in. The line draws across
    // once the seat is taken and carries a streak while the attach runs.
    private var deck: some View {
        HStack(spacing: 0) {
            if let lead {
                seat(lead, detail: leadBranch) {
                    MonoChip(text: "LEAD", size: Typography.Size.micro, tint: Theme.accent)
                }
                .surface(Theme.card, cornerRadius: Radius.card)
                link
            }
            Group {
                if let project {
                    seat(project, detail: project.collapsedPath, tileShown: landed) {
                        InlineLink(title: "Choose another", action: unpick)
                            .fixedSize()
                    }
                    .surface(Theme.card, cornerRadius: Radius.card)
                } else {
                    emptySeat
                }
            }
        }
        .frame(height: Self.seatHeight)
    }

    private func seat<Trailing: View>(_ project: Project, detail: String?, tileShown: Bool = true,
                                      @ViewBuilder trailing: () -> Trailing) -> some View {
        let tint = Theme.projectTint(for: project.name)
        return HStack(spacing: Space.md) {
            ProjectTileView(name: project.name, tint: tint, side: Self.tileSide)
                .opacity(tileShown ? 1 : 0)
                .landingRings(project.id == projectID && landed ? landings : nil, colour: tint.colour,
                              cornerRadius: Self.tileSide * 0.27, reach: 1.9)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(project.name)
                    .font(Typography.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail {
                    Text(detail)
                        .font(Typography.data)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: Space.md)
            trailing()
        }
        .padding(.horizontal, Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptySeat: some View {
        HStack(spacing: Space.md) {
            Image(systemName: "plus")
                .font(Typography.label)
                .foregroundStyle(.tertiary)
                .frame(width: Self.tileSide, height: Self.tileSide)
                .dashedSlot(Color.primary.opacity(0.25), cornerRadius: Self.tileSide * 0.27)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: {
                    frames.seat = $0
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Pick the project to add")
                    .font(Typography.body.weight(.medium))
                    .foregroundStyle(.secondary)
                if let lead {
                    Text("joins \(lead.name) here")
                        .font(Typography.data)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dashedSlot(Theme.accent.opacity(0.55), cornerRadius: Radius.card)
        // A click on the dead Attach button points here, at what is missing.
        .washes(on: blockedClicks, colour: Theme.attention, strength: 0.16,
                cornerRadius: Radius.card, outset: 0)
        .accessibilityElement(children: .combine)
    }

    private var link: some View {
        ZStack(alignment: .leading) {
            LinkLine()
                .stroke(Color.primary.opacity(0.22), style: StrokeStyle(lineWidth: 2, dash: [3, 4]))
            Rectangle()
                .fill(Theme.accent)
                .frame(width: seated == nil ? 0 : Self.linkWidth)
                .motion(Motion.draw, value: seated?.id)
            if working != nil { CometLine(colour: Theme.brand) }
        }
        .frame(width: Self.linkWidth, height: 2)
        .accessibilityHidden(true)
    }

    // MARK: - Choosing

    private var matches: [Project] {
        AttachProjectSearch.matches(attachableProjects, query: query)
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            searchField
            candidateList
            HStack(spacing: Space.lg) {
                keyHint(["↑", "↓"], "move")
                keyHint(["⏎"], "pick")
                keyHint(["esc"], "cancel")
                Spacer(minLength: Space.md)
                Text("\(counted(attachableProjects.count, "project")) "
                     + "\(attachableProjects.count == 1 ? "is" : "are") not in this session yet")
                    .lineLimit(1)
            }
            .font(Typography.caption)
            .foregroundStyle(.secondary)
        }
        .onAppear { searchFocused = true }
    }

    private func keyHint(_ keys: [String], _ verb: String) -> some View {
        HStack(spacing: Space.xs) {
            ForEach(keys, id: \.self) { Keycap($0) }
            Text(verb)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(keys.joined(separator: " ")) to \(verb)")
    }

    private var searchField: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(Typography.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            TextField("Find a project by name or folder", text: $query)
                .textFieldStyle(.plain)
                .font(Typography.body)
                .focused($searchFocused)
                .accessibilityLabel("Find a project")
                .onSubmit(pickAtCursor)
                .onKeyPress(.downArrow) {
                    moveCursor(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveCursor(by: -1)
                    return .handled
                }
            if !query.isEmpty {
                Button(action: clearSearch) {
                    Image(systemName: "xmark.circle.fill")
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                        .frame(width: ControlHeight.xs, height: ControlHeight.xs)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverLift(amount: Motion.smallLift)
                .accessibilityLabel("Clear the search")
                .appTooltip("Clear the search")
            }
        }
        .padding(.horizontal, Space.md)
        .frame(height: ControlHeight.lg)
        .fieldSurface()
        .overlay(RoundedRectangle(cornerRadius: Radius.control)
            .strokeBorder(searchFocused ? Theme.accent : .clear))
        .motion(Motion.hover, value: searchFocused)
    }

    private var candidateList: some View {
        let found = matches
        return ScrollViewReader { proxy in
            Group {
                if found.isEmpty {
                    PaneMessage(icon: "magnifyingglass", title: "No project matches \"\(query.trimmed)\"",
                                detail: "Check the spelling, or add the folder to Code Station first.") {
                        InlineLink(title: "Clear the search", action: clearSearch)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.fadeIn)
                } else {
                    MenuContentScrollView(maxHeight: Self.listHeight, fade: Theme.card) {
                        VStack(alignment: .leading, spacing: 0) {
                            if !query.isBlank {
                                StatusCaps(text: "\(found.count) OF \(attachableProjects.count)",
                                           tint: Theme.secondaryText, size: Typography.Size.micro)
                                    .padding(.horizontal, Space.md)
                                    .padding(.top, Space.sm)
                                    .padding(.bottom, Space.xs)
                            }
                            ForEach(Array(found.enumerated()), id: \.element.id) { index, candidate in
                                AttachCandidateRow(project: candidate, query: query,
                                                   branch: branches[candidate.id],
                                                   isCursor: index == cursor, height: Self.rowHeight,
                                                   space: Self.space, frames: frames,
                                                   point: { cursor = index },
                                                   pick: { pick(candidate) })
                                    .id(candidate.id)
                                    .arrivesInTurn(index)
                            }
                        }
                        .padding(Space.xs)
                    }
                }
            }
            .frame(height: Self.listHeight, alignment: .top)
            .surface(Theme.card, cornerRadius: Radius.card)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Projects you can attach")
            .onChange(of: keyMoves) { _, _ in
                guard found.indices.contains(cursor) else { return }
                proxy.scrollTo(found[cursor].id)
            }
        }
    }

    private func moveCursor(by step: Int) {
        let count = matches.count
        guard count > 0 else { return }
        cursor = (cursor + step + count) % count
        keyMoves += 1
    }

    private func pickAtCursor() {
        let found = matches
        guard found.indices.contains(cursor) else { return }
        pick(found[cursor])
    }

    private func clearSearch() {
        query = ""
        searchFocused = true
    }

    // The tile leaves its row for the seat. The list goes at once, so the tile is the
    // one thing seen moving, and the lineup counts it when it lands.
    private func pick(_ candidate: Project) {
        guard candidate.id != projectID else { return }
        let from = frames.tiles[candidate.id]
        choose(candidate)
        landed = false
        if !reduceMotion, let from, let to = frames.seat {
            flight = Flight(from: from, to: to)
        } else {
            land()
        }
    }

    private func land() {
        flight = nil
        guard let project else { return }
        landed = true
        landings += 1
        AccessibilityNotification.Announcement(
            [project.name + " picked.", workspaceLine].compactMap { $0 }.joined(separator: " ")).post()
    }

    private func unpick() {
        retries.stopAll()
        flight = nil
        landed = false
        freshness = nil
        projectID = nil
        cursor = 0
    }

    private func readBranches() async {
        guard let session else { return }
        var folders = attachableProjects.filter(\.isGitRepository).map { ($0.id, $0.path) }
        if let lead, let root = store.workingDirectory(for: session) { folders.append((lead.id, root)) }
        branches = await AttachProjectSearch.branches(of: folders)
    }

    // MARK: - Setting up

    private func setUp(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            if let workspaceLine {
                Label {
                    Text(workspaceLine).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "square.stack.3d.up").accessibilityHidden(true)
                }
                .font(Typography.detail)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .transition(cardTransition)
            }
            if losesFork {
                Text("After this, Fork from here is no longer available for this session.")
                    .font(Typography.detail)
                    .foregroundStyle(Theme.warningText)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(cardTransition)
            }
            SessionProjectCard(project: project, usesWorktree: useWorktree,
                               report: freshness, startPoint: $startPoint,
                               carryChanges: $carryChanges,
                               updateDefaultBranch: $updateDefaultBranch,
                               selectWorktree: selectWorktree,
                               selectProjectFolder: selectProjectFolder,
                               onChoose: { startPointWasChosen = true },
                               retry: retries.attempts[project.id],
                               reachedOrigin: retries.reached.contains(project.id),
                               retryFetch: retryFetch,
                               stopFetch: { retries.stop(project.id) },
                               showsName: false,
                               waiting: isFetching ? "Fetching branch information…" : nil)
                .id(project.id)
        }
    }

    // MARK: - Footer

    // How far the attach has got, drawn along the top of the footer. It stops short of
    // the end until the work is done, since the last step has no length to measure.
    private var progressLine: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(Theme.accent)
                .frame(width: geometry.size.width * progress, height: 2)
                .motion(Motion.draw, value: progress)
        }
        .frame(height: 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var progress: Double {
        working == nil ? 0 : Double(stage) / Double(max(stages, 1)) * 0.92
    }

    private var blockedReason: String? {
        if project == nil { return "Choose a project to attach." }
        return canAttach ? nil : waitingOn
    }

    private func blockedClick() {
        blockedClicks += 1
        if project == nil { searchFocused = true }
        AccessibilityNotification.Announcement(blockedReason ?? note).post()
    }

    private var session: ChatSession? { store.session(sessionID) }

    private var project: Project? { projectID.flatMap { store.project($0) } }

    private var workspace: ProjectWorkspace? {
        session?.workspaceID.flatMap { store.workspace($0) }
    }

    private var newWorkspaceName: String? {
        guard let project, let session, workspace == nil,
              let lead = store.project(session.projectID) else { return nil }

        return ProjectWorkspace.name(joining: lead.name, project.name)
    }

    private var workspaceLine: String? {
        if let newWorkspaceName {
            return "This session will move into a new workspace called \(newWorkspaceName)."
        }
        guard let project, let workspace, !workspace.projectIDs.contains(project.id) else {
            return nil
        }

        return "\(project.name) will also join \(workspace.name)."
    }

    private var losesFork: Bool { newWorkspaceName != nil && canFork }

    private var attachableProjects: [Project] {
        let attached = Set(session.map { store.checkoutProjects(for: $0).map(\.projectID) } ?? [])
        let members = workspace?.projectIDs ?? []
        let free = store.regularProjects.filter { !attached.contains($0.id) }

        return free.filter { members.contains($0.id) } + free.filter { !members.contains($0.id) }
    }

    private func choose(_ candidate: Project) {
        guard candidate.id != projectID else { return }
        retries.stopAll()
        freshness = nil
        startPoint = .currentCheckout
        startPointWasChosen = false
        carryChanges = false
        updateDefaultBranch = false
        gaveUpWaiting = false
        let member = workspace?.projectIDs.contains(candidate.id) == true
        useWorktree = candidate.isGitRepository
            && (!member || workspace?.worktreeProjectIDs.contains(candidate.id) == true)
        projectID = candidate.id
    }

    private func check() async {
        guard let project, project.isGitRepository else { return }
        activeFetches += 1
        defer { activeFetches -= 1 }
        for fetch in [false, true] {
            let report = await GitFreshness.check(at: project.path, fetch: fetch)
            guard project.id == projectID else { return }
            guard let report else { continue }
            freshness = report
            selectRecommendedStartPoint(for: report)
        }
    }

    private var cardTransition: AnyTransition {
        reduceMotion
            ? .asymmetric(insertion: AnyTransition.opacity.animation(Motion.reveal),
                          removal: AnyTransition.opacity.animation(Motion.leave))
            : .asymmetric(insertion: .fadeIn, removal: .fold)
    }

    private var waitingOn: String? {
        if let working { return working }
        if let project, !retries.isEmpty { return "Fetching \(project.name) again…" }
        if isFetching { return "Fetching branch information…" }

        return nil
    }

    private var isFetching: Bool { project != nil && activeFetches > 0 && !gaveUpWaiting }

    private var note: String {
        guard project != nil else { return "Choose a project to attach." }

        let updates = updatesCheckout || fastForwardsDefaultBranch
        if useWorktree {
            return updates ? "Will update the project folder. 1 worktree will be created."
                : "1 worktree will be created."
        }

        return updates ? "Will update the project folder." : "The project folder is used as it is."
    }

    private var canAttach: Bool { project != nil && waitingOn == nil }

    private func selectWorktree() {
        useWorktree = true
        if let freshness { selectRecommendedStartPoint(for: freshness) }
    }

    private func selectProjectFolder() {
        useWorktree = false
        if let freshness { selectRecommendedStartPoint(for: freshness) }
        if startPoint == .remote { startPoint = .currentCheckout }
    }

    private func retryFetch() {
        guard let project, let freshness else { return }
        retries.start(project.id, path: project.path, after: freshness) { report in
            self.freshness = report
            selectRecommendedStartPoint(for: report)
        }
    }

    private func selectRecommendedStartPoint(for report: GitFreshness.Report) {
        guard !startPointWasChosen else { return }
        startPoint = .recommended(for: report, worktree: useWorktree)
    }

    private var updatesCheckout: Bool {
        startPoint == .updateCheckout && freshness?.canUpdateCheckout == true
    }

    private var fastForwardsDefaultBranch: Bool {
        useWorktree && startPoint == .remote && updateDefaultBranch
            && freshness?.canFastForwardDefaultBranch == true
    }

    private func attach() {
        guard canAttach, let project else { return }
        guard !runner.state(sessionID).isBusy, !runner.isBeingRemoved(sessionID) else {
            dialogs.show(.notice("Could not attach \(project.name)",
                                 message: "Wait for the current turn to finish, then attach the project."))
            return
        }
        working = "Attaching \(project.name)…"
        stage = 0
        stages = (fastForwardsDefaultBranch || updatesCheckout ? 1 : 0) + 1
        Task {
            if fastForwardsDefaultBranch, let branch = freshness?.defaultBranch,
               let remote = freshness?.remoteRef {
                working = "Updating \(branch) from origin…"
                stage += 1
                if let error = await GitActions.fastForwardBranch(branch, to: remote,
                                                                  at: project.path) {
                    working = nil
                    dialogs.show(.fastForwardFailure(error, branch: branch) {
                        updateDefaultBranch = false
                        attach()
                    })
                    return
                }
            } else if updatesCheckout, let report = freshness, let branch = report.defaultBranch {
                working = "Updating \(branch) from origin…"
                stage += 1
                if let error = await GitActions.updateCheckout(to: branch, at: project.path) {
                    working = nil
                    dialogs.show(.updateFailure(error, project: project.name, report: report,
                                                forWorktree: useWorktree) {
                        startPoint = .remote
                        attach()
                    })
                    return
                }
            }
            await finish(project)
        }
    }

    private func finish(_ project: Project) async {
        guard let session else { return dismiss() }
        if useWorktree { working = "Creating a worktree for \(project.name)…" }
        stage += 1
        let movingInto = newWorkspaceName
        let result = await SessionLifecycle.attachProject(
            project, to: session, useWorktree: useWorktree,
            base: useWorktree && startPoint == .remote ? freshness?.remoteRef : nil,
            carryChanges: useWorktree && carryChanges && freshness?.dirty == true,
            store: store, composer: runner.composer)
        working = nil
        switch result {
        case .success:
            onAttached(project, movingInto)
            dismiss()
        case .failure(let failure):
            dialogs.show(.notice(failure.title, message: failure.message))
        }
    }
}

// Where each project's tile sits in the sheet, kept for the flight to start from. It
// is read only at the moment of a pick, so a scroll that moves every row does not ask
// the sheet to draw again.
@MainActor
final class TileFrames {
    var tiles: [UUID: CGRect] = [:]
    var seat: CGRect?
}

// The line between two seats of the lineup.
private struct LinkLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

// Finding a project in the list, and what the list knows about each one without asking
// a remote.
enum AttachProjectSearch {
    // A project is found by its name or by its folder, as written in full or as shown.
    static func matches(_ projects: [Project], query: String) -> [Project] {
        let query = query.trimmed
        guard !query.isEmpty else { return projects }
        return projects.filter {
            range(of: query, in: $0.name) != nil || range(of: query, in: $0.collapsedPath) != nil
                || range(of: query, in: $0.path) != nil
        }
    }

    static func range(of query: String, in text: String) -> Range<String.Index>? {
        let query = query.trimmed
        guard !query.isEmpty else { return nil }
        return text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
    }

    // The text with the part that matched marked, so the reason a row is listed can be
    // seen in the row.
    static func marked(_ text: String, query: String) -> AttributedString {
        var marked = AttributedString(text)
        guard let found = range(of: query, in: text),
              let lower = AttributedString.Index(found.lowerBound, within: marked),
              let upper = AttributedString.Index(found.upperBound, within: marked) else { return marked }
        marked[lower..<upper].backgroundColor = Theme.brand.opacity(0.5)
        return marked
    }

    // The branch each folder is on. One after another, since each read is a few
    // milliseconds and running them side by side would only spend file handles.
    static func branches(of folders: [(id: UUID, path: String)]) async -> [UUID: String] {
        guard let tool = Git.tool() else { return [:] }
        return await Task.detached(priority: .userInitiated) {
            var found: [UUID: String] = [:]
            for folder in folders {
                let output = Git.currentBranch(tool, in: URL(fileURLWithPath: folder.path))
                if output.ok, !output.trimmedText.isEmpty { found[folder.id] = output.trimmedText }
            }
            return found
        }.value
    }
}

// One project that can be attached: its tile, its name over its folder, and the branch
// the folder is on. The row under the cursor says what Return will do.
private struct AttachCandidateRow: View {
    let project: Project
    let query: String
    let branch: String?
    let isCursor: Bool
    let height: CGFloat
    let space: String
    let frames: TileFrames
    let point: () -> Void
    let pick: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        Button(action: pick) {
            HStack(spacing: Space.md) {
                ProjectTileView(name: project.name, tint: Theme.projectTint(for: project.name))
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: {
                        frames.tiles[project.id] = $0
                    }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(AttachProjectSearch.marked(project.name, query: query))
                        .font(Typography.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(AttachProjectSearch.marked(project.collapsedPath, query: query))
                        .font(Typography.data)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .layoutPriority(1)
                Spacer(minLength: Space.md)
                reading
                    .fixedSize()
                    .layoutPriority(2)
                if isCursor {
                    HStack(spacing: Space.xs) {
                        Text("Pick")
                        Keycap("⏎")
                    }
                    .font(Typography.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .fixedSize()
                    .layoutPriority(2)
                    .transition(.fadeIn)
                }
            }
            .padding(.horizontal, Space.md)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: Radius.inset).fill(isCursor ? Theme.sunken : .clear))
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(isCursor ? Theme.accent : .clear)
                    .frame(width: 2)
                    .padding(.vertical, Space.lg)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .focusEffectDisabled()
        .overlay(FocusRingStroke(focused: focused))
        .onPointerHover { if $0 { point() } }
        .motion(Motion.hover, value: isCursor)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([project.name, project.collapsedPath, branch.map { "branch \($0)" }
                                ?? (project.isGitRepository ? nil : "not a Git repository")]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Picks this project to attach.")
        .accessibilityAddTraits(isCursor ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var reading: some View {
        if let branch {
            HStack(spacing: Space.xs) {
                Image(systemName: "arrow.triangle.branch")
                    .font(Typography.micro)
                    .foregroundStyle(.tertiary)
                Text(branch).foregroundStyle(.secondary)
            }
            .font(Typography.data)
            .lineLimit(1)
            .transition(.fadeIn)
        } else if !project.isGitRepository {
            Text("not a Git repository")
                .font(Typography.data)
                .foregroundStyle(.tertiary)
        }
    }
}
