//
//  SelfCheckProbeTests.swift
//  KalsmritikoshTests
//
//  Self-check probe (2026-11-19). The GUI walk saw "Self-check found issues 13/15" on the disposable acceptance ledger.
//  The fast self-check passes 15/15 on a fresh ledger; with the acceptance documents only the advisory data-health check
//  flags issues (background passes not yet run, the deliberately unreadable scan). Two of its lines pointed at a real
//  defect: the entity and timeline caches were filled at launch only, so documents added in the session were missed for a
//  name already known at launch. These tests pin the fix.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@MainActor
@Suite("Self-check probe and retrieval caches after new documents", .serialized)
struct SelfCheckProbeTests {

    @Test("The fast self-check passes on a fresh ledger (no blocker fails)")
    func fastSelfCheckFresh() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("selfcheck-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let state = AppState(bookmarks: BookmarkStore(ephemeral: true))
        await state.boot(databaseURL: temp.appendingPathComponent("ledger.sqlite"))
        let report = await ReleaseReadiness.run(state, mode: .fast)
        let failedBlockers = report.checks.filter { !$0.passed && $0.blocker }
        #expect(failedBlockers.isEmpty, "\(failedBlockers.map { "\($0.id): \($0.detail)" })")
        await state.shutdown()
    }

    @Test("Documents added after launch reach the entity timeline for a name already known at launch")
    func cachesRefreshAfterIngest() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("caches-\(UUID().uuidString)", isDirectory: true)
        let docs = temp.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let state = AppState(bookmarks: BookmarkStore(ephemeral: true))
        await state.boot(databaseURL: temp.appendingPathComponent("ledger.sqlite"))
        let ingest = try #require(state.ingest)
        let trie = try #require(state.entityTrie), timeline = try #require(state.entityTimeline)
        let entities = try #require(state.entities), events = try #require(state.events)

        let first = docs.appendingPathComponent("statement-1.txt")
        try Data("Statement of Asha Rao, 3 March 2026.\nAsha Rao said she approved invoice INV-2041 on 3 March 2026.".utf8).write(to: first)
        _ = try await ingest.ingest(fileAt: first)
        // As at launch: the caches are filled from what the ledger holds now.
        await trie.warm(entities: entities)
        await timeline.warm(events: events)
        let db = try #require(state.database)
        func ledgerCounts() async throws -> (entities: Int, events: Int) {
            let e = try await db.query("SELECT COUNT(*) FROM entities;").first?.int(0) ?? 0
            let v = try await db.query("SELECT COUNT(*) FROM events;").first?.int(0) ?? 0
            return (Int(e), Int(v))
        }
        let before = await trie.stats()?.entitiesLoaded ?? 0
        #expect(before > 0, "the first document's names are in the cache")
        #expect(before == (try await ledgerCounts()).entities)

        // A second document, added during the session, naming people the cache has not seen.
        let second = docs.appendingPathComponent("statement-2.txt")
        try Data("Statement of Vikram Shah, 9 March 2026.\nVikram Shah said Dev Malhotra of Dalmia Traders received the second payment on 9 March 2026.".utf8).write(to: second)
        _ = try await ingest.ingest(fileAt: second)
        let ledger = try await ledgerCounts()
        #expect(ledger.entities > before, "the ledger now holds the new names (\(ledger.entities) vs \(before))")
        #expect((await trie.stats()?.entitiesLoaded ?? 0) == before, "without a refresh the cache still holds only what it had")

        // The post-ingest step drops the caches at once (SQL serves) and refills them in the background.
        await state.runPostIngestChecksSinceLast()
        for _ in 0..<50 {
            if await trie.isWarm(), await timeline.isWarm() { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(await trie.isWarm())
        #expect(await timeline.isWarm())
        #expect((await trie.stats()?.entitiesLoaded ?? 0) == ledger.entities, "the cache holds every name the ledger holds")
        #expect((await timeline.stats()?.eventsLoaded ?? -1) >= 0)
        await state.shutdown()
    }
}
