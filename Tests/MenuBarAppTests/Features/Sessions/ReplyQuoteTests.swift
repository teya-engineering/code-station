import Testing
@testable import MenuBarApp

// Text picked out of the transcript, taken into the composer as a Markdown quote.
struct ReplyQuoteTests {

    @Test func quotesOneLineIntoAnEmptyDraft() {
        #expect(ReplyQuote.appending("Use a retry with backoff.", to: "") ==
                "> Use a retry with backoff.\n\n")
    }

    @Test func keepsAQuoteOfSeveralParagraphsAsOneBlock() {
        let selection = "First point.\n\nSecond point,\nwrapped."
        #expect(ReplyQuote.appending(selection, to: "") ==
                "> First point.\n>\n> Second point,\n> wrapped.\n\n")
    }

    @Test func quotedCodeKeepsItsIndentation() {
        let selection = "if retry {\n    wait()   \n}"
        #expect(ReplyQuote.appending(selection, to: "") ==
                "> if retry {\n>     wait()\n> }\n\n")
    }

    @Test func goesBelowWhatIsAlreadyTyped() {
        #expect(ReplyQuote.appending("Second point.", to: "About this:\n") ==
                "About this:\n\n> Second point.\n\n")
    }

    @Test func trimsTheSelectionAndIgnoresAnEmptyOne() {
        #expect(ReplyQuote.appending("\n  Point.  \n\n", to: "") == "> Point.\n\n")
        #expect(ReplyQuote.appending(" \n ", to: "Draft") == "Draft")
    }

    @Test func sentBubbleDrawsTheQuoteApartFromTheAnswer() {
        let selection = "if retry {\n    wait()\n}\n\nThen log it."
        let prompt = ReplyQuote.appending(selection, to: "About this:") + "Why wait here?"
        #expect(SentPrompt.quoteRuns(prompt) == [
            .init(isQuote: false, text: "About this:"),
            .init(isQuote: true, text: "if retry {\n    wait()\n}\n\nThen log it."),
            .init(isQuote: false, text: "Why wait here?"),
        ])
    }

    @Test func promptWithoutQuotesIsOneRunAsTyped() {
        #expect(SentPrompt.quoteRuns("  indented\nsecond line") ==
                [.init(isQuote: false, text: "  indented\nsecond line")])
    }
}
