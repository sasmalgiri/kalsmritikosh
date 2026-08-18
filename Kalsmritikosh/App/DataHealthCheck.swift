//
//  DataHealthCheck.swift
//  Kalsmritikosh
//
//  Audits the LIVE database (not an isolated copy) and writes a
//  health report listing what's actually ingested + which layers
//  look incomplete. Designed to surface problems that only show up
//  at scale — files with no KO rows, KOs with no chunks, entities
//  with no mentions, fact_type still NULL on most rows, etc.
//
//  Pure read-only: never writes back to any table. Safe to run any
//  time on production data.
//

import Foundation
import OSLog

public enum DataHealthCheck {

    public struct Result: Sendable {
        public let reportURL: URL
        public let summary: String
        public let issuesFound: Int
    }

    @MainActor
    public static func run(_ state: AppState) async throws -> Result {
        guard let database = state.database else {
            throw NSError(
                domain: "DataHealthCheck",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "AppState.database not booted."]
            )
        }
        let started = Date()

        // ── Top-level counts ─────────────────────────────────────────
        let fileCount = (try? await state.files?.count()) ?? 0
        let koCount = (try? await state.objects?.count()) ?? 0
        let entityCount = await scalarCount(database, "SELECT COUNT(*) FROM entities;")
        let mentionCount = await scalarCount(database, "SELECT COUNT(*) FROM entity_mentions;")
        let eventCount = (try? await state.events?.count()) ?? 0
        let chunkCount = await scalarCount(database, "SELECT COUNT(*) FROM chunks;")
        // v54 — vectors now live in chunk_embeddings (model-aware); count
        // distinct embedded chunks so the metric keeps meaning "chunks embedded".
        let vectorCount = await scalarCount(database, "SELECT COUNT(DISTINCT chunk_id) FROM chunk_embeddings;")
        let relationshipCount = (try? await state.relationships?.count()) ?? 0
        let bondCount = (try? await state.factBonds?.count()) ?? 0
        let memoryCount = (try? await state.memoryRepo?.count()) ?? 0
        let summaryCount = await scalarCount(database, "SELECT COUNT(*) FROM summaries;")
        let synthQCount = await scalarCount(database, "SELECT COUNT(*) FROM synthetic_questions;")
        let qaPairCount = await scalarCount(database, "SELECT COUNT(*) FROM qa_pairs;")
        let aliasCount = await scalarCount(database, "SELECT COUNT(*) FROM entity_aliases;")

        // ── File coverage ────────────────────────────────────────────
        let filesNoKO = await scalarCount(database, """
        SELECT COUNT(*) FROM files f
        WHERE f.alias_of IS NULL
          AND NOT EXISTS (SELECT 1 FROM knowledge_objects k WHERE k.file_id = f.id);
        """)
        let aliasFiles = await scalarCount(database, "SELECT COUNT(*) FROM files WHERE alias_of IS NOT NULL;")
        let availabilityRows = (try? await database.query("""
        SELECT availability, COUNT(*) FROM files GROUP BY availability;
        """)) ?? []
        var availabilityBreakdown: [(String, Int)] = []
        for row in availabilityRows {
            if let label = row.string(0) {
                availabilityBreakdown.append((label, Int(row.int(1) ?? 0)))
            }
        }

        // ── KO health (incomplete extractions) ───────────────────────
        let koNoChunks = await scalarCount(database, """
        SELECT COUNT(*) FROM knowledge_objects k
        WHERE NOT EXISTS (SELECT 1 FROM chunks c WHERE c.object_id = k.id);
        """)
        let koNoVectors = await scalarCount(database, """
        SELECT COUNT(*) FROM knowledge_objects k
        WHERE NOT EXISTS (
          SELECT 1 FROM chunks c JOIN chunk_embeddings v ON v.chunk_id = c.id
          WHERE c.object_id = k.id
        );
        """)
        let koNoEntities = await scalarCount(database, """
        SELECT COUNT(*) FROM knowledge_objects k
        WHERE NOT EXISTS (SELECT 1 FROM entity_mentions m WHERE m.source_object_id = k.id);
        """)
        let koNoEvents = await scalarCount(database, """
        SELECT COUNT(*) FROM knowledge_objects k
        WHERE NOT EXISTS (SELECT 1 FROM events e WHERE e.source_object_id = k.id);
        """)
        let koNoSynthQ = await scalarCount(database, """
        SELECT COUNT(*) FROM knowledge_objects k
        WHERE NOT EXISTS (SELECT 1 FROM synthetic_questions q WHERE q.object_id = k.id);
        """)

