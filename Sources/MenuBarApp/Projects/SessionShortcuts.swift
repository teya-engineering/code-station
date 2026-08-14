import Foundation
import SwiftUI

// A project's saved commands, on a strip inside the session that is going to run them.
// They live here rather than in a sheet because the folder they run in is the session's:
// a workspace shortcut means this session's worktree, so the tests it runs are the tests
// for the branch on screen and not the ones in the folder that branch came from.
//
// The strip speaks for one checkout at a time. A session with several of them gets a
// switch on the right, since a command saved against one project has no business running
// in another's worktree.
struct SessionShortcutStrip: View {
    @Environment(ShortcutStore.self) private var shortcuts
    @Environment(ProjectStore.self) private var store

    let session: ChatSession
    @Binding var checkoutProjectID: UUID?
    @Binding var openRun: ShortcutRun?
    let edit: (ShortcutEditorRequest) -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text("SHORTCUTS")
                    .font(.mono(10.5, .semibold))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
            }
            .fixedSize()

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(owned) { shortcut in
                        chip(shortcut)
                    }
                    newButton
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)

            Spacer(minLength: 8)
            folderCaption
        }
        .padding(.horizontal, 20)
        .headerBand(Theme.statusBand, height: Theme.statusBandHeight + 12)
    }

    // MARK: - Chips

    private func chip(_ shortcut: CommandShortcut) -> some View {
        let run = run(for: shortcut)
        return ShortcutChip(
            shortcut: shortcut,
            state: shortcuts.state(run),
            open: openRun == run,
            toggle: { toggle(run) },
            show: { openRun = openRun == run ? nil : run }
        )
        .appContextMenu {
            [
                shortcuts.state(run).isActive
                    ? .item("Stop", action: { toggle(run) })
                    : .item("Run", action: { toggle(run) }),
                .item("Show output", action: { openRun = run }),
                .item("Edit", action: { edit(ShortcutEditorRequest(shortcut: shortcut)) }),
                .separator,
                .item("Remove", kind: .destructive, action: {
                    if openRun?.shortcutID == shortcut.id { openRun = nil }
                    shortcuts.remove(shortcut.id)
                })
            ]
        }
    }

    // Dashed rather than filled, so the one control that makes something new does not
    // read as another saved command.
    private var newButton: some View {
        HStack(spacing: 5) {
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .bold))
            Text("New")
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
        .appMenu { newMenu }
        .accessibilityLabel("New shortcut")
    }

    private var newMenu: [MenuEntry] {
        var entries: [MenuEntry] = [
            .item("New shortcut…", action: { edit(blankRequest) })
        ]
        // The command the agent just ran is the one most worth keeping, and it has
        // already been typed once.
        if let command = SessionShortcuts.lastAgentCommand(in: session) {
            entries.append(.item("Save last terminal command",
                                 subtitle: command,
                                 action: {
                                     var request = blankRequest
                                     request.command = command
                                     edit(request)
                                 }))
        }
        return entries
    }

    private var blankRequest: ShortcutEditorRequest {
        ShortcutEditorRequest(projectID: checkout?.projectID,
                              location: checkout?.worktreePath == nil
                                  ? .projectFolder : .activeWorkspace)
    }

    // MARK: - Which folder

    // Names the folder the chips run in. With one checkout it is a caption; with several
    // it is the switch that decides both the folder and whose shortcuts are on the strip.
    @ViewBuilder private var folderCaption: some View {
        let checkouts = store.checkoutProjects(for: session)
        if checkouts.count > 1 {
            folderLabel(chevron: true)
                .appMenu {
                    checkouts.compactMap { checkout in
                        guard let project = store.project(checkout.projectID) else { return nil }
                        return .item(project.name,
                                     checked: checkout.projectID == checkoutProjectID,
                                     subtitle: checkout.worktreePath == nil
                                         ? "Project folder" : "Worktree",
                                     action: { checkoutProjectID = checkout.projectID })
                    }
                }
                .accessibilityLabel("Choose which checkout the shortcuts run in")
        } else {
            folderLabel(chevron: false)
        }
    }

    private func folderLabel(chevron: Bool) -> some View {
        HStack(spacing: 5) {
            Text(folderText)
                .font(.mono(10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if chevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .fixedSize()
        .contentShape(Rectangle())
    }

    private var folderText: String {
        let checkouts = store.checkoutProjects(for: session)
        let place = checkout?.worktreePath == nil ? "the project folder" : "this worktree"
        guard checkouts.count > 1, let name = checkoutProject?.name else { return "in \(place)" }
        return "\(name) · \(place)"
    }

    // MARK: - The checkout on the strip

    private var checkout: SessionProject? {
        let checkouts = store.checkoutProjects(for: session)
        return checkouts.first { $0.projectID == checkoutProjectID } ?? checkouts.first
    }

    private var checkoutProject: Project? {
        checkout.flatMap { store.project($0.projectID) }
    }

    private var owned: [CommandShortcut] {
        checkout.map { shortcuts.shortcuts(for: $0.projectID) } ?? []
    }

    private func run(for shortcut: CommandShortcut) -> ShortcutRun {
        ShortcutRun(shortcut.id,
                    in: shortcut.directory(projectPath: checkoutProject?.path,
                                           workspacePath: checkout?.worktreePath))
    }

    private func toggle(_ run: ShortcutRun) {
        if shortcuts.state(run).isActive {
            shortcuts.stop(run)
        } else {
            shortcuts.start(run)
            openRun = run
        }
    }
}

// MARK: - One chip

// A saved command as a control: the glyph runs it, everything else opens its output.
// It carries only state - a tick and how long ago, the seconds it has been running, or
// the code it came back with - because the name is what identifies it and anything more
// makes a row of them unreadable.
private struct ShortcutChip: View {
    let shortcut: CommandShortcut
    let state: ShortcutStore.State
    let open: Bool
    let toggle: () -> Void
    let show: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Button(action: toggle) {
                Image(systemName: state.isActive ? "stop.fill" : "play.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(state.isActive ? Theme.deletion : .secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state.isActive ? "Stop \(shortcut.name)"
                                               : "Run \(shortcut.name)")

            Button(action: show) {
                HStack(spacing: 7) {
                    Text(shortcut.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    stateLabel
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderColour))
        .fixedSize()
    }

    // The seconds have to keep moving while a command runs, and an age has to keep
    // growing after it stops, so the reading is redrawn on a clock rather than only
    // when the store next changes.
    @ViewBuilder private var stateLabel: some View {
        if let since = state.since {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 5) {
                    switch state {
                    case .running:
                        Circle().fill(Theme.dotOn).frame(width: 5, height: 5)
                        age(since)
                    case .finished:
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.addition)
                        age(since)
                    case .failed(_, let status, _):
                        Text(status.map { "exit \($0)" } ?? "failed")
                            .font(.mono(10.5, .semibold))
                            .foregroundStyle(Theme.deletion)
                    case .stopped:
                        EmptyView()
                    }
                }
            }
        }
    }

    private func age(_ since: Date) -> some View {
        Text(RelativeTime.duration(since: since))
            .font(.mono(10.5))
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }

    private var borderColour: Color {
        if state.isFailure { return Theme.deletion.opacity(0.55) }
        if open { return Theme.accent.opacity(0.55) }
        return Theme.border
    }
}

