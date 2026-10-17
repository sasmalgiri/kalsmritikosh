//
//  BoundedBookkeepingTests.swift
//  KalsmritikoshTests
//
//  F01/F12 (residual, 2026-09-29 review) — streaming bounded each payload batch, but the bookkeeping
//  around it still grew with the file (per-record ownership list, every invalidation, the mailbox's
//  boundary array), an oversized record had no defined limit, and the pressure governor could apply
//  levels out of order across a suspended responder. These bounds are INSTRUMENTED (high-water
//  counters over a lazily generated stream), not a measured macOS resident-memory figure.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("F01/F12 — bookkeeping stays bounded as a stream grows; pressure is applied in order", .serialized)
@MainActor
struct BoundedBookkeepingTests {

    private actor EventLog {
        var events: [String] = []
        func append(_ e: String) { events.append(e) }
    }

    @Test("Pressure levels are applied one at a time, in order, even when a responder suspends")
    func governorSerializesLevels() async {
        let governor = MemoryPressureGovernor()
        let log = EventLog()
        await governor.addResponder { level in
            await log.append("begin \(level.description)")
            try? await Task.sleep(nanoseconds: 30_000_000)
            await log.append("end \(level.description)")
        }
        async let a: Void = governor.report(.critical)
        async let b: Void = governor.report(.warning)
        async let c: Void = governor.report(.normal)
        _ = await (a, b, c)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let events = await log.events
        // Never interleaved: every begin is followed by its own end before the next begin.
        #expect(events.count % 2 == 0)
        for i in stride(from: 0, to: events.count - 1, by: 2) {
            let level = events[i].dropFirst("begin ".count)
            #expect(events[i].hasPrefix("begin ") && events[i + 1] == "end \(level)", "levels interleaved: \(events)")
        }
        // The last level applied is the last one reported.
        #expect(await governor.currentLevel() == .normal)
        #expect(events.last == "end normal")
    }

    @Test("Relief stops re-warming the moment pressure returns")
    func reliefStopsWhenPressureReturns() async {
        let memory = MemoryHashCache(byteBudget: 64 * 1_048_576)
        await memory.shed(reason: MemoryPressureResponse.pressureShedReason)
        await MemoryPressureResponse.apply(.normal, ingest: nil, lanes: nil, memory: memory, timeline: nil, trie: nil,
                                           rewarm: .init(memory: { Issue.record("re-warmed while pressure was reported again") }),
                                           stillRelieved: { false })
        #expect(await memory.lastShedReason() == MemoryPressureResponse.pressureShedReason, "the cache stays cold")
    }

    // MARK: - Streams generated lazily (never materialised as a fixture)

    /// Emits `count` tiny records one at a time, and one oversized record at `oversizedAt`.
    private struct GeneratingStreamer: StreamingIngestor {
        let count: Int
        let oversizedAt: Int?
        nonisolated var supportedTypes: Set<SourceType> { [.txt] }
        nonisolated func streamsRecords(type: SourceType) -> Bool { true }
        func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject {
            KnowledgeObject(sourceFile: url, sourceType: .txt, content: "whole")
        }
        func streamRecords(fileAt url: URL, type: SourceType, budget: StreamBatchBudget,
                           emit: ([KnowledgeObject]) async throws -> Void) async throws {
            var batcher = KnowledgeObjectBatcher(budget: budget)
            for i in 0..<count {
                let body = i == oversizedAt ? String(repeating: "oversized record body ", count: 40) : "Generated record \(i) notes."
                if let batch = batcher.add(KnowledgeObject(sourceFile: url, sourceType: .txt, content: body)) { try await emit(batch) }
            }
            if let rest = batcher.drain() { try await emit(rest) }
        }
    }

