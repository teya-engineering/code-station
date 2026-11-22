import SwiftUI

// Signing in belongs to the CLI, so the sheet does not imitate its login flow: it hosts
// a real shell, starts the CLI's own login command in it, and lets the CLI take it from
// there. The shell dies with the sheet, and whoever opened it re-reads the account
// afterwards.
struct AgentCommandSheet: View {
    let title: String
    let note: String
    let command: String
    @Environment(\.dismiss) private var dismiss
    @State private var terminal: TerminalSession?
    @State private var focused = true

    var body: some View {
        VStack(spacing: 0) {
            SheetTitle(title, icon: "terminal")
                .padding(.horizontal, Space.pane)
                .headerBand()
            HStack(spacing: Space.md) {
                StatusCaps(text: "RUNS")
                StatusValue(text: command, truncation: .middle)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .statusBand(padding: Space.pane)
            if let terminal {
                TerminalScreen(terminal: terminal, isFocused: $focused)
                    .frame(height: 420)
                    .transition(.fadeIn)
            }
            // The note is what to do in the terminal, so it stays in view rather than
            // behind a question mark.
            SheetFooter(title: note, dismiss: { dismiss() })
        }
        .smoothlyResizes(when: terminal != nil)
        .frame(width: 680)
        .background(Theme.background)
        .onAppear(perform: start)
        .onDisappear { terminal?.stop() }
    }

    private func start() {
        guard terminal == nil else { return }
        let session = TerminalSession(
            directory: FileManager.default.homeDirectoryForCurrentUser.path,
            name: command)
        session.start()
        // Queued into the pty now, run by the shell once it has read its rc files.
        session.send(command + "\n")
        terminal = session
    }
}

struct AgentLoginSheet: View {
    let agent: AgentKind

    var body: some View {
        AgentCommandSheet(
            title: "Sign in to \(agent.title)",
            note: "Follow the CLI's login below, then close this when it is done.",
            command: agent.loginCommand)
    }
}
