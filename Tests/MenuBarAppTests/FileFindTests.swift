import Testing
@testable import MenuBarApp

struct FileFindTests {

    @Test func findsEveryCaseInsensitiveMatch() {
        let result = FileFind.search("find", in: ["🙂 Find find", "nothing", "FIND"])

        #expect(result.matches == [
            FileFindMatch(line: 0, location: 3, length: 4),
            FileFindMatch(line: 0, location: 8, length: 4),
            FileFindMatch(line: 2, location: 0, length: 4)
        ])
        #expect(!result.hasMore)
    }

    @Test func findsAdjacentButNotOverlappingMatches() {
        let result = FileFind.search("aa", in: ["aaaaa"])

        #expect(result.matches == [
            FileFindMatch(line: 0, location: 0, length: 2),
            FileFindMatch(line: 0, location: 2, length: 2)
        ])
    }

    @Test func anEmptyQueryHasNoMatches() {
        #expect(FileFind.search("", in: ["anything"]) == FileFindResult())
    }

    @Test func limitsResultsFromPathologicalQueries() {
        let text = String(repeating: "a", count: FileFind.matchLimit + 1)
        let result = FileFind.search("a", in: [text])

        #expect(result.matches.count == FileFind.matchLimit)
        #expect(result.hasMore)
    }
}
