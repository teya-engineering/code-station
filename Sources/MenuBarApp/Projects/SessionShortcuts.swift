import AppKit
import Foundation
import SwiftUI

// The commands available to a project, docked at the end of the composer's own row
// rather than on a strip of their own. They belong there because running the tests for
// what was just written is the next thing that happens as much as sending another prompt
// is. A command run here uses this session's worktree, so the tests it runs are the tests
// for the branch this session is on.
//
// Every checkout's commands are here at once. A session with several of them tints each
// chip with its project, rather than making the reader switch, since a command saved
// against one project always runs in that project's checkout anyway.
struct SessionShortcutChips: View {
    @Environment(ShortcutStore.self) private var shortcuts
    @Environment(ProjectStore.self) private var store

    let session: ChatSession
    let edit: (ShortcutEditorRequest) -> Void

    // The width the rest of the run-choices row left for the commands, which is what the
    // fit is decided against.
    @State private var rowWidth: CGFloat = 0

    private var scope: ShortcutScope { .session(session.id) }

    var body: some View {
        // The strip is the only part of this that stretches, so it is handed the whole
        // of what the rest of the row left and the fit is decided against that. Anything
        // else flexible beside it - a spacer, say - would take a share of that width and
        // leave the chips squeezed into less room than they were measured for.
        HStack(spacing: ShortcutChipFit.gap) {
            strip

            // Outside the strip: it makes something new rather than being one of the
            // saved commands, and it can never be the control that is counted away.
            newButton
        }
        .background(GeometryReader { geometry in
            Color.clear.preference(key: ShortcutRowWidthKey.self, value: geometry.size.width)
        })
        .onPreferenceChange(ShortcutRowWidthKey.self) { rowWidth = $0 }
    }

    // As many whole chips as the row has room for, and one count chip standing for the
    // rest. Anything the fit could not place overflows the leading edge, so that is the
    // edge the strip clips; the other three stay open so the hover lift still has its
    // room. Clipping nowhere at all is what used to paint chips across the sidebar.
    private var strip: some View {
        let fit = fit
        return HStack(spacing: ShortcutChipFit.gap) {
            ForEach(fit.visible) { placement in
                if let entry = checkout(with: placement.projectID) {
                    chip(placement.shortcut, in: entry)
                }
            }
            if !fit.hidden.isEmpty {
                countChip(fit.hidden)
            }
        }
        // The commands sit against the right of the strip, so the control that saves
        // another one is always beside the last one saved.
        .frame(maxWidth: .infinity, alignment: .trailing)
        .mask { Rectangle().padding(.trailing, -10).padding(.vertical, -10) }
    }

    private struct Fit {
        var visible: [ShortcutPlacement] = []
        var hidden: [ShortcutPlacement] = []
    }

    private var stripWidth: CGFloat? {
        guard rowWidth > 0 else { return nil }
        return max(0, rowWidth - ShortcutChipFit.newButtonWidth - ShortcutChipFit.gap)
    }

    private var fit: Fit {
        // Nothing is placed until the row has been measured, so a chip is never laid out
        // against a width the row turns out not to have.
        guard let stripWidth else { return Fit() }
        let entries = checkouts
        let ordered = ShortcutChipFit.ordered(placements) { state(of: $0, in: entries) }
        let widths = ordered.map { placement in
            ShortcutChipFit.chipWidth(name: placement.shortcut.name,
                                      glyph: placement.shortcut.glyph,
                                      state: state(of: placement, in: entries),
                                      tinted: entries.count > 1)
        }
        let shown = ShortcutChipFit.shown(
            widths: widths,
            countWidth: ShortcutChipFit.countWidth(total: ordered.count, badged: true),
            available: stripWidth)
        return Fit(visible: Array(ordered.prefix(shown)),
                   hidden: Array(ordered.dropFirst(shown)))
    }

    // MARK: - Chips

