import Testing
import CodeStationCore

// The tokenizer as another front end sees it: only the core's public surface, no
// colours. Each supported language gets one sample and the exact tokens it yields.
struct CodeTokenizerTests {

    struct Piece: Equatable, CustomStringConvertible {
        let text: String
        let kind: CodeHighlight.Kind
        init(_ text: String, _ kind: CodeHighlight.Kind) {
            self.text = text
            self.kind = kind
        }
        var description: String { "\(kind):\(text)" }
    }

    private func pieces(_ code: String, _ language: CodeLanguage) -> [Piece] {
        CodeHighlight.lines(of: code, language: language).flatMap { line in
            line.tokens.map { Piece(String(code[$0.range]), $0.kind) }
        }
    }

    @Test func swiftTokens() {
        #expect(pieces("let n: Int = 0x1F // hex", .swift) == [
            Piece("let", .keyword), Piece("Int", .type), Piece("0x1F", .number),
            Piece("// hex", .comment)
        ])
    }

    @Test func jsonTokens() {
        #expect(pieces(#"{"ok": true, "n": -1.5, "x": null}"#, .json) == [
            Piece(#""ok""#, .string), Piece("true", .keyword), Piece(#""n""#, .string),
            Piece("1.5", .number), Piece(#""x""#, .string), Piece("null", .keyword)
        ])
    }

    @Test func yamlTokens() {
        #expect(pieces("debug: Yes # note\nname: 'ada'", .yaml) == [
            Piece("Yes", .keyword), Piece("# note", .comment), Piece("'ada'", .string)
        ])
    }

    @Test func shellTokens() {
        #expect(pieces(#"export N=3 # three"#, .shell) == [
            Piece("export", .keyword), Piece("3", .number), Piece("# three", .comment)
        ])
    }

    @Test func pythonTokens() {
        #expect(pieces(#"def f(x=None): return "ok""#, .python) == [
            Piece("def", .keyword), Piece("None", .keyword), Piece("return", .keyword),
            Piece(#""ok""#, .string)
        ])
    }

    @Test func javascriptTokens() {
        #expect(pieces("const s = `hi`; // tick", .javascript) == [
            Piece("const", .keyword), Piece("`hi`", .string), Piece("// tick", .comment)
        ])
    }

    @Test func javaTokens() {
        #expect(pieces("public static int MAX = 10;", .java) == [
            Piece("public", .keyword), Piece("static", .keyword), Piece("int", .keyword),
            Piece("MAX", .type), Piece("10", .number)
        ])
    }

    @Test func kotlinTokens() {
        #expect(pieces(#"val name: String = "x" /* note */"#, .kotlin) == [
            Piece("val", .keyword), Piece("String", .type), Piece(#""x""#, .string),
            Piece("/* note */", .comment)
        ])
    }

    @Test func goTokens() {
        #expect(pieces(#"func main() { fmt.Println("hi") }"#, .go) == [
            Piece("func", .keyword), Piece("Println", .type), Piece(#""hi""#, .string)
        ])
    }

    @Test func rustTokens() {
        #expect(pieces("pub fn new() -> Self { 0 }", .rust) == [
            Piece("pub", .keyword), Piece("fn", .keyword), Piece("Self", .type),
            Piece("0", .number)
        ])
    }

    @Test func sqlTokens() {
        #expect(pieces("Select * FROM t where id = 1", .sql) == [
            Piece("Select", .keyword), Piece("FROM", .keyword), Piece("where", .keyword),
            Piece("1", .number)
        ])
    }

    @Test func markupTokens() {
        #expect(pieces(#"<a href="x">5</a>"#, .markup) == [
            Piece("a", .keyword), Piece(#""x""#, .string), Piece("a", .keyword)
        ])
    }

    @Test func cLikeTokens() {
        #expect(pieces("int c = 'c'; // done", .cLike) == [
            Piece("int", .keyword), Piece("'c'", .string), Piece("// done", .comment)
        ])
    }

    // MARK: - Whole texts

    @Test func linesCarryStateAndIndexTheWholeText() {
        let code = "/* a\nb */ let x\n"
        let lines = CodeHighlight.lines(of: code, language: .swift)
        #expect(lines.map(\.text) == ["/* a", "b */ let x", ""])
        #expect(lines.map(\.text).joined(separator: "\n") == code)
        #expect(pieces(code, .swift) == [
            Piece("/* a", .comment), Piece("b */", .comment), Piece("let", .keyword)
        ])
    }

    @Test func lineStartStatesLetACallerResumeMidText() {
        let lines = ["let s = \"\"\"", "inside", "\"\"\""]
        let states = CodeHighlight.lineStartStates(lines, language: .swift)
        var state = states[1]
        let tokens = CodeHighlight.tokens(in: lines[1][...], language: .swift, state: &state)
        #expect(tokens == [CodeHighlight.Token(range: lines[1].startIndex..<lines[1].endIndex,
                                               kind: .string)])
        #expect(state == states[2])
    }
}
