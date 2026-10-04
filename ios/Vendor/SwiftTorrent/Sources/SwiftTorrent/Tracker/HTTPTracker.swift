import Foundation

/// HTTP tracker client (BEP-3).
public struct HTTPTracker: Sendable {
    public let announceURL: String

    public init(announceURL: String) {
        self.announceURL = announceURL
    }

    /// Announce to the tracker.
    public func announce(params: AnnounceParams) async throws -> AnnounceResponse {
        // The query is assembled by hand: URLComponents.queryItems re-encodes
        // values, so an already-encoded info_hash would arrive double-encoded
        // and every tracker would reject the announce with "unknown torrent".
        var query = "info_hash=\(Self.encode(params.infoHash.bytes))"
        query += "&peer_id=\(Self.encode(params.peerID))"
        query += "&port=\(params.port)"
        query += "&uploaded=\(params.uploaded)"
        query += "&downloaded=\(params.downloaded)"
        query += "&left=\(params.left)"
        query += "&compact=1"
        query += "&numwant=\(params.numWant)"
        if let event = params.event {
            query += "&event=\(event)"
        }

        guard let url = URL(string: announceURL + (announceURL.contains("?") ? "&" : "?") + query) else {
            throw TrackerError.invalidURL
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        return try parseAnnounceResponse(data)
    }

    /// RFC 3986 encoding for raw byte strings (info_hash, peer_id). An explicit
    /// ASCII allowlist is required: CharacterSet.alphanumerics is Unicode-aware
    /// and would let high bytes (e.g. 0xD1 "Ñ") pass through as multi-byte UTF-8.
    private static func encode(_ data: Data) -> String {
        var out = ""
        for byte in data {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
                out.append(Character(UnicodeScalar(byte)))
            default:
                out.append(contentsOf: String(format: "%%%02X", byte))
            }
        }
        return out
    }

    private func parseAnnounceResponse(_ data: Data) throws -> AnnounceResponse {
        let decoder = BencodeDecoder()
        let value = try decoder.decode(data)

        if let failure = value["failure reason"]?.utf8String {
            throw TrackerError.failure(failure)
        }

        let interval = value["interval"]?.integerValue.map(Int.init) ?? 1800
        let seeders = value["complete"]?.integerValue.map(Int.init) ?? 0
        let leechers = value["incomplete"]?.integerValue.map(Int.init) ?? 0

        var peers: [(String, UInt16)] = []

        if let peersData = value["peers"]?.stringValue {
            // Compact format: 6 bytes per peer (4 IP + 2 port)
            var offset = 0
            while offset + 6 <= peersData.count {
                let ip = "\(peersData[offset]).\(peersData[offset+1]).\(peersData[offset+2]).\(peersData[offset+3])"
                let port = UInt16(peersData[offset+4]) << 8 | UInt16(peersData[offset+5])
                peers.append((ip, port))
                offset += 6
            }
        } else if let peersList = value["peers"]?.listValue {
            // Dictionary format
            for peerValue in peersList {
                if let ip = peerValue["ip"]?.utf8String,
                   let port = peerValue["port"]?.integerValue {
                    peers.append((ip, UInt16(port)))
                }
            }
        }

        return AnnounceResponse(
            interval: interval, seeders: seeders, leechers: leechers, peers: peers
        )
    }
}

public struct AnnounceParams: Sendable {
    public let infoHash: InfoHash
    public let peerID: Data
    public let port: UInt16
    public let uploaded: Int64
    public let downloaded: Int64
    public let left: Int64
    public let numWant: Int
    public let event: String?  // "started", "stopped", "completed"

    public init(infoHash: InfoHash, peerID: Data, port: UInt16,
                uploaded: Int64 = 0, downloaded: Int64 = 0, left: Int64,
                numWant: Int = 50, event: String? = nil) {
        self.infoHash = infoHash
        self.peerID = peerID
        self.port = port
        self.uploaded = uploaded
        self.downloaded = downloaded
        self.left = left
        self.numWant = numWant
        self.event = event
    }
}

public struct AnnounceResponse: Sendable {
    public let interval: Int
    public let seeders: Int
    public let leechers: Int
    public let peers: [(String, UInt16)]
}

public enum TrackerError: Error, Equatable {
    case invalidURL
    case failure(String)
    case invalidResponse
    case connectionFailed
}
