import Foundation
import NIOCore

/// Consumes the 68-byte BitTorrent handshake of an inbound connection and hands
/// it to the session for routing to the matching torrent. Reads are paused so
/// post-handshake bytes can't arrive before the peer pipeline is installed; the
/// adopting PeerManager resumes them after setup.
final class InboundHandshakeRouter: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private var buffer = ByteBuffer()
    private var routed = false
    private let onHandshake: @Sendable (Channel, Handshake) -> Void

    init(onHandshake: @escaping @Sendable (Channel, Handshake) -> Void) {
        self.onHandshake = onHandshake
    }


    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if routed {
            context.fireChannelRead(data)
            return
        }

        var chunk = unwrapInboundIn(data)
        buffer.writeBuffer(&chunk)
        guard buffer.readableBytes >= Handshake.length else { return }

        let bytes = buffer.readBytes(length: Handshake.length) ?? []
        buffer.clear()
        do {
            let handshake = try Handshake.decode(from: Data(bytes))
            routed = true
            context.channel.setOption(ChannelOptions.autoRead, value: false).whenComplete { result in
                if case .success = result {
                    self.onHandshake(context.channel, handshake)
                } else {
                    context.close(promise: nil)
                }
            }
        } catch {
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
