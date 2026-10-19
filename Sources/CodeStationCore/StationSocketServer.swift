import Darwin
import Foundation

// Serves a station host's engine on a Unix domain socket, one `StationConnection` per
// client (see `StationWire` for what is said). Any host runs the same server: the
// daemon, and the GUI while it holds the station.
//
// Only this user can reach it: the socket file is 0600, and the uid of every peer is
// checked as it connects, before it can say anything.
@MainActor
public final class StationSocketServer {
    public let station: StationCommands
    public let version: StationWire.Version
    // The socket path clients connect to, once the server has started.
    public private(set) var endpoint: String?
    // How many clients are connected and past the handshake.
    public var clientCount: Int { peers.count }
    // Called whenever a client comes or goes.
    public var onClientsChanged: (@MainActor () -> Void)?

    private let peerUID: @Sendable (Int32) -> uid_t?
    private var listener: DispatchSourceRead?
    private var peers: [ObjectIdentifier: StationSocketPeer] = [:]
    private var greeting: [ObjectIdentifier: LineSocket] = [:]

    // `peerUID` says which user is on the other end of a connection; tests stand in for
    // the kernel's answer to see another user refused.
    public init(station: StationCommands, version: StationWire.Version = .current,
                peerUID: (@Sendable (Int32) -> uid_t?)? = nil) {
        self.station = station
        self.version = version
        self.peerUID = peerUID ?? { UnixSocket.peerUID($0) }
    }

