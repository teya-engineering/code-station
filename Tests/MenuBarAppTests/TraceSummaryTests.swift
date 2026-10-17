import Testing
@testable import MenuBarApp

struct TraceSummaryTests {
    @Test func asksForAShortPlainSummaryOfTheCondensedTrace() {
        let prompt = TraceSummary.prompt(condensed: "Trace abc in dev: 2 spans")
        #expect(prompt.hasPrefix(TraceSummary.instructions))
        #expect(prompt.hasSuffix("Trace abc in dev: 2 spans"))
        #expect(TraceSummary.instructions.contains("Do not use tools"))
    }

    @Test func keepsWhatTheAgentWroteMinusItsLabel() {
        #expect(TraceSummary.cleaned("  Summary: The gateway timed out.\nOrders was slow.  ")
                == "The gateway timed out.\nOrders was slow.")
        #expect(TraceSummary.cleaned("The gateway timed out.") == "The gateway timed out.")
    }

    @Test func dropsAnAnswerThatIsNotASummary() {
        #expect(TraceSummary.cleaned(nil) == nil)
        #expect(TraceSummary.cleaned("   \n ") == nil)
        #expect(TraceSummary.cleaned("API Error: 529 overloaded") == nil)
        #expect(TraceSummary.cleaned("Summary:") == nil)
    }

    @Test func capsALongAnswer() {
        let long = String(repeating: "a", count: 5_000)
        #expect(TraceSummary.cleaned(long)?.count == TraceSummary.maxCharacters + 1)
    }

    @Test func startsAChatMessageAboutTheTrace() {
        let trace = Trace(traceID: "abc", spans: [TraceTests.span("r", start: 0, duration: 1_000_000)])
        let prod = TroubleshootEnvironment(name: "prd", title: "Prod", isDangerous: true)
        let draft = TraceSummary.chatDraft(trace: trace, environment: prod)
        #expect(draft.text == "About trace `abc` in Prod (attached): ")
        #expect(draft.fileName == "trace-abc.txt")
        #expect(draft.contents.contains("Trace abc in Prod (prd)"))
    }
}
