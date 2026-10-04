import Foundation
import Crypto

/// Mutable piece assembly buffer. A class so per-block writes mutate in place —
/// a value type would copy the whole buffer on every 16 KiB block via COW.
final class PieceBuffer {
    let size: Int
    let blockCount: Int
    var data: Data
    var received: Bitfield

    init(size: Int, blockCount: Int) {
        self.size = size
        self.blockCount = blockCount
        self.data = Data(count: size)
        self.received = Bitfield(count: blockCount)
    }

    var isComplete: Bool {
        received.allSet
    }
}

/// Tracks piece completion and verifies SHA-1 hashes.
public actor PieceManager {
    static let blockSize = 16384

    private let pieceCount: Int
    private let pieceLength: Int
    private let totalSize: Int64
    private let pieceHashes: Data  // concatenated 20-byte SHA-1 hashes
    private var completed: Bitfield
    private var inProgress: Set<Int>
    private var pieceBuffers: [Int: PieceBuffer]
    /// Blocks already requested this generation — a block is requested once and
    /// only re-requested when its generation resets (timeout, corrupt, disconnect).
    private var requested: [Int: Bitfield]
    /// Pieces that belong to the selected files; nil when everything is selected.
    private var allowed: Bitfield?

    public private(set) var startPieceCalls: Int64 = 0
    public private(set) var startPieceCreations: Int64 = 0
    public private(set) var startPieceSkippedCompleted: Int64 = 0
    public private(set) var startPieceSkippedBufferExists: Int64 = 0

    public init(info: TorrentInfo) {
        self.pieceCount = info.pieceCount
        self.pieceLength = info.pieceLength
        self.totalSize = info.totalSize
        self.pieceHashes = info.pieces
        self.completed = Bitfield(count: info.pieceCount)
        self.inProgress = []
        self.pieceBuffers = [:]
        self.requested = [:]
    }

    /// Mark a piece as being downloaded. Keeps any blocks already received so a
    /// piece interrupted by a peer disconnect resumes instead of restarting.
    public func startPiece(_ index: Int) {
        startPieceCalls += 1
        // Actor reentrancy: a fill loop may resume after the piece completed —
        // never restart those.
        guard !completed.get(index) else {
            startPieceSkippedCompleted += 1
            return
        }
        guard pieceBuffers[index] == nil else {
            startPieceSkippedBufferExists += 1
            return
        }
        startPieceCreations += 1
        inProgress.insert(index)
        pieceBuffers[index] = PieceBuffer(size: expectedPieceSize(index), blockCount: blockCount(for: index))
    }

    /// Coherent request plan for a piece: fresh state + missing blocks in one
    /// actor call, so fill loops can't act on a half-completed snapshot.
    public func requestPlan(_ index: Int) -> (hasPiece: Bool, missing: [(offset: Int, length: Int)]) {
        (completed.get(index), missingBlocks(index))
    }

    /// Whether a piece currently has an assembly buffer.
    public func hasBuffer(_ index: Int) -> Bool {
        pieceBuffers[index] != nil
    }

    /// Whether a block of a piece was already received.
    public func isBlockReceived(pieceIndex: Int, offset: Int) -> Bool {
        guard let buffer = pieceBuffers[pieceIndex] else { return false }
        return buffer.received.get(offset / Self.blockSize)
    }

    /// Add a block to a piece being downloaded. Returns true when the piece has
    /// every block and is ready for verification. Duplicate blocks are ignored —
    /// they must never re-trigger completion (the original block already did).
    @discardableResult
    public func addBlock(pieceIndex: Int, offset: Int, data: Data) -> Bool {
        guard let buffer = pieceBuffers[pieceIndex] else { return false }
        let blockIndex = offset / Self.blockSize
        guard blockIndex < buffer.blockCount, !buffer.received.get(blockIndex) else {
            return false
        }
        buffer.data.replaceSubrange(offset..<(offset + data.count), with: data)
        buffer.received.set(blockIndex)
        return buffer.isComplete
    }

    /// Byte ranges of the piece still missing AND not yet requested this
    /// generation, so each block goes on the wire at most once until a reset.
    /// Completed pieces report nothing.
    public func missingBlocks(_ index: Int) -> [(offset: Int, length: Int)] {
        guard !completed.get(index) else { return [] }
        let size = pieceBuffers[index]?.size ?? expectedPieceSize(index)
        let received = pieceBuffers[index]?.received
        let sent = requested[index]
        var blocks: [(offset: Int, length: Int)] = []
        var offset = 0
        while offset < size {
            let blockIndex = offset / Self.blockSize
            if received?.get(blockIndex) != true && sent?.get(blockIndex) != true {
                blocks.append((offset, min(Self.blockSize, size - offset)))
            }
            offset += Self.blockSize
        }
        return blocks
    }

    /// Mark a block as requested for this generation.
    public func markRequested(pieceIndex: Int, offset: Int) {
        let blockIndex = offset / Self.blockSize
        var sent = requested[pieceIndex] ?? Bitfield(count: blockCount(for: pieceIndex))
        sent.set(blockIndex)
        requested[pieceIndex] = sent
    }

    /// All not-yet-received blocks of a piece, ignoring the request generation —
    /// endgame uses this to duplicate the last blocks across peers.
    public func unreceivedBlocks(_ index: Int) -> [(offset: Int, length: Int)] {
        guard !completed.get(index) else { return [] }
        let size = pieceBuffers[index]?.size ?? expectedPieceSize(index)
        let received = pieceBuffers[index]?.received
        var blocks: [(offset: Int, length: Int)] = []
        var offset = 0
        while offset < size {
            if received?.get(offset / Self.blockSize) != true {
                blocks.append((offset, min(Self.blockSize, size - offset)))
            }
            offset += Self.blockSize
        }
        return blocks
    }

    /// Re-request a timed-out block (its response never arrived).
    public func clearRequested(pieceIndex: Int, offset: Int) {
        requested[pieceIndex]?.clear(offset / Self.blockSize)
    }

    /// Start a fresh request generation for a piece (corrupt hash reset).
    public func resetRequested(_ index: Int) {
        requested[index] = nil
    }

    /// True when every in-progress piece has all its blocks requested — the
    /// genuine endgame state where only duplicating requests can make progress.
    public func allBlocksRequested() -> Bool {
        for index in inProgress where !(requested[index]?.allSet ?? false) {
            return false
        }
        return true
    }

    /// Outcome of verifying an assembled piece.
    public enum PieceCompletion {
        /// Hash matched — data is ready for the disk write.
        case verified(Data)
        /// Hash mismatched — the piece must be re-requested.
        case corrupt
        /// No assembly buffer: a duplicate completion raced the real one, or the
        /// piece was never assembling. Not an error.
        case notAssembling
    }

    /// Restrict completion accounting to the selected files' pieces.
    public func setAllowedPieces(_ bitfield: Bitfield) {
        allowed = bitfield
    }

    /// The selection-aware completion mask: `allowed` intersected with completed.
    private func effectiveCompleted() -> (mask: Bitfield, total: Int) {
        guard let allowed else { return (completed, pieceCount) }
        var relevant = allowed
        for index in 0..<pieceCount where relevant.get(index) && !completed.get(index) {
            relevant.clear(index)
        }
        return (relevant, allowed.popcount)
    }

    /// Verify and complete a piece.
    public func completePiece(_ index: Int) -> PieceCompletion {
        guard let buffer = pieceBuffers[index] else { return .notAssembling }

        let expectedHash = pieceHashes.subdata(in: index * 20..<(index + 1) * 20)
        let actualHash = Data(Insecure.SHA1.hash(data: buffer.data))

        pieceBuffers.removeValue(forKey: index)
        inProgress.remove(index)

        guard actualHash == expectedHash else {
            requested[index] = nil
            return .corrupt
        }

        completed.set(index)
        return .verified(buffer.data)
    }

    /// Get the completed bitfield.
    public func getCompleted() -> Bitfield {
        completed
    }

    /// Check if a piece is complete.
    public func hasPiece(_ index: Int) -> Bool {
        completed.get(index)
    }

    /// Check if all selected pieces are complete.
    public func isComplete() -> Bool {
        effectiveCompleted().mask.allSet
    }

    /// Get progress as a fraction (of the selected files).
    public func progress() -> Double {
        let (mask, total) = effectiveCompleted()
        guard total > 0 else { return 1.0 }
        return Double(mask.popcount) / Double(total)
    }

    /// Expected size of a specific piece.
    public func expectedPieceSize(_ index: Int) -> Int {
        let start = Int64(index) * Int64(pieceLength)
        return Int(min(Int64(pieceLength), totalSize - start))
    }

    /// Get the assembled piece data buffer (before completion/verification).
    public func getPieceBuffer(_ index: Int) -> Data? {
        pieceBuffers[index]?.data
    }

    /// Number of 16KB blocks in a piece.
    public func blockCount(for pieceIndex: Int) -> Int {
        let size = expectedPieceSize(pieceIndex)
        return (size + Self.blockSize - 1) / Self.blockSize
    }

    /// Whether a piece is currently being downloaded.
    public func isInProgress(_ index: Int) -> Bool {
        inProgress.contains(index)
    }

    /// Pieces currently being downloaded.
    public func inProgressPieces() -> [Int] {
        Array(inProgress)
    }

    /// The standard piece length for this torrent.
    public func getPieceLength() -> Int {
        pieceLength
    }

    /// Total number of pieces.
    public func getPieceCount() -> Int {
        pieceCount
    }

    /// Declare every piece complete (files must already exist on disk).
    public func markAllComplete() {
        for i in 0..<pieceCount {
            completed.set(i)
        }
        inProgress.removeAll()
        pieceBuffers.removeAll()
        requested.removeAll()
    }
}
