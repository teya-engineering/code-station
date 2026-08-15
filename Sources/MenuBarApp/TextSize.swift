import SwiftUI

// How large the text a session is read through is drawn: the transcript, the tool output
// under it, inline diffs and the terminal. The chrome around all of that keeps its own
// sizes. Headers, status bands and controls are built to fixed heights, so growing their
// labels would crop them rather than make anything easier to read.
enum TextSize: String, CaseIterable, Identifiable {
    case small
    case standard
    case large
    case larger

    var id: String { rawValue }

    var label: String {
        switch self {
        case .small: "Small"
        case .standard: "Default"
        case .large: "Large"
        case .larger: "Larger"
        }
    }

    // What each size multiplies a drawn point size by. Standard is exactly 1, so the app
    // looks untouched until someone asks for something else.
    var scale: CGFloat {
        switch self {
        case .small: 0.9
        case .standard: 1
        case .large: 1.15
        case .larger: 1.3
        }
    }

    // The step keys stop at the ends of the scale rather than wrapping, so holding one
    // down settles on the largest or smallest size instead of jumping back past the middle.
    var bigger: TextSize { Self.allCases[min(index + 1, Self.allCases.count - 1)] }
    var smaller: TextSize { Self.allCases[max(index - 1, 0)] }

    private var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

// The scale in force for whatever is on screen. It travels in the environment so a view
// deep inside the transcript can size its own text without every view between here and
// there having to pass it down.
private struct TextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var textScale: CGFloat {
        get { self[TextScaleKey.self] }
        set { self[TextScaleKey.self] = newValue }
    }
}
