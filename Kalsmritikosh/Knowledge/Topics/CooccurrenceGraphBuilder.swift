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
    public let id = "kalsmritikosh.cooccurrence.builder"

    private let database: Database
    private let intervalSeconds: TimeInterval
    /// Minimum shared-KO count for an edge to land. Filters out
    /// chance one-shot co-mentions that aren't real topic signal.
    private let minWeight: Int
    private var runTask: Task<Void, Never>?
    private var lastRunStatus = LastRunStatus(serviceID: "kalsmritikosh.cooccurrence.builder")
    public func currentStatus() -> LastRunStatus { lastRunStatus }

    /// P1.18b — quoted "Subject:" AND "From:" headers a non-mail document
    /// must carry to count as a message listing.
    static let minQuotedHeadersForListing = 3

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
        KalsmritikoshLog.knowledge.info("CooccurrenceGraphBuilder: starting (interval=\(self.intervalSeconds, privacy: .public)s, minWeight=\(self.minWeight, privacy: .public))")
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
        // Step 1 — the hub ceiling. An entity named in more than a fifth of
        // the documents that have any entity (the owner's own name, a law
        // firm's letterhead offices) connects everything to everything; on the
        // owner's archive such hubs fused 100 unrelated entities into one
        // community. They stay in the ledger and in retrieval — only the topic
        // graph leaves them out.
        let documentsWithEntities: Int
        do {
            let rows = try await database.query(
                "SELECT COUNT(DISTINCT source_object_id) FROM entity_mentions;", [])
            documentsWithEntities = Int(rows.first?.int(0) ?? 0)
        } catch {
            KalsmritikoshLog.knowledge.error("CooccurrenceGraphBuilder: document count failed — \(String(describing: error), privacy: .public)")
            return 0
        }
        let hubCeiling = max(5, documentsWithEntities / 5)

        // Step 2 — compute edges via SQL self-join. We restrict to
        // canonical entities (T1 + T2; T3 stays out of the topic
        // graph since the plan's preserve-not-filter rule only
        // affects RETRIEVAL — T3 should not pollute communities).
        // Dates, amounts and phone numbers are attributes, not topic
        // members: "Thu, 29 Aug 2024 16:08:51" joined unrelated emails.
        // P1.16 — so are places: résumés list cities, spreadsheets list
        // countries, and on the owner's copy one community of 100 (the cap)
        // was nothing but locations. They stay in the ledger and retrieval.
        //
        // Ordering by id ensures each pair appears once
        // (entity_a < entity_b lexicographically).
        // P1.18b — a MESSAGE LISTING (a report or export that quotes many
        // messages' From/Subject headers but is not itself mail) names people
        // side by side without relating them: on the owner's copy three copies
        // of a GDPR report were the ONLY documents joining a manga-scan group,
        // a loan officer and a recruiter to the patent attorneys. Such a
        // document contributes no edge; it stays in the ledger and retrieval.
        // Mail itself is exempt — quoted replies are a real conversation.
        // Computed ONCE, up front: inside the edge query the text scan ran per
        // row and held the database long enough to delay claim projection
        // (measured: a slot answer lost its corroboration floor).
        let listingIDs: [String]
        do {
            let mailTypes = SourceType.allCases.filter { $0.category == .email }.map { SQLValue.text($0.rawValue) }
            let marks = mailTypes.map { _ in "?" }.joined(separator: ", ")
            let minQuoted = Int64(Self.minQuotedHeadersForListing)
            listingIDs = try await database.query("""
            SELECT id FROM knowledge_objects
            WHERE source_type NOT IN (\(marks))
              AND instr(lower(content), 'subject:') > 0
              AND (length(content) - length(replace(lower(content), 'subject:', ''))) / 8 >= ?
              AND (length(content) - length(replace(lower(content), 'from:', ''))) / 5 >= ?;
            """, mailTypes + [.integer(minQuoted), .integer(minQuoted)]).compactMap { $0.string(0) }
        } catch {
            KalsmritikoshLog.knowledge.error("CooccurrenceGraphBuilder: listing scan failed, no document excluded — \(String(describing: error), privacy: .public)")
            listingIDs = []
        }
        let listingJSON = (try? String(data: JSONEncoder().encode(listingIDs), encoding: .utf8)) ?? "[]"
        if !listingIDs.isEmpty {
            KalsmritikoshLog.knowledge.info("CooccurrenceGraphBuilder: \(listingIDs.count, privacy: .public) message-listing document(s) contribute no edges")
        }
        let sql = """
        WITH listings AS (SELECT value AS id FROM json_each(?)),
        eligible AS (
            SELECT e.id FROM entities e
            WHERE e.quality_tier IN ('T1','T2')
              AND e.kind NOT IN ('date', 'deadline', 'milestone', 'money', 'currency', 'phoneNumber', 'location')
              AND COALESCE(e.review_status, '') != 'rejected'
              -- P1.18: a NAME the ledger also holds as a PLACE is a place mistyped
              -- by NER ("Chennai" as an organization bridged the patent matter to
              -- unrelated résumés). The ledger's own typing decides; no gazetteer.
              AND NOT (e.kind IN ('person', 'organization', 'vendor', 'client')
                       AND e.normalized IN (SELECT l.normalized FROM entities l WHERE l.kind = 'location'))
              AND (SELECT COUNT(DISTINCT x.source_object_id) FROM entity_mentions x
                   WHERE x.entity_id = e.id) <= ?
        )
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
        JOIN eligible e1 ON e1.id = m1.entity_id
        JOIN eligible e2 ON e2.id = m2.entity_id
        WHERE m1.source_object_id NOT IN (SELECT id FROM listings)
        GROUP BY m1.entity_id, m2.entity_id
        HAVING weight >= ?;
        """

        // Clear + rebuild as ONE unit. The clear used to commit on its own, so
        // a rebuild that then failed left the graph EMPTY until the next run
        // (the owner's ledger: 0 edges while its mentions support 11,565).
        let binds: [SQLValue] = [
            .text(listingJSON),
            .integer(Int64(hubCeiling)),
            .real(started.timeIntervalSince1970),
            .integer(Int64(minWeight))
        ]
        do {
            // F28 — one isolated savepoint: no reader sees the graph half-cleared.
            try await database.withSavepoint("cooccurrence_rebuild") { db in
                try db.exec("DELETE FROM entity_cooccurrences;", [])
                try db.exec(sql, binds)
            }
        } catch {
            KalsmritikoshLog.knowledge.error("CooccurrenceGraphBuilder: rebuild failed, previous graph kept — \(String(describing: error), privacy: .public)")
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
        KalsmritikoshLog.knowledge.info("CooccurrenceGraphBuilder: rebuilt \(count, privacy: .public) edges in \(elapsed, privacy: .public)s")
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
