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

import Foundation

@MainActor
public enum HealthReportBuilder {

    public static func build(appState: AppState) async -> HealthReport {
        var invariants: [HealthInvariant] = []
        var coverage: [HealthCoverageRow] = []

        // Coverage rows — straight from the live sample.
        if let s = appState.liveMetrics?.current {
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

            // Invariant: embedding states sum to the chunk total.
            invariants.append(HealthInvariant(
                id: "embedding-consistent", title: "Embedding states sum to total",
                status: cov.isConsistent ? .pass : .fail,
                detail: cov.isConsistent ? "consistent" : "counts do not sum to the chunk total"))
        }

        // Invariant: grounded causal links per event ≤ budget (3). Measures
        // the max fan-out among answer-reaching link kinds.
        if let db = appState.database {
            let sql = """
            SELECT COALESCE(MAX(c), 0) FROM (
              SELECT COUNT(*) AS c FROM event_links
              WHERE superseded_by IS NULL
                AND source IN ('lexicalTrigger','user','ontology','llm')
              GROUP BY source_event_id
            );
            """
            if let rows = try? await db.query(sql, []) {
                let maxPerEvent = Int(rows.first?.int(0) ?? 0)
                invariants.append(HealthInvariant(
                    id: "causal-budget", title: "Causal links within budget",
                    status: maxPerEvent <= 3 ? .pass : .fail,
                    detail: "max \(maxPerEvent) grounded links on one event (budget 3)"))
            }
        }

        // Invariant: context-prefix backfill drained (the one backfiller
        // AppState exposes publicly). Amber while it still has work.
        if let ctx = appState.contextPrefixBackfiller {
            let pending = await ctx.pendingCount()
            invariants.append(HealthInvariant(
                id: "backfill-context-prefix", title: "Context-prefix backfill drained",
                status: pending == 0 ? .pass : .warn,
                detail: pending == 0 ? "done" : "\(pending) chunk(s) pending"))
        }

        return HealthReport(coverage: coverage, invariants: invariants)
    }
}
