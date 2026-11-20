import Foundation
import NIOCore
import NIOPosix
import Synchronization

// A server on this machine that answers every request with the same bytes and hangs up.
// The bytes are a whole HTTP response, so a test can send anything a real server might,
// such as a download or a login wall.
final class CannedHTTPServer: Sendable {
    private let reply: Data
    private let listener = Mutex<Channel?>(nil)

    init(reply: String) {
        self.reply = Data(reply.utf8)
    }

    func start() async throws -> UInt16 {
        let reply = reply
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(Answer(reply: reply))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        listener.withLock { $0 = channel }
        return UInt16(channel.localAddress?.port ?? 0)
    }

    func stop() {
        listener.withLock { $0 }?.close(promise: nil)
    }

    private final class Answer: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        private let reply: Data
        private var answered = false

        init(reply: Data) {
            self.reply = reply
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            guard !answered else { return }
            answered = true
            let channel = context.channel
            context.writeAndFlush(NIOAny(ByteBuffer(bytes: reply)))
                .whenComplete { _ in channel.close(promise: nil) }
        }
    }
}
