import AppKit
import SwiftUI
import CodeStationCore

// What a turn that did not end on its own leaves at the foot of the transcript. A failed
// run belongs in the flow of the conversation, not in a dialog, so it is a card with the
// ways out of it. A stop went wrong with nothing, so it gets a button under its
// transcript note rather than a card of its own.

struct TurnEndActions: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner

    let sessionID: UUID
    let agent: AgentKind
    let state: SessionState

    // Read again after every failed turn, because a CLI does not always say in words that
    // its login has lapsed, and once more when the sign-in sheet closes.
    @State private var account: AgentAccount?
    @State private var signingIn = false
    @State private var checkedAfterSignIn = false

    var body: some View {
        if case .failed(let message) = state {
            Group {
                if checkedAfterSignIn, account?.signedIn == true {
                    signedInCard
                } else {
                    failedCard(message,
                               offersSignIn: SessionRunner.signedOut(agent, message: message)
                                   || account?.signedIn == false)
                }
            }
            .task(id: message) {
                checkedAfterSignIn = false
                account = AgentAccount(agent)
            }
            .sheet(isPresented: $signingIn, onDismiss: {
                account?.refresh()
                checkedAfterSignIn = true
            }) {
                AgentLoginSheet(agent: agent).appOverlays()
            }
        }

        if runner.canContinueAfterStop(sessionID, store: store) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ActionButton(title: "Continue", tone: .outlined, height: 28, size: 11.5) {
                    runner.continueAfterStop(sessionID, store: store)
                }
            }
            .transition(.fadeIn)
        }
    }
}

extension TurnEndActions {
    private func failedCard(_ message: String, offersSignIn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(message)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if offersSignIn {
                Text("\(agent.title) has signed you out. Sign in runs \(Text(verbatim: agent.loginCommand).font(.mono(11.5))) in a window here, the same as in Settings, and the turn can then carry on where it stopped.")
                    .font(.system(size: 12))
                    .opacity(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 21)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                // Sign in is the only thing that fixes the cause, so it takes the lead and
                // Continue steps back; Continue stays because a token refresh can still
                // succeed on a retry.
                if offersSignIn {
                    dismissButton
                    continueButton(tone: .outlined)
                    ActionButton(title: "Sign in", height: 28, size: 11.5, icon: "terminal") {
                        signingIn = true
                    }
                } else {
                    continueButton(tone: .dark)
                    dismissButton
                }
            }
        }
        .warningCard()
    }

    private var signedInCard: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Theme.dotOn)
                .frame(width: 7, height: 7)
            Text("\(Text("Signed in to \(agent.title)").fontWeight(.semibold)) \(Text(account?.summary.map { "· \($0)" } ?? "").foregroundStyle(.secondary))")
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            dismissButton
            continueButton(tone: .dark)
        }
        .padding(.vertical, 12)
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .surface(Theme.card, cornerRadius: 10)
        .transition(.fadeIn)
    }

    @ViewBuilder
    private func continueButton(tone: ButtonTone) -> some View {
        if runner.canContinueAfterFailure(sessionID, store: store) {
            ActionButton(title: "Continue", tone: tone, height: 28, size: 11.5) {
                runner.continueAfterFailure(sessionID, store: store)
            }
        }
    }

    private var dismissButton: some View {
        ActionButton(title: "Dismiss", tone: .outlined, height: 28, size: 11.5) {
            runner.dismissFailure(sessionID)
        }
    }
}
