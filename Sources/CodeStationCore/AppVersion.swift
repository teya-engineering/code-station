import Foundation

// A release number, such as "1.10.0" or "v2.0", compared part by part. Anything else
// (a prerelease suffix, an empty part) is not a version.
public struct AppVersion: Comparable, Equatable, Sendable {
    public let display: String
    private let components: [Int]

    public init?(_ value: String) {
        var version = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.first == "v" || version.first == "V" {
            version.removeFirst()
        }
        let pieces = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty else { return nil }

        let components = pieces.compactMap { piece -> Int? in
            guard !piece.isEmpty, piece.allSatisfy(\.isNumber) else { return nil }
            return Int(piece)
        }
        guard components.count == pieces.count else { return nil }

        display = version
        self.components = components
    }

    public static func == (left: Self, right: Self) -> Bool {
        compare(left.components, right.components) == 0
    }

    public static func < (left: Self, right: Self) -> Bool {
        compare(left.components, right.components) < 0
    }

    private static func compare(_ left: [Int], _ right: [Int]) -> Int {
        for index in 0..<max(left.count, right.count) {
            let leftPart = index < left.count ? left[index] : 0
            let rightPart = index < right.count ? right[index] : 0
            if leftPart != rightPart { return leftPart < rightPart ? -1 : 1 }
        }
        return 0
    }
}
