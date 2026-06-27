//
//  QualityTierBackfiller.swift
//  Kalsmritikosh
//
//  HISTORY Phase A.8 — periodic background task that re-tiers rows
//  inserted before the Phase A tier-annotation commits landed (or
//  rows that were written with the schema's DEFAULT 'T2' because
//  their writer hadn't yet been updated to pass an explicit tier).
//
//  Preserve-all-data rule: this task NEVER deletes rows. It only
//  recomputes the quality_tier COLUMN against the same value/kind
//  the classifier sees on a fresh ingest. Idempotent — running it
//  twice produces the same result.
//
//  Scope: entities only for now (events are mostly T2-by-design;
//  bonds + memory inherit at insert time and don't need a backfill
//  pass). Bounded batches so a large archive doesn't lock the DB.
//

import Foundation
import OSLog

public actor QualityTierBackfiller: BackgroundService {
    public let id = "atlas.qualityTier.backfill"

    private let database: Database
    private let intervalSeconds: TimeInterval
    private let batchSize: Int
    private var runTask: Task<Void, Never>?

    public init(
        database: Database,
        intervalSeconds: TimeInterval = 3_600, // hourly
        batchSize: Int = 500
    ) {
        self.database = database
        self.intervalSeconds = intervalSeconds
        self.batchSize = batchSize
    }

    public func start() async {
        guard runTask == nil else { return }
        AtlasLog.knowledge.info("QualityTierBackfiller: starting (interval=\(self.intervalSeconds, privacy: .public)s, batch=\(self.batchSize, privacy: .public))")
        runTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.runOnce()
                let ns = await UInt64(self.intervalSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
            }
        }
    }

    public func stop() async {
        runTask?.cancel()
        runTask = nil
    }

    /// One pass. Picks up to `batchSize` entity rows whose
    /// quality_tier is still 'T2' AND was inserted before this
    /// commit landed (a heuristic: any T2 row whose value would
    /// classify as T3 today is a candidate for re-tier).
    ///
    /// Returns count of rows actually re-tagged so callers can
    /// surface "N rows re-tiered" in Settings.
    @discardableResult
    public func runOnce() async -> Int {
        let candidates: [(id: UUID, value: String, kind: String)]
        do {
            let rows = try await database.query("""
            SELECT id, value, kind FROM entities
            WHERE quality_tier = 'T2'
            ORDER BY ROWID
            LIMIT ?;
            """, [.integer(Int64(batchSize))])
            candidates = rows.compactMap { r -> (UUID, String, String)? in
                guard let id = r.uuid(0),
                      let value = r.string(1),
                      let kind = r.string(2) else { return nil }
                return (id, value, kind)
            }
        } catch {
            AtlasLog.knowledge.error("QualityTierBackfiller: query failed — \(String(describing: error), privacy: .public)")
            return 0
        }
        guard !candidates.isEmpty else { return 0 }

        var changed = 0
        for (id, value, kindRaw) in candidates {
            let kind = Entity.Kind(rawValue: kindRaw) ?? .other
            // We don't know the original source (header vs NER) on a
            // backfilled row. Run the SHAPE-only rules: anything T2
            // that the classifier would now flag as T3 gets demoted.
            // Promotions (T2 → T1) are skipped — without the source
            // signal we can't claim header-derived.
            let proposed = QualityTierClassifier.tier(
                value: value,
                kind: kind,
                source: .ner
            )
            guard proposed == .t3 else { continue }
            do {
                try await database.exec(
                    "UPDATE entities SET quality_tier = ? WHERE id = ?;",
                    [.text(proposed.rawValue), .uuid(id)]
                )
                changed += 1
            } catch {
                AtlasLog.knowledge.error("QualityTierBackfiller: update failed for \(id.uuidString.prefix(8), privacy: .public) — \(String(describing: error), privacy: .public)")
            }
        }
        if changed > 0 {
            AtlasLog.knowledge.info("QualityTierBackfiller: re-tiered \(changed, privacy: .public) of \(candidates.count, privacy: .public) entities to T3")
        }
        return changed
    }
}
