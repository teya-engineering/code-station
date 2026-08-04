import SwiftUI

// The whole window: one sidebar listing projects and their sessions. The detail pane
// belongs to the session being worked on; MCP servers are configured in a sheet on
// top of it, since that is a setup job rather than a place to sit.
struct RootView: View {
    @Environment(ProjectStore.self) private var store
    @State private var configuringServers = false
    @State private var showingDocker = false
    @State private var showingSettings = false

    var body: some View {
        HStack(spacing: 0) {
            AppSidebar(onConfigureServers: { configuringServers = true },
                       onOpenDocker: { showingDocker = true },
                       onOpenSettings: { showingSettings = true })
            Divider().overlay(Theme.hairline)
            detail
        }
        .background(Theme.background)
        // Dialogs and menus are drawn here rather than where they are asked for, so a
        // question from the sidebar is still centred over the whole window and a menu
        // can spill past the panel it was opened from.
        .overlay { ContextMenuHost() }
        .overlay { DialogHost() }
        .sheet(isPresented: $configuringServers) { ConfigManagerView() }
        .sheet(isPresented: $showingDocker) { DockerView() }
        .sheet(isPresented: $showingSettings) { SettingsView() }
    }

    @ViewBuilder private var detail: some View {
        switch store.selection {
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
