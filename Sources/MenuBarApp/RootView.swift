import SwiftUI

// The whole window: one sidebar listing projects and their sessions. The detail pane
// belongs to the session being worked on; MCP servers are configured in a sheet on
// top of it, since that is a setup job rather than a place to sit.
struct RootView: View {
    @Environment(ConfigStore.self) private var configs
    @Environment(ProjectStore.self) private var store
    @Environment(PostmanStore.self) private var postman
    @Environment(PostmanAuthStore.self) private var postmanAuth
    @Environment(AppSettings.self) private var settings
    @Environment(ShortcutStore.self) private var shortcuts
    @State private var skills = SkillsManager()
    @State private var configuringServers = false
    @State private var showingSkills = false
    @State private var showingDocker = false
    @State private var showingSettings = false
    @State private var showingPostman = false
    @State private var showingShortcuts = false
    @State private var showingTroubleshoot = false
    @State private var reviewingOldSessions = false
    @State private var sessionCleanupError: String?

    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                AppSidebar(skills: skills,
                           onConfigureServers: { configuringServers = true },
                           onOpenSkills: { showingSkills = true },
                           onOpenDocker: { showingDocker = true },
                           onOpenSettings: { showingSettings = true },
                           onOpenPostman: { showingPostman = true },
                           onOpenShortcuts: { showingShortcuts = true },
                           onOpenTroubleshoot: { showingTroubleshoot = true },
                           onReviewOldSessions: { reviewingOldSessions = true })
                Divider().overlay(Theme.hairline)
                detail
            }
            if let attention {
                AttentionBanner(title: attention.title, message: attention.message)
                    .padding(.top, 12)
            }
        }
        .background(Theme.background)
        .task { await resumePendingSessionRemovals() }
        .task(id: settings.skillsRefreshInterval) { await refreshSkillsAutomatically() }
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
        .sheet(isPresented: $showingSkills) { SkillsView(manager: skills).appOverlays() }
        .sheet(isPresented: $showingDocker) { DockerView().appOverlays() }
        .sheet(isPresented: $showingSettings) { SettingsView().appOverlays() }
        .sheet(isPresented: $showingPostman) { PostmanView().appOverlays() }
        .sheet(isPresented: $showingShortcuts) { ShortcutsView().appOverlays() }
        .sheet(isPresented: $showingTroubleshoot) {
            TroubleshootView(skills: skills).appOverlays()
        }
        .sheet(isPresented: $reviewingOldSessions) { OldSessionsView().appOverlays() }
    }

    private var persistenceError: String? {
        [configs.loadError, configs.saveError,
         store.loadError, store.transcriptLoadErrors.values.first, store.saveError,
         postman.loadError, postman.saveError,
         postmanAuth.loadError, postmanAuth.saveError,
         shortcuts.loadError, shortcuts.saveError]
            .compactMap { $0 }
            .first
    }

    private var attention: (title: String, message: String)? {
        if let persistenceError {
            return ("Storage needs attention", persistenceError)
        }
        if let sessionCleanupError {
            return ("Session cleanup needs attention", sessionCleanupError)
        }
        return nil
    }

    private func resumePendingSessionRemovals() async {
        let failures = await SessionLifecycle.resumePendingRemovals(in: store)
        sessionCleanupError = failures.isEmpty
            ? nil
            : failures.map(\.message).joined(separator: "\n")
    }

    private func refreshSkillsAutomatically() async {
        let interval = settings.skillsRefreshInterval
        await skills.loadForNotifications(every: interval)
        guard interval != .never else { return }

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(3_600))
            } catch {
                return
            }
            await skills.refreshIfNeeded(every: interval)
        }
    }

    @ViewBuilder private var detail: some View {
        switch store.selection {
        case .home:
            HomeView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                HomeView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct AttentionBanner: View {
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.deletion)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 720, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.deletion.opacity(0.45)))
        .shadow(color: Color.black.opacity(0.12), radius: 12, y: 4)
    }
}
