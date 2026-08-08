import SwiftUI

struct SkillsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var manager = SkillsManager()

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            SheetFooter { dismiss() }
        }
        .frame(width: 900, height: 660)
        .background(Theme.background)
        .task {
            guard !manager.hasLoaded else { return }
            await manager.refresh()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                Task { await manager.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .medium))
                    .rotationEffect(manager.isRefreshing ? .degrees(360) : .zero)
                    .animation(manager.isRefreshing
                               ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                               : .default,
                               value: manager.isRefreshing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(manager.isRefreshing)
            .appTooltip("Refresh marketplace and installed versions")

            VStack(alignment: .leading, spacing: 2) {
                Text("Skills").font(.system(size: 16, weight: .semibold))
                Text("Example Engineering marketplace")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if manager.updateCount > 0 {
                Text("\(manager.updateCount) update\(manager.updateCount == 1 ? "" : "s") available")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secret)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.secret.opacity(0.12)))
            }
        }
        .padding(.horizontal, 20)
        .headerBand()
    }

    @ViewBuilder private var content: some View {
        if !manager.hasLoaded && manager.plugins.isEmpty {
            PaneMessage(icon: "shippingbox",
                        title: "Fetching skills",
                        detail: "Reading the Example marketplace and both agent installations.")
        } else if manager.plugins.isEmpty {
            PaneMessage(icon: "exclamationmark.triangle",
                        title: "Skills could not be loaded",
                        detail: manager.catalogueNotice ?? "The marketplace returned no skills.")
        } else {
            VStack(spacing: 0) {
                if let notice = manager.catalogueNotice {
                    noticeBanner(notice)
                }
                ForEach(SkillHost.allCases) { host in
                    if let failure = manager.hostFailure(host) {
                        noticeBanner("\(host.title) plugin status could not be read. \(failure)")
                    }
                }
                introduction
                columnHeadings
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(manager.plugins) { plugin in
                            skillRow(plugin)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
        }
    }

    private var introduction: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Install a package for either coding agent")
                    .font(.system(size: 13, weight: .semibold))
                Text("The checkboxes manage user-scoped installs. Versions are compared with the latest marketplace manifest each time this screen refreshes.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            Text("\(manager.plugins.count) PACKAGES")
                .font(.mono(10, .semibold))
                .kerning(0.5)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var columnHeadings: some View {
        HStack(spacing: 16) {
            Text("AVAILABLE SKILLS")
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(SkillHost.allCases) { host in
                HStack(spacing: 5) {
                    Circle()
                        .fill(manager.canManage(host) ? Theme.dotOn
                              : manager.hostFailure(host) == nil ? Theme.dotOff : Theme.deletion)
                        .frame(width: 6, height: 6)
                    Text(host.title.uppercased())
                }
                .frame(width: 160, alignment: .leading)
            }
        }
        .font(.mono(10, .semibold))
        .kerning(0.5)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func skillRow(_ plugin: SkillMarketplace.Plugin) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(plugin.name)
                            .font(.system(size: 13.5, weight: .semibold))
                            .textSelection(.enabled)
                        if let version = plugin.version {
                            Text("v\(version)")
                                .font(.mono(10.5, .medium))
                                .foregroundStyle(.secondary)
                        }
                        if let category = plugin.category {
                            Text(category.uppercased())
                                .font(.mono(8.5, .semibold))
                                .kerning(0.4)
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 5)
                                    .fill(Theme.accent.opacity(0.09)))
                        }
                    }
                    Text(plugin.description)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(SkillHost.allCases) { host in
                    hostControl(plugin, host: host)
                        .frame(width: 160, alignment: .leading)
                }
            }

            let failures = SkillHost.allCases.compactMap { host in
                manager.actionFailure(plugin, on: host).map { "\(host.title): \($0)" }
            }
            if !failures.isEmpty {
                Text(failures.joined(separator: "\n"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.deletion)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
    }

    @ViewBuilder private func hostControl(_ plugin: SkillMarketplace.Plugin,
                                          host: SkillHost) -> some View {
        let installation = manager.installation(of: plugin, on: host)
        let outdated = manager.isOutdated(plugin, on: host)
        let progress = manager.progress(of: plugin, on: host)
        let working = progress != nil
        let available = manager.isAvailable(host)
        let manageable = manager.canManage(host)

        VStack(alignment: .leading, spacing: 5) {
            Toggle(isOn: Binding(
                get: { installation != nil },
                set: { selected in
                    Task { await manager.setInstalled(selected, plugin: plugin, on: host) }
                })) {
                    Text(statusText(installation, available: available,
                                    manageable: manageable, progress: progress))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(manageable ? Color.primary : Color.secondary)
                        .lineLimit(2)
                }
                .toggleStyle(.appCheckbox)
                .disabled(!manageable || working)
                .opacity(working ? 0.55 : 1)

            if outdated, let latest = plugin.version {
                Button {
                    Task { await manager.update(plugin, on: host) }
                } label: {
                    Text("Update to v\(latest)")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.secret)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(working)
            } else if let installation, !installation.enabled {
                Text("Disabled in \(host.title)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.secret)
            }
        }
    }

    private func statusText(_ installation: SkillInstallation?, available: Bool,
                            manageable: Bool, progress: SkillActionProgress?) -> String {
        if let progress { return progress.rawValue }
        guard available else { return "CLI not found" }
        guard manageable else { return "Plugin command failed" }
        guard let installation else { return "Not installed" }
        return installation.version == "unknown" ? "Installed" : "Installed v\(installation.version)"
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(Color(red: 0.55, green: 0.20, blue: 0.16))
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(Color(red: 0.98, green: 0.90, blue: 0.88))
    }
}
