import CodeStationCore
import Foundation
import TerminalKit
import TerminalTranscript

// A project, task or workspace in the main pane, as the GUI's detail screens show one.
// Its top bar names it, and the status strip under that reads how it stands: a project's
// checkout (branch, ahead and behind, clean or how many files are uncommitted, the last
// commit), a workspace's projects and lead, a task's last run, runs, inputs and next
// run. Under the top bar it lists its sessions (a task's runs), a workspace's projects
// first.
//
// View state only: the container as the directory last listed it, the strip's readings
// once the station has answered, and which session is selected.
struct ContainerScreen {
    private(set) var container: RemoteContainer
    private(set) var status: RemoteContainerStatus?
    // A task as the station last read it: its prompt, inputs, schedule and runs.
    private(set) var task: RemoteTask?
    // Which of a task's runs are listed, as the GUI's run filter pills choose.
    private(set) var runFilter: TaskRunHistory.Filter = .all
    // Why the strip could not be read, when it could not.
    var notice: String?
    // A project's or task's shortcuts, for the count at the end of its strip.
    var shortcuts: RemoteShortcuts?
    private var selectedID: String?
    private var top = 0
    private let theme: TranscriptTheme

    // The rows its top bar takes: the identity row and the status strip.
    static let topBarRows = 2

    init(_ container: RemoteContainer, theme: TranscriptTheme) {
        self.container = container
        self.theme = theme
        selectedID = container.sessions.first?.id
    }

    var id: String { container.id }

    // The history place this screen is: a task is a project made for a prompt.
    var place: NavigationPlace? {
        guard let uuid = UUID(uuidString: container.id) else { return nil }
        return container.kind == .workspace ? .workspace(uuid) : .project(uuid)
    }

    // MARK: - Updates

    // The container as a fresh list has it. False when it has gone.
    mutating func show(_ directory: RemoteDirectory) -> Bool {
        guard let fresh = directory.containers?.first(where: { $0.id == container.id }) else { return false }
        container = fresh
        keepSelection()
        return true
    }

    mutating func show(_ task: RemoteTask) {
        self.task = task
        keepSelection()
    }

    // The next run filter: All, Scheduled, Failed, and round again.
    mutating func cycleFilter() {
        let all = TaskRunHistory.Filter.allCases
        runFilter = all[((all.firstIndex(of: runFilter) ?? 0) + 1) % all.count]
        keepSelection()
    }

    // A selection that has gone falls back to the first run of a task, or the first
    // session of anything else (not a workspace's first project).
    private mutating func keepSelection() {
        let ids = rowIDs
        if selectedID.map({ !ids.contains($0) }) ?? true {
            selectedID = container.kind == .task ? ids.first : container.sessions.first?.id
        }
    }

    // A task's runs as the filter lists them, newest first.
    var shownRuns: [RemoteTaskRun] {
        guard let task else { return [] }
        switch runFilter {
        case .all: return task.runs
        case .scheduled: return task.runs.filter(\.isScheduled)
        case .failed: return task.runs.filter { $0.failure != nil }
        }
    }

    // The rows the selection moves over: a task's runs once it is read, else a
    // workspace's projects and then the sessions.
    private var rowIDs: [String] {
        if container.kind == .task, task != nil { return shownRuns.map(\.sessionID) }
        return (status?.members?.map(\.projectID) ?? []) + container.sessions.map(\.id)
    }

    // The session or run under the pointer, not a workspace project.
    var selectedSessionID: String? {
        selectedID.flatMap { rowIDs.contains($0) && selectedMember == nil ? $0 : nil }
    }

    mutating func show(_ status: RemoteContainerStatus) {
        self.status = status
        notice = nil
    }

    // MARK: - Moving

    var selected: RemoteSessionRow? { container.sessions.first { $0.id == selectedID } }

    // The workspace project under the pointer, when it is on one.
    var selectedMember: RemoteWorkspaceMember? { status?.members?.first { $0.projectID == selectedID } }

    // From nowhere, up goes to the last row and down to the first.
    mutating func move(by offset: Int) {
        let ids = rowIDs
        guard !ids.isEmpty else { return }
        guard let current = selectedID.flatMap(ids.firstIndex(of:)) else {
            selectedID = offset < 0 ? ids.last : ids.first
            return
        }
        selectedID = ids[min(max(current + offset, 0), ids.count - 1)]
    }

