// A line-friendly tokenizer, not a grammar. Each line is scanned on its own, and the only
// thing carried from one line to the next is whether it ended inside a block comment, a
// multi-line string, or a markup tag. That keeps the work linear and lets a caller start
// anywhere in a file, as long as it knows the state that line starts in.
//
// It only says what each token is. Colouring belongs to each front end, which maps a
// token's kind to its own palette: the GUI to adaptive colours, the terminal to ANSI.
public enum CodeHighlight {

    public enum Kind: Sendable, Equatable, CaseIterable {
        case comment, string, number, keyword, type
    }

    // What a line can leave open for the next one. A plain quote never spans lines: an
    // unterminated string colours its own line and lets go, so one stray quote cannot
    // poison the rest of a file.
    public enum State: Sendable, Equatable {
        case normal
        case blockComment(depth: Int)
        case string(quote: Character, triple: Bool)
        case tag
    }

    // A run of a line worth colouring. The range indexes the string the line was cut
    // from, so it works on the line and on the whole text alike. Text between tokens is
    // plain.
    public struct Token: Sendable, Equatable {
        public let range: Range<String.Index>
        public let kind: Kind

        public init(range: Range<String.Index>, kind: Kind) {
            self.range = range
            self.kind = kind
        }
    }

    // One line of a text and its tokens, in order and never overlapping.
    public struct TokenizedLine: Sendable, Equatable {
        public let text: Substring
        public let tokens: [Token]
    }

    // Colouring is for code a person reads; past this size plain text is also much
    // cheaper to lay out. The tokenizer does not enforce it; callers that colour do.
    public static let sizeLimit = 100_000