        // ── Source-type distribution ─────────────────────────────────
        let sourceTypeRows = (try? await database.query("""
        SELECT source_type, COUNT(*) FROM knowledge_objects
        GROUP BY source_type ORDER BY COUNT(*) DESC;
        """)) ?? []
        var sourceTypeDist: [(String, Int)] = []
        for row in sourceTypeRows {
            if let t = row.string(0) {
                sourceTypeDist.append((t, Int(row.int(1) ?? 0)))
            }
        }

        // ── G3 ontology coverage ─────────────────────────────────────
        // Exclude the `_unclassified` sentinel that OntologyBackfill
        // writes for rows whose entity.kind / event.kind isn't a
        // recognised FactType (date, monetaryAmount, location, …).
        // Those rows ARE processed; they just have no FactType in v1.
        let entityTyped = await scalarCount(database, "SELECT COUNT(*) FROM entities WHERE fact_type IS NOT NULL AND fact_type != '_unclassified';")
        let eventTyped = await scalarCount(database, "SELECT COUNT(*) FROM events WHERE fact_type IS NOT NULL AND fact_type != '_unclassified';")
        let entityCountsByType = (try? await state.entities?.countsByFactType()) ?? [:]
        let eventCountsByType = (try? await state.events?.countsByFactType()) ?? [:]
        let entitySlotPop = await scalarCount(database, """
        SELECT COUNT(*) FROM entities WHERE slot_values_json IS NOT NULL AND slot_values_json != '{}' AND slot_values_json != '';
        """)
        let eventSlotPop = await scalarCount(database, """
        SELECT COUNT(*) FROM events WHERE slot_values_json IS NOT NULL AND slot_values_json != '{}' AND slot_values_json != '';
        """)
        let bondsByName = (try? await database.query("""
        SELECT bond_name, COUNT(*) FROM fact_bonds GROUP BY bond_name ORDER BY COUNT(*) DESC;
        """)) ?? []
        var bondNameDist: [(String, Int)] = []
        for row in bondsByName {
            if let name = row.string(0) {
                bondNameDist.append((name, Int(row.int(1) ?? 0)))
            }
        }

        // ── In-memory cache stats ────────────────────────────────────
        // Each cache exposes isWarm() so we can tell whether the boot
        // task finished warming it. count()/stats() give the loaded
        // payload sizes — if these are 0 while the underlying table
        // is non-empty, the warm-up regressed.
        let bondCacheWarm = (await state.bondGraphCache?.isWarm()) ?? false
        let bondCacheCount = (await state.bondGraphCache?.count()) ?? 0
        let memoryCacheWarm = (await state.memoryCache?.isWarm()) ?? false
        let memoryCacheCount = (await state.memoryCache?.count()) ?? 0
        let timelineWarm = (await state.entityTimeline?.isWarm()) ?? false
        let timelineEvents = (await state.entityTimeline?.count()) ?? 0
        let timelineBuckets = (await state.entityTimeline?.entityCount()) ?? 0
        let trieWarm = (await state.entityTrie?.isWarm()) ?? false
        let trieStats = await state.entityTrie?.stats()
        let hnswBuilt = (await state.hnswIndex?.isBuilt()) ?? false
        let hnswSize = (await state.hnswIndex?.size()) ?? 0

        // Structured-output provider audit — which providers declare
        // the .structuredOutput capability so we know the typed
        // @Generable expert path will fire when the registry picks
        // them.
        let structuredOutputProviders: [String] = await {
            guard let registry = state.capabilities else { return [] }
            let all = await registry.allProviders()
            var ids: [String] = []
            for provider in all where provider.capabilities.contains(.structuredOutput) {
                ids.append(provider.id)
            }
            return ids.sorted()
        }()

