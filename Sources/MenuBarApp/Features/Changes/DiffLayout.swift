import CodeStationCore

enum DiffLayout: CaseIterable {
    case unified
    case sideBySide

    var title: String {
        switch self {
        case .unified: "Unified diff"
        case .sideBySide: "Side by side"
        }
    }
}
