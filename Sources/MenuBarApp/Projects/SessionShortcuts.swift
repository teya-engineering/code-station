import Foundation
import SwiftUI

// The commands available to a project, sitting in the session's own status row rather
// than on a strip of their own. They belong beside the other readings because they are
// the same kind of thing: what this session is, on one line. A command run here uses this
// session's worktree, so the tests it runs are the tests for the branch on the same row.
//
// Every checkout's commands are here at once. A session with several of them tints each
// chip with its project, rather than making the reader switch, since a command saved
// against one project always runs in that project's checkout anyway.
struct SessionShortcutChips: View {
    @Environment(ShortcutStore.self) private var shortcuts
    @Environment(ProjectStore.self) private var store

    let session: ChatSession
    @Binding var openRun: ShortcutRun?
    let edit: (ShortcutEditorRequest) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Shortcuts")

            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    ForEach(placements) { placement in
                        if let entry = checkout(with: placement.projectID) {
                            chip(placement.shortcut, in: entry)
                        }
                    }
                    newButton
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: - Chips

    private func chip(_ shortcut: CommandShortcut, in entry: Checkout) -> some View {
        let run = run(for: shortcut, in: entry)
        return ShortcutChip(
            shortcut: shortcut,
            state: shortcuts.state(run),
            tint: checkouts.count > 1 ? Theme.projectTint(for: entry.project?.name ?? "") : nil,
            open: openRun == run,
            toggle: { toggle(run) }
        )
        .appContextMenu {
            var entries: [MenuEntry] = [
                shortcuts.state(run).isActive
                    ? .item("Stop", action: { toggle(run) })
                    : .item("Run", action: { toggle(run) }),
                .item("Show output", action: { openRun = run }),
                .item("Edit", action: {
                    edit(ShortcutEditorRequest(shortcut: shortcut,
                                               projectID: entry.checkout.projectID,
                                               projectName: entry.project?.name))
                })
            ]
            if !shortcut.availableInAllProjects {
                entries.append(.separator)
                entries.append(.item("Remove", kind: .destructive, action: {
                    if openRun?.shortcutID == shortcut.id { openRun = nil }
                    shortcuts.remove(shortcut.id)
                }))
            }
            return entries
        }
    }

    // Dashed and wordless, so the one control that makes something new neither reads as
    // another saved command nor takes the room of one.
    private var newButton: some View {
        Image(systemName: "plus")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            .appMenu { newMenu }
            .appTooltip("Save a command for this project")
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

    // Anything made from here starts as a command for the session's own project. The
    // editor can share it with every project instead.
    private var blankRequest: ShortcutEditorRequest {
        ShortcutEditorRequest(projectID: session.projectID,
                              projectName: store.project(session.projectID)?.name)
    }

    // MARK: - The checkouts behind the chips

    private struct Checkout {
        let checkout: SessionProject
        let project: Project?
    }

    private var checkouts: [Checkout] {
        store.checkoutProjects(for: session).map {
            Checkout(checkout: $0, project: store.project($0.projectID))
        }
    }

    private var placements: [ShortcutPlacement] {
        shortcuts.shortcuts(for: checkouts.map(\.checkout.projectID))
    }

    private func checkout(with projectID: UUID) -> Checkout? {
        checkouts.first { $0.checkout.projectID == projectID }
    }

    private func run(for shortcut: CommandShortcut, in entry: Checkout) -> ShortcutRun {
        ShortcutRun(shortcut.id,
                    in: shortcut.directory(projectPath: entry.project?.path,
                                           workspacePath: entry.checkout.worktreePath))
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

// A saved command as one small control: click runs it, click again stops it. It carries
// its name and a single glyph for how the last run went - a tick, a pulse, an exclamation
// - because a row of these shares a line with everything else the session has to say, and
// anything more makes that line unreadable. The timing and the output are in the drawer,
// which opens on its own the moment a run starts.
private struct ShortcutChip: View {
    let shortcut: CommandShortcut
    let state: ShortcutStore.State
    // Set only for a session spanning several checkouts, where the checkout this command
    // runs in matters and the name alone does not say.
    let tint: Theme.ProjectTint?
    let open: Bool
    let toggle: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                if let tint { ProjectDot(tint: tint, size: 6) }
                if shortcut.availableInAllProjects {
                    Image(systemName: "globe")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .accessibilityLabel("Available in all projects")
                }
                Text(shortcut.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                stateGlyph
            }
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(borderColour))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state.isActive ? "Stop \(shortcut.name)" : "Run \(shortcut.name)")
        .appTooltip { Tooltip(title: tooltip, subtitle: shortcut.command) }
    }

    @ViewBuilder private var stateGlyph: some View {
        switch state {
        case .stopped:
            EmptyView()
        case .running:
            // A run has no other reading on the chip, so the dot has to be the thing
            // that says it is still going rather than already done.
            Circle()
                .fill(Theme.dotOn)
                .frame(width: 6, height: 6)
                .modifier(Pulse(active: !reduceMotion))
        case .finished:
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.addition)
        case .failed:
            Image(systemName: "exclamationmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.deletion)
        }
    }

    private var tooltip: String {
        switch state {
        case .stopped: "Run \(shortcut.name)"
        case .running(let since): "Running for \(RelativeTime.duration(since: since)). Click to stop."
        case .finished(let at): "Finished \(RelativeTime.duration(since: at)) ago"
        case .failed(_, let status, let at):
            status.map { "Exited with code \($0) \(RelativeTime.duration(since: at)) ago" }
                ?? "Failed \(RelativeTime.duration(since: at)) ago"
        }
    }

    private var borderColour: Color {
        if state.isFailure { return Theme.deletion.opacity(0.55) }
        if open || state.isActive { return Theme.accent.opacity(0.55) }
        return Theme.border
    }
}

// The one moving thing on the row, and only while a command is actually running.
private struct Pulse: ViewModifier {
    let active: Bool
    @State private var faded = false

    func body(content: Content) -> some View {
        content
            .opacity(active && faded ? 0.35 : 1)
            .animation(active ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                              : nil,
                       value: faded)
            .onAppear { if active { faded = true } }
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
                Text("Close")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.deletion)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field))
                    .contentShape(RoundedRectangle(cornerRadius: 7))
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
