//
//  TopicTreeBuilder.swift
//  Kalsmritikosh
//
//  TT (Amendment A1, part 2) — the TOPIC TREE, built by EXTENDING what
//  exists: level-0 communities stay exactly as the AgglomerativeCommunity-
//  Detector writes them (it remains the sole level-0 author); this builder
//  adds LEVEL-1 parents into the SAME `entity_communities` table (whose
//  `level` column has waited for this since v20), nesting by containment
//  over shared identifier anchors and winner terms. Labels are written to
//  `community_summaries`: the anchor's display name where one anchors the
//  node, else the corroborated winner terms — deterministic labels; the
//  LLM's suggestions stay in CommunitySummarizer as reviewable derived
//  objects, never stored truth.
//
//  Determinism laws (unit A): total order at every clustering decision;
//  stable node ids (first member id, sorted); topic count is a stability
//  outcome, never a fixed k. Single-document leaves stay leaves.
//

import Foundation
import os

public struct TopicTreeBuilder {
    private let database: Database
    private static let log = Logger(subsystem: "ecosanskritiinnovation.Kalsmritikosh", category: "knowledge")

    public init(database: Database) {
        self.database = database
    }

    public struct Receipt: Sendable {
        public var levelZeroNodes = 0
        public var levelOneNodes = 0
        public var labeled = 0
    }

