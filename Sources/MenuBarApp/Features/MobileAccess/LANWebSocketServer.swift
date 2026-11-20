import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import Synchronization

struct LANServerFailure: Error, Equatable, Sendable {
    let message: String
}

struct LANResource: Sendable {
    let data: Data
    let contentType: String
}

// The phone's way in to mobile access, on one port of the local network: the page, its
// assets and design previews over plain HTTP, and the session itself over a WebSocket.
final class LANWebSocketServer: Sendable {
    typealias ConnectionID = UUID

    // Files from the phone travel inside a prompt as base64, so a message has to fit a few
    // photos. The phone keeps its uploads under 18 MB, which is 24 MB once encoded.
    static let maximumMessageSize = 25 * 1024 * 1024

    private struct State {
        var listener: Channel?
        var starting = false
        var stopped = false
        var sockets: [ConnectionID: Channel] = [:]
    }

    private let page: Data
    private let resource: @Sendable (String) async -> LANResource?
    private let onOpen: @Sendable (ConnectionID, String) -> Void
    private let onMessage: @Sendable (ConnectionID, String) -> Void
    private let onClose: @Sendable (ConnectionID) -> Void
    private let state = Mutex(State())

    init(page: Data,
         resource: @escaping @Sendable (String) async -> LANResource? = { _ in nil },
         onOpen: @escaping @Sendable (ConnectionID, String) -> Void,
         onMessage: @escaping @Sendable (ConnectionID, String) -> Void,
         onClose: @escaping @Sendable (ConnectionID) -> Void) {
        self.page = page
        self.resource = resource
        self.onOpen = onOpen
        self.onMessage = onMessage
        self.onClose = onClose
    }

    func start() async throws -> UInt16 {
        let busy = state.withLock { state in
            defer { state.starting = true }
            return state.starting || state.listener != nil || state.stopped
        }
        guard !busy else { throw LANServerFailure(message: "Mobile access is already listening.") }

        let listener: Channel
        do {
            // The phone is given this Mac's IPv4 address, so IPv4 is all that has to listen.
            listener = try await ServerBootstrap(group: LocalHTTP.eventLoops)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { [weak self] channel in
                    let server = self
                    return channel.eventLoop.makeCompletedFuture {
                        guard let server else { throw ChannelError.ioOnClosedChannel }
                        try server.prepare(channel)
                    }
                }
                .bind(host: "0.0.0.0", port: 0)
                .get()
        } catch {
            state.withLock { $0.starting = false }
            throw LANServerFailure(message: "Mobile access could not start: \(error)")
        }

        let kept = state.withLock { state in
            state.starting = false
            guard !state.stopped else { return false }
            state.listener = listener
            return true
        }
        guard kept, let port = listener.localAddress?.port else {
            listener.close(promise: nil)
            throw LANServerFailure(message: kept ? "The listening port could not be read."
                                                 : "Mobile access stopped.")
        }
        return UInt16(port)
    }

    func send(_ text: String, to connectionID: ConnectionID) {
        guard let socket = state.withLock({ $0.sockets[connectionID] }) else { return }
        socket.writeAndFlush(WebSocketFrame(fin: true, opcode: .text, data: ByteBuffer(string: text)),
                             promise: nil)
    }

    func close(_ connectionID: ConnectionID) {
        guard let socket = state.withLock({ $0.sockets.removeValue(forKey: connectionID) }) else { return }
        onClose(connectionID)
        Self.sayGoodbye(on: socket)
    }

    func stop() {
        let (listener, sockets) = state.withLock { state in
            state.stopped = true
            defer {
                state.listener = nil
                state.sockets = [:]
            }
            return (state.listener, state.sockets)
        }
        listener?.close(promise: nil)
        for (connectionID, socket) in sockets {
            onClose(connectionID)
            Self.sayGoodbye(on: socket)
        }
    }

    // Writes on a channel go out in order, so a close sent after an error message still
    // lets the error reach the browser and stop its reconnect loop.
    private static func sayGoodbye(on socket: Channel) {
        socket.writeAndFlush(WebSocketFrame(fin: true, opcode: .connectionClose, data: ByteBuffer()))
            .whenComplete { _ in socket.close(promise: nil) }
    }

    // MARK: - Connections

