import Foundation
import Testing
@testable import MenuBarApp

// A pasted server is laid out the way setup guides print it, and the curly quotes that
// chat apps and smart-quote settings put in are read as the straight ones they stand for.
struct JSONPayloadTests {
    // The text as the import reads it, or nil when it does not read even straightened.
    private func readable(_ text: String) -> String? {
        let reading = JSONPayload.read(text)
        return reading.parses ? reading.text : nil
    }

    private func structural(_ quote: Unicode.Scalar, in text: String, at offset: Int? = nil) -> Bool {
        let state = JSONPayload.stringState(of: text, at: offset ?? (text as NSString).length)
        return JSONPayload.typedQuoteIsStructural(quote, in: state)
    }

    @Test func curlyQuotesAroundKeysAndValuesAreStraightened() {
        let typed = "{ \u{201C}fs\u{201D}: { \u{201C}command\u{201D}: \u{201C}npx\u{201D} } }"

        #expect(readable(typed) == #"{ "fs": { "command": "npx" } }"#)
    }

    @Test func curlyQuotesInsideAStraightStringAreKept() {
        let pasted = "{ \"description\": \"the \u{201C}fast\u{201D} one\", \u{201C}url\u{201D}: \"https://x\" }"

        #expect(readable(pasted)
                == "{ \"description\": \"the \u{201C}fast\u{201D} one\", \"url\": \"https://x\" }")
    }

    @Test func aCurlyCloserAfterAStraightOpenerIsStraightened() {
        let halfFixed = "{ \"fs\": { \"command\u{201D}: \"npx\u{201D} } }"
        #expect(readable(halfFixed) == #"{ "fs": { "command": "npx" } }"#)
    }

    @Test func aCurlyQuoteFollowedByMoreWordsStaysInTheValue() {
        let text = "{ \"d\": \"say \u{201C}hi\u{201D} twice\u{201D} }"
        #expect(readable(text) == "{ \"d\": \"say \u{201C}hi\u{201D} twice\" }")
    }

    // One curly key forces the whole text to be straightened; a value whose quotes pair
    // up inside it must come through that whole, even with a comma after its closer.
    @Test func pairedCurlyQuotesInAValueSurviveStraighteningElsewhere() {
        let text = "{\u{201C}desc\u{201D}: \"the \u{201C}fast\u{201D}, one\", \"command\": \"npx\"}"
        #expect(readable(text)
                == "{\"desc\": \"the \u{201C}fast\u{201D}, one\", \"command\": \"npx\"}")
    }

    @Test func aTypedClosingCurlyQuoteClosesAStringWithNoQuoteInIt() {
        #expect(structural("\u{201D}", in: #"{ "command"#))
    }

    // Marks that are as often part of a value as the end of one stay in it.
    @Test func symmetricMarksTypedInAValueStayInIt() {
        #expect(!structural("\u{2033}", in: #"{ "label": "27"#))   // 27″, inches
        #expect(!structural("\u{FF02}", in: #"{ "d": ""#))         // ＂hi＂
        #expect(!structural("\u{00BB}", in: #"{ "d": ""#))         // Danish »tekst«
    }

    // A straightened text keeps the original's offsets only because each quote it swaps
    // is one UTF-16 unit, as `"` is.
    @Test func everyCurlyQuoteIsOneUTF16Unit() {
        for quote in JSONPayload.curlyDoubleQuotes {
            #expect(String(quote).utf16.count == 1)
        }
    }

    @Test func aTypedOpeningCurlyQuoteInsideAValueStaysInIt() {
        #expect(!structural("\u{201C}", in: #"{ "d": "the "#))
        #expect(!structural("\u{00AB}", in: #"{ "d": "le "#))
    }

    @Test func aTypedCurlyQuotePairingOneInTheValueStaysInIt() {
        let text = "{ \"d\": \"the \u{201C}fast"
        #expect(!structural("\u{201D}", in: text))
    }

    @Test func aTypedCurlyQuoteOutsideAStringIsStructural() {
        #expect(structural("\u{201C}", in: "{ "))
    }

    @Test func aStringACurlyQuoteOpenedClosesOnAnyCurlyQuote() {
        let state = JSONPayload.stringState(of: #"{ "command"#, at: 10)
        #expect(state.inString)
        #expect(state.start == 2)
        #expect(JSONPayload.typedQuoteIsStructural("\u{201C}", in: state, openedCurly: true))
    }

    @Test func validJSONIsNeverRewritten() {
        let pasted = "{ \"note\": \"\u{201C}quoted\u{201D}\" }"
        #expect(readable(pasted) == pasted)
    }

    @Test func textThatStillDoesNotReadIsRefused() {
        #expect(readable("{ \u{201C}fs\u{201D}: ") == nil)
    }

    // An inch mark before a comma is part of the value as it is written. The guess
    // `straightened` makes for broken text does not reach the caret, so the string after
    // the value is still read as closed.
    @Test func aCurlyQuoteInAValueDoesNotEndItForTheCaret() {
        let text = "{\"size\": \"27\u{201D}, wide\", "
        #expect(!JSONPayload.stringState(of: text, at: (text as NSString).length).inString)
        #expect(structural("\u{201C}", in: text))
    }

    // A string a pasted curly quote opened closes on any curly quote, as `straightened`
    // reads it.
    @Test func aPastedCurlyOpenerClosesOnAnyCurlyQuote() {
        #expect(structural("\u{201C}", in: "{ \u{201E}command"))
    }

    // Only the English closing quote is ever taken for a half-fixed closer. A double
    // prime before a comma marks inches and stays in the value while the curly quotes
    // around the key are put right.
    @Test func anInchMarkBeforeACommaStaysInTheValue() {
        let pasted = "{ \u{201C}a\u{201D}: { \"command\": \"x\", \"note\": \"27\u{2033}, wide\" } }"
        #expect(readable(pasted) == "{ \"a\": { \"command\": \"x\", \"note\": \"27\u{2033}, wide\" } }")
    }

    // A web page indents its code with no-break spaces, which JSON does not take. Outside
    // a string they read as plain spaces, inside one they stay, and the text keeps its
    // length so the box's offsets still hold.
    @Test func noBreakSpacesOutsideStringsReadAsSpaces() throws {
        let pasted = "\u{00A0}{\n\u{00A0}\u{00A0}\"a\": { \"url\": \"u\u{00A0}v\" }\n}\u{00A0}"
        let text = try #require(readable(pasted))
        #expect(text == " {\n  \"a\": { \"url\": \"u\u{00A0}v\" }\n} ")
        #expect((text as NSString).length == (pasted as NSString).length)
    }
}

