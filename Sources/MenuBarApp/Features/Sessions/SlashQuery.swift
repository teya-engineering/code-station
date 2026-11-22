import Foundation

// A word in a prompt that starts with a slash and may name a command. Ranges count UTF-16
// units, the way the text field counts them.
struct SlashWord: Equatable, Sendable {
    // From the slash to the next space.
    let range: NSRange
    // From the slash to the end of the name. The whole word for a leading command; later
    // on, punctuation after the name is left out of it.
    let nameRange: NSRange
    // The name as written, without the slash.
    let name: String
    // What has been typed of the name up to the caret, for the word the caret is in. The
    // whole name for any other word.
    var query: String
    // Whether it is the first thing in the prompt, where everything is offered.
    let atStart: Bool
}

// The names a prompt can call on, split by where in the prompt each one works.
struct SlashCommandNames: Equatable, Sendable {
    // The first word of a prompt can be any command.
    var leading: Set<String> = []
    // Further in, only what the agent still acts on there.
    var inline: Set<String> = []

    init(leading: Set<String> = [], inline: Set<String> = []) {
        self.leading = leading
        self.inline = inline
    }

    init(_ commands: [AgentCommand], agent: AgentKind) {
        leading = Set(commands.map { $0.name.lowercased() })
        inline = Set(commands.filter { $0.worksMidPrompt(for: agent) }.map { $0.name.lowercased() })
    }

    func offered(atStart: Bool) -> Set<String> { atStart ? leading : inline }
}

// What the menu offers for the word at the caret: the commands that work where it sits,
// and the matches that only work at the start of a prompt, which are shown but cannot be
// picked.
struct SlashOffer: Equatable {
    var usable: [AgentCommand] = []
    var startOnly: [AgentCommand] = []

    var isEmpty: Bool { usable.isEmpty && startOnly.isEmpty }
}

// The slash words in a prompt, and the commands they point at.
//
// A slash counts at the start of the prompt or after a space, a tab or a new line. A word
// holding a second slash is a path, and a slash inside a word, as in `src/routes`, `11/20`
// or `and/or`, never counts. A leading command runs to the first space, since that is
// how the CLI reads one. Later on the agent reads the prompt as prose, so the name is
// the run of letters, digits and `_-:.` after the slash, without a full stop or colon at
// its end. Code, in a fenced block or in backticks, is sent as written and never runs, so
// a slash word in it does not count.
enum SlashQuery {
    private static let slash = UInt16(UInt8(ascii: "/"))
    private static let backtick = UInt16(UInt8(ascii: "`"))

    // Every slash word in the text, in order. A paragraph that comes later in a prompt,
    // such as one under a code block, does not open it, so nothing in it is at the start.
    static func words(in text: String, opensPrompt: Bool = true) -> [SlashWord] {
        let units = Array(text.utf16)
        let code = codeRanges(in: text, units: units)
        var words: [SlashWord] = []
        var index = 0
        var blank = true
        while index < units.count {
            guard !isSpace(units[index]) else {
                index += 1
                continue
            }
            var end = index + 1
            while end < units.count, !isSpace(units[end]) { end += 1 }
            let body = units[(index + 1)..<end]
            let start = index
            if units[index] == slash, !body.contains(slash),
               !code.contains(where: { NSLocationInRange(start, $0) }) {
                let atStart = opensPrompt && blank
                var nameEnd = end
                if !atStart {
                    nameEnd = body.firstIndex { !isNameUnit($0) } ?? end
                    while nameEnd > index + 1, isTrailingPunctuation(units[nameEnd - 1]) { nameEnd -= 1 }
                }
                let name = String(decoding: units[(index + 1)..<nameEnd], as: UTF16.self)
                words.append(SlashWord(range: NSRange(location: index, length: end - index),
                                       nameRange: NSRange(location: index, length: nameEnd - index),
                                       name: name, query: name, atStart: atStart))
            }
            blank = false
            index = end
        }
        return words
    }

    // The slash word the caret is in, with what has been typed of it so far. Nil with a
    // selection, since the caret is then nowhere, and past the length of any name.
    static func word(in text: String, caret: Int?) -> SlashWord? {
        guard let caret,
              var word = words(in: text).first(where: {
                  caret > $0.range.location && caret <= NSMaxRange($0.range)
              }) else { return nil }
        let typed = NSRange(location: word.range.location + 1, length: caret - word.range.location - 1)
        word.query = (text as NSString).substring(with: typed)
        return word.query.count <= 64 ? word : nil
    }

    // The commands to colour. The word being typed, with the caret at its end, is coloured
    // while a command offered there still starts with it. Any other word has to be a whole
    // name offered where it sits, so a typo or a command that only works first stays
    // plain, and the colour always means the command will run.
    static func highlightedRanges(in text: String, caret: Int?, names: SlashCommandNames,
                                  opensPrompt: Bool = true) -> [NSRange] {
        words(in: text, opensPrompt: opensPrompt).compactMap { word in
            let offered = names.offered(atStart: word.atStart)
            let name = word.name.lowercased()
            let typing = caret == NSMaxRange(word.range) && word.nameRange == word.range
            let known = typing ? offered.contains { $0.hasPrefix(name) } : offered.contains(name)
            return known ? word.nameRange : nil
        }
    }

