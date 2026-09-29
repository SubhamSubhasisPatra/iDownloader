import Foundation
import Crypto

/// BEP-9 ut_metadata: fetches torrent metadata via magnet links, and — when
/// constructed with the raw info dict — serves it to other magnet peers.
public actor MetadataExchange {
    private let infoHash: InfoHash
    private let localMetadataID: UInt8 = 1
    private let servingMetadata: Data?

    private var peerMetadataID: UInt8?
    private var metadataSize: Int?
    private var metadataPieces: [Int: Data] = [:]
    private var totalPieces: Int = 0

    public static let metadataPieceSize = 16384

    public enum Result {
        case none
        case sendMessage(PeerMessage)
        case requestMore([PeerMessage])
        case metadataComplete(TorrentInfo)
    }

    /// Leech mode: request metadata from peers that have it.
    public init(infoHash: InfoHash) {
        self.infoHash = infoHash
        self.servingMetadata = nil
    }

    /// Seed mode: serve the exact info-dict bytes whose SHA-1 is the info hash.
    public init(infoHash: InfoHash, metadata: Data) {
        self.infoHash = infoHash
        self.servingMetadata = metadata
        self.metadataSize = metadata.count
        self.totalPieces = (metadata.count + Self.metadataPieceSize - 1) / Self.metadataPieceSize
    }

    /// Build extended handshake payload (bencoded).
    public func buildExtendedHandshake() -> Data {
        var root: [(key: Data, value: BencodeValue)] = [
            (key: Data("m".utf8), value: .dictionary([
                (key: Data("ut_metadata".utf8), value: .integer(Int64(localMetadataID)))
            ]))
        ]
        if let size = metadataSize {
            root.append((key: Data("metadata_size".utf8), value: .integer(Int64(size))))
        }
        return BencodeEncoder().encode(.dictionary(root))
    }

    /// Handle the peer's extended handshake: learn their ut_metadata id and, in
    /// leech mode, request every metadata piece from them.
    public func handleExtendedHandshake(payload: Data) -> Result {
        let decoder = BencodeDecoder()
        guard let value = try? decoder.decode(payload) else { return .none }

        if let m = value["m"], let utMetadata = m["ut_metadata"]?.integerValue {
            peerMetadataID = UInt8(utMetadata)
        }
        if let size = value["metadata_size"]?.integerValue {
            metadataSize = Int(size)
            totalPieces = (Int(size) + Self.metadataPieceSize - 1) / Self.metadataPieceSize
        }

        // We already have the metadata — nothing to fetch
        guard servingMetadata == nil else { return .none }
        guard let peerID = peerMetadataID, let size = metadataSize, size > 0, totalPieces > 0 else {
            return .none
        }

        var requests: [PeerMessage] = []
        for piece in 0..<totalPieces {
            requests.append(.extended(id: peerID, payload: buildMetadataRequest(piece: piece)))
        }
        return .requestMore(requests)
    }

    /// Handle a ut_metadata payload (request, data, or reject) regardless of the
    /// message id it arrived under.
    public func handleMetadataPayload(payload: Data) -> Result {
        let decoder = BencodeDecoder()
        // The payload is: bencoded dict + raw data
        guard let (value, range) = try? decoder.decodeWithRange(payload),
              let msgType = value["msg_type"]?.integerValue,
              let piece = value["piece"]?.integerValue else { return .none }

        switch msgType {
        case 0:  // request (we serve only if constructed with metadata)
            return serveMetadataPiece(piece: Int(piece))
        case 1:  // data
            let pieceData = Data(payload[range.upperBound...])
            metadataPieces[Int(piece)] = pieceData

            if metadataSize != nil, metadataPieces.count == totalPieces {
                return assembleMetadata()
            }
            return .none
        default:  // reject or unknown
            return .none
        }
    }

    private func serveMetadataPiece(piece: Int) -> Result {
        var reject: BencodeValue {
            .dictionary([
                (key: Data("msg_type".utf8), value: .integer(2)),
                (key: Data("piece".utf8), value: .integer(Int64(piece))),
            ])
        }
        guard let data = servingMetadata, piece >= 0, piece < totalPieces else {
            return .requestMore([.extended(id: localMetadataID, payload: BencodeEncoder().encode(reject))])
        }
        let start = piece * Self.metadataPieceSize
        let end = min(start + Self.metadataPieceSize, data.count)
        guard start < end else {
            return .requestMore([.extended(id: localMetadataID, payload: BencodeEncoder().encode(reject))])
        }

        var response = BencodeEncoder().encode(.dictionary([
            (key: Data("msg_type".utf8), value: .integer(1)),
            (key: Data("piece".utf8), value: .integer(Int64(piece))),
            (key: Data("total_size".utf8), value: .integer(Int64(data.count))),
        ]))
        response.append(data.subdata(in: start..<end))
        return .requestMore([.extended(id: localMetadataID, payload: response)])
    }

    private func assembleMetadata() -> Result {
        var assembled = Data()
        for i in 0..<totalPieces {
            guard let piece = metadataPieces[i] else { return .none }
            assembled.append(piece)
        }

        // Verify SHA-1 matches info hash
        let hash = Data(Insecure.SHA1.hash(data: assembled))
        guard hash == infoHash.bytes else {
            metadataPieces.removeAll()
            return .none
        }

        // Parse into TorrentInfo (carries the raw info bytes for serving later)
        guard let info = try? parseInfoFromMetadata(assembled) else { return .none }
        return .metadataComplete(info)
    }

    private func parseInfoFromMetadata(_ data: Data) throws -> TorrentInfo {
        let decoder = BencodeDecoder()
        let infoValue = try decoder.decode(data)

        guard case .dictionary = infoValue else {
            throw TorrentInfoError.invalidFormat("Metadata is not a dictionary")
        }
        guard let nameValue = infoValue["name"], let name = nameValue.utf8String else {
            throw TorrentInfoError.invalidFormat("Missing 'name'")
        }
        guard let plValue = infoValue["piece length"], let pieceLength = plValue.integerValue else {
            throw TorrentInfoError.invalidFormat("Missing 'piece length'")
        }
        guard let piecesValue = infoValue["pieces"], let pieces = piecesValue.stringValue else {
            throw TorrentInfoError.invalidFormat("Missing 'pieces'")
        }

        let isPrivate = infoValue["private"]?.integerValue == 1

        var files: [TorrentInfo.FileEntry] = []
        var totalSize: Int64 = 0

        if let filesValue = infoValue["files"]?.listValue {
            for fileValue in filesValue {
                guard let length = fileValue["length"]?.integerValue,
                      let pathList = fileValue["path"]?.listValue else {
                    throw TorrentInfoError.invalidFormat("Invalid file entry")
                }
                let pathComponents = pathList.compactMap { $0.utf8String }
                let path = ([name] + pathComponents).joined(separator: "/")
                files.append(TorrentInfo.FileEntry(path: path, length: length, offset: totalSize))
                totalSize += length
            }
        } else if let length = infoValue["length"]?.integerValue {
            files.append(TorrentInfo.FileEntry(path: name, length: length, offset: 0))
            totalSize = length
        } else {
            throw TorrentInfoError.invalidFormat("Missing 'length' or 'files'")
        }

        return TorrentInfo(
            infoHash: infoHash, name: name, pieceLength: Int(pieceLength),
            pieces: pieces, totalSize: totalSize, files: files,
            isPrivate: isPrivate, comment: nil, createdBy: nil,
            creationDate: nil, announceURL: nil, announceList: [],
            rawInfo: data
        )
    }

    private func buildMetadataRequest(piece: Int) -> Data {
        let encoder = BencodeEncoder()
        let msg = BencodeValue.dictionary([
            (key: Data("msg_type".utf8), value: .integer(0)), // request
            (key: Data("piece".utf8), value: .integer(Int64(piece)))
        ])
        return encoder.encode(msg)
    }
}
