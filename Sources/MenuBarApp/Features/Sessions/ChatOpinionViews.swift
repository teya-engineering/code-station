import SwiftUI

// What a reviewer of a plan or an answer looks for and reads. The plan or answer and the
// request it answers always go; the files and the whole conversation are the person's
// to choose.
struct ChatOpinionChoices: View {
    let authorTitle: String
    @Binding var focus: Set<ChatSecondOpinion.Focus>
    @Binding var reading: ChatSecondOpinion.Reading

    var body: some View {
        SecondOpinionSection(title: "What to look for") {
            FlowRow(spacing: Space.sm) {
                ForEach(ChatSecondOpinion.Focus.allCases, id: \.self) { item in
                    ChoicePill(title: item.title, selected: focus.contains(item)) {
                        if !focus.insert(item).inserted { focus.remove(item) }
                    }
                    .accessibilityAddTraits(focus.contains(item) ? .isSelected : [])
                }
            }
        }
        SecondOpinionSection(title: "What they read") {
            VStack(alignment: .leading, spacing: Space.sm) {
                row(title: "The project's files", note: "Read-only", on: $reading.files)
                row(title: "The whole conversation", note: "Makes them think like \(authorTitle)",
                    warns: true, on: $reading.conversation)
            }
        }
    }

    private func row(title: String, note: String, warns: Bool = false, on: Binding<Bool>) -> some View {
        Toggle(isOn: on) {
            HStack(spacing: Space.md) {
                Text(title).font(Typography.label)
                Spacer(minLength: 8)
                Text(note).font(Typography.caption)
                    .foregroundStyle(warns ? Theme.attentionText : Color.secondary)
            }
        }
        .toggleStyle(.appCheckbox)
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
        VStack(alignment: .leading, spacing: Space.lg) {
            header
            if opinion.sent == nil {
                // Held together so the body folds away as one piece once the points go,
                // rather than each row dropping out on its own.
                VStack(alignment: .leading, spacing: Space.lg) {
                    if opinion.isRunning || opinion.lanes.contains(where: isFailed) {
                        FlowRow(spacing: Space.sm) {
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
                            .font(Typography.detail).foregroundStyle(.secondary)
                    }
                    verdicts
                    if !opinion.points.isEmpty { points }
                    if opinion.finishedCount > 0 && !opinion.isRunning { footer }
                }
                .transition(.fold)
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(Theme.card, cornerRadius: Radius.floating, border: Theme.border)
        .smoothlyResizes(when: opinion.sent)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Second opinion on this \(opinion.subject.noun)")
        .accessibilityAddTraits(opinion.isRunning ? .updatesFrequently : [])
    }

    private var header: some View {
        HStack(spacing: Space.md) {
            HStack(spacing: -6) {
                ForEach(Array(opinion.lanes.enumerated()), id: \.offset) { ReviewAvatar(agent: $0.element.reviewer.agent, size: 22) }
            }
            Text("Second opinion on this \(opinion.subject.noun)").font(Typography.body.weight(.semibold))
            Spacer(minLength: 8)
            if let sent = opinion.sent {
                Label("Sent \(counted(sent, "point")) to \(authorTitle)", systemImage: "checkmark")
                    .font(Typography.label).foregroundStyle(Theme.dotOnText)
            } else if opinion.isRunning {
                Text("Reading on their own").font(Typography.detail).foregroundStyle(.secondary)
            } else {
                Text("\(opinion.finishedCount) of \(opinion.lanes.count) finished")
                    .font(Typography.detail).foregroundStyle(.secondary)
                GlyphButton(icon: "arrow.clockwise", side: ControlHeight.xs, action: askAgain)
                    .appTooltip("Ask again")
                    .accessibilityLabel("Ask again")
            }
            GlyphButton(icon: "xmark", side: ControlHeight.xs, action: dismiss)
                .appTooltip(opinion.isRunning ? "Stop and put away" : "Put away")
                .accessibilityLabel(opinion.isRunning ? "Stop the second opinion" : "Put the second opinion away")
        }
    }

    @ViewBuilder private var verdicts: some View {
        let done = opinion.lanes.filter(isFinished)
        if !done.isEmpty {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.md, alignment: .top),
                                     count: min(done.count, 2)), alignment: .leading, spacing: Space.md) {
                ForEach(done) { lane in
                    if case .finished(let verdict, let summary) = lane.state {
                        VStack(alignment: .leading, spacing: Space.sm) {
                            HStack(spacing: Space.sm) {
                                ReviewAvatar(agent: lane.reviewer.agent, size: 18)
                                Text(lane.reviewer.agent.title).font(Typography.label)
                                if let seat = lane.reviewer.seatLabel {
                                    Text(seat).font(Typography.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            VerdictChip(verdict: verdict)
                            if !summary.isEmpty {
                                Text(summary).font(Typography.detail).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(Space.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Radius.card).fill(Theme.field))
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private var points: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.sm) {
                Text("What they raised").font(Typography.label)
                Text("Ticked points go to \(authorTitle). The rest stay here.")
                    .font(Typography.detail).foregroundStyle(.tertiary)
            }
            ForEach(opinion.points) { point in
                Toggle(isOn: Binding(get: { point.ticked }, set: { _ in toggle(point.id) })) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        HStack(spacing: Space.sm) {
                            HStack(spacing: -5) {
                                ForEach(Array(point.voices.enumerated()), id: \.offset) {
                                    ReviewAvatar(agent: $0.element.reviewer.agent, size: 16)
                                }
                            }
                            if let step = point.step {
                                Text("Step \(step)").font(Typography.label)
                            }
                            SeverityChip(severity: point.severity)
                            if point.raisedByMoreThanOne {
                                Label(point.voices.count == 2 ? "Both raised this" : "\(point.voices.count) raised this",
                                      systemImage: "checkmark")
                                    .font(Typography.caption.weight(.semibold)).foregroundStyle(Theme.dotOnText)
                            }
                        }
                        ReviewText(text: point.text, size: 12)
                        ForEach(Array(point.voices.dropFirst().enumerated()), id: \.offset) { _, voice in
                            Text("\(voice.reviewer.label()): \(voice.text)")
                                .font(Typography.detail).foregroundStyle(.secondary)
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
        return HStack(spacing: Space.md) {
            ActionButton(title: count > 0 ? "Send \(counted(count, "point")) to \(authorTitle)" : "Tick a point to send",
                         tone: .green, height: ControlHeight.md, size: Typography.Size.detail, action: send)
                .disabled(count == 0)
                .contentTransition(.numericText(value: Double(count)))
                .motion(Motion.control, value: count)
            if planPending {
                ActionButton(title: "Approve plan as is", tone: .outlined, height: ControlHeight.md, size: Typography.Size.detail, action: approve)
            }
            Spacer(minLength: 0)
            if planPending {
                Text("\(authorTitle) revises the plan. Nothing changes until you approve.")
                    .font(Typography.caption).foregroundStyle(.tertiary)
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
            .font(Typography.caption.weight(.semibold))
            .foregroundStyle(ink)
            .padding(.horizontal, Space.sm).padding(.vertical, Space.xxs)
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
