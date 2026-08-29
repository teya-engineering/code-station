import AppKit
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
    @Environment(MobileAccessController.self) private var mobileAccess
    @Environment(OrphanedWorktreeMonitor.self) private var orphanedWorktrees
    @State private var skills = SkillsManager()
    // Only ever one at a time, and a second one asked for while the first is up would
    // replace it rather than stack, so which one is showing is a single choice.
    @State private var sheet: Sheet?
    @State private var sessionCleanupError: String?
    @State private var orphanCleanupError: String?
    @State private var oldSessionDeletionAt: Date?
    @State private var dismissedAttention: Attention?

    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                AppSidebar(skills: skills,
                           tools: tools,
                           oldSessionDeletionAt: oldSessionDeletionAt,
                           onReviewOldSessions: { sheet = .oldSessions })
                Divider().overlay(Theme.hairline)
                detail
            }
            ScheduledTaskRunner()
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
        .onAppear {
            mobileAccess.setEnabled(settings.mobileAccessEnabled)
            let hasExistingWork = !store.projects.isEmpty
                || !store.workspaces.isEmpty
                || !store.sessions.isEmpty
            if settings.shouldShowOnboarding(hasExistingWork: hasExistingWork) {
                sheet = .onboarding
            }
        }
        .onChange(of: settings.mobileAccessEnabled) { _, enabled in
            mobileAccess.setEnabled(enabled)
        }
        // Opening a session answers whatever was posted about it while the app was in
        // the background.
        .onChange(of: store.selection) { _, selection in
            if case .session(let sessionID) = selection {
                AppNotifier.shared.clear(sessionID: sessionID)
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.willResignActiveNotification)) { _ in
            store.applicationWillResignActive()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            store.applicationDidBecomeActive()
        }
        .task { await resumePendingSessionRemovals() }
        .task(id: skillsRefreshRule) { await refreshSkillsAutomatically() }
        .task(id: sweepRule) { await deleteOldSessionsAutomatically() }
        .task(id: settings.autoPruneOrphanedWorktrees) { await monitorOrphanedWorktrees() }
        // Settings answers the shortcut every Mac app answers. The standard Settings
        // scene is deliberately empty, so the shortcut is caught here and opens the
        // same sheet the sidebar's menu does.
        .background(
            Button("", action: { sheet = .settings })
                .buttonStyle(.plain)
                .opacity(0)
                .keyboardShortcut(",", modifiers: .command)
        )
        // Growing the text is Cmd+ in the View menu, which AppKit only matches on a
        // shifted key. The unshifted key most people actually press is the same command,
        // so it is answered here rather than as a second line in the menu saying the same
        // thing. The menu gets first refusal on a key equivalent, so Cmd+ still runs the
        // menu item and only Cmd= reaches this.
        .background(
            Button("", action: { settings.textSize = settings.textSize.bigger })
                .buttonStyle(.plain)
                .opacity(0)
                .keyboardShortcut("=", modifiers: .command)
        )
        .environment(skills)
        .environment(\.textScale, settings.textSize.scale)
        .appOverlays()
        // A sheet is a window of its own, so the layer under it cannot draw over it; each
        // sheet gets one of its own to ask its own questions in.
        .sheet(item: $sheet) { sheet in
            sheetContent(sheet).appOverlays()
        }
    }

    // The tools and settings that open over the window. Each is a setup job rather than a
    // place to sit, which is why none of them is a pane of its own.
    enum Sheet: Identifiable {
        case servers, skills, docker, settings, dispatch, shortcuts, troubleshoot
        case oldSessions, onboarding

        var id: Self { self }
    }

    @ViewBuilder private func sheetContent(_ sheet: Sheet) -> some View {
        switch sheet {
        case .servers: ConfigManagerView()
        case .skills: SkillsView(manager: skills)
        case .docker: DockerView()
        case .settings: SettingsView(skills: skills)
        case .dispatch: DispatchView()
        case .shortcuts: ShortcutsView()
        case .troubleshoot: TroubleshootView(skills: skills)
        case .oldSessions: OldSessionsView()
        case .onboarding:
            FirstRunWizard(initialAgent: runner.agent,
                           onSiteConfigurationLoaded: applySiteConfiguration) {
                settings.completeOnboarding()
                self.sheet = nil
            }
        }
    }

    private var tools: ToolsMenuActions {
        ToolsMenuActions(configureServers: { sheet = .servers },
                         openSkills: { sheet = .skills },
                         openDocker: { sheet = .docker },
                         openDispatch: { sheet = .dispatch },
                         openShortcuts: { sheet = .shortcuts },
                         openTroubleshoot: { sheet = .troubleshoot },
                         openSettings: { sheet = .settings })
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
        if let siteDefaultsFailure = SiteDefaults.current.loadFailure {
            return Attention(title: "Site configuration needs attention",
                             message: siteDefaultsFailure)
        }
        if let sessionCleanupError {
            return Attention(title: "Session cleanup needs attention", message: sessionCleanupError)
        }
        if let orphanCleanupError {
            return Attention(title: "Worktree cleanup needs attention", message: orphanCleanupError)
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
        let policy: OldSessionCleanupPolicy
        let days: Int
    }

    private struct SkillsRefreshRule: Equatable {
        let interval: SkillsRefreshInterval
        let onboardingComplete: Bool
    }

    private var skillsRefreshRule: SkillsRefreshRule {
        SkillsRefreshRule(interval: settings.skillsRefreshInterval,
                          onboardingComplete: settings.hasCompletedOnboarding)
    }

    private var sweepRule: SweepRule {
        SweepRule(policy: settings.oldSessionCleanupPolicy, days: settings.oldSessionDays)
    }

    // Age is the only thing that makes a session sweepable, and age only moves with the
    // clock, so this runs on a timer rather than off a change in the store.
    private func deleteOldSessionsAutomatically() async {
        let rule = sweepRule
        oldSessionDeletionAt = nil
        guard rule.policy.deletesAutomatically else { return }
        var buffer = OldSessionSweep.EligibilityBuffer()

        while !Task.isCancelled {
            let now = Date()
            await OldSessionSweep.run(days: rule.days, policy: rule.policy, store: store,
                                      runner: runner, buffer: &buffer, now: now)
            guard !Task.isCancelled else { return }
            if oldSessionDeletionAt != buffer.nextReadyAt {
                oldSessionDeletionAt = buffer.nextReadyAt
            }
            do {
                try await Task.sleep(for: OldSessionSweep.monitorInterval)
            } catch {
                return
            }
        }
    }

    private func monitorOrphanedWorktrees() async {
        let automaticallyPrunes = settings.autoPruneOrphanedWorktrees
        orphanedWorktrees.setAutomaticPruningEnabled(automaticallyPrunes)
        var nextDiscoveryAt = Date.distantPast

        while !Task.isCancelled {
            let now = Date()
            if now >= nextDiscoveryAt {
                _ = await orphanedWorktrees.refresh(in: store, now: now)
                guard !Task.isCancelled else { return }
                nextDiscoveryAt = Date().addingTimeInterval(
                    OrphanedWorktreeSweep.discoveryInterval)
            }

            if automaticallyPrunes {
                let due = orphanedWorktrees.automaticPruningCandidates(now: now)
                if !due.isEmpty {
                    let result = await orphanedWorktrees.prune(due, now: now)
                    orphanCleanupError = result.failures.isEmpty
                        ? nil
                        : result.failures.map(\.message).joined(separator: "\n")
                    if !result.removed.isEmpty {
                        SessionLog.note(
                            "orphan worktree sweep pruned count=\(result.removed.count)")
                    }
                    if !result.failures.isEmpty {
                        SessionLog.note(
                            "orphan worktree sweep failed count=\(result.failures.count)")
                    }
                }
            } else {
                orphanCleanupError = nil
            }

            do {
                try await Task.sleep(for: OrphanedWorktreeSweep.monitorInterval)
            } catch {
                return
            }
        }
    }

    private func refreshSkillsAutomatically() async {
        guard settings.hasCompletedOnboarding else { return }
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

    private func applySiteConfiguration() {
        let defaults = SiteDefaults.current
        dispatch.applySiteDefaults(defaults)
        dispatchAuth.applySiteDefaults(defaults)
        shortcuts.applySiteDefaults(defaults)
    }

    private var detail: some View {
        Group {
            switch store.selection {
            case .home:
                home
            case .session(let id):
                let opening = store.sessionOpenRequest?.sessionID == id
                    ? store.sessionOpenRequest?.destination ?? .conversation
                    : .conversation
                SessionView(sessionID: id, opening: opening)
                    .id(SessionOpenRequest(sessionID: id, destination: opening))
            case .workspace(let id):
                WorkspaceDetailView(workspaceID: id)
                    .id(id)
            case nil:
                if let project = store.selectedProject {
                    // A task's folder is an implementation detail; what it needs on screen
                    // is its prompt and its runs rather than a repository dashboard.
                    if project.kind == .adHoc {
                        TaskDetailView(projectID: project.id)
                            .id(project.id)
                    } else {
                        ProjectDetailView(projectID: project.id)
                            .id(project.id)
                    }
                } else {
                    home
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var home: some View {
        HomeView(onReviewOldSessions: { sheet = .oldSessions })
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
        .surface(Theme.card, cornerRadius: 10, border: Theme.deletion.opacity(0.45))
        .shadow(color: Color.black.opacity(0.12), radius: 12, y: 4)
    }
}
