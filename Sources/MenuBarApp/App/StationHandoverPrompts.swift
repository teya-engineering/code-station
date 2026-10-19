import SwiftUI
import CodeStationCore

// What the app shows while the station is handed over (ADR-0003): turns still running
// after a short wait are named in a Dialog, with the choice to wait for them or stop
// them. The handover itself is the core's (`StationHandover`); this only asks.
extension Dialog {
    // `waiting` is the Dialog after the person chose to wait: it says so and keeps only
    // the way to stop.
    static func runningTurns(_ turns: [RemoteRunningTurn], message: String, waiting: Bool,
                             wait: @escaping () -> Void, stop: @escaping () -> Void) -> Dialog {
        let one = turns.count == 1
        let title = waiting
            ? (one ? "Waiting for a turn to end" : "Waiting for \(turns.count) turns to end")
            : (one ? "A turn is still running" : "\(turns.count) turns are still running")
        let stopLabel = one ? "Stop it" : "Stop them"
        var dialog = Dialog(
            title: title,
            message: message.isEmpty ? nil : message,
            content: AnyView(RunningTurnList(turns: turns)),
            actions: waiting
                ? [Action(label: stopLabel, kind: .destructive, handler: stop)]
                : [Action(label: one ? "Wait for it" : "Wait for them", kind: .primary, handler: wait),
                   Action(label: stopLabel, kind: .destructive, handler: stop)],
            onCancel: waiting ? {} : wait)
        dialog.width = 400
        dialog.isModal = true
        return dialog
    }
}

private struct RunningTurnList: View {
    let turns: [RemoteRunningTurn]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                if index > 0 {
                    Rectangle().fill(Theme.border).frame(height: 1)
                }
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(turn.title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        if !turn.project.isEmpty {
                            Text(turn.project)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 12)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }
}

// The handover the app is running, if any, and what its Dialog says about it. The app
// delegate fills it; the window it shows in reads it from the environment.
@MainActor
@Observable
final class StationHandoverSlot {
    var current: StationHandover?
    var message = ""
    // Taking the station without a handover, such as from a service of another version
    // that was told to stop: there is no turn to ask about, only the wait.
    var waitingWithoutHandover = false
}

// Shows the running-turns Dialog for a handover in progress, in whichever window it is
// placed: the main window as the app quits, or the window the app opens over a daemon.
// It is drawn again as the turns end, and goes once none is left.
struct StationHandoverPrompts: View {
    @Environment(StationHandoverSlot.self) private var slot
    @Environment(DialogPresenter.self) private var dialogs
    @State private var shown: Dialog.ID?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: state, initial: true) { _, _ in present() }
    }

    private struct State: Equatable {
        var phase: StationHandover.Phase?
        var running: [RemoteRunningTurn] = []
    }

    private var state: State {
        State(phase: slot.current?.phase, running: slot.current?.running ?? [])
    }

    private func present() {
        guard let handover = slot.current else { return }
        let asking = handover.phase == .asking || handover.phase == .waitingForTurns
        guard asking, !handover.running.isEmpty else {
            if let shown, dialogs.current?.id == shown { dialogs.dismiss() }
            shown = nil
            return
        }
        // Another question already open is left to finish first.
        if let current = dialogs.current, current.id != shown { return }
        let dialog = Dialog.runningTurns(handover.running, message: slot.message,
                                         waiting: handover.phase == .waitingForTurns,
                                         wait: { handover.keepWaiting() },
                                         stop: { handover.stopTurns() })
        shown = dialog.id
        dialogs.show(dialog)
    }
}
