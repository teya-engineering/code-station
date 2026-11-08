import Foundation

// The JSON a server is pasted or typed as. People copy setup snippets out of chat apps,
// docs and notes, and those turn straight quotes into typographic ones, which no JSON
// reader accepts. The quotes are put back before anything gives up on the text.
enum JSONPayload {
    // Every mark a smart-quotes setting or a typeset page puts where a `"` was meant:
    // English, German, French and full-width quotes, and the double prime. Every one is a
    // single UTF-16 unit, which is what lets a straightened text keep the original's
    // offsets (JSONPayloadTests checks it).
    static let curlyDoubleQuotes: Set<Unicode.Scalar> = [
        "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", "\u{2033}", "\u{00AB}", "\u{00BB}", "\u{FF02}"
    ]

    // The one curly quote that, typed inside a string, can only be closing it: the
    // English closing quote. The others are left alone there. The double prime marks
    // inches, as in "27″", the full-width quote is symmetric, and » opens a quote in
    // Danish as often as it closes one in French, so taking any of them for the end of
    // the string would cut a value short.
    static let closingCurlyQuotes: Set<Unicode.Scalar> = ["\u{201D}"]

    // The text as the JSON reader takes it, worked out once and shared by everything
    // that needs it: the import, the grey around the servers and the syntax colour.
    struct Reading {
        // As written when that parses, straightened otherwise. Straightening swaps one
        // UTF-16 unit for another, so offsets into it are offsets into the original.
        let text: String
        // The parsed value, nil when neither reading parses.
        let value: Any?
        var parses: Bool { value != nil }
    }

    // Parses at most twice: as written, then straightened when there is a curly quote or
    // an odd space to put right.
    static func read(_ text: String) -> Reading {
        if let value = JSONFormat.parse(text) { return Reading(text: text, value: value) }
        guard text.utf16.contains(where: { isCurlyUnit($0) || isOddSpace($0) }) else {
            return Reading(text: text, value: nil)
        }
        let straight = straightened(text)
        return Reading(text: straight, value: JSONFormat.parse(straight))
    }

