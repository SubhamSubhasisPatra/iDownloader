import XCTest
import Foundation
import Crypto
@testable import SwiftTorrent

/// End-to-end swarm tests over real loopback TCP connections: sessions with
/// listeners, inbound adoption, upload serving, and metadata exchange.
final class SwarmTests: XCTestCase {

    private var cleanupPaths: [String] = []
    private var keepSessions: [Session] = []

    override func tearDown() {
        for path in cleanupPaths {
            try? FileManager.default.removeItem(atPath: path)
        }
        cleanupPaths.removeAll()
        keepSessions.removeAll()
        super.tearDown()
    }

    /// Builds a real single-file metainfo and parses it (raw info bytes included).
    private func makeSwarm(name: String, data: Data, pieceLength: Int) throws -> TorrentInfo {
        var pieces = Data()
        var offset = 0
        while offset < data.count {
            let end = min(offset + pieceLength, data.count)
            pieces.append(Data(Insecure.SHA1.hash(data: data.subdata(in: offset..<end))))
            offset = end
        }
        let infoDict = BencodeValue.dictionary([
            (key: Data("length".utf8), value: .integer(Int64(data.count))),
            (key: Data("name".utf8), value: .string(Data(name.utf8))),
            (key: Data("piece length".utf8), value: .integer(Int64(pieceLength))),
            (key: Data("pieces".utf8), value: .string(pieces)),
        ])
        let metainfo = BencodeEncoder().encode(.dictionary([
            (key: Data("announce".utf8), value: .string(Data("http://tracker.invalid/announce".utf8))),
            (key: Data("info".utf8), value: infoDict),
        ]))
        return try TorrentInfo.parse(from: metainfo)
    }

