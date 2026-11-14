import AppKit
import SwiftUI

struct MarketplaceManagementView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DialogPresenter.self) private var dialogs
    let manager: SkillsManager
    let add: () -> Void
    let browse: (SkillMarketplaceConfiguration) -> Void
    @State private var removalFailure: String?
    @State private var status: String?
    @State private var checking: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                Text("Your marketplaces").scaledSerif(Typography.Size.display)
                Text("Sources you trust, available across your projects.").scaledText(Typography.Size.detail).foregroundStyle(.secondary)
                if let notice = manager.catalogueNotice { SourceFailure(notice, lineLimit: nil) }
                ForEach(manager.marketplaceConfigurations, id: \.marketplace) { source in
                    sourceCard(source)
                }
                if manager.marketplaceConfigurations.isEmpty {
                    PaneMessage(icon: "shippingbox", title: "No marketplaces yet",
                                detail: "Add a Git repository or local JSON file to get started.") {
                        ActionButton(title: "Add marketplace", tone: .dark, action: add)
                    }
                }
                Text("Removing a source keeps its installed packages and agent settings. Add the source again to manage those packages here.")
                    .scaledText(Typography.Size.detail).foregroundStyle(.secondary).padding(.vertical, Space.lg)
                if let removalFailure { SourceFailure(removalFailure, lineLimit: nil) }
                if let status { Text(status).scaledText(Typography.Size.detail).foregroundStyle(Theme.accent) }
                Divider().overlay(Theme.border)
                HStack {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Check for skill updates").scaledText(Typography.Size.body, .semibold)
                        Text("Refresh marketplace versions automatically.").scaledText(Typography.Size.detail).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ForEach(SkillsRefreshInterval.allCases) { interval in
                        ChoicePill(title: interval == .never ? "Manually" : interval.title,
                                   selected: settings.skillsRefreshInterval == interval) {
                            settings.skillsRefreshInterval = interval
                        }
                    }
                }.padding(.vertical, Space.lg)
            }
            .padding(Space.xxxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sourceCard(_ source: SkillMarketplaceConfiguration) -> some View {
        HStack(spacing: Space.xl) {
            Image(systemName: source.isLocalFile ? "doc.text" : "arrow.triangle.branch")
                .font(.system(size: 21)).foregroundStyle(Theme.accent)
                .frame(width: 42, height: 42)
                .surface(Theme.field, cornerRadius: Radius.floating)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack {
                    Text(source.label).scaledText(Typography.Size.body, .semibold)
                    Text(source.isLocalFile ? "Local file" : "Git repository")
                        .font(Font.system(size: Typography.Size.micro)).foregroundStyle(.secondary)
                        .padding(Space.xs).background(Theme.field, in: RoundedRectangle(cornerRadius: Radius.inset))
                }
                Text(source.source).font(Typography.data)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(source.source)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("\(manager.plugins.count { $0.marketplace == source.marketplace }) packages")
                Text(manager.installedPackageCount(for: source.marketplace).map { "\($0) installed" }
                     ?? "Status unavailable").foregroundStyle(.secondary)
            }.font(Typography.caption)
            ActionButton(title: "Browse packages", tone: .outlined, height: ControlHeight.lg, size: Typography.Size.detail) { browse(source) }
            Button { confirmRemoval(source) } label: {
                Text(checking == source.marketplace ? "Checking…" : "Remove…")
                    .font(Typography.label)
                    .foregroundStyle(Theme.deletion)
                    .padding(.horizontal, Space.lg)
                    .frame(height: 32)
                    .surface(Theme.card, cornerRadius: Radius.control, border: Theme.deletion.opacity(0.3))
                    .contentShape(RoundedRectangle(cornerRadius: Radius.control))
            }
            .buttonStyle(.plain)
                .disabled(manager.isBusy || checking != nil)
                .accessibilityLabel("Remove \(source.label)")
        }
        .padding(Space.xl)
        .surface(Theme.card, cornerRadius: Radius.floating, border: Theme.border)
    }

    private func confirmRemoval(_ source: SkillMarketplaceConfiguration) {
        checking = source.marketplace
        removalFailure = nil
        status = nil
        Task {
            await manager.checkInstallationsForRemoval()
            checking = nil
            let count = manager.installedPackageCount(for: source.marketplace)
            dialogs.show(.impact("Remove marketplace?",
                message: "Disconnect \(source.label) from Code Station.\n\(source.source)",
                rows: [
                    .init(title: "Marketplace removed from Repertoire",
                          detail: "Its packages will no longer appear here. Code Station will stop checking this source for updates."),
                    .init(title: count.map { "\($0) installed packages stay installed" } ?? "Installation status unavailable",
                          detail: "Removal will not uninstall skills. Add this source again to manage them here. Agent-controlled updates are unaffected.", kept: true),
                    .init(title: source.isLocalFile ? "Local file and agent settings stay intact" : "Repository and agent settings stay intact",
                          detail: "The original source and marketplace registrations in your agents will not be changed.", kept: true)
                ], warning: "You can add this marketplace again at any time.", action: "Remove marketplace") {
                    do {
                        try manager.removeMarketplace(source)
                        let message = "\(source.label) removed. Installed skills kept."
                        status = message
                        if let window = NSApp.keyWindow {
                            NSAccessibility.post(element: window, notification: .announcementRequested,
                                                 userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
                        }
                    } catch {
                        removalFailure = error.localizedDescription
                    }
                })
        }
    }
}
