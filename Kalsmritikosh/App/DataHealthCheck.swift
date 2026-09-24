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
//  A FAILED PROBE IS NOT A CLEAN RESULT. Every detector below has the shape
//  "if count > 0 then report an issue", and `scalarCount` used to return 0
//  when its query THREW — so a probe broken by schema drift reported no
//  problem. Worse, several counts gate whole sections (`if koCount > 0 { … }`),
//  so one failed query silently switched those checks off while the report
//  still said "Issues found (0)". In an audit whose entire purpose is finding
//  problems, that is the worst failure mode available: quietest exactly when
//  it is most broken.
//
//  Probes now record FAILURE distinctly from zero. A probe that could not run
//  is listed as its own issue, counted in `issuesFound`, and named in the
//  report under "Checks that could not run". The arithmetic is unchanged — a
//  failed probe still contributes 0 — but it can no longer pass as a result.
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

        // Probes that did not run. Collected so the report says so out loud
        // instead of showing their absence as a zero.
        var failedProbes: [String] = []

        /// A counting probe. Returns 0 on failure so the arithmetic below is
        /// untouched, but RECORDS the failure so it cannot read as a result.
        func count(_ label: String, _ sql: String) async -> Int {
            guard let value = await Self.scalarCount(database, sql) else {
                failedProbes.append(label)
                return 0
            }
            return value
        }
        /// A repository count. A nil repository (not booted) and a throwing
        /// `count()` are both "not measured", never "zero rows".
        func repoCount(_ label: String, _ body: () async throws -> Int?) async -> Int {
            do {
                guard let value = try await body() else {
                    failedProbes.append("\(label) — repository not booted")
                    return 0
                }
                return value
            } catch {
                failedProbes.append("\(label) — \(error)")
                return 0
            }
        }

        // ── Top-level counts ─────────────────────────────────────────
        let fileCount = await repoCount("file count") { try await state.files?.count() }
        let koCount = await repoCount("knowledge-object count") { try await state.objects?.count() }
        let entityCount = await count("entity count", "SELECT COUNT(*) FROM entities;")
        let mentionCount = await count("mention count", "SELECT COUNT(*) FROM entity_mentions;")
        let eventCount = await repoCount("event count") { try await state.events?.count() }
        let chunkCount = await count("chunk count", "SELECT COUNT(*) FROM chunks;")
        // v54 — vectors now live in chunk_embeddings (model-aware); count
        // distinct embedded chunks so the metric keeps meaning "chunks embedded".
        let vectorCount = await count("vector count", "SELECT COUNT(DISTINCT chunk_id) FROM chunk_embeddings;")
        let relationshipCount = await repoCount("relationship count") { try await state.relationships?.count() }
        let bondCount = await repoCount("fact-bond count") { try await state.factBonds?.count() }
        let memoryCount = await repoCount("memory-object count") { try await state.memoryRepo?.count() }
        let summaryCount = await count("summary count", "SELECT COUNT(*) FROM summaries;")
        let synthQCount = await count("synth q count", "SELECT COUNT(*) FROM synthetic_questions;")
        let qaPairCount = await count("qa pair count", "SELECT COUNT(*) FROM qa_pairs;")
        let aliasCount = await count("alias count", "SELECT COUNT(*) FROM entity_aliases;")

        // ── File coverage ────────────────────────────────────────────
        let filesNoKO = await count("files no k o", """
        SELECT COUNT(*) FROM files f
        WHERE f.alias_of IS NULL
          AND NOT EXISTS (SELECT 1 FROM knowledge_objects k WHERE k.file_id = f.id);
        """)
        let aliasFiles = await count("alias files", "SELECT COUNT(*) FROM files WHERE alias_of IS NOT NULL;")
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
        let koNoChunks = await count("ko no chunks", """
        SELECT COUNT(*) FROM knowledge_objects k
        WHERE NOT EXISTS (SELECT 1 FROM chunks c WHERE c.object_id = k.id);
        """)
        let koNoVectors = await count("ko no vectors", """
        SELECT COUNT(*) FROM knowledge_objects k
        WHERE NOT EXISTS (
          SELECT 1 FROM chunks c JOIN chunk_embeddings v ON v.chunk_id = c.id
          WHERE c.object_id = k.id
        );
        """)
        let koNoEntities = await count("ko no entities", """
        SELECT COUNT(*) FROM knowledge_objects k
        WHERE NOT EXISTS (SELECT 1 FROM entity_mentions m WHERE m.source_object_id = k.id);
        """)
        let koNoEvents = await count("ko no events", """
        SELECT COUNT(*) FROM knowledge_objects k
        WHERE NOT EXISTS (SELECT 1 FROM events e WHERE e.source_object_id = k.id);
        """)
        let koNoSynthQ = await count("ko no synth q", """
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
        // P3.2 — a DERIVED type counts as typed. `derived:` ids come from
        // documents outside the curated enum (a vehicle service record, a
        // shipping manifest) and name themselves after their own field
        // signature. Excluding them would make the health panel go RED for the
        // product working exactly as intended on a universal archive, which is
        // the absence-as-defect mirror of the absence-as-verification problem.
        let entityTyped = await count("entity typed", "SELECT COUNT(*) FROM entities WHERE fact_type IS NOT NULL AND fact_type != '_unclassified';")
        let eventTyped = await count("event typed", "SELECT COUNT(*) FROM events WHERE fact_type IS NOT NULL AND fact_type != '_unclassified';")
        // Reported SEPARATELY, because "grouped by its own fields" and
        // "recognised as a contract" are different degrees of knowledge and a
        // single number would hide which one the archive actually has.
        let entityDerivedTyped = await count("entity derived-typed",
            "SELECT COUNT(*) FROM entities WHERE fact_type LIKE 'derived:%';")
        let eventDerivedTyped = await count("event derived-typed",
            "SELECT COUNT(*) FROM events WHERE fact_type LIKE 'derived:%';")
        _ = (entityDerivedTyped, eventDerivedTyped)   // surfaced via the report below
        let entityCountsByType = (try? await state.entities?.countsByFactType()) ?? [:]
        let eventCountsByType = (try? await state.events?.countsByFactType()) ?? [:]
        let entitySlotPop = await count("entity slot pop", """
        SELECT COUNT(*) FROM entities WHERE slot_values_json IS NOT NULL AND slot_values_json != '{}' AND slot_values_json != '';
        """)
        let eventSlotPop = await count("event slot pop", """
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
        // Listed first and counted: a probe that did not run means this report
        // is incomplete, and that outranks anything it did manage to check.
        // Without this the audit was SILENT about its own failures and still
        // printed "Issues found (0)".
        for probe in failedProbes {
            issues.append("CHECK DID NOT RUN — \(probe). Its count reads 0 in this report, "
                        + "which is NOT a measurement: any issue it would have found is "
                        + "invisible here.")
        }
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

        // ── P4.4 — ATTRIBUTION STAMP ────────────────────────────────────────
        //
        // A report with no configuration is unattributable. Two runs over the
        // same archive can legitimately produce different numbers because a
        // module moved, and without this the owner has no way to tell that from
        // a regression — they would be comparing two reports that look
        // comparable and are not. Modules are listed by their EFFECTIVE state
        // (`isEnabled`), not their stored preference, so a module force-disabled
        // by the AI regime reads as off here, which is what it actually is.
        md += "## What produced this report\n\n"
        md += "| | |\n|---|---|\n"
        md += "| build | `\(BuildIdentity.gitSHA)` |\n"
        md += "| schema version | v\(SchemaMigrations.latestVersion) |\n"
        md += "| AI regime | \(FeatureFlags.aiRegimeValue().rawValue) |\n"
        let allModules = KnowledgeModule.allCases.filter(\.implemented)
        let onModules = allModules.filter { KnowledgeModuleFlags.isEnabled($0) }
        md += "| modules on | \(onModules.count) of \(allModules.count) |\n\n"
        let offModules = allModules.filter { !KnowledgeModuleFlags.isEnabled($0) }
        if !offModules.isEmpty {
            md += "**Switched off for this run** — each of these is a capability the "
            md += "numbers below do NOT include, which is the most common reason a "
            md += "count is lower than expected:\n\n"
            for m in offModules.sorted(by: { $0.rawValue < $1.rawValue }) {
                md += "- `\(m.rawValue)` — \(m.title)\(m.requiresAI && !FeatureFlags.aiRegimeValue().allowsAI ? " _(forced off: no model under this AI regime)_" : "")\n"
            }
            md += "\n"
        }

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

        // ══ P4 — THE INGESTION REPORT ═══════════════════════════════════════
        //
        // These sections answer one question the counts above cannot: "is the
        // ingestion PROPER?" A row count says how much arrived. It cannot say
        // whether a document finished deriving, why something is missing, which
        // formats were readable at all, or whether the archive is even in a
        // language this version can extract from. Every one of those absences
        // previously rendered as a smaller number with no explanation.
        //
        // Deliberately placed BEFORE "Issues found" so the explanations are read
        // before the verdict.

        md += "## Did every document finish deriving? (P1.3)\n\n"
        let derivComplete = await count("derivation complete",
            "SELECT COUNT(*) FROM knowledge_objects WHERE derivation_complete = 1;")
        let derivUnknown = await count("derivation unknown",
            "SELECT COUNT(*) FROM knowledge_objects WHERE derivation_complete IS NULL;")
        let derivIncomplete = max(0, koCount - derivComplete - derivUnknown)
        md += "| state | documents | what it means |\n|---|---:|---|\n"
        md += "| finished | \(derivComplete) | every derivation stage returned |\n"
        md += "| UNFINISHED | \(derivIncomplete) | the run was interrupted part-way; these look complete in the counts above but are missing part of their ledger |\n"
        md += "| unknown | \(derivUnknown) | derived before this marker existed (or not yet re-derived). Genuinely unknown — NOT counted as finished |\n\n"
        if derivIncomplete > 0 {
            issues.append("\(derivIncomplete) document(s) did not finish deriving — their entities/events/facts are partial. Re-run ingest to resume them.")
        }
        if derivUnknown > 0 && derivComplete == 0 && koCount > 0 {
            md += "Every document predates the completeness marker, so this section "
            md += "cannot yet confirm anything. It will be meaningful after the next "
            md += "full ingest. That is a limit of the report, not a clean result.\n\n"
        }

        md += "## Why is something missing? (P1.2)\n\n"
        let failureRows = (try? await database.query("""
        SELECT stage, COUNT(*) FROM derivation_failures GROUP BY stage ORDER BY COUNT(*) DESC;
        """)) ?? []
        if failureRows.isEmpty {
            md += "No tolerated derivation failures were recorded.\n\n"
            md += "READ THIS CAREFULLY: it means no failure was RECORDED, which is "
            md += "only the same as \"nothing failed\" if the recorder was switched on "
            md += "for the whole run (module `recordDerivationFailures`, default on). "
            md += "Anything that failed while it was off went to the log, not here.\n\n"
        } else {
            md += "Each row is a step that failed and was tolerated — the document was "
            md += "kept, but this part of its ledger is missing. The REASON is the point: "
            md += "\"couldn't parse\" and \"not in the container\" produce the same empty "
            md += "result and mean opposite things.\n\n"
            md += "| stage | occurrences |\n|---|---:|\n"
            for r in failureRows {
                md += "| `\(r.string(0) ?? "—")` | \(Int(r.int(1) ?? 0)) |\n"
            }
            md += "\n"
            let byType = (try? await database.query("""
            SELECT COALESCE(detected_type, '(unknown)'), COUNT(*) FROM derivation_failures
            GROUP BY detected_type ORDER BY COUNT(*) DESC LIMIT 12;
            """)) ?? []
            if !byType.isEmpty {
                md += "**By format** — the grouping that makes a gap actionable "
                md += "(\"31 .pdf failed to link blocks\" is a defect; \"310 .heic skipped\" is by design):\n\n"
                md += "| format | occurrences |\n|---|---:|\n"
                for r in byType { md += "| \(r.string(0) ?? "—") | \(Int(r.int(1) ?? 0)) |\n" }
                md += "\n"
            }
            issues.append("\(failureRows.reduce(0) { $0 + Int($1.int(1) ?? 0) }) tolerated derivation failure(s) recorded — see the Ingestion Report section for the stages and formats.")
        }

        // ── Format coverage (P3.5) — derived from the registry, configured
        // exactly as this run configures it, so a switched-off parser cannot be
        // advertised.
        if let coverage = UniversalParserRegistryBuilder.coverageReport(
            ocr: VisionOCR(),
            iMessageEnabled: FeatureFlags.shared.iMessageLoaderEnabled,
            browserHistoryEnabled: FeatureFlags.shared.browserHistoryLoaderEnabled,
            chatExportEnabled: FeatureFlags.shared.chatExportLoaderEnabled,
            mediaTranscriptionEnabled: KnowledgeModuleFlags.isEnabled(.mediaTranscription)) {
            md += "## What can each format give you? (P3.5)\n\n"
            md += coverage + "\n\n"
        }

        // ── Language honesty (P3.6)
        if let language = await ExtractionLanguageReport.build(database: database) {
            md += "## What languages is your archive in? (P3.6)\n\n"
            if let limitation = language.limitationStatement() {
                md += limitation + "\n\n"
                issues.append("\(language.unsupportedDocuments) document(s) are not in English; structured extraction is English-only in this version, so they will yield few or no facts.")
            } else {
                md += "Every document is in a language this version can extract from, "
                md += "and every document's language was detected.\n\n"
            }
            if !language.coverage.isEmpty {
                md += "| language | documents | structured extraction |\n|---|---:|---|\n"
                for c in language.coverage.sorted(by: { $0.documentCount > $1.documentCount }).prefix(12) {
                    md += "| \(c.displayName) | \(c.documentCount) | \(c.extractionSupported ? "yes" : "NO — searchable only") |\n"
                }
                md += "\n"
            }
        }

        // ── Schema induction (P3.3)
        let inductionSummary = await InducedSchemaAttemptRepository(database: database).summary()
        if inductionSummary.attempted > 0 || KnowledgeModuleFlags.isEnabled(.inducedSchema) {
            md += "## Documents no built-in reader recognised (P3.3)\n\n"
            if !KnowledgeModuleFlags.isEnabled(.inducedSchema) {
                md += "Schema induction is currently OFF. \(inductionSummary.attempted) "
                md += "document(s) were attempted while it was on.\n\n"
            }
            md += "| outcome | documents |\n|---|---:|\n"
            md += "| attempted | \(inductionSummary.attempted) |\n"
            md += "| produced fields | \(inductionSummary.produced) |\n"
            md += "| produced nothing | \(inductionSummary.declined) |\n\n"
            md += "\"Produced nothing\" is recorded WITH its reason per document, so a "
            md += "document that was tried and yielded nothing is distinguishable from "
            md += "one that was never tried. Induced fields are marked `LLM_INDUCED` and "
            md += "carry a lower confidence than every rule-read field.\n\n"
        }

        // ── B-1 — why the topic layer looks the way it does
        let topicDiagnosis = await TopicLayerDiagnosis.run(database: database)
        md += "## Why do you see the topics you see? (B-1)\n\n"
        md += "**\(topicDiagnosis.headline)**\n\n"
        md += "An empty topic layer has at least seven distinct causes and they want "
        md += "completely different responses — from \"ingest something\" to \"nothing "
        md += "is wrong\". The chain below is walked in DEPENDENCY order, so the first "
        md += "unsatisfied link is the CAUSE and everything after it is consequence.\n\n"
        md += "| | link | state |\n|---|---|---|\n"
        for l in topicDiagnosis.links {
            md += "| \(l.outcome.symbol) | \(l.name) | \(l.outcome.line) |\n"
        }
        md += "\n"
        if let missing = topicDiagnosis.firstMissing {
            if topicDiagnosis.emptyButCorrect {
                md += "This is NOT a fault. The layer is empty because grouping would have "
                md += "required inventing a connection the documents do not support.\n\n"
            } else if missing.outcome.isDefect {
                issues.append("Topic layer: the chain stops at “\(missing.name)” — \(missing.outcome.line)")
            }
            if !missing.remedy.isEmpty {
                md += "**What to do:** \(missing.remedy)\n\n"
            }
        }

        // ── B-2 — why the story layer looks the way it does
        let historyDiagnosis = await HistoryLayerDiagnosis.run(database: database)
        md += "## Why do you see the stories you see? (B-2)\n\n"
        md += "**\(historyDiagnosis.headline)**\n\n"
        md += "| | link | state |\n|---|---|---|\n"
        for l in historyDiagnosis.links {
            md += "| \(l.outcome.symbol) | \(l.name) | \(l.outcome.line) |\n"
        }
        md += "\n"
        if let missing = historyDiagnosis.firstMissing {
            if historyDiagnosis.emptyButCorrect {
                md += "This is NOT a fault — see the reason above.\n\n"
            } else if missing.outcome.isDefect {
                issues.append("Story layer: the chain stops at “\(missing.name)” — \(missing.outcome.line)")
            }
            if !missing.remedy.isEmpty {
                md += "**What to do:** \(missing.remedy)\n\n"
            }
        }
        md += "This does NOT judge whether any particular subject's story is correct,\n"
        md += "complete or well-ordered. That requires named subjects — including a\n"
        md += "deliberately ambiguous one — and is recorded as owner-blocked rather than\n"
        md += "approximated with a subject chosen because it happens to work.\n\n"

        md += "## What this report does NOT tell you\n\n"
        md += "Stated so its silence is never mistaken for a clean bill of health:\n\n"
        md += "- **Whether the extracted values are CORRECT.** Everything above counts "
        md += "rows and reports gaps. Nothing here checks a single value against the "
        md += "document it came from.\n"
        md += "- **Whether the right things were extracted.** A document can derive "
        md += "cleanly and completely and still miss the one detail you care about, "
        md += "because no rule was written for it.\n"
        md += "- **Whether answers will be good.** Retrieval and composition quality are "
        md += "not measured here at all.\n"
        md += "- **Anything about files never offered to the app.** This audits what was "
        md += "ingested; it cannot see what was not selected, and a folder you forgot to "
        md += "add looks identical to a folder that was empty.\n\n"

        if !failedProbes.isEmpty {
            md += "## Checks that could not run (\(failedProbes.count))\n\n"
            md += "These probes failed, so their counts appear as 0 above WITHOUT being "
            md += "measured. Treat every number they feed as unknown, not as zero.\n\n"
            for probe in failedProbes { md += "- \(probe)\n" }
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

    /// nil when the query could not run. Returning 0 for a failed probe is
    /// what let a broken audit report a clean bill of health.
    ///
    /// Internal rather than private so a test can prove the distinction
    /// between "no rows" and "the probe failed" — the property the whole fix
    /// rests on.
    static func scalarCount(_ db: Database, _ sql: String) async -> Int? {
        guard let rows = try? await db.query(sql) else { return nil }
        return Int(rows.first?.int(0) ?? 0)
    }
}
