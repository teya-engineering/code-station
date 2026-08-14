import Foundation
import Observation

// Sends the requests and keeps recent answers per environment, so switching between
// requests does not immediately throw away what came back. Response bodies and the
// result cache have separate limits because a useful API tool must stay safe when a
// server returns far more data than expected.
@MainActor
@Observable
final class DispatchRunner {
    struct Key: Hashable {
        let request: UUID
        let environment: ApiEnvironment
    }

    static let defaultResponseByteLimit = 5 * 1024 * 1024
    static let defaultRetainedResultByteLimit = 20 * 1024 * 1024

    private(set) var inFlight: Set<Key> = []
    private(set) var results: [Key: HTTPResult] = [:]

    @ObservationIgnored private let maxResponseBytes: Int
    @ObservationIgnored private let maxRetainedResultBytes: Int
    @ObservationIgnored private let sessionConfiguration: URLSessionConfiguration
    @ObservationIgnored private var downloads: [Key: BoundedResponseLoader] = [:]
    @ObservationIgnored private var resultOrder: [Key] = []
    @ObservationIgnored private var resultCosts: [Key: Int] = [:]
    @ObservationIgnored private var retainedResultBytes = 0

    init(maxResponseBytes: Int = defaultResponseByteLimit,
         maxRetainedResultBytes: Int = defaultRetainedResultByteLimit,
         sessionConfiguration: URLSessionConfiguration? = nil) {
        precondition(maxResponseBytes > 0)
        precondition(maxRetainedResultBytes >= maxResponseBytes)
        self.maxResponseBytes = maxResponseBytes
        self.maxRetainedResultBytes = maxRetainedResultBytes
        if let sessionConfiguration {
            self.sessionConfiguration = sessionConfiguration
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            config.httpShouldSetCookies = false
            self.sessionConfiguration = config
        }
    }

    func isRunning(_ id: UUID, in environment: ApiEnvironment) -> Bool {
        inFlight.contains(Key(request: id, environment: environment))
    }

    func result(_ id: UUID, in environment: ApiEnvironment) -> HTTPResult? {
        results[Key(request: id, environment: environment)]
    }

    func cancel(_ id: UUID, in environment: ApiEnvironment) {
        downloads[Key(request: id, environment: environment)]?.cancel()
    }

    func send(_ request: SavedRequest, environment: ApiEnvironment,
              authorization: String? = nil) async {
        let key = Key(request: request.id, environment: environment)
        guard !inFlight.contains(key) else { return }

        let urlRequest: URLRequest
        switch Self.build(request, environment: environment, authorization: authorization) {
        case .success(let built):
            urlRequest = built
        case .failure(let problem):
            store(HTTPResult(status: 0, headers: [], body: "", duration: 0,
                             byteCount: 0, failure: problem.message), for: key)
            return
        }

        inFlight.insert(key)
        let download = BoundedResponseLoader(limit: maxResponseBytes,
                                             configuration: sessionConfiguration)
        downloads[key] = download
        defer {
            downloads[key] = nil
            inFlight.remove(key)
        }

        let started = Date()
        do {
            let downloaded = try await download.load(urlRequest)
            let elapsed = Date().timeIntervalSince(started)
            let http = downloaded.response as? HTTPURLResponse
            let headers = (http?.allHeaderFields as? [String: String] ?? [:])
                .sorted { $0.key < $1.key }
                .map { HeaderField(key: $0.key, value: $0.value) }
            store(HTTPResult(
                status: http?.statusCode ?? 0,
                headers: headers,
                body: Self.readable(downloaded.data,
                                    contentType: http?.value(forHTTPHeaderField: "Content-Type"),
                                    isTruncated: downloaded.isTruncated),
                duration: elapsed,
                byteCount: downloaded.byteCount,
                isTruncated: downloaded.isTruncated), for: key)
        } catch is CancellationError {
            storeCancellation(for: key, started: started)
        } catch let error as URLError where error.code == .cancelled {
            storeCancellation(for: key, started: started)
        } catch {
            store(HTTPResult(status: 0, headers: [], body: "",
                             duration: Date().timeIntervalSince(started),
                             byteCount: 0, failure: error.localizedDescription), for: key)
        }
    }

    private func storeCancellation(for key: Key, started: Date) {
        store(HTTPResult(status: 0, headers: [], body: "",
                         duration: Date().timeIntervalSince(started),
                         byteCount: 0, failure: "Cancelled."), for: key)
    }

    private func store(_ result: HTTPResult, for key: Key) {
        if let previous = resultCosts[key] {
            retainedResultBytes -= previous
            resultOrder.removeAll { $0 == key }
        }

        let cost = Self.retainedCost(of: result)
        results[key] = result
        resultCosts[key] = cost
        resultOrder.append(key)
        retainedResultBytes += cost

        // One oversized rendered result is more useful than an empty response pane. Its
        // raw body is still transport-bounded; the estimate can exceed the cache limit
        // because invalid UTF-8 expands into replacement characters.
        while retainedResultBytes > maxRetainedResultBytes,
              resultOrder.count > 1,
              let oldest = resultOrder.first {
            resultOrder.removeFirst()
            results.removeValue(forKey: oldest)
            retainedResultBytes -= resultCosts.removeValue(forKey: oldest) ?? 0
        }
    }

    private static func retainedCost(of result: HTTPResult) -> Int {
        result.body.utf8.count
            + (result.failure?.utf8.count ?? 0)
            + result.headers.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
    }

    // MARK: - Building

