import AppKit
import SwiftUI

struct MarketplaceManagementView<AddContent: View>: View {
    @Environment(DialogPresenter.self) private var dialogs
    let manager: SkillsManager
    let failure: String?
    let dismiss: () -> Void
    @ViewBuilder let addContent: () -> AddContent
    @State private var removalFailure: String?
    @State private var status: String?
    @State private var checking: String?
    @State private var contentHeight: CGFloat = 560

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Manage marketplaces").font(.serif(20, .semibold))
                    Text("Choose the sources for your Repertoire.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                ActionButton(title: "Back to Repertoire", tone: .outlined, size: 12, action: dismiss)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .background(Theme.card)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        SectionLabel("ADDED MARKETPLACES · \(manager.marketplaceConfigurations.count)", style: .field)
                        Spacer()
                        Text("Available across your projects")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    ForEach(manager.marketplaceConfigurations, id: \.marketplace) { source in
                        sourceCard(source)
                    }
                    if manager.marketplaceConfigurations.isEmpty {
                        VStack(spacing: 7) {
                            Text("No marketplaces added").font(.serif(17, .semibold))
                            Text("Add a source below to browse and install skills.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(22)
                        .surface(Theme.card, cornerRadius: 12, border: Theme.border)
                    }
                    Text("Removing a marketplace keeps its installed skills in your agents.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if let removalFailure { SourceFailure(removalFailure) }
                    if let status {
                        Text(status).font(.system(size: 12)).foregroundStyle(Theme.accent)
                    }
                    Divider().overlay(Theme.border)
                    Text("Add a marketplace").font(.serif(17, .semibold))
                    addContent()
                    if let failure { SourceFailure(failure) }
                    Text("Repositories must contain .claude-plugin/marketplace.json. Local files must use the marketplace JSON format.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(contentHeight, 560))
            footer
        }
        .frame(width: 780)
        .background(Theme.background)
    }

    private var footer: some View {
        var footer = SheetFooter(title: "Installed skills are managed separately in Repertoire.", dismiss: dismiss)
        footer.horizontalInset = 32
        footer.verticalInset = 22
        return footer
    }

    private func sourceCard(_ source: SkillMarketplaceConfiguration) -> some View {
        HStack(spacing: 16) {
            Image(systemName: source.isLocalFile ? "doc.text" : "arrow.triangle.branch")
                .font(.system(size: 21)).foregroundStyle(Theme.accent)
                .frame(width: 42, height: 42)
                .surface(Theme.field, cornerRadius: 11)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(source.label).font(.system(size: 14, weight: .semibold))
                Text(source.source).font(.mono(11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text("\(source.isLocalFile ? "Local file" : "Git repository") · \(manager.plugins.count { $0.marketplace == source.marketplace }) packages")
                    .font(.system(size: 11)).foregroundStyle(Theme.accent)
                Text(manager.installedPackageCount(for: source.marketplace).map { "\($0) installed packages" }
                     ?? "Installation status unavailable")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { confirmRemoval(source) } label: {
                Text(checking == source.marketplace ? "Checking…" : "Remove…")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.deletion)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .surface(Theme.card, cornerRadius: 8, border: Theme.border)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
                .disabled(manager.isBusy || checking != nil)
                .accessibilityLabel("Remove \(source.label)")
        }
        .padding(20)
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
