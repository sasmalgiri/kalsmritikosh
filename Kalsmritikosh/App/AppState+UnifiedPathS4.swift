//
//  AppState+UnifiedPathS4.swift
//  Kalsmritikosh
//
//  Unified-path program S4 (owner 2026-11-22) — the S3 leftovers on the app side: something now enqueues deep
//  study into the durable enrichment queue (IN-16), and Ask's reconstructed histories are persisted like the
//  Dossier's (HISTORY-09). Not tested yet (owner 2026-11-22: implement now, test later).
//

import Foundation
import os

extension AppState {

    // MARK: - IN-16 enqueue deep study

    /// The most documents one enqueue adds (the queue drains in the background, yielding to questions).
    nonisolated static let deepStudyEnqueueCap = 200

    /// Unified path IN-16 (owner 2026-11-22) — not tested yet. Queue deep study for these documents (deduplicated
    /// by the queue) and drain the deep-study kind in the background. Returns how many were newly queued.
    @discardableResult
    func enqueueDeepStudy(objectIDs: [UUID], reason: String) async -> Int {
        guard let jobs = enrichmentJobs, !objectIDs.isEmpty else { return 0 }
        var queued = 0
        for id in objectIDs.prefix(Self.deepStudyEnqueueCap) {
            do { if try await jobs.enqueue(subjectID: id, kind: .deepStudy) { queued += 1 } } catch {
                KalsmritikoshLog.knowledge.error("Deep study (\(reason, privacy: .public)): enqueue failed: \(String(describing: error), privacy: .public)")
            }
        }
        if objectIDs.count > Self.deepStudyEnqueueCap {
            KalsmritikoshLog.knowledge.info("Deep study (\(reason, privacy: .public)): \(objectIDs.count - Self.deepStudyEnqueueCap, privacy: .public) document(s) beyond the cap not queued this time")
        }
        if queued > 0, let drainer = enrichmentDrainer {
            Task.detached(priority: .utility) { _ = await drainer.drain(kind: .deepStudy) }
        }
        return queued
    }

    /// IN-16 — after an import, with AI on: the documents added since `since` are queued for deep study.
    func enqueueDeepStudyAfterImport(since: Date) async {
        guard ReleaseCapabilityProfile.aiOn(), let database else { return }
        do {
            let rows = try await database.query(
                "SELECT id FROM knowledge_objects WHERE created_at >= ? ORDER BY created_at LIMIT ?;",
                [.date(since), .integer(Int64(Self.deepStudyEnqueueCap))])
            let ids = rows.compactMap { $0.uuid(0) }
            let n = await enqueueDeepStudy(objectIDs: ids, reason: "after import")
            if n > 0 { KalsmritikoshLog.knowledge.info("Deep study: \(n, privacy: .public) new document(s) queued after import") }
        } catch {
            KalsmritikoshLog.knowledge.error("Deep study after import: new documents unreadable: \(String(describing: error), privacy: .public)")
        }
    }

    /// IN-16 — Case tools ▸ Study deeper: the case's authorised documents are queued for deep study.
    func enqueueDeepStudy(caseID: UUID) async -> Int {
        guard let database, let objects else { return 0 }
        do {
            guard let record = try await InvestigationCaseRepository(database: database).fetch(caseID: caseID) else { return 0 }
            let versions = try await CaseRetrievalScopeResolver(evidence: EvidenceStore(database: database))
                .scope(for: record).authorizedSourceVersionIDs
            let ids = try await objects.sourceVersionsByObject(inSourceVersionIDs: versions).keys
                .sorted { $0.uuidString < $1.uuidString }
            return await enqueueDeepStudy(objectIDs: ids, reason: "case tools")
        } catch {
            KalsmritikoshLog.knowledge.error("Deep study for a case: documents unreadable: \(String(describing: error), privacy: .public)")
            return 0
        }
    }

    // MARK: - HISTORY-09 persist Ask's histories

    /// Unified path HISTORY-09 (owner 2026-11-22) — not tested yet. After Ask answered a history question through
    /// the reconstruction path, the same subject is reconstructed by the history engine (deterministic) and saved
    /// through the Ask door (`persistStoryFromAsk`: unreviewed, stamped, de-duplicated, older versions superseded).
    /// Like the story door, only under the owner's whole-archive scope (the engine reads unscoped repositories);
    /// a subject that does not resolve to one anchor is not saved.
    func persistAskHistory(question: String, access: SensitiveAccessContext) async {
        guard access.scope.isGlobalOwnerBypass, let entities, let engine = historyEngine else { return }
        do {
            let anchors = try await entities.allAnchors()
            guard case .resolved(let subject, let anchorKey) = try await HistorySubjectResolver(entities: entities)
                .resolveStory(question: question, anchors: anchors) else { return }
            var result: HistoryReconstructionResult?
            for await update in engine.reconstruct(subject: subject.subject, request: HistoryRequest()) {
                if case .verified(let r) = update { result = r }
            }
            guard let result else { return }
            let narrative = HistoryNarrativeRenderer().render(outline: result.outline)
            if let id = await persistStoryFromAsk(result, narrative: narrative, anchorKey: anchorKey) {
                KalsmritikoshLog.app.info("history: Ask's reconstruction saved (artifact \(id.uuidString.prefix(8), privacy: .public))")
            }
        } catch {
            KalsmritikoshLog.app.error("history: Ask's reconstruction not saved: \(String(describing: error), privacy: .public)")
        }
    }
}
