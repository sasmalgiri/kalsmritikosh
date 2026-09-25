//
//  HealthReportBuilder.swift
//  Kalsmritikosh
//
//  U-3.3 wiring — gathers a HealthReport from LIVE state for the dashboard
//  panel. HONEST BY CONSTRUCTION: it emits only the invariants it actually
//  measures (causal budget, embedding consistency, context-prefix backfill)
//  rather than defaulting unmeasured checks to "pass". Coverage rows come
//  from the live sample. As more invariants get cheap live queries they
//  join the emitted set.
//
//  VACUOUS PASSES REMOVED. Each of these checks used to go GREEN on an empty
//  ledger: no causal links means `MAX(...)` is 0 which is "within budget",
//  no chunks means the embedding states trivially sum, and no queued work
//  means the backfill is "done". So a fresh install — or the state right
//  after an erase — reported "All checks passing" having verified nothing,
//  which is the one thing a self-check panel must never say. A check with
//  nothing to measure is now reported as NOT MEASURED, and the panel's
//  overall status is notMeasured rather than green when that is all there is.
//

import Foundation

@MainActor
public enum HealthReportBuilder {

    public static func build(appState: AppState) async -> HealthReport {
        var invariants: [HealthInvariant] = []
        var coverage: [HealthCoverageRow] = []

        // Coverage rows — straight from the live sample.
        //
        // STALENESS IS THE HAZARD HERE, not the arithmetic. This builder runs
        // ONCE from a `.task` at view-appear, while the metrics poller starts
        // in `.onAppear` — a race this builder always loses on first paint. It
        // then captures whatever `current` holds (nothing, or a pre-ingest
        // zero) and the panel keeps showing it while the cards above refresh
        // every tick. Measured on the owner's machine: cards "Chunks 9,611"
        // beside "chunks: 0" here, with no indication the panel was old.
        //
        // The caller now rebuilds this when the sample changes, and the report
        // carries the sample's own capture time so the UI can say how old it
        // is. `sampleCapturedAt == nil` means the rows below are ABSENT rather
        // than zero.
        var sampledAt: Date?
        if let s = appState.liveMetrics?.current {
            sampledAt = s.capturedAt
            let cov = s.embeddingCoverage
            coverage.append(HealthCoverageRow(id: "embedding", title: "Embedding",
                states: [("embedded", cov.embedded), ("pending", cov.pending),
                         ("excluded", cov.excluded), ("failed", cov.failed)]))
            coverage.append(HealthCoverageRow(id: "ledger", title: "Ledger",
                states: [("documents", s.objectCount), ("chunks", s.chunkCount),
                         ("entities", s.entityCount), ("events", s.eventCount)]))
            coverage.append(HealthCoverageRow(id: "graph", title: "Graph & memory",
                states: [("causal links", s.causalLinkCount), ("memories", s.memoryCount),
                         ("summaries", s.summaryCount)]))

            invariants.append(HealthReport.embeddingInvariant(cov))
        }

        // Invariant: grounded causal links per event ≤ budget (3). Measures
        // the max fan-out among answer-reaching link kinds.
        if let db = appState.database {
            // SUM as well as MAX: without it, "no grounded links at all" and
            // "the busiest event has zero" are indistinguishable, and the
            // former was passing as though it had been checked.
            let sql = """
            SELECT COALESCE(MAX(c), 0), COALESCE(SUM(c), 0) FROM (
              SELECT COUNT(*) AS c FROM event_links
              WHERE superseded_by IS NULL
                AND source IN ('lexicalTrigger','user','ontology','llm')
              GROUP BY source_event_id
            );
            """
            if let rows = try? await db.query(sql, []) {
                let maxPerEvent = Int(rows.first?.int(0) ?? 0)
                let totalLinks = Int(rows.first?.int(1) ?? 0)
                invariants.append(HealthReport.causalBudgetInvariant(
                    maxPerEvent: maxPerEvent, totalLinks: totalLinks))
            }
        }

        // Invariant: context-prefix backfill drained (the one backfiller
        // AppState exposes publicly). Amber while it still has work.
        if let ctx = appState.contextPrefixBackfiller {
            let pending = await ctx.pendingCount()
            // "Drained" only means something once there was something to drain.
            let hasChunks = (appState.liveMetrics?.current.chunkCount ?? 0) > 0
            invariants.append(HealthReport.backfillInvariant(
                id: "backfill-context-prefix", title: "Context-prefix backfill drained",
                pending: pending, hasWork: hasChunks))
        }

        return HealthReport(coverage: coverage, invariants: invariants,
                            sampleCapturedAt: sampledAt)
    }
}
