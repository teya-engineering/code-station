import Foundation
import CodeStationCore

enum AgentReadiness: Equatable {
    case notInstalled
    case checking
    case signInNeeded
    case connected
    case failed

    init(installed: Bool, signedIn: Bool, checking: Bool, failed: Bool) {
        if !installed { self = .notInstalled }
        else if checking { self = .checking }
        else if failed { self = .failed }
        else { self = signedIn ? .connected : .signInNeeded }
    }

    var label: String {
        switch self {
        case .notInstalled: "Not installed"
        case .checking: "Checking…"
        case .signInNeeded: "Sign-in needed"
        case .connected: "Connected"
        case .failed: "Could not verify"
        }
    }
}
