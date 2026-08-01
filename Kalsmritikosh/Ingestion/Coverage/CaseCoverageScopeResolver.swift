//
//  CaseCoverageScopeResolver.swift
//  Kalsmritikosh
//
//  USF-M2 (USF-007 §20/§21/§22) — resolves a workspace's COVERAGE CLOSURE. Direct membership
//  (workspace_sources) is the only stored truth; container / message / attachment / embedded descendants
//  are covered AUTOMATICALLY by traversal, never physically inserted into workspace_sources. A canonical
//  source reachable by several paths is counted ONCE (its occurrence paths are preserved). derivedConversion
//  is deliberately NOT traversed as an independent source.
//

import Foundation

public enum CaseCoverageScopeResolver {

    /// The descendant relations that constitute the coverage closure. `derivedConversion` is excluded —
    /// a converted output is provenance, not another independent case source.
    public static let coverageRelations = ["archiveMember", "attachment", "message", "embedded"]

    public struct Reached: Sendable {
        public var pathsByVersion: [UUID: [String]]   // each version → the DISTINCT paths that reach it
        public var directRoots: Set<UUID>
        public var order: [UUID]                       // first-discovery order (roots first)
    }

    /// Breadth-first closure from the roots. `childrenOf` yields (child, relation, ordinal). A version is
    /// EXPANDED once (dedup) but accumulates every path that reaches it, so occurrences can be counted
    /// without double-counting the source.
    public static func resolve(roots: [(version: UUID, path: String)],
                               childrenOf: (UUID) async -> [(child: UUID, relation: String, ordinal: Int?)]) async -> Reached {
        var pathsByVersion: [UUID: [String]] = [:]
        var directRoots = Set<UUID>()
        var order: [UUID] = []
        var queue: [(UUID, String)] = []
        for r in roots { directRoots.insert(r.version); queue.append((r.version, r.path)) }

        while !queue.isEmpty {
            let (v, path) = queue.removeFirst()
            let firstTime = pathsByVersion[v] == nil
            pathsByVersion[v, default: []].append(path)
            guard firstTime else { continue }   // already expanded — just record the extra occurrence path
            order.append(v)
            for c in await childrenOf(v) {
                let childPath = "\(path) › \(c.relation)[\(c.ordinal.map(String.init) ?? "-")]"
                queue.append((c.child, childPath))
            }
        }
        return Reached(pathsByVersion: pathsByVersion, directRoots: directRoots, order: order)
    }
}
