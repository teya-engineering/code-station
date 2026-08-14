import AppKit
import UserNotifications

// System notifications for sessions that finish a turn or stop to ask something while
// the app is in the background. The window already shows both, so nothing is posted
// while the app is active - this is for the person who went to another app while their
// agents worked, and would otherwise never hear that one of them is waiting.
@MainActor
final class AppNotifier: NSObject {
    static let shared = AppNotifier()

    // How a clicked notification opens its session, handed in by the app delegate.
    var openSession: ((UUID) -> Void)?

    // The notification centre only exists for a real app bundle. A bare `swift run`
    // binary or a test runner has none worth posting to, and asking for the centre
    // there can bring the process down.
    private let center: UNUserNotificationCenter? =
        Bundle.main.bundlePath.hasSuffix(".app") ? .current() : nil

    private enum Authorization { case unasked, asking, granted, denied }
    private var authorization: Authorization = .unasked
    // What arrived while permission was still being asked for; posted with the answer.
    private var pending: [UNNotificationRequest] = []

    // Called at launch so a click on a notification is routed even when that click is
    // what started the app.
    func activate() {
        center?.delegate = self
    }

    func turnEnded(sessionID: UUID, sessionTitle: String, failure: String?) {
        post(identifier: "finished-\(sessionID.uuidString)",
             sessionID: sessionID,
             title: sessionTitle,
             body: failure.map { "The turn failed: \(Self.firstLine($0))" }
                ?? "Finished and waiting for you.")
    }

    func needsInput(sessionID: UUID, sessionTitle: String, request: PermissionRequest) {
        let body = request.isQuestion
            ? (request.questions.first?.text ?? "The agent has a question for you.")
            : "Waiting for permission: \(request.subject.isEmpty ? request.toolName : request.subject)"
        post(identifier: "input-\(sessionID.uuidString)",
             sessionID: sessionID,
             title: sessionTitle,
             body: Self.firstLine(body))
    }

    // Opening a session, or answering what it asked, deals with its notifications, so
    // they leave Notification Centre together with the reason for them.
    func clear(sessionID: UUID) {
        guard let center else { return }
        let identifiers = ["finished-\(sessionID.uuidString)", "input-\(sessionID.uuidString)"]
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        pending.removeAll { identifiers.contains($0.identifier) }
    }

    private func post(identifier: String, sessionID: UUID, title: String, body: String) {
        // The window says all of this better while it is being looked at.
        guard let center, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["sessionID": sessionID.uuidString]
        let request = UNNotificationRequest(identifier: identifier, content: content,
                                            trigger: nil)
        switch authorization {
        case .granted:
            center.add(request)
        case .denied:
            break
        case .asking:
            pending.append(request)
        case .unasked:
            // Asked the first time there is something to say rather than at launch, so
            // the permission prompt arrives with its reason next to it.
            authorization = .asking
            pending.append(request)
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                Task { @MainActor in
                    self.authorization = granted ? .granted : .denied
                    let queued = self.pending
                    self.pending = []
                    guard granted, let center = self.center else { return }
                    for request in queued { try? await center.add(request) }
                }
            }
        }
    }

    // A failure can be a whole stderr dump; the notification takes its first line.
    private nonisolated static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return line.count > 160 ? String(line.prefix(160)) + "…" : line
    }
}

extension AppNotifier: UNUserNotificationCenterDelegate {
    // A banner landing on top of the app would say nothing the window is not already
    // saying, so notifications delivered while the app is frontmost stay silent.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo["sessionID"] as? String,
              let sessionID = UUID(uuidString: raw) else { return }
        await MainActor.run { self.openSession?(sessionID) }
    }
}
