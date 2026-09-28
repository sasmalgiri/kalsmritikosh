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

    // MARK: - memory pressure (F12a) and adaptive workers (F12c)

    /// Counts concurrent entries so a test can read the peak.
    private actor Gauge {
        var now = 0, peak = 0, done = 0
        func enter() { now += 1; peak = max(peak, now) }
        func leave() { now -= 1; done += 1 }
    }

    @Test("Kernel events map to the most severe level they carry")
    func eventLevels() {
        #expect(MemoryPressureLevel(event: .normal) == .normal)
        #expect(MemoryPressureLevel(event: .warning) == .warning)
        #expect(MemoryPressureLevel(event: [.warning, .critical]) == .critical)
    }

    @Test("The governor fans each level CHANGE out once, in order, and ignores repeats")
    func governorFansOutChanges() async {
        actor Log { var seen: [MemoryPressureLevel] = []; func add(_ l: MemoryPressureLevel) { seen.append(l) } }
        let log = Log()
        let governor = MemoryPressureGovernor()
        await governor.addResponder { await log.add($0) }
        for level in [MemoryPressureLevel.warning, .warning, .critical, .normal, .normal] { await governor.report(level) }
        #expect(await log.seen == [.warning, .critical, .normal])
        #expect(await governor.currentLevel() == .normal)
    }

    @Test("Critical pressure sheds every retrieval cache; warning leaves them warm")
    func criticalShedsCaches() async throws {
        let repo = try await seedEntities(10)
        let trie = EntityTrie(byteBudget: 64 * 1_048_576)
        await trie.warm(entities: repo)
        let timeline = EntityTimeline(byteBudget: 64 * 1_048_576)
        let memory = MemoryHashCache(byteBudget: 64 * 1_048_576)
        await memory.note(MemoryObject(subjectKind: .project, subjectIdentifier: "delta", narrative: "n"))
        let governor = MemoryPressureGovernor()
        await MemoryPressureResponse.install(on: governor, ingest: nil, memory: memory, timeline: timeline, trie: trie)
        await governor.report(.warning)
        #expect(await trie.isWarm())
        #expect(await memory.count() == 1)
        await governor.report(.critical)
        #expect(await !trie.isWarm())
        #expect(await trie.lastShedReason()?.contains("pressure") == true)
        #expect(await memory.count() == 0)
        #expect(await timeline.lastShedReason() != nil)
    }

    @Test("Lanes narrow under pressure and restore their boot caps on relief")
    func lanesAdapt() async {
        let lanes = LaneScheduler(capacities: [.cpu: 8, .diskIO: 4, .neuralEngine: 1, .network: 4])
        await lanes.setPressure(.warning)
        #expect(await lanes.capacity(of: .cpu) == 4)
        #expect(await lanes.capacity(of: .diskIO) == 2)
        #expect(await lanes.capacity(of: .network) == 4, "network is not memory-bound")
        await lanes.setPressure(.critical)
        #expect(await lanes.capacity(of: .cpu) == 1)
        await lanes.setPressure(.normal)
        #expect(await lanes.capacity(of: .cpu) == 8)
    }

    @Test("A narrowed lane never runs more than its cap, and widening admits queued work")
    func narrowedLaneHoldsCap() async {
        let lanes = LaneScheduler(capacities: [.cpu: 6])
        await lanes.setPressure(.critical)
        let gauge = Gauge()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    await lanes.withLane(.cpu) {
                        await gauge.enter()
                        try? await Task.sleep(nanoseconds: 5_000_000)
                        await gauge.leave()
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
            await lanes.setPressure(.normal)
        }
        #expect(await gauge.done == 12, "every job still runs")
        #expect(await gauge.peak <= 6)
    }

    @Test("Bounded fan-out runs every item with at most maxInFlight alive")
    func boundedFanOut() async {
        let gauge = Gauge()
        await BoundedFanOut.forEach(Array(0..<200), maxInFlight: 5) { _ in
            await gauge.enter()
            await Task.yield()
            await gauge.leave()
        }
        #expect(await gauge.done == 200)
        #expect(await gauge.peak <= 5)
        #expect(BoundedFanOut.watcherLimit(capacities: [.cpu: 7, .diskIO: 4, .network: 4]) == 30)
    }
}
