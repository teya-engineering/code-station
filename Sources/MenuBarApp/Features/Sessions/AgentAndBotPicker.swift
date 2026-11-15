import SwiftUI

struct CodingAgentPicker: View {
    let agent: AgentKind?
    var enabled = true
    var fills = false
    let entries: [MenuEntry]

    private var title: String { agent?.title ?? "Unavailable" }

    var body: some View {
        ActionButton(title: title, tone: .outlined, height: ControlHeight.xl, size: Typography.Size.detail,
                     icon: agent?.symbol, disclosure: true, fills: fills)
            .appMenu(edge: .top, matchWidth: fills) { entries }
            .disabled(!enabled)
            .accessibilityLabel("Choose coding agent, \(title) selected")
            .motion(Motion.control, value: agent)
    }
}

struct AgentAndBotPicker: View {
    let avatars: [AgentAvatar]
    @Binding var selectedAvatarName: String
    var sessionID: UUID? = nil
    let agent: AgentKind?
    var agentEnabled = true
    let agentMenu: [MenuEntry]

    var body: some View {
        HStack(spacing: Space.lg) {
            SessionBotPicker(avatars: avatars, selectedName: $selectedAvatarName,
                             sessionID: sessionID, size: ControlHeight.md, showsName: true)
            CodingAgentPicker(agent: agent, enabled: agentEnabled, entries: agentMenu)
        }
    }
}
