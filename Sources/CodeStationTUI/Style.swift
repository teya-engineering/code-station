import TerminalTranscript

// SGR codes in the basic 16-colour palette, which every terminal has.
enum Style {
    static let reset = "\u{1B}[0m"
    static let bold = "\u{1B}[1m"
    static let dim = "\u{1B}[2m"
    static let reverse = "\u{1B}[7m"
    static let red = "\u{1B}[31m"
    static let green = "\u{1B}[32m"
    static let yellow = "\u{1B}[33m"
    static let magenta = "\u{1B}[35m"
    static let cyan = "\u{1B}[36m"

    // What a style of the transcript theme turns on, at the theme's colour depth. Empty
    // when the style is drawn plain.
    static func code(_ style: LineStyle, theme: TranscriptTheme) -> String {
        theme.sgr(for: style).map { "\u{1B}[\($0)m" } ?? ""
    }

    // A session's state word in the colour the GUI gives its tone.
    static func state(_ word: String, theme: TranscriptTheme) -> String {
        code(.state(StateTone(word: word)), theme: theme)
    }
}
