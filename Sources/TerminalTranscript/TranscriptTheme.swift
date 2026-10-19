import CodeStationCore

// How each kind of text looks in a terminal. The renderer says what text is; the theme
// turns that into SGR codes for the colour depth the terminal has. Every depth draws the
// same weights (bold, dim, italic, underline); only the colours change, from one palette
// of exact colours down to the nearest of 256, the basic 16, or none.
public struct TranscriptTheme: Equatable, Sendable {
    public enum ColourDepth: Equatable, Sendable {
        // No colour at all (NO_COLOR, or a dumb terminal). Bold and dim still work.
        case none
        // The basic 16 colours every terminal has.
        case ansi16
        // The xterm 256-colour palette, and 24-bit colour.
        case ansi256, truecolour

        // What the terminal says it can draw. NO_COLOR (no-color.org) and a dumb or
        // missing TERM get no colour; COLORTERM=truecolor or 24bit, or a "-direct" TERM,
        // gets 24-bit colour; a "256color" TERM gets 256; any other terminal gets 16.
        public init(environment: [String: String]) {
            let term = environment["TERM"]?.lowercased() ?? ""
            let colourTerm = environment["COLORTERM"]?.lowercased() ?? ""
            if environment["NO_COLOR"].map({ !$0.isEmpty }) == true || term.isEmpty || term == "dumb" {
                self = .none
            } else if colourTerm == "truecolor" || colourTerm == "24bit" || term.hasSuffix("-direct")
                        || term.contains("truecolor") || term.contains("24bit") {
                self = .truecolour
            } else if term.contains("256color") {
                self = .ansi256
            } else {
                self = .ansi16
            }
        }
    }

    public var depth: ColourDepth

    public init(depth: ColourDepth) {
        self.depth = depth
    }

    public init(environment: [String: String]) {
        self.init(depth: ColourDepth(environment: environment))
    }

    public static let monochrome = TranscriptTheme(depth: .none)
    public static let basic = TranscriptTheme(depth: .ansi16)

    // A colour at every depth: the exact one, and the basic colour that stands for it.
    // The 256-colour form is worked out from the exact one.
    struct Colour: Equatable {
        var red: Int, green: Int, blue: Int
        var basic: Int

        // The hues of the GUI's dark canvas, so a transcript reads the same in both.
        static let accent = Colour(red: 106, green: 170, blue: 214, basic: 36)
        static let teal = Colour(red: 63, green: 165, blue: 165, basic: 36)
        static let amber = Colour(red: 224, green: 176, blue: 74, basic: 33)
        static let red = Colour(red: 224, green: 108, blue: 100, basic: 31)
        static let green = Colour(red: 127, green: 176, blue: 138, basic: 32)
        static let plum = Colour(red: 164, green: 123, blue: 192, basic: 35)
        static let grey = Colour(red: 140, green: 145, blue: 133, basic: 90)

        // The nearest colour of the xterm 6×6×6 cube.
        var cube: Int {
            func level(_ value: Int) -> Int {
                value < 48 ? 0 : value < 115 ? 1 : (value - 35) / 40
            }
            return 16 + 36 * level(red) + 6 * level(green) + level(blue)
        }
    }

    // How a style looks: its weights, and its colour when the terminal has colour.
    private func look(_ style: LineStyle) -> (weights: [Int], colour: Colour?) {
        switch style {
        case .plain: return ([], nil)
        case .userMarker: return ([1], .accent)
        case .user: return ([1], nil)
        case .thinking: return ([2, 3], nil)
        case .tool: return ([], .teal)
        case .toolRunning: return ([], .amber)
        case .toolError: return ([1], .red)
        case .added: return ([], .green)
        case .removed: return ([], .red)
        case .notice: return ([2], nil)
        case .heading(let level): return (level == 1 ? [1, 4] : [1], level <= 2 ? .accent : nil)
        case .strong: return ([1], nil)
        case .emphasis: return ([3], nil)
        case .strongEmphasis: return ([1, 3], nil)
        case .strikethrough: return ([9], nil)
        case .code: return ([], .amber)
        case .link: return ([4], .accent)
        case .linkTarget: return ([2], nil)
        case .listMarker: return ([], .accent)
        case .quote, .rule, .output: return ([2], nil)
        case .outputError: return ([], .red)
        case .attention: return ([1], .amber)
        case .state(let tone):
            switch tone {
            case .running, .waiting: return ([1], .green)
            case .needsYou: return ([1], .amber)
            case .failed: return ([1], .red)
            case .idle: return ([2], nil)
            }
        case .syntax(let kind):
            switch kind {
            // A comment is dimmed rather than coloured, so it recedes at every depth.
            case .comment: return ([2], depth == .none || depth == .ansi16 ? nil : .grey)
            case .string: return ([], .amber)
            case .number: return ([], .green)
            case .keyword: return ([], .plum)
            case .type: return ([], .teal)
            }
        }
    }

    // The SGR parameters for a style, or nil when it is drawn as it is.
    public func sgr(for style: LineStyle) -> String? {
        let (weights, colour) = look(style)
        var parts = weights.map(String.init)
        if let colour {
            switch depth {
            case .none: break
            case .ansi16: parts.append(String(colour.basic))
            case .ansi256: parts.append("38;5;\(colour.cube)")
            case .truecolour: parts.append("38;2;\(colour.red);\(colour.green);\(colour.blue)")
            }
        }
        // With no colour, a failed call is still told apart by its weight.
        return parts.isEmpty ? nil : parts.joined(separator: ";")
    }

    // The line as the terminal should receive it. Each styled run resets after itself,
    // so a line never leaks its style into the next. Only the theme's own codes reach the
    // terminal: any in the text are taken out (see TerminalText).
    public func encode(_ line: StyledLine) -> String {
        line.spans.map { span in
            let text = TerminalText.sanitized(span.text)
            guard let sgr = sgr(for: span.style), !text.isEmpty else { return text }
            return "\u{1B}[\(sgr)m\(text)\u{1B}[0m"
        }.joined()
    }
}
