import Foundation
import CodeStationCore

// One word as the speech engine wrote it. The alternatives are only filled in when the
// engine was unsure of the word, so a word that has them is one worth checking.
struct HeardWord: Equatable, Sendable {
    var text: String
    var alternatives: [String] = []
}

// Everything heard in one take: the words the engine has settled on, and the tail it is
// still guessing at, which can still change as more is said.
struct DictationHeard: Equatable, Sendable {
    var settled: [HeardWord] = []
    var volatile: String = ""

    var isEmpty: Bool { settled.isEmpty && volatile.isBlank }
}

// A word in the prompt box that the engine was unsure of. The range is in UTF-16 units,
// which is what the text view colours and hit-tests in.
struct UnsureWord: Equatable, Sendable {
    var range: NSRange
    var heard: String
    var alternatives: [String]
}

// A take turned into prompt text: punctuation written out, file names turned into code
// spans, and where the grey tail and the unsure words sit in it.
struct WrittenTake: Equatable, Sendable {
    var text: String = ""
    var tentative: NSRange?
    var unsure: [UnsureWord] = []
}

enum DictationWriter {
    private struct Token {
        var text: String
        var alternatives: [String] = []
        var tentative = false
        // Stuck to the token before it with no space, like a comma.
        var gluedToPrevious = false
    }

    static func write(_ heard: DictationHeard, files: SpokenFileNames = SpokenFileNames(names: [])) -> WrittenTake {
        var tokens: [Token] = []
        for word in heard.settled {
            let parts = word.text.split(whereSeparator: \.isWhitespace).map(String.init)
            for part in parts {
                // Alternatives describe the whole word, so they only stay with it when it
                // was one piece.
                tokens.append(Token(text: part, alternatives: parts.count == 1 ? word.alternatives : []))
            }
        }
        let named = files.replace(in: tokens.map(\.text)).map { word in
            (word.text, word.source.map { tokens[$0].alternatives } ?? [])
        }
        tokens = SpokenPunctuation.apply(named).map {
            Token(text: $0.text, alternatives: $0.alternatives, gluedToPrevious: $0.glued)
        }

        for part in heard.volatile.split(whereSeparator: \.isWhitespace) {
            tokens.append(Token(text: String(part), tentative: true))
        }

        var text = ""
        var unsure: [UnsureWord] = []
        var tentativeStart: Int?
        for token in tokens {
            if !text.isEmpty, !token.gluedToPrevious, text.last != "\n" {
                text += " "
            }
            let start = (text as NSString).length
            if token.tentative, tentativeStart == nil { tentativeStart = start }
            text += token.text
            if !token.alternatives.isEmpty {
                let core = token.text.trimmingCharacters(in: .punctuationCharacters)
                let offset = (token.text as NSString).range(of: core).location
                if !core.isEmpty, offset != NSNotFound {
                    unsure.append(UnsureWord(range: NSRange(location: start + offset,
                                                            length: (core as NSString).length),
                                             heard: core,
                                             alternatives: token.alternatives.filter { $0 != core }))
                }
            }
        }
        let tentative = tentativeStart.map {
            NSRange(location: $0, length: (text as NSString).length - $0)
        }
        return WrittenTake(text: text, tentative: tentative, unsure: unsure.filter { !$0.alternatives.isEmpty })
    }
}

// The engine offers other readings of a whole phrase, not of one word. Lining each one up
// against the best reading shows which words it would change, and to what.
enum DictationAlternatives {
    // Below this the engine is guessing often enough that a word with another reading is
    // worth a second look. Above it, asking would mostly be noise.
    static let sureEnough = 0.8

    static func words(best: [String], confidences: [Double?], alternatives: [[String]]) -> [HeardWord] {
        var others = Array(repeating: [String](), count: best.count)
        let plain = best.map(comparable)
        for alternative in alternatives {
            let difference = alternative.map(comparable).difference(from: plain)
            var inserted: [Int: String] = [:]
            for case let .insert(offset, _, _) in difference { inserted[offset] = alternative[offset] }
            for case let .remove(offset, _, _) in difference {
                guard let other = inserted[offset] else { continue }
                let word = other.trimmingCharacters(in: .punctuationCharacters)
                if !word.isEmpty, !others[offset].contains(word) { others[offset].append(word) }
            }
        }
        return best.indices.map { index in
            let confidence = index < confidences.count ? confidences[index] : nil
            let unsure = (confidence ?? 0) < sureEnough
            return HeardWord(text: best[index], alternatives: unsure ? others[index] : [])
        }
    }

    private static func comparable(_ word: String) -> String {
        word.trimmingCharacters(in: .punctuationCharacters).lowercased()
    }
}

// The few marks that are said rather than typed. Only phrases that are never ordinary
// words in a prompt are taken, so "the trial period" keeps its word.
enum SpokenPunctuation {
    private static let marks: [([String], String)] = [
        (["new", "paragraph"], "\n\n"),
        (["new", "line"], "\n"),
        (["full", "stop"], "."),
        (["question", "mark"], "?"),
        (["exclamation", "mark"], "!"),
        (["comma"], ",")
    ]

