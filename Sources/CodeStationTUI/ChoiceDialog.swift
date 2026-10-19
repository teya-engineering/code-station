import TerminalKit
import TerminalTranscript

// A question with a few answers, over everything else, as the GUI's `Dialog` with
// several actions asks it: a title, a message and a row of buttons. Enter takes the
// focused button, which starts on the first; Tab and the arrows move between them. Esc
// closes without an answer.
struct ChoiceDialog<Answer> {
    let title: String
    var message: String?
    let buttons: [(label: String, answer: Answer)]
    private(set) var focused = 0

    init(_ title: String, message: String? = nil, buttons: [(label: String, answer: Answer)]) {
        self.title = title
        self.message = message
        self.buttons = buttons
    }

    enum Outcome { case handled, ignored, cancel, answer(Answer) }

    mutating func handle(_ key: Key) -> Outcome {
        guard !buttons.isEmpty else { return .cancel }
        switch key {
        case .escape, .char("q", []): return .cancel
        case .enter([]), .char(" ", []): return .answer(buttons[focused].answer)
        case .tab([]), .right, .char("l", []): focused = (focused + 1) % buttons.count
        case .tab(.shift), .left, .char("h", []): focused = (focused - 1 + buttons.count) % buttons.count
        default: return .ignored
        }
        return .handled
    }

    func frame(size: TerminalSize, theme: TranscriptTheme) -> [String] {
        let width = max(size.cols, 1)
        var lines = [SidebarView.paint([(" " + title, Style.bold)], width: width)]
        if let message {
            lines += TranscriptRenderer.wrap(message, width: max(width - 2, 1))
                .map { SidebarView.paint([(" " + $0, Style.dim)], width: width) }
        }
        lines.append("")
        var row: [(String, String)] = [(" ", "")]
        for (index, button) in buttons.enumerated() {
            if index > 0 { row.append(("  ", "")) }
            row.append(("[ \(button.label) ]", (index == 0 ? Style.bold : "") + (index == focused ? Style.reverse : "")))
        }
        lines.append(SidebarView.paint(row, width: width))
        let height = max(size.rows - 1, 1)
        let shown = Array(lines.prefix(height))
        let footer = SidebarView.paint([(" enter \(buttons[focused].label.lowercased()) · tab switch · esc close",
                                         Style.dim)], width: width)
        return shown + Array(repeating: "", count: max(height - shown.count, 0)) + [footer]
    }
}
