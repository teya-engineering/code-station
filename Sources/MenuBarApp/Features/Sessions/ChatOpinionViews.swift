import SwiftUI
import CodeStationCore

// What a reviewer of a plan or an answer looks for and reads. The subject itself and the
// request always go; the files and the whole conversation are the person's to choose.
struct ChatOpinionChoices: View {
    let authorTitle: String
    @Binding var focus: Set<ChatSecondOpinion.Focus>
    @Binding var reading: ChatSecondOpinion.Reading
    let noun: String

    var body: some View {
        SecondOpinionSection(title: "What to look for") {
            FlowRow(spacing: 6) {
                ForEach(ChatSecondOpinion.Focus.allCases, id: \.self) { item in
                    ChoicePill(title: item.title, selected: focus.contains(item)) {
                        if !focus.insert(item).inserted { focus.remove(item) }
                    }
                    .accessibilityAddTraits(focus.contains(item) ? .isSelected : [])
                }
            }
        }
        SecondOpinionSection(title: "What they read") {
            VStack(alignment: .leading, spacing: 6) {
                row(title: "This \(noun) and your request", note: "Always", on: .constant(true))
                    .disabled(true)
                row(title: "The project's files", note: "Read-only", on: $reading.files)
                row(title: "The whole conversation", note: "Makes them think like \(authorTitle)",
                    warns: true, on: $reading.conversation)
            }
        }
    }

    private func row(title: String, note: String, warns: Bool = false, on: Binding<Bool>) -> some View {
        Toggle(isOn: on) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                Text(note).font(.system(size: 11))
                    .foregroundStyle(warns ? Theme.attentionText : Color.secondary)
            }
        }
        .toggleStyle(.appCheckbox)
    }
}

// The ask dialog as it opens from Chat. It keeps its own choices while it is open and
// hands them over when the person asks.
struct ChatOpinionAsk: View {
    let subject: ChatSecondOpinion.Subject
    let author: SecondOpinion.Reviewer
    let installed: [AgentKind]
    let ask: ([SecondOpinion.Reviewer], [ChatSecondOpinion.Focus], ChatSecondOpinion.Reading) -> Void

    @State private var lineup: [SecondOpinion.Reviewer]
    @State private var focus = Set(ChatSecondOpinion.Focus.standard)
    @State private var reading = ChatSecondOpinion.Reading()

    init(subject: ChatSecondOpinion.Subject, author: SecondOpinion.Reviewer, installed: [AgentKind],
         ask: @escaping ([SecondOpinion.Reviewer], [ChatSecondOpinion.Focus], ChatSecondOpinion.Reading) -> Void) {
        self.subject = subject
        self.author = author
        self.installed = installed
        self.ask = ask
        _lineup = State(initialValue: Preferences.secondOpinionLineup().filter { installed.contains($0.agent) })
    }

    var body: some View {
        SecondOpinionAskView(
            message: subject.kind == .plan
                ? "Agents that did not write this plan check it before anything changes. You pick which points reach \(author.agent.title)."
                : "Agents that did not write this answer check it on their own. You pick which points reach \(author.agent.title).",
            safety: "Read-only, and without your MCP servers. \(author.agent.title) sees nothing they say until you send it.",
            author: author, installed: installed, lineup: $lineup,
            choices: {
                ChatOpinionChoices(authorTitle: author.agent.title, focus: $focus, reading: $reading,
                                   noun: subject.noun)
            },
            ask: { ask(lineup, ChatSecondOpinion.Focus.allCases.filter(focus.contains), reading) })
    }
}

