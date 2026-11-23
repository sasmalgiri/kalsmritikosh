//
//  AppState+UnifiedPathS3.swift
//  Kalsmritikosh
//
//  Unified-path program S3 (owner 2026-11-22) — the app-side helpers that connect built-but-unused
//  pieces to the live product: deep study on demand (AI-28) and the case's local enrichment check
//  (IN-20). Not tested yet (owner 2026-11-22: implement now, test later).
//

import Foundation
import os

extension AppState {

    // MARK: - AI-28 Study deeper

    /// Unified path AI-28 (owner 2026-11-22) — not tested yet. Deep study (Tier 3) for the named
    /// subjects, on demand. When ingest-time distillation runs, the Tier3Escalator drops each
    /// subject into the updater's stream; otherwise the memory distiller runs for each subject now
    /// (the person asked). Without AI the distiller writes what its deterministic path can.
    /// Returns how many subjects were queued or distilled.
    @discardableResult
    public func studyDeeper(subjects: [(kind: MemoryObject.SubjectKind, identifier: String)],
                            triggeringObjectID: UUID?) async -> Int {
        let wanted = subjects.filter { !$0.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.prefix(25)
        guard !wanted.isEmpty else { return 0 }
        if let tier3Escalator, let trigger = triggeringObjectID {
            for s in wanted {
                await tier3Escalator.forceEscalate(subjectKind: s.kind, subjectIdentifier: s.identifier, triggeringObjectID: trigger)
            }
            return wanted.count
        }
        guard let memoryDistiller else { return 0 }
        let activity = beginProcess("Studying deeper")
        defer { finishProcess(activity) }
        var done = 0
        for s in wanted {
            do {
                if try await memoryDistiller.distill(.init(kind: s.kind, identifier: s.identifier),
                                                     triggeredBy: triggeringObjectID) != nil { done += 1 }
            } catch {
                KalsmritikoshLog.knowledge.error("Study deeper: distillation failed: \(String(describing: error), privacy: .public)")
            }
        }
        return done
    }

    // MARK: - IN-20 local enrichment

    /// Unified path IN-20 (owner 2026-11-22) — not tested yet. The LOCAL enrichment adapter: the
    /// sanctions lists already saved on this Mac (by an earlier Online lookup), matched here; nothing
    /// is sent. A list never saved is reported as not searched (the result says partial or failed,
    /// never "no match"). Registry and court lookups stay in Online tools (outside providers).
    public func localSanctionsCheck(_ name: String) async -> CaseEnrichmentResult {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder: URL?
        do { folder = try ScanRescue.folder().deletingLastPathComponent().appendingPathComponent("Public lists", isDirectory: true) } catch {
            KalsmritikoshLog.app.error("Local sanctions check: list folder not found: \(String(describing: error), privacy: .public)")
            folder = nil
        }
        let sources: [PublicSource] = SanctionsLists.requests().map(\.0)
        // Speed PERF-29 (owner 2026-11-23) — not tested yet. The kept lists parsed once into the shared index (reused
        // until a list file changes), off the main actor.
        let (searched, index) = await Task.detached(priority: .userInitiated) {
            SanctionsListCache.local(folder: folder, sources: sources)
        }.value
        let missing = sources.filter { s in !searched.contains(s) }
        return CaseEnrichmentAdapters.sanctions(query: query, matches: index.match(query),
                                                searched: searched, failedLists: missing, at: Date())
    }
}

extension AppState {

    // MARK: - IN-16 deep-enrichment queue handlers

    /// Unified path IN-16 (owner 2026-11-22) — not tested yet. Registers the `.deepStudy` handler on
    /// the durable enrichment queue, reusing the existing engines: the document's deterministic
    /// summary (HeuristicSummarizer, no model), then — only when the capability registry resolves a
    /// reasoning provider (AI allowed) — memory distillation for the people, organisations and
    /// projects the document names. Without AI the summary still runs and distillation is skipped.
    /// The other kinds stay unhandled (the drainer never claims a kind without a handler).
    func registerEnrichmentHandlers() async {
        guard let enrichmentDrainer else { return }
        await enrichmentDrainer.register(.deepStudy) { [weak self] objectID in
            guard let self else { return }
            try await self.deepStudyJob(objectID: objectID)
        }
    }

