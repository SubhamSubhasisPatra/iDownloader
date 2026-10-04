import XCTest
import NIOCore
import NIOEmbedded
@testable import SwiftTorrent

/// Verifies the decoder emits every message present in one TCP segment —
/// a handshake followed immediately by an extended handshake.
final class DecoderTests: XCTestCase {
    func testHandshakePlusExtendedInOneSegment() throws {
        let ih = Data([0xdd, 0x82, 0x55, 0xec, 0xdc, 0x7c, 0xa5, 0x5f, 0xb0, 0xbb,
                       0xf8, 0x13, 0x23, 0xd8, 0x70, 0x62, 0xdb, 0x1f, 0x6d, 0x1c])
        var segment = Data([0x13])
        segment.append(Data("BitTorrent protocol".utf8))
        segment.append(Data(repeating: 0, count: 8))
        segment.append(ih)
        segment.append(Data(repeating: 7, count: 20))
        let extPayload = Data("d1:md12:ut_metadatai3ee1:v6:probe1:metadata_sizei0ee".utf8)
        segment.append(Data([0x00, 0x00, 0x00, UInt8(extPayload.count + 2), 0x14, 0x00]))
        segment.append(extPayload)

        let channel = EmbeddedChannel(handler: ByteToMessageHandler(PeerMessageDecoder()))
        var inBuffer = channel.allocator.buffer(capacity: segment.count)
        inBuffer.writeBytes(segment)
        try channel.writeInbound(inBuffer)
        // The handshake itself is not emitted as a message; the extended one must be.
        let first: PeerMessage? = try channel.readInbound()
        guard case .extended(let id, let payload)? = first else {
            XCTFail("expected extended message, got \(String(describing: first))")
            return
        }
        XCTAssertEqual(id, 0)
        XCTAssertEqual(payload, extPayload)
    }

    func testFullPipelineDeliversMessagesToHandler() throws {
        let ih = Data([0xdd, 0x82, 0x55, 0xec, 0xdc, 0x7c, 0xa5, 0x5f, 0xb0, 0xbb,
                       0xf8, 0x13, 0x23, 0xd8, 0x70, 0x62, 0xdb, 0x1f, 0x6d, 0x1c])
        var handshake = Data([0x13])
        handshake.append(Data("BitTorrent protocol".utf8))
        handshake.append(Data(repeating: 0, count: 8))
        handshake.append(ih)
        handshake.append(Data(repeating: 7, count: 20))

        let extPayload = Data("d1:md12:ut_metadatai3ee".utf8)
        var messages: [PeerMessage] = []
        let messageHandler = PeerMessageHandler(onMessage: { messages.append($0) }, onDisconnect: nil)

        let channel = EmbeddedChannel(handler: ByteToMessageHandler(PeerMessageDecoder()))
        try channel.pipeline.addHandler(messageHandler).wait()

        var inBuffer = channel.allocator.buffer(capacity: 128)
        inBuffer.writeBytes(handshake + Data([0x00, 0x00, 0x00, UInt8(extPayload.count + 2), 0x14, 0x00]) + extPayload)
        try channel.writeInbound(inBuffer)

        XCTAssertEqual(messages.count, 1)
        guard case .extended(let id, let payload)? = messages.first else {
            XCTFail("expected extended message")
            return
        }
        XCTAssertEqual(id, 0)
        XCTAssertEqual(payload, extPayload)
    }
}