        // P9.3 (GOV-005) — disk-ANN parity tripwire: when a model's persisted
        // strategy is diskIVF and its index claims ready, every stored
        // embedding must have a posting. A mismatch means the reconcile pass
        // is behind (the maintenance job repairs it) — surfacing it here
        // makes a silent-degradation regression impossible to miss.
        var annParityIssues: [String] = []
        if let metaRows = try? await database.query(
            "SELECT model_id, strategy, state FROM ann_index_meta;", []) {
            for row in metaRows {
                guard let modelID = row.string(0), row.string(1) == "diskIVF", row.string(2) == "ready"
                else { continue }
                let embeddings = Int((try? await database.query(
                    "SELECT COUNT(*) FROM chunk_embeddings WHERE model_id = ?;",
                    [.text(modelID)]))?.first?.int(0) ?? 0)
                let postings = Int((try? await database.query(
                    "SELECT COUNT(*) FROM ann_postings WHERE model_id = ?;",
                    [.text(modelID)]))?.first?.int(0) ?? 0)
                if postings != embeddings {
                    annParityIssues.append("ANN postings/embeddings parity broken for \(modelID): \(postings) postings vs \(embeddings) embeddings — the ann.strategy.maintenance reconcile will repair; if it persists, the maintenance job is not running")
                }
            }
        }

        // ── Identify issues ──────────────────────────────────────────
        var issues: [String] = []
        issues.append(contentsOf: annParityIssues)
        if fileCount > 0, filesNoKO > 0 {
            let pct = Double(filesNoKO) / Double(fileCount) * 100
            issues.append("\(filesNoKO) of \(fileCount) files have NO KnowledgeObject row (\(String(format: "%.1f", pct))%) — loader failure or unsupported type")
        }
        if koCount > 0 {
            if koNoChunks > 0 {
                issues.append("\(koNoChunks) of \(koCount) KOs have NO chunks — chunker regression or empty content")
            }
            if koNoVectors > 0 {
                let pct = Double(koNoVectors) / Double(koCount) * 100
                issues.append("\(koNoVectors) of \(koCount) KOs have NO vector embeddings (\(String(format: "%.1f", pct))%) — embedder skipped or failed")
            }
            if koNoEntities > 0 {
                let pct = Double(koNoEntities) / Double(koCount) * 100
                issues.append("\(koNoEntities) of \(koCount) KOs have NO entity mentions (\(String(format: "%.1f", pct))%) — entity extractor returned empty")
            }
            if koNoSynthQ > 0 {
                let pct = Double(koNoSynthQ) / Double(koCount) * 100
                if pct > 30 {
                    issues.append("\(koNoSynthQ) of \(koCount) KOs lack synthetic questions (\(String(format: "%.1f", pct))%) — retrieval question-shape matching is degraded")
                }
            }
        }
        if entityCount > 0 {
            let typedPct = Double(entityTyped) / Double(entityCount) * 100
            if typedPct < 90 {
                issues.append("Only \(entityTyped) of \(entityCount) entities have fact_type set (\(String(format: "%.1f", typedPct))%) — OntologyBackfill incomplete; run Rebuild Typed Bonds or restart the app to retrigger the backfill")
            }
        }
        if eventCount > 0 {
            let typedPct = Double(eventTyped) / Double(eventCount) * 100
            if typedPct < 90 {
                issues.append("Only \(eventTyped) of \(eventCount) events have fact_type set (\(String(format: "%.1f", typedPct))%) — OntologyBackfill incomplete")
            }
        }
        if koCount > 0 && bondCount == 0 {
            issues.append("fact_bonds is EMPTY despite \(koCount) KOs ingested — click 'Rebuild Typed Bonds' to populate the typed graph for the existing corpus")
        }
        // Cache health: if SQLite has rows but the in-memory cache
        // is empty AND warmed, the warm path regressed.
        if bondCount > 0 && bondCacheWarm && bondCacheCount == 0 {
            issues.append("InMemoryBondGraph is warmed but EMPTY despite \(bondCount) fact_bonds rows — warm-up regression")
        }
        if memoryCount > 0 && memoryCacheWarm && memoryCacheCount == 0 {
            issues.append("MemoryHashCache is warmed but EMPTY despite \(memoryCount) memory_objects rows — warm-up regression")
        }
        if eventCount > 0 && timelineWarm && timelineEvents == 0 {
            issues.append("EntityTimeline is warmed but EMPTY despite \(eventCount) events rows — warm-up regression")
        }
        if entityCount > 0 && trieWarm && (trieStats?.entitiesLoaded ?? 0) == 0 {
            issues.append("EntityTrie is warmed but EMPTY despite \(entityCount) entities — warm-up regression")
        }
        if vectorCount > 0 && hnswBuilt && hnswSize == 0 {
            issues.append("HNSWVectorIndex is built but EMPTY despite \(vectorCount) vectors rows — build regression")
        }
        if vectorCount > 5_000 && !hnswBuilt {
            issues.append("HNSWVectorIndex is NOT built despite \(vectorCount) vectors — every vector query is brute-forcing the whole table. Restart the app or wait for the boot warm task to complete.")
        }
        if structuredOutputProviders.isEmpty {
            issues.append("No provider declares .structuredOutput capability — the @Generable typed-output path (item #7) will never fire; experts will prompt-parse instead")
        }

