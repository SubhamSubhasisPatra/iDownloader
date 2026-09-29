import Foundation
import NIOCore
import NIOPosix
import NIOExtras

/// Manages a single peer TCP connection using SwiftNIO.
public final class PeerConnection: @unchecked Sendable {
    public let address: String
    public let port: UInt16

    private var _channel: Channel?
    private let lock = NSLock()
    private let infoHash: Data
    private let peerID: Data
    private var handshakeConsumed = false
    private var _remotePeerID: Data?
    private var _supportsExtensions = false
    /// Inbound connections already consumed their handshake in the session router.
    private let skipHandshakeOnAttach: Bool

    public var remotePeerID: Data? {
        lock.lock()
        defer { lock.unlock() }
        return _remotePeerID
    }
    public var supportsExtensions: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _supportsExtensions
    }

    public var onMessage: (@Sendable (PeerMessage) -> Void)?
    public var onDisconnect: (@Sendable () -> Void)?

    public init(address: String, port: UInt16, infoHash: Data, peerID: Data) {
        self.address = address
        self.port = port
        self.infoHash = infoHash
        self.peerID = peerID
        self.skipHandshakeOnAttach = false
    }

    /// Wrap a connection accepted by the session listener; its handshake was
    /// decoded by InboundHandshakeRouter before the peer pipeline is installed.
    public init(adopted channel: Channel, infoHash: Data, peerID: Data,
                remoteID: Data, remoteSupportsExtensions: Bool) {
        self.address = channel.remoteAddress.map { "\($0)" } ?? ""
        self.port = UInt16(channel.remoteAddress?.port ?? 0)
        self._channel = channel
        self.infoHash = infoHash
        self.peerID = peerID
        self._remotePeerID = remoteID
        self._supportsExtensions = remoteSupportsExtensions
        self.handshakeConsumed = true
        self.skipHandshakeOnAttach = true
    }

    private func setChannel(_ ch: Channel) {
        lock.lock()
        _channel = ch
        lock.unlock()
    }

    private func getChannel() -> Channel? {
        lock.lock()
        defer { lock.unlock() }
        return _channel
    }

    private func setRemoteInfo(id: Data, extensions: Bool) {
        lock.lock()
        _remotePeerID = id
        _supportsExtensions = extensions
        handshakeConsumed = true
        lock.unlock()
    }

    /// Outbound connections learn the remote handshake asynchronously from the
    /// decoder; wait briefly so extension negotiation isn't raced by callers.
    public func waitForHandshake(timeout seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        while remotePeerID == nil && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    public func connect(on group: EventLoopGroup) async throws -> Channel {
        let onMsg = self.onMessage
        let onDisc = self.onDisconnect
        let decoder = PeerMessageDecoder()
        decoder.onHandshake = { [weak self] handshake in
            self?.setRemoteInfo(
                id: handshake.peerID,
                extensions: handshake.reserved.count > 5 && handshake.reserved[5] & 0x10 != 0)
        }

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .channelOption(ChannelOptions.socketOption(.so_rcvbuf), value: 4 * 1024 * 1024)
            .channelOption(ChannelOptions.socketOption(.so_sndbuf), value: 1024 * 1024)
            .connectTimeout(.seconds(10))
            .channelInitializer { channel in
                let decoderHandler = ByteToMessageHandler(decoder)
                let messageHandler = PeerMessageHandler(onMessage: onMsg, onDisconnect: onDisc)
                return channel.pipeline.addHandlers([decoderHandler, messageHandler])
            }
        let ch = try await nioAwait(bootstrap.connect(host: address, port: Int(port)))

        setChannel(ch)

        // Send handshake as raw bytes (before the encoder is in the pipeline)
        let handshake = Handshake(infoHash: infoHash, peerID: peerID)
        var buffer = ch.allocator.buffer(capacity: Handshake.length)
        buffer.writeBytes(handshake.encode())
        try await nioAwait(ch.writeAndFlush(buffer))

        // Add the message encoder after handshake is sent
        try await nioAwait(ch.pipeline.addHandler(PeerMessageEncoder()))

        return ch
    }

    /// Install the message pipeline on an adopted inbound channel. The caller
    /// must have set onMessage/onDisconnect first and keep channel reads paused
    /// until acceptInbound() has sent our handshake.
    public func attachPipeline() async throws {
        guard let ch = getChannel() else {
            throw PeerConnectionError.notConnected
        }
        let decoder = PeerMessageDecoder()
        decoder.skipHandshake = skipHandshakeOnAttach
        try await nioAwait(ch.pipeline.addHandler(ByteToMessageHandler(decoder)))
        try await nioAwait(ch.pipeline.addHandler(
            PeerMessageHandler(onMessage: onMessage, onDisconnect: onDisconnect)))
    }

    /// Reply to an inbound handshake with ours and enable message encoding.
    public func acceptInbound() async throws {
        guard let ch = getChannel() else {
            throw PeerConnectionError.notConnected
        }
        let handshake = Handshake(infoHash: infoHash, peerID: peerID)
        var buffer = ch.allocator.buffer(capacity: Handshake.length)
        buffer.writeBytes(handshake.encode())
        try await nioAwait(ch.writeAndFlush(buffer))
        try await nioAwait(ch.pipeline.addHandler(PeerMessageEncoder()))
    }

    public func send(_ message: PeerMessage) async throws {
        guard let ch = getChannel() else {
            throw PeerConnectionError.notConnected
        }
        try await nioAwait(ch.writeAndFlush(message))
    }

    public func close() async throws {
        guard let ch = getChannel() else { return }
        try await nioAwait(ch.close())
    }
}