    /// A complete seeder session with a live listener on an ephemeral port.
    private func makeSeeder(info: TorrentInfo, data: Data) async throws -> (Session, TorrentHandle, UInt16) {
        let dir = NSTemporaryDirectory() + "swarm-\(UUID().uuidString)"
        cleanupPaths.append(dir)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent(info.name)))

        let settings = SessionSettings(listenPort: 0, dhtEnabled: false, savePath: dir)
        let session = Session(settings: settings)
        keepSessions.append(session)
        try await session.startListener()
        let handle = try await session.addTorrent(AddTorrentParams(torrentInfo: info, savePath: dir))
        await handle.markSeedComplete()
        let boundPort = await session.listeningPort
        let port = try XCTUnwrap(boundPort)
        return (session, handle, port)
    }

    private func makeLeecher() async throws -> (Session, String) {
        let dir = NSTemporaryDirectory() + "swarm-\(UUID().uuidString)"
        cleanupPaths.append(dir)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let session = Session(settings: SessionSettings(listenPort: 0, dhtEnabled: false, savePath: dir))
        keepSessions.append(session)
        return (session, dir)
    }

    /// Diagnostic: two seeders, small file, polls wire counters to locate storms.
    func testDebugSwarm() async throws {
        let data = Data((0..<(1 * 1024 * 1024)).map { _ in UInt8.random(in: 0...255) })
        let info = try makeSwarm(name: "debug.bin", data: data, pieceLength: 131072)
        let (_, seedA, portA) = try await makeSeeder(info: info, data: data)
        let (_, seedB, portB) = try await makeSeeder(info: info, data: data)
        let (leechSession, leechDir) = try await makeLeecher()
        let leech = try await leechSession.addTorrent(AddTorrentParams(torrentInfo: info, savePath: leechDir))
        await leech.addPeer(address: "127.0.0.1", port: portA)
        await leech.addPeer(address: "127.0.0.1", port: portB)


        for i in 0..<20 {
            try await Task.sleep(for: .seconds(1))
            let st = await leech.status()
            let w = await leech.wireStats()
            let d = await leech.debugCounters()
            let asm = await leech.debugAssembly()
            let pend = await leech.debugPending()
            let ua = await seedA.uploadedTotal()
            let ub = await seedB.uploadedTotal()
            print("t=\(i)s prog=\(String(format: "%.2f", st.progress)) sent=\(w.sent) recv=\(w.received) dups=\(d.dups) dropped=\(d.dropped) vfail=\(d.verifyFails) startCalls=\(asm.calls) creations=\(asm.creations) skipBuf=\(asm.skipBuf) pendAdds=\(pend.adds) pendRm=\(pend.removes) pendClr=\(pend.clears)")
            if st.progress >= 1.0 { break }
        }
        let st = await leech.status()
        XCTAssertEqual(st.progress, 1.0, "debug swarm should complete")
    }

    /// 16 MiB from two seeders at once — proves genuine multi-peer ("multipart")
    /// downloading: every seeder must serve part of the data, and the result is
    /// byte-exact.
    func testLeechFromTwoSeedersInParallel() async throws {
        let data = Data((0..<(16 * 1024 * 1024)).map { _ in UInt8.random(in: 0...255) })
        let info = try makeSwarm(name: "parallel.bin", data: data, pieceLength: 262144)
        let (_, seedHandleA, portA) = try await makeSeeder(info: info, data: data)
        let (_, seedHandleB, portB) = try await makeSeeder(info: info, data: data)

        let (leechSession, leechDir) = try await makeLeecher()
        let leech = try await leechSession.addTorrent(AddTorrentParams(torrentInfo: info, savePath: leechDir))
        await leech.addPeer(address: "127.0.0.1", port: portA)
        await leech.addPeer(address: "127.0.0.1", port: portB)

        let started = Date()
        // Poll alongside the completion wait so a stall is visible in the log
        var finished = false
        for i in 0..<60 {
            try await Task.sleep(for: .seconds(2))
            let st = await leech.status()
            let upA = await seedHandleA.uploadedTotal()
            let upB = await seedHandleB.uploadedTotal()
            print("swarm t=\(i * 2)s progress=\(String(format: "%.3f", st.progress)) peers=\(st.numPeers) A=\(upA) B=\(upB)")
            if st.progress >= 1.0 {
                finished = true
                break
            }
        }
        try await leech.waitForCompletion(timeout: 5)
        XCTAssertTrue(finished, "swarm did not complete in 120 s")
        let elapsed = Date().timeIntervalSince(started)

        let downloaded = try Data(contentsOf: URL(fileURLWithPath: (leechDir as NSString).appendingPathComponent(info.name)))
        XCTAssertEqual(downloaded, data, "downloaded file must be byte-exact")

        let upA = await seedHandleA.uploadedTotal()
        let upB = await seedHandleB.uploadedTotal()
        XCTAssertGreaterThan(upA, 0, "seeder A must have served pieces")
        XCTAssertGreaterThan(upB, 0, "seeder B must have served pieces")
        print("Swarm: 16 MiB from 2 peers in \(String(format: "%.2f", elapsed)) s " +
              "(A served \(upA), B served \(upB))")
    }

    /// A magnet resolves its metadata over a real connection via ut_metadata.
    func testMagnetMetadataOverRealConnection() async throws {
        let data = Data(repeating: 0x5A, count: 1024 * 1024)
        let info = try makeSwarm(name: "metadata.bin", data: data, pieceLength: 131072)
        let (_, _, port) = try await makeSeeder(info: info, data: data)

        let (leechSession, leechDir) = try await makeLeecher()
        let magnet = try XCTUnwrap(MagnetLink(
            uri: "magnet:?xt=urn:btih:\(info.infoHash.description)&dn=metadata.bin"))
        let leech = try await leechSession.addTorrent(AddTorrentParams(magnetLink: magnet, savePath: leechDir))
        await leech.addPeer(address: "127.0.0.1", port: port)

        let fetched = try await leech.waitForMetadata(timeout: 30)
        XCTAssertEqual(fetched.name, info.name)
        XCTAssertEqual(fetched.totalSize, info.totalSize)
        XCTAssertEqual(fetched.pieceLength, info.pieceLength)
        XCTAssertEqual(fetched.infoHash, info.infoHash)
    }

    /// An inbound connection adopted by the listener completes the handshake and
    /// receives the seeder's bitfield, so a remote leecher can pull from us.
    func testInboundPeerCompletesDownload() async throws {
        let data = Data((0..<(2 * 1024 * 1024)).map { _ in UInt8.random(in: 0...255) })
        let info = try makeSwarm(name: "inbound.bin", data: data, pieceLength: 262144)
        let (_, _, port) = try await makeSeeder(info: info, data: data)

        // The leecher connects out to the seeder's listener, which exercises the
        // seeder's inbound adoption path (router → adopt → handshake reply).
        let (leechSession, leechDir) = try await makeLeecher()
        let leech = try await leechSession.addTorrent(AddTorrentParams(torrentInfo: info, savePath: leechDir))
        await leech.addPeer(address: "127.0.0.1", port: port)

        try await leech.waitForCompletion(timeout: 60)
        let downloaded = try Data(contentsOf: URL(fileURLWithPath: (leechDir as NSString).appendingPathComponent(info.name)))
        XCTAssertEqual(downloaded, data)
    }
}
