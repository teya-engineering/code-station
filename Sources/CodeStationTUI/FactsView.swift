import CodeStationCore
import TerminalKit

// The session's facts in full, over its transcript: what the GUI's facts card holds and
// what the top bar folds into its Details entry when it is narrow. Opened with `D` from
// the transcript; Esc, q or D closes it, and d goes on to the changes.
enum FactsView {
    static func frame(_ header: RemoteHeader, size: TerminalSize) -> [String] {
        let width = max(size.cols, 10)
        var rows: [(label: String, value: [TopBarView.Run])] = []
        if let branch = header.branch, !branch.isEmpty { rows.append(("BRANCH", [(branch, "")])) }
        rows.append(("CHANGES", TopBarView.changes(header) ?? [("No changes", Style.dim)]))
        for (index, pullRequest) in (header.pullRequests ?? []).enumerated() {
            rows.append((index == 0 ? "PULL REQ" : "", [("#\(pullRequest.number) ", Style.cyan),
                                                        (pullRequest.url, Style.dim)]))
        }
        if let model = header.model { rows.append(("MODEL", [(model, "")])) }
        if let context = header.context {
            rows.append(("CONTEXT", [(TopBarView.percent(context) + " full", "")]))
        }
        if let cost = header.cost { rows.append(("COST", [(TopBarView.cost(cost), "")])) }

        var lines = [SidebarView.paint([(" Session details", Style.bold)], width: width), ""]
        for row in rows {
            let label = " " + row.label.padding(toLength: 10, withPad: " ", startingAt: 0)
            lines.append(SidebarView.paint([(label, Style.dim)] + row.value, width: width))
        }
        let help = SidebarView.paint([(" esc close · d changes", Style.dim)], width: width)
        lines += Array(repeating: "", count: max(size.rows - lines.count - 1, 0))
        return Array(lines.prefix(max(size.rows - 1, 0))) + [help]
    }
}
