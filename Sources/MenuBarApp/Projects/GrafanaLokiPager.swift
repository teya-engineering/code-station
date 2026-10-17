import Foundation

// Loki hands back at most one page of lines per query, newest first. Walking the window's
// end back to the oldest line seen collects the rest, within limits that keep a run quick:
// any stop short of the window's start marks the run capped, so the chip can say so.
enum GrafanaLokiPager {
    static let maxLines = 5000
    static let maxPages = 10

    struct Outcome: Equatable, Sendable {
        let result: GrafanaToolResult
        let capped: Bool
    }

    enum Stop: LocalizedError, Equatable {
        case failed(String)
        var errorDescription: String? {
            switch self { case .failed(let message): message }
        }
    }

    static func run(arguments: Data, levelField: String?,
                    call: @Sendable (Data) async throws -> MCPHTTPClient.ToolResult) async throws -> Outcome {
        guard var args = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] else {
            throw Stop.failed("The query could not be prepared.")
        }
        var entries: [GrafanaToolResult.LogEntry] = []
        var seen: Set<String> = []
        var pages = 0
        var capped = false

        paging: while true {
            let body = (try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])) ?? Data()
            let reply: MCPHTTPClient.ToolResult
            do {
                reply = try await call(body)
            } catch {
                if pages == 0 { throw Stop.failed(error.localizedDescription) }
                capped = true
                break paging
            }
            let page: [GrafanaToolResult.LogEntry]
            switch reply.isError ? nil : GrafanaToolResult.parse(reply.text, levelField: levelField) {
            case .logs(let entries, _)?:
                page = entries
            case .empty?:
                page = []
            default:
                if pages == 0 { throw Stop.failed(reply.text) }
                capped = true
                break paging
            }
            pages += 1
            let before = entries.count
            for entry in page where seen.insert(entry.rawTimestamp + "\u{0}" + entry.line).inserted {
                entries.append(entry)
            }
            if page.count < GrafanaQueryEdit.pageLimit { break paging }
            if entries.count == before || entries.count >= maxLines || pages >= maxPages {
                capped = true
                break paging
            }
            // Loki's end is exclusive, so the next page ends just after the oldest line seen:
            // it picks up that line's same-instant neighbours, and the repeats are dropped.
            let oldest = page.compactMap { Int64($0.rawTimestamp.replacingOccurrences(of: "\"", with: "")) }.min()
            guard let oldest else { break paging }
            args["endRfc3339"] = GrafanaQueryEdit.rfc3339(nanoseconds: oldest + 1)
        }

        let kept = entries.prefix(maxLines).enumerated().map { index, entry in
            GrafanaToolResult.LogEntry(id: index, rawTimestamp: entry.rawTimestamp, date: entry.date,
                                       line: entry.line, labels: entry.labels, fields: entry.fields,
                                       metadata: entry.metadata, level: entry.level, message: entry.message)
        }
        let result: GrafanaToolResult = kept.isEmpty ? .empty : .logs(Array(kept), truncated: false)
        return Outcome(result: result, capped: capped)
    }
}
