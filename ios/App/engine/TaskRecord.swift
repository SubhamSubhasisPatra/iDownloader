import Foundation
import SwiftTorrent

enum TaskStatus: String, Codable {
    case waiting
    case running
    case paused
    case completed
    case failed
}

struct TaskRecord: Identifiable, Codable {
    let taskId: String
    var name: String
    var url: String
    var status: TaskStatus = .waiting
    var fileSize: Int64 = 0
    var receivedBytes: Int64 = 0
    var speed: Int64 = 0
    var createdAt: Int = Int(Date().timeIntervalSince1970)
    var completedAt: Int = 0
    var errorMessage: String = ""
    var segmentCount: Int = 0
    var categoryId: String = Category.other.id
    var relativeFolder: String = ""
    var kind: String = "http"
    var peers: Int = 0
    /// Torrent-only: indexes into the torrent's file list; nil means every file.
    var selectedFiles: [Int]?
    /// Torrent-only: fetch pieces in order so the first files complete first.
    var sequential: Bool = false

    enum CodingKeys: String, CodingKey {
        case taskId, name, url, status, fileSize, receivedBytes, speed
        case createdAt, completedAt, errorMessage, segmentCount
        case categoryId, relativeFolder, kind, peers
        case selectedFiles, sequential
    }

    init(taskId: String, name: String, url: String) {
        self.taskId = taskId
        self.name = name
        self.url = url
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskId = try c.decode(String.self, forKey: .taskId)
        name = try c.decode(String.self, forKey: .name)
        url = try c.decode(String.self, forKey: .url)
        status = try c.decodeIfPresent(TaskStatus.self, forKey: .status) ?? .waiting
        fileSize = try c.decodeIfPresent(Int64.self, forKey: .fileSize) ?? 0
        receivedBytes = try c.decodeIfPresent(Int64.self, forKey: .receivedBytes) ?? 0
        speed = 0
        createdAt = try c.decodeIfPresent(Int.self, forKey: .createdAt) ?? 0
        completedAt = try c.decodeIfPresent(Int.self, forKey: .completedAt) ?? 0
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage) ?? ""
        segmentCount = try c.decodeIfPresent(Int.self, forKey: .segmentCount) ?? 0
        categoryId = try c.decodeIfPresent(String.self, forKey: .categoryId) ?? Category.other.id
        relativeFolder = try c.decodeIfPresent(String.self, forKey: .relativeFolder) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "http"
        peers = try c.decodeIfPresent(Int.self, forKey: .peers) ?? 0
        selectedFiles = try c.decodeIfPresent([Int].self, forKey: .selectedFiles)
        sequential = try c.decodeIfPresent(Bool.self, forKey: .sequential) ?? false
    }

    var id: String { taskId }
    var progress: Double {
        guard fileSize > 0 else { return 0 }
        return min(1, Double(receivedBytes) / Double(fileSize))
    }

    var canPause: Bool { kind == "torrent" || segmentCount > 0 }

    var category: Category { Category.byId(categoryId) }

    /// Full path of the finished file (Documents root or a category subfolder).
    var outputURL: URL {
        Paths.documents
            .appending(path: relativeFolder, directoryHint: relativeFolder.isEmpty ? .notDirectory : .isDirectory)
            .appending(path: name)
    }

    /// Estimated time left in seconds; nil when it cannot be estimated.
    var timeLeft: Int? {
        guard status == .running, speed > 0, fileSize > 0 else { return nil }
        let remaining = max(0, fileSize - receivedBytes)
        return Int(Double(remaining) / Double(speed))
    }
}

private extension Decoder {
    func decode<T: Decodable>(with container: KeyedDecodingContainer<TaskRecord.CodingKeys>,
                              key: TaskRecord.CodingKeys) throws -> T {
        try container.decode(T.self, forKey: key)
    }
}

/// Unconfirmed torrent waiting for the user's confirmation in the add sheet.
/// Carries everything `TaskService.addTorrent` needs to create the task.
struct TorrentDraft: Identifiable {
    let taskId: String
    /// Magnet URI or .torrent URL; empty when the user picked a local file.
    var url: String = ""
    /// Raw .torrent bytes when the source was a file or URL.
    var blobData: Data?
    /// Parsed metadata; nil for magnets whose metadata has not arrived yet.
    var info: TorrentInfo?

    /// Display name before metadata is known (magnet dn or the info hash).
    var displayName: String {
        if let name = info?.name { return name }
        if url.hasPrefix("magnet:") {
            let dn = URLComponents(string: url)?.queryItems?.first { $0.name == "dn" }?.value ?? ""
            let decoded = dn.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? dn
            if !decoded.trimmingCharacters(in: .whitespaces).isEmpty { return decoded }
        }
        return String(localized: "Fetching metadata…")
    }

    var totalSize: Int64 { info?.totalSize ?? 0 }
}

extension TorrentDraft {
    var id: String { taskId }
}

struct DownloadError: LocalizedError {
    let message: String
    let isRetryable: Bool
    let retryAfter: Int?
    let isStale: Bool

    init(message: String, isRetryable: Bool = false, retryAfter: Int? = nil, isStale: Bool = false) {
        self.message = message
        self.isRetryable = isRetryable
        self.retryAfter = retryAfter
        self.isStale = isStale
    }

    /// 429 / 408 / 5xx are transient; honoring Retry-After when present.
    static func server(_ status: Int, retryAfter: Int? = nil) -> DownloadError {
        let retryable = status == 429 || status == 408 || (500..<600).contains(status)
        return DownloadError(message: "Server error \(status)",
                             isRetryable: retryable, retryAfter: retryAfter)
    }

    static func network(_ error: Error) -> DownloadError {
        let retryableCodes: [URLError.Code] = [
            .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
            .cannotFindHost, .dnsLookupFailed, .cannotLoadFromNetwork,
        ]
        let retryable = (error as? URLError).map { retryableCodes.contains($0.code) } ?? false
        return DownloadError(message: "Network error: \(error.localizedDescription)", isRetryable: retryable)
    }

    /// The server ignored If-Range and returned the full file: the remote file
    /// changed and the segment map is stale, so the download restarts cleanly.
    static var stale: DownloadError {
        DownloadError(message: "File changed on server, restarting download",
                      isRetryable: true, isStale: true)
    }

    var errorDescription: String? { message }
}
