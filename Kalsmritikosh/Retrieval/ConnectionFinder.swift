//
//  ConnectionFinder.swift
//  Kalsmritikosh
//
//  "How are these two connected?" — a deterministic shortest-path over the
//  evidence-backed relationship graph. Given two entities, find the shortest
//  chain of relationships linking them and show each hop with its citation. The
//  connect-the-dots move an investigator/journalist makes by hand, done in one
//  step. Pure BFS; no model. AppState does the (bounded) graph expansion, this
//  finds and reconstructs the path.
//

import Foundation

/// An undirected edge in the working adjacency: the neighbor reached, the
/// relationship label, and the source document backing it.
public struct ConnectionEdge: Sendable, Hashable {
    public let neighbor: Entity.ID
    public let label: String
    public let evidenceObjectID: KnowledgeObject.ID?
    public init(neighbor: Entity.ID, label: String, evidenceObjectID: KnowledgeObject.ID?) {
        self.neighbor = neighbor; self.label = label; self.evidenceObjectID = evidenceObjectID
    }
}

/// One hop along a found path.
public struct ConnectionHop: Sendable, Hashable {
    public let from: Entity.ID
    public let to: Entity.ID
    public let label: String
    public let evidenceObjectID: KnowledgeObject.ID?
    public init(from: Entity.ID, to: Entity.ID, label: String, evidenceObjectID: KnowledgeObject.ID?) {
        self.from = from; self.to = to; self.label = label; self.evidenceObjectID = evidenceObjectID
    }
}

public struct ConnectionPath: Sendable, Hashable {
    public let nodes: [Entity.ID]      // source … target
    public let hops: [ConnectionHop]   // nodes.count - 1
    public init(nodes: [Entity.ID], hops: [ConnectionHop]) { self.nodes = nodes; self.hops = hops }
}

public enum ConnectionFinder {

    /// Breadth-first shortest path from `from` to `to` over an adjacency map.
    /// Deterministic: neighbor lists are visited in a stable (uuid-sorted) order,
    /// so the same graph always yields the same shortest path. Returns nil when
    /// no path exists within the provided adjacency.
    public static func shortestPath(
        from: Entity.ID, to: Entity.ID, adjacency: [Entity.ID: [ConnectionEdge]]
    ) -> ConnectionPath? {
        if from == to { return ConnectionPath(nodes: [from], hops: []) }
        var queue: [Entity.ID] = [from]
        var head = 0
        var visited: Set<Entity.ID> = [from]
        var parent: [Entity.ID: (prev: Entity.ID, edge: ConnectionEdge)] = [:]

        while head < queue.count {
            let node = queue[head]; head += 1
            let edges = (adjacency[node] ?? []).sorted { $0.neighbor.uuidString < $1.neighbor.uuidString }
            for e in edges where !visited.contains(e.neighbor) {
                visited.insert(e.neighbor)
                parent[e.neighbor] = (node, e)
                if e.neighbor == to { return reconstruct(to: to, parent: parent) }
                queue.append(e.neighbor)
            }
        }
        return nil
    }

    private static func reconstruct(
        to: Entity.ID, parent: [Entity.ID: (prev: Entity.ID, edge: ConnectionEdge)]
    ) -> ConnectionPath {
        var nodes: [Entity.ID] = [to]
        var hops: [ConnectionHop] = []
        var cur = to
        while let p = parent[cur] {
            hops.append(ConnectionHop(from: p.prev, to: cur, label: p.edge.label, evidenceObjectID: p.edge.evidenceObjectID))
            nodes.append(p.prev)
            cur = p.prev
        }
        return ConnectionPath(nodes: nodes.reversed(), hops: hops.reversed())
    }
}

// MARK: - Resolved (view-model) form

/// A node on the path with display info.
public struct ConnectionNode: Sendable, Hashable, Identifiable {
    public let id: Entity.ID
    public let name: String
    public let kind: String
    public init(id: Entity.ID, name: String, kind: String) { self.id = id; self.name = name; self.kind = kind }
}

/// A hop with resolved names + a citation the UI can open.
public struct ResolvedConnectionHop: Sendable, Hashable, Identifiable {
    public let id: Int              // position in the path
    public let label: String
    public let fromName: String
    public let toName: String
    public let evidenceFilename: String?
    public let evidenceURL: URL?
    public init(id: Int, label: String, fromName: String, toName: String, evidenceFilename: String?, evidenceURL: URL?) {
        self.id = id; self.label = label; self.fromName = fromName; self.toName = toName
        self.evidenceFilename = evidenceFilename; self.evidenceURL = evidenceURL
    }
}

public struct ResolvedConnection: Sendable {
    public let nodes: [ConnectionNode]
    public let hops: [ResolvedConnectionHop]
    public init(nodes: [ConnectionNode], hops: [ResolvedConnectionHop]) { self.nodes = nodes; self.hops = hops }
}
