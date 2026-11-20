import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

// What the app's small local web servers share: the event loops they run on, reading the
// target of a request, and answering it once before hanging up.
enum LocalHTTP {
    static let eventLoops = MultiThreadedEventLoopGroup.singleton

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

    // Each server answers one request per connection, so the reply always closes it.
    // The future completes once the reply has been written, whether or not the close
    // that follows succeeds.
    @discardableResult
    static func reply(on channel: Channel,
                      status: HTTPResponseStatus,
                      headers: [(String, String)] = [],
                      body: Data = Data()) -> EventLoopFuture<Void> {
        var fields = HTTPHeaders(headers)
        fields.replaceOrAdd(name: "Content-Length", value: String(body.count))
        fields.replaceOrAdd(name: "Connection", value: "close")
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: fields)
        channel.write(HTTPServerResponsePart.head(head), promise: nil)
        channel.write(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: body))), promise: nil)
        let written = channel.writeAndFlush(HTTPServerResponsePart.end(nil))
        written.whenComplete { _ in channel.close(promise: nil) }
        return written
    }
}
