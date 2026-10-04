import Foundation

/// Iterative DHT lookup algorithms.
public actor DHTTraversal {
    private let dhtNode: DHTNode
    private let alpha: Int  // parallelism factor

    public init(dhtNode: DHTNode, alpha: Int = 3) {
        self.dhtNode = dhtNode
        self.alpha = alpha
    }

    /// Iterative find_node lookup — finds the k closest nodes to a target.
    public func findNode(target: NodeID) async throws -> [DHTNodeEntry] {
        var closest = await dhtNode.closestNodes(to: target)
        var queried = Set<NodeID>()
        var improved = true

        while improved {
            improved = false
            let toQuery = closest
                .filter { !queried.contains($0.id) }
                .prefix(alpha)

            for node in toQuery {
                queried.insert(node.id)
                do {
                    try await dhtNode.findNode(target: target, to: node.address, port: node.port)
                } catch {
                    continue
                }
            }

            // Allow time for responses
            try? await Task.sleep(for: .milliseconds(500))

            let newClosest = await dhtNode.closestNodes(to: target)
            if newClosest.first?.id != closest.first?.id {
                improved = true
                closest = newClosest
            }
        }

        return closest
    }

    /// Iterative get_peers lookup — finds peers for an info hash. When
    /// `announcePort` is set, announce_peer is sent to the nodes that issued
    /// tokens so other swarm members can discover us too (we're otherwise
    /// invisible: get_peers responses only list announced peers).
    public func getPeers(infoHash: InfoHash, announcePort: UInt16? = nil) async throws -> [(String, UInt16)] {
        let target = NodeID(bytes: infoHash.bytes.prefix(20).count == 20
            ? Data(infoHash.bytes.prefix(20))
            : infoHash.bytes + Data(count: max(0, 20 - infoHash.bytes.count)))

        var closest = await dhtNode.closestNodes(to: target)
        var queried = Set<NodeID>()
        var peers: [(String, UInt16)] = []
        var tokenedNodes: [(address: String, port: UInt16, token: Data)] = []

        for _ in 0..<10 {  // max iterations
            let toQuery = closest
                .filter { !queried.contains($0.id) }
                .prefix(alpha)

            if toQuery.isEmpty { break }

            // Query nodes concurrently
            await withTaskGroup(of: ([(String, UInt16)], (String, UInt16, Data)?).self) { group in
                for node in toQuery {
                    queried.insert(node.id)
                    group.addTask {
                        do {
                            let response = try await self.dhtNode.getPeersAndWait(
                                infoHash: infoHash, to: node.address, port: node.port
                            )
                            let token = await self.extractToken(from: response)
                            let found = await self.extractPeers(from: response)
                            return (found, token.map { (node.address, node.port, $0) })
                        } catch {
                            return ([], nil)
                        }
                    }
                }
                for await (found, tokened) in group {
                    peers.append(contentsOf: found)
                    if let tokened {
                        tokenedNodes.append((tokened.0, tokened.1, tokened.2))
                    }
                }
            }

            if !peers.isEmpty { break }

            closest = await dhtNode.closestNodes(to: target)
        }

        // Announce ourselves to the closest token-issuing nodes (BEP-5).
        if let announcePort {
            for node in tokenedNodes.prefix(8) {
                try? await dhtNode.announcePeer(
                    infoHash: infoHash, port: announcePort, token: node.token,
                    to: node.address, nodePort: node.port)
            }
        }

        return peers
    }

    /// Extract the announce token from a get_peers response.
    private func extractToken(from message: DHTMessage) -> Data? {
        guard case .response(_, let values) = message else { return nil }
        return values.first(where: { String(data: $0.key, encoding: .utf8) == "token" })?.value.stringValue
    }

    /// Extract peers from a get_peers response.
    private func extractPeers(from message: DHTMessage) -> [(String, UInt16)] {
        guard case .response(_, let values) = message else { return [] }

        var peers: [(String, UInt16)] = []

        // Check for "values" key (list of compact peers)
        if let valuesEntry = values.first(where: { String(data: $0.key, encoding: .utf8) == "values" }),
           let peerList = valuesEntry.value.listValue {
            for peerValue in peerList {
                if let peerData = peerValue.stringValue, peerData.count == 6 {
                    let ip = "\(peerData[peerData.startIndex]).\(peerData[peerData.startIndex + 1]).\(peerData[peerData.startIndex + 2]).\(peerData[peerData.startIndex + 3])"
                    let port = UInt16(peerData[peerData.startIndex + 4]) << 8 | UInt16(peerData[peerData.startIndex + 5])
                    peers.append((ip, port))
                }
            }
        }

        return peers
    }
}
