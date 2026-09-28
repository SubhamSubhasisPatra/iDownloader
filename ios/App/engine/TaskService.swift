import UIKit
import Observation
import SwiftTorrent

/// One active task run; the service calls stop() to pause or cancel it.
protocol TaskRun: Actor {
    func stop() async
}

/// Single public entry point owning the user-visible task workflow: schedules runs, persists records, aggregates speed.
@MainActor
@Observable
final class TaskService {
    private(set) var tasks: [TaskRecord] = []
    private(set) var totalSpeed: Int64 = 0

    private var runs: [String: any TaskRun] = [:]
    private var runTasks: [String: Task<Void, Never>] = [:]
    private var speedSamples: [String: Int64] = [:]
    private var torrentSpeeds: [String: Int64] = [:]
    private var httpTotal: Int64 = 0
    private var speedTimer: Timer?

    init() {
        loadSavedTasks()
        scheduleNext()
        speedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sampleSpeed() }
        }
    }

    var githubEnabled: Bool {
        UserDefaults.standard.object(forKey: "githubEnabled") as? Bool ?? true
    }

    var githubSite: String {
        UserDefaults.standard.string(forKey: "githubSite") ?? GitHubProxy.autoKey
    }

    var githubCustomSite: String {
        UserDefaults.standard.string(forKey: "githubCustomSite") ?? ""
    }

    private var isAutoStart: Bool {
        UserDefaults.standard.object(forKey: "autoStart") as? Bool ?? true
    }

    private var usesCategoryFolders: Bool {
        UserDefaults.standard.object(forKey: "categoryFolders") as? Bool ?? true
    }

    // MARK: - User actions

    /// Returns an error message; nil means the task was added.
    func add(_ urlString: String) async -> String? {
        var text = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if URL(string: text) == nil {
            text = text.replacingOccurrences(of: " ", with: "%20")
        }
        guard let rawURL = URL(string: text), let scheme = rawURL.scheme?.lowercased() else {
            return String(localized: "Invalid URL")
        }

        if scheme == "magnet" {
            return addTorrentTask(url: rawURL.absoluteString, name: magnetDisplayName(rawURL.absoluteString))
        }
        if scheme == "https" || scheme == "http", rawURL.pathExtension.lowercased() == "torrent" {
            return await addTorrentFileTask(rawURL)
        }
        guard scheme == "http" || scheme == "https" else {
            return String(localized: "Invalid URL")
        }

        let url = await GitHubProxy.resolve(rawURL, enabled: githubEnabled,
                                            site: githubSite, customSite: githubCustomSite)

        let category = Category.match(toName(from: rawURL))
        let folderURL = outputFolder(for: category)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let name = uniqueName(toName(from: rawURL), in: folderURL)
        FileManager.default.createFile(atPath: outputURL(for: name, in: category).path, contents: nil)

        var record = TaskRecord(taskId: newTaskId(), name: name, url: url.absoluteString)
        record.categoryId = category.id
        record.relativeFolder = usesCategoryFolders ? category.folder : ""
        tasks.insert(record, at: 0)
        save()
        if isAutoStart {
            scheduleNext()
        }
        return nil
    }

    /// Magnet link: name comes from the dn parameter, falling back to the info hash.
    private func addTorrentTask(url: String, name: String) -> String? {
        var record = TaskRecord(taskId: newTaskId(), name: toSafeFilename(name, fallback: "torrent"), url: url)
        record.kind = "torrent"
        tasks.insert(record, at: 0)
        save()
        if isAutoStart {
            scheduleNext()
        }
        return nil
    }

    /// .torrent file link: fetch and archive the file, then add the task as a torrent.
    private func addTorrentFileTask(_ url: URL) async -> String? {
        let taskId = newTaskId()
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw DownloadError.server((response as? HTTPURLResponse)?.statusCode ?? 400)
            }
            guard data.count < 15 << 20 else {
                throw DownloadError(message: "Torrent file is too large")
            }
            try FileManager.default.createDirectory(
                at: Paths.torrentBlob(taskId).deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: Paths.torrentBlob(taskId), options: .atomic)
        } catch {
            return error.localizedDescription
        }

        let baseName = url.lastPathComponent.isEmpty ? "torrent" : url.lastPathComponent
        var record = TaskRecord(taskId: taskId, name: toSafeFilename(baseName, fallback: "torrent"), url: url.absoluteString)
        record.kind = "torrent"
        tasks.insert(record, at: 0)
        save()
        if isAutoStart {
            scheduleNext()
        }
        return nil
    }

    private func magnetDisplayName(_ magnet: String) -> String {
        guard let components = URLComponents(string: magnet) else { return "torrent" }
        let dn = components.queryItems?.first { $0.name == "dn" }?.value ?? ""
        let decoded = dn.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? dn
        if !decoded.trimmingCharacters(in: .whitespaces).isEmpty {
            return decoded
        }
        if let xt = components.queryItems?.first(where: { $0.name == "xt" })?.value {
            return xt.split(separator: ":").last.map(String.init) ?? "torrent"
        }
        return "torrent"
    }

    func start(_ taskId: String) {
        guard let index = taskIndex(taskId), tasks[index].status != .completed else { return }
        tasks[index].status = .waiting
        tasks[index].errorMessage = ""
        save()
        scheduleNext()
    }

    /// Resumes every queued and failed task.
    func resumeAll() {
        for index in tasks.indices where tasks[index].status == .waiting || tasks[index].status == .failed {
            tasks[index].status = .waiting
            tasks[index].errorMessage = ""
        }
        save()
        scheduleNext()
    }

    func pause(_ taskId: String) {
        guard runs[taskId] != nil else { return }
        runTasks[taskId]?.cancel()
        let run = runs[taskId]
        Task { await run?.stop() }
    }

    func pauseAll() {
        for record in tasks where record.status == .running {
            pause(record.taskId)
        }
    }

    func redownload(_ taskId: String) {
        guard let index = taskIndex(taskId) else { return }
        try? FileManager.default.removeItem(at: Paths.partFolder(taskId))
        tasks[index].status = .waiting
        tasks[index].receivedBytes = 0
        tasks[index].speed = 0
        tasks[index].fileSize = 0
        tasks[index].segmentCount = 0
        tasks[index].completedAt = 0
        tasks[index].errorMessage = ""
        save()
        scheduleNext()
    }

    func rename(_ taskId: String, to newName: String) {
        guard let index = taskIndex(taskId), tasks[index].status != .running else { return }
        let record = tasks[index]
        let candidate = toSafeFilename(newName, fallback: record.name)
        let folder = Paths.finalFile("", in: record.relativeFolder)
        let unique = uniqueName(candidate, in: folder)
        let oldURL = record.outputURL
        let newURL = Paths.finalFile(unique, in: record.relativeFolder)
        if FileManager.default.fileExists(atPath: oldURL.path) {
            do {
                try FileManager.default.moveItem(at: oldURL, to: newURL)
            } catch {
                return
            }
        }
        tasks[index].name = unique
        save()
    }

    func remove(_ taskId: String, deleteFile: Bool) {
        runTasks[taskId]?.cancel()
        let run = runs[taskId]
        Task { await run?.stop() }
        runs[taskId] = nil
        runTasks[taskId] = nil
        speedSamples[taskId] = nil
        torrentSpeeds[taskId] = nil

        if let index = taskIndex(taskId) {
            let record = tasks[index]
            if record.kind == "torrent" {
                let isDone = record.status == .completed
                if let hash = TorrentEngine.infoHash(taskId: taskId, url: record.url) {
                    Task { await TorrentEngine.shared.remove(hash, deleteFiles: !isDone || deleteFile) }
                }
                try? FileManager.default.removeItem(at: Paths.appSupport
                    .appending(path: "BTFiles", directoryHint: .isDirectory)
                    .appending(path: taskId, directoryHint: .isDirectory))
                try? FileManager.default.removeItem(at: Paths.torrentBlob(taskId))
            } else {
                try? FileManager.default.removeItem(at: Paths.partFolder(taskId))
                let finalURL = record.outputURL
                let isPlaceholder = fileSize(at: finalURL) == 0
                if deleteFile || isPlaceholder || record.status != .completed {
                    try? FileManager.default.removeItem(at: finalURL)
                }
            }
            tasks.remove(at: index)
        }
        save()
    }

    /// Removes all completed task records (optionally deleting their files).
    func clearFinished(deleteFiles: Bool) {
        for record in tasks where record.status == .completed {
            runTasks[record.taskId] = nil
            runs[record.taskId] = nil
            speedSamples[record.taskId] = nil
            if deleteFiles {
                try? FileManager.default.removeItem(at: record.outputURL)
            }
        }
        tasks.removeAll { $0.status == .completed }
        save()
    }

    func applyEngineSettings() {
        Task { await TorrentEngine.shared.applySettings() }
    }

    // MARK: - Scheduling

    func scheduleNext() {
        let storedMax = UserDefaults.standard.integer(forKey: "maxConcurrentTask")
        let limit = storedMax > 0 ? storedMax : 3
        var runningCount = tasks.filter { $0.status == .running }.count
        for record in tasks.reversed() where record.status == .waiting {
            guard runningCount < limit else { break }
            startRun(record)
            runningCount += 1
        }
    }

    private func startRun(_ record: TaskRecord) {
        guard let index = taskIndex(record.taskId), tasks[index].status == .waiting else { return }
        let taskId = record.taskId
        if tasks[index].kind == "torrent" {
            startTorrentRun(taskId)
        } else {
            startHTTPRun(taskId)
        }
    }

    private func startHTTPRun(_ taskId: String) {
        guard let index = taskIndex(taskId), tasks[index].status == .waiting else { return }
        let storedSubworkers = UserDefaults.standard.integer(forKey: "subworkerCount")
        let run = DownloadRun(record: tasks[index], subworkerCount: storedSubworkers > 0 ? storedSubworkers : 8)
        tasks[index].status = .running
        runs[taskId] = run

        runTasks[taskId] = Task { [weak self] in
            // Transient failures (429, 5xx, network drops) retry automatically with
            // exponential backoff, honoring Retry-After; each attempt resumes from
            // the on-disk segment map.
            var attempt = 0
            while true {
                do {
                    let result = try await run.execute()
                    if let self, let index = self.taskIndex(taskId) {
                        self.tasks[index].name = result.name
                    }
                    self?.finishRun(taskId, status: .completed, fileSize: max(result.size, 0))
                    return
                } catch is CancellationError {
                    self?.finishRun(taskId, status: .paused)
                    return
                } catch {
                    guard let downloadError = error as? DownloadError else {
                        self?.finishRun(taskId, status: .failed, message: error.localizedDescription)
                        return
                    }
                    if downloadError.isStale {
                        try? FileManager.default.removeItem(at: Paths.partFolder(taskId))
                    }
                    attempt += 1
                    let delay = max(downloadError.retryAfter ?? 0, min(60, 1 << min(attempt, 6)))
                    if attempt < 5, downloadError.isRetryable {
                        self?.setRetryNotice(taskId, attempt: attempt, delay: delay, detail: downloadError.message)
                        do {
                            try await Task.sleep(for: .seconds(Double(delay)))
                        } catch {
                            self?.finishRun(taskId, status: .paused)
                            return
                        }
                        continue
                    }
                    self?.finishRun(taskId, status: .failed, message: downloadError.message)
                    return
                }
            }
        }
    }

    private func setRetryNotice(_ taskId: String, attempt: Int, delay: Int, detail: String) {
        guard let index = taskIndex(taskId) else { return }
        tasks[index].errorMessage = "Retrying in \(delay)s (attempt \(attempt)/5) — \(detail)"
        tasks[index].speed = 0
    }

    private func startTorrentRun(_ taskId: String) {
        guard let index = taskIndex(taskId), tasks[index].status == .waiting else { return }
        let run = TorrentRun(record: tasks[index])
        tasks[index].status = .running
        runs[taskId] = run

        runTasks[taskId] = Task { [weak self] in
            do {
                let final = try await run.execute { @MainActor [weak self] status in
                    self?.applyTorrentStatus(taskId, status)
                }
                self?.completeTorrentRun(taskId, final)
            } catch is CancellationError {
                self?.finishRun(taskId, status: .paused)
            } catch {
                self?.finishRun(taskId, status: .failed, message: error.localizedDescription)
            }
        }
    }

    private func applyTorrentStatus(_ taskId: String, _ status: TorrentStatus) {
        torrentSpeeds[taskId] = Int64(status.downloadRate)
        totalSpeed = httpTotal + torrentSpeeds.values.reduce(0, +)
        guard let index = taskIndex(taskId) else { return }
        tasks[index].fileSize = status.totalSize
        tasks[index].receivedBytes = status.totalDownloaded
        tasks[index].speed = Int64(status.downloadRate)
        tasks[index].peers = status.numPeers + status.numSeeds
    }

    private func completeTorrentRun(_ taskId: String, _ status: TorrentStatus) {
        runs[taskId] = nil
        runTasks[taskId] = nil
        torrentSpeeds[taskId] = nil
        guard let index = taskIndex(taskId) else { return }
        tasks[index].speed = 0
        tasks[index].peers = 0

        // Moves the finished product from BT staging into Documents: single file, or a folder for multi-file torrents.
        let staging = Paths.appSupport
            .appending(path: "BTFiles", directoryHint: .isDirectory)
            .appending(path: taskId, directoryHint: .isDirectory)
        let items = (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []

        let productName = toSafeFilename(status.name.isEmpty ? tasks[index].name : status.name,
                                         fallback: tasks[index].name)
        let category = Category.match(productName)
        let folder = outputFolder(for: category)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let finalName = uniqueName(productName, in: folder)
        let destination = Paths.finalFile(finalName, in: usesCategoryFolders ? category.folder : "")
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        do {
            if items.count == 1, items[0].hasDirectoryPath == false {
                tasks[index].relativeFolder = usesCategoryFolders ? category.folder : ""
                try FileManager.default.moveItem(at: items[0], to: destination)
            } else {
                let sourceFolder = items.first { $0.hasDirectoryPath } ?? staging
                tasks[index].relativeFolder = usesCategoryFolders ? category.folder : ""
                try FileManager.default.moveItem(at: sourceFolder, to: destination)
            }
        } catch {
            finishRun(taskId, status: .failed, message: "Move failed: \(error.localizedDescription)")
            return
        }

        tasks[index].name = finalName
        tasks[index].categoryId = category.id
        try? FileManager.default.removeItem(at: staging)
        try? FileManager.default.removeItem(at: Paths.torrentBlob(taskId))
        finishRun(taskId, status: .completed, fileSize: max(status.totalSize, 0))
    }

    private func finishRun(_ taskId: String, status: TaskStatus, fileSize: Int64? = nil, message: String = "") {
        runs[taskId] = nil
        runTasks[taskId] = nil
        speedSamples[taskId] = nil
        guard let index = taskIndex(taskId) else { return }
        tasks[index].status = status
        tasks[index].speed = 0
        tasks[index].errorMessage = message
        if let fileSize {
            tasks[index].fileSize = fileSize
            tasks[index].receivedBytes = fileSize
        }
        if status == .completed {
            tasks[index].completedAt = Int(Date().timeIntervalSince1970)
        }
        save()
        scheduleNext()
    }

    private func sampleSpeed() async {
        var total: Int64 = 0
        for (taskId, run) in runs {
            guard let httpRun = run as? DownloadRun else { continue }
            let written = await httpRun.writtenBytes()
            let previous = speedSamples[taskId] ?? written
            speedSamples[taskId] = written
            guard let index = taskIndex(taskId) else { continue }
            let speed = max(0, written - previous)
            tasks[index].receivedBytes = written
            tasks[index].speed = speed
            if tasks[index].fileSize == 0 {
                tasks[index].fileSize = await httpRun.knownSize()
            }
            if tasks[index].segmentCount == 0 {
                tasks[index].segmentCount = await httpRun.knownSegments()
            }
            total += speed
        }
        httpTotal = total
        totalSpeed = total + torrentSpeeds.values.reduce(0, +)
        UIApplication.shared.isIdleTimerDisabled = !runs.isEmpty
    }

    private func taskIndex(_ taskId: String) -> Int? {
        tasks.firstIndex { $0.taskId == taskId }
    }

    // MARK: - Output locations

    private func outputFolder(for category: Category) -> URL {
        usesCategoryFolders ? Paths.categoryFolder(category) : Paths.documents
    }

    private func outputURL(for name: String, in category: Category) -> URL {
        Paths.finalFile(name, in: usesCategoryFolders ? category.folder : "")
    }

    private func newTaskId() -> String {
        "tsk_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
    }

    // MARK: - Persistence

    private func loadSavedTasks() {
        guard let data = try? Data(contentsOf: Paths.tasksFile),
              let records = try? JSONDecoder().decode([TaskRecord].self, from: data) else { return }
        var restored: [TaskRecord] = []
        for var record in records {
            if record.status == .running {
                record.status = .waiting
            }
            if record.status != .completed {
                record.receivedBytes = partsSize(record.taskId)
            }
            record.speed = 0
            restored.append(record)
        }
        tasks = restored
    }

    private func partsSize(_ taskId: String) -> Int64 {
        let folder = Paths.partFolder(taskId)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.reduce(Int64(0)) { $0 + fileSize(at: $1) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        try? data.write(to: Paths.tasksFile, options: .atomic)
    }
}