    // A whole text, split on newlines, each line tokenized in the state the one before
    // it left. The lines join back into the text with "\n".
    public static func lines(of code: String, language: CodeLanguage) -> [TokenizedLine] {
        var state = State.normal
        return code.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            TokenizedLine(text: line, tokens: tokens(in: line, language: language, state: &state))
        }
    }

    // The state each line starts in, for callers that draw a file in chunks and need to
    // pick up colouring mid-document without scanning from the top every time.
    public static func lineStartStates(_ lines: [String], language: CodeLanguage) -> [State] {
        var states: [State] = []
        states.reserveCapacity(lines.count)
        var state = State.normal
        for line in lines {
            states.append(state)
            _ = tokens(in: line[...], language: language, state: &state)
        }
        return states
    }

    // MARK: - Tokenizing

    // One line, starting in `state` and leaving in it what the line left open. The line
    // must not contain a newline.
    public static func tokens(in line: Substring, language: CodeLanguage,
                       state: inout State) -> [Token] {
        if language == .markup { return markupTokens(in: line, state: &state) }
        let rules = rules(for: language)
        var tokens: [Token] = []
        var i = line.startIndex

        // Finish whatever the previous line left open before reading fresh code.
        switch state {
        case .blockComment(let depth):
            let start = i
            scanBlockComment(line, from: &i, depth: depth, rules: rules, state: &state)
            if start < i { tokens.append(Token(range: start..<i, kind: .comment)) }
        case .string(let quote, let triple):
            let start = i
            scanString(line, from: &i, quote: quote, triple: triple, rules: rules, state: &state)
            if start < i { tokens.append(Token(range: start..<i, kind: .string)) }
        case .tag, .normal:
            state = .normal
        }

        while i < line.endIndex {
            let c = line[i]

            if rules.lineComments.contains(where: { matches(line, at: i, $0) }),
               c != "#" || hashCommentStarts(line, at: i) {
                tokens.append(Token(range: i..<line.endIndex, kind: .comment))
                i = line.endIndex
                break
            }

            if let (open, _) = rules.blockComment, matches(line, at: i, open) {
                let start = i
                i = line.index(i, offsetBy: open.count)
                scanBlockComment(line, from: &i, depth: 1, rules: rules, state: &state)
                tokens.append(Token(range: start..<i, kind: .comment))
                continue
            }

            if rules.quotes.contains(c) {
                let start = i
                var triple = false
                if rules.tripleQuotes, matches(line, at: i, String(repeating: c, count: 3)) {
                    triple = true
                    i = line.index(i, offsetBy: 3)
                } else {
                    i = line.index(after: i)
                }
                scanString(line, from: &i, quote: c, triple: triple, rules: rules, state: &state)
                tokens.append(Token(range: start..<i, kind: .string))
                continue
            }

            // A digit here is a literal: identifiers below swallow their own digits, so
            // the 9 in file9 never reaches this branch.
            if c.isNumber {
                let start = i
                scanNumber(line, from: &i)
                tokens.append(Token(range: start..<i, kind: .number))
                continue
            }

            if c.isLetter || c == "_" {
                let start = i
                var j = line.index(after: i)
                while j < line.endIndex,
                      line[j].isLetter || line[j].isNumber || line[j] == "_" {
                    j = line.index(after: j)
                }
                let word = line[start..<j]
                let key = rules.caseInsensitiveKeywords ? word.lowercased() : String(word)
                if rules.keywords.contains(key) {
                    tokens.append(Token(range: start..<j, kind: .keyword))
                } else if rules.typesByCase, c.isUppercase {
                    tokens.append(Token(range: start..<j, kind: .type))
                }
                i = j
                continue
            }

            i = line.index(after: i)
        }
        return tokens
    }

    // MARK: - Scanners

    private static func matches(_ line: Substring, at start: String.Index, _ token: String) -> Bool {
        var i = start
        for ch in token {
            guard i < line.endIndex, line[i] == ch else { return false }
            i = line.index(after: i)
        }
        return true
    }

    // A # opens a comment only on a word boundary, so a colour code or ${#name} in shell
    // and yaml keeps its own reading.
    private static func hashCommentStarts(_ line: Substring, at i: String.Index) -> Bool {
        i == line.startIndex || line[line.index(before: i)].isWhitespace
    }

    private static func scanBlockComment(_ line: Substring, from i: inout String.Index,
                                         depth: Int, rules: Rules, state: inout State) {
        guard let (open, close) = rules.blockComment else {
            i = line.endIndex
            state = .normal
            return
        }
        var depth = depth
        while i < line.endIndex {
            if rules.nestsBlockComments, matches(line, at: i, open) {
                depth += 1
                i = line.index(i, offsetBy: open.count)
            } else if matches(line, at: i, close) {
                depth -= 1
                i = line.index(i, offsetBy: close.count)
                if depth == 0 {
                    state = .normal
                    return
                }
            } else {
                i = line.index(after: i)
            }
        }
        state = .blockComment(depth: depth)
    }

    // Called with i just past the opening quote or quotes.
    private static func scanString(_ line: Substring, from i: inout String.Index,
                                   quote: Character, triple: Bool,
                                   rules: Rules, state: inout State) {
        let escapes = !rules.rawQuotes.contains(quote)
        let terminator = String(repeating: quote, count: triple ? 3 : 1)
        while i < line.endIndex {
            if escapes, line[i] == "\\" {
                i = line.index(after: i)
                if i < line.endIndex { i = line.index(after: i) }
            } else if matches(line, at: i, terminator) {
                i = line.index(i, offsetBy: terminator.count)
                state = .normal
                return
            } else {
                i = line.index(after: i)
            }
        }
        state = triple || rules.multilineQuotes.contains(quote)
            ? .string(quote: quote, triple: triple)
            : .normal
    }

    private static func scanNumber(_ line: Substring, from i: inout String.Index) {
        let start = i
        i = line.index(after: i)
        // A based literal carries its letters: 0xFF or 0b1010 is one number.
        if line[start] == "0", i < line.endIndex, "xXbBoO".contains(line[i]) {
            i = line.index(after: i)
            while i < line.endIndex, line[i].isHexDigit || line[i] == "_" {
                i = line.index(after: i)
            }
            return
        }
        var seenDot = false
        while i < line.endIndex {
            let c = line[i]
            if c.isNumber || c == "_" {
                i = line.index(after: i)
            } else if c == ".", !seenDot {
                let next = line.index(after: i)
                guard next < line.endIndex, line[next].isNumber else { break }
                seenDot = true
                i = line.index(after: next)
            } else if c == "e" || c == "E" {
                var j = line.index(after: i)
                if j < line.endIndex, line[j] == "+" || line[j] == "-" { j = line.index(after: j) }
                guard j < line.endIndex, line[j].isNumber else { break }
                i = j
            } else {
                break
            }
        }
    }

    // Markup is its own little machine: strings and numbers only mean anything inside a
    // tag, so prose with an apostrophe in it stays prose.
    private static func markupTokens(in line: Substring, state: inout State) -> [Token] {
        var tokens: [Token] = []
        var i = line.startIndex

        // Runs to the close of an open comment and files it from `start`, so the `<!--`
        // that opened it on this line lands in the same token.
        func scanCommentClose(from start: Substring.Index) {
            while i < line.endIndex, !matches(line, at: i, "-->") { i = line.index(after: i) }
            if i < line.endIndex {
                i = line.index(i, offsetBy: 3)
                state = .normal
            } else {
                state = .blockComment(depth: 1)
            }
            if start < i { tokens.append(Token(range: start..<i, kind: .comment)) }
        }

        switch state {
        case .blockComment:
            scanCommentClose(from: i)
        case .string(let quote, _):
            let start = i
            while i < line.endIndex, line[i] != quote { i = line.index(after: i) }
            if i < line.endIndex {
                i = line.index(after: i)
                state = .tag
            }
            if start < i { tokens.append(Token(range: start..<i, kind: .string)) }
        case .tag, .normal:
            break
        }

        while i < line.endIndex {
            let c = line[i]
            if state == .tag {
                if c == "\"" || c == "'" {
                    let start = i
                    i = line.index(after: i)
                    while i < line.endIndex, line[i] != c { i = line.index(after: i) }
                    if i < line.endIndex {
                        i = line.index(after: i)
                    } else {
                        state = .string(quote: c, triple: false)
                    }
                    tokens.append(Token(range: start..<i, kind: .string))
                } else if c == ">" {
                    state = .normal
                    i = line.index(after: i)
                } else if c.isNumber {
                    let start = i
                    scanNumber(line, from: &i)
                    tokens.append(Token(range: start..<i, kind: .number))
                } else {
                    i = line.index(after: i)
                }
                continue
            }

            if matches(line, at: i, "<!--") {
                let start = i
                i = line.index(i, offsetBy: 4)
                scanCommentClose(from: start)
                continue
            }

            // Only a < that actually opens a tag counts, so "a < b" in text stays text.
            if c == "<" {
                var j = line.index(after: i)
                if j < line.endIndex, line[j] == "/" || line[j] == "!" || line[j] == "?" {
                    j = line.index(after: j)
                }
                let nameStart = j
                while j < line.endIndex,
                      line[j].isLetter || line[j].isNumber
                        || line[j] == "-" || line[j] == ":" || line[j] == "_" {
                    j = line.index(after: j)
                }
                if nameStart < j {
                    tokens.append(Token(range: nameStart..<j, kind: .keyword))
                    state = .tag
                    i = j
                    continue
                }
            }

            i = line.index(after: i)
        }
        return tokens
    }

    // MARK: - Rules

    private struct Rules: Sendable {
        var lineComments: [String] = []
        var blockComment: (open: String, close: String)?
        var nestsBlockComments = false
        var quotes: [Character] = ["\""]
        var tripleQuotes = false
        // Quotes whose strings run across lines even without tripling: raw strings in Go,
        // template literals in JavaScript.
        var multilineQuotes: [Character] = []
        // Quotes with no escape character, so a backslash inside is just a backslash.
        var rawQuotes: [Character] = []
        var keywords: Set<String> = []
        var caseInsensitiveKeywords = false
        var typesByCase = false
    }

    private static func rules(for language: CodeLanguage) -> Rules {
        switch language {
        case .swift: swiftRules
        case .json: jsonRules
        case .yaml: yamlRules
        case .shell: shellRules
        case .python: pythonRules
        case .javascript: javascriptRules
        case .java: javaRules
        case .kotlin: kotlinRules
        case .go: goRules
        case .rust: rustRules
        case .sql: sqlRules
        case .markup, .cLike: cLikeRules
        }
    }

    private static let swiftRules = Rules(
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        nestsBlockComments: true,
        quotes: ["\""],
        tripleQuotes: true,
        keywords: [
            "actor", "any", "as", "associatedtype", "async", "await", "break", "case",
            "catch", "class", "continue", "convenience", "default", "defer", "deinit",
            "didSet", "do", "dynamic", "else", "enum", "extension", "fallthrough", "false",
            "fileprivate", "final", "for", "func", "guard", "if", "import", "in",
            "indirect", "infix", "init", "inout", "internal", "is", "lazy", "let",
            "mutating", "nil", "nonisolated", "open", "operator", "override", "postfix",
            "prefix", "private", "protocol", "public", "repeat", "required", "rethrows",
            "return", "self", "some", "static", "struct", "subscript", "super", "switch",
            "throw", "throws", "true", "try", "typealias", "unowned", "var", "weak",
            "where", "while", "willSet"
        ],
        typesByCase: true)

    private static let jsonRules = Rules(
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        quotes: ["\""],
        keywords: ["true", "false", "null"])

    private static let yamlRules = Rules(
        lineComments: ["#"],
        quotes: ["\"", "'"],
        keywords: ["true", "false", "null", "yes", "no", "on", "off"],
        caseInsensitiveKeywords: true)

    private static let shellRules = Rules(
        lineComments: ["#"],
        quotes: ["\"", "'"],
        keywords: [
            "alias", "break", "case", "cd", "continue", "do", "done", "echo", "elif",
            "else", "esac", "exit", "export", "fi", "for", "function", "if", "in",
            "local", "readonly", "return", "select", "set", "shift", "source", "then",
            "trap", "unset", "until", "while"
        ])

    private static let pythonRules = Rules(
        lineComments: ["#"],
        quotes: ["\"", "'"],
        tripleQuotes: true,
        keywords: [
            "and", "as", "assert", "async", "await", "break", "class", "continue", "def",
            "del", "elif", "else", "except", "False", "finally", "for", "from", "global",
            "if", "import", "in", "is", "lambda", "match", "None", "nonlocal", "not",
            "or", "pass", "raise", "return", "self", "True", "try", "while", "with",
            "yield"
        ],
        typesByCase: true)

    private static let javascriptRules = Rules(
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        quotes: ["\"", "'", "`"],
        multilineQuotes: ["`"],
        keywords: [
            "as", "async", "await", "break", "case", "catch", "class", "const",
            "continue", "debugger", "default", "delete", "do", "else", "enum", "export",
            "extends", "false", "finally", "for", "from", "function", "get", "if",
            "implements", "import", "in", "instanceof", "interface", "let", "new",
            "null", "of", "private", "protected", "public", "readonly", "return", "set",
            "static", "super", "switch", "this", "throw", "true", "try", "type",
            "typeof", "undefined", "var", "void", "while", "with", "yield"
        ],
        typesByCase: true)

    private static let javaRules = Rules(
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        quotes: ["\"", "'"],
        tripleQuotes: true,
        keywords: [
            "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char",
            "class", "const", "continue", "default", "do", "double", "else", "enum",
            "extends", "false", "final", "finally", "float", "for", "if", "implements",
            "import", "instanceof", "int", "interface", "long", "native", "new", "null",
            "package", "permits", "private", "protected", "public", "record", "return",
            "sealed", "short", "static", "strictfp", "super", "switch", "synchronized",
            "this", "throw", "throws", "transient", "true", "try", "var", "void",
            "volatile", "while", "yield"
        ],
        typesByCase: true)

    private static let kotlinRules = Rules(
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        nestsBlockComments: true,
        quotes: ["\"", "'"],
        tripleQuotes: true,
        keywords: [
            "abstract", "as", "break", "by", "catch", "class", "companion", "const",
            "constructor", "continue", "data", "do", "else", "enum", "false", "final",
            "finally", "for", "fun", "if", "import", "in", "init", "inline", "interface",
            "internal", "is", "it", "lateinit", "null", "object", "open", "operator",
            "out", "override", "package", "private", "protected", "public", "return",
            "sealed", "super", "suspend", "this", "throw", "true", "try", "typealias",
            "val", "var", "when", "where", "while"
        ],
        typesByCase: true)

    private static let goRules = Rules(
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        quotes: ["\"", "'", "`"],
        multilineQuotes: ["`"],
        rawQuotes: ["`"],
        keywords: [
            "break", "case", "chan", "const", "continue", "default", "defer", "else",
            "fallthrough", "false", "for", "func", "go", "goto", "if", "import",
            "interface", "iota", "map", "nil", "package", "range", "return", "select",
            "struct", "switch", "true", "type", "var"
        ],
        typesByCase: true)

    // Rust has no ' in its quote list: a lifetime like 'a would read as a string that
    // never closes and take the rest of the line with it.
    private static let rustRules = Rules(
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        nestsBlockComments: true,
        quotes: ["\""],
        keywords: [
            "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else",
            "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop",
            "match", "mod", "move", "mut", "pub", "ref", "return", "self", "static",
            "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while"
        ],
        typesByCase: true)

    private static let sqlRules = Rules(
        lineComments: ["--"],
        blockComment: ("/*", "*/"),
        quotes: ["'", "\""],
        keywords: [
            "add", "all", "alter", "and", "as", "asc", "begin", "between", "by", "case",
            "check", "column", "commit", "constraint", "create", "cross", "database",
            "default", "delete", "desc", "distinct", "drop", "else", "end", "exists",
            "false", "foreign", "from", "full", "group", "having", "in", "index",
            "inner", "insert", "into", "is", "join", "key", "left", "like", "limit",
            "not", "null", "offset", "on", "or", "order", "outer", "primary",
            "references", "returning", "right", "rollback", "select", "set", "table",
            "then", "transaction", "true", "union", "unique", "update", "values",
            "view", "when", "where", "with"
        ],
        caseInsensitiveKeywords: true)

    private static let cLikeRules = Rules(
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        quotes: ["\"", "'"],
        keywords: [
            "auto", "bool", "break", "case", "catch", "char", "class", "const",
            "continue", "default", "delete", "do", "double", "else", "enum", "extern",
            "false", "final", "finally", "float", "for", "goto", "if", "import",
            "include", "inline", "int", "interface", "long", "namespace", "new", "null",
            "nullptr", "operator", "override", "private", "protected", "public",
            "return", "short", "signed", "sizeof", "static", "struct", "switch",
            "template", "this", "throw", "true", "try", "typedef", "typename", "union",
            "unsigned", "using", "var", "virtual", "void", "volatile", "while"
        ],
        typesByCase: true)
}
