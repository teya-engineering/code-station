import CodeStationCore
import Foundation
import TerminalKit
import TerminalTranscript

// The sidebar: the GUI's tree of tasks, workspaces and projects, each with its session
// cards, as the station arranges it from the shared sort and grouping. It holds view
// state only: the tree the station last sent, the filter typed over it, which row is
// selected, how far the column is scrolled, and what is folded or unfolded. The selection
// follows the row's id, not its position, so a tree that reorders under it keeps
// pointing at the same row.
//
// Folding starts from what the GUI remembers (the arrangement's expansion and collapsed
// sections) and the GUI's defaults: a workspace is open, and so is the current
// container, which is the one the open session is in, or before any is opened the one
// the first session is in. What is folded or unfolded here stays here: the GUI's stored
// folding is never written.
//
// Around the tree, held in place while it scrolls, sit the rest of the GUI's sidebar: the
// running count in the heading, the Needs you stack and the filter's notice above the
// tree, and the cleanup strips and the Add and Tools entries below it (`Extra`).
struct SidebarView {
    private(set) var directory: RemoteDirectory?
    // The id of the selected row: a section, container, session or See more.
    private(set) var selectedID: String?
    // The first line of the tree on screen.
    private var top = 0
    // Narrows the tree to the sessions that match every word of it. Empty shows them all.
    private(set) var filter = ""
    // Whether typed keys go to the filter rather than to the sidebar's own letters.
    private(set) var editingFilter = false
    // Containers opened or closed here, by id, over what the GUI remembers.
    private var expansion: [String: Bool] = [:]
    // Sections folded or unfolded here, over the GUI's collapsed sections.
    private var sectionFolding: [SidebarGroup: Bool] = [:]
    // Containers whose See more was pressed, which show every card until they are folded.
    private var showingAll: Set<String> = []
    // The container the person is in, which is open unless folded by hand.
    private var currentID: String?
    // The session open in the main pane, which keeps its card on screen.
    private var openID: String?
    // The one container opened while filtering, whose sessions show whole rather than
    // narrowed, as the GUI's filter box reveals it. Typing lets it go.
    private var revealedID: String?
    // Who the station is moving to while its host hands it over, for the banner.
    private(set) var handover: String?
    // Why the station host will not serve this terminal any more (a host of another build
    // took the station), in place of the list it can no longer follow.
    private(set) var refusal: String?
    // Why the sidebar may be empty or stale: the station host takes this terminal's
    // connection but does not answer it, while the client keeps trying.
    private(set) var silence: String?
    // A line said in place of the key help until the next key, such as why a foot entry
    // has nothing to open yet.
    var notice: String?

    // One row of the tree. A session card takes two lines, three with an activity line;
    // everything else one.
    enum Row {
        case section(SidebarGroup, count: Int, folded: Bool)
        case container(RemoteContainer, expanded: Bool)
        case session(RemoteSessionRow, in: RemoteContainer)
        // The dashed "See N more…" card under a container's last shown card.
        case more(RemoteContainer, hidden: Int)

        var id: String {
            switch self {
            case .section(let group, _, _): Self.sectionID(group)
            case .container(let container, _): container.id
            case .session(let row, _): row.id
            case .more(let container, _): Self.moreID(container.id)
            }
        }

        static func sectionID(_ group: SidebarGroup) -> String { "section:" + group.rawValue }
        static func moreID(_ containerID: String) -> String { "more:" + containerID }

        var height: Int {
            if case .session(let row, _) = self { return row.activity == nil ? 2 : 3 }
            return 1
        }
    }

    // A row above or below the tree, held in place while the tree scrolls between them:
    // the Needs you stack and the filter's notice at the top, the cleanup strips and the
    // Add and Tools entries at the foot. Each is selectable, by an id of its own.
    enum Extra: Equatable {
        case notice(Notice)
        // "Show <container> in sidebar", under "Current session is outside this filter."
        case showCurrent(RemoteContainer)
        case oldSessions(RemoteCleanup)
        case orphans(RemoteCleanup)
        case add
        case tools

        var id: String {
            switch self {
            case .notice(let notice): "notice:" + notice.row.id
            case .showCurrent: "show-current"
            case .oldSessions: "strip:old"
            case .orphans: "strip:orphans"
            case .add: "foot:add"
            case .tools: "foot:tools"
            }
        }
    }

