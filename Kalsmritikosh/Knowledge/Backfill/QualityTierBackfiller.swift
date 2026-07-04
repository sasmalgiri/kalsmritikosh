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
                let ns = UInt64(self.intervalSeconds * 1_000_000_000)
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

        // Build the structured-header allow-list ONCE per pass: any
        // entity value that appears in a KO's `t13_structuredEntities`
        // metadata is, by construction, header-derived. The audit on
        // 2026-06-28 surfaced 8972 entities with ZERO T1 because the
        // structured-header tagging code shipped AFTER the user's
        // archive was already ingested. Without this promotion pass,
        // T1 stays empty forever even though the source signal lives
        // intact in the KO metadata.
        let headerValues = await loadStructuredHeaderValues()

        var demoted = 0
        var promoted = 0
        for (id, value, kindRaw) in candidates {
            let kind = Entity.Kind(rawValue: kindRaw) ?? .other
            let normalized = value.lowercased()
            // T2 → T1 promotion: header-derived values get the upgrade
            // they would have received at ingest time.
            if headerValues.contains(normalized) {
                do {
                    try await database.exec(
                        "UPDATE entities SET quality_tier = 'T1' WHERE id = ?;",
                        [.uuid(id)]
                    )
                    promoted += 1
                    continue
                } catch {
                    AtlasLog.knowledge.error("QualityTierBackfiller: promote failed for \(id.uuidString.prefix(8), privacy: .public) — \(String(describing: error), privacy: .public)")
                }
            }
            // T2 → T3 demotion: shape-only rules; anything the classifier
            // would flag as T3 today gets demoted.
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
                demoted += 1
            } catch {
                AtlasLog.knowledge.error("QualityTierBackfiller: update failed for \(id.uuidString.prefix(8), privacy: .public) — \(String(describing: error), privacy: .public)")
            }
        }
        if promoted > 0 || demoted > 0 {
            AtlasLog.knowledge.info("QualityTierBackfiller: promoted \(promoted, privacy: .public) T2→T1, demoted \(demoted, privacy: .public) T2→T3 of \(candidates.count, privacy: .public) candidates")
        }
        return promoted + demoted
    }

    /// Scan the `t13_structuredEntities` metadata column on every KO
    /// and collect the lowercased VALUES of the structured entities.
    /// Returns a flat set so the per-entity check is O(1).
    ///
    /// Cost: one paged scan over knowledge_objects per pass. Bounded
    /// to mbox / eml / appleMail rows because only those carry
    /// structured headers — there's no point scanning every PDF /
    /// spreadsheet for keys that aren't there.
    private func loadStructuredHeaderValues() async -> Set<String> {
        var out: Set<String> = []
        do {
            let rows = try await database.query("""
            SELECT metadata_json FROM knowledge_objects
            WHERE source_type IN ('mbox','eml','appleMail')
              AND metadata_json LIKE '%t13_structuredEntities%';
            """, [])
            for row in rows {
                guard let json = row.string(0),
                      let data = json.data(using: .utf8),
                      let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let raw = meta["t13_structuredEntities"] as? String,
                      let entitiesData = raw.data(using: .utf8),
                      let entities = try? JSONSerialization.jsonObject(with: entitiesData) as? [[String: Any]]
                else { continue }
                for entity in entities {
                    if let value = entity["value"] as? String {
                        out.insert(value.lowercased())
                    }
                    if let normalized = entity["normalizedValue"] as? String {
                        out.insert(normalized.lowercased())
                    }
                }
            }
        } catch {
            AtlasLog.knowledge.error("QualityTierBackfiller: header scan failed — \(String(describing: error), privacy: .public)")
        }
        AtlasLog.knowledge.info("QualityTierBackfiller: collected \(out.count, privacy: .public) structured-header values for promotion")
        return out
    }
}
