import Foundation
import Observation

// Sends the requests and keeps the last answer for each one per environment, so
// switching between requests in the sidebar does not throw away what came back, and an
// answer from one environment is never on screen while the other is active.
@MainActor
@Observable
final class PostmanRunner {
    struct Key: Hashable {
        let request: UUID
        let environment: ApiEnvironment
    }

    private(set) var inFlight: Set<Key> = []
    private(set) var results: [Key: HTTPResult] = [:]

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    func isRunning(_ id: UUID, in environment: ApiEnvironment) -> Bool {
        inFlight.contains(Key(request: id, environment: environment))
    }

    func result(_ id: UUID, in environment: ApiEnvironment) -> HTTPResult? {
        results[Key(request: id, environment: environment)]
    }

    func send(_ request: SavedRequest, environment: ApiEnvironment,
              authorization: String? = nil) async {
        let key = Key(request: request.id, environment: environment)
        guard !inFlight.contains(key) else { return }
        guard let urlRequest = Self.build(request, environment: environment,
                                          authorization: authorization) else {
            results[key] = HTTPResult(status: 0, headers: [], body: "", duration: 0,
                                      byteCount: 0, failure: "That URL is not valid.")
            return
        }

        inFlight.insert(key)
        defer { inFlight.remove(key) }

        let started = Date()
        do {
            let (data, response) = try await session.data(for: urlRequest)
            let elapsed = Date().timeIntervalSince(started)
            let http = response as? HTTPURLResponse
            let headers = (http?.allHeaderFields as? [String: String] ?? [:])
                .sorted { $0.key < $1.key }
                .map { HeaderField(key: $0.key, value: $0.value) }
            results[key] = HTTPResult(
                status: http?.statusCode ?? 0,
                headers: headers,
                body: Self.readable(data, contentType: http?.value(forHTTPHeaderField: "Content-Type")),
                duration: elapsed,
                byteCount: data.count)
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            results[key] = HTTPResult(status: 0, headers: [], body: "", duration: elapsed,
                                      byteCount: 0, failure: error.localizedDescription)
        }
    }

    // MARK: - Building

    private static func build(_ request: SavedRequest, environment: ApiEnvironment,
                              authorization: String?) -> URLRequest? {
        // {{env}} is substituted at the last moment, so the saved request stays a
        // template and the same list serves both environments.
        let trimmed = environment.resolve(request.url)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else { return nil }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue

        // The collection's token goes on first, so an Authorization header typed into the
        // request itself still wins.
        if let authorization, request.useAuth {
            urlRequest.setValue(authorization, forHTTPHeaderField: "Authorization")
        }

        for header in request.headers where header.enabled && !header.key.isEmpty {
            urlRequest.setValue(header.value, forHTTPHeaderField: header.key)
        }

        if request.bodyType != .none, !request.body.isEmpty {
            urlRequest.httpBody = Data(request.body.utf8)
            // A Content-Type typed by hand is the more deliberate choice, so the one
            // implied by the body type only fills a gap.
            if urlRequest.value(forHTTPHeaderField: "Content-Type") == nil,
               let contentType = request.bodyType.contentType {
                urlRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
        }
        return urlRequest
    }

    // MARK: - Reading the response

    private static func readable(_ data: Data, contentType: String?) -> String {
        guard !data.isEmpty else { return "" }
        guard let text = String(data: data, encoding: .utf8) else {
            return "\(data.count) bytes that are not text."
        }
        guard contentType?.localizedCaseInsensitiveContains("json") == true else { return text }
        return prettyJSON(data) ?? text
    }

    private static func prettyJSON(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return nil }
        return String(data: pretty, encoding: .utf8)
    }
}
