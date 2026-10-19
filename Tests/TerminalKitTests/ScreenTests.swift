import Testing
import TerminalKit

// The screen turns a frame (one styled string per row) into the bytes that bring the
// terminal from the last frame to this one. Only rows that changed are rewritten, and
// every frame is one synchronized update so the terminal never shows half of it.
struct ScreenTests {
    private let begin = "\u{1B}[?2026h"
    private let end = "\u{1B}[?2026l"
    private let hideCursor = "\u{1B}[?25l"
    private let clear = "\u{1B}[2J"

    private func row(_ number: Int, _ text: String) -> String {
        "\u{1B}[\(number);1H\u{1B}[0m\(text)\u{1B}[0m\u{1B}[K"
    }

    @Test func theFirstFrameClearsAndPaintsEveryRow() {
        var screen = Screen()
        let bytes = screen.render(["one", "two"], size: TerminalSize(cols: 10, rows: 2))
        #expect(bytes == begin + clear + row(1, "one") + row(2, "two") + hideCursor + end)
    }

    @Test func anUnchangedFrameWritesNoRows() {
        var screen = Screen()
        let size = TerminalSize(cols: 10, rows: 2)
        _ = screen.render(["one", "two"], size: size)
        #expect(screen.render(["one", "two"], size: size) == begin + hideCursor + end)
    }

    @Test func onlyTheRowThatChangedIsRewritten() {
        var screen = Screen()
        let size = TerminalSize(cols: 10, rows: 3)
        _ = screen.render(["one", "two", "three"], size: size)
        #expect(screen.render(["one", "2", "three"], size: size)
                == begin + row(2, "2") + hideCursor + end)
    }

    // A frame shorter than the screen leaves the rows under it blank, and rows past the
    // bottom are never written, since they would scroll the screen.
    @Test func aFrameIsFittedToTheScreensHeight() {
        var screen = Screen()
        #expect(screen.render(["a"], size: TerminalSize(cols: 5, rows: 2))
                == begin + clear + row(1, "a") + row(2, "") + hideCursor + end)
        var tall = Screen()
        #expect(tall.render(["a", "b", "c"], size: TerminalSize(cols: 5, rows: 2))
                == begin + clear + row(1, "a") + row(2, "b") + hideCursor + end)
    }

    @Test func aNewSizeRepaintsEverything() {
        var screen = Screen()
        _ = screen.render(["one", "two"], size: TerminalSize(cols: 10, rows: 2))
        #expect(screen.render(["one", "two"], size: TerminalSize(cols: 20, rows: 2))
                == begin + clear + row(1, "one") + row(2, "two") + hideCursor + end)
    }

    @Test func invalidatingRepaintsTheNextFrame() {
        var screen = Screen()
        let size = TerminalSize(cols: 10, rows: 1)
        _ = screen.render(["one"], size: size)
        screen.invalidate()
        #expect(screen.render(["one"], size: size) == begin + clear + row(1, "one") + hideCursor + end)
    }

    @Test func aCursorIsPlacedAndShown() {
        var screen = Screen()
        let bytes = screen.render(["> hi"], size: TerminalSize(cols: 10, rows: 1),
                                  cursor: Screen.Cursor(row: 0, col: 4))
        #expect(bytes == begin + clear + row(1, "> hi") + "\u{1B}[1;5H\u{1B}[?25h" + end)
    }
}
