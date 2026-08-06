import SwiftUI

// The session log, in the app rather than in Finder. A turn that stops moving leaves
// nothing on screen to look at, and the answer is almost always in the last few lines
// here, so the point of this screen is to have them without leaving the window.
struct LogView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var lines: [LogLine] = []
    @State private var lastWritten: Date?
    @State private var follow = true

    // How often the file is checked while the screen is open. The log is written from a
    // read handler on every chunk of CLI output, so anything faster would be a poll for
    // its own sake.
    private static let refresh: Duration = .milliseconds(1_200)

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            SheetFooter(done: { dismiss() }) {
                Button("Reveal in Finder") { SessionLog.revealInFinder() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .frame(width: 760, height: 560)
        .background(Theme.background)
        .task { await watch() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Session log").font(.serif(16))
                Text("Every line Claude Code sent, and what the app did with it. The newest is at the bottom.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Toggle("Follow", isOn: $follow)
                .toggleStyle(.appSwitch)
                .font(.system(size: 12))
                .help("Stay at the newest line as it is written")
        }
        .padding(.horizontal, 20)
        .headerBand()
    }

    @ViewBuilder private var content: some View {
        if lines.isEmpty {
            VStack(spacing: 6) {
                Text("Nothing logged yet")
                    .font(.system(size: 13, weight: .semibold))
                Text("The log fills up as soon as a session runs.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines) { line in
                            LogRow(line: line)
                                .id(line.id)
                        }
                        // Scrolling to the last line would leave it against the bottom
                        // edge; this is what the view is actually pinned to.
                        Color.clear.frame(height: 1).id(Self.bottom)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .textSelection(.enabled)
                }
                .onChange(of: lines.count) { _, _ in
                    guard follow else { return }
                    scroller.scrollTo(Self.bottom, anchor: .bottom)
                }
                .onChange(of: follow) { _, following in
                    guard following else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        scroller.scrollTo(Self.bottom, anchor: .bottom)
                    }
                }
                .onAppear { scroller.scrollTo(Self.bottom, anchor: .bottom) }
            }
        }
    }

    private static let bottom = "bottom"

    // MARK: - Reading

    // The file is only read again once it has grown, so an open log screen costs a stat
    // call a second rather than a reparse of the whole tail.
    private func watch() async {
        while !Task.isCancelled {
            let written = SessionLog.lastWritten
            if written != lastWritten {
                lastWritten = written
                lines = await Task.detached(priority: .userInitiated) {
                    LogLine.parse(SessionLog.tail())
                }.value
            }
            try? await Task.sleep(for: Self.refresh)
        }
    }
}

// One entry, split into the three things it is made of so the message is the only part
// at full strength: the stamps are there to be scanned past, not read.
struct LogLine: Identifiable, Equatable {
    let id: Int
    let time: String
    let session: String
    let message: String

    // Entries are written as "HH:mm:ss.SSS [12ab34cd] what happened". Anything that does
    // not look like one is kept whole rather than dropped: a line the app did not write
    // is exactly the kind of thing worth seeing.
    static func parse(_ text: String) -> [LogLine] {
        text.split(separator: "\n", omittingEmptySubsequences: true).enumerated().map { index, raw in
            let line = String(raw)
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, parts[1].hasPrefix("["), parts[1].hasSuffix("]") else {
                return LogLine(id: index, time: "", session: "", message: line)
            }
            let tag = parts[1].dropFirst().dropLast()
            // Lines that belong to the app rather than to any one session are tagged with
            // dashes, which say nothing worth a column of their own.
            return LogLine(id: index,
                           time: String(parts[0]),
                           session: tag.allSatisfy { $0 == "-" } ? "" : String(tag),
                           message: String(parts[2]))
        }
    }
}

private struct LogRow: View {
    let line: LogLine

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(line.time)
                .font(.mono(11))
                .foregroundStyle(.tertiary)
                .frame(width: 78, alignment: .leading)
            Text(line.session)
                .font(.mono(11))
                .foregroundStyle(Theme.monogram(for: line.session))
                .frame(width: 62, alignment: .leading)
            Text(line.message)
                .font(.mono(11.5))
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1.5)
    }

    // The log is read when something has gone wrong, so the lines that say so are the
    // ones worth finding at a glance.
    private var tint: Color {
        let text = line.message.lowercased()
        if text.contains("error") || text.contains("failed") || text.contains("could not") {
            return Theme.deletion
        }
        return .primary
    }
}
