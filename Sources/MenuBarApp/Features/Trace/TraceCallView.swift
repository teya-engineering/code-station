import SwiftUI

// A trace the agent fetched, drawn as the waterfall rather than as the JSON it came in. A
// trace the transcript cut short cannot be drawn from what was kept, so it shows as text
// with a way to ask the agent to draw it in full.
struct TraceCallView: View {
    @Environment(\.askAgent) private var askAgent

    let rendering: TraceRendering
    let output: String

    var body: some View {
        switch rendering {
        case .trace(_, let trace):
            TraceWaterfallView(trace: trace, maxHeight: 460)
        case .truncated(let call):
            VStack(alignment: .leading, spacing: Space.md) {
                ToolOutputCard(label: "OUTPUT", text: output, isFailure: false, runInShell: nil)
                if let askAgent, let traceID = call.traceID {
                    InlineAskButton(title: "Ask the agent to draw this trace") {
                        askAgent(TraceFollowUp.fullTrace(traceID, server: call.server))
                    }
                }
            }
        }
    }
}

// What a finished call's result reads as, kept so a transcript drawn again does not parse
// the same JSON again. A result never changes once it has arrived, so its id and length
// are enough to tell whether what is kept still stands for it.
@MainActor
enum ToolRenderingCache {
    enum Rendering {
        case grafana(GrafanaRendering)
        case trace(TraceRendering)
        case none
    }

    private struct Entry {
        let resultLength: Int
        let rendering: Rendering
    }

    private static var entries: [String: Entry] = [:]
    private static let limit = 500

    static func rendering(of tool: ToolUse) -> Rendering {
        guard let result = tool.result, !tool.isError else { return .none }
        if let entry = entries[tool.id], entry.resultLength == result.utf8.count {
            return entry.rendering
        }
        let rendering: Rendering = if let grafana = GrafanaToolCall.rendered(tool) {
            .grafana(grafana)
        } else if let trace = TraceToolCall.rendered(tool) {
            .trace(trace)
        } else {
            .none
        }
        if entries.count >= limit { entries.removeAll(keepingCapacity: true) }
        entries[tool.id] = Entry(resultLength: result.utf8.count, rendering: rendering)
        return rendering
    }
}
