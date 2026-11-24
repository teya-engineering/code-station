import Foundation

// How many lines a shell keeps above the screen. The default is SwiftTerm's own 500, so
// nothing changes until the person asks for more. Each line costs a little memory in
// every open tab, which is what holds the top of the range down.
enum TerminalScrollback {
    static let range = 500...100_000
    // Steps from the default land on round numbers: 1,000, 1,500 and so on.
    static let step = 500
    static let fallback = 500

    static func resolved(_ lines: Int) -> Int {
        min(max(lines, range.lowerBound), range.upperBound)
    }
}