    mutating func moveToFirst() { selectedID = rowIDs.first }
    mutating func moveToLast() { selectedID = rowIDs.last }

    // MARK: - The top bar

    typealias Run = (text: String, style: String)

    func topBar(width: Int, now: Date) -> [String] {
        let width = max(width, 1)
        let glyph = switch container.kind {
        case .task: "□"
        case .workspace: "▤"
        case .project: "■"
        }
        let identity = SidebarView.paint([(" \(glyph) ", ""), (container.name, Style.bold)], width: width)
        return [identity, strip(width: width, now: now)]
    }

    // The readings on the left, and what sits at the end of the row on the right while
    // there is room for both.
    private func strip(width: Int, now: Date) -> String {
        let (left, right) = readings(now: now)
        let used = Self.width(of: left) + Self.width(of: right)
        let runs = right.isEmpty || used + 3 > width ? left
            : left + [(String(repeating: " ", count: width - used - 1), "")] + right
        return SidebarView.paint(runs, width: width)
    }

    private func readings(now: Date) -> (left: [Run], right: [Run]) {
        if let notice { return ([(" " + notice, Style.red)], []) }
        switch container.kind {
        case .project:
            let (left, right) = projectReadings(now: now)
            return (left + shortcutRuns, right)
        case .workspace: return (workspaceReadings(), [])
        case .task: return (taskReadings(now: now) + shortcutRuns, [])
        }
    }

    // " ⎇ main ↑1 ↓2  1 UNCOMMITTED FILE" … "JUST NOW · first".
    private func projectReadings(now: Date) -> (left: [Run], right: [Run]) {
        guard let checkout = status?.checkout else { return ([(" Reading git…", Style.dim)], []) }
        guard checkout.state == "ready" else { return ([(" " + Self.verdict(checkout.state), Style.dim)], []) }
        var left = Self.checkoutRuns(checkout)
        left.insert((" ", ""), at: 0)
        let right: [Run] = if let subject = checkout.lastCommitSubject {
            (checkout.lastCommitDate.map { [(Self.ago($0, now: now), Style.dim), (" · ", Style.dim)] } ?? [])
                + [(subject, "")]
        } else {
            [("nothing committed yet", Style.dim)]
        }
        return (left, right)
    }

    // " WORKSPACE · 2 PROJECTS  ■ alpha · main  1 WITH UNCOMMITTED WORK".
    private func workspaceReadings() -> [Run] {
        let members = status?.members
        let count = members?.count ?? container.path.split(separator: ",").count
        var runs: [Run] = [(" WORKSPACE · \(count) PROJECTS", Style.cyan)]
        guard let members else { return runs + [("  Reading git…", Style.dim)] }
        if let lead = members.first(where: \.isLead) {
            runs.append(("  ■ ", Style.dim))
            runs.append((lead.name, Style.bold))
            if let branch = lead.checkout?.branch, lead.checkout?.state == "ready", !branch.isEmpty {
                runs.append((" · " + branch, ""))
            }
        }
        let dirty = members.count { ($0.checkout?.uncommitted ?? 0) > 0 }
        if dirty > 0 { runs.append(("  \(dirty) WITH UNCOMMITTED WORK", Style.yellow)) }
        return runs
    }

    // " IDLE · 1m  1 RUN · 2 INPUTS  Next run in 14m", or " NEVER RUN …".
    private func taskReadings(now: Date) -> [Run] {
        guard let task = status?.task else { return [(" Reading the task…", Style.dim)] }
        var runs: [Run] = []
        if let last = task.lastRun {
            let style = Style.state(last.state, theme: theme)
            runs += [(" " + last.state, style), (" · " + SidebarView.age(since: last.at, now: now), Style.dim)]
        } else {
            runs.append((" NEVER RUN", Style.dim))
        }
        var counts = "\(task.runs) \(task.runs == 1 ? "RUN" : "RUNS")"
        if task.inputs > 0 { counts += " · \(task.inputs) \(task.inputs == 1 ? "INPUT" : "INPUTS")" }
        runs.append(("  " + counts, ""))
        if let next = task.nextRunAt {
            runs.append(("  Next run in " + TopBarView.duration(since: now, now: next), Style.cyan))
        }
        return runs
    }

