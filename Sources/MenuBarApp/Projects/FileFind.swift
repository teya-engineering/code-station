import Foundation

struct FileFindResult: Equatable, Sendable {
    var matches: [NSRange] = []
    var hasMore = false
}

// Search over the whole document rather than line by line. Ranges are UTF-16 offsets into
// the text, which is what the text view wants back when a match has to be coloured in or
// scrolled to, including when the text before it uses emoji.
enum FileFind {
    static let matchLimit = 10_000

    static func search(_ query: String, in text: String) -> FileFindResult {
        guard !query.isEmpty else { return FileFindResult() }

        var matches: [NSRange] = []
        var remaining = text.startIndex..<text.endIndex
        while let range = text.range(of: query, options: [.caseInsensitive], range: remaining) {
            if matches.count == matchLimit {
                return FileFindResult(matches: matches, hasMore: true)
            }
            matches.append(NSRange(range, in: text))

            // A non-empty query always advances, so adjacent matches are found while
            // overlapping ones are treated the same way as editor find controls.
            remaining = range.upperBound..<text.endIndex
        }
        return FileFindResult(matches: matches)
    }
}
