import Darwin
import Foundation

// The station socket's plumbing: a Unix domain socket, and one connected end of it that
// sends and receives newline-delimited lines. Both the host's server and the client use
// it, so the two sides frame messages the same way.

struct SocketFailure: Error, CustomStringConvertible {
    let description: String

    init(_ what: String, errno code: Int32 = errno) {
        description = "\(what): \(String(cString: strerror(code)))"
    }
}

enum UnixSocket {
    // The longest path `sun_path` holds, leaving room for the terminating zero.
    static let maximumPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    // A socket listening at `path`, which only this user may open. Whatever was left at
    // the path is replaced: the caller holds the station lock, so nobody else serves it.
    static func listen(at path: String) throws -> Int32 {
        guard path.utf8.count <= maximumPathLength else {
            throw SocketFailure("\(path) is too long for a socket", errno: ENAMETOOLONG)
        }
        unlink(path)
        let fd = try makeSocket()
        var address = self.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let failure = SocketFailure("bind \(path)")
            close(fd)
            throw failure
        }
        // Narrowed before anyone can connect: a connection is only accepted once the
        // socket listens.
        guard chmod(path, 0o600) == 0, Darwin.listen(fd, 16) == 0 else {
            let failure = SocketFailure("listen on \(path)")
            close(fd)
            unlink(path)
            throw failure
        }
        return fd
    }

    // A socket connected to the one listening at `path`, or nil when nobody listens.
    static func connect(to path: String) -> Int32? {
        guard path.utf8.count <= maximumPathLength, let fd = try? makeSocket() else { return nil }
        var address = self.address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    static func accept(_ listener: Int32) -> Int32? {
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return nil }
        prepare(fd)
        return fd
    }

    // The user on the other end of a connected socket, as the kernel knows it.
    static func peerUID(_ fd: Int32) -> uid_t? {
        var uid = uid_t(0), gid = gid_t(0)
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    private static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketFailure("socket") }
        prepare(fd)
        return fd
    }

    // Not inherited by the agents and shells the process starts, and a write to a peer
    // that has gone fails as an error rather than killing the process.
    private static func prepare(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let bytes = Array(path.utf8.prefix(maximumPathLength))
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }
}

// One connected end of the station socket. Lines arrive on the main queue in the order
// they were sent, without their newline; each `send` goes out as one line. Reading and
// writing happen on a queue of the socket's own, so a slow peer never holds up the main
// actor. `onClose` is called once, when the peer goes or `close` is called.
final class LineSocket: @unchecked Sendable {
    private let fd: Int32
    private let queue = DispatchQueue(label: "com.teya.code-station.socket")
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private var closed = false
    private var onLine: (@MainActor (Data) -> Void)?
    private var onClose: (@MainActor () -> Void)?

    // A line longer than this is not a message the station sends, so the peer is dropped.
    static let maximumLine = 64 * 1024 * 1024

    init(fd: Int32) {
        self.fd = fd
    }

    func start(onLine: @escaping @MainActor (Data) -> Void, onClose: @escaping @MainActor () -> Void) {
        queue.async { [self] in
            // Read from one place only: a second reader would block on data the first took.
            guard !closed, source == nil else { return }
            self.onLine = onLine
            self.onClose = onClose
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable() }
            source.setCancelHandler { [fd] in Darwin.close(fd) }
            self.source = source
            source.resume()
        }
    }

    func send(_ line: Data) {
        queue.async { [self] in
            guard !closed else { return }
            var data = line
            data.append(0x0A)
            let written = data.withUnsafeBytes { raw -> Bool in
                var offset = 0
                while offset < raw.count {
                    let count = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if count < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    offset += count
                }
                return true
            }
            if !written { shut() }
        }
    }

    func close() {
        queue.async { [self] in shut() }
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = read(fd, &chunk, chunk.count)
        if count < 0, errno == EINTR || errno == EAGAIN { return }
        guard count > 0 else {
            shut()
            return
        }
        buffer.append(contentsOf: chunk[0..<count])
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(Data(buffer[buffer.startIndex..<newline]))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        guard buffer.count <= Self.maximumLine else {
            shut()
            return
        }
        guard !lines.isEmpty, let onLine else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                for line in lines where !line.isEmpty { onLine(line) }
            }
        }
    }

    private func shut() {
        guard !closed else { return }
        closed = true
        if let source {
            source.cancel()
        } else {
            Darwin.close(fd)
        }
        source = nil
        let onClose = self.onClose
        onLine = nil
        self.onClose = nil
        if let onClose {
            DispatchQueue.main.async { MainActor.assumeIsolated { onClose() } }
        }
    }
}