    private func deepStudyJob(objectID: UUID) async throws {
        if let objects, let summariesRepo {
            let summarizer = HeuristicSummarizer(objectsRepo: objects, summariesRepo: summariesRepo)
            _ = try await summarizer.summarize(scope: .document(objectID), level: .document, length: .executive)
        }
        guard let entities, let memoryDistiller, let capabilities else { return }
        let aiAllowed = (try? await capabilities.resolve(CapabilitySpec.reasoning(contextTokens: 2_000, purpose: "memory.distill"))) != nil
        guard aiAllowed else {
            KalsmritikoshLog.knowledge.info("Deep study job: memory distillation skipped (AI not allowed)")
            return
        }
        let named = try await entities.findByMentionSource(objectID)
        var seen = Set<String>()
        for e in named {
            let kind: MemoryObject.SubjectKind
            switch e.kind {
            case .person: kind = .person
            case .organization: kind = .organization
            case .project: kind = .project
            default: continue
            }
            guard seen.insert("\(kind.rawValue)|\(e.value.lowercased())").inserted else { continue }
            if seen.count > 8 { break }
            do { _ = try await memoryDistiller.distill(.init(kind: kind, identifier: e.value), triggeredBy: objectID) } catch {
                KalsmritikoshLog.knowledge.error("Deep study job: distillation failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

extension AppState {

    // MARK: - IN-18 register refresh + merge audit

    /// Unified path IN-18 (owner 2026-11-22) — not tested yet. Run EntityRegisterRefresh (clean
    /// stored names, soft-merge collisions; reversible, nothing deleted) and record each merge it
    /// made in the reconciliation audit (v200 entity_reconciliation_events).
    func refreshEntityRegisterAndAudit(context: String) async {
        guard let database, let entities else { return }
        let receipt: EntityRegisterRefreshReceipt
        do { receipt = try await EntityRegisterRefresh(database: database, entities: entities).run() } catch {
            KalsmritikoshLog.knowledge.error("\(context, privacy: .public): register refresh failed: \(String(describing: error), privacy: .public)")
            return
        }
        if receipt.scanned > 0 {
            KalsmritikoshLog.knowledge.info("\(context, privacy: .public): register refresh — \(receipt.renderLines(), privacy: .public)")
        }
        guard !receipt.merges.isEmpty else { return }
        let audit = EntityReconciliationAuditRepository(database: database)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for m in receipt.merges {
            do {
                try await audit.record(ReconciliationEvent(op: .merge(winner: m.winner, losers: [m.loser]),
                                                           initiatedByHuman: false, atMillis: now),
                                       origin: "registerRefresh")
            } catch {
                KalsmritikoshLog.knowledge.error("\(context, privacy: .public): merge audit not recorded: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

extension AppState {

    // MARK: - IN-18 round 2 — undo an automatic merge

    /// Unified path IN-18 (owner 2026-11-22, round 2) — not tested yet. Undo one merge from the reconciliation audit: a
    /// register-refresh or human merge is unmerged (the loser stands alone again), an OCR-variant fold gets its tier,
    /// confidence and alias back. The undo is recorded as its own split event (the audit is append-only). Returns a line
    /// for the screen.
    public func undoEntityMerge(_ merge: EntityReconciliationAuditRepository.OpenMerge) async -> String {
        guard let database, let entities else { return "The ledger is not open." }
        do {
            if merge.origin.hasPrefix("ocrVariant") {
                let parts = merge.origin.split(separator: ":")
                let tier = parts.count > 1 ? String(parts[1]) : "T2"
                let confidence = parts.count > 2 ? (Double(parts[2]) ?? 0.5) : 0.5
                for loser in merge.losers {
                    try await entities.unmarkOCRVariant(loserID: loser, winnerID: merge.winner, tier: tier, confidence: confidence)
                }
            } else {
                for loser in merge.losers { try await entities.unmerge(loserID: loser) }
            }
            try await EntityReconciliationAuditRepository(database: database).record(
                ReconciliationEvent(op: EntityReconciliationAudit.reverse(.merge(winner: merge.winner, losers: merge.losers)),
                                    initiatedByHuman: true, atMillis: Int64(Date().timeIntervalSince1970 * 1000)), origin: "undo")
            return "Undone: the names stand apart again."
        } catch {
            KalsmritikoshLog.knowledge.error("Undo merge failed: \(String(describing: error), privacy: .public)")
            return "Not undone: \(error.localizedDescription)"
        }
    }

    // MARK: - IN-19 versions + readiness in the document inspector

    /// Unified path IN-19 (owner 2026-11-22) — not tested yet. One version list for a document:
    /// canonical `source_versions` rows (authoritative) unified with legacy `file_versions` rows
    /// (lower confidence) by VersionModelConsolidator, newest first.
    public func documentVersions(objectID: UUID) async -> [SourceVersionView] {
        guard let database else { return [] }
        do {
            // Test phase T2 (2026-11-22): a document's versions hang off its FILE (source_versions.logical_source_id =
            // knowledge_objects.file_id, as EvidenceStore.currentVersionID resolves it) — never the KnowledgeObject id,
            // which matched nothing, so the inspector's version list was always empty.
            let canonical = try await database.query("""
            SELECT sv.id, sv.logical_source_id, sv.content_hash, sv.valid_from, sv.is_current FROM source_versions sv
            JOIN knowledge_objects ko ON sv.logical_source_id = ko.file_id
            WHERE ko.id = ? ORDER BY sv.valid_from DESC LIMIT 50;
            """, [.uuid(objectID)]).compactMap { r -> CanonicalVersionRecord? in
                guard let id = r.uuid(0), let logical = r.uuid(1), let hash = r.string(2) else { return nil }
                return CanonicalVersionRecord(id: id, logicalSourceID: logical, contentHash: hash,
                                              validFrom: Date(timeIntervalSince1970: r.double(3) ?? 0), isCurrent: (r.int(4) ?? 0) != 0)
            }
            let legacy = try await database.query("""
            SELECT fv.version_id, fv.file_id, fv.content_hash, fv.superseded_at FROM file_versions fv
            JOIN knowledge_objects ko ON ko.file_id = fv.file_id WHERE ko.id = ? ORDER BY fv.superseded_at DESC LIMIT 50;
            """, [.uuid(objectID)]).compactMap { r -> LegacyVersionRecord? in
                guard let id = r.uuid(0), let file = r.uuid(1) else { return nil }
                return LegacyVersionRecord(versionID: id, fileID: file, contentHash: r.string(2),
                                           supersededAt: Date(timeIntervalSince1970: r.double(3) ?? 0))
            }
            return VersionModelConsolidator.unify(canonical: canonical, legacy: legacy)
        } catch {
            KalsmritikoshLog.ui.error("Document versions not read: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Unified path IN-19 (owner 2026-11-22) — not tested yet. The readiness event history of the
    /// document's current version (SourceReadinessLedgerInspector, read-only).
    public func readinessHistory(objectID: UUID) async -> [SourceReadinessLedgerInspector.EventRow] {
        guard let database else { return [] }
        do {
            guard let current = try await database.query(
                // Test phase T2 (2026-11-22): through the document's file, as above (the KnowledgeObject id matched nothing).
                "SELECT sv.id FROM source_versions sv JOIN knowledge_objects ko ON sv.logical_source_id = ko.file_id WHERE ko.id = ? AND sv.is_current = 1 LIMIT 1;",
                [.uuid(objectID)]).first?.uuid(0) else { return [] }
            return try await SourceReadinessLedgerInspector(database: database).events(sourceVersionID: current)
        } catch {
            KalsmritikoshLog.ui.error("Readiness history not read: \(String(describing: error), privacy: .public)")
            return []
        }
    }
}

extension AppState {
    // MARK: - HISTORY-09 history versions this session

    /// Unified path HISTORY-09 (owner 2026-11-22) — not tested yet.
    func previousHistoryOutline(for subject: String) -> HistoryOutline? {
        historyOutlinesThisSession[subject.lowercased()]
    }

    /// Unified path HISTORY-09 (owner 2026-11-22) — not tested yet.
    func rememberHistoryOutline(_ outline: HistoryOutline, for subject: String) {
        historyOutlinesThisSession[subject.lowercased()] = outline
    }

    /// Unified path HISTORY-09 (owner 2026-11-22, round 2) — not tested yet. What changed against the newest PERSISTED
    /// history of the subject (any earlier session): counts of new / no longer supported / changed items, compared by
    /// kind and title, status, confidence and evidence count (the same keys HistoryDiffEngine uses). nil = none persisted.
    func changeSincePersistedHistory(_ outline: HistoryOutline, excluding: UUID?) async -> (at: Date, new: Int, retracted: Int, changed: Int)? {
        guard let historyArtifacts else { return nil }
        let previous: (at: Date, items: [String: HistoryArtifactRepository.ItemSignature])?
        do {
            previous = try await historyArtifacts.previousItemSignatures(subjectID: outline.subject.canonicalEntityID,
                                                                         subjectLabel: outline.subject.displayName, excluding: excluding)
        } catch {
            KalsmritikoshLog.knowledge.error("History compare: earlier history not read: \(String(describing: error), privacy: .public)")
            return nil
        }
        guard let previous else { return nil }
        var seen = Set<String>()
        var new = 0, changed = 0
        for item in outline.items {
            let key = "\(item.kind.rawValue)|\(item.title.lowercased())"
            seen.insert(key)
            guard let old = previous.items[key] else { new += 1; continue }
            if old.status != LegacyEvidenceStatusAdapter.encode(item.assessment).rawValue
                || abs(old.confidence - item.confidence) > 0.0001 || old.evidenceCount != item.evidence.count { changed += 1 }
        }
        let retracted = previous.items.keys.filter { !seen.contains($0) }.count
        return (previous.at, new, retracted, changed)
    }
}

extension AppState {

    // MARK: - QA-20 local measurements (counts and scores only, never content)

    /// Unified path QA-20 (owner 2026-11-22) — not tested yet. Retrieval recall of the bundled gold
    /// questions over the CURRENT ledger (RetrievalGoldEval). A score line only.
    public func measureRetrievalGold() async -> String {
        guard let retriever, let objects else { return "Not run: the ledger isn't open yet." }
        do {
            let questions = try EvalKitRunner().loadQuestions()
            return await RetrievalGoldEval().run(retriever: retriever, objects: objects, questions: questions, chunks: chunks).renderLine()
        } catch {
            KalsmritikoshLog.app.error("Measurements: gold questions not loaded: \(String(describing: error), privacy: .public)")
            return "Not run: the gold questions could not be read."
        }
    }

    /// Unified path QA-20 (owner 2026-11-22) — not tested yet. RetrievalEval recall/precision@10 of the
    /// keyword layer: each gold question's expected source files are resolved to this ledger's documents
    /// by file name; questions whose files are not in this ledger are left out (counted).
    public func measureRetrievalEval() async -> String {
        guard let database, let chunks else { return "Not run: the ledger isn't open yet." }
        do {
            let questions = try EvalKitRunner().loadQuestions()
            var cases: [RetrievalGoldCase] = []
            var ranked: [String: [UUID]] = [:]
            var skipped = 0
            for q in questions {
                var relevant = Set<UUID>()
                for name in q.expectedSourceFiles {
                    let rows = try await database.query("""
                    SELECT k.id FROM knowledge_objects k JOIN files f ON f.id = k.file_id WHERE f.url LIKE ? LIMIT 20;
                    """, [.text("%/" + name)])
                    relevant.formUnion(rows.compactMap { $0.uuid(0) })
                }
                guard !relevant.isEmpty else { skipped += 1; continue }
                cases.append(RetrievalGoldCase(question: q.text, relevantObjectIDs: relevant))
                var seen = Set<UUID>()
                ranked[q.text] = try await chunks.searchFTS(q.text, limit: 40).map(\.objectID).filter { seen.insert($0).inserted }
            }
            let m = RetrievalEval.score(cases: cases, k: 10) { ranked[$0] ?? [] }
            return String(format: "keyword layer — recall@10 %.3f, precision@10 %.3f, covered %.3f (n=%d; %d question(s) whose files are not in this ledger left out)",
                          m.meanRecallAtK, m.meanPrecisionAtK, m.answerableCovered, m.cases, skipped)
        } catch {
            KalsmritikoshLog.app.error("Measurements: retrieval eval failed: \(String(describing: error), privacy: .public)")
            return "Not run: \(error.localizedDescription)"
        }
    }

    /// Unified path QA-20 (owner 2026-11-22) — not tested yet. The vector index benchmark on synthetic
    /// vectors in a throwaway database (ANNBenchmark): timings and recall only.
    public func measureANN() async -> String {
        do {
            let metrics = try await ANNBenchmark(queryCount: 20, insertCount: 20).run(sizes: [2_000])
            return metrics.map {
                String(format: "%d vectors — query p50 %.1f ms (exact %.1f ms), recall@10 %.3f", $0.size, $0.queryP50Ms, $0.bruteForceP50Ms, $0.recallAt10)
            }.joined(separator: "\n")
        } catch {
            KalsmritikoshLog.app.error("Measurements: ANN benchmark failed: \(String(describing: error), privacy: .public)")
            return "Not run: \(error.localizedDescription)"
        }
    }

    /// Unified path QA-20 (owner 2026-11-22) — not tested yet. Error analysis of the labelled fixture
    /// against this ledger (GroundTruthEvalKit → ErrorAnalysisClassifier): counts per error kind.
    public func measureErrorAnalysis() async -> String {
        guard let entities, let events else { return "Not run: the ledger isn't open yet." }
        guard let url = Bundle.main.url(forResource: "ground-truth-projectdelta", withExtension: "json", subdirectory: "Eval")
            ?? Bundle.main.url(forResource: "ground-truth-projectdelta", withExtension: "json") else {
            return "Not run: the labelled fixture is not in this build."
        }
        do {
            let gt = try await GroundTruthEvalKit().run(fixtureURL: url, entities: entities, events: events, links: eventLinks)
            let report = ErrorAnalysisClassifier().classify(report: gt)
            let parts = report.histogram.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
            return parts.isEmpty ? "No errors classified (the fixture's documents may not be in this ledger)." : parts.joined(separator: " · ")
        } catch {
            KalsmritikoshLog.app.error("Measurements: error analysis failed: \(String(describing: error), privacy: .public)")
            return "Not run: \(error.localizedDescription)"
        }
    }
}
