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
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Double
        let since = last.map { Date(timeIntervalSince1970: $0) } ?? Date().addingTimeInterval(-3600)
        let now = Date()
        await runPostIngestChecks(since: since)
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
            let rows = try await database.query("""
                SELECT DISTINCT e.id, e.value, ko.id, f.url
                FROM knowledge_objects ko
                JOIN entity_mentions m ON m.source_object_id = ko.id
                JOIN entities e ON e.id = m.entity_id
                JOIN files f ON f.id = ko.file_id
                WHERE ko.created_at >= ? AND e.kind IN ('person','organization','vendor','client')
                LIMIT 5000;
                """, [.real(since.timeIntervalSince1970)])
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
        for q in list {
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
}
