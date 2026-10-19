import Foundation

// A place the app can be pointed at. The store keeps what is open in two properties,
// because choosing a project is not the same as opening something inside it. This names
// both as one value, so a trail of them can be walked back and forward.
public enum NavigationPlace: Hashable {
    case home
    case project(UUID)
    case session(UUID)
    case workspace(UUID)
}

// The trail of places visited, walked with Cmd+[ and Cmd+]. It works the way Back and
// Forward do in a browser: stepping back leaves the places ahead within reach, and
// arriving somewhere new from the middle of the trail drops whatever was ahead of it.
//
// Places that have left the app are dropped as the trail is walked past them, so a
// deleted session never comes back under the cursor.
//
// Each front end keeps a trail of its own, as each keeps its own selection: the GUI's in
// `ProjectNavigation`, the TUI's in its app.
public struct NavigationHistory: Equatable {
    // Long enough to cover a day of moving around, short enough that the trail cannot
    // grow without end.
    static let limit = 100

    public private(set) var back: [NavigationPlace] = []
    public private(set) var current: NavigationPlace?
    public private(set) var forward: [NavigationPlace] = []

    public init() {}

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    // Arriving somewhere. Landing on the place already showing is not a move, so it
    // leaves the trail alone: opening the same session twice must not fill the trail
    // with copies of it.
    public mutating func visit(_ place: NavigationPlace) {
        guard place != current else { return }
        if let current { back.append(current) }
        current = place
        forward.removeAll()
        if back.count > Self.limit { back.removeFirst(back.count - Self.limit) }
    }

    public mutating func goBack(reachable: (NavigationPlace) -> Bool) -> NavigationPlace? {
        while let previous = back.popLast() {
            guard reachable(previous) else { continue }
            if let current { forward.append(current) }
            current = previous
            return previous
        }
        return nil
    }

    public mutating func goForward(reachable: (NavigationPlace) -> Bool) -> NavigationPlace? {
        while let next = forward.popLast() {
            guard reachable(next) else { continue }
            if let current { back.append(current) }
            current = next
            return next
        }
        return nil
    }
}
