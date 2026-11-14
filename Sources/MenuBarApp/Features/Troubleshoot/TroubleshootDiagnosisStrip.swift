import SwiftUI

// The line over a diagnosis's conversation, from the moment the brief is sent: what state
// the agent is in and for how long, where it is looking, the window it was given, who is
// running it, and how much it has found. Everything here is read off the session and its
// transcript, so nothing on the strip can disagree with the conversation under it, and
// the counts say whether Evidence is worth opening before it is.
struct TroubleshootDiagnosisStrip: View {
    let session: ChatSession
    let state: SessionStateReading
    // "Claude Code · claude-opus-5-5", worked out by the pane that knows the defaults.
    let agentLine: String
    let openEvidence: () -> Void

    var body: some View {
        let tally = TroubleshootEvidenceTally(messages: session.messages)
        let environment = environment
        ViewThatFits(in: .horizontal) {
            readings(tally: tally, environment: environment, showsAgent: true, showsWindow: true)
            readings(tally: tally, environment: environment, showsAgent: false, showsWindow: true)
            readings(tally: tally, environment: environment, showsAgent: false, showsWindow: false)
        }
        .statusBand(padding: 20)
    }

    private func readings(tally: TroubleshootEvidenceTally,
                          environment: TroubleshootEnvironment?,
                          showsAgent: Bool, showsWindow: Bool) -> some View {
        HStack(spacing: Space.md) {
            stateReading
            if let environment {
                StatusRule()
                HStack(spacing: Space.sm) {
                    if environment.isDangerous {
                        Circle().fill(Theme.attention).frame(width: 6, height: 6)
                    }
                    StatusValue(text: environment.isDangerous
                                ? "\(environment.title) · read-only"
                                : environment.title)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(environment.isDangerous
                                    ? "\(environment.title), live, the agent only reads"
                                    : environment.title)
            }
            if showsWindow, let window = session.troubleshootTimeWindow {
                StatusRule()
                HStack(spacing: Space.xs) {
                    Image(systemName: "clock")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    StatusValue(text: window)
                }
            }
            if showsAgent {
                StatusRule()
                StatusValue(text: agentLine)
            }

            Spacer(minLength: 12)

            evidence(tally)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // The state word and its count, the same reading the header pill carries, so the two
    // never say different things about one session.
    private var stateReading: some View {
        HStack(spacing: Space.sm) {
            Breathing(active: state.tone == .running) {
                Circle().fill(state.tone.colour).frame(width: 6, height: 6)
            }
            StatusCaps(text: state.word, tint: state.tone.wordColour)
            if state.ticks {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    elapsed
                }
            } else {
                elapsed
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([state.spokenWord, state.shortElapsed.map { "for \($0)" }]
            .compactMap { $0 }.joined(separator: " "))
    }

    @ViewBuilder private var elapsed: some View {
        if let elapsed = state.shortElapsed {
            StatusValue(text: elapsed).monospacedDigit()
        }
    }

    private func evidence(_ tally: TroubleshootEvidenceTally) -> some View {
        HStack(spacing: Space.sm) {
            if tally.isEmpty {
                StatusValue(text: "No evidence yet")
            } else {
                ForEach(tally.readings, id: \.self) { reading in
                    Text(reading)
                        .font(Typography.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Space.sm)
                        .frame(height: 20)
                        .fieldSurface(cornerRadius: Radius.inset)
                        .fixedSize()
                }
            }
            InlineAskButton(title: "Open Evidence", action: openEvidence)
                .padding(.leading, Space.xs)
                .accessibilityLabel("Open Evidence")
        }
        .layoutPriority(1)
    }

    // The deployment the brief named, looked up again so a renamed title in the site file
    // shows as it is now. A session from before the name was kept shows no environment.
    private var environment: TroubleshootEnvironment? {
        guard let name = session.troubleshootEnvironment else { return nil }
        return TroubleshootEnvironment.all().first { $0.name == name }
            ?? TroubleshootEnvironment(name: name, title: name)
    }
}
