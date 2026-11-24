import Foundation

// A request's address read two ways: the template as it is typed, cut into the parts
// worth tinting, and the address it becomes in one environment, with the parts that were
// filled in marked. What is shown always comes from the runner, so it is what is sent.
enum DispatchAddress {
    enum Token: Equatable {
        case text(String)
        case property(name: String, text: String)
        case path(name: String)

        var text: String {
            switch self {
            case .text(let text), .property(_, let text): text
            case .path(let name): ":" + name
            }
        }
    }

    // One stretch of the address as sent. A substituted one came from a {{property}} or
    // a path value rather than from what was typed.
    struct Part: Equatable {
        var text: String
        var substituted = false
    }

    struct Resolved: Equatable {
        var parts: [Part]
        // The one thing to fix before this can be sent, when there is one.
        var problem: String?

        var text: String { parts.map(\.text).joined() }
    }

    static func tokens(in url: String) -> [Token] {
        var special: [(range: Range<String.Index>, token: Token)] = []

        let path = SavedRequest.pathRange(of: url)
        var cursor = path.lowerBound
        while cursor < path.upperBound {
            let end = url[cursor..<path.upperBound].firstIndex(of: "/") ?? path.upperBound
            let segment = url[cursor..<end]
            if segment.first == ":", segment.count > 1 {
                special.append((cursor..<end, .path(name: String(segment.dropFirst()))))
            }
            cursor = end < path.upperBound ? url.index(after: end) : end
        }

        let matches = RequestPropertyResolver.placeholder.matches(in: url, range: NSRange(url.startIndex..., in: url))
        for match in matches {
            guard let range = Range(match.range, in: url),
                  let name = Range(match.range(at: 1), in: url),
                  !special.contains(where: { $0.range.overlaps(range) }) else { continue }
            special.append((range, .property(name: String(url[name]), text: String(url[range]))))
        }
        special.sort { $0.range.lowerBound < $1.range.lowerBound }

        var tokens: [Token] = []
        var start = url.startIndex
        for (range, token) in special {
            if start < range.lowerBound { tokens.append(.text(String(url[start..<range.lowerBound]))) }
            tokens.append(token)
            start = range.upperBound
        }
        if start < url.endIndex { tokens.append(.text(String(url[start...]))) }
        return tokens
    }

    // Whether a {{property}} has something to become. {{env}} always does.
    static func isKnown(_ property: String, properties: [EnvironmentProperty]) -> Bool {
        property == "env" || properties.contains { $0.name == property && !$0.value.isEmpty }
    }

    static func resolve(_ request: SavedRequest, environment: ApiEnvironment,
                        properties: [EnvironmentProperty]) -> Resolved {
        let sent = DispatchRunner.resolve(request, environment: environment, authorization: nil,
                                          properties: properties)
        let shown = DispatchRunner.resolve(request, environment: environment, authorization: nil,
                                           properties: properties, masked: true)

        var resolver = RequestPropertyResolver(environment: environment, properties: properties, masked: true)
        var parts: [Part] = []
        for token in tokens(in: request.url) {
            switch token {
            case .text(let text):
                parts.append(Part(text: text))
            case .property(_, let text):
                let value = resolver.text(text, field: "URL")
                parts.append(Part(text: value, substituted: value != text))
            case .path(let name):
                let typed = request.pathValue(for: name)
                if typed.isEmpty {
                    parts.append(Part(text: token.text))
                } else {
                    let value = FormURLEncoding.component(resolver.text(typed, field: "Path \(name)"))
                    parts.append(Part(text: value, substituted: true))
                }
            }
        }
        // The runner has the last word. When the parts do not add up to its address, the
        // address is shown whole and untinted rather than risk showing a different one.
        let joined = parts.map(\.text).joined()
        if shown.url.hasPrefix(joined) {
            let rest = String(shown.url.dropFirst(joined.count))
            if !rest.isEmpty { parts.append(Part(text: rest)) }
        } else {
            parts = [Part(text: shown.url)]
        }
        return Resolved(parts: parts, problem: problem(with: request, sent: sent))
    }

    private static func problem(with request: SavedRequest, sent: DispatchRunner.ResolvedRequest) -> String? {
        if request.url.trimmed.isEmpty { return "Type an address to send to." }
        if let first = sent.problems.first { return first }
        if let missing = request.pathNames.first(where: { request.pathValue(for: $0).isEmpty }) {
            return "Give :\(missing) a value in Parameters."
        }
        guard !DispatchRunner.isValidURL(sent.url) else { return nil }
        let lowered = sent.url.lowercased()
        return lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
            ? "The address is not one that can be sent to."
            : "The address needs to start with http:// or https://."
    }
}
