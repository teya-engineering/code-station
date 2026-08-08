import SwiftUI

// The whole window: one sidebar listing projects and their sessions. The detail pane
// belongs to the session being worked on; MCP servers are configured in a sheet on
// top of it, since that is a setup job rather than a place to sit.
struct RootView: View {
    @Environment(ProjectStore.self) private var store
    @State private var configuringServers = false
    @State private var showingSkills = false
    @State private var showingDocker = false
    @State private var showingSettings = false
    @State private var showingPostman = false
    @State private var showingAI = false
    @State private var showingTroubleshoot = false
    @State private var reviewingOldSessions = false

    var body: some View {
        HStack(spacing: 0) {
            AppSidebar(onConfigureServers: { configuringServers = true },
                       onOpenSkills: { showingSkills = true },
                       onOpenDocker: { showingDocker = true },
                       onOpenSettings: { showingSettings = true },
                       onOpenPostman: { showingPostman = true },
                       onOpenAI: { showingAI = true },
                       onOpenTroubleshoot: { showingTroubleshoot = true },
                       onReviewOldSessions: { reviewingOldSessions = true })
            Divider().overlay(Theme.hairline)
            detail
        }
        .background(Theme.background)
        // Settings answers the shortcut every Mac app answers. The standard Settings
        // scene is deliberately empty, so the shortcut is caught here and opens the
        // same sheet the sidebar's menu does.
        .background(
            Button("", action: { showingSettings = true })
                .buttonStyle(.plain)
                .opacity(0)
                .keyboardShortcut(",", modifiers: .command)
        )
        .appOverlays()
        // A sheet is a window of its own, so the layer under it cannot draw over it; each
        // sheet gets one of its own to ask its own questions in.
        .sheet(isPresented: $configuringServers) { ConfigManagerView().appOverlays() }
        .sheet(isPresented: $showingSkills) { SkillsView().appOverlays() }
        .sheet(isPresented: $showingDocker) { DockerView().appOverlays() }
        .sheet(isPresented: $showingSettings) { SettingsView().appOverlays() }
        .sheet(isPresented: $showingPostman) { PostmanView().appOverlays() }
        .sheet(isPresented: $showingAI) { AIView().appOverlays() }
        .sheet(isPresented: $showingTroubleshoot) { TroubleshootView().appOverlays() }
        .sheet(isPresented: $reviewingOldSessions) { OldSessionsView().appOverlays() }
    }

    @ViewBuilder private var detail: some View {
        switch store.selection {
        case .session(let id):
            SessionView(sessionID: id)
                .id(id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .workspace(let id):
            WorkspaceDetailView(workspaceID: id)
                .id(id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case nil:
            if let project = store.selectedProject {
                ProjectDetailView(projectID: project.id)
                    .id(project.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                WelcomeView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