    // Every connection starts as HTTP. A request for a pairing's socket is upgraded, and
    // then the page handler steps aside for the WebSocket one. Anything else is answered
    // as a page and the connection closes.
    private func prepare(_ channel: Channel) throws {
        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: Self.maximumMessageSize,
            shouldUpgrade: { channel, head in
                channel.eventLoop.makeSucceededFuture(Self.pairingID(in: head.uri) == nil ? nil : HTTPHeaders())
            },
            upgradePipelineHandler: { [weak self] channel, head in
                let server = self
                return channel.eventLoop.makeCompletedFuture {
                    guard let server, let pairingID = Self.pairingID(in: head.uri) else {
                        throw ChannelError.ioOnClosedChannel
                    }
                    try channel.pipeline.syncOperations.addHandler(NIOWebSocketFrameAggregator(
                        minNonFinalFragmentSize: 0,
                        maxAccumulatedFrameCount: 1_000,
                        maxAccumulatedFrameSize: Self.maximumMessageSize))
                    try channel.pipeline.syncOperations.addHandler(SocketHandler(server: server, pairingID: pairingID))
                }
            })
        try channel.pipeline.syncOperations.configureHTTPServerPipeline(
            withServerUpgrade: (upgraders: [upgrader], completionHandler: { context in
                context.pipeline.removeHandler(name: PageHandler.name, promise: nil)
            }))
        try channel.pipeline.syncOperations.addHandler(PageHandler(server: self), name: PageHandler.name)
    }

    private static func pairingID(in target: String) -> String? {
        let path = LocalHTTP.path(in: target)
        guard path.hasPrefix("/socket/") else { return nil }
        let pairingID = String(path.dropFirst("/socket/".count))
        return UUID(uuidString: pairingID) == nil ? nil : pairingID
    }

    private func opened(_ connectionID: ConnectionID, socket: Channel, pairingID: String) {
        let kept = state.withLock { state in
            guard !state.stopped else { return false }
            state.sockets[connectionID] = socket
            return true
        }
        guard kept else {
            socket.close(promise: nil)
            return
        }
        onOpen(connectionID, pairingID)
    }

    private func received(_ text: String, from connectionID: ConnectionID) {
        onMessage(connectionID, text)
    }

    private func lost(_ connectionID: ConnectionID) {
        guard state.withLock({ $0.sockets.removeValue(forKey: connectionID) }) != nil else { return }
        onClose(connectionID)
    }

    // MARK: - Pages

    private func answer(_ head: HTTPRequestHead, on channel: Channel) {
        let path = LocalHTTP.path(in: head.uri)
        guard head.method == .GET else {
            reply(on: channel, status: .notFound, body: Data("Not found".utf8))
            return
        }
        if path.hasPrefix("/design/") || path.hasPrefix("/assets/") {
            Task {
                let found = await resource(path)
                reply(on: channel, status: found == nil ? .notFound : .ok,
                      body: found?.data ?? Data(),
                      contentType: found?.contentType ?? "text/plain",
                      design: path.hasPrefix("/design/"))
            }
        } else if path.hasPrefix("/mobile/") {
            reply(on: channel, status: .ok, body: page, contentType: "text/html; charset=utf-8")
        } else {
            reply(on: channel, status: .notFound, body: Data("Not found".utf8))
        }
    }

    private func reply(on channel: Channel, status: HTTPResponseStatus, body: Data,
                       contentType: String = "text/plain; charset=utf-8", design: Bool = false) {
        let policy = design
            ? "sandbox allow-scripts; default-src 'none'; script-src 'self' 'unsafe-inline'; "
                + "style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; "
                + "frame-src 'self'; connect-src 'none'; form-action 'none'; base-uri 'none'"
            : "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
                + "connect-src ws: wss:; frame-src 'self'; base-uri 'none'; object-src 'none'"
        LocalHTTP.reply(on: channel, status: status, headers: [
            ("Content-Type", contentType),
            ("Cache-Control", "no-store"),
            ("Content-Security-Policy", policy),
            ("Referrer-Policy", "no-referrer"),
            ("X-Content-Type-Options", "nosniff"),
        ], body: body)
    }

    // Removable, since the upgrade to a socket takes it out of the pipeline.
    private final class PageHandler: ChannelInboundHandler, RemovableChannelHandler {
        typealias InboundIn = HTTPServerRequestPart
        static let name = "page"

        private weak var server: LANWebSocketServer?
        private var head: HTTPRequestHead?

        init(server: LANWebSocketServer) {
            self.server = server
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
                server?.answer(head, on: context.channel)
            }
        }
    }

    // MARK: - The socket

    private final class SocketHandler: ChannelInboundHandler {
        typealias InboundIn = WebSocketFrame

        private let connectionID = ConnectionID()
        private let pairingID: String
        private weak var server: LANWebSocketServer?

        init(server: LANWebSocketServer, pairingID: String) {
            self.server = server
            self.pairingID = pairingID
        }

        func handlerAdded(context: ChannelHandlerContext) {
            server?.opened(connectionID, socket: context.channel, pairingID: pairingID)
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let frame = unwrapInboundIn(data)
            switch frame.opcode {
            case .text:
                server?.received(String(buffer: frame.unmaskedData), from: connectionID)
            case .ping:
                context.writeAndFlush(NIOAny(WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)),
                                      promise: nil)
            case .pong:
                break
            default:
                // A close from the browser, or binary data the protocol never sends.
                server?.close(connectionID)
            }
        }

        func channelInactive(context: ChannelHandlerContext) {
            server?.lost(connectionID)
            context.fireChannelInactive()
        }
    }
}
