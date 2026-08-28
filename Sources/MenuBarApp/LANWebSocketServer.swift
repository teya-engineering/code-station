import CryptoKit
import Foundation
import Network

struct LANServerFailure: Error, Equatable, Sendable {
    let message: String
}

enum WebSocketHandshake {
    private static let identifier = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    static func accept(for key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + identifier).utf8))
        return Data(digest).base64EncodedString()
    }
}

struct WebSocketFrameDecoder {
    enum Event: Equatable {
        case text(String)
        case close
        case ping(Data)
        case pong
    }

    enum Failure: Error, Equatable {
        case invalidFrame
        case messageTooLarge
    }

    private var buffer = Data()
    private let maximumMessageSize: Int

    init(maximumMessageSize: Int = 1024 * 1024) {
        self.maximumMessageSize = maximumMessageSize
    }

    mutating func append(_ data: Data) throws -> [Event] {
        buffer.append(data)
        var events: [Event] = []

        while true {
            let bytes = [UInt8](buffer)
            guard bytes.count >= 2 else { return events }

            let final = bytes[0] & 0x80 != 0
            let opcode = bytes[0] & 0x0F
            let masked = bytes[1] & 0x80 != 0
            var length = Int(bytes[1] & 0x7F)
            var cursor = 2

            guard final, masked else { throw Failure.invalidFrame }

            if length == 126 {
                guard bytes.count >= cursor + 2 else { return events }
                length = Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1])
                cursor += 2
            } else if length == 127 {
                guard bytes.count >= cursor + 8 else { return events }
                var longLength: UInt64 = 0
                for byte in bytes[cursor..<(cursor + 8)] {
                    longLength = longLength << 8 | UInt64(byte)
                }
                guard longLength <= UInt64(maximumMessageSize) else {
                    throw Failure.messageTooLarge
                }
                length = Int(longLength)
                cursor += 8
            }

            guard length <= maximumMessageSize else { throw Failure.messageTooLarge }
            guard bytes.count >= cursor + 4 + length else { return events }

            let mask = Array(bytes[cursor..<(cursor + 4)])
            cursor += 4
            let payload = Data(bytes[cursor..<(cursor + length)].enumerated().map {
                $0.element ^ mask[$0.offset % 4]
            })
            buffer.removeFirst(cursor + length)

            switch opcode {
            case 0x1:
                guard let text = String(data: payload, encoding: .utf8) else {
                    throw Failure.invalidFrame
                }
                events.append(.text(text))
            case 0x8:
                events.append(.close)
            case 0x9:
                events.append(.ping(payload))
            case 0xA:
                events.append(.pong)
            default:
                throw Failure.invalidFrame
            }
        }
    }
}

final class LANWebSocketServer: @unchecked Sendable {
    typealias ConnectionID = UUID

    // Network delivers every callback on `queue`, and sends are dispatched there before
    // touching this state. The unchecked marker records that confinement for Swift 6.
    private final class Client: @unchecked Sendable {
        let id = ConnectionID()
        let connection: NWConnection
        var requestData = Data()
        var frames = WebSocketFrameDecoder()
        var upgraded = false

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    private struct Request {
        let target: String
        let headers: [String: String]
        let consumedBytes: Int

        // Nil until the whole head has arrived, and for anything that is not a GET.
        static func parse(_ data: Data) -> Request? {
            let separator = Data("\r\n\r\n".utf8)
            guard let range = data.range(of: separator),
                  let text = String(data: data[..<range.lowerBound], encoding: .utf8) else {
                return nil
            }
            let lines = text.components(separatedBy: "\r\n")
            guard let first = lines.first,
                  let target = HTTPRequestLine.target(of: first[...]) else { return nil }
            let headers = Dictionary(lines.dropFirst().compactMap { line -> (String, String)? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
                return (name, value)
            }, uniquingKeysWith: { first, _ in first })
            return Request(target: target,
                           headers: headers,
                           consumedBytes: range.upperBound)
        }
    }

    private let queue = DispatchQueue(label: "code-station.mobile-access")
    private let page: Data
    private let onOpen: @Sendable (ConnectionID, String) -> Void
    private let onMessage: @Sendable (ConnectionID, String) -> Void
    private let onClose: @Sendable (ConnectionID) -> Void
    private let listener = HTTPListener()
    private var clients: [ConnectionID: Client] = [:]

    init(page: Data,
         onOpen: @escaping @Sendable (ConnectionID, String) -> Void,
         onMessage: @escaping @Sendable (ConnectionID, String) -> Void,
         onClose: @escaping @Sendable (ConnectionID) -> Void) {
        self.page = page
        self.onOpen = onOpen
        self.onMessage = onMessage
        self.onClose = onClose
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { self.begin(continuation) }
        }
    }

    func send(_ text: String, to connectionID: ConnectionID) {
        queue.async {
            guard let client = self.clients[connectionID], client.upgraded else { return }
            self.sendFrame(opcode: 0x1, payload: Data(text.utf8), to: client)
        }
    }

    func close(_ connectionID: ConnectionID) {
        queue.async { self.finish(connectionID, sendClose: true) }
    }