// MARK: - Output

// Where a chip's run went, docked under the content the way the terminal is. It is a
// captured log rather than a shell: the point of a shortcut is that it reports how it
// ended, which a live terminal cannot be asked.
struct ShortcutOutputDrawer: View {
    @Environment(ShortcutStore.self) private var shortcuts

    let run: ShortcutRun
    let onClose: () -> Void

    private static let bottom = "shortcut-drawer-bottom"

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.hairline)
            strip
            Divider().overlay(Theme.hairline)
            ScrollViewReader { scroller in
                ScrollView {
                    Text(text)
                        .font(.mono(11))
                        .foregroundStyle(log.isEmpty ? AnyShapeStyle(.secondary)
                                                     : AnyShapeStyle(.primary))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .onChange(of: log) { _, _ in
                    scroller.scrollTo(Self.bottom, anchor: .bottom)
                }
            }
            .frame(height: 240)
        }
        .background(Theme.card)
    }

    private var strip: some View {
        HStack(spacing: 8) {
            Text("OUTPUT")
                .font(.mono(10.5, .semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)
            if let name = shortcuts.shortcut(run.shortcutID)?.name {
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            Text(status)
                .font(.mono(10.5))
                .foregroundStyle(statusColour)
                .lineLimit(1)

            Spacer(minLength: 12)

            if !log.isEmpty {
                Button { shortcuts.clearLog(run) } label: {
                    Text("Clear")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field))
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide the output")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Theme.card)
    }

    private var log: String { shortcuts.log(run) }

    private var text: String {
        if !log.isEmpty { return log }
        switch shortcuts.state(run) {
        case .stopped: return "Run this shortcut to see its output."
        case .running: return "Waiting for output…"
        case .finished: return "Finished without output."
        case .failed(let message, _, _): return message
        }
    }

    private var status: String {
        switch shortcuts.state(run) {
        case .stopped: "not running"
        case .running(let since): "running · \(RelativeTime.duration(since: since))"
        case .finished: "exit 0"
        case .failed(_, let code, _): code.map { "exit \($0)" } ?? "failed"
        }
    }

    private var statusColour: Color {
        switch shortcuts.state(run) {
        case .failed: Theme.deletion
        case .finished: Theme.addition
        default: .secondary
        }
    }
}

// MARK: - Promoting what the agent ran

enum SessionShortcuts {
    // The last shell command the agent ran in this session, for the menu entry that
    // turns it into a saved shortcut. Only single-line commands are offered: a chip
    // names one thing, and a heredoc pasted into a chip name is not that.
    static func lastAgentCommand(in session: ChatSession) -> String? {
        for message in session.messages.reversed() where message.role == .assistant {
            for tool in message.tools.reversed() where tool.name == "Bash" {
                guard let command = command(in: tool.input) else { continue }
                return command
            }
        }
        return nil
    }

    // Claude Code sends a call's input as JSON, while Codex hands over the command
    // itself, so a shell call arrives in one of two shapes under the same name.
    private static func command(in input: String) -> String? {
        let object = (try? JSONSerialization.jsonObject(with: Data(input.utf8)))
            as? [String: Any]
        let command = object.map { $0["command"] as? String ?? "" } ?? input
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n") else { return nil }
        return trimmed
    }
}
