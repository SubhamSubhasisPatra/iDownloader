import Foundation

/// Tracks per-peer protocol state for download orchestration.
public actor PeerState {
    public var amChoking: Bool = true
    public var amInterested: Bool = false
    public var peerChoking: Bool = true
    public var peerInterested: Bool = false
    public var peerBitfield: Bitfield
    public var supportsExtensions: Bool = false

    /// Pending block requests: (pieceIndex, offset, length) → timestamp
    public struct BlockRequest: Hashable, Sendable {
        public let pieceIndex: Int
        public let offset: Int
        public let length: Int
    }
    private var pendingRequests: [BlockRequest: Date] = [:]
    public private(set) var pendingAdds: Int64 = 0
    public private(set) var pendingRemoves: Int64 = 0
    public private(set) var pendingClears: Int64 = 0
    public let maxPipelineDepth: Int

    // 5 个在途请求 ≈ 80 KiB，高 RTT 链路的吞吐被窗口卡死；32 个 ≈ 512 KiB 在途，
    // 与主流客户端的每 peer 请求队列深度一致
    public init(pieceCount: Int, maxPipelineDepth: Int = 32) {
        self.peerBitfield = Bitfield(count: pieceCount)
        self.maxPipelineDepth = maxPipelineDepth
    }

    public func getPeerBitfield() -> Bitfield {
        peerBitfield
    }

    public func getPeerChoking() -> Bool {
        peerChoking
    }

    public func getPeerInterested() -> Bool {
        peerInterested
    }

    public func getAmInterested() -> Bool {
        amInterested
    }

    public func getAmChoking() -> Bool {
        amChoking
    }

    public var pendingCount: Int {
        pendingRequests.count
    }

    public var canRequest: Bool {
        pendingRequests.count < maxPipelineDepth
    }

    public func getPendingRequests() -> [BlockRequest: Date] {
        pendingRequests
    }

    public func hasPending(_ request: BlockRequest) -> Bool {
        pendingRequests[request] != nil
    }

    public func setPeerBitfield(_ bf: Bitfield) {
        peerBitfield = bf
    }

    public func setHave(_ index: Int) {
        peerBitfield.set(index)
    }

    public func setPeerChoking(_ choking: Bool) {
        peerChoking = choking
    }

    public func setPeerInterested(_ interested: Bool) {
        peerInterested = interested
    }

    public func setAmChoking(_ choking: Bool) {
        amChoking = choking
    }

    public func setAmInterested(_ interested: Bool) {
        amInterested = interested
    }

    public func addPendingRequest(_ request: BlockRequest) {
        pendingAdds += 1
        pendingRequests[request] = Date()
    }

    public func removePendingRequest(_ request: BlockRequest) {
        pendingRemoves += 1
        pendingRequests.removeValue(forKey: request)
    }

    public func clearPendingRequests() {
        if !pendingRequests.isEmpty { pendingClears += 1 }
        pendingRequests.removeAll()
    }

    /// Returns requests older than the given timeout interval.
    public func timedOutRequests(timeout: TimeInterval = 20) -> [BlockRequest] {
        let cutoff = Date().addingTimeInterval(-timeout)
        return pendingRequests.filter { $0.value < cutoff }.map(\.key)
    }
}
