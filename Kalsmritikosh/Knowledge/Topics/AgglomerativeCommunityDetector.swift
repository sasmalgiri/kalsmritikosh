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
    public let id = "atlas.community.detect"

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
    private var runTask: Task<Void, Never>?
    private var lastRunStatus = LastRunStatus(serviceID: "atlas.community.detect")
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
        AtlasLog.knowledge.info("AgglomerativeCommunityDetector: starting (interval=\(self.intervalSeconds, privacy: .public)s, minMergeWeight=\(self.minMergeWeight, privacy: .public), maxCommunitySize=\(self.maxCommunitySize, privacy: .public))")
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
                    : await self.intervalSeconds
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
            let rows = try await database.query("""
            SELECT entity_a, entity_b, weight
            FROM entity_cooccurrences
            WHERE weight >= ?
            ORDER BY weight DESC;
            """, [.integer(Int64(minMergeWeight))])
            edges = rows.compactMap { row -> (UUID, UUID, Int)? in
                guard let a = row.uuid(0),
                      let b = row.uuid(1),
                      let w = row.int(2) else { return nil }
                return (a, b, Int(w))
            }
        } catch {
            AtlasLog.knowledge.error("AgglomerativeCommunityDetector: load edges failed — \(String(describing: error), privacy: .public)")
            return 0
        }
        guard !edges.isEmpty else {
            AtlasLog.knowledge.info("AgglomerativeCommunityDetector: no edges in graph; skipping")
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

        // Step 3 — greedy merge in descending weight order.
        var mergeCount = 0
        for edge in edges {
            if union(edge.a, edge.b) { mergeCount += 1 }
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
        var insertedRows = 0
        var insertFailures = 0
        let savepointName = "atlas_communities_write"
        do {
            try await database.exec("SAVEPOINT \(savepointName);")
            try await database.exec("DELETE FROM entity_communities WHERE level = ?;", [.integer(level0)])
            for (root, members) in membership {
                let sortedMembers = members.sorted { $0.uuidString < $1.uuidString }
                let stableID = sortedMembers.first ?? root
                for member in sortedMembers {
                    do {
                        try await database.exec(
                            "INSERT INTO entity_communities (community_id, entity_id, level, computed_at) VALUES (?, ?, ?, ?);",
                            [.uuid(stableID), .uuid(member), .integer(level0), .real(ts)]
                        )
                        insertedRows += 1
                    } catch {
                        insertFailures += 1
                        if insertFailures <= 3 {
                            AtlasLog.knowledge.error("AgglomerativeCommunityDetector: insert failed for member \(member.uuidString.prefix(8), privacy: .public) — \(String(describing: error), privacy: .public)")
                        }
                    }
                }
            }
            // Roll back the DELETE if literally nothing landed; we
            // don't want to empty the table on a wholesale failure.
            if insertedRows == 0 {
                try? await database.exec("ROLLBACK TO SAVEPOINT \(savepointName);")
                try? await database.exec("RELEASE SAVEPOINT \(savepointName);")
                AtlasLog.knowledge.error("AgglomerativeCommunityDetector: ALL inserts failed (\(insertFailures, privacy: .public) failures); kept previous communities table contents")
                return 0
            }
            try await database.exec("RELEASE SAVEPOINT \(savepointName);")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(savepointName);")
            try? await database.exec("RELEASE SAVEPOINT \(savepointName);")
            AtlasLog.knowledge.error("AgglomerativeCommunityDetector: write block failed — \(String(describing: error), privacy: .public)")
            return 0
        }
        if insertFailures > 0 {
            AtlasLog.knowledge.error("AgglomerativeCommunityDetector: \(insertFailures, privacy: .public) of \(insertedRows + insertFailures, privacy: .public) inserts failed (likely FK violations from cooccurrence edges pointing at deleted entity ids)")
        }

        let elapsed = Int(Date().timeIntervalSince(started))
        AtlasLog.knowledge.info("AgglomerativeCommunityDetector: built \(membership.count, privacy: .public) communities from \(edges.count, privacy: .public) edges (merges=\(mergeCount, privacy: .public)) in \(elapsed, privacy: .public)s")
        lastRunStatus = LastRunStatus(
            serviceID: lastRunStatus.serviceID,
            startedAt: lastRunStatus.startedAt,
            finishedAt: nil,
            resultCount: membership.count,
            runCount: lastRunStatus.runCount
        )
        return membership.count
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
