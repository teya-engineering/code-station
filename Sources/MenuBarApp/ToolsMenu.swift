import SwiftUI

// The setup and utility screens folded behind one control, so the screens that offer it
// keep belonging to the work rather than to the app. Each card carries its state under
// the name - the count, the environment, whether the model server is up - so folding them
// away costs a click but not the glance.
//
// Two places offer it: the cog closing the sidebar, and Home. They wear different labels
// around the same menu, which is why the entries are built here instead of in either.
struct ToolsMenuActions {
    let configureServers: () -> Void
    let openSkills: () -> Void
    let openDocker: () -> Void
    let openDispatch: () -> Void
    let openShortcuts: () -> Void
    let openTroubleshoot: () -> Void
    let openSettings: () -> Void
}

extension View {
    func toolsMenu(_ actions: ToolsMenuActions,
                   skills: SkillsManager,
                   edge: VerticalEdge = .bottom) -> some View {
        modifier(ToolsMenuModifier(actions: actions, skills: skills, edge: edge))
    }
}

private struct ToolsMenuModifier: ViewModifier {
    let actions: ToolsMenuActions
    let skills: SkillsManager
    let edge: VerticalEdge

    @Environment(ConfigStore.self) private var configs
    @Environment(DockerService.self) private var docker
    @Environment(DispatchAuthStore.self) private var dispatchAuth
    @Environment(ShortcutStore.self) private var shortcuts
    @Environment(AppUpdateChecker.self) private var appUpdates

    func body(content: Content) -> some View {
        content.appMenu(edge: edge, refreshOnOpen: { await docker.refresh() }) { entries }
    }

    private var entries: [MenuEntry] {
        var entries: [MenuEntry] = [
            .cards([
                MenuCardItem(label: "MCP servers", icon: "server.rack",
                             detail: "\(configs.servers.count)",
                             handler: actions.configureServers),
                MenuCardItem(label: "Skills", icon: "sparkles",
                             showsUpdate: skills.updateCount > 0,
                             detail: "Claude + Codex", handler: actions.openSkills),
                MenuCardItem(label: "Docker", icon: "shippingbox.fill",
                             detail: dockerDetail.text, detailColour: dockerDetail.colour,
                             handler: actions.openDocker),
                MenuCardItem(label: "Dispatch", icon: "paperplane.fill",
                             detail: dispatchAuth.active.name,
                             detailColour: dispatchAuth.active.accent,
                             handler: actions.openDispatch),
                MenuCardItem(label: "Shortcuts", icon: "bolt.fill",
                             detail: shortcutsDetail.text, detailColour: shortcutsDetail.colour,
                             handler: actions.openShortcuts),
                MenuCardItem(label: "Troubleshoot", icon: "stethoscope",
                             detail: "Agent diagnosis",
                             handler: actions.openTroubleshoot)
            ])
        ]
        if let release = appUpdates.availableRelease {
            entries.append(.separator)
            entries.append(.item("Teya Code Station \(release.version)",
                                 icon: "arrow.down.circle",
                                 showsUpdate: true,
                                 subtitle: "A new version is available",
                                 action: appUpdates.openReleasePage))
        }
        entries.append(.separator)
        entries.append(.item("Settings", detail: "⌘,", action: actions.openSettings))
        return entries
    }

    private var dockerDetail: (text: String, colour: Color?) {
        let containers = docker.containers
        guard containers.hasLoaded else { return ("checking…", nil) }
        guard containers.failure == nil else { return ("unavailable", Theme.deletion) }
        guard !containers.items.isEmpty else { return ("none running", nil) }
        return ("\(containers.items.count) running", Theme.addition)
    }

    // The card speaks for the screen it opens, which is the Mac's own list. A project's
    // shortcuts report on the strip inside its sessions instead.
    private var shortcutsDetail: (text: String, colour: Color?) {
        let mac = shortcuts.macShortcuts
        let running = shortcuts.runningCount(of: mac)
        if running > 0 { return ("\(running) running", Theme.addition) }
        let failed = shortcuts.failureCount(of: mac)
        if failed > 0 { return ("\(failed) failed", Theme.deletion) }
        return ("\(mac.count) saved", nil)
    }
}
