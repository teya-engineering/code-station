import SwiftUI

// How many log lines landed in each stretch of a result, split by how serious they were.
// It is counted from the lines the result holds, so it is only as whole as the result is.
struct LogRhythm: Equatable {
    struct Bucket: Equatable {
        var errors = 0
        var warnings = 0
        var others = 0

        var total: Int { errors + warnings + others }
    }

    enum Level { case error, warning, other }

    let start: Double
    // How long one bar covers, in seconds.
    let step: Double
    let buckets: [Bucket]

    private static let steps: [Double] = [1, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600,
                                          7200, 21600, 43200, 86400]

    // Nil when there is no rhythm to show: too few lines carry a time, or they all
    // landed in the same second.
    init?(_ entries: [GrafanaToolResult.LogEntry], bars: Int = ChartMetrics.rhythmBars) {
        let dated = entries.compactMap { entry in entry.date.map { ($0.timeIntervalSince1970, entry.level) } }
        guard dated.count >= 4, let low = dated.map(\.0).min(), let high = dated.map(\.0).max(),
              high - low >= 1 else { return nil }
        let span = high - low
        let step = Self.steps.first { span / $0 < Double(bars) } ?? (span / Double(bars)).rounded(.up)
        let start = (low / step).rounded(.down) * step
        var buckets = Array(repeating: Bucket(), count: Int((high - start) / step) + 1)
        for (time, level) in dated {
            let index = min(Int((time - start) / step), buckets.count - 1)
            switch Self.level(level) {
            case .error: buckets[index].errors += 1
            case .warning: buckets[index].warnings += 1
            case .other: buckets[index].others += 1
            }
        }
        self.start = start
        self.step = step
        self.buckets = buckets
    }

    var peak: Int { buckets.map(\.total).max() ?? 0 }
    var end: Double { start + step * Double(buckets.count) }

    func bucket(of date: Date?) -> Int? {
        guard let time = date?.timeIntervalSince1970, time >= start, time < end else { return nil }
        return Int((time - start) / step)
    }

    static func level(_ level: String?) -> Level {
        switch level?.uppercased() {
        case "ERROR", "ERR", "FATAL", "CRITICAL", "CRIT": .error
        case "WARN", "WARNING": .warning
        default: .other
        }
    }

    var stepText: String {
        step < 60 ? counted(Int(step), "second") : step < 3600 ? counted(Int(step / 60), "minute")
            : counted(Int(step / 3600), "hour")
    }

    func summary(_ index: Int) -> String {
        let bucket = buckets[index]
        return "\(counted(bucket.errors, "error")), \(counted(bucket.warnings, "warning")), "
            + "\(bucket.others) other"
    }
}

// The rhythm drawn as a strip of stacked bars above the lines: errors on top in red,
// warnings in amber, the rest in grey. Pointing at a bar lights the lines that landed in
// it, and pointing at a line lights its bar.
struct LogRhythmStrip: View {
    let rhythm: LogRhythm
    @Binding var hot: Int?

    @Environment(\.textScale) private var textScale
    @State private var grown = false

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let slot = proxy.size.width / CGFloat(rhythm.buckets.count)
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(Array(rhythm.buckets.enumerated()), id: \.offset) { index, bucket in
                        bar(bucket, height: proxy.size.height)
                            .padding(.horizontal, min(ChartMetrics.rhythmGap, slot / 4) / 2)
                            .frame(width: slot, height: proxy.size.height, alignment: .bottom)
                            .background(Color.primary.opacity(hot == index ? 0.09 : 0))
                            .scaleEffect(y: grown ? 1 : ChartMotion.zoomGrowth, anchor: .bottom)
                            .opacity(grown ? 1 : 0)
                            .motion(ChartMotion.restack(bar: index, of: rhythm.buckets.count), value: grown)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        hot = min(max(Int(point.x / max(slot, 1)), 0), rhythm.buckets.count - 1)
                    case .ended:
                        hot = nil
                    }
                }
            }
            .frame(height: ChartMetrics.rhythmHeight)
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.md)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack(spacing: Space.md) {
                Text(TranscriptChartFormat.clock(rhythm.start, seconds: true))
                Spacer(minLength: 0)
                Text(hot.map { "\(clock($0))   \(rhythm.summary($0))" } ?? "Each bar is \(rhythm.stepText).")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(TranscriptChartFormat.clock(rhythm.end, seconds: true))
            }
            .scaledMono(Typography.Size.micro)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.sm)
        }
        .motion(Motion.hover, value: hot)
        .onAppear { grown = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Log volume")
        .accessibilityValue(spoken)
    }

    private func clock(_ index: Int) -> String {
        TranscriptChartFormat.clock(rhythm.start + rhythm.step * Double(index), seconds: true)
    }

    private var spoken: String {
        let errors = rhythm.buckets.reduce(0) { $0 + $1.errors }
        let warnings = rhythm.buckets.reduce(0) { $0 + $1.warnings }
        return "\(counted(errors, "error")) and \(counted(warnings, "warning")), in bars of \(rhythm.stepText)"
    }

    private func bar(_ bucket: LogRhythm.Bucket, height: CGFloat) -> some View {
        let unit = height / CGFloat(max(rhythm.peak, 1))
        return VStack(spacing: 0) {
            Rectangle().fill(Theme.deletion).frame(height: CGFloat(bucket.errors) * unit)
            Rectangle().fill(Theme.attention).frame(height: CGFloat(bucket.warnings) * unit)
            Rectangle().fill(Theme.chartGrid).frame(height: CGFloat(bucket.others) * unit)
        }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: Radius.tag / 2, topTrailingRadius: Radius.tag / 2))
    }
}
