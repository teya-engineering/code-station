import SwiftUI

// The third pane of a session, next to the transcript and the diff: what this session
// runs Claude Code with, and what it has spent. The CLI hides the same choices behind
// /model, /effort and /usage, none of which can be typed at an agent that is driven
// over a pipe, so they live here instead.
//
// Nothing here is a setting of its own. Every choice is either "follow the app default"
// or an override for this one conversation, which is what the first row of each group
// says and what the badges mark.
struct SessionSettingsView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    let sessionID: UUID

    private var settings: SessionSettings {
        store.session(sessionID)?.settings ?? SessionSettings()
    }

    private var defaults: SessionSettings { runner.defaults }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                banner
                model
                effort
                permissions
                usage
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func change(_ edit: (inout SessionSettings) -> Void) {
        var updated = settings
        edit(&updated)
        store.setSettings(updated, for: sessionID)
    }

    private func badge(_ overridden: Bool) -> String? {
        overridden ? "OVERRIDDEN" : nil
    }

    // MARK: - What this pane is

    private var banner: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(settings.overridesAnything ? "This session runs its own way"
                                                : "This session follows the app settings")
                    .font(.system(size: 13, weight: .semibold))
                Text("Everything below starts at the app default and can be overridden for this conversation alone. Whatever is left on the default keeps following Settings, including later changes there.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if settings.overridesAnything {
                Button("Follow the defaults") {
                    store.setSettings(SessionSettings(), for: sessionID)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                .fixedSize()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
    }

    // MARK: - Choices

    private var model: some View {
        ChoiceBlock("MODEL",
                    note: "Applies from the next turn on. The conversation carries over, so a model can be swapped mid-session.",
                    badge: badge(settings.model != nil)) {
            VStack(spacing: 4) {
                OptionRow(title: "Use the default",
                          detail: ModelChoice.summary(of: defaults.model),
                          selected: settings.model == nil) {
                    change { $0.model = nil }
                }
                ForEach(ModelChoice.all.filter { $0.id != nil }, id: \.title) { choice in
                    OptionRow(title: choice.title,
                              detail: choice.detail,
                              selected: settings.model == choice.id) {
                        change { $0.model = choice.id }
                    }
                }
            }
        }
    }

    private var effort: some View {
        ChoiceBlock("EFFORT",
                    note: "How long the model thinks before it answers. Default is \(EffortChoice.summary(of: defaults.effort).lowercased()).",
                    badge: badge(settings.effort != nil)) {
            HStack(spacing: 4) {
                ForEach(EffortChoice.all, id: \.title) { choice in
                    ChoicePill(title: choice.title, selected: settings.effort == choice.id) {
                        change { $0.effort = choice.id }
                    }
                }
            }
        }
    }

    private var permissions: some View {
        ChoiceBlock("PERMISSIONS", badge: badge(settings.permissionMode != nil)) {
            VStack(spacing: 4) {
                OptionRow(title: "Use the default",
                          detail: PermissionMode.title(of: defaults.permissionMode),
                          selected: settings.permissionMode == nil) {
                    change { $0.permissionMode = nil }
                }
                ForEach(PermissionMode.all, id: \.mode) { choice in
                    OptionRow(title: choice.title,
                              detail: choice.detail,
                              selected: settings.permissionMode == choice.mode) {
                        change { $0.permissionMode = choice.mode }
                    }
                }
            }
        }
    }

    // MARK: - Usage

    private var usage: some View {
        ChoiceBlock("USAGE") {
            VStack(alignment: .leading, spacing: 14) {
                limits
                Divider().overlay(Theme.hairline)
                spend
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
        }
    }

    // The account's windows, which every session shares. The CLI only reports them while
    // a turn runs, so before the first one there is nothing to show.
    @ViewBuilder private var limits: some View {
        let windows = runner.rateLimits.values.sorted { $0.kind < $1.kind }
        if windows.isEmpty {
            Text("Account limits show up here once a turn has run.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(windows, id: \.kind) { window in
                    LimitRow(limit: window)
                }
            }
        }
    }

    @ViewBuilder private var spend: some View {
        let spent = store.session(sessionID)?.usage
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                Figure(label: "COST", value: String(format: "$%.2f", spent?.costUSD ?? 0))
                Figure(label: "TURNS", value: "\(spent?.turns ?? 0)")
                Figure(label: "SENT", value: formattedTokens((spent?.inputTokens ?? 0)
                    + (spent?.cacheReadTokens ?? 0) + (spent?.cacheWriteTokens ?? 0)))
                Figure(label: "WRITTEN", value: formattedTokens(spent?.outputTokens ?? 0))
            }

            if let spent, let fraction = spent.contextFraction {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Context after the last turn")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(formattedTokens(spent.contextTokens)) of \(formattedTokens(spent.contextWindow))")
                            .font(.mono(11))
                            .foregroundStyle(.secondary)
                    }
                    Meter(fraction: fraction, colour: fraction > 0.85 ? Theme.deletion : Theme.dotOn)
                    if let model = spent.model {
                        Text(model).font(.mono(11)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: - Pieces

    private struct LimitRow: View {
        let limit: RateLimit

        var body: some View {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(limit.title).font(.system(size: 13, weight: .medium))
                    if limit.isBlocked {
                        badge("REACHED", colour: Theme.deletion)
                    } else if limit.isWarning {
                        badge("RUNNING LOW", colour: Theme.secret)
                    }
                    Spacer(minLength: 0)
                    if let resets = limit.resetsAt {
                        Text("resets \(resets.formatted(.relative(presentation: .named)))")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                if let used = limit.utilization {
                    Meter(fraction: used, colour: limit.isBlocked ? Theme.deletion : Theme.dotOn)
                }
            }
        }

        private func badge(_ text: String, colour: Color) -> some View {
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(colour)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(colour.opacity(0.12)))
        }
    }

    private struct Figure: View {
        let label: String
        let value: String

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                Text(value).font(.mono(15, .semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