    // A session the GUI names above the tree or in the running count's menu, and why.
    struct Notice: Equatable {
        let row: RemoteSessionRow
        let container: RemoteContainer
        let notice: RemoteNotice
    }

    // What the selection is on, for the keys to act on.
    enum Target {
        case row(Row)
        case extra(Extra)
    }

    // MARK: - Notices

    // Every noticed session, as the GUI orders them (`SidebarNotices.comesFirst`): what
    // needs input, then what runs, then what finished unseen, the newest first in each.
    var notices: [Notice] {
        let kinds: [RemoteNotice.Kind] = [.needsInput, .running, .finished]
        return (directory?.containers ?? []).flatMap { container in
            container.sessions.compactMap { row in row.notice.map { Notice(row: row, container: container, notice: $0) } }
        }
        .sorted { first, second in
            let left = kinds.firstIndex(of: first.notice.kind)!, right = kinds.firstIndex(of: second.notice.kind)!
            return left != right ? left < right : first.row.lastActivity > second.row.lastActivity
        }
    }

    // The Needs you stack: every notice but the running ones.
    var waiting: [Notice] { notices.filter { $0.notice.kind != .running } }

    var runningCount: Int { notices.count { $0.notice.kind == .running } }

    // How many stack entries are drawn. The GUI peeks two cards behind the top one; a
    // terminal lists two, and counts the rest.
    static let stackShown = 2

    // Where the jump key goes: the session needing the person after the one open, round
    // to the first, or with none waiting, the first running.
    func jumpTarget() -> Notice? {
        let waiting = waiting
        guard !waiting.isEmpty else { return notices.first }
        let current = openID.flatMap { id in waiting.firstIndex { $0.row.id == id } }
        return waiting[current.map { ($0 + 1) % waiting.count } ?? 0]
    }

    mutating func handoverStarted(to successor: String) { handover = successor }

    mutating func linkChanged(_ message: String?) { silence = message }

    mutating func hostRefused(_ message: String) {
        refusal = message
        handover = nil
    }

    // MARK: - Above and below the tree

    private var headExtras: [Extra] {
        var extras = waiting.prefix(Self.stackShown).map(Extra.notice)
        if let outside = currentOutsideFilter { extras.append(.showCurrent(outside)) }
        return extras
    }

    private var footExtras: [Extra] {
        var extras: [Extra] = []
        if let cleanup = directory?.cleanup {
            if cleanup.oldSessions > 0 || cleanup.oldSessionsDeleting != nil { extras.append(.oldSessions(cleanup)) }
            if cleanup.orphanedWorktrees > 0 { extras.append(.orphans(cleanup)) }
        }
        return extras + [.add, .tools]
    }

    // Whether a strip at the foot counts down, so the frame is worth drawing each second.
    var showsCountdown: Bool {
        guard let cleanup = directory?.cleanup else { return false }
        return cleanup.oldSessionsDeletingAt != nil || (cleanup.orphanedWorktrees > 0 && cleanup.orphansPruneAt != nil)
    }

    // The container of the open session, while the filter leaves it out, as the GUI
    // says when the current row is outside the filter.
    private var currentOutsideFilter: RemoteContainer? {
        guard isFiltering, let id = containerID(of: openID), let current = container(id),
              !containers.contains(where: { $0.id == id }) else { return nil }
        return current
    }

    var target: Target? {
        guard let selectedID else { return nil }
        if let row = rows.first(where: { $0.id == selectedID }) { return .row(row) }
        return (headExtras + footExtras).first { $0.id == selectedID }.map(Target.extra)
    }

    // MARK: - The tree

    private var arrangement: RemoteArrangement {
        directory?.arrangement ?? RemoteArrangement(sort: .name, grouping: .flat)
    }