@MainActor
struct CurlyQuoteImportTests {
    private let scratch = ScratchDirectory(prefix: "curly-import")

    @Test func aServerTypedWithSmartQuotesImports() throws {
        let file = scratch.path("config.json")
        try Data(#"{ "mcpServers": {} }"#.utf8).write(to: file)
        let configs = ConfigStore(configURL: file)

        try configs.importJSON("""
        { \u{201C}fs\u{201D}: { \u{201C}command\u{201D}: \u{201C}npx\u{201D}, \u{201C}args\u{201D}: [\u{201C}-y\u{201D}] } }
        """)

        let server = try #require(configs.servers.first)
        #expect(server.name == "fs")
        #expect(server.command == "npx")
    }
    // The import reads the text exactly as the box does, odd spaces and all.
    @Test func aServerIndentedWithNoBreakSpacesImports() throws {
        let file = scratch.path("config.json")
        try Data(#"{ "mcpServers": {} }"#.utf8).write(to: file)
        let configs = ConfigStore(configURL: file)
        try configs.importJSON("\u{00A0}{ \"fs\": { \"command\": \"npx\" } }\u{00A0}")
        #expect(configs.servers.first?.name == "fs")
    }
}

// The box greys out what the import leaves behind, so the scope it finds in the text has
// to be the one the import reads.
struct ServerScopeTests {
    private func scope(_ text: String) throws -> JSONPayload.ServerScope {
        try #require(JSONPayload.serverScope(in: JSONPayload.read(text)))
    }

    private func kept(_ text: String, _ scope: JSONPayload.ServerScope) -> String {
        (text as NSString).substring(with: scope.range)
    }

    @Test func aClaudeSnippetKeepsOnlyWhatIsInsideMcpServers() throws {
        let text = """
        {
          "mcpServers": {
            "incident-io": {
              "type": "http",
              "url": "https://mcp.incident.io/mcp"
            }
          }
        }
        """
        let found = try scope(text)
        #expect(found.wrapper == ["mcpServers"])
        #expect(found.serverNames == ["incident-io"])
        #expect(kept(text, found).hasPrefix("{\n    \"incident-io\""))
        #expect(kept(text, found).hasSuffix("}\n  }"))
    }

    @Test func aBareMapHasNoWrapper() throws {
        let found = try scope(#"{ "a": { "command": "x" }, "b": { "url": "y" } }"#)
        #expect(found.wrapper.isEmpty)
        #expect(found.serverNames == ["a", "b"])
    }

    @Test func vsCodeSettingsReachTwoLevelsDown() throws {
        let text = #"{ "editor.fontSize": 13, "mcp": { "servers": { "s": { "url": "u" } }, "inputs": [] } }"#
        let found = try scope(text)
        #expect(found.wrapper == ["mcp", "servers"])
        #expect(kept(text, found) == #"{ "s": { "url": "u" } }"#)
    }

    @Test func aServerNamedLikeAWrapperIsNotAWrapper() throws {
        let found = try scope(#"{ "servers": { "command": "npx" } }"#)
        #expect(found.wrapper.isEmpty)
        #expect(found.serverNames == ["servers"])
    }

    @Test func keysInsideAListAreNeverAWrapper() throws {
        let found = try scope(#"{ "x": [ { "mcpServers": { "a": {} } } ], "b": { "url": "u" } }"#)
        #expect(found.wrapper.isEmpty)
    }

    @Test func aWrapperStillBeingTypedRunsToTheEnd() throws {
        let text = "{\n  \"mcpServers\": {\n    \"a\": { \"url\": \"u\" },\n    \"b"
        let found = try scope(text)
        #expect(found.wrapper == ["mcpServers"])
        #expect(found.serverNames == ["a"])
        #expect(NSMaxRange(found.range) == (text as NSString).length)
    }

    // Valid text is scanned as written, so a curly quote before a comma inside a value
    // is not mistaken for the end of it.
    @Test func validTextIsScannedAsWritten() throws {
        let found = try scope("{ \"mcpServers\": { \"a\": { \"url\": \"u\", \"note\": \"x \u{201C}y\u{201D}, z\" } } }")
        #expect(found.wrapper == ["mcpServers"])
        #expect(found.serverNames == ["a"])
    }

    @Test func curlyQuotedWrappersAreFound() throws {
        let text = "{ \u{201C}mcpServers\u{201D}: { \u{201C}a\u{201D}: { \u{201C}url\u{201D}: \u{201C}u\u{201D} } } }"
        let found = try scope(text)
        #expect(found.wrapper == ["mcpServers"])
        #expect(kept(text, found).hasPrefix("{ \u{201C}a"))
    }

    @Test func escapedKeysAreReadAsTheJSONReaderReadsThem() throws {
        let found = try scope(#"{ "mcp\u0053ervers": { "a": { "url": "u" } } }"#)
        #expect(found.wrapper == ["mcpServers"])
        #expect(found.serverNames == ["a"])
    }

    // JSONSerialization keeps the first of two equal keys, so only the first can lead
    // anywhere.
    @Test func aRepeatedKeyIsNeverTheWrapper() throws {
        let found = try scope(#"{ "mcpServers": { "command": "x" }, "mcpServers": { "a": { "url": "u" } } }"#)
        #expect(found.wrapper.isEmpty)
    }

    @Test func aCaretIsInsideAStringOnlyBetweenItsQuotes() {
        let text = #"{ "a": "b\"c", "#
        let inString = { JSONPayload.stringState(of: text, at: $0).inString }
        #expect(!inString(2))
        #expect(inString(4))
        #expect(inString(11))
        #expect(!inString((text as NSString).length))
    }

    // A quote followed by a combining mark is one Character but still a quote to JSON.
    @Test func aStringStartingWithACombiningMarkIsStillAString() throws {
        let found = try scope("{ \"mcpServers\": { \"\u{0301}a\": { \"url\": \"u\" } } }")
        #expect(found.wrapper == ["mcpServers"])
        #expect(found.serverNames == ["\u{0301}a"])
    }

    // Once the text parses, the grey follows the wrapper the import walks to.
    @Test(arguments: [
        #"{ "mcpServers": { "a": { "url": "u" } } }"#,
        #"{ "servers": { "command": "npx" } }"#,
        #"{ "editor.fontSize": 13, "mcp": { "servers": { "s": { "url": "u" } } } }"#,
        #"{ "mcp\u0053ervers": { "a": { "url": "u" } } }"#,
        #"{ "mcpServers": { "command": "x" }, "mcpServers": { "a": { "url": "u" } } }"#,
        #"{ "x": [ { "mcpServers": { "a": {} } } ], "b": { "url": "u" } }"#,
    ])
    func theGreyAndTheImportAgree(text: String) throws {
        let reading = JSONPayload.read(text)
        let root = try #require(reading.value as? [String: Any])
        #expect(try scope(text).wrapper == JSONPayload.servers(in: root).wrapper)
    }

    // The note names only what the import takes as a server, and once the text parses it
    // knows what the import refuses: anything but an object with a command or a url.
    @Test func onlyObjectsAreNamedAsServers() throws {
        let parsed = try scope(#"{ "mcpServers": { "a": { "url": "u" }, "b": 1, "c": [], "d": { "args": [] } } }"#)
        #expect(parsed.serverNames == ["a"])
        #expect(parsed.notServers == ["b", "c", "d"])

        let bare = try scope(#"{ "a": { "command": "x" }, "inputs": [] }"#)
        #expect(bare.wrapper.isEmpty)
        #expect(bare.notServers == ["inputs"])

        let typing = try scope("{ \"mcpServers\": { \"a\": 1, \"b\": { \"url\"")
        #expect(typing.serverNames == ["b"])
        #expect(typing.notServers.isEmpty)
    }

    // One server pasted with no name around it is said to be just that, rather than
    // its own fields being taken for servers.
    @Test func aServerWithNoNameIsSaidToBeOne() throws {
        let found = try scope(#"{ "command": "npx", "args": ["-y", "pkg"] }"#)
        #expect(found.unnamedServer)
        #expect(found.notServers.isEmpty)
        #expect(try scope(#"{ "url": "https://x" }"#).unnamedServer)
        #expect(try !scope(#"{ "a": { "url": "u" } }"#).unnamedServer)
    }

    // Only text that parses says what the import would take; a guess at text still being
    // typed is marked as one.
    @Test func onlyParsedTextIsMarkedParsed() throws {
        #expect(try scope(#"{ "mcpServers": { "a": { "url": "u" } } }"#).servers.parsed)
        #expect(try !scope(#"{ "mcpServers": { "a": { "url": "u" } } // a comment"#).servers.parsed)
    }
}

// The import reads the servers from where the box's grey says they are.
@MainActor
struct WrapperImportTests {
    private let scratch = ScratchDirectory(prefix: "wrapper-import")

    @Test func anEscapedWrapperKeyIsUnwrapped() throws {
        let file = scratch.path("config.json")
        try Data(#"{ "mcpServers": {} }"#.utf8).write(to: file)
        let configs = ConfigStore(configURL: file)

        try configs.importJSON(#"{ "mcp\u0053ervers": { "incident-io": { "type": "http", "url": "https://x" } } }"#)

        #expect(configs.servers.map(\.name) == ["incident-io"])
    }

}