    private func rig(_ streamer: GeneratingStreamer, batch: StreamBatchBudget) async throws -> (IngestCoordinator, Database, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bookkeep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db); try await db.exec("PRAGMA foreign_keys = ON;")
        let vault = EvidenceVault(root: dir.appendingPathComponent("vault", isDirectory: true))
        let plugin = ExistingParserPluginAdapter(pluginID: "test.generator", pluginVersion: "1", supportedTypes: [.txt],
                                                 executionMode: .immediate, loader: streamer, structural: nil,
                                                 enforceLoaderTypeSupport: false, declaredSurfaces: [.text])
        let fallback = ExistingParserPluginAdapter(pluginID: "test.fallback", pluginVersion: "1", supportedTypes: [.unknown],
                                                   executionMode: .immediate, loader: TextLoader(), structural: nil,
                                                   enforceLoaderTypeSupport: false, declaredSurfaces: [.text])
        let c = IngestCoordinator(
            universalRegistry: try UniversalParserRegistry(plugins: [plugin], unknownFallback: fallback),
            entityExtractor: NLEntityExtractor(), entityLinker: EntityLinker(), eventExtractor: RuleEventExtractor(),
            files: FilesRepository(database: db), objects: KnowledgeObjectRepository(database: db),
            chunks: ChunksRepository(database: db), evidenceStore: EvidenceStore(database: db),
            ingestAttempts: IngestAttemptsRepository(database: db), sourceRelations: SourceRelationsRepository(database: db),
            evidenceVault: vault, readiness: SourceReadinessRepository(database: db),
            containerInspection: ContainerInspectionRepository(database: db),
            intakeCoordinator: UniversalSourceIntakeCoordinator(repository: CanonicalSourceIntakeRepository(database: db, vault: vault)),
            custodyModeOverride: .managed)
        await c.configureUpgrades(database: db, jobs: SourceUpgradeJobRepository(database: db))
        await c.setMemoryBudget(IngestMemoryBudget(streamAboveBytes: 16, deferWholeFileAboveBytes: 1 << 30, batch: batch))
        let url = dir.appendingPathComponent("stream.txt")
        try String(repeating: "x", count: 64).write(to: url, atomically: true, encoding: .utf8)
        return (c, db, url)
    }

    @Test("Live bookkeeping does not grow with the record count: 40 and 400 records have the same high-water marks")
    func bookkeepingIndependentOfCount() async throws {
        let budget = StreamBatchBudget(maxObjects: 4, maxContentBytes: 256, maxRecordBytes: 4096)
        var marks: [IngestCoordinator.StreamBookkeeping] = []
        for n in [40, 400] {
            let (c, _, url) = try await rig(GeneratingStreamer(count: n, oversizedAt: nil), batch: budget)
            let svid = try #require(try await c.ingest(fileAt: url).sourceVersionID)
            let outcomes = try await c.streamRecordOutcomes(sourceVersionID: svid)
            #expect(outcomes.count == n && outcomes.allSatisfy { $0.state == .committed })
            marks.append(await c.streamBookkeeping())
        }
        for m in marks {
            #expect(m.maxBatchObjects <= budget.maxObjects)
            #expect(m.maxBatchContentBytes <= budget.maxContentBytes)
            #expect(m.maxInMemoryOwnership == 0, "ownership keys live in durable rows, not an in-memory list")
            #expect(m.retainedInvalidations <= 1024)
        }
        #expect(marks[0].records == 40 && marks[1].records == 400)
        #expect(marks[0].maxBatchObjects == marks[1].maxBatchObjects)
        #expect(marks[0].maxInMemoryOwnership == marks[1].maxInMemoryOwnership)
    }

    @Test("An oversized record hits an explicit, recoverable per-record limit; raising it and retrying commits it once")
    func oversizedRecordIsRecoverable() async throws {
        let small = StreamBatchBudget(maxObjects: 4, maxContentBytes: 4096, maxRecordBytes: 200)
        let (c, db, url) = try await rig(GeneratingStreamer(count: 6, oversizedAt: 3), batch: small)
        let svid = try #require(try await c.ingest(fileAt: url).sourceVersionID)
        let outcomes = try await c.streamRecordOutcomes(sourceVersionID: svid)
        #expect(outcomes.filter { $0.state == .committed }.count == 5)
        #expect(outcomes.first { $0.state == .failed }?.reason?.contains("per-record budget") == true)
        #expect(await c.streamBookkeeping().oversizedRecords == 1)
        #expect(try await SourceReadinessRepository(database: db).snapshot(sourceVersionID: svid).dimension(.textExtraction)?.state == .partial)
        // Custody was kept, so raising the limit and retrying recovers the record — exactly once.
        await c.setMemoryBudget(IngestMemoryBudget(streamAboveBytes: 16, deferWholeFileAboveBytes: 1 << 30,
                                                   batch: StreamBatchBudget(maxObjects: 4, maxContentBytes: 4096, maxRecordBytes: 4096)))
        try await c.resumeStreamedIngest(sourceVersionID: svid)
        let after = try await c.streamRecordOutcomes(sourceVersionID: svid)
        #expect(after.count == 6 && after.allSatisfy { $0.state == .committed })
        #expect(try await db.query("SELECT COUNT(*) FROM chunks WHERE source_version_id = ? AND text LIKE '%oversized record body%' AND superseded_by_run IS NULL;",
                                   [.uuid(svid)]).first?.int(0) ?? 0 >= 1)
        #expect(try await SourceReadinessRepository(database: db).snapshot(sourceVersionID: svid).dimension(.textExtraction)?.state == .ready)
    }

    @Test("Walking mbox boundaries one at a time yields exactly the collected boundaries")
    func incrementalBoundariesMatch() {
        var mbox = "preamble line\n"
        for i in 0..<25 { mbox += "From a\(i)@x Mon Jan 1 00:00:00 2024\nSubject: s\(i)\n\nbody \(i) mentions From inside a line\n" }
        let data = Data(mbox.utf8)
        var walked = [0], start = 0
        while start < data.count { start = EmailLoader.nextMboxBoundary(data, after: start); walked.append(start) }
        #expect(walked == EmailLoader.mboxBoundaries(data))
        #expect(EmailLoader.countMboxMessages(data) == walked.count - 1)
    }
}