    static func apply(_ words: [(String, [String])]) -> [(text: String, alternatives: [String], glued: Bool)] {
        var out: [(text: String, alternatives: [String], glued: Bool)] = []
        var capitaliseNext = false
        var index = 0
        while index < words.count {
            if let (length, mark) = mark(at: index, in: words.map(\.0)) {
                index += length
                if mark.hasPrefix("\n") {
                    if var last = out.popLast() {
                        last.text = last.text.trimmingTrailing(" ")
                        out.append(last)
                    }
                    out.append((mark, [], true))
                } else if var last = out.popLast() {
                    // The engine may already have put a mark there; the spoken one wins.
                    while let end = last.text.last, ",.;:!?".contains(end) { last.text.removeLast() }
                    last.text += mark
                    out.append(last)
                }
                capitaliseNext = mark != ","
                continue
            }
            var (text, alternatives) = words[index]
            let followsBreak = out.last?.text.hasSuffix("\n") == true
            if capitaliseNext, let first = text.first, first.isLowercase {
                text = first.uppercased() + text.dropFirst()
            }
            capitaliseNext = false
            out.append((text, alternatives, followsBreak))
            index += 1
        }
        return out
    }

    private static func mark(at index: Int, in words: [String]) -> (Int, String)? {
        for (phrase, mark) in marks where index + phrase.count <= words.count {
            let said = words[index..<index + phrase.count].map {
                $0.trimmingCharacters(in: .punctuationCharacters).lowercased()
            }
            if said == phrase { return (phrase.count, mark) }
        }
        return nil
    }
}

// File names said aloud, matched against the project's own files. "use delivery filters
// dot ts" is the way people read `useDeliveryFilters.ts`, so both are broken into the
// same run of lower-case words and compared. Only names with an extension are matched:
// without the "dot" there is nothing to tell a file apart from ordinary words.
struct SpokenFileNames: Sendable {
    private var byWords: [String: String] = [:]
    private var longest = 0

    init(names: [String]) {
        for name in names {
            let words = Self.words(in: name)
            guard words.contains("dot"), words.count >= 3, words.last != "dot" else { continue }
            let key = words.joined(separator: " ")
            if byWords[key] == nil { byWords[key] = name }
            longest = max(longest, words.count)
        }
    }

    var isEmpty: Bool { byWords.isEmpty }

    // Splits a name the way it is read aloud: at dots, dashes, underscores, digits and
    // each capital that starts a new word.
    static func words(in text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previous: Character?
        func flush() {
            if !current.isEmpty { words.append(current.lowercased()) }
            current = ""
        }
        // A dot at either end is punctuation, not part of a name.
        for character in text.trimmingCharacters(in: CharacterSet(charactersIn: ".")) {
            if character == "." {
                flush()
                words.append("dot")
            } else if character.isLetter {
                let startsWord = previous.map {
                    ($0.isLowercase && character.isUppercase) || $0.isNumber
                } ?? false
                if startsWord { flush() }
                current.append(character)
            } else if character.isNumber {
                if previous?.isLetter == true { flush() }
                current.append(character)
            } else {
                flush()
            }
            previous = character
        }
        flush()
        return words
    }

    // Each word either stays as it was or is folded, with the words after it, into one
    // file name. The source says which heard word a kept word came from.
    func replace(in heard: [String]) -> [(text: String, source: Int?)] {
        guard !isEmpty else { return heard.enumerated().map { ($1, $0) } }
        let spoken = heard.map { Self.words(in: $0) }
        var out: [(text: String, source: Int?)] = []
        var index = 0
        while index < heard.count {
            var key: [String] = []
            var found: (end: Int, name: String)?
            var end = index
            while end < heard.count, key.count < longest {
                key += spoken[end]
                if let name = byWords[key.joined(separator: " ")] { found = (end, name) }
                end += 1
            }
            if let found {
                let trailing = String(heard[found.end].reversed().prefix { ",;:!?".contains($0) }.reversed())
                out.append(("`\(found.name)`" + trailing, nil))
                index = found.end + 1
            } else {
                out.append((heard[index], index))
                index += 1
            }
        }
        return out
    }
}

// Where a take goes in the prompt: at the caret, between what was typed before it and
// what was typed after. Taking the take back out leaves exactly what was there.
struct DictationInsertion: Equatable, Sendable {
    let head: String
    let tail: String

    init(text: String, caret: Int) {
        let string = text as NSString
        let caret = min(max(0, caret), string.length)
        head = string.substring(to: caret)
        tail = string.substring(from: caret)
    }

    var original: String { head + tail }

    // The text with the take in place, and where the take starts in it.
    func compose(_ take: WrittenTake) -> (text: String, offset: Int) {
        guard !take.text.isEmpty else { return (original, (head as NSString).length) }
        var written = take.text
        let opensSentence = head.trimmingCharacters(in: .whitespaces).isEmpty
            || head.trimmingCharacters(in: .whitespaces).last.map { ".!?\n".contains($0) } == true
        // Only where the capital is the same length, so the marks measured on the take
        // still land on the same letters.
        if opensSentence, let first = written.first, first.isLowercase,
           first.uppercased().utf16.count == String(first).utf16.count {
            written = first.uppercased() + written.dropFirst()
        }
        let before = head.isEmpty || head.last?.isWhitespace == true ? "" : " "
        let after = tail.isEmpty || tail.first.map { $0.isWhitespace || ",.;:!?)".contains($0) } == true ? "" : " "
        let text = head + before + written + after + tail
        return (text, (head as NSString).length + (before as NSString).length)
    }
}

private extension String {
    func trimmingTrailing(_ character: Character) -> String {
        var copy = self
        while copy.last == character { copy.removeLast() }
        return copy
    }
}
