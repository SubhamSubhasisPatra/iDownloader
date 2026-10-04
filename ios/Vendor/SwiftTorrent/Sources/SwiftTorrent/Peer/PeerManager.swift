import Foundation
import NIOCore
import NIOPosix

/// Manages the pool of peer connections for a torrent.
public actor PeerManager {
    private let infoHash: Data
    private let peerID: Data
    private let group: EventLoopGroup
    private var connections: [String: PeerConnection] = [:]
    private var connectedPeers: Set<String> = []
    private var peerInfos: [String: PeerInfo] = [:]
    private var peerStates: [String: PeerState] = [:]
    private let maxConnections: Int

    public var pieceManager: PieceManager?
    public var piecePicker: PiecePicker?
    public var diskIO: DiskIO?
    public var metadataExchange: MetadataExchange?
    public var onPieceCompleted: ((Int) -> Void)?
    public var onMetadataReceived: ((TorrentInfo) -> Void)?

    // BEP-11 ut_pex：本地宣告的消息 id 固定为 2
    private let pexLocalID: UInt8 = 2
    private var pexPeerIDs: [String: UInt8] = [:]
    private var pexUnsent: [(String, UInt16)] = []
    private var pexLastSentAt: Date?

    /// Peer's advertised ut_metadata message id (BEP-9) — data messages arrive under it.
    private var metaPeerIDs: [String: UInt8] = [:]

    private var pieceCount: Int = 0

    /// Bytes received in piece messages (session total).
    public private(set) var downloadedBytes: Int64 = 0
    /// Bytes served in response to peer requests (session total).
    public private(set) var uploadedBytes: Int64 = 0
    /// Request messages sent (diagnostics for wire-storm bugs).
    public private(set) var requestsSent: Int64 = 0
    public private(set) var dupBlocksReceived: Int64 = 0
    public private(set) var pieceVerifyFailures: Int64 = 0
    public private(set) var blocksDroppedNoBuffer: Int64 = 0

    /// Download throttle in bytes/sec, 0 = unlimited.
    private var rateLimit: Int = 0
    private var windowStart = Date()
    private var windowBytes: Int64 = 0

    public init(infoHash: Data, peerID: Data, group: EventLoopGroup, maxConnections: Int = 50) {
        self.infoHash = infoHash
        self.peerID = peerID
        self.group = group
        self.maxConnections = maxConnections
    }

    public func configure(pieceManager: PieceManager, piecePicker: PiecePicker, diskIO: DiskIO, pieceCount: Int) {
        self.pieceManager = pieceManager
        self.piecePicker = piecePicker
        self.diskIO = diskIO
        self.pieceCount = pieceCount
    }

    public func configureMetadataExchange(_ exchange: MetadataExchange) {
        self.metadataExchange = exchange
    }

    public func setOnMetadataReceived(_ handler: @escaping (TorrentInfo) -> Void) {
        self.onMetadataReceived = handler
    }

    public func updateRateLimit(_ bytesPerSecond: Int) {
        rateLimit = bytesPerSecond
    }

    /// Admit a connection accepted by the session listener.
    public func adoptInbound(channel: Channel, remote: Handshake) async {
        let key = channel.remoteAddress.map { "\($0)" } ?? UUID().uuidString
        let conn = PeerConnection(
            adopted: channel, infoHash: infoHash, peerID: peerID,
            remoteID: remote.peerID,
            remoteSupportsExtensions: remote.reserved.count > 5 && remote.reserved[5] & 0x10 != 0)
        guard registerPeer(key: key, conn: conn) else {
            try? await nioAwait(channel.close())
            return
        }
        do {
            try await conn.attachPipeline()
            try await conn.acceptInbound()
        } catch {
            removePeerByKey(key)
            try? await nioAwait(channel.close())
            return
        }
        try? await nioAwait(channel.setOption(ChannelOptions.autoRead, value: true))
        await onPeerConnected(key: key, conn: conn)
    }

    /// Add a peer and attempt connection. The PeerState is registered before the
    /// connect Task runs — peers send their bitfield/unchoke immediately after
    /// the handshake, and messages beating registration used to be dropped forever.
    public func addPeer(address: String, port: UInt16) async {
        let key = "\(address):\(port)"
        let conn = PeerConnection(address: address, port: port, infoHash: infoHash, peerID: peerID)
        guard registerPeer(key: key, conn: conn) else { return }

        Task {
            do {
                _ = try await conn.connect(on: group)
                await self.onPeerConnected(key: key, conn: conn)
            } catch {
                await self.removePeerByKey(key)
            }
        }
    }

    /// Shared registration for outbound and inbound peers. Messages may arrive
    /// the instant the channel is live, so this must be synchronous.
    private func registerPeer(key: String, conn: PeerConnection) -> Bool {
        guard connections[key] == nil, connections.count < maxConnections else { return false }
        connections[key] = conn
        peerInfos[key] = PeerInfo(id: Data(), address: conn.address, port: conn.port)
        peerStates[key] = PeerState(pieceCount: pieceCount > 0 ? pieceCount : 1)

        conn.onMessage = { [weak self] message in
            guard let self else { return }
            Task { await self.handleMessage(message, from: key) }
        }
        conn.onDisconnect = { [weak self] in
            guard let self else { return }
            Task { await self.handleDisconnect(key: key) }
        }
        return true
    }

    private func onPeerConnected(key: String, conn: PeerConnection) async {
        guard peerStates[key] != nil else { return }
        connectedPeers.insert(key)

        // Outbound: the remote handshake may still be in flight; without it we
        // can't know whether extension negotiation is possible.
        await conn.waitForHandshake(timeout: 10)

        // The peer may have dropped during the handshake wait.
        guard let state = peerStates[key], connections[key] === conn else { return }
        await state.setAmInterested(true)
        try? await conn.send(.interested)

        // Extended handshake carries ut_metadata (magnet path) and ut_pex (always)
        if conn.supportsExtensions {
            let extHandshake = await buildExtendedHandshake()
            try? await conn.send(.extended(id: 0, payload: extHandshake))
        }

        // Advertise what we already have so peers can request from us
        if let pm = pieceManager {
            let completed = await pm.getCompleted()
            if completed.popcount > 0 {
                try? await conn.send(.bitfield(completed.toData()))
            }
        }

        // The peer's bitfield/unchoke may have arrived while the handshake was settling
        await fillRequests(for: key)
    }

    private func handleDisconnect(key: String) {
        if let state = peerStates[key] {
            Task {
                // Free the blocks this peer owed so other peers request them —
                // the request generation must not bury them or the torrent stalls.
                let pending = await state.getPendingRequests()
                for request in pending.keys {
                    await self.pieceManager?.clearRequested(pieceIndex: request.pieceIndex, offset: request.offset)
                }
                let bf = await state.getPeerBitfield()
                if var picker = self.piecePicker {
                    picker.removePeerBitfield(bf)
                    self.piecePicker = picker
                }
            }
        }
        connections.removeValue(forKey: key)
        peerInfos.removeValue(forKey: key)
        peerStates.removeValue(forKey: key)
        connectedPeers.remove(key)
    }

    private func handleMessage(_ message: PeerMessage, from key: String) async {
        guard let state = peerStates[key], let conn = connections[key] else { return }

        switch message {
        case .bitfield(let data):
            let bf = Bitfield(data: data, count: pieceCount > 0 ? pieceCount : data.count * 8)
            await state.setPeerBitfield(bf)
            if var picker = piecePicker {
                picker.addPeerBitfield(bf)
                piecePicker = picker
            }
            peerInfos[key]?.peerBitfield = bf
            await fillRequests(for: key)

        case .have(let pieceIndex):
            let idx = Int(pieceIndex)
            await state.setHave(idx)
            if var picker = piecePicker {
                picker.addHave(idx)
                piecePicker = picker
            }
            await fillRequests(for: key)

        case .choke:
            await state.setPeerChoking(true)
            // The peer won't serve our outstanding requests; release them so the
            // request generation doesn't bury those blocks until the 20 s timeout.
            let pending = await state.getPendingRequests()
            for request in pending.keys {
                await state.removePendingRequest(request)
                await pieceManager?.clearRequested(pieceIndex: request.pieceIndex, offset: request.offset)
            }

        case .unchoke:
            await state.setPeerChoking(false)
            await fillRequests(for: key)

        case .interested:
            await state.setPeerInterested(true)
            // Leech-friendly policy: unchoke anyone interested so the swarm moves fast
            if await state.getAmChoking() {
                await state.setAmChoking(false)
                try? await conn.send(.unchoke)
            }

        case .notInterested:
            await state.setPeerInterested(false)
            if !(await state.getAmChoking()) {
                await state.setAmChoking(true)
                try? await conn.send(.choke)
            }

        case .request(let index, let begin, let length):
            await serveUpload(index: Int(index), begin: Int(begin), length: Int(length), key: key)

        case .piece(let index, let begin, let block):
            let pieceIndex = Int(index)
            let offset = Int(begin)
            let request = PeerState.BlockRequest(pieceIndex: pieceIndex, offset: offset, length: block.count)
            await state.removePendingRequest(request)

            guard let pm = pieceManager else { break }
            downloadedBytes += Int64(block.count)
            windowBytes += Int64(block.count)
            let dup = await pm.isBlockReceived(pieceIndex: pieceIndex, offset: offset)
            if dup { dupBlocksReceived += 1 }
            let pieceDone = await pm.addBlock(pieceIndex: pieceIndex, offset: offset, data: block)
            if !dup, !(await pm.hasBuffer(pieceIndex)) { blocksDroppedNoBuffer += 1 }
            if pieceDone {
                await onPieceComplete(index: pieceIndex)
            }
            await fillRequests(for: key)

        case .extended(let extID, let payload):
            await handleExtendedMessage(extID: extID, payload: payload, from: key)

        default:
            break
        }
    }

    /// Serve a block request from a peer we unchoked (seeding path).
    private func serveUpload(index: Int, begin: Int, length: Int, key: String) async {
        guard length > 0, length <= 1_048_576,
              let pm = pieceManager, let dio = diskIO,
              let state = peerStates[key], let conn = connections[key] else { return }
        guard await pm.hasPiece(index),
              await state.getPeerInterested(),
              !(await state.getAmChoking()) else { return }
        let pieceSize = await pm.expectedPieceSize(index)
        guard begin >= 0, begin + length <= pieceSize else { return }
        guard let piece = try? await dio.readPieceCached(index: index),
              begin + length <= piece.count else { return }

        uploadedBytes += Int64(length)
        try? await conn.send(.piece(
            index: UInt32(index), begin: UInt32(begin),
            block: piece.subdata(in: begin..<(begin + length))))
    }

    private func onPieceComplete(index pieceIndex: Int) async {
        guard let pm = pieceManager else { return }
        let outcome = await pm.completePiece(pieceIndex)
        switch outcome {
        case .verified(let data):
            if let dio = diskIO {
                try? await dio.writePiece(index: pieceIndex, data: data)
            }
            await broadcastHave(pieceIndex: UInt32(pieceIndex))
            onPieceCompleted?(pieceIndex)
        case .corrupt:
            // Corrupt piece: cancel its outstanding requests everywhere and let
            // the picker re-request it from scratch
            pieceVerifyFailures += 1
            await cancelPieceRequests(pieceIndex: pieceIndex)
        case .notAssembling:
            break  // duplicate completion raced the real one — nothing to do
        }
    }

    private func cancelPieceRequests(pieceIndex: Int) async {
        for (key, state) in peerStates {
            let pending = await state.getPendingRequests()
            for request in pending.keys where request.pieceIndex == pieceIndex {
                await state.removePendingRequest(request)
                try? await connections[key]?.send(.cancel(
                    index: UInt32(pieceIndex),
                    begin: UInt32(request.offset),
                    length: UInt32(request.length)))
            }
            await fillRequests(for: key)
        }
    }

    private func handleExtendedMessage(extID: UInt8, payload: Data, from key: String) async {
        if extID == 0 {
            recordRemoteExtensionIDs(payload: payload, key: key)
        }

        guard let metaEx = metadataExchange else { return }

        if extID == 0 {
            let result = await metaEx.handleExtendedHandshake(payload: payload)
            await deliver(result, to: key)
            return
        }

        // Route by payload content: every ut_metadata message carries msg_type
        // (BEP-9), while clients sometimes advertise a ut_pex id that collides
        // with the id their ut_metadata data actually arrives under.
        if Self.isMetadataPayload(payload) {
            let result = await metaEx.handleMetadataPayload(payload: payload)
            await deliver(result, to: key)
        } else if extID == pexPeerIDs[key] {
            await handleIncomingPEX(payload: payload)
        }
    }

    /// True when the extended payload is ut_metadata (request, data, or reject).
    private static func isMetadataPayload(_ payload: Data) -> Bool {
        guard let decoded = try? BencodeDecoder().decode(payload) else { return false }
        return decoded["msg_type"] != nil
    }

    private func deliver(_ result: MetadataExchange.Result, to key: String) async {
        switch result {
        case .sendMessage(let msg):
            try? await connections[key]?.send(msg)
        case .requestMore(let messages):
            for msg in messages {
                try? await connections[key]?.send(msg)
            }
        case .metadataComplete(let info):
            onMetadataReceived?(info)
        case .none:
            break
        }
    }

    private func recordRemoteExtensionIDs(payload: Data, key: String) {
        guard let decoded = try? BencodeDecoder().decode(payload) else { return }
        if let pexID = decoded["m"]?["ut_pex"]?.integerValue, pexID > 0, pexID <= Int(UInt8.max) {
            pexPeerIDs[key] = UInt8(pexID)
        }
        if let metaID = decoded["m"]?["ut_metadata"]?.integerValue, metaID > 0, metaID <= Int(UInt8.max) {
            metaPeerIDs[key] = UInt8(metaID)
        }
    }

    private func handleIncomingPEX(payload: Data) async {
        guard let decoded = try? BencodeDecoder().decode(payload),
              let added = decoded["added"]?.stringValue else { return }
        // BEP-11: "added" is a compact IPv4 peer list; dropped is ignored
        for (address, port) in Self.parseCompactPeers(added) {
            if pexUnsent.count < 200 {
                pexUnsent.append((address, port))
            }
            await addPeer(address: address, port: port)
        }
    }

    private static func parseCompactPeers(_ data: Data) -> [(String, UInt16)] {
        let bytes = [UInt8](data)
        var peers: [(String, UInt16)] = []
        var offset = 0
        while offset + 6 <= bytes.count {
            let ip = "\(bytes[offset]).\(bytes[offset + 1]).\(bytes[offset + 2]).\(bytes[offset + 3])"
            let port = UInt16(bytes[offset + 4]) << 8 | UInt16(bytes[offset + 5])
            peers.append((ip, port))
            offset += 6
        }
        return peers
    }

    /// Broadcasts peers discovered via PEX to connected peers; call periodically (~every 2 s),
    /// it self-throttles to BEP-11's suggested ~60 s cadence.
    public func pexTick() async {
        if let last = pexLastSentAt, Date().timeIntervalSince(last) < 60 { return }
        pexLastSentAt = Date()

        guard !pexUnsent.isEmpty else { return }
        let announced = pexUnsent
        pexUnsent.removeAll()

        var bytes = Data()
        for (address, port) in announced {
            let octets = address.split(separator: ".").compactMap { UInt8($0) }
            guard octets.count == 4 else { continue }
            bytes.append(contentsOf: octets)
            bytes.append(UInt8(port >> 8))
            bytes.append(UInt8(port & 0xFF))
        }
        guard !bytes.isEmpty else { return }

        let payload = BencodeEncoder().encode(.dictionary([
            (key: Data("added".utf8), value: .string(bytes)),
            (key: Data("dropped".utf8), value: .string(Data())),
        ]))
        for (key, conn) in connections
        where pexPeerIDs[key] != nil && connectedPeers.contains(key) {
            try? await conn.send(.extended(id: pexLocalID, payload: payload))
        }
    }

    /// Fill this peer's request pipeline. Keeps picking pieces until the pipeline
    /// is full — the old one-piece-per-fill loop left half of it idle.
    private func fillRequests(for key: String) async {
        guard let state = peerStates[key],
              let pm = pieceManager,
              let picker = piecePicker,
              let conn = connections[key] else { return }
        guard !(await state.getPeerChoking()) else { return }
        guard downloadAllowed() else { return }

        let completed = await pm.getCompleted()
        let peerBF = await state.getPeerBitfield()
        let inProgress = await pm.inProgressPieces()
        let candidates = picker.pickMultiple(have: completed, peerHas: peerBF,
                                             count: 8, inProgress: Set(inProgress))

        for pieceIndex in candidates {
            guard await state.canRequest else { break }
            let inProg = await pm.isInProgress(pieceIndex)
            let hasPiece = await pm.hasPiece(pieceIndex)
            if !inProg && !hasPiece {
                await pm.startPiece(pieceIndex)
            }
            for block in await pm.missingBlocks(pieceIndex) {
                guard await state.canRequest else { break }
                let request = PeerState.BlockRequest(pieceIndex: pieceIndex, offset: block.offset, length: block.length)
                guard !(await state.hasPending(request)) else { continue }
                await state.addPendingRequest(request)
                await pm.markRequested(pieceIndex: pieceIndex, offset: block.offset)
                requestsSent += 1
                try? await conn.send(.request(
                    index: UInt32(pieceIndex),
                    begin: UInt32(block.offset),
                    length: UInt32(block.length)))
            }
        }

        // Endgame: nothing left to pick or request but the torrent isn't
        // complete — request the last unreceived blocks from every peer that
        // has their piece, regardless of the request generation. addBlock
        // deduplicates what arrives twice.
        if candidates.isEmpty, !(await pm.isComplete()), await pm.allBlocksRequested() {
            await fillEndgame(state: state, conn: conn, pm: pm, completed: completed, peerBF: peerBF)
        }
    }

    private func fillEndgame(state: PeerState, conn: PeerConnection, pm: PieceManager,
                             completed: Bitfield, peerBF: Bitfield) async {
        if let last = endgameLastFired, Date().timeIntervalSince(last) < 0.25 { return }
        endgameLastFired = Date()

        for pieceIndex in await pm.inProgressPieces() {
            guard peerBF.get(pieceIndex), !completed.get(pieceIndex),
                  !(await pm.hasPiece(pieceIndex)) else { continue }
            for block in await pm.unreceivedBlocks(pieceIndex) {
                guard await state.pendingCount < 64 else { return }
                let request = PeerState.BlockRequest(pieceIndex: pieceIndex, offset: block.offset, length: block.length)
                guard !(await state.hasPending(request)) else { continue }
                await state.addPendingRequest(request)
                requestsSent += 1
                try? await conn.send(.request(
                    index: UInt32(pieceIndex),
                    begin: UInt32(block.offset),
                    length: UInt32(block.length)))
            }
        }
    }

    /// Endgame re-fires at most every 250 ms per peer — without this the
    /// arrival-driven fill loop re-duplicates the last blocks at wire speed.
    private var endgameLastFired: Date?

    /// Sliding 1 s window check against the configured download rate limit.
    private func downloadAllowed() -> Bool {
        guard rateLimit > 0 else { return true }
        if Date().timeIntervalSince(windowStart) >= 1 {
            windowStart = Date()
            windowBytes = 0
        }
        return windowBytes < Int64(rateLimit)
    }

    /// Remove a peer.
    public func removePeer(address: String, port: UInt16) async {
        let key = "\(address):\(port)"
        if let conn = connections.removeValue(forKey: key) {
            try? await conn.close()
        }
        peerInfos.removeValue(forKey: key)
        peerStates.removeValue(forKey: key)
        connectedPeers.remove(key)
    }

    /// Get all connected peer infos.
    public func peers() -> [PeerInfo] {
        Array(peerInfos.values)
    }

    /// Number of active connections.
    public var connectionCount: Int {
        connections.count
    }

    /// Number of peers that completed the TCP handshake.
    public var connectedCount: Int {
        connectedPeers.count
    }

    /// Aggregate wire diagnostics.
    public func debugPendingStats() async -> (adds: Int64, removes: Int64, clears: Int64) {
        var adds: Int64 = 0, removes: Int64 = 0, clears: Int64 = 0
        for state in peerStates.values {
            adds += await state.pendingAdds
            removes += await state.pendingRemoves
            clears += await state.pendingClears
        }
        return (adds, removes, clears)
    }

    /// Connected peers that have every piece.
    public func seedCount() async -> Int {
        guard pieceCount > 0 else { return 0 }
        var seeds = 0
        for state in peerStates.values {
            if await state.getPeerBitfield().popcount == pieceCount {
                seeds += 1
            }
        }
        return seeds
    }

    /// Broadcast a have message to all peers.
    public func broadcastHave(pieceIndex: UInt32) async {
        let msg = PeerMessage.have(pieceIndex: pieceIndex)
        for (key, conn) in connections {
            guard connectedPeers.contains(key) else { continue }
            try? await conn.send(msg)
        }
    }

    /// Check for timed-out requests and cancel them.
    public func checkTimeouts() async {
        for (key, state) in peerStates {
            let timedOut = await state.timedOutRequests()
            for request in timedOut {
                await state.removePendingRequest(request)
                await pieceManager?.clearRequested(pieceIndex: request.pieceIndex, offset: request.offset)
            }
            if !timedOut.isEmpty {
                await fillRequests(for: key)
            }
        }
    }

    /// Combines MetadataExchange's handshake dict with our ut_pex advertisement.
    private func buildExtendedHandshake() async -> Data {
        var root: [(key: Data, value: BencodeValue)] = []
        if let metaEx = metadataExchange {
            let raw = await metaEx.buildExtendedHandshake()
            if let decoded = try? BencodeDecoder().decode(raw),
               case .dictionary(let pairs) = decoded {
                root = pairs
            }
        }

        let utPex: (key: Data, value: BencodeValue) = (
            Data("ut_pex".utf8), .integer(Int64(pexLocalID))
        )
        if let mIndex = root.firstIndex(where: { $0.key == Data("m".utf8) }) {
            if case .dictionary(var m) = root[mIndex].value {
                m.removeAll { $0.key == utPex.key }
                m.append(utPex)
                root[mIndex].value = .dictionary(m)
            }
        } else {
            root.append((Data("m".utf8), .dictionary([utPex])))
        }
        return BencodeEncoder().encode(.dictionary(root))
    }

    private func removePeerByKey(_ key: String) {
        connections.removeValue(forKey: key)
        peerInfos.removeValue(forKey: key)
        peerStates.removeValue(forKey: key)
        connectedPeers.remove(key)
    }
}
