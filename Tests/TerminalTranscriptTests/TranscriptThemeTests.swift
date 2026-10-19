import CodeStationCore
import Foundation
import Testing
import TerminalTranscript

// The same lines at every colour depth: exact colours, the nearest of 256, the basic 16,
// or none. Weights (bold, dim, italic, underline) are the same at each, so the
// transcript keeps its shape when the colour goes.
struct TranscriptThemeTests {

    @Test(arguments: [
        (["TERM": "xterm-256color", "COLORTERM": "truecolor"], TranscriptTheme.ColourDepth.truecolour),
        (["TERM": "xterm-256color", "COLORTERM": "24bit"], .truecolour),
        (["TERM": "xterm-direct"], .truecolour),
        (["TERM": "xterm-256color"], .ansi256),
        (["TERM": "tmux-256color"], .ansi256),
        (["TERM": "xterm"], .ansi16),
        (["TERM": "vt100"], .ansi16),
        (["TERM": "dumb", "COLORTERM": "truecolor"], .none),
        (["TERM": "xterm-256color", "COLORTERM": "truecolor", "NO_COLOR": "1"], .none),
        // An empty NO_COLOR asks for nothing (no-color.org).
        (["TERM": "xterm-256color", "NO_COLOR": ""], .ansi256),
        ([:], .none),
    ])
    func theDepthComesFromTheEnvironment(environment: [String: String], depth: TranscriptTheme.ColourDepth) {
        #expect(TranscriptTheme(environment: environment).depth == depth)
    }

    @Test func highlightedCodeAtEachDepth() {
        let line = TranscriptRenderer.lines(for: answer("```swift\nlet x = 1 // c\n```"), width: 30)[0]

        #expect(encode(line, .none) == "  let x = 1 \u{1B}[2m// c\u{1B}[0m")
        #expect(encode(line, .ansi16)
                == "  \u{1B}[35mlet\u{1B}[0m x = \u{1B}[32m1\u{1B}[0m \u{1B}[2m// c\u{1B}[0m")
        #expect(encode(line, .ansi256)
                == "  \u{1B}[38;5;139mlet\u{1B}[0m x = \u{1B}[38;5;108m1\u{1B}[0m \u{1B}[2;38;5;102m// c\u{1B}[0m")
        #expect(encode(line, .truecolour)
                == "  \u{1B}[38;2;164;123;192mlet\u{1B}[0m x = \u{1B}[38;2;127;176;138m1\u{1B}[0m "
                + "\u{1B}[2;38;2;140;145;133m// c\u{1B}[0m")
    }

    @Test func markdownAtEachDepth() {
        let lines = TranscriptRenderer.lines(for: answer("# Title\n\nSee `x`"), width: 30)

        #expect(lines.map { encode($0, .none) } == ["\u{1B}[1;4mTitle\u{1B}[0m", "", "See x"])
        #expect(lines.map { encode($0, .ansi16) }
                == ["\u{1B}[1;4;36mTitle\u{1B}[0m", "", "See \u{1B}[33mx\u{1B}[0m"])
        #expect(lines.map { encode($0, .ansi256) }
                == ["\u{1B}[1;4;38;5;74mTitle\u{1B}[0m", "", "See \u{1B}[38;5;179mx\u{1B}[0m"])
        #expect(lines.map { encode($0, .truecolour) }
                == ["\u{1B}[1;4;38;2;106;170;214mTitle\u{1B}[0m", "", "See \u{1B}[38;2;224;176;74mx\u{1B}[0m"])
    }

    @Test func aToolLineAtEachDepth() {
        let line = TranscriptRenderer.lines(for: answer(blocks: [.init(kind: "tools", tools: [
            RemoteTool(id: "1", name: "Edit", argument: "a", added: 2, removed: 1, result: "ok"),
        ])]), width: 30)[0]

        #expect(encode(line, .none) == "● Edit · a +2 -1")
        #expect(encode(line, .ansi256)
                == "\u{1B}[38;5;73m● \u{1B}[0m\u{1B}[38;5;73mEdit · a\u{1B}[0m\u{1B}[38;5;108m +2\u{1B}[0m"
                + "\u{1B}[38;5;167m -1\u{1B}[0m")
    }

    // Each depth uses only the codes it may: none has no colour at all, 16 only the basic
    // colours, 256 only palette indices, truecolour only 24-bit colours. The weights a
    // style carries are the same at every depth.
    @Test func eachDepthUsesOnlyItsOwnCodesAndKeepsTheWeights() {
        let styles: [LineStyle] = [
            .plain, .userMarker, .user, .thinking, .tool, .toolRunning, .toolError, .added, .removed, .notice,
            .heading(1), .heading(2), .heading(3), .strong, .emphasis, .strongEmphasis, .strikethrough,
            .code, .link, .linkTarget, .listMarker, .quote, .rule, .output, .outputError,
        ] + CodeHighlight.Kind.allCases.map { .syntax($0) }
        let weights = Set([1, 2, 3, 4, 9])

        for style in styles {
            func parameters(_ depth: TranscriptTheme.ColourDepth) -> [Int] {
                (TranscriptTheme(depth: depth).sgr(for: style) ?? "").split(separator: ";").compactMap { Int($0) }
            }
            let none = parameters(.none)
            #expect(none.allSatisfy(weights.contains), "\(style)")
            let basic = parameters(.ansi16)
            #expect(basic.filter { !weights.contains($0) }.allSatisfy { (30...37).contains($0) || (90...97).contains($0) },
                    "\(style)")
            #expect(basic.filter(weights.contains) == none, "\(style)")
            for (depth, mode) in [(TranscriptTheme.ColourDepth.ansi256, 5), (.truecolour, 2)] {
                let sgr = TranscriptTheme(depth: depth).sgr(for: style) ?? ""
                let colour = sgr.range(of: "38;")
                let prefix = colour.map { String(sgr[..<$0.lowerBound]) } ?? sgr
                #expect(prefix.split(separator: ";").compactMap { Int($0) } == none, "\(style) \(depth)")
                if let colour {
                    #expect(sgr[colour.upperBound...].hasPrefix("\(mode);"), "\(style) \(depth)")
                }
            }
        }
    }

    private func encode(_ line: StyledLine, _ depth: TranscriptTheme.ColourDepth) -> String {
        TranscriptTheme(depth: depth).encode(line)
    }
}
