import SwiftUI
import CodeStationCore

struct CodingAgentPicker: View {
    let title: String
    var enabled = true
    let entries: [MenuEntry]

    var body: some View {
        ActionButton(title: title, tone: .outlined, height: 38, size: 12, disclosure: true)
            .appMenu(edge: .top) { entries }
            .disabled(!enabled)
            .accessibilityLabel("Choose coding agent, \(title) selected")
    }
}

struct AgentAndBotPicker: View {
    let avatars: [AgentAvatar]
    @Binding var selectedAvatarName: String
    var sessionID: UUID? = nil
    let agentTitle: String
    var agentEnabled = true
    let agentMenu: [MenuEntry]

    var body: some View {
        HStack(spacing: 12) {
            SessionBotPicker(avatars: avatars, selectedName: $selectedAvatarName,
                             sessionID: sessionID, size: 28, showsName: true)
            CodingAgentPicker(title: agentTitle, enabled: agentEnabled, entries: agentMenu)
        }
    }
}
