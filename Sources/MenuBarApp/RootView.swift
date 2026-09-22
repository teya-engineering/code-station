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
    @Environment(AppUpdateChecker.self) private var appUpdates
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var skills = SkillsManager()
    @State private var commandPalette = GlobalCommandPaletteController()
    // Only ever one at a time, and a second one asked for while the first is up would
    // replace it rather than stack, so which one is showing is a single choice.
    @State private var sheet: Sheet?
    @State private var sessionCleanupError: String?
    @State private var orphanCleanupError: String?
    @State private var oldSessionDeletion: OldSessionSweep.Deletion?
    @State private var dismissedAttention: Attention?
    // An update being taken is news of its own, so putting the offer away does not also
    // hide the download it started. Each stage can be dismissed once.
    @State private var dismissedUpdateStage: AppUpdateInstallState.Stage?
    // Raised by the file being read in the detail pane while it holds Command-F.
    @State private var fileOwnsFindShortcut = false

    var body: some View {
        window
            .background(keyboardShortcuts)
            .environment(skills)
            .environment(commandPalette)
            .environment(\.textScale, settings.textSize.scale)
            .appOverlays()
            // A sheet is a window of its own, so the layer under it cannot draw over it; each
            // sheet gets one of its own to ask its own questions in.
            .sheet(item: $sheet) { sheet in
                sheetContent(sheet).appOverlays()
            }
    }

    private var layout: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                AppSidebar(skills: skills,
                           tools: tools,
                           oldSessionDeletion: oldSessionDeletion,
                           onReviewOldSessions: { sheet = .oldSessions },
                           fileOwnsFindShortcut: fileOwnsFindShortcut)
                Divider().overlay(Theme.hairline)
                detail
            }
            .onPreferenceChange(FileFindShortcutKey.self) { fileOwnsFindShortcut = $0 }
            ScheduledTaskRunner()
            AppUpdateRestartPrompt()
            VStack(spacing: 8) {
                if let attention, attention != dismissedAttention {
                    AttentionBanner(title: attention.title,
                                    message: attention.message,
                                    onDismiss: { dismissedAttention = attention })
                }
                if let release = updateOnShow {
                    AppUpdateBanner(release: release,
                                    state: appUpdates.installState,
                                    canInstallInPlace: appUpdates.canInstallInPlace,
                                    onInstall: appUpdates.installUpdate,
                                    onRestart: appUpdates.relaunch,
                                    onViewRelease: appUpdates.openReleasePage,
                                    onReadNotes: appUpdates.openReleaseNotes,
                                    onDismiss: dismissUpdateBanner)
                }
            }
            .padding(.top, 12)
            ZStack {
                if commandPalette.isPresented {
                    commandPaletteLayer
                        .transition(.opacity)
                }
            }
            // The palette stays in the view tree until its fade has finished, and while
            // it is there the backdrop still takes the click that lands on it without
            // acting on it. A closed palette is made to take no clicks at all rather than
            // relying on it being gone.
            .allowsHitTesting(commandPalette.isPresented)
            .zIndex(10)
        }
        .background(Theme.background)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14),
                   value: commandPalette.isPresented)
    }

    // The window and the work that runs for as long as it is up. Kept apart from `body`
    // because one chain of this many modifiers takes the type checker past its own
    // time limit on a slow machine.
    private var window: some View {
        layout
            .onChange(of: appUpdates.installState.stage) { _, _ in
                dismissedUpdateStage = nil
            }
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
            .task { await appUpdates.checkIfNeeded() }
            .task(id: skillsRefreshRule) { await refreshSkillsAutomatically() }
            .task(id: sweepRule) { await deleteOldSessionsAutomatically() }
            .task(id: settings.autoPruneOrphanedWorktrees) { await monitorOrphanedWorktrees() }
    }

    // Keys the window answers wherever the focus is. They are drawn as buttons because a
    // key equivalent belongs to one, and kept invisible because the window says what it
    // does elsewhere.
    private var keyboardShortcuts: some View {
        ZStack {
            // Settings answers the shortcut every Mac app answers. The standard Settings
            // scene is deliberately empty, so the shortcut is caught here and opens the
            // same sheet the sidebar's menu does.
            Button("", action: { sheet = .settings })
                .keyboardShortcut(",", modifiers: .command)
            Button("") {
                guard sheet == nil else { return }
                commandPalette.open()
            }
            .keyboardShortcut("k", modifiers: .command)
            // Cmd+[ and Cmd+] are Back and Forward on the rest of the Mac, so they retrace
            // the projects, workspaces and sessions already looked at. They are disabled
            // when the trail has no more to give, which leaves the key to anything that has
            // a better use for it.
            Button("") { store.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!canNavigateHistory || !store.canGoBack)
            Button("") { store.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!canNavigateHistory || !store.canGoForward)
            if commandPalette.isPresented {
                Button("") { commandPalette.close() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            // Growing the text is Cmd+ in the View menu, which AppKit only matches on a
            // shifted key. The unshifted key most people actually press is the same command,
            // so it is answered here rather than as a second line in the menu saying the same
            // thing. The menu gets first refusal on a key equivalent, so Cmd+ still runs the
            // menu item and only Cmd= reaches this.
            Button("", action: { settings.textSize = settings.textSize.bigger })
                .keyboardShortcut("=", modifiers: .command)
        }
        .buttonStyle(.plain)
        .opacity(0)
    }

    // Moving the window behind a sheet or the palette would leave the person looking at
    // something that no longer belongs to what is underneath it.
    private var canNavigateHistory: Bool { sheet == nil && !commandPalette.isPresented }

    private var commandPaletteLayer: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.black.opacity(0.17)
                    .contentShape(Rectangle())
                    .onTapGesture { commandPalette.close() }

                GlobalCommandPalette(openSettings: {
                    commandPalette.close()
                    sheet = .settings
                })
                .frame(width: min(720, geometry.size.width - 64),
                       height: min(620, geometry.size.height - 64))
                .padding(.top, 28)
            }
        }
        .ignoresSafeArea()
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
        case .oldSessions:
            OldSessionsView(sessions: OldSessions.reviewable(days: settings.oldSessionDays,
                                                             store: store, runner: runner))
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

    // Before anything is taken the banner is an announcement, which a person can put away
    // for good. From the first click it reports on work under way, which stays on offer
    // even for a version whose announcement was dismissed earlier.
    private var updateOnShow: AppUpdateRelease? {
        let stage = appUpdates.installState.stage
        guard stage != dismissedUpdateStage else { return nil }
        return stage == .idle ? appUpdates.announcedRelease : appUpdates.availableRelease
    }

    private func dismissUpdateBanner() {
        let stage = appUpdates.installState.stage
        if stage == .idle {
            appUpdates.dismissAnnouncement()
        } else {
            dismissedUpdateStage = stage
        }
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
        oldSessionDeletion = nil
        guard rule.policy.deletesAutomatically else { return }
        var buffer = OldSessionSweep.EligibilityBuffer()

        while !Task.isCancelled {
            let now = Date()
            await OldSessionSweep.run(days: rule.days, policy: rule.policy, store: store,
                                      runner: runner, buffer: &buffer, now: now)
            guard !Task.isCancelled else { return }
            if oldSessionDeletion != buffer.deletion {
                oldSessionDeletion = buffer.deletion
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
                    let result = await orphanedWorktrees.prune(due, in: store, now: now)
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
            .hoverLift(amount: Motion.smallLift)
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

// Draws nothing. It is here to ask about restarting the moment an update finishes
// installing, wherever in the app the person happens to be and whether or not the banner
// that started it is still on screen.
private struct AppUpdateRestartPrompt: View {
    @Environment(AppUpdateChecker.self) private var appUpdates
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: appUpdates.installState) { _, state in
                guard state == .ready, let release = appUpdates.availableRelease else { return }
                dialogs.show(.confirm("Teya Code Station \(release.version) is ready",
                                      message: message,
                                      action: "Restart now",
                                      kind: .primary,
                                      cancel: "Later",
                                      handler: appUpdates.relaunch))
            }
    }

    private var message: String {
        let busy = store.sessions.filter { runner.state($0.id).isBusy }.count
        guard busy > 0 else { return "Restarting the app finishes the update." }
        return "Restarting the app finishes the update and stops "
            + "\(counted(busy, "session")) still running."
    }
}

// One banner for the whole life of an update: the offer, the download, and the restart
// that finishes it. They are the same piece of news at different stages, so a person who
// clicks Update watches the row they clicked rather than losing it and hunting for
// progress somewhere else.
private struct AppUpdateBanner: View {
    let release: AppUpdateRelease
    let state: AppUpdateInstallState
    let canInstallInPlace: Bool
    let onInstall: () -> Void
    let onRestart: () -> Void
    let onViewRelease: () -> Void
    let onReadNotes: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                if case .downloading(let fraction) = state {
                    progress(fraction)
                } else {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            buttons
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
            .hoverLift(amount: Motion.smallLift)
            .appTooltip("Dismiss")
            .accessibilityLabel("Dismiss update \(release.version)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 720, alignment: .leading)
        .surface(Theme.card, cornerRadius: 10, border: tint.opacity(0.42))
        .shadow(color: Color.black.opacity(0.12), radius: 12, y: 4)
    }

    @ViewBuilder
    private var buttons: some View {
        switch state {
        case .idle:
            if canInstallInPlace {
                ActionButton(title: "Update", tone: .green, height: 28, size: 11,
                             action: onInstall)
                ActionButton(title: "Notes", tone: .outlined, height: 28, size: 11,
                             action: onReadNotes)
            } else {
                ActionButton(title: "View release", tone: .outlined, height: 28, size: 11,
                             action: onViewRelease)
            }
        case .downloading:
            EmptyView()
        case .installing:
            ProgressView().controlSize(.small)
        case .ready:
            ActionButton(title: "Restart now", tone: .green, height: 28, size: 11,
                         action: onRestart)
        case .failed:
            ActionButton(title: "Try again", tone: .outlined, height: 28, size: 11,
                         action: onInstall)
            ActionButton(title: "Download", tone: .outlined, height: 28, size: 11,
                         action: onViewRelease)
        }
    }

    private func progress(_ fraction: Double) -> some View {
        HStack(spacing: 7) {
            GeometryReader { proxy in
                Capsule().fill(Theme.field)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Theme.accent)
                            .frame(width: proxy.size.width * max(0.02, min(1, fraction)))
                    }
                    .overlay(Capsule().stroke(Theme.border))
            }
            .frame(width: 160, height: 5)
            Text("\(Int(fraction * 100))%")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(height: 13)
    }

    private var icon: String {
        switch state {
        case .ready: "arrow.clockwise.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .idle, .downloading, .installing: "arrow.down.circle.fill"
        }
    }

    private var tint: Color {
        if case .failed = state { return Theme.deletion }
        return Theme.accent
    }

    private var title: String {
        switch state {
        case .idle: "Teya Code Station \(release.version) is available"
        case .downloading: "Downloading Teya Code Station \(release.version)"
        case .installing: "Installing Teya Code Station \(release.version)"
        case .ready: "Teya Code Station \(release.version) is ready"
        case .failed: "The update could not be installed"
        }
    }

    private var message: String {
        switch state {
        case .idle where canInstallInPlace:
            "Download and install it here, then restart when it suits you."
        case .idle:
            "View the release notes and download the signed update from GitHub."
        case .downloading:
            ""
        case .installing:
            "Checking the signature and swapping the app."
        case .ready:
            "Restart to finish. Anything still running will be stopped."
        case .failed(let reason):
            reason
        }
    }
}
