import SwiftUI

// A trace the agent fetched, drawn as the waterfall rather than as the JSON it came in. A
// trace the transcript cut short cannot be drawn from what was kept, so it shows as text
// with a way to fetch it again in full.
struct TraceCallView: View {
    @Environment(TraceStore.self) private var traces: TraceStore?

    let rendering: TraceRendering
    let toolID: String
    let output: String

    var body: some View {
        switch rendering {
        case .trace(_, let trace):
            TraceWaterfallView(trace: trace, maxHeight: 420)
        case .truncated(let call):
            if let full = traces?.fullTrace(toolID)?.trace {
                TraceWaterfallView(trace: full, maxHeight: 420)
            } else {
                truncated(call)
            }
        }
    }

    private func truncated(_ call: TraceToolCall) -> some View {
        let state = traces?.fullTrace(toolID)
        return VStack(alignment: .leading, spacing: 8) {
            ToolOutputCard(label: "OUTPUT", text: output, isFailure: false, runInShell: nil)
            if let traces {
                HStack(spacing: 8) {
                    ChoicePill(title: state?.isLoading == true ? "Loading full trace…" : "Load full trace",
                               selected: false, enabled: state?.isLoading != true) {
                        traces.loadFull(toolID, call: call)
                    }
                    if let message = state?.message {
                        Text(message)
                            .scaledMono(10.5)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
