import SwiftUI

struct SessionWorkingSetPreview: View {
    let session: ChatSession
    let state: SessionStateReading
    let reviewRequest: () -> Void

    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner

    var body: some View {
        let path = store.workingDirectory(for: session) ?? ""
        let entries = WorkingSetSummary.timeline(
            in: session.messages, activeTools: runner.runningTools(session.id),
            backgroundTasks: runner.activeBackgroundTasks(session.id),
            runningAgentIDs: runner.runningAgents(session.id), projectPath: path)
        let headline = WorkingSetSummary.headline(in: entries)
        let groups = WorkingSetSummary.turns(in: session.messages, entries: entries)
        VStack(spacing: 0) {
            currentWork(headline: headline, entries: entries, path: path)
            if groups.isEmpty {
                VStack(spacing: Space.xs) {
                    Text("Ready when you are").fontWeight(.semibold)
                    Text("Your next prompt will start the working set.")
                        .foregroundStyle(.secondary)
                }
                .font(Typography.detail)
                .padding(Space.xl)
                .frame(maxWidth: .infinity)
            } else {
                WorkingSetHistory(groups: groups, projectPath: path,
                                  headline: headline, compact: true)
            }
        }
        .id(session.id)
    }

    @ViewBuilder
    private func currentWork(headline: WorkingSetRunningItem?,
                             entries: [WorkingSetTimelineEntry], path: String) -> some View {
        let live = LiveConversation.id(of: session.id, store: store, runner: runner)
        if let request = runner.question(live) {
            VStack(alignment: .leading, spacing: Space.sm) {
                Label(request.isQuestion ? request.title : "Permission needed",
                      systemImage: "exclamationmark.circle")
                    .font(Typography.label)
                Text(request.subject.isBlank ? request.toolName : request.subject)
                    .font(Typography.data)
                    .lineLimit(2)
                InlineLink(title: "Review request", size: Typography.Size.detail, action: reviewRequest)
            }
            .foregroundStyle(Theme.attentionText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.lg)
            .background(RoundedRectangle(cornerRadius: Radius.control).fill(Theme.attention.opacity(0.1)))
            .padding(Space.lg)
        } else if let headline, state.tone == .running {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.sm) {
                    PulsingDot(size: 6)
                    Text("Current work").font(Typography.caption.weight(.semibold))
                    Spacer()
                    if let started = headline.startedAt {
                        ElapsedTime(since: started, size: 10)
                    }
                }
                .foregroundStyle(Theme.dotOnText)
                if let entry = entries.first(where: { $0.id == headline.id }),
                   case .call(let call) = entry.content {
                    WorkingSetTimelineRow(call: call, projectPath: path, indent: 0)
                } else {
                    Text(headline.title).font(Typography.data).lineLimit(1)
                    Text(headline.detail).font(Font.system(size: Typography.Size.micro)).foregroundStyle(.secondary)
                }
            }
            .padding(Space.md)
            .background(RoundedRectangle(cornerRadius: Radius.control).fill(Theme.dotOn.opacity(0.09)))
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)
        } else if !session.messages.isEmpty || state.tone == .running {
            HStack(spacing: Space.sm) {
                StateLight(tone: state.tone, size: 7)
                Text(state.completionActivity?.detail
                     ?? (state.tone == .running ? "Thinking" : state.tone == .idle ? "Finished" : state.spokenWord))
                    .font(Typography.detail.weight(.medium))
                Spacer()
            }
            .padding(Space.lg)
        }
    }
}
