import SwiftUI

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
                        .font(Typography.data)
                        .foregroundStyle(log.isEmpty ? AnyShapeStyle(.secondary)
                                                     : AnyShapeStyle(.primary))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.lg)
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .onChange(of: log) { _, _ in
                    scroller.scrollTo(Self.bottom, anchor: .bottom)
                }
            }
            .frame(height: 240)
        }
        .background(Theme.card)
        .interruptOnStopKey(isEnabled: shortcuts.state(run).isActive) {
            shortcuts.stop(run)
        }
    }

    private var strip: some View {
        HStack(spacing: Space.md) {
            Text("OUTPUT")
                .font(Typography.data.weight(.semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)
            if let name = shortcuts.shortcut(run.shortcutID)?.name {
                Text(name)
                    .font(Typography.label)
                    .lineLimit(1)
            }
            Text(status)
                .font(Typography.data)
                .foregroundStyle(statusColour)
                .lineLimit(1)

            Spacer(minLength: 12)

            // Kept in the row whether or not anything is running, so the way to stop a
            // command is always in the same place. The chip that opens this panel no
            // longer stops anything, and a control that comes and goes is one the reader
            // has to find again every time they need it.
            let running = shortcuts.state(run).isActive
            stripButton("Stop", tint: Theme.deletion, enabled: running) {
                shortcuts.stop(run)
            }
            .appTooltip(running ? "Stop this command (^C)" : "Nothing is running")

            if !log.isEmpty {
                stripButton("Clear", tint: Theme.accent) { shortcuts.clearLog(run) }
            }

            // Named for what it does, since the row beside it stops the command and the
            // two must not read as the same thing: this only puts the panel away, and
            // whatever is running carries on.
            stripButton("Close output", tint: Theme.deletion, action: onClose)
                .appTooltip("Hide this panel. Anything running keeps running.")
                .accessibilityLabel("Hide the output")
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .background(Theme.card)
    }

    private func stripButton(_ title: String, tint: Color, enabled: Bool = true,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typography.caption.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.xs)
                .background(RoundedRectangle(cornerRadius: Radius.control).fill(Theme.field))
                .contentShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .hoverLift()
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
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

// The stroke that ends a running command, wherever the reader's hands happen to be.
// The pane prints a command the way a shell does, so ^C is what anyone watching it
// reaches for, and there is no text field in it to type that into. A monitor is what
// catches it: the drawer never holds the keyboard, since the composer beside it does.
private struct InterruptCatcher: ViewModifier {
    let isEnabled: Bool
    let interrupt: () -> Void

    @State private var monitor = WindowKeyMonitor(AppCommand.stopCommand.info.keys)

    func body(content: Content) -> some View {
        content
            .background(WindowAnchor(monitor: monitor).keyMonitor(monitor, follows: .stopCommand))
            .onChange(of: isEnabled, initial: true) { _, enabled in
                guard enabled else { return monitor.stop() }
                monitor.start {
                    interrupt()
                    return true
                }
            }
            .onDisappear { monitor.stop() }
    }
}

extension View {
    func interruptOnStopKey(isEnabled: Bool,
                             interrupt: @escaping () -> Void) -> some View {
        modifier(InterruptCatcher(isEnabled: isEnabled, interrupt: interrupt))
    }
}
