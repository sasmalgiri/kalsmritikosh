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
            // Only an identifier that names a MATTER may join two communities.
            // A bank account, tax id or personal id printed on a letterhead or
            // receipt is shared by unrelated matters — on the owner's archive one
            // account number pulled 332 of 340 members into a single node.
            let field = String(key.split(separator: "|").first ?? "")
            guard SubjectSpine.subjectGradeFields.contains(field) else { continue }
            let canon = key.split(separator: "|").dropFirst().joined(separator: "|")
            if !canon.isEmpty { anchorCanons[canon.lowercased()] = key }
        }
        // A truncated copy ("Application-2023310" in a report's subject list) is
        // not its own matter: drop any canon that is a strict prefix of another.
        let allCanons = Array(anchorCanons.keys)
        for c in allCanons where allCanons.contains(where: { $0 != c && $0.hasPrefix(c) }) {
            anchorCanons.removeValue(forKey: c)
        }
        // L3 — a term that most documents carry ("patent", "khurana", a city on
        // every letterhead) links everything to everything; on the owner's
        // archive such terms fused 226 of 340 members into one node. Only terms
        // corroborated by ≥2 documents AND by at most a fifth of them are links.
        let totalKOs = Int((try await database.query("SELECT COUNT(*) FROM knowledge_objects;", [])).first?.int(0) ?? 0)
        let dfCeiling = max(2, totalKOs / 5)
        var signature: [String: Set<String>] = [:]
        for (cid, ents) in members {
            var sig = Set<String>()
            for chunk in stride(from: 0, to: ents.count, by: 200) {
                let slice = Array(ents[chunk..<min(chunk + 200, ents.count)])
                let qs = slice.map { _ in "?" }.joined(separator: ",")
                let termRows = try await database.query("""
                SELECT DISTINCT dt.term FROM entities e1
                JOIN document_terms dt ON dt.object_id = e1.source_object_id
                WHERE e1.id IN (\(qs)) AND dt.corroboration >= 2 AND dt.corroboration <= ?;
                """, slice.map { .uuid($0) } + [.integer(Int64(dfCeiling))])
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

        // 2b — HUB CEILING. An anchor or term shared by more than a quarter of
        //      all communities is a hub, not a link: the owner's archive glued
        //      226 of 340 members into one node through a single identifier
        //      carried by reports that list every email.
        var spread: [String: Int] = [:]
        for sig in signature.values { for s in sig { spread[s, default: 0] += 1 } }
        let hubCeiling = max(3, members.count / 4)
        for (cid, sig) in signature {
            signature[cid] = sig.filter { (spread[$0] ?? 0) <= hubCeiling }
        }

        // 3 — level-1 nesting as STARS, never chains (P1.3, 2026-09-27). The
        //     first version was union-find over "share an anchor OR ≥3 terms",
        //     which is transitive: on the owner's archive 57 of 81 level-0
        //     communities (319 entities — résumés, GDPR reports, bounces) chained
        //     into one "Patent" node through one weak link at a time.
        //     (a) An anchored community joins the node of its MOST SPECIFIC
        //         shared anchor (fewest communities carry it; ties by key) — it
        //         sits under a matter only if it names that matter itself.
        //     (b) A term-only community attaches to its single best match, and
        //         only ONE hop out: a follower never pulls further followers in.
        //         "Best" is overlap RELATIVE TO SIZE (Jaccard ≥ 0.15, ≥3 shared
        //         terms): a raw count let two 100-entity communities, whose
        //         signatures hold hundreds of terms, adopt ~40 unrelated
        //         followers (email date headers, job-site addresses).
        let cids = members.keys.sorted()
        var anchorSpread: [String: Int] = [:]
        for sig in signature.values {
            for s in sig where s.hasPrefix("anchor:") { anchorSpread[s, default: 0] += 1 }
        }
        var groupOf: [String: String] = [:]     // community → group key
        var isFollower = Set<String>()          // joined by (b); may not recruit
        for c in cids {
            let anchors = (signature[c] ?? []).filter { $0.hasPrefix("anchor:") && (anchorSpread[$0] ?? 0) >= 2 }
            if let best = anchors.min(by: { (anchorSpread[$0] ?? 0, $0) < (anchorSpread[$1] ?? 0, $1) }) {
                groupOf[c] = best
            }
        }
        let termSets = signature.mapValues { $0.filter { $0.hasPrefix("term:") } }
        func termSimilarity(_ a: String, _ b: String) -> Double? {
            let ta = termSets[a] ?? [], tb = termSets[b] ?? []
            let shared = ta.intersection(tb).count
            guard shared >= 3 else { return nil }
            let jaccard = Double(shared) / Double(ta.union(tb).count)
            return jaccard >= 0.15 ? jaccard : nil
        }
        for c in cids where groupOf[c] == nil {
            var best: (id: String, j: Double)? = nil
            for d in cids where d != c {
                guard let j = termSimilarity(c, d) else { continue }
                if best == nil || j > best!.j || (j == best!.j && d < best!.id) { best = (d, j) }
            }
            guard let partner = best?.id else { continue }
            if let g = groupOf[partner] {
                guard !isFollower.contains(partner) else { continue }   // one hop only
                groupOf[c] = g
                isFollower.insert(c)
            } else {
                // Two term-only communities found each other: the smaller id roots it.
                let root = min(c, partner)
                groupOf[c] = "terms:" + root
                groupOf[partner] = "terms:" + root
                isFollower.insert(c == root ? partner : c)
            }
        }
        var groups: [String: [String]] = [:]
        for c in cids {
            // Ungrouped communities stay leaves; the root is the smallest member id.
            guard let g = groupOf[c] else { groups[c, default: []].append(c); continue }
            groups[g, default: []].append(c)
        }
        groups = Dictionary(uniqueKeysWithValues: groups.values.map { kids in
            let sortedKids = kids.sorted()
            return (sortedKids[0], sortedKids)
        })

        // A6 idempotence (parity caught it): a wholesale rewrite every boot
        // moves the ledger stamp every run. Skip when NOTHING level-0 changed
        // since the last build (signature = level-0 row count + max stamp vs
        // the stored level-1 build stamp).
        let sig = try await database.query("""
        SELECT (SELECT COUNT(*) FROM entity_communities WHERE level = 0),
               (SELECT COALESCE(MAX(computed_at), 0) FROM entity_communities WHERE level = 0),
               (SELECT COALESCE(MAX(computed_at), 0) FROM entity_communities WHERE level = 1);
        """, []).first
        let l0Count = sig?.int(0) ?? 0
        let l0Max = sig?.double(1) ?? 0
        let l1Built = sig?.double(2) ?? -1
        if l1Built >= l0Max, l0Count > 0, receipt.levelOneNodes == 0 {
            // Level-1 is newer than every level-0 row → the tree is current.
            let existing = try await database.query(
                "SELECT COUNT(DISTINCT community_id) FROM entity_communities WHERE level = 1;", []).first?.int(0) ?? 0
            if existing > 0 || groups.allSatisfy({ $0.value.count < 2 }) {
                receipt.levelOneNodes = Int(existing)
                return receipt
            }
        }

        // 4 — persist level-1 (replace wholesale; level-0 untouched) + labels.
        try await database.exec("SAVEPOINT topic_tree;", [])
        do {
            try await database.exec("DELETE FROM entity_communities WHERE level = 1;", [])
            // Replace the labels with the nodes: a node that no longer exists
            // kept its old label, so stale titles outlived every rebuild.
            try await database.exec("DELETE FROM community_summaries WHERE level = 1;", [])
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
