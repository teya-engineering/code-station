import SwiftUI

// The whole window: one sidebar listing projects and their sessions, plus an MCP
// Servers entry that hands the detail pane over to the original config manager.
struct RootView: View {
    @Environment(ProjectStore.self) private var store

    var body: some View {
        HStack(spacing: 0) {
            AppSidebar()
            Divider().overlay(Theme.hairline)
            detail
        }
        .background(Theme.background)
    }

    @ViewBuilder private var detail: some View {
        switch store.selection {
        case .mcpServers:
            ConfigManagerView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .session(let id):
            SessionView(sessionID: id)
                .id(id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case nil:
            WelcomeView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct WelcomeView: View {
    @Environment(ProjectStore.self) private var store

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.split.2x1")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(store.projects.isEmpty ? "Add a project to get started" : "Select a session")
                .font(.serif(22))
            if store.projects.isEmpty {
                Text("A project is a folder on your Mac. Claude Code runs in that folder itself, so its changes land straight in your working tree.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
        }
    }
}
