import SwiftUI

struct RemoteCommitList: View {
    let commits: [GitRemoteCommit]
    let emptyMessage: String
    // Commits on their way down from origin sit on a sunken fill, so they never read as
    // the ones about to be sent.
    var incoming = false

    var body: some View {
        if commits.isEmpty {
            Text(emptyMessage)
                .font(Typography.detail)
                .foregroundStyle(Theme.secondaryText)
        } else {
            HuggingHeight(limit: 222) {
                ScrollView { rows }.scrollBounceBehavior(.basedOnSize)
            }
            .background(incoming ? Theme.sunken : .clear)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Theme.settingsBorder))
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(commits.enumerated()), id: \.element.id) { index, commit in
                HStack(alignment: .firstTextBaseline, spacing: Space.lg) {
                    Text(commit.shortID)
                        .font(Typography.data.weight(.medium))
                        .foregroundStyle(Theme.secondaryText)
                        .textSelection(.enabled)
                    Text(commit.subject)
                        .font(Typography.detail)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) {
                    if index > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                }
                .accessibilityElement(children: .combine)
                .arrives(after: Double(min(index, 3)) * 0.028, rising: 4)
            }
        }
    }
}
