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
            VStack(alignment: .leading, spacing: 14) {
                Text("Your marketplaces").scaledSerif(22)
                Text("Sources you trust, available across your projects.").scaledText(12).foregroundStyle(.secondary)
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
                    .scaledText(12).foregroundStyle(.secondary).padding(.vertical, 12)
                if let removalFailure { SourceFailure(removalFailure, lineLimit: nil) }
                if let status { Text(status).scaledText(12).foregroundStyle(Theme.accent) }
                Divider().overlay(Theme.border)
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Check for skill updates").scaledText(13, .semibold)
                        Text("Refresh marketplace versions automatically.").scaledText(12).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ForEach(SkillsRefreshInterval.allCases) { interval in
                        ChoicePill(title: interval == .never ? "Manually" : interval.title,
                                   selected: settings.skillsRefreshInterval == interval) {
                            settings.skillsRefreshInterval = interval
                        }
                    }
                }.padding(.vertical, 12)
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sourceCard(_ source: SkillMarketplaceConfiguration) -> some View {
        HStack(spacing: 16) {
            Image(systemName: source.isLocalFile ? "doc.text" : "arrow.triangle.branch")
                .font(.system(size: 21)).foregroundStyle(Theme.accent)
                .frame(width: 42, height: 42)
                .surface(Theme.field, cornerRadius: 11)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(source.label).scaledText(14, .semibold)
                    Text(source.isLocalFile ? "Local file" : "Git repository")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .padding(4).background(Theme.field, in: RoundedRectangle(cornerRadius: 5))
                }
                Text(source.source).font(.mono(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(source.source)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(manager.plugins.count { $0.marketplace == source.marketplace }) packages")
                Text(manager.installedPackageCount(for: source.marketplace).map { "\($0) installed" }
                     ?? "Status unavailable").foregroundStyle(.secondary)
            }.font(.system(size: 11))
            ActionButton(title: "Browse packages", tone: .outlined, height: 32, size: 12) { browse(source) }
            Button { confirmRemoval(source) } label: {
                Text(checking == source.marketplace ? "Checking…" : "Remove…")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.deletion)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .surface(Theme.card, cornerRadius: 8, border: Theme.deletion.opacity(0.3))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
                .disabled(manager.isBusy || checking != nil)
                .accessibilityLabel("Remove \(source.label)")
        }
        .padding(18)
        .surface(Theme.card, cornerRadius: 12, border: Theme.border)
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