public enum PeerConnectionError: Error {
    case notConnected
    case handshakeFailed
}

// MARK: - NIO Channel Handlers

/// Decodes peer wire protocol messages from byte stream.
final class PeerMessageDecoder: ByteToMessageDecoder {
    typealias InboundOut = PeerMessage

    private var handshakeReceived = false
    /// Set for inbound connections whose handshake was already consumed upstream.
    var skipHandshake = false
    /// Invoked with the decoded handshake before any message is emitted.
    var onHandshake: (@Sendable (Handshake) -> Void)?

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        if !handshakeReceived {
            if skipHandshake {
                handshakeReceived = true
                return .continue
            }
            guard buffer.readableBytes >= Handshake.length else { return .needMoreData }
            guard let bytes = buffer.readBytes(length: Handshake.length) else { return .needMoreData }
            let handshake = try Handshake.decode(from: Data(bytes))
            onHandshake?(handshake)
            handshakeReceived = true
            return .continue
        }

        guard buffer.readableBytes >= 4 else { return .needMoreData }
        let lengthBytes = buffer.getBytes(at: buffer.readerIndex, length: 4)!
        let length = Data(lengthBytes).readUInt32BE(at: 0)

        if length == 0 {
            buffer.moveReaderIndex(forwardBy: 4)
            context.fireChannelRead(wrapInboundOut(.keepAlive))
            return .continue
        }

        guard buffer.readableBytes >= 4 + Int(length) else { return .needMoreData }
        buffer.moveReaderIndex(forwardBy: 4)
        guard let payload = buffer.readBytes(length: Int(length)) else { return .needMoreData }
        let message = try PeerMessage.decode(from: Data(payload))
        context.fireChannelRead(wrapInboundOut(message))
        return .continue
    }
}

/// Receives decoded PeerMessage and calls the callback.
final class PeerMessageHandler: ChannelInboundHandler {
    typealias InboundIn = PeerMessage

    private let onMessage: (@Sendable (PeerMessage) -> Void)?
    private let onDisconnect: (@Sendable () -> Void)?

    init(onMessage: (@Sendable (PeerMessage) -> Void)?, onDisconnect: (@Sendable () -> Void)?) {
        self.onMessage = onMessage
        self.onDisconnect = onDisconnect
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        onMessage?(message)
    }

    func channelInactive(context: ChannelHandlerContext) {
        onDisconnect?()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

/// Encodes peer wire protocol messages to byte stream.
final class PeerMessageEncoder: ChannelOutboundHandler {
    typealias OutboundIn = PeerMessage
    typealias OutboundOut = ByteBuffer

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let msg = unwrapOutboundIn(data)
        let encoded = msg.encode()
        var buffer = context.channel.allocator.buffer(capacity: encoded.count)
        buffer.writeBytes(encoded)
        context.write(wrapOutboundOut(buffer), promise: promise)
    }
}