    // The GUI's shortcuts chip: "  ⚡ 3", with how many run or failed, or "⚡ Add" for a
    // project with none saved. `!` opens them.
    private var shortcutRuns: [Run] {
        guard let shortcuts else { return [] }
        let saved = shortcuts.shortcuts.count
        var runs: [Run] = [("  ⚡ " + (saved == 0 ? "Add" : "\(saved)"),
                            shortcuts.running > 0 ? Style.cyan : shortcuts.failed > 0 ? Style.red : Style.dim)]
        if shortcuts.running > 0 { runs.append((" ● \(shortcuts.running) running", Style.cyan)) }
        if shortcuts.failed > 0 { runs.append((" ✗ \(shortcuts.failed) failed", Style.red)) }
        return runs
    }

    // "⎇ main ↑1 ↓2  CLEAN", for a project's strip and a workspace's project rows.
    static func checkoutRuns(_ checkout: RemoteCheckoutReading) -> [Run] {
        var runs: [Run] = [("⎇ " + (checkout.branch.isEmpty ? "detached" : checkout.branch), "")]
        if checkout.ahead > 0 { runs.append((" ↑\(checkout.ahead)", Style.dim)) }
        if checkout.behind > 0 { runs.append((" ↓\(checkout.behind)", Style.dim)) }
        let dirty = checkout.uncommitted
        runs.append(dirty == 0 ? ("  CLEAN", Style.dim)
                    : ("  \(dirty) UNCOMMITTED \(dirty == 1 ? "FILE" : "FILES")", Style.yellow))
        return runs
    }

    // What the strip says in place of a checkout git could not read.
    static func verdict(_ state: String) -> String {
        switch state {
        case "notARepo": "NOT A GIT REPOSITORY"
        case "missingFolder": "FOLDER NOT FOUND"
        case "gitMissing": "GIT NOT FOUND ON PATH"
        default: "GIT COULD NOT READ THIS FOLDER"
        }
    }

    // "JUST NOW", "5M AGO": when the last commit landed.
    private static func ago(_ date: Date, now: Date) -> String {
        let short = SidebarView.age(since: date, now: now)
        return short == "now" ? "JUST NOW" : "\(short.uppercased()) AGO"
    }

    private static func width(of runs: [Run]) -> Int {
        runs.reduce(0) { $0 + TerminalColumns.width(of: $1.text) }
    }

    // MARK: - The body

    mutating func frame(size: TerminalSize, focused: Bool, now: Date) -> [String] {
        let width = max(size.cols, 1)
        var lines: [String] = []
        var selectedLine: Int?
        if container.kind == .workspace {
            lines.append(SidebarView.paint([(" PROJECTS", Style.bold + Style.dim)], width: width))
            if let members = status?.members {
                for member in members {
                    let selected = focused && member.projectID == selectedID
                    if selected { selectedLine = lines.count }
                    lines.append(memberLine(member, width: width, selected: selected))
                }
            } else {
                lines.append(SidebarView.paint([("  Reading git…", Style.dim)], width: width))
            }
            lines.append("")
        }
        if container.kind == .task, let task {
            lines += taskLines(task, width: width, now: now)
            if shownRuns.isEmpty {
                let none = task.runs.isEmpty ? "  Not run yet. Press n to run it."
                    : runFilter == .scheduled ? "  No scheduled runs." : "  No failed runs."
                lines.append(SidebarView.paint([(none, Style.dim)], width: width))
            }
            var day: Date?
            for run in shownRuns {
                let start = Calendar.current.startOfDay(for: run.createdAt)
                if start != day {
                    day = start
                    lines.append(SidebarView.paint([(" " + TaskRunHistory.dayTitle(start, now: now), Style.dim)],
                                                   width: width))
                }
                let selected = focused && run.sessionID == selectedID
                if selected { selectedLine = lines.count }
                lines.append(runLine(run, width: width, selected: selected, now: now))
            }
        } else {
        lines.append(SidebarView.paint([(container.kind == .task ? " RUNS" : " SESSIONS", Style.bold + Style.dim)],
                                       width: width))
        if container.sessions.isEmpty {
            let none = container.kind == .task ? "  Never run." : "  No sessions yet. Press n to start one."
            lines.append(SidebarView.paint([(none, Style.dim)], width: width))
        }
        for row in container.sessions {
            let selected = focused && row.id == selectedID
            if selected { selectedLine = lines.count }
            lines.append(sessionLine(row, width: width, selected: selected, now: now))
        }
        }
        let height = max(size.rows - 1, 1)
        if let selectedLine {
            if selectedLine < top { top = max(selectedLine - 1, 0) }
            if selectedLine >= top + height { top = selectedLine - height + 1 }
        }
        top = min(max(top, 0), max(lines.count - height, 0))
        var shown = Array(lines[top..<min(lines.count, top + height)])
        shown += Array(repeating: "", count: max(height - shown.count, 0))
        let keys = switch container.kind {
        case .workspace:
            " jk move · enter open · n new session · l make lead · w worktree · d changes · r read · esc back"
        case .task:
            " n run · e edit · i inputs · s schedule · f filter" + (container.schedule?.isWaiting == true ? " · c confirm" : "")
                + " · ! shortcuts · enter open · esc back"
        case .project:
            " ↑↓/jk move · enter open · n new session · ! shortcuts · P/U/F push pull fetch · B branch · r read again · esc back"
        }
        let help = SidebarView.paint([(keys, Style.dim)], width: width)
        return shown + [help]
    }

