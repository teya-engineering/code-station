import CodeStationCore
import Foundation
import Testing
import TerminalTranscript

// Text from agents and files is drawn, never obeyed. Whatever escape codes or control
// characters it carries are taken out or shown as visible symbols before it reaches the
// terminal, and widths count what is really drawn.
struct TerminalTextTests {

    @Test(arguments: [
        // SGR colour and a reset around a word.
        ("\u{1B}[31mred\u{1B}[0m", "red"),
        // Clear screen, cursor moves, private modes.
        ("a\u{1B}[2J\u{1B}[1;1Hb\u{1B}[?25l", "ab"),
        // A window title set by OSC, ended by BEL and by ST.
        ("\u{1B}]0;pwned\u{07}x", "x"),
        ("\u{1B}]8;;https://e.com\u{1B}\\link\u{1B}]8;;\u{1B}\\", "link"),
        // DCS and APC strings.
        ("\u{1B}Pq#0;2\u{1B}\\ok", "ok"),
        ("\u{1B}_hidden\u{1B}\\ok", "ok"),
        // Two-byte escapes: charset designation, save cursor, full reset.
        ("\u{1B}(Ba\u{1B}7b\u{1B}c", "ab"),
        // C1 controls: an 8-bit CSI sequence, an 8-bit OSC, and a stray one.
        ("\u{9B}31mred", "red"),
        ("\u{9D}0;title\u{9C}x", "x"),
        ("a\u{85}b", "ab"),
        // Carriage returns: CRLF is a line break, and so is a lone CR.
        ("one\r\ntwo", "one\ntwo"),
        ("50%\r100%", "50%\n100%"),
        // Tabs become four spaces; newlines stay.
        ("a\tb\nc", "a    b\nc"),
        // Other controls are shown as their symbols.
        ("bell\u{07}", "bell␇"),
        ("nul\u{00}del\u{7F}", "nul␀del␡"),
        ("back\u{08}space", "back␈space"),
        // An escape with nothing after it is shown, not sent.
        ("end\u{1B}", "end␛"),
        // An unterminated OSC swallows the rest rather than reaching the terminal.
        ("ok\u{1B}]0;title", "ok"),
        // Ordinary text is left alone.
        ("café 日本 ✓", "café 日本 ✓"),
    ])
    func controlsAreStrippedOrMadeVisible(input: String, drawn: String) {
        #expect(TerminalText.sanitized(input) == drawn)
    }

    @Test func fittingCountsOnlyWhatIsDrawn() {
        let fitted = TerminalColumns.fit("\u{1B}[1mTitle\u{1B}[0m\u{1B}]0;x\u{07}", to: 8)

        #expect(fitted == "Title")
        #expect(!fitted.contains("\u{1B}"))
        #expect(TerminalColumns.fit("\u{1B}[31mabcdefghij", to: 6) == "abcde…")
        #expect(TerminalColumns.fit("a\tb", to: 10) == "a    b")
    }

    @Test(arguments: [
        "\u{1B}[2J\u{1B}[HThe build \u{1B}[32mpassed\u{1B}[0m and \u{1B}]0;title\u{07}more words follow",
        "line one\r\nline two\rline three\u{9B}2J",
        "tabs\there\tand\u{07}bells\u{00}too",
    ])
    func proseLinesCarryNoControlsAndFitTheWidth(text: String) {
        let lines = TranscriptRenderer.lines(for: answer(text), width: 12)

        #expect(!lines.isEmpty)
        for line in lines {
            #expect(!line.text.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) })
            #expect(line.width <= 12)
        }
    }

    @Test func aPromptsCarriageReturnsBreakItsLines() {
        let lines = TranscriptRenderer.lines(for: prompt("one\r\ntwo"), width: 20)

        #expect(lines.map(\.text) == ["› one", "  two"])
    }

    @Test func toolOutputIsDrawnWithoutItsEscapes() {
        let tool = RemoteTool(id: "t", name: "Bash", argument: "make\u{1B}]0;x\u{07}",
                              result: "\u{1B}[1;31merror\u{1B}[0m: failed\r\nnext\u{1B}[K")
        let message = answer(blocks: [.init(kind: "tools", tools: [tool])], id: "m")

        let lines = TranscriptRenderer.lines(for: message, width: 30, expanded: ["t"])

        #expect(lines.map(\.text) == ["● Bash · make", "  error: failed", "  next"])
    }

    @Test func aThemeEncodesNoControlsFromTheText() {
        let line = StyledLine([Span("\u{1B}[2Jgone", .tool)])

        #expect(TranscriptTheme.basic.encode(line) == "\u{1B}[36mgone\u{1B}[0m")
    }
}
