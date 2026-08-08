import Foundation

struct FileFindMatch: Equatable, Sendable {
    let line: Int
    let location: Int
    let length: Int
}

struct FileFindResult: Equatable, Sendable {
    var matches: [FileFindMatch] = []
    var hasMore = false
}

// Search works on the same lines the Explorer draws. Keeping UTF-16 offsets makes each
// result safe to apply to NSAttributedString, including when text before it uses emoji.
enum FileFind {
    static let matchLimit = 10_000

    static func search(_ query: String, in lines: [String]) -> FileFindResult {
        guard !query.isEmpty else { return FileFindResult() }

        var matches: [FileFindMatch] = []
        for (lineNumber, line) in lines.enumerated() {
            var remaining = line.startIndex..<line.endIndex
            while let range = line.range(of: query,
                                         options: [.caseInsensitive],
                                         range: remaining) {
                if matches.count == matchLimit {
                    return FileFindResult(matches: matches, hasMore: true)
                }

                let utf16Range = NSRange(range, in: line)
                matches.append(FileFindMatch(line: lineNumber,
                                             location: utf16Range.location,
                                             length: utf16Range.length))

                // A non-empty query always advances, so adjacent matches are found while
                // overlapping ones are treated the same way as editor find controls.
                remaining = range.upperBound..<line.endIndex
            }
        }
        return FileFindResult(matches: matches)
    }
}