        // ── Render report ────────────────────────────────────────────
        var md = "# Kalsmritikosh — Data Health Report\n\n"
        md += "Generated: \(Date().formatted(date: .abbreviated, time: .standard))\n"
        md += "Database: `\(database.url.path)`\n"
        md += "Audit runtime: \(String(format: "%.1f", Date().timeIntervalSince(started)))s\n\n"

        md += "## Overview\n\n"
        md += "| Layer | Rows |\n|---|---:|\n"
        md += "| files | \(fileCount) |\n"
        md += "| knowledge_objects | \(koCount) |\n"
        md += "| chunks | \(chunkCount) |\n"
        md += "| vectors | \(vectorCount) |\n"
        md += "| entities (canonical) | \(entityCount) |\n"
        md += "| entity_mentions | \(mentionCount) |\n"
        md += "| entity_aliases | \(aliasCount) |\n"
        md += "| events | \(eventCount) |\n"
        md += "| relationships (T3 graph) | \(relationshipCount) |\n"
        md += "| **fact_bonds (G3 graph)** | **\(bondCount)** |\n"
        md += "| memory_objects | \(memoryCount) |\n"
        md += "| summaries | \(summaryCount) |\n"
        md += "| synthetic_questions | \(synthQCount) |\n"
        md += "| qa_pairs | \(qaPairCount) |\n\n"

        md += "## File coverage\n\n"
        md += "- Files registered: \(fileCount)\n"
        md += "- Files with no KO row: \(filesNoKO)\n"
        md += "- Alias files (T7 dedup): \(aliasFiles)\n"
        if !availabilityBreakdown.isEmpty {
            md += "- Availability:\n"
            for (label, count) in availabilityBreakdown {
                md += "  - \(label): \(count)\n"
            }
        }
        md += "\n"

        md += "## KO health\n\n"
        md += "| Check | Count |\n|---|---:|\n"
        md += "| KOs without chunks | \(koNoChunks) |\n"
        md += "| KOs without vectors | \(koNoVectors) |\n"
        md += "| KOs without entity mentions | \(koNoEntities) |\n"
        md += "| KOs without events | \(koNoEvents) |\n"
        md += "| KOs without synthetic questions | \(koNoSynthQ) |\n\n"

        md += "## Source-type distribution\n\n"
        if sourceTypeDist.isEmpty {
            md += "_(no KOs)_\n\n"
        } else {
            md += "| source_type | KOs |\n|---|---:|\n"
            for (t, count) in sourceTypeDist {
                md += "| \(t) | \(count) |\n"
            }
            md += "\n"
        }

        md += "## G3 ontology coverage\n\n"
        let entityTypedPct = entityCount > 0
            ? String(format: " (%.1f%%)", Double(entityTyped) / Double(entityCount) * 100)
            : ""
        let eventTypedPct = eventCount > 0
            ? String(format: " (%.1f%%)", Double(eventTyped) / Double(eventCount) * 100)
            : ""
        md += "- Entities classified: \(entityTyped) / \(entityCount)\(entityTypedPct)\n"
        md += "- Events classified: \(eventTyped) / \(eventCount)\(eventTypedPct)\n"
        md += "- Entity slot_values populated: \(entitySlotPop)\n"
        md += "- Event slot_values populated: \(eventSlotPop)\n\n"

        if !entityCountsByType.isEmpty {
            md += "**Entity fact_type breakdown:**\n\n"
            md += "| fact_type | count |\n|---|---:|\n"
            for (k, v) in entityCountsByType.sorted(by: { $0.value > $1.value }) {
                md += "| \(k) | \(v) |\n"
            }
            md += "\n"
        }
        if !eventCountsByType.isEmpty {
            md += "**Event fact_type breakdown:**\n\n"
            md += "| fact_type | count |\n|---|---:|\n"
            for (k, v) in eventCountsByType.sorted(by: { $0.value > $1.value }) {
                md += "| \(k) | \(v) |\n"
            }
            md += "\n"
        }
        if !bondNameDist.isEmpty {
            md += "**fact_bonds by name:**\n\n"
            md += "| bond_name | count |\n|---|---:|\n"
            for (name, count) in bondNameDist {
                md += "| \(name) | \(count) |\n"
            }
            md += "\n"
        }

