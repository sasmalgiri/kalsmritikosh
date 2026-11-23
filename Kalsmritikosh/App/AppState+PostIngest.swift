//
//  AppState+PostIngest.swift
//  Kalsmritikosh
//
//  After an import finishes, the "living ledger" checks of the plan run:
//   * W3-4 alerts — watchlist names found in newly added documents, contradictions and
//     gaps detected since the import started;
//   * N-11 question monitors — every pinned question is asked again and an alert is
//     raised only when its answer, its sources or a contradiction changed.
//  Each part honours its own module switch; nothing here changes evidence.
//

import Foundation
import CryptoKit
import os

extension AppState {

    public var alertsRepository: ProductAlertsRepository? {
        guard let database else { return nil }
        return ProductAlertsRepository(database: database)
    }

    public var pinnedQuestions: PinnedQuestionsRepository? {
        guard ProductModuleFlags.isEnabled(.questionMonitors), let database else { return nil }
        return PinnedQuestionsRepository(database: database)
    }

    private static let lastCheckKey = "kalsmritikosh.postIngest.lastCheck"

    /// Run the checks for everything added since they last ran (first run: the last hour).
    public func runPostIngestChecksSinceLast() async {
        await refreshRetrievalCaches()
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Double
        let since = last.map { Date(timeIntervalSince1970: $0) } ?? Date().addingTimeInterval(-3600)
        let now = Date()
        await runPostIngestChecks(since: since)
        // Unified path IN-18 (owner 2026-11-22) — not tested yet. The people register is refreshed
        // after imports (idempotent: an unchanged register scans nothing) and each merge is audited.
        await refreshEntityRegisterAndAudit(context: "Post-import")
        // Unified path IN-16 (owner 2026-11-22) — not tested yet: with AI on, new documents are queued for deep study.
        await enqueueDeepStudyAfterImport(since: since)
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.lastCheckKey)
    }

    /// Run after a batch completes. `since` = when the batch started.
    public func runPostIngestChecks(since: Date) async {
        guard let database, let alerts = alertsRepository else { return }
        if ProductModuleFlags.isEnabled(.proactiveAlerts) {
            await alertWatchlistHits(since: since, database: database, alerts: alerts)
            do {
                for r in try await database.query(
                    "SELECT description FROM contradictions WHERE detected_at >= ? LIMIT 50;", [.real(since.timeIntervalSince1970)]) {
                    try await alerts.add(kind: "contradiction", title: "New contradiction found",
                                         detail: r.string(0), objectID: nil)
                }
                for r in try await database.query(
                    "SELECT description, reason FROM gap_nodes WHERE detected_at >= ? AND dismissed = 0 LIMIT 50;",
                    [.real(since.timeIntervalSince1970)]) {
                    try await alerts.add(kind: "gap", title: "Something may be missing: \(r.string(0) ?? "")",
                                         detail: r.string(1), objectID: nil)
                }
            } catch {
                KalsmritikoshLog.app.error("Post-ingest alerts failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if ProductModuleFlags.isEnabled(.questionMonitors) { await rerunPinnedQuestions(alerts: alerts) }
        if ProductModuleFlags.isEnabled(.spotlightIndex) { await syncSpotlight() }   // W3-7
        if ProductModuleFlags.isEnabled(.smartCollections) { await runAutomationRules(since: since) }   // W3-5
    }

    private func alertWatchlistHits(since: Date, database: Database, alerts: ProductAlertsRepository) async {
        guard ProductModuleFlags.isEnabled(.watchlists), let lists = try? await watchlists?.all(), !lists.isEmpty else { return }
        do {
            // PERF-11 (2026-11-17): every new mention is read, a page at a time in a stable order (the old single 5,000-row
            // read had no order, and the next batch starts later, so the rest were never alerted on).
            // Speed PERF-23 (owner 2026-11-23) — not tested yet: keyset on (ko.created_at, e.id, ko.id) — the same order — not OFFSET.
            var rows: [SQLRow] = []
            var after: [SQLValue]? = nil
            while true {
                let page = try await database.query("""
                    SELECT DISTINCT e.id, e.value, ko.id, f.url, ko.created_at
                    FROM knowledge_objects ko
                    JOIN entity_mentions m ON m.source_object_id = ko.id
                    JOIN entities e ON e.id = m.entity_id
                    JOIN files f ON f.id = ko.file_id
                    WHERE ko.created_at >= ? AND e.kind IN ('person','organization','vendor','client')
                    \(after == nil ? "" : "AND (ko.created_at, e.id, ko.id) > (?, ?, ?)")
                    ORDER BY ko.created_at, e.id, ko.id LIMIT ?;
                    """, [.real(since.timeIntervalSince1970)] + (after ?? []) + [.integer(5_000)])
                rows += page
                guard page.count >= 5_000, let last = page.last, last.values.count > 4 else { break }
                after = [last.values[4], last.values[0], last.values[2]]
            }
            var byEntity: [UUID: (name: String, object: UUID, file: String)] = [:]
            for r in rows {
                guard let eid = r.uuid(0), let name = r.string(1), let oid = r.uuid(2) else { continue }
                byEntity[eid] = (name, oid, (r.string(3).flatMap { URL(string: $0)?.lastPathComponent }) ?? "a new document")
            }
            let candidates = byEntity.map { WatchlistMatcher.Candidate(entityID: $0.key, name: $0.value.name, aliases: []) }
            for list in lists {
                for m in WatchlistMatcher.match(terms: list.terms, candidates: candidates) {
                    guard let hit = byEntity[m.entityID] else { continue }
                    try await alerts.add(kind: "watchlist", title: "\(list.name): “\(m.term)” appears in \(hit.file)",
                                         detail: "Matched “\(m.matchedOn)” (\(m.strength.rawValue)).", objectID: hit.object)
                }
            }
        } catch {
            KalsmritikoshLog.app.error("Watchlist alerts failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// N-11 — ask every pinned question again; alert only on change.
    public func rerunPinnedQuestions(alerts: ProductAlertsRepository) async {
        guard let pinned = pinnedQuestions, let list = try? await pinned.all() else { return }
        let access = SensitiveAccessContext(scope: .globalOwnerRetrieval())
        // Speed PERF-22 (owner 2026-11-23) — not tested yet. Pinned questions concurrently under an AIMD limiter (at most
        // 3: each is a whole ask); each question's answer is recorded as soon as it is in (the per-item checkpoint).
        // AI split AI-49 (owner 2026-11-24) — background work outside a case never has the AI read documents: a pinned
        // question is re-run on the app's search (no permission asked, nothing sent); asking it again opens the agent.
        let brain = self.brain
        _ = await AdaptiveConcurrency.mapResults(list, cap: min(3, AdaptiveConcurrency.aiCap())) { q in
            let a = await brain.answerWithDiagnostics(question: q.question, access: access).answer
            let text = a.refused ? "(no evidence)" : (a.answerText ?? a.body)
            let citations = Array(Set(a.citations.map(\.objectID))).sorted { $0.uuidString < $1.uuidString }
            let fingerprint = SHA256.hash(data: Data((text + "|" + citations.map(\.uuidString).joined(separator: ",")
                                                       + "|\(a.contradictions.count)").utf8))
                .map { String(format: "%02x", $0) }.joined()
            if let last = q.lastFingerprint, last != fingerprint {
                var what: [String] = []
                if (q.lastAnswer ?? "") != text { what.append("the answer") }
                if Set(q.lastCitationIDs) != Set(citations) { what.append("its sources") }
                if (q.lastContradictions ?? 0) != a.contradictions.count { what.append("contradictions") }
                try? await alerts.add(kind: "question", title: "“\(q.question)” changed: \(what.joined(separator: ", "))",
                                      detail: "Before: \(String((q.lastAnswer ?? "").prefix(300)))\nNow: \(String(text.prefix(300)))",
                                      objectID: nil)
            }
            try? await pinned.record(q.id, answer: text, fingerprint: fingerprint, citations: citations,
                                     contradictions: a.contradictions.count)
        }
    }

    /// Self-check probe 2026-11-19: the entity and timeline caches were filled at launch and never after, so a name known at
    /// launch resolved only to its launch-time entities and events — documents added during the session were missed for
    /// that name until a restart (a name new since launch already fell back to SQL). After documents are added the caches
    /// are dropped at once (retrieval then reads SQL, which has everything) and refilled in the background.
    func refreshRetrievalCaches() async {
        guard let trie = entityTrie, let timeline = entityTimeline, let entities, let events else { return }
        await trie.shed(reason: "documents were added; refilling")
        await timeline.shed(reason: "documents were added; refilling")
        Task.detached(priority: .utility) {
            await trie.warm(entities: entities)
            await timeline.warm(events: events)
        }
    }
}
