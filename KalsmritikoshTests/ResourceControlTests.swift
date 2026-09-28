//
//  ResourceControlTests.swift
//  KalsmritikoshTests
//
//  F12 — memory-aware resource control: the corpus-wide retrieval caches are byte-accounted and
//  shed whole (falling back to SQL) instead of growing without bound.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("F12 — memory-aware resource control")
struct ResourceControlTests {

    private func freshDBWithKO() async throws -> (Database, UUID) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        let fileID = UUID(), koID = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?, ?, ?);",
                          [.uuid(fileID), .text("file:///rc-test"), .text("text")])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?, ?, ?, ?, 0, 0);
        """, [.uuid(koID), .uuid(fileID), .text("text"), .text("resource control body")])
        return (db, koID)
    }

    private func seedEntities(_ n: Int) async throws -> EntitiesRepository {
        let (db, ko) = try await freshDBWithKO()
        let repo = EntitiesRepository(database: db)
        _ = try await repo.insertBatch((0..<n).map {
            Entity(kind: .organization, value: "Supplier Number\($0) Holdings", sourceObjectID: ko)
        })
        return repo
    }

    // MARK: - byte-accounted caches (F12b)

    @Test("Within budget the trie warms, resolves, and reports its resident bytes")
    func trieWarmsWithinBudget() async throws {
        let repo = try await seedEntities(50)
        let trie = EntityTrie(byteBudget: 64 * 1_048_576)
        await trie.warm(entities: repo, pageSize: 7)
        #expect(await trie.isWarm())
        #expect(await trie.lastShedReason() == nil)
        #expect(await trie.residentBytes() > 0)
        #expect(await !trie.resolve("Supplier Number7").isEmpty)
    }

    @Test("A warm that would exceed the byte budget sheds whole and reports cold, never partial")
    func trieWarmOverBudgetSheds() async throws {
        let repo = try await seedEntities(200)
        // Measure the full cost, then allow well under it.
        let probe = EntityTrie(byteBudget: .max)
        await probe.warm(entities: repo, pageSize: 25)
        let full = await probe.residentBytes()
        let trie = EntityTrie(byteBudget: full / 4)
        await trie.warm(entities: repo, pageSize: 25)
        #expect(await !trie.isWarm(), "a partial trie must not claim warm — its misses would read as 'no entity'")
        #expect(await trie.residentBytes() == 0)
        #expect(await trie.lastShedReason()?.contains("budget") == true)
        #expect(await trie.resolve("Supplier Number7").isEmpty)
    }

    @Test("After a shed, patches are ignored until the next warm, which restores the cache")
    func shedStaysColdUntilRewarm() async throws {
        let repo = try await seedEntities(20)
        let trie = EntityTrie(byteBudget: 64 * 1_048_576)
        await trie.warm(entities: repo)
        await trie.shed(reason: "memory pressure")
        await trie.note(id: UUID(), value: "Late Arrival Corp")
        #expect(await !trie.isWarm())
        #expect(await trie.residentBytes() == 0)
        #expect(await trie.lastShedReason() == "memory pressure")
        await trie.warm(entities: repo)
        #expect(await trie.isWarm())
        #expect(await trie.lastShedReason() == nil)
        #expect(await !trie.resolve("Supplier Number3").isEmpty)
    }

    @Test("The timeline sheds when incremental events grow it past its budget")
    func timelineGrowthSheds() async {
        let entity = UUID()
        let budget = 50 * (EntityTimeline.slotBytes) + EntityTimeline.bucketBytes
        let timeline = EntityTimeline(byteBudget: budget)
        func event(_ i: Int) -> Event {
            Event(id: UUID(), kind: .other, date: Date(timeIntervalSince1970: Double(i) * 86_400), title: "E\(i)",
                  entityIDs: [entity], sourceObjectID: UUID(), datePrecision: .day)
        }
        for i in 0..<40 { await timeline.note(event: event(i), participants: [entity]) }
        #expect(await timeline.lastShedReason() == nil)
        #expect(await timeline.slots(forEntity: entity).count == 40)
        for i in 40..<80 { await timeline.note(event: event(i), participants: [entity]) }
        #expect(await timeline.lastShedReason() != nil)
        #expect(await timeline.residentBytes() == 0)
        #expect(await timeline.slots(forEntity: entity).isEmpty)
        #expect(await !timeline.isWarm())
    }

    @Test("The memory cache accounts narrative bytes and sheds past its budget")
    func memoryCacheAccountsAndSheds() async {
        let narrative = String(repeating: "n", count: 10_000)
        let one = MemoryHashCache.estimatedBytes(
            MemoryObject(subjectKind: .project, subjectIdentifier: "p0", narrative: narrative), key: "project|p0")
        #expect(one > 10_000, "the estimate must count the narrative payload")
        let cache = MemoryHashCache(byteBudget: one * 3 + one / 2)
        for i in 0..<3 {
            await cache.note(MemoryObject(subjectKind: .project, subjectIdentifier: "p\(i)", narrative: narrative))
        }
        #expect(await cache.count() == 3)
        // Replacing an entry re-accounts it rather than double counting.
        await cache.note(MemoryObject(subjectKind: .project, subjectIdentifier: "p0", narrative: narrative))
        #expect(await cache.count() == 3)
        #expect(await cache.lastShedReason() == nil)
        await cache.note(MemoryObject(subjectKind: .project, subjectIdentifier: "p3", narrative: narrative))
        #expect(await cache.count() == 0)
        #expect(await cache.lastShedReason() != nil)
    }

    @Test("The default cache budget scales with RAM inside fixed bounds")
    func defaultBudgetBounds() {
        let mb = 1_048_576
        #expect(CacheByteBudget.defaultBytes(physicalMemory: 16 * 1024 * UInt64(mb)) == 256 * mb)
        #expect(CacheByteBudget.defaultBytes(physicalMemory: 1024 * UInt64(mb)) == 32 * mb)
        #expect(CacheByteBudget.defaultBytes(physicalMemory: 256 * 1024 * UInt64(mb)) == 512 * mb)
    }
}