    /// Build level-1 parents over the existing level-0 communities and label
    /// every node deterministically. Idempotent: same level-0 world + same
    /// terms → same tree, always (level-1 rows are replaced wholesale).
    @discardableResult
    public func run() async throws -> Receipt {
        var receipt = Receipt()

        // 1 — the level-0 world (the detector's, untouched).
        let rows = try await database.query("""
        SELECT community_id, entity_id FROM entity_communities WHERE level = 0;
        """, [])
        var members: [String: [UUID]] = [:]
        for row in rows {
            guard let cid = row.string(0), let eid = row.uuid(1) else { continue }
            members[cid, default: []].append(eid)
        }
        receipt.levelZeroNodes = members.count
        guard !members.isEmpty else { return receipt }

        // 2 — each community's signature: the corroborated winner terms of the
        //     documents its members came from. A term equal to an identifier
        //     anchor's canon VALUE is an ANCHOR edge — one anchor row exists
        //     per identity (the UNIQUE law), but its value appears in the TEXT
        //     of every document naming it, so corroborated identifier terms
        //     are exactly the cross-document anchor linkage.
        var anchorCanons: [String: String] = [:]   // canon value → identity key
        let anchorRows = try await database.query("""
        SELECT normalized FROM entities WHERE kind = 'identifierAnchor' AND merged_into IS NULL;
        """, [])
        for r in anchorRows {
            guard let key = r.string(0) else { continue }
            let canon = key.split(separator: "|").dropFirst().joined(separator: "|")
            if !canon.isEmpty { anchorCanons[canon.lowercased()] = key }
        }
        var signature: [String: Set<String>] = [:]
        for (cid, ents) in members {
            var sig = Set<String>()
            for chunk in stride(from: 0, to: ents.count, by: 200) {
                let slice = Array(ents[chunk..<min(chunk + 200, ents.count)])
                let qs = slice.map { _ in "?" }.joined(separator: ",")
                let termRows = try await database.query("""
                SELECT DISTINCT dt.term FROM entities e1
                JOIN document_terms dt ON dt.object_id = e1.source_object_id
                WHERE e1.id IN (\(qs)) AND dt.corroboration >= 2;
                """, slice.map { .uuid($0) })
                for r in termRows {
                    guard let t = r.string(0) else { continue }
                    if let identity = anchorCanons[t.lowercased()] {
                        sig.insert("anchor:" + identity)
                    } else {
                        sig.insert("term:" + t.lowercased())
                    }
                }
            }
            signature[cid] = sig
        }

        // 3 — level-1 nesting by CONTAINMENT-like overlap: two level-0 nodes
        //     join one parent when their signatures share an anchor, or share
        //     ≥3 corroborated terms. Union-find, edges walked in total order.
        var parentOf: [String: String] = [:]
        func find(_ x: String) -> String {
            var r = x
            while let p = parentOf[r], p != r { r = p }
            return r
        }
        func union(_ a: String, _ b: String) {
            let ra = find(a), rb = find(b)
            guard ra != rb else { return }
            // Total order: the lexicographically smaller root wins.
            if ra < rb { parentOf[rb] = ra } else { parentOf[ra] = rb }
        }
        let cids = members.keys.sorted()
        for c in cids { parentOf[c] = c }
        for i in 0..<cids.count {
            for j in (i + 1)..<cids.count {
                let a = signature[cids[i]] ?? [], b = signature[cids[j]] ?? []
                let shared = a.intersection(b)
                let sharedAnchor = shared.contains { $0.hasPrefix("anchor:") }
                let sharedTerms = shared.filter { $0.hasPrefix("term:") }.count
                if sharedAnchor || sharedTerms >= 3 { union(cids[i], cids[j]) }
            }
        }
        var groups: [String: [String]] = [:]
        for c in cids { groups[find(c), default: []].append(c) }

        // 4 — persist level-1 (replace wholesale; level-0 untouched) + labels.
        try await database.exec("SAVEPOINT topic_tree;", [])
        do {
            try await database.exec("DELETE FROM entity_communities WHERE level = 1;", [])
            let now = Date().timeIntervalSince1970
            for (root, children) in groups.sorted(by: { $0.key < $1.key }) {
                // A parent with one child adds no structure — leaves stay leaves.
                guard children.count >= 2 else { continue }
                let allMembers = children.flatMap { members[$0] ?? [] }
                    .sorted { $0.uuidString < $1.uuidString }
                let nodeID = "L1-" + root
                for eid in allMembers {
                    try await database.exec("""
                    INSERT OR REPLACE INTO entity_communities (community_id, entity_id, level, computed_at)
                    VALUES (?, ?, 1, ?);
                    """, [.text(nodeID), .uuid(eid), .real(now)])
                }
                receipt.levelOneNodes += 1
                if let label = try await deterministicLabel(for: children, signature: signature) {
                    try await database.exec("""
                    INSERT OR REPLACE INTO community_summaries (community_id, level, title, summary, member_count, top_entity_ids_json, computed_at)
                    VALUES (?, 1, ?, '', ?, '[]', ?);
                    """, [.text(nodeID), .text(label), .integer(Int64(allMembers.count)), .real(now)])
                    receipt.labeled += 1
                }
            }
            try await database.exec("RELEASE topic_tree;", [])
        } catch {
            try? await database.exec("ROLLBACK TO topic_tree;", [])
            try? await database.exec("RELEASE topic_tree;", [])
            throw error
        }
        Self.log.info("TopicTree: \(receipt.levelZeroNodes) leaves → \(receipt.levelOneNodes) level-1 nodes (\(receipt.labeled) labeled)")
        return receipt
    }

    /// The node's label: an anchoring identifier's display form where one
    /// anchors the node (deterministic — smallest identity key wins ties),
    /// else the top corroborated shared terms.
    private func deterministicLabel(for children: [String], signature: [String: Set<String>]) async throws -> String? {
        var counts: [String: Int] = [:]
        for c in children {
            for s in signature[c] ?? [] { counts[s, default: 0] += 1 }
        }
        let sharedAnchors = counts.filter { $0.key.hasPrefix("anchor:") && $0.value >= 2 }
            .keys.sorted()
        if let key = sharedAnchors.first {
            let identity = String(key.dropFirst("anchor:".count))
            let parts = identity.split(separator: "|", maxSplits: 1).map(String.init)
            if parts.count == 2, let label = SubjectResolver.anchorLabels[parts[0]] {
                return "\(label) \(parts[1])"
            }
            return identity
        }
        let sharedTerms = counts.filter { $0.key.hasPrefix("term:") && $0.value >= 2 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(3)
            .map { String($0.key.dropFirst("term:".count)) }
        return sharedTerms.isEmpty ? nil : sharedTerms.joined(separator: " · ")
    }
}