    private func chip(_ shortcut: Shortcut, in entry: Checkout) -> some View {
        let run = run(for: shortcut, in: entry)
        return ShortcutChip(
            shortcut: shortcut,
            state: shortcuts.state(run),
            tint: checkouts.count > 1 ? Theme.projectTint(for: entry.project?.name ?? "") : nil,
            open: shortcuts.output(for: scope) == run,
            toggle: { toggle(run) }
        )
        .appContextMenu {
            var entries: [MenuEntry] = [
                shortcuts.state(run).isActive
                    ? .item("Stop", action: { toggle(run) })
                    : .item("Run", action: { toggle(run) }),
                .item("Show output", action: { shortcuts.showOutput(run, for: scope) }),
                .item("Edit", action: {
                    edit(ShortcutEditorRequest(shortcut: shortcut,
                                               projectID: entry.checkout.projectID,
                                               projectName: entry.project?.name))
                })
            ]
            if !shortcut.availableInAllProjects {
                entries.append(.separator)
                entries.append(.item("Remove", kind: .destructive, action: {
                    shortcuts.remove(shortcut.id)
                }))
            }
            return entries
        }
    }

    // MARK: - What did not fit

    // One chip standing for the commands the row had no room for. It is the same shape
    // as a chip with secondary text, so it reads as a container rather than as another
    // command, and it carries the state of anything running or failed behind it so a run
    // is never silently out of sight.
    private func countChip(_ hidden: [ShortcutPlacement]) -> some View {
        let entries = checkouts
        let states = hidden.map { state(of: $0, in: entries) }
        return ShortcutCountChip(
            count: hidden.count,
            badge: states.contains(where: \.isActive) ? Theme.dotOn
                : states.contains(where: \.isFailure) ? Theme.deletion : nil,
            menu: { overflowMenu(hidden, in: entries) })
    }

    private func overflowMenu(_ hidden: [ShortcutPlacement],
                              in entries: [Checkout]) -> [MenuEntry] {
        let tinted = entries.count > 1
        var menu: [MenuEntry] = hidden.compactMap { placement in
            guard let entry = entries.first(where: {
                $0.checkout.projectID == placement.projectID
            }) else { return nil }
            let shortcut = placement.shortcut
            let run = run(for: shortcut, in: entry)
            let state = shortcuts.state(run)
            // Picking one runs it, which sorts it to the front and so brings it back
            // into the row it was just counted out of.
            return .item(shortcut.name,
                         projectTint: tinted
                            ? Theme.projectTint(for: entry.project?.name ?? "") : nil,
                         icon: shortcut.glyph,
                         subtitle: shortcut.text,
                         monospacedSubtitle: true,
                         detail: Self.detail(for: state),
                         detailColour: Self.detailColour(for: state),
                         action: { toggle(run) })
        }
        // Never a dead end: the place the commands went is also a place to save another.
        menu.append(.separator)
        menu.append(.item("New command…", icon: "plus", action: { edit(blankRequest) }))
        return menu
    }

    private static func detail(for state: ShortcutStore.State) -> String? {
        switch state {
        case .stopped: nil
        case .running: "running"
        case .finished: "exit 0"
        case .failed(_, let code, _): code.map { "exit \($0)" } ?? "failed"
        }
    }

    private static func detailColour(for state: ShortcutStore.State) -> Color? {
        switch state {
        case .running: Theme.dotOn
        case .failed: Theme.deletion
        case .finished, .stopped: nil
        }
    }

