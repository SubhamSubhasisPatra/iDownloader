import Foundation
import NIOCore
import NIOPosix

/// Errors thrown by TorrentHandle wait methods.
public enum TorrentError: Error {
    case timeout
}

/// Per-torrent controller tying peers, pieces, and disk together.
public actor TorrentHandle {
    public let infoHash: InfoHash
    private var info: TorrentInfo?
    private let magnetLink: MagnetLink?
    private let savePath: String
    private let peerID: Data
    private let group: EventLoopGroup

    private var peerManager: PeerManager
    private var pieceManager: PieceManager?
    private var piecePicker: PiecePicker?
    private var diskIO: DiskIO?
    private var trackerManager: TrackerManager?
    private var state: TorrentState = .paused
    private var totalDownloaded: Int64 = 0
    private var totalUploaded: Int64 = 0
    private var lastDownloadRateSample: Int64 = 0
    private var lastUploadRateSample: Int64 = 0
    private var downloadRate: Double = 0
    private var uploadRate: Double = 0
    private var reannounceTask: Task<Void, Never>?
    private var downloadMonitorTask: Task<Void, Never>?
    private var dhtTask: Task<Void, Never>?
    private var metadataExchange: MetadataExchange?
    private var metadataContinuations: [UInt64: CheckedContinuation<TorrentInfo, Error>] = [:]
    private var completionContinuations: [UInt64: CheckedContinuation<Void, Error>] = [:]
    private var nextWaitID: UInt64 = 0
    private let dhtNode: DHTNode?

    public init(params: AddTorrentParams, settings: SessionSettings, group: EventLoopGroup,
                dhtNode: DHTNode? = nil) {
        let hash = params.infoHash!
        self.infoHash = hash
        self.info = params.torrentInfo
        self.magnetLink = params.magnetLink
        self.savePath = params.savePath ?? settings.savePath
        self.peerID = generatePeerID()
        self.group = group
        self.dhtNode = dhtNode
        self.peerManager = PeerManager(
            infoHash: hash.bytes, peerID: peerID, group: group,
            maxConnections: settings.maxConnectionsPerTorrent)

        if let magnet = params.magnetLink, !magnet.trackers.isEmpty {
            let tiers = magnet.trackers.map { [$0] }
            self.trackerManager = TrackerManager(tiers: tiers, group: group)
        }
    }

    private func setupDownloadComponents(info: TorrentInfo) async {
        self.info = info
        let pm = PieceManager(info: info)
        let pp = PiecePicker(pieceCount: info.pieceCount)
        let fs = FileStorage(info: info)
        let dio = DiskIO(basePath: savePath, fileStorage: fs)
        self.pieceManager = pm
        self.piecePicker = pp
        self.diskIO = dio

        if self.trackerManager == nil {
            self.trackerManager = TrackerManager(info: info, group: group)
        }

        // Serve the metadata to other magnet peers from the exact info bytes
        let servingExchange = MetadataExchange(infoHash: info.infoHash, metadata: info.rawInfo)
        self.metadataExchange = servingExchange

        await peerManager.configure(
            pieceManager: pm, piecePicker: pp, diskIO: dio,
            pieceCount: info.pieceCount
        )
        await peerManager.configureMetadataExchange(servingExchange)
    }

    /// Complete initialization for .torrent-file init path (must be called after init).
    internal func finishInitialization() async {
        if let info = self.info {
            await setupDownloadComponents(info: info)
        }
    }

    /// Start downloading.
    public func start() async throws {
        guard state == .paused || state == .stopped else { return }

        if info != nil {
            state = .downloading
            // Allocate files on disk
            try? await diskIO?.allocateFiles()
            startDownloadMonitor()
        } else if magnetLink != nil {
            state = .downloadingMetadata
            // Set up metadata exchange
            let metaEx = MetadataExchange(infoHash: infoHash)
            self.metadataExchange = metaEx
            await peerManager.configureMetadataExchange(metaEx)
            let weakSelf = self
            await peerManager.setOnMetadataReceived { info in
                Task { await weakSelf.onMetadataReceived(info: info) }
            }
        } else {
            state = .downloading
        }

        // Announce to trackers
        if let trackerMgr = trackerManager {
            let left = info?.totalSize ?? 0
            let params = AnnounceParams(
                infoHash: infoHash, peerID: peerID, port: 6881,
                left: left - totalDownloaded, event: "started"
            )
            await announceToAllTrackers(trackerMgr: trackerMgr, params: params)
            startReannounceLoop(trackerMgr: trackerMgr)
        }

        startDHTLoop()
    }

    /// Periodic DHT get_peers lookup: on thin swarms trackers alone miss most leeches.
    private func startDHTLoop() {
        guard let dhtNode else { return }
        dhtTask?.cancel()
        dhtTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let traversal = DHTTraversal(dhtNode: dhtNode)
                if let peers = try? await traversal.getPeers(infoHash: self.infoHash) {
                    for (address, port) in peers {
                        await self.peerManager.addPeer(address: address, port: port)
                    }
                }
                try? await Task.sleep(for: .seconds(45))
            }
        }
    }

    private func onMetadataReceived(info: TorrentInfo) async {
        await setupDownloadComponents(info: info)
        state = .downloading
        try? await diskIO?.allocateFiles()
        startDownloadMonitor()

        // Resume all waiting metadata continuations
        let conts = metadataContinuations
        metadataContinuations.removeAll()
        for (_, cont) in conts {
            cont.resume(returning: info)
        }
    }

    private func startDownloadMonitor() {
        downloadMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { break }
                let complete = await self.refreshProgress()
                if complete {
                    await self.transitionToSeeding()
                    break
                }
            }
        }
    }

    /// Samples transfer counters, runs timeout sweeps, and reports completion.
    private func refreshProgress() async -> Bool {
        await peerManager.checkTimeouts()
        await peerManager.pexTick()

        let downloaded = await peerManager.downloadedBytes
        let uploaded = await peerManager.uploadedBytes
        downloadRate = Double(downloaded - lastDownloadRateSample) / 2.0
        uploadRate = Double(uploaded - lastUploadRateSample) / 2.0
        lastDownloadRateSample = downloaded
        lastUploadRateSample = uploaded
        totalDownloaded = downloaded
        totalUploaded = uploaded

        guard let pm = pieceManager else { return false }
        return await pm.isComplete()
    }

    private func transitionToSeeding() {
        state = .seeding
        downloadMonitorTask?.cancel()

        // Resume all waiting completion continuations
        let conts = completionContinuations
        completionContinuations.removeAll()
        for (_, cont) in conts {
            cont.resume()
        }
    }

    /// Announce to all tracker tiers concurrently.
    private func announceToAllTrackers(trackerMgr: TrackerManager, params: AnnounceParams) async {
        if let response = try? await trackerMgr.announce(params: params) {
            for (address, port) in response.peers {
                await peerManager.addPeer(address: address, port: port)
            }
        }
    }

    /// Periodically re-announce to trackers.
    private func startReannounceLoop(trackerMgr: TrackerManager) {
        reannounceTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = await trackerMgr.getInterval()
                try? await Task.sleep(for: .seconds(max(interval, 60)))
                guard let self, !Task.isCancelled else { break }

                let left = await self.getRemainingBytes()
                let infoHash = self.infoHash
                let peerID = self.peerID
                let uploaded = await self.totalUploaded
                let downloaded = await self.totalDownloaded
                let params = AnnounceParams(
                    infoHash: infoHash, peerID: peerID, port: 6881,
                    uploaded: uploaded, downloaded: downloaded,
                    left: left
                )
                if let response = try? await trackerMgr.announce(params: params) {
                    for (address, port) in response.peers {
                        await self.peerManager.addPeer(address: address, port: port)
                    }
                }
            }
        }
    }

    private func getRemainingBytes() -> Int64 {
        (info?.totalSize ?? 0) - totalDownloaded
    }

    /// Manually add a peer (trackers, DHT, PEX, or local discovery).
    public func addPeer(address: String, port: UInt16) async {
        await peerManager.addPeer(address: address, port: port)
    }

    /// Admit a peer connection accepted by the session listener.
    func acceptInbound(channel: Channel, remote: Handshake) async {
        await peerManager.adoptInbound(channel: channel, remote: remote)
    }

    /// Apply a new download rate limit (bytes/sec, 0 = unlimited).
    public func updateRateLimit(_ bytesPerSecond: Int) async {
        await peerManager.updateRateLimit(bytesPerSecond)
    }

    /// Pause the torrent.
    public func pause() {
        state = .paused
        reannounceTask?.cancel()
        downloadMonitorTask?.cancel()
        dhtTask?.cancel()
    }

    /// Removes this torrent's own files (its savePath), not the session-wide save root.
    public func deleteFiles() async {
        try? FileManager.default.removeItem(atPath: savePath)
    }

    /// Resume the torrent.
    public func resume() async throws {
        try await start()
    }

    /// Get current status snapshot.
    public func status() async -> TorrentStatus {
        let progress = await pieceManager?.progress() ?? 0
        let completed = await pieceManager?.getCompleted()
        let name: String
        if let info = info {
            name = info.name
        } else if let dn = magnetLink?.displayName {
            name = dn
        } else {
            name = "Unknown"
        }
        return TorrentStatus(
            infoHash: infoHash,
            name: name,
            state: state,
            progress: progress,
            downloadRate: downloadRate,
            uploadRate: uploadRate,
            totalDownloaded: totalDownloaded,
            totalUploaded: totalUploaded,
            totalSize: info?.totalSize ?? 0,
            numPeers: await peerManager.connectionCount,
            numSeeds: await peerManager.seedCount(),
            piecesCompleted: completed?.popcount ?? 0,
            piecesTotal: info?.pieceCount ?? 0
        )
    }

    /// Live upload counter (not waiting on the monitor's 2 s sample).
    public func uploadedTotal() async -> Int64 {
        await peerManager.uploadedBytes
    }

    /// Live wire counters (requests sent / bytes received / bytes served).
    public func wireStats() async -> (sent: Int64, received: Int64, uploaded: Int64) {
        async let sent = peerManager.requestsSent
        async let received = peerManager.downloadedBytes
        async let uploaded = peerManager.uploadedBytes
        return await (sent, received, uploaded)
    }

    /// Live diagnostic counters for wire-storm debugging.
    public func debugCounters() async -> (dups: Int64, verifyFails: Int64, dropped: Int64) {
        async let dups = peerManager.dupBlocksReceived
        async let fails = peerManager.pieceVerifyFailures
        async let dropped = peerManager.blocksDroppedNoBuffer
        return await (dups, fails, dropped)
    }

    /// Piece-assembly diagnostics.
    public func debugAssembly() async -> (calls: Int64, creations: Int64, skipComp: Int64, skipBuf: Int64) {
        guard let pm = pieceManager else { return (0, 0, 0, 0) }
        async let calls = pm.startPieceCalls
        async let creations = pm.startPieceCreations
        async let skipComp = pm.startPieceSkippedCompleted
        async let skipBuf = pm.startPieceSkippedBufferExists
        return await (calls, creations, skipComp, skipBuf)
    }

    /// Pending-request bookkeeping diagnostics.
    public func debugPending() async -> (adds: Int64, removes: Int64, clears: Int64) {
        await peerManager.debugPendingStats()
    }

    /// Returns the file entries for this torrent, or nil if metadata is not yet available.
    public func getFiles() -> [TorrentInfo.FileEntry]? {
        info?.files
    }

    /// Generate resume data for saving state.
    public func generateResumeData() async -> ResumeData? {
        guard let completed = await pieceManager?.getCompleted() else { return nil }
        return ResumeData(
            infoHash: infoHash, completedPieces: completed,
            uploaded: totalUploaded, downloaded: totalDownloaded,
            savePath: savePath
        )
    }

    /// Declare every piece complete (files must already exist on disk).
    func markSeedComplete() async {
        guard let pm = pieceManager else { return }
        await pm.markAllComplete()
        totalDownloaded = info?.totalSize ?? 0
    }

    /// Wait until metadata is available, or return immediately if already present.
    public func waitForMetadata(timeout seconds: Int) async throws -> TorrentInfo {
        if let info = self.info {
            return info
        }

        let id = nextWaitID
        nextWaitID += 1

        return try await withCheckedThrowingContinuation { continuation in
            metadataContinuations[id] = continuation

            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard let self else { return }
                if let cont = await self.removeMetadataContinuation(id: id) {
                    cont.resume(throwing: TorrentError.timeout)
                }
            }
        }
    }

    private func removeMetadataContinuation(id: UInt64) -> CheckedContinuation<TorrentInfo, Error>? {
        metadataContinuations.removeValue(forKey: id)
    }

    /// Wait until all pieces are downloaded, or return immediately if already complete.
    public func waitForCompletion(timeout seconds: Int) async throws {
        if state == .seeding {
            return
        }

        let id = nextWaitID
        nextWaitID += 1

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            completionContinuations[id] = continuation

            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard let self else { return }
                if let cont = await self.removeCompletionContinuation(id: id) {
                    cont.resume(throwing: TorrentError.timeout)
                }
            }
        }
    }

    private func removeCompletionContinuation(id: UInt64) -> CheckedContinuation<Void, Error>? {
        completionContinuations.removeValue(forKey: id)
    }
}