    private var query: String { filter.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var isFiltering: Bool { !query.isEmpty }

    // The containers as filtered, by the GUI's rules (`SidebarFilter`): a container stays
    // when its name matches, or for a workspace a member project's, or when it holds a
    // matching session; it shows only the matching sessions and the open one, unless it
    // was opened while filtering, when it shows them all.
    private var containers: [RemoteContainer] {
        let all = directory?.containers ?? []
        let query = query
        guard !query.isEmpty else { return all }
        return all.compactMap { container in
            let matching = container.sessions.filter { Self.matches($0, query: query) }
            guard Self.matches(container, query: query) || !matching.isEmpty else { return nil }
            if container.id == revealedID { return container }
            return container.holding(container.sessions.filter { Self.matches($0, query: query) || $0.id == openID })
        }
    }

    // The containers in the order the tree draws them, sections and all, before folding.
    private var orderedContainers: [RemoteContainer] {
        let containers = containers
        guard arrangement.grouping == .kind else { return containers }
        return SidebarGroup.allCases.flatMap { group in containers.filter { Self.group(of: $0.kind) == group } }
    }

    // Every row in order: by type, a heading over each kind that has containers; flat,
    // one run with no headings. A folded section is its heading alone, a folded container
    // its row alone, and an open one shows its first cards and then See more.
    var rows: [Row] {
        let containers = containers
        func tree(_ containers: [RemoteContainer]) -> [Row] {
            containers.flatMap { container -> [Row] in
                let expanded = isExpanded(container) && !container.sessions.isEmpty
                guard expanded else { return [.container(container, expanded: false)] }
                let shown = visibleSessions(of: container)
                var rows = [Row.container(container, expanded: true)] + shown.map { Row.session($0, in: container) }
                if shown.count < container.sessions.count {
                    rows.append(.more(container, hidden: container.sessions.count - shown.count))
                }
                return rows
            }
        }
        switch arrangement.grouping {
        case .flat:
            return tree(containers)
        case .kind:
            return SidebarGroup.allCases.flatMap { group -> [Row] in
                let members = containers.filter { Self.group(of: $0.kind) == group }
                guard !members.isEmpty else { return [] }
                let folded = isFolded(group)
                return [.section(group, count: members.count, folded: folded)] + (folded ? [] : tree(members))
            }
        }
    }

    static func group(of kind: RemoteContainer.Kind) -> SidebarGroup {
        switch kind {
        case .task: .tasks
        case .workspace: .workspaces
        case .project: .projects
        }
    }

    // A filter is asking to see what matched, so it opens every container and section.
    private func isExpanded(_ container: RemoteContainer) -> Bool {
        if isFiltering { return true }
        return expansion[container.id] ?? arrangement.expansion[container.id]
            ?? (container.kind == .workspace || container.id == currentID)
    }

    private func isFolded(_ group: SidebarGroup) -> Bool {
        if isFiltering { return false }
        return sectionFolding[group] ?? arrangement.collapsedSections.contains(group)
    }

    // The first cards of a container, as many as the GUI's "Sessions shown". The open
    // session, or else the selected one, when it would fall past them, takes the last
    // place, so the container always draws the same number of cards. A filter shows every
    // match, and See more every card.
    private func visibleSessions(of container: RemoteContainer) -> [RemoteSessionRow] {
        let sessions = container.sessions
        guard !isFiltering, !showingAll.contains(container.id) else { return sessions }
        let limit = SidebarSessionLimit.resolved(arrangement.sessionLimit)
        let head = Array(sessions.prefix(limit))
        let kept = [openID, selectedID].compactMap { id in sessions.first { $0.id == id } }.first
        guard let kept, !head.contains(where: { $0.id == kept.id }) else { return head }
        return Array(head.prefix(limit - 1)) + [kept]
    }

    private var treeIDs: [String] { rows.map(\.id) }

    private var selectableIDs: [String] { headExtras.map(\.id) + treeIDs + footExtras.map(\.id) }

    private var sessionIDs: [String] {
        rows.compactMap { if case .session(let row, _) = $0 { row.id } else { nil } }
    }

    private var sessionRows: [RemoteSessionRow] {
        directory?.containers?.flatMap(\.sessions) ?? []
    }

    mutating func show(_ directory: RemoteDirectory) {
        self.directory = directory
        // A list without a successor comes from the host now serving the station.
        handover = directory.handingOverTo
        // Before anything is opened, the container the first session is in is current,
        // as the selection starts on that session.
        if currentID == nil {
            currentID = orderedContainers.first { !$0.sessions.isEmpty }?.id
        }
        keepSelectionShowing()
    }

    // The selection stays on its row while that row still shows, and otherwise moves to
    // the first session, or the first row when there are no sessions.
    private mutating func keepSelectionShowing() {
        let ids = selectableIDs
        if selectedID == nil || !ids.contains(selectedID!) { selectedID = sessionIDs.first ?? treeIDs.first ?? ids.first }
    }

    // MARK: - Moving

    mutating func move(by offset: Int) {
        let ids = selectableIDs
        guard !ids.isEmpty else { return }
        let current = selectedID.flatMap(ids.firstIndex(of:)) ?? 0
        selectedID = ids[min(max(current + offset, 0), ids.count - 1)]
    }

    // The next or previous container, from a container or a session inside one.
    mutating func moveContainer(by offset: Int) {
        let rows = rows
        let containerIDs = rows.compactMap { if case .container(let c, _) = $0 { c.id } else { nil } }
        guard !containerIDs.isEmpty else { return }
        let current = containerID(of: selectedID).flatMap(containerIDs.firstIndex(of:))
        let target = current.map { $0 + offset } ?? (offset > 0 ? 0 : containerIDs.count - 1)
        selectedID = containerIDs[min(max(target, 0), containerIDs.count - 1)]
    }

    // The first and last rows of the tree, past the stack and the foot.
    mutating func moveToFirst() { selectedID = treeIDs.first ?? selectableIDs.first }
    mutating func moveToLast() { selectedID = treeIDs.last ?? selectableIDs.last }

    // The container a row belongs to, looked up in the whole tree so a session hidden by
    // folding or the limit is found too.
    private func containerID(of id: String?) -> String? {
        guard let id else { return nil }
        for container in directory?.containers ?? [] {
            if container.id == id || Row.moreID(container.id) == id || container.sessions.contains(where: { $0.id == id }) {
                return container.id
            }
        }
        return nil
    }

    private func container(_ id: String?) -> RemoteContainer? {
        directory?.containers?.first { $0.id == id }
    }

    // The project or task the selection is in, for a new session to start in.
    var selectedProjectID: String? {
        guard let container = container(containerID(of: selectedID)), container.kind != .workspace else { return nil }
        return container.id
    }

    // Points at a row, when the tree has it.
    mutating func select(_ id: String) {
        if selectableIDs.contains(id) { selectedID = id }
    }

    // Points at a session, letting go of a filter that hides it and opening its container
    // and section, so a session just made is the one selected when the tree comes back.
    mutating func reveal(_ id: String) {
        if !selectableIDs.contains(id) { clearFilter() }
        unfold(toShow: id)
        select(id)
    }

    // The session went on screen in the main pane: its container becomes the current one,
    // and opens, as selecting a session does in the GUI.
    mutating func opened(_ id: String) {
        openID = id
        unfold(toShow: id)
        currentID = containerID(of: id) ?? currentID
        keepSelectionShowing()
    }

    mutating func closed() {
        openID = nil
    }

    private mutating func unfold(toShow id: String) {
        guard let container = container(containerID(of: id)) else { return }
        expansion[container.id] = true
        if arrangement.grouping == .kind { sectionFolding[Self.group(of: container.kind)] = false }
    }

    // The conversation a session's card speaks for: its own, or its Design companion's
    // when that is the one running, waiting or last to speak.
    func conversation(of id: String) -> RemoteCommand.Conversation {
        sessionRows.first { $0.id == id }?.conversation ?? .main
    }

    // The selected session, while the filter still shows it.
    var openableID: String? {
        selectedID.flatMap { sessionIDs.contains($0) ? $0 : nil }
    }

    // MARK: - Folding

    // Folds or unfolds what the selection is on: a section, a container, or the container
    // of a session, which then takes the selection. On See more it shows every card.
    mutating func toggleFold() {
        guard let row = rows.first(where: { $0.id == selectedID }) else { return }
        switch row {
        case .section(let group, _, let folded):
            sectionFolding[group] = !folded
        case .container(let container, let expanded):
            guard !container.sessions.isEmpty else { return }
            setExpanded(!expanded, container)
        case .session(_, let container):
            setExpanded(false, container)
            selectedID = container.id
        case .more:
            showAll()
        }
        keepSelectionShowing()
    }

    // Enter on a row that is not a session: a section heading folds or unfolds, and See
    // more shows the rest. While filtering, a container shows all its sessions, as
    // opening it does in the GUI; otherwise containers are left to their own screens.
    mutating func activate() {
        guard let row = rows.first(where: { $0.id == selectedID }) else { return }
        switch row {
        case .section, .more: toggleFold()
        case .container(let container, _) where isFiltering: revealedID = container.id
        case .container, .session: break
        }
    }

    // "Show <container> in sidebar": the filter goes, and the open session is pointed at.
    mutating func showCurrent() {
        guard let openID else { return }
        clearFilter()
        reveal(openID)
    }

    // Closing a container starts its limit over, as in the GUI.
    private mutating func setExpanded(_ expanded: Bool, _ container: RemoteContainer) {
        if isFiltering { clearFilter() }
        expansion[container.id] = expanded
        if !expanded { showingAll.remove(container.id) }
    }

    // See more shows every card of the container, and the selection goes to the first
    // card it brought in.
    private mutating func showAll() {
        guard case .more(let container, _)? = rows.first(where: { $0.id == selectedID }) else { return }
        let before = Set(visibleSessions(of: container).map(\.id))
        showingAll.insert(container.id)
        selectedID = container.sessions.first { !before.contains($0.id) }?.id ?? container.id
    }

    // MARK: - Filtering

    mutating func startFilter() { editingFilter = true }

    // Leaves the filter's text in place and gives the keys back to the sidebar.
    mutating func stopEditingFilter() { editingFilter = false }

    // Restores the whole tree.
    mutating func clearFilter() {
        editingFilter = false
        setFilter("")
    }

    // Whether the key edited the filter, which takes printable keys while it is typed.
    mutating func editFilter(with key: Key) -> Bool {
        switch key {
        case .char(let character, let mods) where mods.isEmpty || mods == .shift:
            setFilter(filter + String(character))
        case .paste(let pasted):
            setFilter(filter + pasted.replacingOccurrences(of: "\n", with: " "))
        case .backspace(.alt), .char("w", .ctrl):
            var words = filter.split(separator: " ", omittingEmptySubsequences: false)
            while words.last?.isEmpty == true { words.removeLast() }
            if !words.isEmpty { words.removeLast() }
            setFilter(words.joined(separator: " ") + (words.isEmpty ? "" : " "))
        case .backspace:
            // Backspace on an empty filter leaves it, as in a pager's search.
            if filter.isEmpty { editingFilter = false } else { setFilter(String(filter.dropLast())) }
        case .char("u", .ctrl): setFilter("")
        default: return false
        }
        return true
    }

    private mutating func setFilter(_ text: String) {
        filter = text
        revealedID = nil
        top = 0
        let sessions = sessionIDs
        // A filter narrows to sessions, so the selection goes to a session that shows.
        if isFiltering, selectedID.map(sessions.contains) != true {
            selectedID = sessions.first
        }
        keepSelectionShowing()
    }

    // A session matches on its title, or a troubleshooting one on the word its chip
    // shows, as typed rather than as drawn (`SidebarFilter`).
    static func matches(_ row: RemoteSessionRow, query: String) -> Bool {
        row.title.localizedCaseInsensitiveContains(query)
            || (row.isTroubleshooting && "troubleshoot".localizedCaseInsensitiveContains(query))
    }

    // A container matches on its name, and a workspace on a member project's too.
    static func matches(_ container: RemoteContainer, query: String) -> Bool {
        ([container.name] + (container.members ?? [])).contains { $0.localizedCaseInsensitiveContains(query) }
    }

    // MARK: - Drawing

    // The column at the sidebar's size, every row its full width so the border lines up:
    // the heading, the handover banner while there is one, the Needs you stack and the
    // filter's notice, the tree, then the cleanup strips, Add and Tools, and the key help.
    // Only the tree scrolls. The selection is drawn in reverse while the sidebar has the
    // keys, and keeps only its marker while the main pane has them.
    mutating func frame(size: TerminalSize, focused: Bool, theme: TranscriptTheme,
                        now: Date = Date()) -> [String] {
        let width = max(size.cols, 1)
        var head = [heading(width: width, theme: theme),
                    Self.paint([(" " + arrangement.sort.label + " · "
                                 + (arrangement.grouping == .kind ? arrangement.grouping.label : "Ungrouped"),
                                 Style.dim)], width: width)]
        if let handover {
            head += TranscriptRenderer.wrap("The station is moving to \(handover)…", width: max(width - 1, 1))
                .map { Self.paint([(" " + $0, Style.bold + Style.code(.attention, theme: theme))], width: width) }
        }
        if let silence, refusal == nil {
            head += TranscriptRenderer.wrap(silence, width: max(width - 1, 1))
                .map { Self.paint([(" " + $0, Style.bold + Style.code(.attention, theme: theme))], width: width) }
        }
        if let refusal {
            head += TranscriptRenderer.wrap(refusal, width: max(width - 1, 1))
                .map { Self.paint([(" " + $0, Style.bold + Style.code(.state(.failed), theme: theme))], width: width) }
        }
        head += headLines(width: width, focused: focused, theme: theme)
        let foot = footLines(width: width, focused: focused, theme: theme, now: now)
        let bodyHeight = max(size.rows - head.count - foot.count - 1, 1)

        var body: [String]
        let rows = rows
        if directory == nil {
            body = [Self.paint([("  Loading…", Style.dim)], width: width)]
        } else if rows.isEmpty && isFiltering {
            body = Self.wrapped("Nothing matches “\(query)”.", width: width)
        } else if rows.isEmpty {
            body = Self.wrapped("No projects yet. Add a folder with Add below and the agent will run right inside it.",
                                width: width)
        } else {
            var lines: [String] = []
            var selectedLines: Range<Int>?
            for row in rows {
                let selected = row.id == selectedID
                if selected { selectedLines = lines.count..<(lines.count + row.height) }
                lines += draw(row, width: width, selected: selected, focused: focused, theme: theme, now: now)
            }
            // Keep the selected row on screen, with the row above it when there is room.
            if let selectedLines {
                if selectedLines.lowerBound < top { top = max(selectedLines.lowerBound - 1, 0) }
                if selectedLines.upperBound > top + bodyHeight { top = selectedLines.upperBound - bodyHeight }
            }
            top = min(max(top, 0), max(lines.count - bodyHeight, 0))
            body = Array(lines[top..<min(lines.count, top + bodyHeight)])
        }
        let blank = String(repeating: " ", count: width)
        return head + body + Array(repeating: blank, count: max(bodyHeight - body.count, 0))
            + foot + [footer(width: width, theme: theme)]
    }

    // " Code Station", and on the right, while any session runs, a green count of them.
    private func heading(width: Int, theme: TranscriptTheme) -> String {
        let running = runningCount
        guard running > 0 else { return Self.paint([(" Code Station", Style.bold)], width: width) }
        let count = "● \(running) "
        let room = max(width - TerminalColumns.width(of: count), 0)
        return Self.paint([(TerminalColumns.pad(TerminalColumns.fit(" Code Station", to: room), to: room), Style.bold),
                           (count, Style.state("RUNNING", theme: theme))], width: width)
    }

    // The Needs you stack, then the notice that the open session is outside the filter.
    private func headLines(width: Int, focused: Bool, theme: TranscriptTheme) -> [String] {
        var lines: [String] = []
        let waiting = waiting
        let amber = Style.code(.attention, theme: theme)
        if !waiting.isEmpty {
            lines.append(Self.paint([(" NEEDS YOU", Style.bold + amber), (" \(waiting.count)", Style.bold),
                                     (" · " + KeyBindings.name(of: KeyBindings.jumpKey), Style.dim)], width: width))
            for notice in waiting.prefix(Self.stackShown) {
                let selected = selectedID == Extra.notice(notice).id
                let reversed = selected && focused
                let marker = selected ? "▸ " : "  "
                lines.append(Self.paint([(marker, ""), ("!", Style.bold + amber), (" ", ""),
                                         (notice.row.title, Style.bold)], width: width, reversed: reversed))
                lines.append(Self.paint([("    ", ""), (notice.notice.reason, amber),
                                         (" · " + notice.container.name, Style.dim)], width: width, reversed: reversed))
            }
            if waiting.count > Self.stackShown {
                lines.append(Self.paint([("    +\(waiting.count - Self.stackShown) more", Style.dim)], width: width))
            }
        }
        if let outside = currentOutsideFilter {
            lines += Self.wrapped("Current session is outside this filter.", width: width)
            let selected = selectedID == Extra.showCurrent(outside).id
            lines.append(Self.paint([(selected ? "▸ " : "  ", ""),
                                     ("Show \(outside.name) in sidebar", Style.bold + Style.cyan)],
                                    width: width, reversed: selected && focused))
        }
        return lines
    }

    // The cleanup strips, then Add and Tools on one row.
    private func footLines(width: Int, focused: Bool, theme: TranscriptTheme, now: Date) -> [String] {
        var lines: [String] = []
        let amber = Style.code(.attention, theme: theme)
        for extra in footExtras {
            let selected = selectedID == extra.id
            let reversed = selected && focused
            let marker = selected ? "▸ " : "  "
            switch extra {
            case .oldSessions(let cleanup):
                let days = counted(cleanup.oldSessionDays, "day")
                let title: String
                var detail: [String] = []
                if let deleting = cleanup.oldSessionsDeleting {
                    title = "\(counted(deleting, "session")) will be deleted"
                    detail.append("Older than \(days)")
                    if let at = cleanup.oldSessionsDeletingAt {
                        detail.append("⏱ " + CleanupCountdown.text(until: at, now: now))
                    }
                } else {
                    title = "\(counted(cleanup.oldSessions, "session")) older than \(days)"
                }
                if cleanup.snoozedProjects > 0 {
                    detail.append("\(counted(cleanup.snoozedProjects, "project")) snoozed")
                }
                lines.append(Self.paint([(marker, ""), (title, Style.bold)], width: width, reversed: reversed))
                if !detail.isEmpty {
                    lines.append(Self.paint([("  " + detail.joined(separator: " · "), Style.dim)],
                                            width: width, reversed: reversed))
                }
            case .orphans(let cleanup):
                let size = cleanup.orphanedBytes > 0
                    ? ByteCountFormatter.string(fromByteCount: cleanup.orphanedBytes, countStyle: .file)
                    : "No disk usage"
                var detail = "No session · " + size
                if let at = cleanup.orphansPruneAt { detail += " · ⏱ " + CleanupCountdown.text(until: at, now: now) }
                lines.append(Self.paint([(marker, ""), (counted(cleanup.orphanedWorktrees, "orphaned worktree"),
                                                        Style.bold + amber)], width: width, reversed: reversed))
                lines.append(Self.paint([("  " + detail, amber)], width: width, reversed: reversed))
            case .add, .tools, .notice, .showCurrent:
                break
            }
        }
        // Add and Tools share a row, each drawn in reverse when it is the one selected.
        func entry(_ extra: Extra, _ label: String) -> (text: String, style: String) {
            let selected = selectedID == extra.id
            return ((selected ? "▸" : " ") + label + " ", Style.bold + (selected && focused ? Style.reverse : ""))
        }
        lines.append(Self.paint([entry(.add, "+ Add"), (" ", ""), entry(.tools, "⚙ Tools")], width: width))
        return lines
    }

    // A dim note, wrapped to the column, two spaces in.
    private static func wrapped(_ text: String, width: Int) -> [String] {
        TranscriptRenderer.wrap(text, width: max(width - 2, 1)).map { paint([("  " + $0, Style.dim)], width: width) }
    }

    // The key help, or the filter while one is typed or applied, or a passing notice.
    private func footer(width: Int, theme: TranscriptTheme) -> String {
        if let notice { return Self.paint([(" " + notice, Style.code(.attention, theme: theme))], width: width) }
        guard editingFilter || !filter.isEmpty else {
            return Self.paint([(" ↑↓ move · a actions · ? keys", Style.dim)], width: width)
        }
        return Self.paint([(" / " + filter, Style.bold)], width: width)
    }

    // Where the cursor sits while the filter is being typed: just after its text.
    func filterCursor(size: TerminalSize) -> Screen.Cursor? {
        guard editingFilter else { return nil }
        let column = min(TerminalColumns.width(of: " / " + filter), max(size.cols - 1, 0))
        return Screen.Cursor(row: max(size.rows - 1, 0), col: column)
    }

    private func draw(_ row: Row, width: Int, selected: Bool, focused: Bool,
                      theme: TranscriptTheme, now: Date) -> [String] {
        let marker = selected ? "▸ " : "  "
        let reversed = selected && focused
        switch row {
        case .section(let group, let count, let folded):
            // The count shows only while the section is folded, as in the GUI.
            return [Self.paint([(marker + group.title.uppercased(), Style.bold + Style.dim),
                                (folded ? " \(count)" : "", Style.dim)], width: width, reversed: reversed)]
        case .container(let container, let expanded):
            let glyph = switch container.kind {
            case .project: "■"
            case .task: "□"
            case .workspace: "▤"
            }
            let prefix = marker + glyph + " "
            // The snooze chip counts the days its cleanup still waits, as the GUI's does.
            let snooze = container.snoozedUntil.map { " ☾" + ProjectSnooze.badge(until: $0, now: now) } ?? ""
            let suffix = (container.isPinned ? " ⚑" : "") + snooze + (container.isMissing ? " (missing)" : "")
            // The trailing marks: how many need the person while the cards are folded
            // away, a light while any runs, and the disclosure when there are cards.
            var trailing: [(text: String, style: String)] = []
            if !expanded, container.needsYou > 0 {
                trailing.append((" !\(container.needsYou)", Style.bold + Style.state("NEEDS YOU", theme: theme)))
            }
            if container.running > 0 { trailing.append((" ●", Style.state("RUNNING", theme: theme))) }
            // A task's timer, as the GUI's clock: amber while a run waits to be confirmed.
            if let schedule = container.schedule, schedule.isActive {
                trailing.append(schedule.isWaiting ? (" ◷ confirm", Style.bold + Style.yellow) : (" ◷", Style.cyan))
            }
            if !container.sessions.isEmpty { trailing.append((expanded ? " ▾" : " ▸", Style.dim)) }
            let trailingWidth = trailing.reduce(0) { $0 + TerminalColumns.width(of: $1.text) }
            let room = max(width - TerminalColumns.width(of: prefix) - TerminalColumns.width(of: suffix)
                           - trailingWidth, 1)
            let name = TerminalColumns.fit(container.name, to: room)
            let gap = String(repeating: " ", count: max(room - TerminalColumns.width(of: name), 0))
            return [Self.paint([(prefix, ""), (name, Style.bold), (suffix, Style.dim), (gap, "")] + trailing,
                               width: width, reversed: reversed)]
        case .session(let session, _):
            return drawCard(session, width: width, marker: marker, reversed: reversed, theme: theme, now: now)
        case .more(_, let hidden):
            return [Self.paint([(marker, ""), ("┆", Style.dim), (" See \(hidden) more…", Style.dim)],
                               width: width, reversed: reversed)]
        }
    }

    // A card: the node and title, then the state word with its chips and time, then what
    // the session is doing when there is something to say.
    private func drawCard(_ session: RemoteSessionRow, width: Int, marker: String, reversed: Bool,
                          theme: TranscriptTheme, now: Date) -> [String] {
        let node: (String, String) = session.isUnread ? ("●", Style.code(.attention, theme: theme))
            : session.isPinned ? ("⚑", "") : ("│", Style.dim)
        let title = TerminalColumns.fit(session.title, to: max(width - 4, 1))
        let word = session.failure == nil ? session.state : "FAILED"
        var chips: [(text: String, style: String)] = []
        switch session.worktree {
        case .all: chips.append((" WT", Style.cyan))
        case .partial: chips.append((" MIXED", Style.code(.attention, theme: theme)))
        case nil: break
        }
        if session.isTroubleshooting { chips.append((" TROUBLESHOOT", Style.magenta)) }
        if session.hasUncommittedChanges { chips.append((" ±", Style.code(.attention, theme: theme))) }
        var facts = ""
        if let needsInput = session.needsInput { facts += " · " + needsInput }
        facts += " · " + Self.age(since: session.lastActivity, now: now)
        var lines = [
            Self.paint([(marker, ""), node, (" ", ""), (title, session.isUnread ? Style.bold : "")],
                       width: width, reversed: reversed),
            Self.paint([("  ", ""), ("│", Style.dim), (" ", ""), (word, Style.state(word, theme: theme))]
                       + chips + [(facts, Style.dim)], width: width, reversed: reversed),
        ]
        if let activity = session.activity {
            lines.append(Self.paint([("  ", ""), ("│", Style.dim), (" " + activity, Style.dim)],
                                    width: width, reversed: reversed))
        }
        return lines
    }

    // Runs of text, each in its own style, cut and padded to exactly `width` columns.
    // Each run starts from a reset, so styles never leak from one run into the next, and
    // a reversed row stays reversed across all of them.
    static func paint(_ runs: [(text: String, style: String)], width: Int, reversed: Bool = false) -> String {
        var out = ""
        var used = 0
        for run in runs where used < width {
            let text = TerminalColumns.width(of: run.text) > width - used
                ? TerminalColumns.fit(run.text, to: width - used) : run.text
            used += TerminalColumns.width(of: text)
            out += Style.reset + (reversed ? Style.reverse : "") + run.style + text
        }
        return out + Style.reset + (reversed ? Style.reverse : "")
            + String(repeating: " ", count: max(width - used, 0)) + Style.reset
    }

    // How long ago, in the fewest characters: now, 5m, 3h, 2d, 6w.
    static func age(since date: Date, now: Date) -> String {
        let seconds = max(now.timeIntervalSince(date), 0)
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        case ..<(7 * 86_400): return "\(Int(seconds / 86_400))d"
        default: return "\(Int(seconds / (7 * 86_400)))w"
        }
    }
}
