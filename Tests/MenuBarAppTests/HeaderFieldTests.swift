import Foundation
import Testing
@testable import MenuBarApp

// A header name that is not a token reaches an HTTP/2 server as a frame it cannot read,
// and the stream is dropped without a reply. The failure then arrives as a lost
// connection, which points at the network instead of at the header. These tests cover
// the two ways that is headed off: a pasted line is split into its two boxes, and a name
// that is still unusable stops the send while the reason is still known.
struct HeaderFieldTests {

    @Test func splitsAPastedHeaderLine() {
        var header = HeaderField(key: "Authorization: Basic dGVrdG9u", value: "")
        header.splitPastedName()
        #expect(header.key == "Authorization")
        #expect(header.value == "Basic dGVrdG9u")
    }

    @Test func splittingKeepsAValueThatHasNoColonToTakeItsPlace() {
        var header = HeaderField(key: "Authorization:", value: "already here")
        header.splitPastedName()
        #expect(header.key == "Authorization")
        #expect(header.value == "already here")
    }

    @Test func splittingTakesOnlyTheFirstColon() {
        var header = HeaderField(key: "X-Trace: a:b:c", value: "")
        header.splitPastedName()
        #expect(header.key == "X-Trace")
        #expect(header.value == "a:b:c")
    }

    @Test func splittingLeavesAPlainNameAlone() {
        var header = HeaderField(key: "Accept", value: "application/json")
        header.splitPastedName()
        #expect(header.key == "Accept")
        #expect(header.value == "application/json")
    }

    @Test func acceptsTokenNames() {
        #expect(HeaderField.isValidName("Authorization"))
        #expect(HeaderField.isValidName("X-Request-Id"))
        #expect(HeaderField.isValidName("If-None-Match"))
    }

    @Test func rejectsNamesThatAreNotTokens() {
        #expect(!HeaderField.isValidName("Authorization: Basic"))
        #expect(!HeaderField.isValidName("My Header"))
        #expect(!HeaderField.isValidName(""))
        #expect(!HeaderField.isValidName("Café"))
    }
}
