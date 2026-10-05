import Foundation

struct EnvironmentProperty: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name = ""
    var value = ""
    var isSecret = false

    static func validation(_ rows: [Self]) -> String? {
        var names = Set<String>()
        for row in rows {
            guard row.name.range(of: "^[A-Za-z_][A-Za-z0-9_]*\\z", options: .regularExpression) != nil else {
                return "Use letters, digits and underscores; start with a letter or underscore."
            }
            guard row.name != "env" else { return "env is reserved for the built-in environment identifier." }
            guard names.insert(row.name).inserted else { return "Property names must be unique within an environment." }
        }
        return nil
    }
}

struct RequestPropertyResolver {
    let environment: ApiEnvironment
    var properties: [EnvironmentProperty] = []
    var masked = false
    private(set) var problems: [String] = []
    private static let placeholder = try! NSRegularExpression(pattern: #"\{\{([^{}]+)\}\}"#)

    mutating func text(_ template: String, field: String, json: Bool = false, encoded: Bool = false) -> String {
        let matches = Self.placeholder.matches(in: template, range: NSRange(template.startIndex..., in: template))
        var result = ""
        var cursor = template.startIndex
        for match in matches {
            let range = Range(match.range, in: template)!
            let name = String(template[Range(match.range(at: 1), in: template)!])
            result += template[cursor..<range.lowerBound]
            var value: String
            if name == "env" {
                value = environment.name
            } else if let property = properties.first(where: { $0.name == name }), !property.value.isEmpty {
                value = masked && property.isSecret ? "REDACTED" : property.value
            } else {
                problems.append("Set {{\(name)}} in \(environment.label) (\(environment.name)): \(field).")
                value = String(template[range])
            }
            if encoded {
                value = value.addingPercentEncoding(withAllowedCharacters:
                    CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? value
            }
            if json {
                // Only a placeholder inside a JSON string needs string escaping.
                var inside = false
                var escaped = false
                for character in template[..<range.lowerBound] {
                    if escaped { escaped = false }
                    else if character == "\\" { escaped = true }
                    else if character == "\"" { inside.toggle() }
                }
                if inside {
                    let encoded = try! JSONEncoder().encode(value)
                    value = String(String(decoding: encoded, as: UTF8.self).dropFirst().dropLast())
                } else if masked, properties.contains(where: { $0.name == name && $0.isSecret }) {
                    value = "\"REDACTED\""
                }
            }
            result += value
            cursor = range.upperBound
        }
        result += template[cursor...]
        return result
    }

    mutating func resolve(_ source: SavedRequest) -> SavedRequest {
        var request = source
        request.url = text(source.url, field: "URL")
        for index in request.pathParams.indices where request.pathParams[index].enabled
            && !request.pathParams[index].key.isEmpty
            && request.url.contains(":" + request.pathParams[index].key) {
            let value = text(source.pathParams[index].value, field: "Path \(source.pathParams[index].key)")
            request.pathParams[index].value = value.addingPercentEncoding(withAllowedCharacters:
                CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? value
        }
        for index in request.queryParams.indices where request.queryParams[index].enabled && !request.queryParams[index].key.isEmpty {
            request.queryParams[index].value = text(source.queryParams[index].value, field: "Query \(source.queryParams[index].key)")
        }
        for index in request.headers.indices where request.headers[index].enabled && !request.headers[index].key.isEmpty {
            request.headers[index].value = text(source.headers[index].value, field: "Header \(source.headers[index].key)")
            if request.headers[index].value.contains(where: { $0 == "\r" || $0 == "\n" }) {
                problems.append("\(environment.label): header \(source.headers[index].key) contains a line break.")
            }
        }
        if source.method.canCarryBody && source.bodyType != .none {
            if source.bodyType == .form {
                // Split the template before resolution so a value cannot add a form field.
                request.body = source.body.split(whereSeparator: { $0.isNewline || $0 == "&" }).map { pair in
                    let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    return parts.map { part in
                        text(String(part).trimmed, field: "Form body", encoded: true)
                    }.joined(separator: "=")
                }.joined(separator: "&")
            } else {
                request.body = text(source.body, field: "Body", json: source.bodyType == .json)
            }
            if source.bodyType == .json && !request.body.isEmpty,
               (try? JSONSerialization.jsonObject(with: Data(request.body.utf8), options: [.fragmentsAllowed])) == nil {
                problems.append("\(environment.label): the resolved JSON body is not valid.")
            }
        }
        return request
    }
}
