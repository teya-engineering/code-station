import Foundation
import Network

// A one-shot web server on the loopback interface. The browser finishes the OAuth dance
// by being redirected here, which is how the authorization code gets back into the app
// without the user copying anything by hand.
//
// Binding and waiting are separate on purpose: the browser must not be sent anywhere
// until the port is actually listening, and a port that is already taken should be an
// error before a tab opens rather than a wait that goes nowhere.
//
// State is only ever touched on `queue`, so the server is safe to hand across tasks even
// though Network's callbacks arrive on their own.
final class LoopbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "conductor.oauth.callback")
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var ready: CheckedContinuation<Void, Error>?
    private var waiter: CheckedContinuation<[String: String], Error>?
    // A redirect that lands before anyone asks for it, which the timeout can also fill.
    private var arrived: Result<[String: String], Error>?
    private var timeoutItem: DispatchWorkItem?
    // Set once the server is done, so a bind retry already in the queue does not open a
    // listener nobody is waiting for any more.
    private var stopped = false

    // Returns once the port is listening, or throws if it cannot be.
    func start(port: UInt16, timeout: TimeInterval = 300) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { self.begin(port: port, timeout: timeout, ready: continuation) }
            }
        } onCancel: {
            queue.async { self.giveUp(CancellationError()) }
        }
    }

    // The query the redirect carried: the code and state, or the provider's error.
    func waitForRedirect() async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let arrived = self.arrived {
                        continuation.resume(with: arrived)
                        return
                    }
                    self.waiter = continuation
                }
            }
        } onCancel: {
            queue.async { self.giveUp(CancellationError()) }
        }
    }

    func stop() {
        queue.async { self.cleanUp() }
    }

    // MARK: - Listening

    private func begin(port: UInt16,
                       timeout: TimeInterval,
                       ready continuation: CheckedContinuation<Void, Error>) {
        ready = continuation

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            giveUp(OAuthError("\(port) is not a usable port."))
            return
        }

        let item = DispatchWorkItem { [weak self] in
            self?.giveUp(OAuthError("Timed out waiting for the browser to come back."))
        }
        timeoutItem = item
        queue.asyncAfter(deadline: .now() + timeout, execute: item)

        listen(on: nwPort, attemptsLeft: 12)
    }

    // Cancelling a listener frees its port a moment later rather than at once, so a
    // sign-in started right after one was called off would otherwise be told the address
    // is still in use. The bind is retried for about a second before that is believed.
    private func listen(on nwPort: NWEndpoint.Port, attemptsLeft: Int) {
        guard !stopped else { return }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredInterfaceType = .loopback

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            giveUp(OAuthError("Could not listen on port \(nwPort.rawValue): \(error.localizedDescription)."))
            return
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.queue.async { self.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            // A listener being retired still reports its state, and that is not news.
            guard let self, let listener, self.listener === listener else { return }
            self.queue.async {
                guard self.listener === listener else { return }
                switch state {
                case .ready:
                    self.resumeReady(.success(()))
                case .failed(let error):
                    self.listener = nil
                    listener.cancel()
                    guard attemptsLeft > 0, Self.isAddressInUse(error) else {
                        self.giveUp(OAuthError(
                            "Could not listen on port \(nwPort.rawValue): \(error.localizedDescription)"))
                        return
                    }
                    self.queue.asyncAfter(deadline: .now() + 0.05) {
                        self.listen(on: nwPort, attemptsLeft: attemptsLeft - 1)
                    }
                default:
                    break
                }
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private static func isAddressInUse(_ error: NWError) -> Bool {
        guard case .posix(let code) = error else { return false }
        return code == .EADDRINUSE
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        // One read is enough: the redirect is a bare GET, so the request line carrying the
        // query is in the first packet.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else { return }
            self.queue.async {
                guard let data, let request = String(data: data, encoding: .utf8),
                      let query = Self.query(from: request) else {
                    self.reply(on: connection, body: Self.page(title: "Nothing to do here",
                                                               detail: "This window can be closed."))
                    return
                }
                let landed = query["error"] == nil
                // Finishing tears the listener down, and that has to wait until the page
                // is on its way out, or the browser shows a connection error instead of it.
                self.reply(on: connection,
                           body: Self.page(title: landed ? "Signed in" : "Sign-in failed",
                                           detail: landed ? "You can close this window and go back to Conductor."
                                                          : query["error_description"] ?? query["error"] ?? "")) {
                    self.finish(.success(query))
                }
            }
        }
    }

    private func reply(on connection: NWConnection, body: String, then done: (@Sendable () -> Void)? = nil) {
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            guard let self, let done else { return }
            self.queue.async { done() }
        })
    }

    // MARK: - Finishing

    private func resumeReady(_ result: Result<Void, Error>) {
        guard let ready else { return }
        self.ready = nil
        ready.resume(with: result)
    }

    // Whatever went wrong, both halves have to hear about it: the caller may be waiting
    // on either the bind or the redirect.
    private func giveUp(_ error: Error) {
        resumeReady(.failure(error))
        finish(.failure(error))
    }

    private func finish(_ result: Result<[String: String], Error>) {
        if let waiter {
            self.waiter = nil
            waiter.resume(with: result)
        } else if arrived == nil {
            arrived = result
        }
        cleanUp()
    }

    private func cleanUp() {
        stopped = true
        timeoutItem?.cancel()
        timeoutItem = nil
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }

    // MARK: - Parsing

    static func query(from request: String) -> [String: String]? {
        guard let line = request.split(separator: "\r\n", maxSplits: 1).first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        // The target is a path, so it only becomes parseable once it is a whole URL.
        guard let components = URLComponents(string: "http://localhost" + parts[1]),
              let items = components.queryItems else { return [:] }
        return Dictionary(items.compactMap { item in
            item.value.map { (item.name, $0) }
        }, uniquingKeysWith: { first, _ in first })
    }

    private static func page(title: String, detail: String) -> String {
        """
        <!doctype html><meta charset="utf-8"><title>\(title)</title>
        <body style="font-family:-apple-system,system-ui,sans-serif;background:#f6f5f1;color:#1c1c1a;
        display:flex;align-items:center;justify-content:center;height:100vh;margin:0">
        <div style="text-align:center"><h1 style="font-weight:600;font-size:20px">\(title)</h1>
        <p style="color:#6b6b66;font-size:14px">\(detail)</p></div>
        """
    }
}