    func stop() {
        queue.async {
            self.listener.answer(.failure(LANServerFailure(message: "Mobile access stopped.")))
            self.listener.cancel()
            for id in Array(self.clients.keys) {
                self.finish(id, sendClose: true)
            }
        }
    }

    private func begin(_ continuation: CheckedContinuation<UInt16, Error>) {
        guard !listener.isListening else {
            continuation.resume(throwing: LANServerFailure(
                message: "Mobile access is already listening."))
            return
        }
        let bound: NWListener
        do {
            bound = try NWListener(using: .tcp, on: .any)
        } catch {
            continuation.resume(throwing: LANServerFailure(
                message: "Mobile access could not start: \(error.localizedDescription)"))
            return
        }
        listener.expect(continuation)
        listener.start(bound, on: queue) { [weak self] connection in
            self?.accept(connection)
        } failed: { [weak self] error in
            self?.listener.answer(.failure(LANServerFailure(
                message: "Mobile access could not listen: \(error.localizedDescription)")))
        }
    }

    private func accept(_ connection: NWConnection) {
        let client = Client(connection: connection)
        clients[client.id] = client
        let connectionID = client.id
        connection.stateUpdateHandler = { [weak self] state in
            guard case .failed = state else {
                if case .cancelled = state { self?.finish(connectionID) }
                return
            }
            self?.finish(connectionID)
        }
        connection.start(queue: queue)
        receive(from: client)
    }

    private func receive(from client: Client) {
        client.connection.receive(minimumIncompleteLength: 1,
                                  maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            guard self.clients[client.id] != nil else { return }
            if let data, !data.isEmpty {
                if client.upgraded {
                    self.readFrames(data, from: client)
                } else {
                    client.requestData.append(data)
                    self.readRequest(from: client)
                }
            }
            if complete || error != nil {
                self.finish(client.id)
            } else if self.clients[client.id] != nil {
                self.receive(from: client)
            }
        }
    }

    private func readRequest(from client: Client) {
        guard client.requestData.count <= 32 * 1024 else {
            reply(status: "431 Request Header Fields Too Large", body: Data(), to: client)
            return
        }
        guard let request = Request.parse(client.requestData) else { return }
        let path = HTTPRequestLine.path(in: request.target)

        if path.hasPrefix("/mobile/") {
            reply(status: "200 OK", body: page, contentType: "text/html; charset=utf-8", to: client)
            return
        }

        if path.hasPrefix("/socket/"),
           request.headers["upgrade"]?.lowercased() == "websocket",
           let key = request.headers["sec-websocket-key"] {
            let pairingID = String(path.dropFirst("/socket/".count))
            guard UUID(uuidString: pairingID) != nil else {
                reply(status: "404 Not Found", body: Data(), to: client)
                return
            }
            let response = [
                "HTTP/1.1 101 Switching Protocols",
                "Upgrade: websocket",
                "Connection: Upgrade",
                "Sec-WebSocket-Accept: \(WebSocketHandshake.accept(for: key))",
                "",
                "",
            ].joined(separator: "\r\n")
            client.requestData.removeFirst(request.consumedBytes)
            client.upgraded = true
            client.connection.send(content: Data(response.utf8), completion: .contentProcessed {
                [weak self] error in
                guard let self else { return }
                guard error == nil else {
                    self.finish(client.id)
                    return
                }
                self.onOpen(client.id, pairingID)
                if !client.requestData.isEmpty {
                    let remaining = client.requestData
                    client.requestData.removeAll(keepingCapacity: false)
                    self.readFrames(remaining, from: client)
                }
            })
            return
        }

        reply(status: "404 Not Found", body: Data("Not found".utf8), to: client)
    }

    private func readFrames(_ data: Data, from client: Client) {
        do {
            for event in try client.frames.append(data) {
                switch event {
                case .text(let text):
                    onMessage(client.id, text)
                case .close:
                    finish(client.id, sendClose: true)
                case .ping(let payload):
                    sendFrame(opcode: 0xA, payload: payload, to: client)
                case .pong:
                    break
                }
            }
        } catch {
            finish(client.id, sendClose: true)
        }
    }

    private func reply(status: String, body: Data, contentType: String = "text/plain; charset=utf-8",
                       to client: Client) {
        let header = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Cache-Control: no-store",
            "Content-Security-Policy: default-src 'self'; script-src 'unsafe-inline'; "
                + "style-src 'unsafe-inline'; connect-src ws: wss:",
            "X-Content-Type-Options: nosniff",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        client.connection.send(content: Data(header.utf8) + body, completion: .contentProcessed {
            [weak self] _ in
            self?.finish(client.id)
        })
    }

    private func sendFrame(opcode: UInt8, payload: Data, to client: Client) {
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= Int(UInt16.max) {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            let count = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((count >> UInt64(shift)) & 0xFF))
            }
        }
        frame.append(payload)
        client.connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard error != nil else { return }
            self?.finish(client.id)
        })
    }

    private func finish(_ connectionID: ConnectionID, sendClose: Bool = false) {
        guard let client = clients.removeValue(forKey: connectionID) else { return }
        if sendClose, client.upgraded {
            sendFrame(opcode: 0x8, payload: Data(), to: client)
        }
        client.connection.cancel()
        if client.upgraded { onClose(connectionID) }
    }
}
