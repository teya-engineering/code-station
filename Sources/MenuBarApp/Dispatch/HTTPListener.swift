import Foundation
import Network

// What the two local servers share: reading the GET they are sent, and bringing a
// listener up on a port.

// The request line of a GET, which is all either local server ever answers.
enum HTTPRequestLine {
    // The target of a GET request line, or nil for anything else, so a stray POST or a
    // garbled packet is refused rather than guessed at.
    static func target(of line: Substring) -> String? {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        return String(parts[1])
    }

    static func query(in target: String) -> [String: String] {
        guard let items = components(of: target)?.queryItems else { return [:] }
        return Dictionary(items.compactMap { item in
            item.value.map { (item.name, $0) }
        }, uniquingKeysWith: { first, _ in first })
    }

    static func path(in target: String) -> String {
        components(of: target)?.path ?? ""
    }

    // The target is a path, so it only becomes parseable once it is a whole URL.
    private static func components(of target: String) -> URLComponents? {
        URLComponents(string: "http://localhost" + target)
    }
}

// What stops a listener from coming up, in words a sheet can show.
struct ListenerFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// One listener and the wait for it to come up. Network keeps reporting the state of a
// listener after its owner has let go of it, so only the listener held here counts, and
// whoever is waiting is answered exactly once however the start ends.
//
// Everything here runs on the owner's queue, which is what the unchecked marker records.
final class HTTPListener: @unchecked Sendable {
    private var listener: NWListener?
    private var ready: CheckedContinuation<UInt16, Error>?

    var isListening: Bool { listener != nil }

    // Remembers who is waiting for the port to open.
    func expect(_ continuation: CheckedContinuation<UInt16, Error>) {
        ready = continuation
    }

    // Starts `listener` on `queue`, answering the wait with the port once it is up. A bind
    // failure lets the listener go first, so `failed` can start another in its place.
    func start(_ listener: NWListener, on queue: DispatchQueue,
               accept: @escaping @Sendable (NWConnection) -> Void,
               failed: @escaping @Sendable (NWError) -> Void) {
        self.listener = listener
        listener.newConnectionHandler = accept
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.listener === listener else { return }
            switch state {
            case .ready:
                guard let port = listener.port?.rawValue else {
                    self.answer(.failure(ListenerFailure(message: "The listening port could not be read.")))
                    return
                }
                self.answer(.success(port))
            case .failed(let error):
                self.listener = nil
                listener.cancel()
                failed(error)
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    // Answers the wait, if anyone is still waiting.
    func answer(_ result: Result<UInt16, Error>) {
        guard let ready else { return }
        self.ready = nil
        ready.resume(with: result)
    }

    func cancel() {
        listener?.cancel()
        listener = nil
    }
}
