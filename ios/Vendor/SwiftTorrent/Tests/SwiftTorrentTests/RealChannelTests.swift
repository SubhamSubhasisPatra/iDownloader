import XCTest
import NIOCore
import NIOPosix
@testable import SwiftTorrent

/// Speaks the real PeerConnection stack against a local mock peer that sends
/// its handshake reply and an extended handshake back. Guards the regression
/// where post-handshake messages never reached onMessage.
final class RealChannelTests: XCTestCase {
    func testPeerConnectionDeliversExtendedMessages() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { try? group.syncShutdownGracefully() }

        let ih = InfoHash(hex: "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c")!
        let extPayload = Data("d1:md12:ut_metadatai3ee".utf8)

        // Mock peer: accept, read our handshake, reply with handshake + ext message.
        let reply: [UInt8] = [0x13] + Array("BitTorrent protocol".utf8) + [0, 0, 0, 0, 0, 0x10, 0, 0]
            + Array(ih.bytes) + Array(repeating: 9, count: 20)
        let mock = ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(MockHandshakeHandler(reply: reply, extPayload: extPayload))
            }
        let serverChannel = try await mock.bind(host: "127.0.0.1", port: 0).get()
        let port = UInt16(serverChannel.localAddress!.port!)

        let received = LockedArray<PeerMessage>()
        let peerID = generatePeerID()
        let conn = PeerConnection(address: "127.0.0.1", port: port, infoHash: ih.bytes, peerID: peerID)
        conn.onMessage = { msg in received.append(msg) }
        conn.onDisconnect = { received.append(.keepAlive) }  // sentinel: keepAlive = disconnect
        _ = try await conn.connect(on: group)
        await conn.waitForHandshake(timeout: 5)
        XCTAssertTrue(conn.remotePeerID != nil, "handshake reply was consumed")
        XCTAssertTrue(conn.supportsExtensions, "mock handshake must set the extension bit")

        // Wait for the extended message to flow through the real pipeline.
        for _ in 0..<50 where received.value.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard case .extended(let id, let payload)? = received.value.first else {
            XCTFail("no extended message delivered; got \(received.value)")
            return
        }
        XCTAssertEqual(id, 0)
        XCTAssertEqual(payload, extPayload)
        try await serverChannel.close()
    }
}

final class LockedArray<T> {
    private var items: [T] = []
    private let lock = NSLock()
    func append(_ item: T) {
        lock.lock(); items.append(item); lock.unlock()
    }
    var value: [T] {
        lock.lock(); defer { lock.unlock() }; return items
    }
}

final class MockHandshakeHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let reply: [UInt8]
    let extPayload: Data
    private var sent = false

    init(reply: [UInt8], extPayload: Data) {
        self.reply = reply
        self.extPayload = extPayload
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)
        let bytes = buf.readBytes(length: buf.readableBytes) ?? []
        guard bytes.count >= 68, !sent else { return }
        sent = true
        var out = context.channel.allocator.buffer(capacity: reply.count + extPayload.count + 6)
        out.writeBytes(reply)
        // extended message: length prefix, id 20, ext id 0, payload
        out.writeInteger(UInt32(extPayload.count + 2))
        out.writeInteger(UInt8(20))
        out.writeInteger(UInt8(0))
        out.writeBytes(extPayload)
        context.writeAndFlush(NIOAny(out), promise: nil)
    }
}
