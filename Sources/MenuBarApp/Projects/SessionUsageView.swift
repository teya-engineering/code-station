import SwiftUI

// The third pane of a session, next to the transcript and the diff: what the
// conversation has spent, and how the account's limits are doing. What the session runs
// with - model, effort, permissions - is picked on the composer bar instead, where the
// send button is; this pane holds the numbers that build up as it runs. The CLI hides
// them behind /usage, which cannot be typed at an agent driven over a pipe, so they
// live here.
struct SessionUsageView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    let sessionID: UUID

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                usage
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

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