// A second opinion joined to the plan or answer it judged. While the seats read it shows
// their lanes; once they are in, one verdict per seat and the points they raised, each
// with a tick. Only ticked points are sent, and only when the person sends them.
struct ChatOpinionCard: View {
    let opinion: ChatOpinion
    let authorTitle: String
    // Whether the plan is still waiting on an answer, which is what makes approving it
    // from here possible.
    var planPending = false
    let toggle: (UUID) -> Void
    let send: () -> Void
    let approve: () -> Void
    let askAgain: () -> Void
    let retry: (SecondOpinion.Reviewer) -> Void
    let stop: (SecondOpinion.Reviewer) -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if opinion.sent == nil {
                if opinion.isRunning || opinion.lanes.contains(where: isFailed) {
                    FlowRow(spacing: 6) {
                        ForEach(opinion.lanes.filter { !isFinished($0) }) { lane in
                            ReviewLane(reviewer: lane.reviewer, started: lane.started, ended: lane.ended,
                                       activity: lane.activity, state: laneState(lane),
                                       stop: { stop(lane.reviewer) }, retry: { retry(lane.reviewer) },
                                       dismiss: isFailed(lane) ? { stop(lane.reviewer) } : nil)
                        }
                    }
                }
                if opinion.isRunning {
                    Label(planPending ? "You can keep chatting. Approving now does not wait for them."
                          : "You can keep chatting while they read.", systemImage: "clock")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                verdicts
                if !opinion.points.isEmpty { points }
                if opinion.finishedCount > 0 && !opinion.isRunning { footer }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(Theme.card, cornerRadius: 12, border: Theme.border)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Second opinion on this \(opinion.subject.noun)")
        .accessibilityAddTraits(opinion.isRunning ? .updatesFrequently : [])
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: -6) {
                ForEach(Array(opinion.lanes.enumerated()), id: \.offset) { ReviewAvatar(agent: $0.element.reviewer.agent, size: 22) }
            }
            Text("Second opinion on this \(opinion.subject.noun)").font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            if let sent = opinion.sent {
                Label("Sent \(counted(sent, "point")) to \(authorTitle)", systemImage: "checkmark")
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.dotOnText)
            } else if opinion.isRunning {
                Text("Reading on their own").font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else {
                Text("\(opinion.finishedCount) of \(opinion.lanes.count) finished")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                GlyphButton(icon: "arrow.clockwise", side: 22, action: askAgain)
                    .appTooltip("Ask again")
                    .accessibilityLabel("Ask again")
            }
            GlyphButton(icon: "xmark", side: 22, action: dismiss)
                .appTooltip(opinion.isRunning ? "Stop and put away" : "Put away")
                .accessibilityLabel(opinion.isRunning ? "Stop the second opinion" : "Put the second opinion away")
        }
    }

    @ViewBuilder private var verdicts: some View {
        let done = opinion.lanes.filter(isFinished)
        if !done.isEmpty {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top),
                                     count: min(done.count, 2)), alignment: .leading, spacing: 8) {
                ForEach(done) { lane in
                    if case .finished(let verdict, let summary) = lane.state {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                ReviewAvatar(agent: lane.reviewer.agent, size: 18)
                                Text(lane.reviewer.agent.title).font(.system(size: 12, weight: .semibold))
                                if let seat = lane.reviewer.seatLabel {
                                    Text(seat).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            VerdictChip(verdict: verdict)
                            if !summary.isEmpty {
                                Text(summary).font(.system(size: 12)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private var points: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("What they raised").font(.system(size: 12, weight: .semibold))
                Text("Ticked points go to \(authorTitle). The rest stay here.")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
            ForEach(opinion.points) { point in
                Toggle(isOn: Binding(get: { point.ticked }, set: { _ in toggle(point.id) })) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            HStack(spacing: -5) {
                                ForEach(Array(point.voices.enumerated()), id: \.offset) {
                                    ReviewAvatar(agent: $0.element.reviewer.agent, size: 16)
                                }
                            }
                            if let step = point.step {
                                Text("Step \(step)").font(.system(size: 11.5, weight: .semibold))
                            }
                            SeverityChip(severity: point.severity)
                            if point.raisedByMoreThanOne {
                                Label(point.voices.count == 2 ? "Both raised this" : "\(point.voices.count) raised this",
                                      systemImage: "checkmark")
                                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.dotOnText)
                            }
                        }
                        ReviewText(text: point.text, size: 12)
                        ForEach(Array(point.voices.dropFirst().enumerated()), id: \.offset) { _, voice in
                            Text("\(voice.reviewer.label()): \(voice.text)")
                                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, -2)
                }
                .toggleStyle(.appCheckbox)
                .accessibilityLabel((point.step.map { "Step \($0). " } ?? "") + point.severity.label + ". " + point.text)
            }
        }
    }

    private var footer: some View {
        let count = opinion.ticked.count
        return HStack(spacing: 10) {
            ActionButton(title: count > 0 ? "Send \(counted(count, "point")) to \(authorTitle)" : "Tick a point to send",
                         tone: .green, height: 28, size: 12, action: send)
                .disabled(count == 0)
            if planPending {
                ActionButton(title: "Approve plan as is", tone: .outlined, height: 28, size: 12, action: approve)
            }
            Spacer(minLength: 0)
            if planPending {
                Text("\(authorTitle) revises the plan. Nothing changes until you approve.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func isFailed(_ lane: ChatOpinion.Lane) -> Bool {
        if case .failed = lane.state { return true }
        return false
    }

    private func isFinished(_ lane: ChatOpinion.Lane) -> Bool {
        if case .finished = lane.state { return true }
        return false
    }

    private func laneState(_ lane: ChatOpinion.Lane) -> ReviewLane.State {
        switch lane.state {
        case .running: .running
        case .finished(let verdict, _): .finished(verdict.label)
        case .failed(let message): .failed(message)
        }
    }
}

// A reviewer's verdict, said in an icon and words so it never rests on colour.
struct VerdictChip: View {
    let verdict: ChatSecondOpinion.Verdict

    var body: some View {
        Label(verdict.label, systemImage: verdict.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(ink)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(fill))
            .fixedSize()
    }

    private var ink: Color {
        switch verdict {
        case .agrees: Theme.dotOnText
        case .agreesWithChanges: Theme.attentionText
        case .disagrees: Theme.warningText
        }
    }

    private var fill: Color {
        switch verdict {
        case .agrees: Theme.dotOn.opacity(0.12)
        case .agreesWithChanges: Theme.attention.opacity(0.14)
        case .disagrees: Theme.deletion.opacity(0.12)
        }
    }
}
