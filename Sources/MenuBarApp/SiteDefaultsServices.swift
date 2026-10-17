import Foundation

extension SiteDefaults {
    // What an organisation knows about one service's logs: where they are in Loki, how a
    // line is written, and what its fields mean. A diagnosis is handed it so the agent
    // queries the service directly instead of exploring labels first.
    struct Service: Codable, Sendable, Equatable, Identifiable {
        enum LogFormat: String, Codable, Sendable { case logfmt, json }

        var name: String
        var lokiSelector: String
        var logFormat: LogFormat
        var levelField: String? = nil
        var levelValues: [String]? = nil
        var traceField: String? = nil
        var fields: [String: String]? = nil
        var prometheusSelector: String? = nil
        var notes: String? = nil
        // Which Grafana holds this service's logs: the <scope> in grafana-<scope>-<env>.
        var scope: String? = nil
        // What the service is called in traces, when that is not its name here.
        var traceServiceName: String? = nil

        var id: String { name }

        var traceName: String { traceServiceName ?? name }

        var promptContext: String {
            var lines = ["Service log context: \(name)",
                         "- Loki selector: \(lokiSelector)",
                         "- Log format: \(logFormat.rawValue)"]
            if let levelField {
                let values = levelValues.map { " (\($0.joined(separator: ", ")))" } ?? ""
                lines.append("- Level field: \(levelField)\(values)")
            }
            if let traceField { lines.append("- Trace field: \(traceField)") }
            if let fields, !fields.isEmpty {
                let described = fields.sorted { $0.key < $1.key }
                    .map { "\($0.key): \($0.value)" }.joined(separator: "; ")
                lines.append("- Fields: \(described)")
            }
            if let prometheusSelector { lines.append("- Prometheus selector: \(prometheusSelector)") }
            if let scope {
                lines.append("- Grafana scope: \(scope) (its logs are on the \(Grafana.namePrefix)\(scope)-<environment> server)")
            }
            if let notes { lines.append("- Notes: \(notes)") }
            lines.append("Start Loki queries from this selector rather than discovering labels.")
            return lines.joined(separator: "\n")
        }

        // A Loki query belongs to this service when its stream selector carries every
        // matcher of the service's selector, however spaced or ordered. Text in line filters
        // after the selector does not count.
        func matches(_ call: GrafanaToolCall) -> Bool {
            switch call.kind {
            case .lokiLogs:
                let wanted = Self.streamMatchers(in: lokiSelector)
                return !wanted.isEmpty && wanted.isSubset(of: Self.streamMatchers(in: call.query))
            case .prometheus:
                guard let prometheusSelector else { return false }
                return Self.compacted(call.query).contains(Self.compacted(prometheusSelector))
            }
        }

        // The matchers inside the first {...} of a query, each with the spaces outside its
        // quoted value removed.
        static func streamMatchers(in query: String) -> Set<String> {
            guard let open = query.firstIndex(of: "{") else { return [] }
            var matchers: Set<String> = []
            var current = ""
            var inQuote = false
            var escaped = false
            for character in query[query.index(after: open)...] {
                if inQuote {
                    current.append(character)
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        inQuote = false
                    }
                    continue
                }
                switch character {
                case "\"":
                    inQuote = true
                    current.append(character)
                case ",", "}":
                    if !current.isEmpty { matchers.insert(current) }
                    current = ""
                    if character == "}" { return matchers }
                case " ", "\t", "\n":
                    break
                default:
                    current.append(character)
                }
            }
            return matchers
        }

        private static func compacted(_ text: String) -> String {
            var result = ""
            var inQuote = false
            for character in text {
                if character == "\"" { inQuote.toggle() }
                if !inQuote, character == " " || character == "\t" || character == "\n" { continue }
                result.append(character)
            }
            return result
        }
    }

    // One mistyped service should not cost a team the rest of its configuration, so each
    // entry is read on its own and the ones that do not decode are left out.
    struct DecodedServices: Decodable {
        let services: [Service]

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            var kept: [Service] = []
            while !container.isAtEnd {
                let before = container.currentIndex
                guard let service = try? container.decode(Service.self) else {
                    _ = try? container.decode(DiscardedEntry.self)
                    if container.currentIndex == before { break }
                    continue
                }
                let usable = !service.name.trimmed.isEmpty && !service.lokiSelector.trimmed.isEmpty
                if usable, !kept.contains(where: { $0.name == service.name }) {
                    kept.append(service)
                }
            }
            services = kept
        }

        private struct DiscardedEntry: Decodable {}
    }
}
