import Foundation

struct DispatchWorkbenchState: Codable, Equatable {
    enum RequestTab: String, Codable, CaseIterable, Identifiable {
        case parameters = "Parameters", headers = "Headers", body = "Body", auth = "Auth"
        var id: Self { self }
    }

    enum ResponseTab: String, Codable, CaseIterable, Identifiable {
        case body = "Body", table = "Table", headers = "Headers"
        var id: Self { self }
    }

    var selectedID: UUID?
    var requestTab = RequestTab.parameters
    var responseTab = ResponseTab.body
    var responseHeight: CGFloat = 270
    var responseExpanded = false
}

enum DispatchSplitLayout {
    static let handleHeight: CGFloat = 10
    static let minimumEditorHeight: CGFloat = 110
    // Before the first send the response is one line, so the request has the room.
    static let closedHeight = DispatchMetrics.responseHeaderHeight

    static func responseHeight(_ preferred: CGFloat, available: CGFloat) -> CGFloat {
        let maximum = max(0, available - minimumEditorHeight - handleHeight)
        return min(maximum, max(min(120, maximum), preferred.isFinite ? preferred : 300))
    }
}
