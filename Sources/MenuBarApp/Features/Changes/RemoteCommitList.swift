import SwiftUI
import CodeStationCore

struct RemoteCommitList: View {
    let commits: [GitRemoteCommit]
    let emptyMessage: String

    var body: some View {
        if commits.isEmpty {
            Text(emptyMessage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("COMMITS")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(commits) { commit in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(commit.shortID)
                                    .font(.mono(11, .medium))
                                    .foregroundStyle(.secondary)
                                Text(commit.subject)
                                    .font(.system(size: 12))
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                        }
                    }
                }
                .frame(maxHeight: 190)
            }
        }
    }

}
