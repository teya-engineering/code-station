import AppKit
import SwiftUI
import CodeStationCore

// The token colours, kept adaptive so they read on both the light and dark canvas. The
// hues are borrowed from colours already in the app - the response pane's amber and
// green, the project wheel's plum and teal - so highlighted code sits in the same family
// as everything around it.
enum CodeStyle {
    static let comment = Theme.adaptiveNSColor(
        light: NSColor(srgbRed: 0.44, green: 0.46, blue: 0.42, alpha: 1),
        dark: NSColor(srgbRed: 0.55, green: 0.57, blue: 0.52, alpha: 1))
    static let string = Theme.adaptiveNSColor(
        light: NSColor(srgbRed: 0.541, green: 0.365, blue: 0.063, alpha: 1),
        dark: NSColor(srgbRed: 0.878, green: 0.690, blue: 0.290, alpha: 1))
    static let number = Theme.adaptiveNSColor(
        light: NSColor(srgbRed: 0.184, green: 0.420, blue: 0.227, alpha: 1),
        dark: NSColor(srgbRed: 0.498, green: 0.690, blue: 0.541, alpha: 1))
    static let keyword = Theme.adaptiveNSColor(
        light: NSColor(srgbRed: 0.420, green: 0.267, blue: 0.533, alpha: 1),
        dark: NSColor(srgbRed: 0.643, green: 0.482, blue: 0.753, alpha: 1))
    static let type = Theme.adaptiveNSColor(
        light: NSColor(srgbRed: 0.118, green: 0.431, blue: 0.431, alpha: 1),
        dark: NSColor(srgbRed: 0.247, green: 0.647, blue: 0.647, alpha: 1))

    static func nsColor(for kind: CodeHighlight.Kind) -> NSColor {
        switch kind {
        case .comment: comment
        case .string: string
        case .number: number
        case .keyword: keyword
        case .type: type
        }
    }

    static func color(for kind: CodeHighlight.Kind) -> Color {
        Color(nsColor: nsColor(for: kind))
    }
}

// The GUI's colouring step. The core's tokenizer finds the tokens; this paints each one
// with the colour its kind maps to and leaves the text between them plain.
extension CodeHighlight {

    static func highlight(_ code: String, tag: String?) -> AttributedString {
        guard let language = CodeLanguage(tag: tag) else { return AttributedString(code) }
        return highlight(code, language: language)
    }

    static func highlight(_ code: String, language: CodeLanguage) -> AttributedString {
        guard code.utf8.count <= sizeLimit else { return AttributedString(code) }
        var result = AttributedString()
        var first = true
        for line in lines(of: code, language: language) {
            if !first { result += AttributedString("\n") }
            first = false
            result += coloured(line)
        }
        return result
    }

    private static func coloured(_ line: TokenizedLine) -> AttributedString {
        let text = line.text
        guard !line.tokens.isEmpty else { return AttributedString(String(text)) }
        var result = AttributedString()
        var i = text.startIndex
        for token in line.tokens {
            if i < token.range.lowerBound {
                result += AttributedString(String(text[i..<token.range.lowerBound]))
            }
            var run = AttributedString(String(text[token.range]))
            run.foregroundColor = CodeStyle.color(for: token.kind)
            result += run
            i = token.range.upperBound
        }
        if i < text.endIndex {
            result += AttributedString(String(text[i...]))
        }
        return result
    }
}
