import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Synchronization

// A one-shot web server on the loopback interface. The browser finishes the OAuth dance
// by being redirected here, which is how the authorization code gets back into the app
// without the user copying anything by hand.
//
// Binding and waiting are separate on purpose: the browser must not be sent anywhere
// until the port is actually listening, and a port that is already taken should be an
// error before a tab opens rather than a wait that goes nowhere.
final class LoopbackServer: Sendable {
    private struct State {
        var listeners: [Channel] = []
        var waiter: CheckedContinuation<[String: String], Error>?
        // A redirect that lands before anyone asks for it, which the timeout can also fill.
        var arrived: Result<[String: String], Error>?
        var timeout: Task<Void, Never>?
        // Set once the server is done, so a bind still in flight closes what it opened.
        var stopped = false
    }

    private let state = Mutex(State())

    // Returns once the port is listening, or throws if it cannot be.
    func start(port: UInt16, path: String = "/callback", timeout: TimeInterval = 300) async throws {
        try Task.checkCancellation()
        let listeners: [Channel]
        do {
            listeners = try await bind(port: port, path: path.isEmpty ? "/" : path, attemptsLeft: 12)
        } catch {
            finish(.failure(error))
            throw error
        }
        let kept = state.withLock { state in
            guard !state.stopped else { return false }
            state.listeners = listeners
            state.timeout = Task { [weak self] in
                guard (try? await Task.sleep(for: .seconds(timeout))) != nil else { return }
                self?.finish(.failure(OAuthError("Timed out waiting for the browser to come back.")))
            }
            return true
        }
        guard kept, !Task.isCancelled else {
            listeners.forEach { $0.close(promise: nil) }
            finish(.failure(CancellationError()))
            throw CancellationError()
        }
    }

    // The query the redirect carried: the code and state, or the provider's error.
    func waitForRedirect() async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let arrived = state.withLock { state in
                    if state.arrived == nil { state.waiter = continuation }
                    return state.arrived
                }
                if let arrived { continuation.resume(with: arrived) }
            }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }

    func stop() {
        finish(.failure(CancellationError()))
    }

    // MARK: - Listening

    // The callback URL usually says localhost, which a browser may try over IPv6 first, so
    // both loopback addresses listen. A Mac with IPv6 turned off still signs in over IPv4.
    //
    // Closing a listener frees its port a moment later rather than at once, so a sign-in
    // started right after one was called off would otherwise be told the port is still in
    // use. The bind is retried for about half a second before that is believed.
    private func bind(port: UInt16, path: String, attemptsLeft: Int) async throws -> [Channel] {
        do {
            let ipv4 = try await bootstrap(path: path).bind(host: "127.0.0.1", port: Int(port)).get()
            guard let ipv6 = try? await bootstrap(path: path).bind(host: "::1", port: Int(port)).get()
            else { return [ipv4] }
            return [ipv4, ipv6]
        } catch let error as IOError where error.errnoCode == EADDRINUSE {
            guard attemptsLeft > 0 else {
                throw OAuthError("Port \(port) is already in use by another program.")
            }
            try await Task.sleep(for: .milliseconds(50))
            return try await bind(port: port, path: path, attemptsLeft: attemptsLeft - 1)
        } catch {
            throw OAuthError("Could not listen on port \(port): \(error).")
        }
    }

    private func bootstrap(path: String) -> ServerBootstrap {
        let landed: @Sendable ([String: String]) -> Void = { [weak self] query in
            self?.finish(.success(query))
        }
        return ServerBootstrap(group: LocalHTTP.eventLoops)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(CallbackHandler(path: path, landed: landed))
                }
            }
    }

    // MARK: - Finishing

    // Whatever ends the wait, both halves have to hear about it: the caller may be
    // waiting on either the bind or the redirect.
    private func finish(_ result: Result<[String: String], Error>) {
        let ended = state.withLock { state -> (waiter: CheckedContinuation<[String: String], Error>?,
                                               listeners: [Channel], timeout: Task<Void, Never>?)? in
            guard !state.stopped else { return nil }
            state.stopped = true
            state.arrived = result
            defer {
                state.waiter = nil
                state.listeners = []
                state.timeout = nil
            }
            return (state.waiter, state.listeners, state.timeout)
        }
        guard let ended else { return }
        ended.timeout?.cancel()
        ended.listeners.forEach { $0.close(promise: nil) }
        ended.waiter?.resume(with: result)
    }

    // MARK: - Answering the browser

    private final class CallbackHandler: ChannelInboundHandler {
        typealias InboundIn = HTTPServerRequestPart

        private let path: String
        private let landed: @Sendable ([String: String]) -> Void
        private var head: HTTPRequestHead?

        init(path: String, landed: @escaping @Sendable ([String: String]) -> Void) {
            self.path = path
            self.landed = landed
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let head):
                self.head = head
            case .body:
                break
            case .end:
                guard let head else { return }
                self.head = nil
                let html = [("Content-Type", "text/html; charset=utf-8")]
                guard let query = LoopbackServer.query(method: head.method, target: head.uri, path: path) else {
                    let page = LoopbackServer.page(title: "Nothing to do here",
                                                   detail: "This window can be closed.")
                    LocalHTTP.reply(on: context.channel, status: .ok, headers: html, body: Data(page.utf8))
                    return
                }
                let signedIn = query["error"] == nil
                let page = LoopbackServer.page(
                    title: signedIn ? "Signed in" : "Sign-in failed",
                    detail: signedIn ? "You can close this window and go back to Code Station."
                                     : query["error_description"] ?? query["error"] ?? "")
                // The page goes out before the listener closes, so the browser sees it.
                let landed = self.landed
                LocalHTTP.reply(on: context.channel, status: .ok, headers: html, body: Data(page.utf8))
                    .whenComplete { _ in landed(query) }
            }
        }
    }

    // MARK: - Reading the request

    static func query(method: NIOHTTP1.HTTPMethod, target: String, path: String = "/callback") -> [String: String]? {
        guard method == .GET, LocalHTTP.path(in: target) == path else { return nil }
        return LocalHTTP.query(in: target)
    }

    static func page(title: String, detail: String) -> String {
        let title = title.htmlEscaped
        let detail = detail.htmlEscaped
        return """
        <!doctype html><meta charset="utf-8"><title>\(title)</title>
        <body style="font-family:-apple-system,system-ui,sans-serif;background:#f6f5f1;color:#1c1c1a;
        display:flex;align-items:center;justify-content:center;height:100vh;margin:0">
        <div style="text-align:center"><h1 style="font-weight:600;font-size:20px">\(title)</h1>
        <p style="color:#6b6b66;font-size:14px">\(detail)</p></div>
        """
    }
}
