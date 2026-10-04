import Foundation

/// Piece selection strategy: rarest-first by default, in-order for sequential
/// downloads. Both respect an optional allowed-piece mask (file selection).
public struct PiecePicker: Sendable {
    private let pieceCount: Int
    private var availability: [Int]  // how many peers have each piece
    private var allowed: Bitfield?
    private var sequential = false

    public init(pieceCount: Int) {
        self.pieceCount = pieceCount
        self.availability = [Int](repeating: 0, count: pieceCount)
    }

    /// Restrict picking to the selected files' pieces.
    public mutating func setAllowedPieces(_ bitfield: Bitfield) {
        allowed = bitfield
    }

    /// Sequential mode picks pieces in index order (files fill one by one).
    public mutating func setSequential(_ value: Bool) {
        sequential = value
    }

    /// Update availability from a peer's bitfield.
    public mutating func addPeerBitfield(_ bitfield: Bitfield) {
        for i in 0..<min(pieceCount, bitfield.count) {
            if bitfield.get(i) {
                availability[i] += 1
            }
        }
    }

    /// Remove a peer's bitfield from availability counts.
    public mutating func removePeerBitfield(_ bitfield: Bitfield) {
        for i in 0..<min(pieceCount, bitfield.count) {
            if bitfield.get(i) {
                availability[i] = max(0, availability[i] - 1)
            }
        }
    }

    /// Increment availability for a single piece (peer sent "have").
    public mutating func addHave(_ pieceIndex: Int) {
        guard pieceIndex >= 0 && pieceIndex < pieceCount else { return }
        availability[pieceIndex] += 1
    }

    /// Pick the next piece to request using rarest-first strategy.
    /// `have` is our own bitfield; `peerHas` is the peer's bitfield.
    public func pick(have: Bitfield, peerHas: Bitfield) -> Int? {
        pickMultiple(have: have, peerHas: peerHas, count: 1, inProgress: []).first
    }

    /// Pick several pieces for a peer's request pipeline. Pieces another peer
    /// is already assembling rank last, so connections spread across the swarm
    /// instead of piling onto the same piece and idling.
    public func pickMultiple(have: Bitfield, peerHas: Bitfield, count: Int,
                             inProgress: Set<Int>) -> [Int] {
        var candidates: [(index: Int, rank: Int)] = []
        for i in 0..<pieceCount {
            guard !have.get(i) && peerHas.get(i), allowed?.get(i) != false else { continue }
            let order = sequential ? i : availability[i]
            candidates.append((i, (inProgress.contains(i) ? 1 : 0) * max(pieceCount, 1) + order))
        }
        candidates.sort { $0.rank < $1.rank }
        return Array(candidates.prefix(count).map(\.index))
    }
}
