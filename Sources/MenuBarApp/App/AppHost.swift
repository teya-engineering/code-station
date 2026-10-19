import AppKit
import CodeStationCore

// The GUI's answer to the core's host services: system notifications through
// `AppNotifier`, the chosen NSSound, the general pasteboard, Launch Services for "Open in"
// and the open panel for a folder. Handed to the session runner at launch.
@MainActor
final class AppHost: HostServices {
    private let notifier: AppNotifier

    init(notifier: AppNotifier = .shared) {
        self.notifier = notifier
    }

    func turnEnded(sessionID: UUID, sessionTitle: String, failure: String?) {
        notifier.turnEnded(sessionID: sessionID, sessionTitle: sessionTitle, failure: failure)
    }

    func needsInput(sessionID: UUID, sessionTitle: String, request: PermissionRequest) {
        notifier.needsInput(sessionID: sessionID, sessionTitle: sessionTitle, request: request)
    }

    func waitWentStale(sessionID: UUID, sessionTitle: String, tasks: [AgentBackgroundTask]) {
        notifier.waitWentStale(sessionID: sessionID, sessionTitle: sessionTitle, tasks: tasks)
    }

    func clear(sessionID: UUID) {
        notifier.clear(sessionID: sessionID)
    }

    // Heard while the window is open on another session too. It waits for the beat the
    // sidebar's tick starts drawing on, so sound and sight land together. A test runner
    // or a bare `swift run` binary stays quiet.
    func playSessionSound() {
        guard AppNotifier.isBundled else { return }
        let sound = Preferences.sessionFinishedSound()
        Task {
            try? await Task.sleep(for: TurnMotion.soundBeat)
            sound.play()
        }
    }

    func copy(_ content: ClipboardContent) {
        Pasteboard.copy(content)
    }

    func openInApps() -> [OpenInApp] {
        WorktreeOpener.apps
    }

    func open(_ path: URL, in app: OpenInApp) {
        WorktreeOpener.open(path, in: app)
    }

    func openLink(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func chooseDirectory(prompt: String, message: String,
                         startingAt directory: URL?) async throws -> URL? {
        FilePicker.chooseFolder(prompt: prompt, message: message, directory: directory)
    }
}
