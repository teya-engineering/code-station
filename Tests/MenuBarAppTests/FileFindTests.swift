import Foundation
import Testing
@testable import MenuBarApp

struct FileFindTests {

    @Test func findsEveryCaseInsensitiveMatch() {
        let result = FileFind.search("find", in: "🙂 Find find\nnothing\nFIND")

        // The emoji is two UTF-16 units, which is what the offsets count in.
        #expect(result.matches == [
            NSRange(location: 3, length: 4),
            NSRange(location: 8, length: 4),
            NSRange(location: 21, length: 4)
        ])
        #expect(!result.hasMore)
    }

    @Test func findsAdjacentButNotOverlappingMatches() {
        let result = FileFind.search("aa", in: "aaaaa")

        #expect(result.matches == [
            NSRange(location: 0, length: 2),
            NSRange(location: 2, length: 2)
        ])
    }

    @Test func matchesRunAcrossLines() {
        let result = FileFind.search("b\nc", in: "a b\nc d")

        #expect(result.matches == [NSRange(location: 2, length: 3)])
    }

    @Test func anEmptyQueryHasNoMatches() {
        #expect(FileFind.search("", in: "anything") == FileFindResult())
    }

    @Test func limitsResultsFromPathologicalQueries() {
        let text = String(repeating: "a", count: FileFind.matchLimit + 1)
        let result = FileFind.search("a", in: text)

        #expect(result.matches.count == FileFind.matchLimit)
        #expect(result.hasMore)
    }
}
