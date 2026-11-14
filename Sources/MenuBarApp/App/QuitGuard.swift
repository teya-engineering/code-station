import AppKit
import SwiftUI

// Quitting stops every session that is still running, so the app asks first. AppKit
// decides to quit outside of SwiftUI, and only a view inside the window can draw the
// app's own dialog, so this carries the question from one to the other.
@MainActor
@Observable
final class QuitGuard {
    // Counts up each time a quit waits on an answer, so asking again while the
    // dialog is up still reaches the window.
    private(set) var requests = 0
    private var allowed = false

    func shouldAsk(running: Int) -> Bool {
        !allowed && running > 0
    }

    func ask() {
        requests += 1
    }

    // For a quit the person has already agreed to, here or somewhere else, and for the
    // system logging out, which a dialog nobody is there to answer would hold up.
    func allow() {
        allowed = true
    }

    func quit() {
        allowed = true
        NSApp.terminate(nil)
    }
}

// Shows the question in whichever layer is in front. A sheet is a window of its own over
// the main one, so while a sheet is up the main window's dialog would sit behind it.
struct QuitConfirmation: View {
    var isFront = true

    @Environment(QuitGuard.self) private var quitGuard
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: quitGuard.requests) {
                if isFront { confirm() }
            }
    }

    private func confirm() {
        // A Design companion's work already counts toward the session it belongs to.
        let running = store.sessions.filter {
            $0.designSourceSessionID == nil && runner.isBusy($0.id, store: store)
        }
        // A session can finish between the quit and the dialog, which leaves nothing to ask.
        guard !running.isEmpty else { return quitGuard.quit() }
        var dialog = Dialog.confirm(
            running.count == 1 ? "Quit while a session is running?"
                : "Quit while \(running.count) sessions are running?",
            message: "Quitting stops \(running.count == 1 ? "it" : "them") in the middle of the turn. "
                + "What has been written so far is kept.",
            action: "Quit",
            cancel: "Keep running",
            handler: quitGuard.quit)
        dialog.content = AnyView(SessionTitleList(titles: running.map(\.title)))
        dialog.isModal = true
        dialogs.show(dialog)
    }
}

// The sessions a dialog is about, listed by title.
struct SessionTitleList: View {
    let titles: [String]

    private let shown = 4

    private func rowStart(_ index: Int) -> Double {
        0.16 + Double(index) * 0.06
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            // The rows follow the list in one by one, the way the rows of a deletion do.
            ForEach(Array(titles.prefix(shown).enumerated()), id: \.offset) { index, title in
                HStack(spacing: Space.md) {
                    Circle().fill(Theme.dotOn).frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                        .arrives(after: rowStart(index) + 0.04, growing: 0.5, animation: Motion.pop)
                    Text(title).font(Typography.detail).lineLimit(1).truncationMode(.tail)
                        .arrives(after: rowStart(index) + 0.06, sliding: 6, animation: Motion.reveal)
                }
            }
            if titles.count > shown {
                Text("and \(titles.count - shown) more")
                    .font(Typography.detail).foregroundStyle(.secondary)
                    .padding(.leading, Space.lg)
                    .arrives(after: rowStart(shown) + 0.06, animation: Motion.reveal)
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(Theme.border))
        .padding(.top, Space.xs)
    }
}
