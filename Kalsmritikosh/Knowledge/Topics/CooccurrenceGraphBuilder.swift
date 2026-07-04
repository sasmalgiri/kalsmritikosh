//
//  CooccurrenceGraphBuilder.swift
//  Kalsmritikosh
//
//  HISTORY Phase B.1 — builds the entity co-occurrence graph in
//  `entity_cooccurrences`. An edge means two entities share at
//  least one KnowledgeObject; the weight is the count of shared
//  KOs.
//
//  Why this exists: community detection (Phase B.2) needs an
//  edge-weighted graph as input. mem0-style narrative composition
//  (Phase D) needs topic boundaries to know where one chapter
//  ends and the next begins. Both feed off this table.
//
//  Cost note: a naive self-join over `entity_mentions` is O(N²)
//  per source_object. For real archives we batch by KO id, so the
//  rebuild is roughly O(total_mentions × avg_mentions_per_KO).
//

import Foundation
import OSLog

public actor CooccurrenceGraphBuilder: BackgroundService {
    public let id = "atlas.cooccurrence.builder"

    private let database: Database
    private let intervalSeconds: TimeInterval
    /// Minimum shared-KO count for an edge to land. Filters out
    /// chance one-shot co-mentions that aren't real topic signal.
    private let minWeight: Int
    private var runTask: Task<Void, Never>?
    private var lastRunStatus = LastRunStatus(serviceID: "atlas.cooccurrence.builder")
    public func currentStatus() -> LastRunStatus { lastRunStatus }

    public init(
        database: Database,
        intervalSeconds: TimeInterval = 6 * 3_600, // 4× per day
        minWeight: Int = 2
    ) {
        self.database = database
        self.intervalSeconds = intervalSeconds
        self.minWeight = minWeight
    }

    public func start() async {
        guard runTask == nil else { return }
        AtlasLog.knowledge.info("CooccurrenceGraphBuilder: starting (interval=\(self.intervalSeconds, privacy: .public)s, minWeight=\(self.minWeight, privacy: .public))")
        runTask = Task { [weak self] in
            guard let self else { return }
            // Boot-warmup window — on a fresh DB, the first pass at
            // boot time finds zero entity mentions (ingestion hasn't
            // produced any yet). Without this short retry the graph
            // stays empty for the full 6-hour interval. We keep
            // retrying every 5 minutes for the first 2 hours after
            // start; after that we trust the steady-state cadence.
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

    /// One full rebuild. Idempotent; replaces the table contents.
    /// Returns the number of edges written.
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
        // Step 1 — clear the existing graph. The cost of a rebuild
        // is dominated by step 2; the truncate is cheap.
        do {
            try await database.exec("DELETE FROM entity_cooccurrences;", [])
        } catch {
            AtlasLog.knowledge.error("CooccurrenceGraphBuilder: truncate failed — \(String(describing: error), privacy: .public)")
            return 0
        }

        // Step 2 — compute edges via SQL self-join. We restrict to
        // canonical entities (T1 + T2; T3 stays out of the topic
        // graph since the plan's preserve-not-filter rule only
        // affects RETRIEVAL — T3 should not pollute communities).
        //
        // Ordering by id ensures each pair appears once
        // (entity_a < entity_b lexicographically).
        let sql = """
        INSERT INTO entity_cooccurrences (entity_a, entity_b, weight, computed_at)
        SELECT
            m1.entity_id AS entity_a,
            m2.entity_id AS entity_b,
            COUNT(DISTINCT m1.source_object_id) AS weight,
            ?
        FROM entity_mentions m1
        JOIN entity_mentions m2
            ON m1.source_object_id = m2.source_object_id
            AND m1.entity_id < m2.entity_id
        JOIN entities e1 ON e1.id = m1.entity_id AND e1.quality_tier IN ('T1','T2')
        JOIN entities e2 ON e2.id = m2.entity_id AND e2.quality_tier IN ('T1','T2')
        GROUP BY m1.entity_id, m2.entity_id
        HAVING weight >= ?;
        """

        do {
            try await database.exec(sql, [
                .real(started.timeIntervalSince1970),
                .integer(Int64(minWeight))
            ])
        } catch {
            AtlasLog.knowledge.error("CooccurrenceGraphBuilder: rebuild failed — \(String(describing: error), privacy: .public)")
            return 0
        }

        let count: Int
        do {
            let rows = try await database.query("SELECT COUNT(*) FROM entity_cooccurrences;", [])
            count = Int(rows.first?.int(0) ?? 0)
        } catch {
            count = -1
        }
        let elapsed = Int(Date().timeIntervalSince(started))
        AtlasLog.knowledge.info("CooccurrenceGraphBuilder: rebuilt \(count, privacy: .public) edges in \(elapsed, privacy: .public)s")
        lastRunStatus = LastRunStatus(
            serviceID: lastRunStatus.serviceID,
            startedAt: lastRunStatus.startedAt,
            finishedAt: nil,
            resultCount: max(0, count),
            runCount: lastRunStatus.runCount
        )
        return count
    }

    // MARK: - Read API

    /// Returns the heaviest edges for a single entity. Used by the
    /// Phase B.2 community detector to walk neighbors.
    public func neighbors(of entityID: Entity.ID, limit: Int = 50) async throws -> [(other: Entity.ID, weight: Int)] {
        let rows = try await database.query("""
        SELECT entity_b, weight FROM entity_cooccurrences WHERE entity_a = ?
        UNION ALL
        SELECT entity_a, weight FROM entity_cooccurrences WHERE entity_b = ?
        ORDER BY weight DESC
        LIMIT ?;
        """, [.uuid(entityID), .uuid(entityID), .integer(Int64(limit))])
        return rows.compactMap { row -> (Entity.ID, Int)? in
            guard let other = row.uuid(0),
                  let weight = row.int(1) else { return nil }
            return (other, Int(weight))
        }
    }

    /// Counts of edges by quality_tier mix — surfaced in Settings
    /// for the operator to see "topic graph has 4,217 edges, 87
    /// communities" type stats once Phase B.2 lands.
    public func edgeCount() async throws -> Int {
        let rows = try await database.query("SELECT COUNT(*) FROM entity_cooccurrences;", [])
        return Int(rows.first?.int(0) ?? 0)
    }
}
