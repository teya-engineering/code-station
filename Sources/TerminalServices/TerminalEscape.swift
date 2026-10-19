import Foundation

// The escape sequences the terminal host writes, built as strings so tests can read the
// exact bytes.
enum TerminalEscape {
    static let bell = "\u{07}"

    // OSC 9: a desktop notification in iTerm2, Ghostty, kitty and WezTerm. Terminals
    // without it ignore the sequence. A control character would end it early, so none
    // goes in.
    static func notification(_ text: String) -> String {
        "\u{1B}]9;\(text.filter { !$0.isASCIIControl })\u{07}"
    }

    // OSC 52 to the system clipboard ("c"), the text in base64. It is carried in the
    // terminal's own stream, so it works over SSH wherever the terminal allows it
    // (iTerm2, Ghostty, kitty, WezTerm, Alacritty, xterm with allowWindowOps).
    static func clipboard(_ text: String) -> String {
        "\u{1B}]52;c;\(Data(text.utf8).base64EncodedString())\u{07}"
    }

    // tmux's passthrough: the sequence inside a DCS, every ESC in it doubled. tmux hands
    // it to the outer terminal untouched when `allow-passthrough` is on.
    static func tmuxPassthrough(_ sequence: String) -> String {
        "\u{1B}Ptmux;" + sequence.replacingOccurrences(of: "\u{1B}", with: "\u{1B}\u{1B}") + "\u{1B}\\"
    }
}

extension Character {
    var isASCIIControl: Bool {
        guard let value = asciiValue else { return false }
        return value < 0x20 || value == 0x7F
    }
}