        md += "## In-memory caches\n\n"
        md += "| Cache | Warm? | Loaded |\n|---|---|---:|\n"
        md += "| InMemoryBondGraph | \(bondCacheWarm ? "✓" : "—") | \(bondCacheCount) bonds |\n"
        md += "| MemoryHashCache | \(memoryCacheWarm ? "✓" : "—") | \(memoryCacheCount) memories |\n"
        md += "| EntityTimeline | \(timelineWarm ? "✓" : "—") | \(timelineEvents) events across \(timelineBuckets) entities |\n"
        if let trieStats {
            md += "| EntityTrie | \(trieWarm ? "✓" : "—") | \(trieStats.entitiesLoaded) entities, \(trieStats.trieNodes) trie nodes |\n"
        } else {
            md += "| EntityTrie | \(trieWarm ? "✓" : "—") | (no stats) |\n"
        }
        md += "| HNSWVectorIndex | \(hnswBuilt ? "✓" : "—") | \(hnswSize) vectors |\n"
        md += "\nA cache that hasn't warmed yet is normal during the first few seconds after boot — the OntologyBackfill detached task warms all five in parallel. Re-run this audit after ~5s if any row shows `—`.\n\n"

        md += "## Structured-output providers (item #7)\n\n"
        if structuredOutputProviders.isEmpty {
            md += "_(none declared)_\n\n"
        } else {
            md += "These providers can return typed `@Generable` claims directly — experts call respondClaims(...) and skip the prompt-parser:\n\n"
            for id in structuredOutputProviders {
                md += "- `\(id)`\n"
            }
            md += "\n"
        }

        md += "## Issues found (\(issues.count))\n\n"
        if issues.isEmpty {
            md += "✓ No data-health issues detected.\n"
        } else {
            for issue in issues { md += "- ⚠️ \(issue)\n" }
        }
        md += "\n"

        if !issues.isEmpty {
            md += "## Recommended actions\n\n"
            if bondCount == 0 && koCount > 0 {
                md += "1. **Rebuild Typed Bonds** — populate fact_bonds for the corpus already ingested.\n"
            }
            if entityCount > 0 && Double(entityTyped) / Double(entityCount) < 0.9 {
                md += "1. Restart the app — OntologyBackfill runs at boot; let it complete before running diagnostics.\n"
            }
            if filesNoKO > 0 || koNoChunks > 0 || koNoVectors > 0 {
                md += "1. Inspect ingestion logs (`log show --subsystem ecosanskritiinnovation.Kalsmritikosh`) for loader / chunker / embedder errors on the offending files.\n"
            }
            md += "\n"
        }

        // ── Write to disk ────────────────────────────────────────────
        let documentsDir = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let reportDir = documentsDir.appendingPathComponent("EvalBaselines", isDirectory: true)
        try? FileManager.default.createDirectory(at: reportDir, withIntermediateDirectories: true)
        let url = reportDir.appendingPathComponent("data-health-report.md", isDirectory: false)
        try md.data(using: .utf8)?.write(to: url, options: .atomic)

        let summary = """
        Files: \(fileCount) · KOs: \(koCount) · Entities: \(entityCount) · Events: \(eventCount)
        Bonds: \(bondCount) · Memory: \(memoryCount) · Vectors: \(vectorCount)
        fact_type: entities \(entityTyped)/\(entityCount), events \(eventTyped)/\(eventCount)
        Issues found: \(issues.count)
        """
        KalsmritikoshLog.app.info("DataHealthCheck complete → \(url.path, privacy: .private) (\(issues.count, privacy: .public) issues)")
        return Result(reportURL: url, summary: summary, issuesFound: issues.count)
    }

    // MARK: - Helpers

    private static func scalarCount(_ db: Database, _ sql: String) async -> Int {
        guard let rows = try? await db.query(sql) else { return 0 }
        return Int(rows.first?.int(0) ?? 0)
    }
}