    // Dashed and wordless, so the one control that makes something new neither reads as
    // another saved command nor takes the room of one.
    private var newButton: some View {
        Image(systemName: "plus")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: ShortcutChipFit.newButtonWidth, height: 22)
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            .appMenu { newMenu }
            .appTooltip("Save a command or a prompt for this project")
            .accessibilityLabel("New shortcut")
    }

    private var newMenu: [MenuEntry] {
        var entries: [MenuEntry] = [
            .item("New command…", action: { edit(blankRequest) }),
            // Saved here beside the commands, but offered on the rail above the session,
            // since that is where a prompt is sent from.
            .item("New prompt…", action: {
                var request = blankRequest
                request.kind = .prompt
                edit(request)
            })
        ]
        // The command the agent just ran is the one most worth keeping, and it has
        // already been typed once.
        if let command = SessionShortcuts.lastAgentCommand(in: session) {
            entries.append(.item("Save last terminal command",
                                 subtitle: command,
                                 action: {
                                     var request = blankRequest
                                     request.text = command
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

    // Commands only. A prompt has no folder and no output, so it is offered on the icon
    // rail above the session instead, where the conversation it lands in is the one on
    // screen.
    private var placements: [ShortcutPlacement] {
        shortcuts.shortcuts(for: checkouts.map(\.checkout.projectID), kind: .command)
    }

    private func checkout(with projectID: UUID) -> Checkout? {
        checkouts.first { $0.checkout.projectID == projectID }
    }

    private func state(of placement: ShortcutPlacement,
                       in entries: [Checkout]) -> ShortcutStore.State {
        guard let entry = entries.first(where: {
            $0.checkout.projectID == placement.projectID
        }) else { return .stopped }
        return shortcuts.state(run(for: placement.shortcut, in: entry))
    }

    private func run(for shortcut: Shortcut, in entry: Checkout) -> ShortcutRun {
        ShortcutRun(shortcut.id,
                    in: shortcut.directory(projectPath: entry.project?.path,
                                           workspacePath: entry.checkout.worktreePath))
    }

    private func toggle(_ run: ShortcutRun) {
        if shortcuts.state(run).isActive {
            shortcuts.stop(run)
        } else {
            shortcuts.start(run)
            shortcuts.showOutput(run, for: scope)
        }
    }
}

// MARK: - One chip

// A saved command as one small control: click runs it, click again stops it. It carries
// the icon it was given, its name, and a single glyph for how the last run went - a dot,
// a tick, an exclamation - because a row of these shares a line with everything else the
// session has to say, and anything more makes that line unreadable. The timing and the
// output are in the drawer, which opens on its own the moment a run starts.
struct ShortcutChip: View {
    let shortcut: Shortcut
    let state: ShortcutStore.State
    // Set only for a session spanning several checkouts, where the checkout this command
    // runs in matters and the name alone does not say.
    let tint: Theme.ProjectTint?
    let open: Bool
    let toggle: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            ZStack {
                HStack(spacing: 6) {
                    if let tint { ProjectDot(tint: tint, size: 6) }
                    if let glyph = shortcut.glyph {
                        Image(systemName: glyph)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    Text(shortcut.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // The name takes exactly the width the fit measured it at, capped
                        // so that one long name cannot take the room of four commands. A
                        // name left free to give or take would let the row share its width
                        // out evenly and starve the widest chip into an ellipsis; this way
                        // a chip is the size it was counted as or it is not in the row at
                        // all. The whole name stays in the tooltip and in the menu.
                        .frame(width: ShortcutChipFit.nameWidth(shortcut.name),
                               alignment: .leading)
                    stateGlyph
                }
                .opacity(offeringStop ? 0 : 1)

                Text("Stop")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.deletion)
                    .lineLimit(1)
                    .opacity(offeringStop ? 1 : 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 22)
            .surface(backgroundColour, cornerRadius: 7, border: borderColour)
            .shadow(color: emphasisColour.opacity(hovering ? 0.32 : 0),
                    radius: hovering ? 6 : 0)
            .scaleEffect(hovering && !reduceMotion ? 1.04 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovering)
        .onHover { hovering = $0 }
        .accessibilityLabel(state.isActive ? "Stop \(shortcut.name)" : "Run \(shortcut.name)")
        .appTooltip {
            Tooltip(title: tooltip, subtitle: shortcut.text,
                    note: shortcut.availableInAllProjects ? "Available in all projects" : nil)
        }
    }

    @ViewBuilder private var stateGlyph: some View {
        switch state {
        case .stopped:
            EmptyView()
        case .running:
            Circle()
                .fill(Theme.dotOn)
                .frame(width: 6, height: 6)
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
        if hovering { return emphasisColour.opacity(0.75) }
        if state.isFailure { return emphasisColour.opacity(0.55) }
        if open || state.isActive { return Theme.accent.opacity(0.55) }
        return Theme.border
    }

    private var backgroundColour: Color {
        hovering ? emphasisColour.opacity(0.1) : Theme.card
    }

    private var emphasisColour: Color {
        if offeringStop { return Theme.deletion }
        return state.isFailure ? Theme.deletion : Theme.accent
    }

    private var offeringStop: Bool {
        hovering && state.isActive
    }
}

// MARK: - The count chip

// The commands the row had no room for, as one control. It is the chip shape again but
// in secondary type, so it reads as a container rather than as another command, and it
// opens on the list it stands for.
struct ShortcutCountChip: View {
    let count: Int
    // The state of whatever is hidden behind it, when that state is worth seeing from
    // the row: green while one of them runs, red when one of them failed.
    let badge: Color?
    let menu: () -> [MenuEntry]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        HStack(spacing: ShortcutChipFit.contentSpacing) {
            HStack(spacing: ShortcutChipFit.countSpacing) {
                Text("\(count)").font(.mono(11, .semibold))
                Text("more").font(.system(size: 12, weight: .semibold))
            }
            if let badge {
                Circle()
                    .fill(badge)
                    .frame(width: ShortcutChipFit.dotWidth, height: ShortcutChipFit.dotWidth)
            }
            // Upwards, because that is where the menu opens from a row this near the
            // bottom of the window.
            Image(systemName: "chevron.up")
                .font(.system(size: 8, weight: .semibold))
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, ShortcutChipFit.horizontalPadding)
        .frame(height: 22)
        .surface(hovering ? Theme.accent.opacity(0.1) : Theme.card,
                 cornerRadius: 7,
                 border: hovering ? Theme.accent.opacity(0.75) : Theme.border)
        .shadow(color: Theme.accent.opacity(hovering ? 0.32 : 0), radius: hovering ? 6 : 0)
        .scaleEffect(hovering && !reduceMotion ? 1.04 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .appMenu(edge: .top, menu)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovering)
        .onHover { hovering = $0 }
        .appTooltip(label)
        .accessibilityLabel(label)
        .accessibilityHint("Opens the commands that did not fit the row")
    }

    private var label: String {
        count == 1 ? "1 more shortcut" : "\(count) more shortcuts"
    }
}

private struct ShortcutRowWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Fitting the row

// How much of the row each command takes, and how many of them the row can hold. The
// chips share their line with everything else the next turn runs on, so they get what is
// left of it and no more: a chip is either wholly in the row or behind the count, never
// half drawn against the edge of the pane.
//
// Widths are read from the type rather than from the chips once they are on screen. A
// width that only settled after a chip had been drawn would feed back into the fit that
// decided to draw it, and the row would never come to rest.
@MainActor
enum ShortcutChipFit {
    static let gap: CGFloat = 7
    static let horizontalPadding: CGFloat = 9
    static let contentSpacing: CGFloat = 6
    // The count and the word it counts are one phrase, so they sit closer than the parts
    // of the chip around them.
    static let countSpacing: CGFloat = 3
    static let dotWidth: CGFloat = 6
    static let newButtonWidth: CGFloat = 22
    static let nameWidthCap: CGFloat = 104

    private static let nameFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let countFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)

    // Running first, then just failed, then the order they were saved in. A command that
    // is doing something has to keep its slot in the row; everything else falls back to
    // the list the reader already knows.
    static func ordered(_ placements: [ShortcutPlacement],
                        state: (ShortcutPlacement) -> ShortcutStore.State) -> [ShortcutPlacement] {
        placements.enumerated()
            .sorted { left, right in
                let first = rank(state(left.element))
                let second = rank(state(right.element))
                return first == second ? left.offset < right.offset : first < second
            }
            .map(\.element)
    }

    private static func rank(_ state: ShortcutStore.State) -> Int {
        if state.isActive { return 0 }
        if state.isFailure { return 1 }
        return 2
    }

    // How many chips off the front of the row fit. The count chip is set aside before
    // anything is fitted, so the row never promises a slot it has to take back once it
    // turns out something was left over.
    static func shown(widths: [CGFloat], countWidth: CGFloat, available: CGFloat) -> Int {
        guard !widths.isEmpty else { return 0 }
        let total = widths.reduce(0, +) + gap * CGFloat(widths.count - 1)
        if total <= available { return widths.count }

        let room = available - countWidth - gap
        var used: CGFloat = 0
        var shown = 0
        for width in widths {
            let next = used + (shown == 0 ? 0 : gap) + width
            guard next <= room else { break }
            used = next
            shown += 1
        }
        return shown
    }

    static func nameWidth(_ name: String) -> CGFloat {
        min(textWidth(name, font: nameFont), nameWidthCap)
    }

    static func chipWidth(name: String, glyph: String?, state: ShortcutStore.State,
                          tinted: Bool) -> CGFloat {
        var content: CGFloat = 0
        var parts = 0
        if tinted {
            content += dotWidth
            parts += 1
        }
        if let glyph {
            content += symbolWidth(glyph, size: 9.5, weight: .semibold)
            parts += 1
        }
        content += nameWidth(name)
        parts += 1
        if let width = stateGlyphWidth(state) {
            content += width
            parts += 1
        }
        content += contentSpacing * CGFloat(parts - 1)
        // Hovering a running command swaps its label for the word that stops it, and the
        // chip keeps its width while it does.
        return ceil(max(content, textWidth("Stop", font: nameFont))) + horizontalPadding * 2
    }

    // Measured for every command at once and with room for the state dot, so whatever
    // ends up behind the count chip, the width set aside for it was enough.
    static func countWidth(total: Int, badged: Bool) -> CGFloat {
        var content = textWidth("\(total)", font: countFont)
            + countSpacing
            + textWidth("more", font: nameFont)
            + contentSpacing
            + symbolWidth("chevron.up", size: 8, weight: .semibold)
        if badged { content += contentSpacing + dotWidth }
        return ceil(content) + horizontalPadding * 2
    }

    private static func stateGlyphWidth(_ state: ShortcutStore.State) -> CGFloat? {
        switch state {
        case .stopped: nil
        case .running: dotWidth
        case .finished: symbolWidth("checkmark", size: 8, weight: .bold)
        case .failed: symbolWidth("exclamationmark", size: 9, weight: .bold)
        }
    }

    private static var textWidths: [String: CGFloat] = [:]
    private static var symbolWidths: [String: CGFloat] = [:]

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        let key = "\(font.fontName)|\(font.pointSize)|\(text)"
        if let cached = textWidths[key] { return cached }
        let width = ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width)
        textWidths[key] = width
        return width
    }

    private static func symbolWidth(_ name: String, size: CGFloat,
                                    weight: NSFont.Weight) -> CGFloat {
        let key = "\(name)|\(size)|\(weight.rawValue)"
        if let cached = symbolWidths[key] { return cached }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
        let width = ceil(image?.size.width ?? size)
        symbolWidths[key] = width
        return width
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
                guard let command = ToolPresentation.shellCommand(in: tool.input)?.trimmed,
                      !command.isEmpty, !command.contains("\n") else { continue }
                return command
            }
        }
        return nil
    }
}