    // Starts listening at `path`, or at a short path in the temporary folder when `path`
    // is too long for a socket. Answers with the path it listens at.
    @discardableResult
    public func start(at path: String) throws -> String {
        stop()
        let endpoint = StationSocketPath.usable(path)
        let fd = try UnixSocket.listen(at: endpoint)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        let peerUID = self.peerUID
        let me = getuid()
        source.setEventHandler { [weak self] in
            guard let client = UnixSocket.accept(fd) else { return }
            let socket = LineSocket(fd: client)
            MainActor.assumeIsolated {
                guard let self else { return socket.close() }
                guard peerUID(client) == me else {
                    socket.send(StationWire.encode(StationWire.Greeting(refused: .anotherUser)) ?? Data())
                    socket.close()
                    return
                }
                self.greet(socket)
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        listener = source
        self.endpoint = endpoint
        return endpoint
    }

    // Stops listening, removes the socket and lets every client go.
    public func stop() {
        listener?.cancel()
        listener = nil
        if let endpoint { unlink(endpoint) }
        endpoint = nil
        for socket in greeting.values { socket.close() }
        greeting = [:]
        for peer in Array(peers.values) { peer.hangUp() }
    }

    // The first line must be a hello with the same version, or the client is told why
    // not and let go. Every line after it is a request for the client's peer. The socket
    // is read from one place for its whole life, since a hello and the first requests
    // can arrive together.
    private func greet(_ socket: LineSocket) {
        let key = ObjectIdentifier(socket)
        greeting[key] = socket
        var peer: StationSocketPeer?
        socket.start(onLine: { [weak self] line in
            if let peer { return peer.receive(line) }
            guard let self, self.greeting.removeValue(forKey: key) != nil else { return }
            guard let hello = StationWire.decode(StationWire.Hello.self, from: line) else {
                socket.close()
                return
            }
            guard hello.hello == self.version else {
                let refusal = StationRefusal.versionMismatch(client: hello.hello, host: self.version)
                socket.send(StationWire.encode(StationWire.Greeting(refused: refusal)) ?? Data())
                socket.close()
                return
            }
            socket.send(StationWire.encode(StationWire.Greeting(welcome: self.version)) ?? Data())
            peer = self.admit(socket)
        }, onClose: { [weak self] in
            self?.greeting[key] = nil
            peer?.hangUp()
        })
    }

    private func admit(_ socket: LineSocket) -> StationSocketPeer {
        let peer = StationSocketPeer(socket: socket, station: station.connect())
        let key = ObjectIdentifier(peer)
        peers[key] = peer
        peer.onGone = { [weak self] in
            self?.peers[key] = nil
            self?.onClientsChanged?()
        }
        onClientsChanged?()
        return peer
    }
}

// One client of the server: its connection to the engine, the requests it has sent and
// the streams it subscribed to.
//
// Requests start in the order they came, each as soon as it arrives, so a command that
// waits (reading changes, syncing, creating a worktree) holds up nothing the client asks
// for next, such as a stop or a permission answer. Only what opens, closes or ends a
// stream keeps strict order, one after another, so a stream is never closed before it
// is open. A stream starts once its request's answer has gone, so the answer (an open
// session's snapshot) always reaches the client before anything pushed down it.
@MainActor
final class StationSocketPeer {
    let station: any StationInterface
    var onGone: (@MainActor () -> Void)?
    private let socket: LineSocket
    private let ordered: AsyncStream<StationWire.RequestFrame>.Continuation
    private var worker: Task<Void, Never>?
    // Requests under way outside the ordered lane, by id.
    private var running: [Int: Task<Void, Never>] = [:]
    private var subscriptions: [Int: Task<Void, Never>] = [:]
    // Streams each request subscribed to, by request id, started once its answer has gone.
    private var starting: [Int: [() -> Void]] = [:]
    private var gone = false

    init(socket: LineSocket, station: any StationInterface) {
        self.socket = socket
        self.station = station
        let (incoming, ordered) = AsyncStream.makeStream(of: StationWire.RequestFrame.self)
        self.ordered = ordered
        worker = Task { @MainActor [weak self, incoming] in
            for await frame in incoming {
                guard let self else { return }
                await self.run(frame)
            }
        }
    }

    func receive(_ line: Data) {
        guard !gone else { return }
        guard let frame = StationWire.decode(StationWire.RequestFrame.self, from: line) else {
            return hangUp()
        }
        if frame.request.keepsOrder {
            ordered.yield(frame)
            return
        }
        let id = frame.id
        running[id] = Task { @MainActor [weak self] in
            await self?.run(frame)
            self?.running[id] = nil
        }
    }

    private func run(_ frame: StationWire.RequestFrame) async {
        guard !gone else { return }
        do {
            let value = try await frame.request.perform(id: frame.id, for: self)
            reply(frame.id, value)
        } catch {
            starting[frame.id] = nil
            send(StationWire.RefusalFrame(id: frame.id, refusal: error))
        }
        let ready = starting.removeValue(forKey: frame.id) ?? []
        for start in ready { start() }
    }

    // Pushes what `stream` sends as subscription `id`, and `ending` once it ends.
    func forward<Element: Sendable>(_ stream: AsyncStream<Element>, as id: Int, ending: StationPush?,
                                    _ push: @escaping @MainActor (Element) -> StationPush) {
        starting[id, default: []].append { [weak self] in
            guard let self, !self.gone else { return }
            self.subscriptions[id] = Task { @MainActor [weak self] in
                for await element in stream {
                    self?.send(StationWire.PushFrame(subscription: id, push: push(element)))
                }
                guard let self, !Task.isCancelled else { return }
                self.subscriptions[id] = nil
                if let ending { self.send(StationWire.PushFrame(subscription: id, push: ending)) }
            }
        }
    }

    func cancel(_ subscription: Int) {
        subscriptions.removeValue(forKey: subscription)?.cancel()
    }

    func cancelAll() {
        for task in subscriptions.values { task.cancel() }
        subscriptions = [:]
    }

    // The client is gone, or is being let go: everything it had open goes with it.
    func hangUp() {
        guard !gone else { return }
        gone = true
        ordered.finish()
        worker?.cancel()
        for task in running.values { task.cancel() }
        running = [:]
        cancelAll()
        socket.close()
        let station = self.station
        Task { @MainActor in await station.disconnect() }
        onGone?()
    }

    private func reply<Value: Encodable>(_ id: Int, _ value: Value) {
        send(StationWire.ReplyFrame(id: id, value: value))
    }

    private func send(_ frame: some Encodable) {
        guard !gone, let data = StationWire.encode(frame) else { return }
        socket.send(data)
    }
}

// Where the socket goes: beside the station lock, unless that path is too long for
// `sun_path` (104 bytes on macOS), when a short name in the temporary folder stands in.
// The name is taken from the preferred path, so each station gets its own.
public enum StationSocketPath {
    public static func beside(_ lockFile: URL) -> String {
        lockFile.deletingLastPathComponent().appendingPathComponent("station.sock").path
    }

    public static func usable(_ preferred: String) -> String {
        guard preferred.utf8.count > UnixSocket.maximumPathLength else { return preferred }
        let name = "code-station-\(String(StableHash.fnv1a(preferred), radix: 36)).sock"
        for folder in [FileManager.default.temporaryDirectory.path, "/tmp"] {
            let path = (folder as NSString).appendingPathComponent(name)
            if path.utf8.count <= UnixSocket.maximumPathLength { return path }
        }
        return "/tmp/" + name
    }
}

extension StationRefusal {
    static let anotherUser = StationRefusal("This station belongs to another user.")

    static func versionMismatch(client: StationWire.Version, host: StationWire.Version) -> StationRefusal {
        StationRefusal("This Code Station (\(client)) cannot talk to the station host (\(host)). "
                       + "Update Code Station so both are the same version.")
    }
}
