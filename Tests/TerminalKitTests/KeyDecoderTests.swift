import Testing
import TerminalKit

// The decoder turns what a terminal sends into keys. It is fed raw bytes exactly as a
// read on the tty returns them, including sequences cut in half by a read boundary.
struct KeyDecoderTests {

    private func decode(_ chunks: [UInt8]...) -> [Key] {
        var decoder = KeyDecoder()
        return chunks.flatMap { decoder.feed($0) }
    }

    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    @Test func printableTextBecomesCharacters() {
        #expect(decode(bytes("hi")) == [.char("h", []), .char("i", [])])
    }

    @Test func aCharacterSplitAcrossReadsWaitsForItsLastByte() {
        var decoder = KeyDecoder()
        #expect(decoder.feed([0xC3]) == [])
        #expect(decoder.feed([0xA9]) == [.char("é", [])])
    }

    @Test func controlBytesBecomeTheirKeys() {
        #expect(decode([0x0D, 0x09, 0x7F, 0x03]) == [
            .enter([]), .tab([]), .backspace([]), .char("c", .ctrl),
        ])
    }

    @Test func cursorKeysCarryTheirModifiers() {
        #expect(decode(bytes("\u{1B}[A\u{1B}[1;5B\u{1B}[1;2C\u{1B}OD")) == [
            .up([]), .down(.ctrl), .right(.shift), .left([]),
        ])
    }

    @Test func editingKeysAreDecoded() {
        #expect(decode(bytes("\u{1B}[5~\u{1B}[6~\u{1B}[3~\u{1B}[H\u{1B}[4~\u{1B}[Z")) == [
            .pageUp([]), .pageDown([]), .delete([]), .home([]), .end([]), .tab(.shift),
        ])
    }

    @Test func altArrivesAsAnEscapePrefix() {
        #expect(decode(bytes("\u{1B}x\u{1B}\r")) == [.char("x", .alt), .enter(.alt)])
    }

    @Test func aLoneEscapeWaitsUntilItIsFlushed() {
        var decoder = KeyDecoder()
        #expect(decoder.feed([0x1B]) == [])
        #expect(decoder.hasLoneEscape)
        #expect(decoder.flush() == [.escape])
        #expect(!decoder.hasLoneEscape)
    }

    // Escape pressed twice quickly lands in one read. The first is Escape at once, and
    // the second waits to be flushed like any lone Escape.
    @Test func twoEscapesInOneReadAreEscapeThenALoneEscape() {
        var decoder = KeyDecoder()
        #expect(decoder.feed([0x1B, 0x1B]) == [.escape])
        #expect(decoder.hasLoneEscape)
        #expect(decoder.flush() == [.escape])
    }

    // An Escape followed at once by a sequence is the Escape key and then that key.
    @Test func anEscapeBeforeASequenceIsEscapeThenTheKey() {
        #expect(decode(bytes("\u{1B}\u{1B}[A")) == [.escape, .up([])])
        #expect(decode(bytes("\u{1B}\u{1B}\u{1B}x")) == [.escape, .escape, .char("x", .alt)])
    }

    @Test func anEscapeSequenceSplitAcrossReadsIsOneKey() {
        #expect(decode([0x1B], bytes("[1;5"), bytes("A")) == [.up(.ctrl)])
    }

    @Test func aBracketedPasteArrivesWholeEvenAcrossReads() {
        #expect(decode(bytes("\u{1B}[200~line one\nli"), bytes("ne two\u{1B}[20"), bytes("1~x")) == [
            .paste("line one\nline two"), .char("x", []),
        ])
    }

    // Shift+Enter is what puts a new line in the composer, and terminals report it in
    // either of two encodings.
    @Test func shiftEnterIsReadFromKittyAndModifyOtherKeys() {
        #expect(decode(bytes("\u{1B}[13;2u\u{1B}[27;2;13~")) == [.enter(.shift), .enter(.shift)])
    }

    @Test func kittyReportsControlLettersAndPlainKeys() {
        #expect(decode(bytes("\u{1B}[97;5u\u{1B}[27u\u{1B}[9u\u{1B}[127u")) == [
            .char("a", .ctrl), .escape, .tab([]), .backspace([]),
        ])
    }

    @Test func anUnknownSequenceIsSwallowedAndWhatFollowsIsKept() {
        #expect(decode(bytes("\u{1B}[99x\u{1B}[?1;2ca")) == [.char("a", [])])
    }
}