    // Curly quotes outside a string open or close one, so they become `"`. Inside a
    // string that a straight quote opened they are part of the value, as in
    // "description": "the “fast” one", and they stay. The one exception is an English closing
    // quote ” that has no partner in the value so far and is followed by what follows a
    // closing quote, a colon, a comma or a closing bracket: that is a closing quote someone
    // half put right, as in "command”: "npx”, typed straight where it opens and left curly
    // where it closes. Counting partners keeps "the “fast”, one" whole, and only ” counts
    // (see `closingCurlyQuotes`), so the inch mark in "27″, wide" stays in the value.
    //
    // Outside a string, a space JSON does not take, such as the no-break space a web page
    // indents its code with, becomes a plain one. Every such space is one UTF-16 unit too.
    //
    // Text that already reads is never passed through here by `read`, so the guess can
    // only ever rescue text, not break it.
    static func straightened(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var inString = false
        var openedCurly = false
        var curliesInString = 0
        var escaped = false

        func isSpace(_ scalar: Unicode.Scalar) -> Bool {
            scalar.isASCII ? JSONScanner.isWhitespace(UInt16(scalar.value)) : isOddSpace(scalar)
        }

        func closesAString(after index: Int) -> Bool {
            var next = index + 1
            while next < scalars.count, isSpace(scalars[next]) { next += 1 }
            guard next < scalars.count else { return false }
            return [":", ",", "}", "]"].contains(scalars[next])
        }

        for (index, scalar) in scalars.enumerated() {
            let curly = curlyDoubleQuotes.contains(scalar)
            if inString {
                if escaped {
                    escaped = false
                    out.append(scalar)
                } else if scalar == "\\" {
                    escaped = true
                    out.append(scalar)
                } else if scalar == "\""
                            || (curly && openedCurly)
                            || (closingCurlyQuotes.contains(scalar) && curliesInString.isMultiple(of: 2)
                                && closesAString(after: index)) {
                    inString = false
                    out.append("\"")
                } else {
                    if curly { curliesInString += 1 }
                    out.append(scalar)
                }
            } else if scalar == "\"" || curly {
                inString = true
                openedCurly = curly
                curliesInString = 0
                out.append("\"")
            } else if !scalar.isASCII, isOddSpace(scalar) {
                out.append(" ")
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    // MARK: - Where the servers are

    // Claude and Cursor keep servers under "mcpServers", VS Code's mcp.json under
    // "servers", and VS Code's settings under "mcp" > "servers" or the older
    // "github.copilot.chat.mcp.servers". Tried in this order.
    static let wrapperPaths: [[String]] = [["mcpServers"], ["servers"], ["mcp", "servers"],
                                           ["github.copilot.chat.mcp.servers"]]

    // The part of a paste that holds the servers. The import reads only this object;
    // everything outside it, such as the wrapper or VS Code's "inputs", is left behind.
    struct ServerScope: Equatable {
        var servers: Servers
        // From the opening brace of the servers' object to its closing one, in UTF-16
        // offsets, which is how the text view counts.
        var range: NSRange

        var wrapper: [String] { servers.wrapper }
        var serverNames: [String] { servers.names }
        var notServers: [String] { servers.notServers }
        var unnamedServer: Bool { servers.unnamed }
    }

    // Which servers a paste holds, apart from where they are written: what the note under
    // the box tells.
    struct Servers: Equatable {
        // The keys that lead to the servers. Empty when the paste is a bare map of them.
        var wrapper: [String]
        // The keys whose values are servers, in the order they are written. While the
        // text is still being typed, every key whose value is an object.
        var names: [String]
        // The keys whose values are not servers, which the import refuses (see
        // `isServer`). Only known once the text parses: while it is being typed, a key may
        // have no value yet.
        var notServers: [String] = []
        // Whether the paste is a single server with no name around it, as in
        // { "command": "npx" }, which the import cannot add until it has one.
        var unnamed = false
        // Whether this was read from the parsed text, which the import would take, rather
        // than guessed from text that does not parse yet.
        var parsed = false
    }

    // Said both under the box and when Add is pressed.
    static let unnamedServerMessage = "This reads as one server with no name. Name it, as in { \"my-server\": { … } }."

    // The servers in a parsed paste and the keys that lead to them: the first path that
    // reaches an object which is not itself a server, or the paste itself when it is a
    // bare map. This is what the import reads, worked out on the value JSONSerialization
    // made, so it can never disagree with the parser.
    static func servers(in root: [String: Any]) -> (wrapper: [String], map: [String: Any]) {
        for path in wrapperPaths {
            var node: Any? = root
            for key in path { node = (node as? [String: Any])?[key] }
            if let map = node as? [String: Any], !isServer(map) {
                return (path, map)
            }
        }
        return ([], root)
    }

    // What the import takes for a server: an object with a "command" (stdio) or a "url"
    // (remote).
    static func isServer(_ value: Any?) -> Bool {
        guard let object = value as? [String: Any] else { return false }
        return object["command"] != nil || object["url"] != nil
    }

    // Where the servers sit in the text, for the box to grey out everything around them.
    //
    // Text that parses takes its wrapper from `servers(in:)`, the same answer the import
    // gets, and only looks up where that object is written. Text still being typed does not
    // parse, so the scan picks the wrapper itself, by the same rule: a string or object left
    // open runs to the end of the text, which keeps the grey steady while someone edits
    // inside it. Keys are compared decoded, so "mcp\u0053ervers" is "mcpServers" here as it
    // is to the JSON reader.
    static func serverScope(in reading: Reading) -> ServerScope? {
        let objects = objectSpans(in: reading.text)
        if let parsed = reading.value as? [String: Any] {
            let (wrapper, values) = servers(in: parsed)
            guard let map = objects.first(where: { $0.path == wrapper }) else { return nil }
            if wrapper.isEmpty, isServer(parsed) {
                return ServerScope(servers: Servers(wrapper: [], names: [], unnamed: true, parsed: true),
                                   range: map.range)
            }
            return ServerScope(servers: Servers(wrapper: wrapper,
                                                names: map.keys.filter { isServer(values[$0]) },
                                                notServers: map.keys.filter { !isServer(values[$0]) },
                                                parsed: true),
                               range: map.range)
        }
        guard let root = objects.first(where: { $0.path.isEmpty }) else { return nil }
        for path in wrapperPaths {
            if let map = objects.first(where: { $0.path == path }),
               !map.keys.contains("command"), !map.keys.contains("url") {
                return ServerScope(servers: Servers(wrapper: path, names: map.objectKeys), range: map.range)
            }
        }
        return ServerScope(servers: Servers(wrapper: [], names: root.objectKeys), range: root.range)
    }

    private struct ObjectSpan {
        var path: [String]
        var range: NSRange
        var keys: [String]
        // The keys whose value is written as an object, in the same order.
        var objectKeys: [String]
    }

    // Every object down to the deepest wrapper, with the keys written directly in it.
    // Straightening swaps one UTF-16 unit for another, so offsets into the straightened
    // text are offsets into the original.
    private static func objectSpans(in text: String) -> [ObjectSpan] {
        let units = Array(text.utf16)
        let maxDepth = wrapperPaths.map(\.count).max() ?? 0

        struct Frame {
            // Nil inside a list, where nothing is a wrapper, and below the deepest
            // wrapper, where nothing needs looking at. Only a frame with a path keeps keys.
            var path: [String]?
            var start: Int
            var isObject: Bool
            var keys: [String] = []
            var seen: Set<String> = []
            var objectKeys: Set<String> = []
            var expectsKey = true
            // Nil after a key the object already had. JSONSerialization keeps the first
            // of two equal keys, so the value of a repeat is never what the import reads.
            var lastKey: String?
        }
        var stack: [Frame] = []
        var spans: [ObjectSpan] = []

        func childPath() -> [String]? {
            guard let parent = stack.last else { return [] }
            guard parent.isObject, let path = parent.path, path.count < maxDepth,
                  let key = parent.lastKey else { return nil }
            return path + [key]
        }

        func close(_ frame: Frame, at end: Int) {
            guard frame.isObject, let path = frame.path else { return }
            spans.append(ObjectSpan(path: path, range: NSRange(location: frame.start, length: end - frame.start),
                                    keys: frame.keys, objectKeys: frame.keys.filter(frame.objectKeys.contains)))
        }

        // Frames are changed where they sit in the stack, so a frame with a thousand keys
        // is not copied on every one.
        JSONScanner.forEach(in: units) { token in
            switch token {
            case .string(let range, let closed):
                let top = stack.count - 1
                guard closed, top >= 0, stack[top].isObject, stack[top].expectsKey else { return }
                stack[top].expectsKey = false
                guard stack[top].path != nil else { return }
                let key = decodedKey(Array(units[range]))
                let fresh = stack[top].seen.insert(key).inserted
                if fresh { stack[top].keys.append(key) }
                stack[top].lastKey = fresh ? key : nil
            case .unit(let unit, let index):
                switch unit {
                case JSONScanner.openBrace, JSONScanner.openBracket:
                    let path = childPath()
                    if unit == JSONScanner.openBrace, let top = stack.indices.last, stack[top].isObject,
                       stack[top].path != nil, let key = stack[top].lastKey {
                        stack[top].objectKeys.insert(key)
                    }
                    stack.append(Frame(path: path, start: index, isObject: unit == JSONScanner.openBrace))
                case JSONScanner.closeBrace, JSONScanner.closeBracket:
                    if let frame = stack.popLast() { close(frame, at: index + 1) }
                case JSONScanner.comma:
                    if let top = stack.indices.last, stack[top].isObject { stack[top].expectsKey = true }
                default:
                    break
                }
            }
        }
        // Whatever is still open runs to the end of the text.
        for frame in stack { close(frame, at: units.count) }
        return spans
    }

    // A key as the JSON reader sees it, given its quoted UTF-16 units. Only a key with
    // an escape needs reading; one that does not read is kept as written.
    // The quotes come off as units, not Characters: a quote and a combining mark after it
    // are one Character.
    private static func decodedKey(_ quoted: [UInt16]) -> String {
        let written = String(decoding: quoted.dropFirst().dropLast(), as: UTF16.self)
        guard quoted.contains(JSONScanner.backslash) else { return written }
        return JSONFormat.parse(String(decoding: quoted, as: UTF16.self)) as? String ?? written
    }

    // MARK: - Typing a quote

    // Where a caret sits relative to the strings before it.
    struct StringState: Equatable {
        var inString = false
        // The UTF-16 offset of the quote that opened the string the caret is in.
        var start = 0
        // Whether that quote was a curly one, so any curly quote closes the string.
        var openedCurly = false
        // How many curly quotes that string holds so far.
        var curlies = 0
    }

    // Reads the quotes before the caret as they are written. A curly quote outside a
    // string opens one, and closes one that a curly quote opened; in a string a straight
    // quote opened, it is part of the value. Unlike `straightened`, this never guesses
    // that a curly quote in a value closes it, so "27”, wide" stays one value however
    // the rest of the text reads. Pass the straightened reading instead of the text when
    // that is what parses: it is then exactly what the JSON reader sees.
    static func stringState(of text: String, at offset: Int) -> StringState {
        let nsText = text as NSString
        let prefix = Array(nsText.substring(to: min(max(offset, 0), nsText.length)).utf16)
        var state = StringState()
        var escaped = false
        for (index, unit) in prefix.enumerated() {
            let curly = isCurlyUnit(unit)
            if !state.inString {
                if unit == JSONScanner.quote || curly {
                    state = StringState(inString: true, start: index, openedCurly: curly)
                }
            } else if escaped {
                escaped = false
            } else if unit == JSONScanner.backslash {
                escaped = true
            } else if unit == JSONScanner.quote || (curly && state.openedCurly) {
                state = StringState()
            } else if curly {
                state.curlies += 1
            }
        }
        return state
    }

    // Whether a curly quote typed where `state` says is meant as `"`. Outside a string it
    // always is. In a string that a curly quote opened, whether still in the text or typed
    // and already straightened (`openedCurly`), any curly quote closes it, the way
    // `straightened` reads one, so German „command“ closes on its “. In any other
    // string it is when the value has no curly quote waiting for a partner and the quote
    // is the closing ” (see `closingCurlyQuotes`): typing "command” closes the key, typing
    // "the “fast” keeps both
    // marks in the value. Unlike `straightened`, nothing after the caret can be read yet,
    // so the kind of quote stands in for what follows it.
    static func typedQuoteIsStructural(_ quote: Unicode.Scalar, in state: StringState,
                                       openedCurly: Bool = false) -> Bool {
        guard state.inString else { return true }
        if openedCurly || state.openedCurly { return true }
        return state.curlies.isMultiple(of: 2) && closingCurlyQuotes.contains(quote)
    }

    // Every curly quote is a single UTF-16 unit, and none is below « (U+00AB), so ASCII
    // text never reaches the set.
    // A space that is not one of JSON's four, such as a no-break space. All of them are in
    // the Basic Multilingual Plane, so each is one UTF-16 unit.
    static func isOddSpace(_ unit: UInt16) -> Bool {
        unit >= 0x80 && (Unicode.Scalar(unit).map(isOddSpace) ?? false)
    }

    static func isOddSpace(_ scalar: Unicode.Scalar) -> Bool {
        !scalar.isASCII && scalar.properties.isWhitespace
    }

    static func isCurlyUnit(_ unit: UInt16) -> Bool {
        unit >= 0xAB && (Unicode.Scalar(unit).map(curlyDoubleQuotes.contains) ?? false)
    }
}