    // Exactly what goes on the wire: the address with {{env}} filled in, the headers in
    // the order they are sent, and the body if there is one. Sending and writing the
    // request out as curl both read this, so what is copied is what would be sent.
    struct ResolvedRequest {
        var url: String
        var headers: [HeaderField]
        var body: String?
    }

    nonisolated static func resolve(_ request: SavedRequest, environment: ApiEnvironment,
                                    authorization: String?) -> ResolvedRequest {
        // {{env}} is substituted at the last moment, so the saved request stays a
        // template and the same list serves both environments.
        let url = environment.resolve(request.expandedURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var headers: [HeaderField] = []
        // Setting a header twice replaces it rather than sending it twice, the way
        // URLRequest treats it, and the name is matched however it was typed.
        func set(_ key: String, _ value: String) {
            let field = HeaderField(key: key, value: value)
            if let index = headers.firstIndex(where: {
                $0.key.caseInsensitiveCompare(key) == .orderedSame
            }) {
                headers[index] = field
            } else {
                headers.append(field)
            }
        }

        // The collection's token goes on first, so an Authorization header typed into the
        // request itself still wins.
        if let authorization, request.useAuth {
            set("Authorization", authorization)
        }

        for header in request.headers where header.enabled && !header.key.isEmpty {
            set(header.key, header.value)
        }

        var body: String?
        if request.bodyType != .none, !request.body.isEmpty {
            body = request.body
            // A Content-Type typed by hand is the more deliberate choice, so the one
            // implied by the body type only fills a gap.
            if !headers.contains(where: { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }),
               let contentType = request.bodyType.contentType {
                set("Content-Type", contentType)
            }
        }
        return ResolvedRequest(url: url, headers: headers, body: body)
    }

    // What stops a request before it is sent. Each case carries its own wording, since
    // "check the URL" and "check that header" send you looking in different places.
    enum Problem: Error {
        case url
        case headerName(String)

        var message: String {
            switch self {
            case .url:
                "That URL is not valid."
            case .headerName(let name):
                """
                "\(name)" is not a header name. A name can hold letters, digits and \
                !#$%&'*+-.^_`|~, but not spaces or colons. A whole "Name: value" line \
                belongs in both boxes, not just the first.
                """
            }
        }
    }

    private static func build(_ request: SavedRequest, environment: ApiEnvironment,
                              authorization: String?) -> Result<URLRequest, Problem> {
        let resolved = resolve(request, environment: environment, authorization: authorization)
        guard let url = URL(string: resolved.url), url.scheme != nil, url.host != nil else {
            return .failure(.url)
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        for header in resolved.headers {
            guard HeaderField.isValidName(header.key) else {
                return .failure(.headerName(header.key))
            }
            urlRequest.setValue(header.value, forHTTPHeaderField: header.key)
        }
        if let body = resolved.body {
            urlRequest.httpBody = Data(body.utf8)
        }
        return .success(urlRequest)
    }

    // MARK: - Reading the response

    private static func readable(_ data: Data, contentType: String?, isTruncated: Bool) -> String {
        guard !data.isEmpty else { return "" }
        let text: String
        if isTruncated {
            text = String(decoding: data, as: UTF8.self)
        } else if let decoded = String(data: data, encoding: .utf8) {
            text = decoded
        } else {
            return "\(data.count) bytes that are not text."
        }
        guard !isTruncated,
              data.count <= 256 * 1024,
              contentType?.localizedCaseInsensitiveContains("json") == true
        else { return text }
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

private struct BoundedURLResponse: @unchecked Sendable {
    let data: Data
    let response: URLResponse
    let byteCount: Int
    let isTruncated: Bool
}

// URLSession normally assembles a complete response before returning it. This delegate
// keeps a prefix instead and stops the task on the first chunk beyond the limit, which
// bounds both transfer work and application memory for unknown or misleading servers.
private final class BoundedResponseLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<BoundedURLResponse, Error>?
    private var response: URLResponse?
    private var data = Data()
    private var receivedByteCount = 0
    private var isTruncated = false
    private var isCancelled = false
    private var isFinished = false

    init(limit: Int, configuration: URLSessionConfiguration) {
        self.limit = limit
        self.configuration = configuration
    }

    func load(_ request: URLRequest) async throws -> BoundedURLResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !isCancelled else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let session = URLSession(configuration: configuration,
                                         delegate: self,
                                         delegateQueue: nil)
                self.session = session
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        self.response = response
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        receivedByteCount += chunk.count
        let remaining = max(0, limit - data.count)
        data.append(contentsOf: chunk.prefix(remaining))
        let crossedLimit = chunk.count > remaining
        if crossedLimit { isTruncated = true }
        lock.unlock()

        if crossedLimit { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: (any Error)?) {
        lock.lock()
        guard !isFinished, let continuation else {
            lock.unlock()
            return
        }
        isFinished = true
        self.continuation = nil
        self.task = nil

        let result: Result<BoundedURLResponse, Error>
        if isTruncated, let response {
            let expected = response.expectedContentLength > 0
                ? Int(response.expectedContentLength)
                : 0
            result = .success(BoundedURLResponse(data: data,
                                                 response: response,
                                                 byteCount: max(receivedByteCount, expected),
                                                 isTruncated: true))
        } else if isCancelled {
            result = .failure(CancellationError())
        } else if let error {
            result = .failure(error)
        } else if let response {
            result = .success(BoundedURLResponse(data: data,
                                                 response: response,
                                                 byteCount: receivedByteCount,
                                                 isTruncated: false))
        } else {
            result = .failure(URLError(.badServerResponse))
        }
        lock.unlock()

        session.finishTasksAndInvalidate()
        continuation.resume(with: result)
    }
}
