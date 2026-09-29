import Foundation
import NIOCore
import NIOPosix

/// Async disk I/O. Write handles stay open (one open/seek per piece, not per
/// slice) and served reads hit a small byte-bounded piece cache.
public actor DiskIO {
    private let basePath: String
    private let fileStorage: FileStorage
    private var writeHandles: [String: FileHandle] = [:]
    private var pieceCache: [Int: Data] = [:]
    private var pieceCacheBytes = 0
    private let pieceCacheLimit = 64 * 1024 * 1024

    public init(basePath: String, fileStorage: FileStorage) {
        self.basePath = basePath
        self.fileStorage = fileStorage
    }

    deinit {
        for handle in writeHandles.values {
            try? handle.close()
        }
    }

    /// Write a piece to disk.
    public func writePiece(index: Int, data: Data) throws {
        pieceCache.removeValue(forKey: index)

        var dataOffset = 0
        for slice in fileStorage.fileSlices(forPiece: index) {
            let filePath = (basePath as NSString).appendingPathComponent(slice.path)
            let handle = try writeHandle(for: filePath)
            handle.seek(toFileOffset: UInt64(slice.offset))
            let chunk = data.subdata(in: dataOffset..<dataOffset + slice.length)
            handle.write(chunk)
            dataOffset += slice.length
        }
    }

    /// Read a piece from disk.
    public func readPiece(index: Int) async throws -> Data {
        let slices = fileStorage.fileSlices(forPiece: index)
        var result = Data()

        for slice in slices {
            let filePath = (basePath as NSString).appendingPathComponent(slice.path)
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
            defer { try? handle.close() }
            handle.seek(toFileOffset: UInt64(slice.offset))
            let chunk = handle.readData(ofLength: slice.length)
            result.append(chunk)
        }

        return result
    }

    /// Read a completed piece for upload, serving repeats from a small cache.
    public func readPieceCached(index: Int) async throws -> Data {
        if let cached = pieceCache[index] {
            return cached
        }
        let data = try await readPiece(index: index)
        if pieceCacheBytes > pieceCacheLimit {
            pieceCache.removeAll()
            pieceCacheBytes = 0
        }
        pieceCache[index] = data
        pieceCacheBytes += data.count
        return data
    }

    /// Ensure all files exist with correct sizes.
    public func allocateFiles() throws {
        for file in fileStorage.files {
            let filePath = (basePath as NSString).appendingPathComponent(file.path)
            let dir = (filePath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

            if !FileManager.default.fileExists(atPath: filePath) {
                FileManager.default.createFile(atPath: filePath, contents: nil)
                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: filePath))
                handle.truncateFile(atOffset: UInt64(file.length))
                try handle.close()
            }
        }
    }

    private func writeHandle(for filePath: String) throws -> FileHandle {
        if let handle = writeHandles[filePath] {
            return handle
        }
        let dir = (filePath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: filePath) {
            FileManager.default.createFile(atPath: filePath, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: filePath))
        writeHandles[filePath] = handle
        return handle
    }
}
