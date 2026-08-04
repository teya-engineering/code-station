import Foundation
import Testing
@testable import MenuBarApp

// The emulator turns a shell's byte stream into lines. These cover the sequences that
// ordinary command output actually uses.
struct TerminalEmulatorTests {

    private func render(_ input: String) -> [String] {
        var emulator = TerminalEmulator()
        emulator.feed(Data(input.utf8))
        return emulator.lines().map(\.text)
    }

    @Test func splitsOnNewlines() {
        #expect(render("one\ntwo\nthree") == ["one", "two", "three"])
    }

    @Test func carriageReturnOverwritesTheLine() {
        // How a progress counter redraws itself in place.
        #expect(render("50%\r100%") == ["100%"])
    }

    // A shorter overwrite leaves the tail of what was there, exactly like a real tty.
    @Test func carriageReturnLeavesUncoveredText() {
        #expect(render("longer\rab") == ["abnger"])
    }

    @Test func eraseToEndOfLineClearsTheTail() {
        #expect(render("longer\rab\u{1B}[K") == ["ab"])
    }

    @Test func backspaceMovesTheCursorBack() {
        #expect(render("abc\u{8}d") == ["abd"])
    }

    @Test func tabsAdvanceToTheNextStop() {
        #expect(render("a\tb") == ["a       b"])
    }

    @Test func colourCodesBecomeStyledSpansNotText() {
        var emulator = TerminalEmulator()
        emulator.feed(Data("\u{1B}[32mBuild complete!\u{1B}[0m".utf8))
        let lines = emulator.lines()
        #expect(lines.count == 1)
        #expect(lines[0].text == "Build complete!")
        #expect(lines[0].spans.first?.style.color == .green)
    }

    @Test func boldAndColourCombine() {
        var emulator = TerminalEmulator()
        emulator.feed(Data("\u{1B}[1;31merror\u{1B}[0m: bad".utf8))
        let spans = emulator.lines()[0].spans
        #expect(spans[0].text == "error")
        #expect(spans[0].style.bold)
        #expect(spans[0].style.color == .red)
        // The reset has to end the styling, or the whole line turns red.
        #expect(spans[1].style.color == nil)
        #expect(spans[1].style.bold == false)
    }

    @Test func twoHundredFiftySixColoursAreMapped() {
        var emulator = TerminalEmulator()
        emulator.feed(Data("\u{1B}[38;5;9mx".utf8))
        #expect(emulator.lines()[0].spans[0].style.color == .brightRed)
    }

    // Window title sequences must never show up as text.
    @Test func operatingSystemCommandsAreSwallowed() {
        #expect(render("\u{1B}]0;my title\u{7}done") == ["done"])
    }

    @Test func unknownSequencesDoNotLeak() {
        #expect(render("\u{1B}[?25lhidden\u{1B}[?25h") == ["hidden"])
    }

    @Test func clearScreenStartsOver() {
        #expect(render("old stuff\n\u{1B}[2Jfresh") == ["fresh"])
    }

    // Reads off a pipe do not line up with escape sequences or characters.
    @Test func sequencesSplitAcrossReadsStillWork() {
        var emulator = TerminalEmulator()
        emulator.feed(Data("\u{1B}[3".utf8))
        emulator.feed(Data("2mgreen".utf8))
        let line = emulator.lines()[0]
        #expect(line.text == "green")
        #expect(line.spans[0].style.color == .green)
    }

    @Test func multiByteCharactersSplitAcrossReadsStillWork() {
        var emulator = TerminalEmulator()
        let bytes = Array("héllo".utf8)
        emulator.feed(Data(bytes[0..<2]))   // cuts the é in half
        emulator.feed(Data(bytes[2...]))
        #expect(emulator.lines()[0].text == "héllo")
    }

    @Test func scrollbackIsCapped() {
        var emulator = TerminalEmulator()
        emulator.feed(Data(String(repeating: "line\n", count: 6000).utf8))
        #expect(emulator.lineCount <= 5001)
    }
}
