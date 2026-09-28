import Foundation

enum Paths {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func partFolder(_ taskId: String) -> URL {
        appSupport
            .appending(path: "TaskFiles", directoryHint: .isDirectory)
            .appending(path: taskId, directoryHint: .isDirectory)
    }

    static var tasksFile: URL {
        appSupport.appending(path: "tasks.json")
    }

    static func torrentBlob(_ taskId: String) -> URL {
        appSupport
            .appending(path: "Torrents", directoryHint: .isDirectory)
            .appending(path: "\(taskId).torrent")
    }

    static func finalFile(_ name: String, in relativeFolder: String = "") -> URL {
        documents
            .appending(path: relativeFolder, directoryHint: relativeFolder.isEmpty ? .notDirectory : .isDirectory)
            .appending(path: name)
    }

    static func categoryFolder(_ category: Category) -> URL {
        documents.appending(path: category.folder, directoryHint: .isDirectory)
    }

    /// (free, total) volume capacity in bytes; nil when unavailable.
    static func volumeCapacity() -> (free: Int64, total: Int64)? {
        let values = try? documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage,
              let total = values?.volumeTotalCapacity else { return nil }
        return (free, Int64(total))
    }
}

func fileSize(at url: URL) -> Int64 {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return attributes?[.size] as? Int64 ?? 0
}

func toReadableTime(_ seconds: Int) -> String {
    if seconds < 60 {
        return "\(seconds)s"
    }
    if seconds < 3600 {
        return "\(seconds / 60)m\(seconds % 60)s"
    }
    return "\(seconds / 3600)h\((seconds % 3600) / 60)m\(seconds % 60)s"
}
