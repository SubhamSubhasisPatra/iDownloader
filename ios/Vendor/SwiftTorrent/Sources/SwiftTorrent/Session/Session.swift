import Foundation
import NIOCore
import NIOPosix

/// Top-level controller for managing torrents.
public actor Session {
    private var settings: SessionSettings
    private var torrents: [InfoHash: TorrentHandle] = [:]
    private let group: MultiThreadedEventLoopGroup
    private var dhtNode: DHTNode?
    private var listener: Channel?
    private let alertContinuation: AsyncStream<any Alert>.Continuation
    public let alerts: AsyncStream<any Alert>

    public init(settings: SessionSettings = SessionSettings()) {
        self.settings = settings
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

        let (stream, continuation) = AsyncStream<any Alert>.makeStream()
        self.alerts = stream
        self.alertContinuation = continuation
    }

    /// Add a torrent to the session.
    public func addTorrent(_ params: AddTorrentParams) async throws -> TorrentHandle {
        guard let hash = params.infoHash else {
            throw AddTorrentError.noInfoHash
        }
        if let existing = torrents[hash] {
            return existing
        }

        let handle = TorrentHandle(params: params, settings: settings, group: group,
                                   dhtNode: dhtNode,
                                   listenPort: listeningPort ?? settings.listenPort)
        await handle.finishInitialization()
        torrents[hash] = handle

        alertContinuation.yield(TorrentAddedAlert(
            infoHash: hash,
            name: params.torrentInfo?.name ?? params.magnetLink?.displayName ?? "Unknown"
        ))

        if !params.paused {
            try await handle.start()
        }

        return handle
    }

    /// Remove a torrent from the session.
    public func removeTorrent(_ infoHash: InfoHash, deleteFiles: Bool = false) async {
        guard let handle = torrents.removeValue(forKey: infoHash) else { return }
        await handle.pause()

        if deleteFiles {
            // Only the torrent's own savePath — removing settings.savePath would
            // wipe every other torrent's files
            await handle.deleteFiles()
        }

        alertContinuation.yield(TorrentRemovedAlert(infoHash: infoHash))
    }

    /// Get a torrent handle by info hash.
    public func torrent(for infoHash: InfoHash) -> TorrentHandle? {
        torrents[infoHash]
    }

    /// Get all torrent handles.
    public func allTorrents() -> [TorrentHandle] {
        Array(torrents.values)
    }

    /// Get status of all torrents.
    public func allStatus() async -> [TorrentStatus] {
        var statuses: [TorrentStatus] = []
        for handle in torrents.values {
            statuses.append(await handle.status())
        }
        return statuses
    }

    /// Update session settings. The rate limit reaches running torrents too.
    public func updateSettings(_ newSettings: SessionSettings) {
        self.settings = newSettings
        for handle in torrents.values {
            Task { await handle.updateRateLimit(newSettings.downloadRateLimit) }
        }
    }

    /// Start DHT if enabled.
    public func startDHT() async throws {
        guard settings.dhtEnabled else { return }
        let node = DHTNode(port: settings.dhtPort, group: group)
        try await node.start()
        self.dhtNode = node
    }

    /// Listen for inbound peer connections and route them by info hash
    /// (port 0 binds an ephemeral port; see `listeningPort`).
    public func startListener() async throws {
        guard listener == nil else { return }

        let route: @Sendable (Channel, Handshake) -> Void = { [weak self] channel, handshake in
            Task { await self?.routeInbound(channel: channel, handshake: handshake) }
        }
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(InboundHandshakeRouter(onHandshake: route))
            }
        listener = try await nioAwait(
            bootstrap.bind(host: "0.0.0.0", port: Int(settings.listenPort)))
    }

    /// The port the listener actually bound (ephemeral binds resolve here).
    public var listeningPort: UInt16? {
        listener?.localAddress?.port.map { UInt16($0) }
    }

    private func routeInbound(channel: Channel, handshake: Handshake) async {
        guard let handle = torrents[InfoHash(bytes: handshake.infoHash)] else {
            try? await nioAwait(channel.close())
            return
        }
        await handle.acceptInbound(channel: channel, remote: handshake)
    }

    /// Pause all torrents.
    public func pauseAll() async {
        for handle in torrents.values {
            await handle.pause()
        }
    }

    /// Resume all torrents.
    public func resumeAll() async throws {
        for handle in torrents.values {
            try await handle.resume()
        }
    }

    /// Shutdown the session.
    public func shutdown() async throws {
        await pauseAll()
        if let listener {
            try? await nioAwait(listener.close())
        }
        alertContinuation.finish()
        try await group.shutdownGracefully()
    }
}
