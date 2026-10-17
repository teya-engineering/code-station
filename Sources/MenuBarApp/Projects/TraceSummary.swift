import Foundation

// The few lines at the top of the Trace tab: what the request did, where its time went,
// and what failed. Asked of the session's own CLI in a throwaway run, so the question and
// the answer stay out of the conversation.
enum TraceSummary {
    static let instructions = """
    Do not use tools and do not change any files. Below is one distributed trace, condensed to its span tree. In 3 to 5 short lines of plain text, say what the request did, where its time went, and what failed and where. Name the services and operations. No headings, no markdown, no preamble. Return only the summary.
    """

    static let maxCharacters = 1_200

    static func prompt(condensed: String) -> String {
        "\(instructions)\n\n\(condensed)"
    }

    static func cleaned(_ text: String?) -> String? {
        guard var clean = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clean.isEmpty else { return nil }
        let lower = clean.lowercased()
        let failures = ["api error", "prompt is too long", "invalid api key"]
        if failures.contains(where: { lower.hasPrefix($0) }) { return nil }
        if lower.hasPrefix("summary:") {
            clean = String(clean.dropFirst("summary:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !clean.isEmpty else { return nil }
        return clean.count > maxCharacters ? String(clean.prefix(maxCharacters)) + "…" : clean
    }

    struct ChatDraft: Equatable {
        let text: String
        let fileName: String
        let contents: String
    }

    // The composer gets the start of a question; the trace itself goes along as an attached
    // file, so the field stays readable and the person sees what is being sent.
    static func chatDraft(trace: Trace, environment: TroubleshootEnvironment) -> ChatDraft {
        ChatDraft(
            text: "About trace `\(trace.traceID)` in \(environment.title) (attached): ",
            fileName: "trace-\(trace.traceID).txt",
            contents: """
            The person is asking about this trace. Fetch it again if you need more than this.

            \(TraceCondenser.text(trace, environment: environment.promptTitle))
            """)
    }

    @MainActor
    static func ask(sessionID: UUID, prompt: String, runner: SessionRunner,
                    store: ProjectStore) async -> String? {
        guard let session = store.session(sessionID),
              let path = runner.agentPath(session.agent),
              let directory = store.workingDirectories(for: session).first else { return nil }
        let text = await OneShotAgent.read(
            agent: session.agent, at: path,
            arguments: PromptSuggestion.arguments(for: session.agent, prompt: prompt),
            searchPath: ProcessManager.searchPath, workingDirectory: directory,
            timeout: .seconds(60), purpose: "trace summary")
        return cleaned(text)
    }
}
