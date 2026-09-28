import Foundation
import SwiftTorrent

/// BitTorrent session owner: all torrent tasks share one session, started on first use with the configured settings.
actor TorrentEngine {
    static let shared = TorrentEngine()
    private var session: Session?

    private func makeSettings() -> SessionSettings {
        let dhtEnabled = UserDefaults.standard.object(forKey: "dhtEnabled") as? Bool ?? true
        let limitKbps = UserDefaults.standard.integer(forKey: "speedLimitKbps")
        var settings = SessionSettings(
            savePath: Paths.appSupport.appending(path: "BTFiles", directoryHint: .isDirectory).path
        )
        settings.maxConnections = 400
        settings.maxConnectionsPerTorrent = 120
        settings.dhtEnabled = dhtEnabled
        settings.downloadRateLimit = limitKbps > 0 ? limitKbps * 1024 : 0
        return settings
    }

    func acquire() async throws -> Session {
        if let session { return session }
        let new = Session(settings: makeSettings())
        try FileManager.default.createDirectory(
            at: Paths.appSupport.appending(path: "BTFiles", directoryHint: .isDirectory),
            withIntermediateDirectories: true)
        if makeSettings().dhtEnabled {
            try? await new.startDHT()
        }
        session = new
        return new
    }

    /// Applies new session settings (rate limit and so on); silently skipped when the session is not running.
    func applySettings() async {
        guard let session else { return }
        await session.updateSettings(makeSettings())
    }

    func remove(_ infoHash: InfoHash, deleteFiles: Bool) async {
        guard let session else { return }
        await session.removeTorrent(infoHash, deleteFiles: deleteFiles)
    }

    nonisolated static func infoHash(taskId: String, url: String) -> InfoHash? {
        if url.hasPrefix("magnet:") {
            return (try? AddTorrentParams.fromMagnet(url))?.infoHash
        }
        return (try? AddTorrentParams.fromFile(Paths.torrentBlob(taskId).path))?.infoHash
    }
}

/// One torrent task run: joins the session, polls status and reports back.
actor TorrentRun: TaskRun {
    private let record: TaskRecord
    private var handle: TorrentHandle?

    init(record: TaskRecord) {
        self.record = record
    }

    /// Polls until completion and returns the final status. On cancellation the underlying torrent is paused.
    func execute(onUpdate: @escaping @Sendable (TorrentStatus) async -> Void) async throws -> TorrentStatus {
        let session = try await TorrentEngine.shared.acquire()
        let staging = Paths.appSupport
            .appending(path: "BTFiles", directoryHint: .isDirectory)
            .appending(path: record.taskId, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let params: AddTorrentParams
        if record.url.hasPrefix("magnet:") {
            params = try AddTorrentParams.fromMagnet(record.url, savePath: staging.path)
        } else {
            let blob = Paths.torrentBlob(record.taskId)
            guard FileManager.default.fileExists(atPath: blob.path) else {
                throw DownloadError(message: "Torrent file is missing, remove and re-add the task")
            }
            params = try AddTorrentParams.fromFile(blob.path, savePath: staging.path)
        }

        var added: TorrentHandle
        if let hash = params.infoHash, let existing = await session.torrent(for: hash) {
            added = existing
        } else {
            added = try await session.addTorrent(params)
        }
        handle = added
        try await added.start()

        while true {
            try Task.checkCancellation()
            let status = await added.status()
            await onUpdate(status)
            if status.progress >= 1.0 {
                return status
            }
            try await Task.sleep(for: .seconds(1))
        }
    }

    func stop() async {
        await handle?.pause()
    }
}
