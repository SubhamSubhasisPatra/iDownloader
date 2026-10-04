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
        let settings = makeSettings()
        let new = Session(settings: settings)
        try FileManager.default.createDirectory(
            at: Paths.appSupport.appending(path: "BTFiles", directoryHint: .isDirectory),
            withIntermediateDirectories: true)
        if settings.dhtEnabled {
            try? await new.startDHT()
        }
        try? await new.startListener()
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

    /// Snapshot of a torrent's file list and per-file completion for the UI.
    func fileStatus(_ hash: InfoHash) async -> (files: [TorrentInfo.FileEntry], progress: [Double])? {
        guard let session else { return nil }
        guard let handle = await session.torrent(for: hash) else { return nil }
        guard let files = await handle.getFiles(), files.count > 1 else { return nil }
        return (files, await handle.fileProgresses())
    }

    nonisolated static func infoHash(taskId: String, url: String) -> InfoHash? {
        if url.hasPrefix("magnet:") {
            return (try? AddTorrentParams.fromMagnet(url))?.infoHash
        }
        return (try? AddTorrentParams.fromFile(Paths.torrentBlob(taskId).path))?.infoHash
    }

    /// Resolves a magnet's metadata without creating a task: joins the session,
    /// waits for the info dict, then pauses the handle for the later task run.
    /// A handle that already existed (another task's torrent) is left untouched.
    func fetchMetadata(_ magnet: String, timeout seconds: Int = 45) async -> TorrentInfo? {
        guard let params = try? AddTorrentParams.fromMagnet(magnet), let hash = params.infoHash else {
            return nil
        }
        guard let session = try? await acquire() else { return nil }

        let staging = Paths.appSupport
            .appending(path: "BTFiles", directoryHint: .isDirectory)
            .appending(path: "meta", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        var created = false
        let handle: TorrentHandle
        if let existing = await session.torrent(for: hash) {
            handle = existing
        } else {
            var fresh = params
            fresh.savePath = staging.path
            guard let added = try? await session.addTorrent(fresh) else { return nil }
            handle = added
            created = true
        }
        _ = try? await handle.start()
        let info = try? await handle.waitForMetadata(timeout: seconds)
        if created {
            await handle.pause()
            if info == nil {
                // Nothing usable: drop the half-added torrent so the session stays clean.
                await session.removeTorrent(hash, deleteFiles: true)
            }
        }
        return info
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
        // Apply the user's choices; no-ops until metadata is around.
        await added.setSequential(record.sequential)
        if let selection = record.selectedFiles {
            await added.selectFiles(Set(selection))
        }
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
