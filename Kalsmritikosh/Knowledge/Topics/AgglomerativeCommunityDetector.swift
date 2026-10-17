//
//  AgglomerativeCommunityDetector.swift
//  Kalsmritikosh
//
//  HISTORY Phase B.2 — community detection MVP. Greedy bottom-up
//  agglomerative clustering on the entity_cooccurrences graph
//  built by Phase B.1.
//
//  This is the simpler-but-deterministic alternative to Leiden the
//  plan explicitly allowed:
//      "We could also start with a simpler agglomerative clustering,
//       accept lower quality, swap later."
//
//  Algorithm:
//    1. Every entity starts as its own community (union-find).
//    2. Walk co-occurrence edges in DESCENDING weight order.
//    3. For each edge (a, b):
//         - Find current community of a and b.
//         - If different AND combined size ≤ maxCommunitySize:
//             merge them.
//         - Stop when edge weight drops below minMergeWeight.
//    4. Write resulting (community_id, entity_id) rows.
//
//  Properties:
//    - Deterministic given a fixed edge-order
//    - O(E × α(N)) with union-find — fast on practical archive sizes
//    - Produces communities of bounded size (no runaway "everything
//      is connected to gmail.com" mega-cluster)
//    - Doesn't need iteration; one pass through edges is enough
//
//  Leiden swap-in later: keep the same output table; replace just
//  this detector.
//

import Foundation
import OSLog