    // At the start of a prompt everything that matches is offered. Further in, a match the
    // agent only acts on as the first word is shown apart, so it is clear why it is there
    // and that it will not run. A slash on its own further in is usually just a slash, as
    // in `A / B`, so nothing is offered until a letter follows it.
    static func offer(for word: SlashWord, in commands: [AgentCommand], agent: AgentKind) -> SlashOffer {
        guard word.atStart || !word.query.isEmpty else { return SlashOffer() }
        let found = matches(word.query, in: commands)
        guard !word.atStart else { return SlashOffer(usable: found) }
        return SlashOffer(usable: found.filter { $0.worksMidPrompt(for: agent) },
                          startOnly: found.filter { !$0.worksMidPrompt(for: agent) })
    }

    // The prompt with a command put in place of the word at the caret, and where the caret
    // goes. The word is replaced from its slash to the end of its name, or to the caret if
    // that is further on. A space follows unless a space or punctuation is already there,
    // so anything the command takes can be typed straight on. The caret lands past that
    // space, but not past a line break or a comma the person typed.
    static func completing(_ word: SlashWord, with command: AgentCommand, caret: Int,
                           in text: String) -> (text: String, caret: Int) {
        let text = text as NSString
        let start = word.range.location
        let end = min(max(NSMaxRange(word.nameRange), caret), text.length)
        let next = (text.substring(from: end) as String).first
        let settled = next.map { $0.isWhitespace || ",.;:!?)".contains($0) } ?? false
        let typed = command.typed
        let completed = text.replacingCharacters(in: NSRange(location: start, length: end - start),
                                                 with: settled ? typed : typed + " ")
        let steps = !settled || next.map { $0.isWhitespace && !$0.isNewline } == true ? 1 : 0
        return (completed, start + (typed as NSString).length + steps)
    }

    // What Markdown shows as code, the way the transcript reads it: every line from a fence
    // to the fence that closes it, or to the end if none does, and each span opened by a
    // run of backticks and closed by a run just as long.
    private static func codeRanges(in text: String, units: [UInt16]) -> [NSRange] {
        guard units.contains(backtick) || text.contains("~~~") else { return [] }
        var ranges: [NSRange] = []
        var prose: [NSRange] = []
        var fence: Fence?
        var fenceStart = 0
        var proseStart = 0
        var offset = 0
        for line in text.components(separatedBy: "\n") {
            let length = line.utf16.count
            let lineFence = Fence(line)
            if let opened = fence {
                if let lineFence, opened.isClosed(by: lineFence) {
                    ranges.append(NSRange(location: fenceStart, length: offset + length - fenceStart))
                    fence = nil
                    proseStart = offset + length
                }
            } else if let lineFence, lineFence.opens {
                prose.append(NSRange(location: proseStart, length: offset - proseStart))
                fence = lineFence
                fenceStart = offset
            }
            offset += length + 1
        }
        if fence != nil {
            ranges.append(NSRange(location: fenceStart, length: units.count - fenceStart))
        } else {
            prose.append(NSRange(location: proseStart, length: max(units.count - proseStart, 0)))
        }

        for part in prose {
            var index = part.location
            let end = NSMaxRange(part)
            while index < end {
                guard units[index] == backtick else {
                    index += 1
                    continue
                }
                let run = backtickRun(at: index, in: units, before: end)
                var search = index + run
                var closed = false
                while search < end {
                    guard units[search] == backtick else {
                        search += 1
                        continue
                    }
                    let closing = backtickRun(at: search, in: units, before: end)
                    if closing == run {
                        ranges.append(NSRange(location: index, length: search + closing - index))
                        index = search + closing
                        closed = true
                        break
                    }
                    search += closing
                }
                if !closed { index += run }
            }
        }
        return ranges
    }

    private static func backtickRun(at index: Int, in units: [UInt16], before end: Int) -> Int {
        var length = 0
        while index + length < end, units[index + length] == backtick { length += 1 }
        return length
    }

    private static func isSpace(_ unit: UInt16) -> Bool {
        Unicode.Scalar(unit)?.properties.isWhitespace ?? false
    }

    private static func isNameUnit(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit), scalar.isASCII else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || "_-:.".unicodeScalars.contains(scalar)
    }

    private static func isTrailingPunctuation(_ unit: UInt16) -> Bool {
        unit == UInt16(UInt8(ascii: ".")) || unit == UInt16(UInt8(ascii: ":"))
    }

    // What matches, nearest first: the name itself, then a name starting with it, then a
    // name holding it anywhere. A name is often two words joined by a colon, so the part
    // after the colon counts as a start of its own.
    static func matches(_ query: String, in commands: [AgentCommand]) -> [AgentCommand] {
        let query = query.lowercased()
        guard !query.isEmpty else { return commands }
        return commands.compactMap { command -> (AgentCommand, Int)? in
            let name = command.name.lowercased()
            let tail = name.split(separator: ":").last.map(String.init) ?? name
            if name == query { return (command, 0) }
            if name.hasPrefix(query) { return (command, 1) }
            if tail.hasPrefix(query) { return (command, 2) }
            if name.contains(query) { return (command, 3) }
            return nil
        }
        .enumerated()
        .sorted { left, right in
            left.element.1 != right.element.1
                ? left.element.1 < right.element.1
                : left.offset < right.offset
        }
        .map(\.element.0)
    }
}
