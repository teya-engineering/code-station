import AppKit
import SwiftUI

// Looking a request up by its traceId: the whole of it as Tempo has it, drawn as Grafana
// draws it, with the ways out of it beside it.
struct TraceTabView: View {
    @Environment(TraceStore.self) private var traces
    @Environment(GrafanaQueryRunner.self) private var grafana
    @Environment(SessionRunner.self) private var runner

    let sessionID: UUID
    let openConversation: () -> Void
    let openTroubleshoot: () -> Void

    @FocusState private var inputFocused: Bool
    @State private var showsRawAnswer = false

    // The lookup is the store's, not this view's: the pane keeps only the tab that is
    // open, so anything held here would go the moment Chat is looked at.
    private var lookup: TraceStore.Lookup { traces.lookup(sessionID) }

    private func entry<Value>(_ field: WritableKeyPath<TraceStore.Lookup, Value>) -> Binding<Value> {
        Binding(get: { traces.lookup(sessionID)[keyPath: field] },
                set: { value in traces.edit(sessionID) { $0[keyPath: field] = value } })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heading
                inputCard
                state
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .onAppear { if lookup.trace == nil { inputFocused = true } }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Trace").font(.serif(21))
            Text("Look a request up by its traceId. Every span comes from the Tempo on the \(TraceStore.tempoScope) Grafana.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("ENVIRONMENT")
            TroubleshootEnvironmentPills(environment: entry(\.environment))
            HStack(spacing: 10) {
                TextField("traceId, or a Grafana trace link", text: entry(\.input))
                    .textFieldStyle(.plain)
                    .font(.mono(12.5))
                    .focused($inputFocused)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .surface(Theme.field, cornerRadius: 8, border: Theme.border)
                    .onSubmit { traces.find(sessionID) }
                ActionButton(title: isFetching ? "Finding…" : "Find trace",
                             tone: .green, height: 32, size: 12.5) {
                    traces.find(sessionID)
                }
                .disabled(isFetching || lookup.input.isBlank)
            }
        }
        .padding(15)
        .cardSurface(cornerRadius: 11)
    }

    private var isFetching: Bool {
        if case .fetching = lookup.phase { return true }
        return false
    }

    @ViewBuilder private var state: some View {
        switch lookup.phase {
        case .idle:
            EmptyView()
        case .fetching(let server):
            Text("Asking \(server)…")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        case .failed(let failure):
            failureCard(failure)
        case .found:
            if let trace = lookup.trace { found(trace) }
        }
    }

    private func failureCard(_ failure: TraceStore.Failure) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(failure.message)
                .font(.system(size: 12.5))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if case .notFound(_, let environment) = failure {
                HStack(spacing: 6) {
                    ForEach(TroubleshootEnvironment.all().filter { $0 != environment }) { other in
                        ChoicePill(title: "Try \(other.title)", selected: false) {
                            traces.edit(sessionID) { $0.environment = other }
                            traces.find(sessionID)
                        }
                    }
                }
            }
            if case .unreadable(let text) = failure {
                smallLink(showsRawAnswer ? "Hide the answer" : "Show the answer") {
                    showsRawAnswer.toggle()
                }
                if showsRawAnswer {
                    Text(text)
                        .scaledMono(11)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .surface(Theme.sunken, cornerRadius: 8, border: Theme.border)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 11)
    }

    private func found(_ trace: Trace) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            summaryCard
            actionRow(trace)
            TraceWaterfallView(trace: trace) { span in spanLogs(span, trace: trace) }
        }
    }

    private var services: [SiteDefaults.Service] { SiteDefaults.current.services ?? [] }

    @ViewBuilder private func spanLogs(_ span: Trace.Span, trace: Trace) -> some View {
        let key = TraceSpanLogs.toolID(traceID: trace.traceID, spanID: span.id,
                                       environment: lookup.shownEnvironment.name)
        if let logs = traces.spanLogs(key) {
            if let call = logs.call, let toolID = logs.toolID {
                GrafanaResultView(call: call, result: .empty, toolID: toolID,
                                  service: logs.service, followsLatestRun: true)
            } else if let message = logs.message {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    smallLink("Try again") {
                        traces.showLogs(for: span, sessionID: sessionID, services: services)
                    }
                }
            } else {
                Text("Finding the Loki datasource…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } else {
            switch TraceSpanLogs.plan(span: span, trace: trace,
                                      environment: lookup.shownEnvironment.name, services: services) {
            case .run(let server, _, _, _, _):
                smallLink("Logs for this trace in \(span.service) →") {
                    traces.showLogs(for: span, sessionID: sessionID, services: services)
                }
                .appTooltip("Reads them from \(server)")
            case .unavailable(let reason):
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                SectionLabel("SUMMARY")
                Spacer(minLength: 8)
                if lookup.summary != .running {
                    smallLink(lookup.summary == .failed ? "Retry" : "Regenerate") {
                        traces.summarise(sessionID)
                    }
                }
                ActionButton(title: "Ask in Chat", tone: .outlined, height: 26, size: 11.5) {
                    traces.askInChat(sessionID, runner: runner)
                    openConversation()
                }
            }
            switch lookup.summary {
            case .idle, .running:
                Text("Summarising…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            case .done(let text):
                Text(text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed:
                Text("No summary. The agent did not answer.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 11)
    }

    private func actionRow(_ trace: Trace) -> some View {
        HStack(spacing: 10) {
            ActionButton(title: "Troubleshoot this trace", tone: .dark, height: 30, size: 12,
                         icon: "stethoscope") {
                traces.troubleshoot(sessionID, runner: runner, services: services)
                openTroubleshoot()
            }
            if let link = grafanaLink(trace) {
                ActionButton(title: "Open in Grafana", tone: .outlined, height: 30, size: 12,
                             icon: "arrow.up.right.square") {
                    NSWorkspace.shared.open(link)
                }
            }
            Spacer(minLength: 0)
            if let datasource = lookup.datasource, let server = lookup.server {
                Text("\(datasource.name) on \(server)")
                    .font(.mono(10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func grafanaLink(_ trace: Trace) -> URL? {
        guard let server = lookup.server, let datasource = lookup.datasource,
              let base = grafana.grafanaURL(ofServer: server) else { return nil }
        return TraceLink.explore(grafanaURL: base, datasourceUID: datasource.uid,
                                 traceID: trace.traceID)
    }

    private func smallLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