public actor AgglomerativeCommunityDetector: BackgroundService {
    public let id = "kalsmritikosh.community.detect"

    private let database: Database
    private let intervalSeconds: TimeInterval
    /// Stop merging when an edge's weight drops below this. Below
    /// this threshold the edge is "weak" and probably reflects a
    /// chance co-mention more than a real topic boundary.
    private let minMergeWeight: Int
    /// Upper bound on community size. Without this, in a busy
    /// inbox every email implicitly mentions "gmail.com" and the
    /// algorithm would collapse the entire graph into one
    /// community.
    private let maxCommunitySize: Int
    /// P1.18 — the weakest ASSOCIATION an edge may carry to merge: the share
    /// of the rarer entity's documents that also name the other. Weight alone
    /// chained a matter to the cap: an address named beside the law firm only
    /// in three archive-wide reports (of its ten documents) joined the patent
    /// matter as readily as the firm's own letterhead partners (always beside
    /// it). Single-linkage needs a relative bar, not just an absolute one.
    static let minAssociation = 0.5
    private var runTask: Task<Void, Never>?
    private var lastRunStatus = LastRunStatus(serviceID: "kalsmritikosh.community.detect")
    public func currentStatus() -> LastRunStatus { lastRunStatus }

    public init(
        database: Database,
        intervalSeconds: TimeInterval = 12 * 3_600, // 2× per day
        minMergeWeight: Int = 3,
        maxCommunitySize: Int = 100
    ) {
        self.database = database
        self.intervalSeconds = intervalSeconds
        self.minMergeWeight = minMergeWeight
        self.maxCommunitySize = maxCommunitySize
    }

    public func start() async {
        guard runTask == nil else { return }
        KalsmritikoshLog.knowledge.info("AgglomerativeCommunityDetector: starting (interval=\(self.intervalSeconds, privacy: .public)s, minMergeWeight=\(self.minMergeWeight, privacy: .public), maxCommunitySize=\(self.maxCommunitySize, privacy: .public))")
        runTask = Task { [weak self] in
            guard let self else { return }
            // Boot-warmup window — same rationale as
            // CooccurrenceGraphBuilder. On a fresh DB the first run
            // finds no co-occurrence edges, so the 12-hour interval
            // would leave the communities table empty for half a day
            // after ingestion produces edges. Retry every 5 min for
            // the first 2 hours, then back off to the configured
            // cadence.
            let bootTime = Date()
            while !Task.isCancelled {
                let produced = await self.runOnce()
                let warmupActive = Date().timeIntervalSince(bootTime) < 2 * 3_600
                let sleepSeconds: TimeInterval = (produced == 0 && warmupActive)
                    ? 5 * 60
                    : self.intervalSeconds
                let ns = UInt64(sleepSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
            }
        }
    }

    public func stop() async {
        runTask?.cancel()
        runTask = nil
    }

    /// One full detection pass. Idempotent; replaces the existing
    /// communities table contents. Returns the number of communities
    /// produced.
    @discardableResult
    public func runOnce() async -> Int {
        let started = Date()
        lastRunStatus = LastRunStatus(
            serviceID: lastRunStatus.serviceID,
            startedAt: started, finishedAt: nil,
            resultCount: 0,
            runCount: lastRunStatus.runCount
        )
        defer {
            lastRunStatus = LastRunStatus(
                serviceID: lastRunStatus.serviceID,
                startedAt: started,
                finishedAt: Date(),
                resultCount: lastRunStatus.resultCount,
                runCount: lastRunStatus.runCount + 1,
                lastError: lastRunStatus.lastError
            )
        }

        // Step 1 — load edges sorted DESC by weight.
        let edges: [(a: UUID, b: UUID, w: Int)]
        do {
            // P1.14 — attributes are never community members, even when an
            // older graph still carries their edges: on the owner's copy 88
            // of ~350 community members were email date headers, left over
            // from a graph built before CooccurrenceGraphBuilder excluded
            // them. Same kind list as the builder.
            // P1.18 — retired entities and names the ledger also holds as a
            // PLACE (NER typed "Chennai" an organization) join nothing.
            let rows = try await database.query("""
            WITH places AS (SELECT normalized FROM entities WHERE kind = 'location')
            SELECT c.entity_a, c.entity_b, c.weight
            FROM entity_cooccurrences c
            JOIN entities ea ON ea.id = c.entity_a
            JOIN entities eb ON eb.id = c.entity_b
            WHERE c.weight >= ?
              AND ea.kind NOT IN ('date', 'deadline', 'milestone', 'money', 'currency', 'phoneNumber', 'location')
              AND eb.kind NOT IN ('date', 'deadline', 'milestone', 'money', 'currency', 'phoneNumber', 'location')
              AND COALESCE(ea.review_status, '') != 'rejected' AND COALESCE(eb.review_status, '') != 'rejected'
              AND NOT (ea.kind IN ('person', 'organization', 'vendor', 'client') AND ea.normalized IN (SELECT normalized FROM places))
              AND NOT (eb.kind IN ('person', 'organization', 'vendor', 'client') AND eb.normalized IN (SELECT normalized FROM places))
            ORDER BY c.weight DESC, c.entity_a, c.entity_b;
            """, [.integer(Int64(minMergeWeight))])
            edges = rows.compactMap { row -> (UUID, UUID, Int)? in
                guard let a = row.uuid(0),
                      let b = row.uuid(1),
                      let w = row.int(2) else { return nil }
                return (a, b, Int(w))
            }
        } catch {
            KalsmritikoshLog.knowledge.error("AgglomerativeCommunityDetector: load edges failed — \(String(describing: error), privacy: .public)")
            return 0
        }
        guard !edges.isEmpty else {
            KalsmritikoshLog.knowledge.info("AgglomerativeCommunityDetector: no edges in graph; skipping")
            return 0
        }

        // Step 2 — union-find. Each unique entity is initially its
        // own community.
        var parent: [UUID: UUID] = [:]
        var size: [UUID: Int] = [:]
        func find(_ x: UUID) -> UUID {
            if parent[x] == nil { parent[x] = x; size[x] = 1 }
            var cur = x
            while parent[cur] != cur { cur = parent[cur]! }
            // Path compression
            var node = x
            while node != cur {
                let next = parent[node]!
                parent[node] = cur
                node = next
            }
            return cur
        }
        func union(_ x: UUID, _ y: UUID) -> Bool {
            let rx = find(x), ry = find(y)
            guard rx != ry else { return false }
            let sx = size[rx]!, sy = size[ry]!
            if sx + sy > maxCommunitySize { return false }
            // Smaller into larger.
            if sx < sy {
                parent[rx] = ry
                size[ry] = sx + sy
            } else {
                parent[ry] = rx
                size[rx] = sx + sy
            }
            return true
        }

        // P1.18 — per-entity document counts for the association bar.
        var documentCount: [UUID: Int] = [:]
        do {
            for row in try await database.query("""
            SELECT entity_id, COUNT(DISTINCT source_object_id) FROM entity_mentions GROUP BY entity_id;
            """, []) {
                if let id = row.uuid(0), let n = row.int(1) { documentCount[id] = Int(n) }
            }
        } catch {
            // Without counts every edge passes the bar — the historical behaviour.
            KalsmritikoshLog.knowledge.error("AgglomerativeCommunityDetector: document counts failed — \(String(describing: error), privacy: .public)")
        }

        // Step 3 — greedy merge in descending weight order.
        var mergeCount = 0
        var weakSkipped = 0
        for edge in edges {
            guard Self.associated(weight: edge.w, documentsA: documentCount[edge.a], documentsB: documentCount[edge.b]) else {
                weakSkipped += 1
                continue
            }
            if union(edge.a, edge.b) { mergeCount += 1 }
        }
        if weakSkipped > 0 {
            KalsmritikoshLog.knowledge.info("AgglomerativeCommunityDetector: \(weakSkipped, privacy: .public) weakly associated edge(s) not merged")
        }

        // Step 4 — collect membership: { root: [members] }
        var membership: [UUID: [UUID]] = [:]
        for entity in parent.keys {
            let root = find(entity)
            membership[root, default: []].append(entity)
        }

        // Step 5 — write to DB. Replace contents.
        //
        // Real-data audit (2026-06-28): production DB had 23,581
        // edges with weight ≥ 3 and 127,989 total cooccurrence rows,
        // but entity_communities was EMPTY. Root cause: a single
        // failing INSERT inside the for-loop bubbled to the outer
        // catch, abandoning ALL membership writes even though the
        // preceding DELETE had committed. The detector then returned
        // 0 and logged ONE error — easy to miss in production logs.
        //
        // Fix: per-row error swallow + counters so one FK violation
        // doesn't kill the whole pass. SAVEPOINT wrap so the DELETE
        // rolls back when the membership write fails ENTIRELY (zero
        // INSERTs succeeded), so the table never ends up emptier than
        // before.
        let level0: Int64 = 0
        let ts = started.timeIntervalSince1970
        let savepointName = "kalsmritikosh_communities_write"
        let groups: [(id: UUID, members: [UUID])] = membership.map { root, members in
            let sorted = members.sorted { $0.uuidString < $1.uuidString }
            return (sorted.first ?? root, sorted)
        }
        /// Thrown inside the savepoint to undo the DELETE when nothing landed.
        struct NothingInserted: Error { let failures: Int }
        let insertedRows: Int, insertFailures: Int
        do {
            // F28 — replace level 0 in ONE isolated savepoint.
            (insertedRows, insertFailures) = try await database.withSavepoint(savepointName) { db -> (Int, Int) in
                var inserted = 0, failures = 0
                try db.exec("DELETE FROM entity_communities WHERE level = ?;", [.integer(level0)])
                for (stableID, sortedMembers) in groups {
                    for member in sortedMembers {
                        do {
                            try db.exec(
                                "INSERT INTO entity_communities (community_id, entity_id, level, computed_at) VALUES (?, ?, ?, ?);",
                                [.uuid(stableID), .uuid(member), .integer(level0), .real(ts)]
                            )
                            inserted += 1
                        } catch {
                            failures += 1
                            if failures <= 3 {
                                KalsmritikoshLog.knowledge.error("AgglomerativeCommunityDetector: insert failed for member \(member.uuidString.prefix(8), privacy: .public) — \(String(describing: error), privacy: .public)")
                            }
                        }
                    }
                }
                // Roll back the DELETE if literally nothing landed; we
                // don't want to empty the table on a wholesale failure.
                if inserted == 0 { throw NothingInserted(failures: failures) }
                return (inserted, failures)
            }
        } catch let e as NothingInserted {
            KalsmritikoshLog.knowledge.error("AgglomerativeCommunityDetector: ALL inserts failed (\(e.failures, privacy: .public) failures); kept previous communities table contents")
            return 0
        } catch {
            KalsmritikoshLog.knowledge.error("AgglomerativeCommunityDetector: write block failed — \(String(describing: error), privacy: .public)")
            return 0
        }
        if insertFailures > 0 {
            KalsmritikoshLog.knowledge.error("AgglomerativeCommunityDetector: \(insertFailures, privacy: .public) of \(insertedRows + insertFailures, privacy: .public) inserts failed (likely FK violations from cooccurrence edges pointing at deleted entity ids)")
        }

        // P1.14 — the level-1 topic tree is built over these communities; the
        // boot pass may have built it from the previous set, so refresh it
        // now rather than leaving the Big Picture one detector cycle stale.
        do {
            _ = try await TopicTreeBuilder(database: database).run()
        } catch {
            KalsmritikoshLog.knowledge.error("AgglomerativeCommunityDetector: topic tree refresh failed — \(String(describing: error), privacy: .public)")
        }

        let elapsed = Int(Date().timeIntervalSince(started))
        KalsmritikoshLog.knowledge.info("AgglomerativeCommunityDetector: built \(membership.count, privacy: .public) communities from \(edges.count, privacy: .public) edges (merges=\(mergeCount, privacy: .public)) in \(elapsed, privacy: .public)s")
        lastRunStatus = LastRunStatus(
            serviceID: lastRunStatus.serviceID,
            startedAt: lastRunStatus.startedAt,
            finishedAt: nil,
            resultCount: membership.count,
            runCount: lastRunStatus.runCount
        )
        return membership.count
    }

    /// True when the co-mentions cover at least `minAssociation` of the rarer
    /// entity's documents. Unknown counts pass (no evidence to refuse on).
    nonisolated static func associated(weight: Int, documentsA: Int?, documentsB: Int?) -> Bool {
        guard let a = documentsA, let b = documentsB, min(a, b) > 0 else { return true }
        return Double(weight) / Double(min(a, b)) >= minAssociation
    }

    // MARK: - Read API

    /// What community does this entity belong to (at level 0)?
    public func community(forEntity id: Entity.ID) async throws -> UUID? {
        let rows = try await database.query(
            "SELECT community_id FROM entity_communities WHERE entity_id = ? AND level = 0 LIMIT 1;",
            [.uuid(id)]
        )
        return rows.first?.uuid(0)
    }

    /// Who's in this community?
    public func members(of communityID: UUID, limit: Int = 100) async throws -> [Entity.ID] {
        let rows = try await database.query(
            "SELECT entity_id FROM entity_communities WHERE community_id = ? AND level = 0 LIMIT ?;",
            [.uuid(communityID), .integer(Int64(limit))]
        )
        return rows.compactMap { $0.uuid(0) }
    }

    /// All distinct communities, sorted by descending member count.
    /// Used by Phase B.3 to know which communities need a summary.
    public func allCommunities(limit: Int = 1_000) async throws -> [(id: UUID, memberCount: Int)] {
        let rows = try await database.query("""
        SELECT community_id, COUNT(*) AS member_count
        FROM entity_communities
        WHERE level = 0
        GROUP BY community_id
        ORDER BY member_count DESC
        LIMIT ?;
        """, [.integer(Int64(limit))])
        return rows.compactMap { row -> (UUID, Int)? in
            guard let id = row.uuid(0),
                  let count = row.int(1) else { return nil }
            return (id, Int(count))
        }
    }
}
