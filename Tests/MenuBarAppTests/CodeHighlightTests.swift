import SwiftUI
import Testing
@testable import MenuBarApp

// The tokenizer scans line by line, so what matters is that each token lands in the
// right kind, that markers inside strings and comments do not fool it, and that the
// state carried between lines keeps multi-line constructs whole.
struct CodeHighlightTests {

    private func tokens(_ code: String,
                        _ language: CodeLanguage) -> [(text: String, kind: CodeHighlight.Kind)] {
        var state = CodeHighlight.State.normal
        var out: [(String, CodeHighlight.Kind)] = []
        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            for token in CodeHighlight.tokens(in: line, language: language, state: &state) {
                out.append((String(line[token.range]), token.kind))
            }
        }
        return out
    }

    private func kind(of text: String, in code: String,
                      _ language: CodeLanguage) -> CodeHighlight.Kind? {
        tokens(code, language).first { $0.text == text }?.kind
    }

    // MARK: - Kinds

    @Test func tellsKeywordsTypesAndNumbersApart() {
        let code = "let count: Int = 42"
        #expect(kind(of: "let", in: code, .swift) == .keyword)
        #expect(kind(of: "Int", in: code, .swift) == .type)
        #expect(kind(of: "42", in: code, .swift) == .number)
        #expect(kind(of: "count", in: code, .swift) == nil)
    }

    @Test func stringHoldingACommentMarkerStaysAString() {
        let code = #"let s = "not // a comment""#
        let found = tokens(code, .swift)
        #expect(found.contains { $0.text == #""not // a comment""# && $0.kind == .string })
        #expect(!found.contains { $0.kind == .comment })
    }

    @Test func commentHoldingQuotesStaysAComment() {
        let code = #"// it's all "quoted" here"#
        let found = tokens(code, .swift)
        #expect(found.count == 1)
        #expect(found.first?.kind == .comment)
        #expect(found.first?.text == code)
    }

    @Test func escapedQuotesDoNotEndTheString() {
        let code = #"let s = "say \"hi\"" + tail"#
        let found = tokens(code, .swift)
        #expect(found.contains { $0.text == #""say \"hi\""# + "\"" && $0.kind == .string })
        // The identifier after the string is back outside it.
        #expect(!found.contains { $0.text.contains("tail") && $0.kind == .string })
    }

    @Test func digitsInsideIdentifiersAreNotNumbers() {
        let code = "let utf8 = file9"
        #expect(!tokens(code, .swift).contains { $0.kind == .number })
    }

    @Test func numberShapes() {
        #expect(kind(of: "0xFF", in: "mask = 0xFF", .python) == .number)
        #expect(kind(of: "1_000", in: "let n = 1_000", .swift) == .number)
        #expect(kind(of: "1.5e3", in: "x = 1.5e3", .python) == .number)
    }

    // MARK: - Multi-line state

    @Test func blockCommentSpansLines() {
        let code = "/* first\nstill inside\n*/ let x = 1"
        let found = tokens(code, .swift)
        #expect(found.contains { $0.text == "still inside" && $0.kind == .comment })
        #expect(found.contains { $0.text == "let" && $0.kind == .keyword })
    }

    @Test func nestedBlockCommentsNeedEveryClose() {
        let code = "/* outer /* inner */ still */ let x = 1"
        let found = tokens(code, .swift)
        #expect(found.contains { $0.text == "let" && $0.kind == .keyword })
        #expect(found.first?.kind == .comment)
        #expect(found.first?.text.contains("still") == true)
    }

    @Test func swiftMultilineStringSpansLines() {
        let code = "let s = \"\"\"\nlet not = keyword\n\"\"\"\nreturn s"
        let found = tokens(code, .swift)
        // The middle line is string, not code.
        #expect(found.contains { $0.text == "let not = keyword" && $0.kind == .string })
        #expect(found.contains { $0.text == "return" && $0.kind == .keyword })
    }

    @Test func pythonTripleQuotesSpanLines() {
        let code = "s = '''start\n# not a comment\n''' # real comment"
        let found = tokens(code, .python)
        #expect(found.contains { $0.text == "# not a comment" && $0.kind == .string })
        #expect(found.contains { $0.text == "# real comment" && $0.kind == .comment })
    }

    @Test func goRawStringSpansLinesWithoutEscapes() {
        // In a raw string the backslash is a plain character, so `a\` closes at the tick.
        let closing = tokens(#"s := `a\` + b"#, .go)
        #expect(closing.contains { $0.text == #"`a\`"# && $0.kind == .string })

        let spanning = tokens("s := `first\nsecond` + done", .go)
        #expect(spanning.contains { $0.text == "second`" && $0.kind == .string })
    }

    @Test func javascriptTemplateLiteralSpansLines() {
        let code = "const s = `line one\nline two`; return s"
        let found = tokens(code, .javascript)
        #expect(found.contains { $0.text == "line two`" && $0.kind == .string })
        #expect(found.contains { $0.text == "return" && $0.kind == .keyword })
    }

    @Test func unterminatedPlainStringLetsGoAtLineEnd() {
        let code = "let a = \"unterminated\nlet b = 2"
        let found = tokens(code, .swift)
        #expect(found.contains { $0.text == "b" } == false)
        #expect(found.filter { $0.text == "let" && $0.kind == .keyword }.count == 2)
        #expect(found.contains { $0.text == "2" && $0.kind == .number })
    }

    @Test func lineStartStatesFollowOpenConstructs() {
        let states = CodeHighlight.lineStartStates(["/* open", "inside", "*/ done"],
                                                   language: .swift)
        #expect(states == [.normal, .blockComment(depth: 1), .blockComment(depth: 1)])
    }

    // MARK: - Per-language quirks

    @Test func hashCommentsNeedAWordBoundary() {
        let found = tokens("echo a#b # trailing", .shell)
        #expect(found.contains { $0.text == "# trailing" && $0.kind == .comment })
        #expect(!found.contains { $0.text.contains("a#b") && $0.kind == .comment })
    }

    @Test func shellKeywordsAndStrings() {
        let code = "if [ -f x ]; then echo 'done'; fi"
        #expect(kind(of: "if", in: code, .shell) == .keyword)
        #expect(kind(of: "fi", in: code, .shell) == .keyword)
        #expect(kind(of: "'done'", in: code, .shell) == .string)
    }

    @Test func yamlLiteralsIgnoreCase() {
        let code = "enabled: True\ncount: 3 # note"
        #expect(kind(of: "True", in: code, .yaml) == .keyword)
        #expect(kind(of: "3", in: code, .yaml) == .number)
        #expect(kind(of: "# note", in: code, .yaml) == .comment)
    }

    @Test func sqlKeywordsIgnoreCase() {
        let code = "SELECT id FROM users where name = 'ann' -- lookup"
        #expect(kind(of: "SELECT", in: code, .sql) == .keyword)
        #expect(kind(of: "where", in: code, .sql) == .keyword)
        #expect(kind(of: "'ann'", in: code, .sql) == .string)
        #expect(kind(of: "-- lookup", in: code, .sql) == .comment)
    }

    @Test func jsonColoursLiteralsAndStrings() {
        let code = #"{"name": "ada", "ok": true, "n": 12}"#
        #expect(kind(of: #""name""#, in: code, .json) == .string)
        #expect(kind(of: "true", in: code, .json) == .keyword)
        #expect(kind(of: "12", in: code, .json) == .number)
    }

    @Test func rustLifetimesAreNotStrings() {
        let code = "fn get<'a>(x: &'a str) -> &'a str { x }"
        let found = tokens(code, .rust)
        #expect(!found.contains { $0.kind == .string })
        #expect(found.contains { $0.text == "fn" && $0.kind == .keyword })
    }

    // MARK: - Markup

    @Test func markupColoursTagsAndAttributeStrings() {
        let code = #"<div class="wide">it's 5 < 6 in here</div>"#
        let found = tokens(code, .markup)
        #expect(found.contains { $0.text == "div" && $0.kind == .keyword })
        #expect(found.contains { $0.text == #""wide""# && $0.kind == .string })
        // Prose between tags stays prose: no string from the apostrophe, no number.
        #expect(!found.contains { $0.text.contains("s 5 < 6") })
        #expect(!found.contains { $0.text == "5" })
    }

    @Test func markupCommentSpansLines() {
        let code = "<!-- first\nsecond -->\n<p>done</p>"
        let found = tokens(code, .markup)
        #expect(found.contains { $0.text == "second -->" && $0.kind == .comment })
        #expect(found.contains { $0.text == "p" && $0.kind == .keyword })
    }

    // MARK: - Language resolution

    @Test func unknownFenceTagsFallBackToCLike() {
        #expect(CodeLanguage(tag: "mystery") == .cLike)
        #expect(CodeLanguage(tag: "swift") == .swift)
        #expect(CodeLanguage(tag: nil) == nil)
        #expect(CodeLanguage(tag: "") == nil)
        let code = #"return "text" // done"#
        #expect(kind(of: "return", in: code, .cLike) == .keyword)
        #expect(kind(of: #""text""#, in: code, .cLike) == .string)
        #expect(kind(of: "// done", in: code, .cLike) == .comment)
    }

    @Test func unknownFileExtensionsStayPlain() {
        #expect(CodeLanguage(fileExtension: "txt") == nil)
        #expect(CodeLanguage(fileExtension: "md") == nil)
        #expect(CodeLanguage(fileExtension: "swift") == .swift)
        #expect(CodeLanguage(fileExtension: "kts") == .kotlin)
        #expect(CodeLanguage(fileExtension: "YML") == .yaml)
    }

    // MARK: - Rendering

    @Test func untaggedCodeStaysOneRun() {
        let highlighted = CodeHighlight.highlight("let x = 1", tag: nil)
        #expect(highlighted.runs.count == 1)
    }

    // Whatever the colouring does, it must never change the text itself.
    @Test func neverAltersTheText() {
        let samples: [(String, CodeLanguage)] = [
            ("let s = \"broken\nfunc x() { /* open", .swift),
            ("'''\nhalf a docstring", .python),
            ("<div class=\"open", .markup),
            ("select ' from -- \"", .sql),
            ("emoji 🎉 in \"a 🎉 string\" // and 🎉 comments", .swift)
        ]
        for (code, language) in samples {
            let highlighted = CodeHighlight.highlight(code, language: language)
            #expect(String(highlighted.characters) == code)
        }
    }

    @Test func hugeInputSkipsColouring() {
        let code = String(repeating: "let x = 1\n", count: 12_000)
        #expect(code.utf8.count > CodeHighlight.sizeLimit)
        #expect(CodeHighlight.highlight(code, language: .swift).runs.count == 1)
    }
}
