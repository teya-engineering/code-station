import SwiftUI

// The whole window: one sidebar listing projects and their sessions. The detail pane
// belongs to the session being worked on; MCP servers are configured in a sheet on
// top of it, since that is a setup job rather than a place to sit.
struct RootView: View {
    @Environment(ConfigStore.self) private var configs
    @Environment(ProjectStore.self) private var store
    @Environment(DispatchStore.self) private var dispatch
    @Environment(DispatchAuthStore.self) private var dispatchAuth
    @Environment(AppSettings.self) private var settings
    @Environment(ShortcutStore.self) private var shortcuts
    @Environment(SessionRunner.self) private var runner
    @State private var skills = SkillsManager()
    @State private var configuringServers = false
    @State private var showingSkills = false
    @State private var showingDocker = false
    @State private var showingSettings = false
    @State private var showingDispatch = false
    @State private var showingShortcuts = false
    @State private var showingTroubleshoot = false
    @State private var reviewingOldSessions = false
    @State private var sessionCleanupError: String?
    @State private var dismissedAttention: Attention?

    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                AppSidebar(skills: skills,
                           tools: tools,
                           onReviewOldSessions: { reviewingOldSessions = true })
                Divider().overlay(Theme.hairline)
                detail
            }
            if let attention, attention != dismissedAttention {
                AttentionBanner(title: attention.title,
                                message: attention.message,
                                onDismiss: { dismissedAttention = attention })
                    .padding(.top, 12)
            }
        }
        .background(Theme.background)
        .onChange(of: attention) { oldValue, newValue in
            if oldValue != newValue { dismissedAttention = nil }
        }
        .task { await resumePendingSessionRemovals() }
        .task(id: settings.skillsRefreshInterval) { await refreshSkillsAutomatically() }
        .task(id: sweepRule) { await deleteOldSessionsAutomatically() }
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
        .sheet(isPresented: $showingDispatch) { DispatchView().appOverlays() }
        .sheet(isPresented: $showingShortcuts) { ShortcutsView().appOverlays() }
        .sheet(isPresented: $showingTroubleshoot) {
            TroubleshootView(skills: skills).appOverlays()
        }
        .sheet(isPresented: $reviewingOldSessions) { OldSessionsView().appOverlays() }
    }

    private var tools: ToolsMenuActions {
        ToolsMenuActions(configureServers: { configuringServers = true },
                         openSkills: { showingSkills = true },
                         openDocker: { showingDocker = true },
                         openDispatch: { showingDispatch = true },
                         openShortcuts: { showingShortcuts = true },
                         openTroubleshoot: { showingTroubleshoot = true },
                         openSettings: { showingSettings = true })
    }

    private var persistenceError: String? {
        [configs.loadError, configs.saveError,
         store.loadError, store.transcriptLoadErrors.values.first, store.saveError,
         dispatch.loadError, dispatch.saveError,
         dispatchAuth.loadError, dispatchAuth.saveError,
         shortcuts.loadError, shortcuts.saveError]
            .compactMap { $0 }
            .first
    }

    private var attention: Attention? {
        if let persistenceError {
            return Attention(title: "Storage needs attention", message: persistenceError)
        }
        if let sessionCleanupError {
            return Attention(title: "Session cleanup needs attention", message: sessionCleanupError)
        }
        return nil
    }

    private func resumePendingSessionRemovals() async {
        let failures = await SessionLifecycle.resumePendingRemovals(in: store)
        sessionCleanupError = failures.isEmpty
            ? nil
            : failures.map(\.message).joined(separator: "\n")
    }

    private struct SweepRule: Equatable {
        let enabled: Bool
        let days: Int
    }

    private var sweepRule: SweepRule {
        SweepRule(enabled: settings.autoDeleteOldSessions, days: settings.oldSessionDays)
    }

    // Age is the only thing that makes a session sweepable, and age only moves with the
    // clock, so this runs on a timer rather than off a change in the store.
    private func deleteOldSessionsAutomatically() async {
        let rule = sweepRule
        guard rule.enabled else { return }

        while !Task.isCancelled {
            await OldSessionSweep.run(days: rule.days, store: store, runner: runner)
            do {
                try await Task.sleep(for: OldSessionSweep.interval)
            } catch {
                return
            }
        }
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
            home
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
                // A task's folder is an implementation detail; what it needs on screen is
                // its prompt and its runs rather than a repository dashboard.
                if project.kind == .adHoc {
                    TaskDetailView(projectID: project.id)
                        .id(project.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProjectDetailView(projectID: project.id)
                        .id(project.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                home
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var home: some View {
        HomeView(onReviewOldSessions: { reviewingOldSessions = true })
    }
}

private struct Attention: Equatable {
    let title: String
    let message: String
}

private struct AttentionBanner: View {
    let title: String
    let message: String
    let onDismiss: () -> Void

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
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Theme.field))
                    .overlay(Circle().stroke(Theme.border))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .appTooltip("Dismiss")
            .accessibilityLabel("Dismiss \(title)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 720, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.deletion.opacity(0.45)))
        .shadow(color: Color.black.opacity(0.12), radius: 12, y: 4)
    }
}
