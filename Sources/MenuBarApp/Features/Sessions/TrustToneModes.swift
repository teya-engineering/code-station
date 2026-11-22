import Foundation

extension TrustTone {
    init(_ mode: PermissionMode) {
        self = switch mode {
        case .manual: .asksEverything
        case .auto: .risky
        case .acceptEdits: .allowsEdits
        case .plan: .plans
        }
    }

    init(_ mode: CodexSandboxMode) {
        self = switch mode {
        case .workspaceWrite: .risky
        case .approveForMe: .allowsEdits
        case .fullAccess: .unrestricted
        }
    }

    init(_ mode: CopilotAccessMode) {
        self = switch mode {
        case .workspace: .allowsEdits
        case .fullAccess: .unrestricted
        }
    }
}