    // A task's prompt, inputs and schedule, then the heading of its runs, as the GUI's
    // task screen lays out its prompt card, its settings and its run list.
    private func taskLines(_ task: RemoteTask, width: Int, now: Date) -> [String] {
        var lines = [SidebarView.paint([(" PROMPT", Style.bold + Style.dim), ("  e edit", Style.dim)], width: width)]
        if task.prompt.isEmpty {
            lines.append(SidebarView.paint([("  No prompt yet. Press e to write one.", Style.dim)], width: width))
        } else {
            let wrapped = task.prompt.split(separator: "\n", omittingEmptySubsequences: false)
                .flatMap { TranscriptRenderer.wrap(String($0), width: max(width - 4, 1)) }
            lines += wrapped.prefix(6).map { SidebarView.paint([("  " + $0, "")], width: width) }
            if wrapped.count > 6 { lines.append(SidebarView.paint([("  …", Style.dim)], width: width)) }
        }
        if let agent = task.agent { lines.append(SidebarView.paint([("  runs with " + agent.title, Style.dim)], width: width)) }
        lines.append("")
        lines.append(SidebarView.paint([(" INPUTS", Style.bold + Style.dim), ("  i edit", Style.dim)], width: width))
        if task.inputs.isEmpty {
            lines.append(SidebarView.paint([("  None yet. Write {{ticket}} in the prompt and every run asks for a ticket first.",
                                             Style.dim)], width: width))
        }
        for input in task.inputs {
            lines.append(SidebarView.paint([("  {{\(input.name)}}", Style.cyan), ("  " + input.title, ""),
                                            ("  " + input.kind.title.lowercased() + (input.required ? "" : ", optional"),
                                             Style.dim)], width: width))
        }
        lines.append("")
        let schedule = task.schedule
        let state: Run = schedule?.isWaitingForConfirmation == true && schedule?.isActive == true
            ? ("CONFIRM", Style.yellow) : schedule?.isActive == true ? ("ON", Style.cyan) : ("OFF", Style.dim)
        lines.append(SidebarView.paint([(" SCHEDULE  ", Style.bold + Style.dim), state, ("  s change", Style.dim)],
                                       width: width))
        if let schedule, schedule.isActive {
            var parts = [schedule.summary]
            if schedule.isWaitingForConfirmation {
                parts.append("Waiting for you to confirm the next run")
            } else if let next = schedule.nextRunAt {
                parts.append("Next run in " + TopBarView.duration(since: now, now: next))
            }
            if let maximum = schedule.maximumRuns { parts.append("\(schedule.completedRuns) of \(maximum) runs done") }
            if schedule.timing == .interval, schedule.requiresConfirmation { parts.append("asks first") }
            lines.append(SidebarView.paint([("  " + parts.joined(separator: " · "),
                                             schedule.isWaitingForConfirmation ? Style.yellow : "")], width: width))
            if schedule.isWaitingForConfirmation {
                lines.append(SidebarView.paint([("  Press c to run it, skip it or turn the timer off.", Style.yellow)],
                                               width: width))
            }
        } else if let schedule, schedule.hasReachedMaximum, schedule.completedRuns > 0 {
            lines.append(SidebarView.paint([("  Finished after \(schedule.completedRuns) scheduled runs. Runs only when you run it now.",
                                             Style.dim)], width: width))
        } else {
            lines.append(SidebarView.paint([("  Runs only when you run it.", Style.dim)], width: width))
        }
        lines.append("")
        var heading: [Run] = [(" RUNS", Style.bold + Style.dim), (" \(task.runs.count)  ", Style.dim)]
        for filter in TaskRunHistory.Filter.allCases {
            heading.append((filter == runFilter ? "[\(filter.title)]" : " \(filter.title) ", filter == runFilter ? Style.bold : Style.dim))
        }
        heading.append(("  f filter", Style.dim))
        lines.append(SidebarView.paint(heading, width: width))
        return lines
    }

