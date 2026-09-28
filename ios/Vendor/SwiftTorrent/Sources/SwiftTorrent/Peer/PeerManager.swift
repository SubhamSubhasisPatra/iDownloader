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

    private var pieceCount: Int = 0

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

    public func configureMagnet(metadataExchange: MetadataExchange) {
        self.metadataExchange = metadataExchange
    }

    public func setOnMetadataReceived(_ handler: @escaping (TorrentInfo) -> Void) {
        self.onMetadataReceived = handler
    }

    /// Add a peer and attempt connection.
    public func addPeer(address: String, port: UInt16) async {
        let key = "\(address):\(port)"
        guard connections[key] == nil else { return }
        guard connections.count < maxConnections else { return }

        let conn = PeerConnection(address: address, port: port, infoHash: infoHash, peerID: peerID)
        connections[key] = conn
        peerInfos[key] = PeerInfo(id: Data(), address: address, port: port)

        // Set up message callbacks
        conn.onMessage = { [weak self] message in
            guard let self else { return }
            Task { await self.handleMessage(message, from: key) }
        }
        conn.onDisconnect = { [weak self] in
            guard let self else { return }
            Task { await self.handleDisconnect(key: key) }
        }

        Task {
            do {
                let _ = try await conn.connect(on: group)
                await self.onPeerConnected(key: key, conn: conn)
            } catch {
                await self.removePeerByKey(key)
            }
        }
    }

    private func onPeerConnected(key: String, conn: PeerConnection) async {
        connectedPeers.insert(key)

        let pc = pieceCount > 0 ? pieceCount : 1
        let state = PeerState(pieceCount: pc)
        await state.setAmInterested(true)
        if conn.supportsExtensions {
            await state.setAmInterested(true)
        }
        peerStates[key] = state

        // Send interested
        try? await conn.send(.interested)

        // Extended handshake carries ut_metadata (magnet path) and ut_pex (always)
        if conn.supportsExtensions {
            let extHandshake = await buildExtendedHandshake()
            try? await conn.send(.extended(id: 0, payload: extHandshake))
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

    private func handleDisconnect(key: String) {
        if let state = peerStates[key] {
            Task {
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
        guard let state = peerStates[key] else { return }

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
            await state.clearPendingRequests()

        case .unchoke:
            await state.setPeerChoking(false)
            await fillRequests(for: key)

        case .interested:
            await state.setPeerInterested(true)

        case .notInterested:
            await state.setPeerInterested(false)

        case .piece(let index, let begin, let block):
            let pieceIndex = Int(index)
            let offset = Int(begin)
            let request = PeerState.BlockRequest(pieceIndex: pieceIndex, offset: offset, length: block.count)
            await state.removePendingRequest(request)

            guard let pm = pieceManager else { break }
            await pm.addBlock(pieceIndex: pieceIndex, offset: offset, data: block)

            // Check if all blocks received for this piece
            let expectedSize = await pm.expectedPieceSize(pieceIndex)
            let buffer = await pm.getPieceBuffer(pieceIndex)
            if let buf = buffer, buf.count >= expectedSize {
                await onPieceComplete(index: pieceIndex, data: buf)
            }

            await fillRequests(for: key)

        case .extended(let extID, let payload):
            await handleExtendedMessage(extID: extID, payload: payload, from: key)

        default:
            break
        }
    }

    private func handleExtendedMessage(extID: UInt8, payload: Data, from key: String) async {
        if extID == 0 {
            // Record which message id this peer uses for ut_pex
            if let decoded = try? BencodeDecoder().decode(payload),
               let pexID = decoded["m"]?["ut_pex"]?.integerValue,
               pexID > 0, pexID <= Int(UInt8.max) {
                pexPeerIDs[key] = UInt8(pexID)
            }
        } else if extID == pexPeerIDs[key], let decoded = try? BencodeDecoder().decode(payload),
                  let added = decoded["added"]?.stringValue {
            // BEP-11: "added" is a compact IPv4 peer list; dropped is ignored
            for (address, port) in Self.parseCompactPeers(added) {
                if pexUnsent.count < 200 {
                    pexUnsent.append((address, port))
                }
                await addPeer(address: address, port: port)
            }
        }

        guard let metaEx = metadataExchange else { return }
        let result = await metaEx.handleExtendedMessage(id: extID, payload: payload)
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

    private func fillRequests(for key: String) async {
        guard let state = peerStates[key],
              let pm = pieceManager,
              let conn = connections[key] else { return }

        let peerChoking = await state.getPeerChoking()
        guard !peerChoking else { return }

        let completed = await pm.getCompleted()

        while await state.canRequest {
            let peerBF = await state.getPeerBitfield()
            guard let picker = piecePicker,
                  let pieceIndex = picker.pick(have: completed, peerHas: peerBF) else { break }

            // Start piece if not in progress
            let inProg = await pm.isInProgress(pieceIndex)
            let hasPc = await pm.hasPiece(pieceIndex)
            if !inProg && !hasPc {
                await pm.startPiece(pieceIndex)
            }

            let pieceSize = await pm.expectedPieceSize(pieceIndex)
            let blockSize = 16384
            var offset = 0
            while offset < pieceSize {
                let canReq = await state.canRequest
                guard canReq else { break }
                let length = min(blockSize, pieceSize - offset)
                let request = PeerState.BlockRequest(pieceIndex: pieceIndex, offset: offset, length: length)
                if !(await state.hasPending(request)) {
                    await state.addPendingRequest(request)
                    try? await conn.send(.request(
                        index: UInt32(pieceIndex),
                        begin: UInt32(offset),
                        length: UInt32(length)
                    ))
                }
                offset += blockSize
            }
            break // One piece at a time per fill cycle
        }
    }

    private func onPieceComplete(index pieceIndex: Int, data: Data) async {
        guard let pm = pieceManager else { return }
        let verified = await pm.completePiece(pieceIndex)
        if verified {
            // Write to disk
            if let dio = diskIO {
                try? await dio.writePiece(index: pieceIndex, data: data)
            }
            await broadcastHave(pieceIndex: UInt32(pieceIndex))
            onPieceCompleted?(pieceIndex)
        }
    }

    private func markConnected(key: String) {
        connectedPeers.insert(key)
    }

    private func removePeerByKey(_ key: String) {
        connections.removeValue(forKey: key)
        peerInfos.removeValue(forKey: key)
        peerStates.removeValue(forKey: key)
        connectedPeers.remove(key)
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

    /// Implements the choking algorithm — unchoke top uploaders + one optimistic unchoke.
    public func runChokingAlgorithm() async {
        var peers = Array(peerInfos)
        peers.sort { $0.value.downloadRate > $1.value.downloadRate }

        let unchokeSlots = 4
        for (i, peer) in peers.enumerated() {
            var info = peer.value
            if i < unchokeSlots {
                info.amChoking = false
            } else if i == unchokeSlots {
                info.amChoking = false
            } else {
                info.amChoking = true
            }
            peerInfos[peer.key] = info
        }
    }

    /// Send interested message to all peers.
    public func sendInterestedToAll() async {
        let msg = PeerMessage.interested
        for (key, conn) in connections {
            guard connectedPeers.contains(key) else { continue }
            try? await conn.send(msg)
        }
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
            }
            if !timedOut.isEmpty {
                await fillRequests(for: key)
            }
        }
    }
}
