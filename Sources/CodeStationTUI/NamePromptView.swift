import TerminalKit
import TerminalTranscript

// A new name typed over everything else, the terminal's version of the GUI's inline
// rename field: it starts on the old name, Enter saves, Esc cancels. Why a name was
// refused shows in its footer until the next key.
struct NamePromptView {
    let title: String
    var field = ComposerView()
    var notice: String?
    // The footer's key help.
    var help = " enter rename · esc cancel"

    init(title: String, name: String) {
        self.title = title
        field.replace(with: name)
    }

    enum Outcome { case edited, save, cancel, ignored }

    mutating func handle(_ key: Key) -> Outcome {
        notice = nil
        switch key {
        case .escape: return .cancel
        case .enter([]): return .save
        case .enter, .char("j", .ctrl): return .ignored
        case .paste(let text):
            return field.handle(.paste(text.split(whereSeparator: \.isNewline).joined(separator: " "))) == .ignored
                ? .ignored : .edited
        default:
            return field.handle(key) == .ignored ? .ignored : .edited
        }
    }

    func frame(size: TerminalSize, theme: TranscriptTheme) -> (lines: [String], cursor: Screen.Cursor?) {
        let width = max(size.cols, 10)
        var lines = [Style.bold + TerminalColumns.fit(" " + title, to: width) + Style.reset, ""]
        let (field, at) = field.layout(width: width - 1)
        let top = lines.count
        lines += field.map { " " + $0 }
        let rows = max(size.rows, lines.count + 1)
        lines += Array(repeating: "", count: rows - lines.count - 1)
        lines.append(notice.map { SidebarView.paint([(" " + $0, Style.code(.attention, theme: theme))], width: width) }
                     ?? Style.dim + TerminalColumns.fit(help, to: width) + Style.reset)
        return (lines, Screen.Cursor(row: top + at.row, col: at.col + 1))
    }
}