    // "▸ │ Review PR 12   Scheduled · pr 12      14:02 · 4m 12s", as the GUI's `TaskRunRow`.
    private func runLine(_ run: RemoteTaskRun, width: Int, selected: Bool, now: Date) -> String {
        let live = run.state == "RUNNING" || run.state == "WAITING"
        let node: Run = run.failure != nil ? ("●", Style.red) : live ? ("●", Style.state(run.state, theme: theme)) : ("│", Style.dim)
        let time = run.createdAt.formatted(date: .omitted, time: .shortened)
        let took = live ? "working " + TopBarView.duration(since: run.createdAt, now: now)
            : run.lastActivity > run.createdAt ? TaskRunHistory.duration(run.lastActivity.timeIntervalSince(run.createdAt)) : ""
        let right = "  " + time + (took.isEmpty ? "" : " · " + took)
        let trigger = live ? run.state : run.isScheduled ? "Scheduled" : "Run by you"
        let about = run.failure.map { "Stopped: " + ($0.split(whereSeparator: \.isNewline).first.map(String.init) ?? $0) }
            ?? (run.given.isEmpty ? "" : run.given)
        let room = max(width - 4 - TerminalColumns.width(of: right), min(12, width))
        let titleRoom = max(min(TerminalColumns.width(of: run.title), room / 2), min(room, 8))
        let title = TerminalColumns.fit(run.title, to: titleRoom)
        let meta = TerminalColumns.fit("  " + trigger + (about.isEmpty ? "" : " · " + about),
                                       to: max(room - TerminalColumns.width(of: title), 0))
        let used = 4 + TerminalColumns.width(of: title) + TerminalColumns.width(of: meta) + TerminalColumns.width(of: right)
        return SidebarView.paint([(selected ? "▸ " : "  ", ""), node, (" ", ""), (title, Style.bold),
                                  (meta, run.failure != nil ? Style.red : Style.dim),
                                  (String(repeating: " ", count: max(width - used, 0)), ""), (right, Style.dim)],
                                 width: width, reversed: selected)
    }

    // "▸ ■ alpha  lead · worktree  ⎇ main  CLEAN".
    private func memberLine(_ member: RemoteWorkspaceMember, width: Int, selected: Bool) -> String {
        var runs: [Run] = [(selected ? "▸ ■ " : "  ■ ", Style.dim), (member.name, Style.bold)]
        if member.isLead { runs.append(("  lead", Style.cyan)) }
        if let worktree = member.usesWorktree {
            runs.append((worktree ? "  worktree" : "  folder", Style.dim))
        }
        runs.append(("  ", ""))
        if let checkout = member.checkout, checkout.state == "ready" {
            runs += Self.checkoutRuns(checkout)
        } else {
            runs.append((Self.verdict(member.checkout?.state ?? "").lowercased(), Style.dim))
        }
        return SidebarView.paint(runs, width: width, reversed: selected)
    }

    // "▸ │ Fix the login bug   IDLE · 2m".
    private func sessionLine(_ row: RemoteSessionRow, width: Int, selected: Bool, now: Date) -> String {
        let node: Run = row.isUnread ? ("●", Style.code(.attention, theme: theme))
            : row.isPinned ? ("⚑", "") : ("│", Style.dim)
        let word = row.failure == nil ? row.state : "FAILED"
        let facts = "  " + word + " · " + SidebarView.age(since: row.lastActivity, now: now)
        let room = max(width - 4 - TerminalColumns.width(of: facts), min(12, width))
        return SidebarView.paint([(selected ? "▸ " : "  ", ""), node, (" ", ""),
                                  (TerminalColumns.fit(row.title, to: room), row.isUnread ? Style.bold : ""),
                                  ("  " + word, Style.state(word, theme: theme)),
                                  (" · " + SidebarView.age(since: row.lastActivity, now: now), Style.dim)],
                                 width: width, reversed: selected)
    }
}
