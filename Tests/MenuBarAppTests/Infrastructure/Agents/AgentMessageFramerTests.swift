import Foundation
import Testing
@testable import MenuBarApp
@testable import CodeStationCore

struct AgentMessageFramerTests {
    @Test func contentLengthCountsBytesAndRetainsPartialMessages() throws {
        let body = Data("{\"text\":\"Olá\"}".utf8)
        var framer = AgentMessageFramer(format: .contentLength)
        framer.append(Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body.dropLast())
        #expect(try framer.next() == nil)
        framer.append(body.suffix(1) + Data("Content-Length: 2\r\n\r\n{}".utf8))
        #expect(try framer.next() == body)
        #expect(try framer.next() == Data("{}".utf8))
        #expect(try framer.next() == nil)
    }

    @Test func jsonLinesRetainsPartialLines() throws {
        var framer = AgentMessageFramer(format: .jsonLines)
        framer.append(Data("first\nsec".utf8))
        #expect(try framer.next() == Data("first".utf8))
        #expect(try framer.next() == nil)
        framer.append(Data("ond\n".utf8))
        #expect(try framer.next() == Data("second".utf8))
    }

    @Test(arguments: ["-1", "33554433", "invalid"])
    func rejectsInvalidLengths(_ length: String) {
        var framer = AgentMessageFramer(format: .contentLength)
        framer.append(Data("Content-Length: \(length)\r\n\r\n".utf8))
        #expect(throws: AgentMessageFramer.Failure.self) { try framer.next() }
    }

    @Test func answeredRequestsDoNotExpireAndUnknownRepliesDoNotRemoveOthers() {
        var requests = AgentRequestTracker<String>()
        let start = Date(timeIntervalSince1970: 100)
        let first = requests.insert("first", at: start)
        let second = requests.insert("second", at: start.addingTimeInterval(20))
        #expect(requests.remove(99) == nil)
        #expect(requests.remove(first) == "first")
        #expect(!requests.hasExpired(at: start.addingTimeInterval(25), timeout: 10))
        #expect(requests.hasExpired(at: start.addingTimeInterval(31), timeout: 10))
        #expect(requests.remove(second) == "second")
        #expect(!requests.hasExpired(at: start.addingTimeInterval(100), timeout: 10))
    }
}
