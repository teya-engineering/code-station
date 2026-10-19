import SwiftUI
import Testing
@testable import CodeStationCore
@testable import MenuBarApp

struct SentPromptTests {
    @Test func formatsInlineCodeAndKeepsLineBreaks() {
        let text = SentPrompt.inline("Use `some_value` here.\n\n  Keep this line.", commandNames: [])

        #expect(String(text.characters) == "Use some_value here.\n\n  Keep this line.")
        #expect(text.runs.contains {
            String(text[$0.range].characters) == "some_value"
                && $0.inlinePresentationIntent?.contains(.code) == true
        })
    }

    @Test func linksAPastedURLWithoutItsSurroundingPunctuation() {
        let url = "https://github.com/saltpay/o11y-collector-external/pull/8"
        let text = SentPrompt.inline("👋 /review pull request 8 (\(url)).", commandNames: ["review"])
        let links = text.runs.filter { $0.link != nil }

        #expect(links.count == 1)
        #expect(links.first?.link?.absoluteString == url)
        #expect(links.map { String(text[$0.range].characters) } == [url])
    }

    @Test func preservesExplicitLinksAndDoesNotLinkInlineCode() {
        let text = SentPrompt.inline(
            "[https://label.example](https://target.example) `https://code.example` https://plain.example",
            commandNames: [])

        #expect(text.runs.compactMap(\.link).map(\.absoluteString)
            == ["https://target.example", "https://plain.example"])
    }

    @Test func keepsLocalMarkdownLinks() {
        let text = SentPrompt.inline("Read [the file](/tmp/report.txt:12).", commandNames: [])

        #expect(text.runs.compactMap(\.link).first?.isFileURL == true)
    }

    @Test(arguments: ["/review pull request 8", "  /REVIEW\ncheck this", "/backend:review changes"])
    func highlightsKnownLeadingCommands(prompt: String) {
        let text = SentPrompt.inline(prompt, commandNames: ["review", "backend:review"])
        let highlighted = text.runs.filter { $0.foregroundColor == Theme.accent }

        #expect(highlighted.count == 1)
        #expect(highlighted.allSatisfy { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    }

    @Test(arguments: ["/tmp/file.txt", "/review/file.txt", "/unknown fix this", "Try /review",
                      "`/review`", "[/review](https://example.com)", "**/review**", "/reviewer"])
    func leavesPathsUnknownCommandsAndQuotedCommandsAlone(prompt: String) {
        let text = SentPrompt.inline(prompt, commandNames: ["review"])

        #expect(!text.runs.contains { $0.foregroundColor == Theme.accent })
    }

    @Test func preservesPlainPromptWhitespace() {
        let prompt = "  first\n\nsecond  \n"

        #expect(SentPrompt.segments(prompt) == [MessageSegment(id: 0, text: prompt, isCode: false)])
    }

    @Test func splitsFencesAndPreservesCodeIndentationAndBlankLines() {
        let prompt = "Before\n```swift\n\n    let value = 1\n\n```\nAfter"
        let segments = SentPrompt.segments(prompt)

        #expect(segments.map(\.text) == ["Before", "\n    let value = 1\n", "After"])
        #expect(segments.map(\.isCode) == [false, true, false])
        #expect(segments[1].language == "swift")
        #expect(!segments[1].isOpen)
    }

    @Test func keepsShorterFencesInsideAnOuterFence() {
        let segments = SentPrompt.segments("````markdown\n```swift\nlet x = 1\n```\n````")

        #expect(segments.count == 1)
        #expect(segments.first?.text == "```swift\nlet x = 1\n```")
        #expect(segments.first?.language == "markdown")
    }

    @Test func letsTheBlockSpacingSeparateCodeFromProse() {
        let segments = SentPrompt.segments("Before\n\n```text\n\n  code\n\n```\n\nAfter")

        #expect(segments.map(\.text) == ["Before", "\n  code\n", "After"])
    }

    @Test func acceptsTildeAndUnclosedFences() {
        let segments = SentPrompt.segments("~~~text\n/review https://example.com\n~~~\n```swift\nlet x = 1")

        #expect(segments.map(\.isCode) == [true, true])
        #expect(segments.map(\.isOpen) == [false, true])
        #expect(segments.last?.text == "let x = 1")
    }

    @Test func doesNotTreatInlineBackticksAsABlock() {
        let prompt = "Explain ```some code``` and `other code`."

        #expect(SentPrompt.segments(prompt) == [MessageSegment(id: 0, text: prompt, isCode: false)])
    }
}
