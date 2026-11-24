import Foundation

// Each shell keeps its own history in memory, so the upper limit applies to every tab.
enum TerminalScrollback {
    static let range = 500...100_000
    static let step = 500
    static let fallback = 10_000

    static func resolved(_ lines: Int) -> Int {
        min(max(lines, range.lowerBound), range.upperBound)
    }
}
