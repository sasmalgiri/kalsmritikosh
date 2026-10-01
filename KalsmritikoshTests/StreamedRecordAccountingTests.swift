//
//  StreamedRecordAccountingTests.swift
//  KalsmritikoshTests
//
//  F01/F15 (residual, 2026-09-29 review) — the streaming ingest caught a failing record, logged it and
//  moved on; readiness then measured the SURVIVING chunks, so a lost record vanished behind "ready".
//  Every streamed record now has a durable outcome (attempting / committed / failed with reason), a
//  failed record keeps the source's text readiness partial, and a retry commits exactly the missing
//  records — rolling back a half-written attempt first, so nothing is duplicated.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("F01/F15 — every streamed record is accounted for; retry converges without duplicates", .serialized)
@MainActor
struct StreamedRecordAccountingTests {

    private struct Rig { let c: IngestCoordinator; let db: Database; let dir: URL }

    private func rig(registry: UniversalParserRegistry? = nil) async throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stracc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db); try await db.exec("PRAGMA foreign_keys = ON;")
        let vault = EvidenceVault(root: dir.appendingPathComponent("vault", isDirectory: true))
        let intake = UniversalSourceIntakeCoordinator(repository: CanonicalSourceIntakeRepository(database: db, vault: vault))
        let c = IngestCoordinator(
            universalRegistry: try registry ?? UniversalParserRegistryBuilder.standard(ocr: VisionOCR()),
            entityExtractor: NLEntityExtractor(), entityLinker: EntityLinker(), eventExtractor: RuleEventExtractor(),
            files: FilesRepository(database: db), objects: KnowledgeObjectRepository(database: db),
            chunks: ChunksRepository(database: db), evidenceStore: EvidenceStore(database: db),
            ingestAttempts: IngestAttemptsRepository(database: db), sourceRelations: SourceRelationsRepository(database: db),
            evidenceVault: vault, readiness: SourceReadinessRepository(database: db),
            containerInspection: ContainerInspectionRepository(database: db), intakeCoordinator: intake,
            custodyModeOverride: .managed)
        await c.configureUpgrades(database: db, jobs: SourceUpgradeJobRepository(database: db))
        // Stream anything larger than 64 bytes, one record per batch.
        await c.setMemoryBudget(IngestMemoryBudget(streamAboveBytes: 64, deferWholeFileAboveBytes: 1 << 30,
                                                   batch: StreamBatchBudget(maxObjects: 1, maxContentBytes: 4096)))
        return Rig(c: c, db: db, dir: dir)
    }

    /// Five messages, one per record (per-message mode via distinct subjects); message 3 is poisoned.
    private func mailbox(_ r: Rig) throws -> URL {
        var mbox = ""
        for i in 1...5 {
            let body = i == 3 ? "Record three carries the poison-marker token in its body." : "Record \(i) is an ordinary message body."
            mbox += "From m\(i)@example.com Mon Jan 0\(i) 00:00:00 2024\nFrom: Sender \(i) <m\(i)@example.com>\n"
                + "To: owner@example.com\nSubject: Distinct subject \(i)\nDate: Mon, 0\(i) Jan 2024 10:00:00 +0000\n\n\(body)\n\n"
        }
        let url = r.dir.appendingPathComponent("five.mbox")
        try mbox.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A persistence failure AFTER the record's object row is written: its chunk insert aborts.
    private func poison(_ r: Rig) async throws {
        try await r.db.exec("""
            CREATE TRIGGER test_poison BEFORE INSERT ON chunks WHEN NEW.text LIKE '%poison-marker%'
            BEGIN SELECT RAISE(ABORT, 'injected persistence failure'); END;
            """)
    }

    private func count(_ r: Rig, _ sql: String, _ svid: UUID) async throws -> Int {
        Int(try await r.db.query(sql, [.uuid(svid)]).first?.int(0) ?? 0)
    }

    @Test("A record that fails to persist is counted, keeps readiness partial, and a retry commits it once")
    func failedRecordThenRetry() async throws {
        let r = try await rig()
        try await poison(r)
        let svid = try #require(try await r.c.ingest(fileAt: try mailbox(r)).sourceVersionID)

        let outcomes = try await r.c.streamRecordOutcomes(sourceVersionID: svid)
        #expect(outcomes.filter { $0.state == .committed }.count == 4)
        let failed = outcomes.filter { $0.state == .failed }
        #expect(failed.count == 1)
        #expect(failed.first?.reason?.contains("injected persistence failure") == true, "the failure reason must be actionable")
        let text = try await SourceReadinessRepository(database: r.db).snapshot(sourceVersionID: svid).dimension(.textExtraction)
        #expect(text?.state == .partial, "a lost record must never read as complete text")
        // Committed records stay searchable.
        #expect(!(try await ChunksRepository(database: r.db).searchFTS("ordinary", limit: 10)).isEmpty)

        // Fix the cause and retry: every record exists exactly once, with lineage.
        try await r.db.exec("DROP TRIGGER test_poison;")
        try await r.c.resumeStreamedIngest(sourceVersionID: svid)
        let after = try await r.c.streamRecordOutcomes(sourceVersionID: svid)
        #expect(after.count == 5 && after.allSatisfy { $0.state == .committed })
        let fileID = try #require(try await r.db.query("SELECT logical_source_id FROM source_versions WHERE id = ?;", [.uuid(svid)]).first?.uuid(0))
        #expect(try await r.db.query("SELECT COUNT(*) FROM knowledge_objects WHERE file_id = ?;", [.uuid(fileID)]).first?.int(0) == 5,
                "the half-written attempt must be rolled back, not duplicated")
        #expect(try await count(r, "SELECT COUNT(*) FROM chunks WHERE source_version_id = ? AND text LIKE '%poison-marker%' AND superseded_by_run IS NULL;", svid) == 1)
        #expect(Set(after.compactMap(\.objectID)).count == 5)
        #expect(try await SourceReadinessRepository(database: r.db).snapshot(sourceVersionID: svid).dimension(.textExtraction)?.state == .ready)
        // A second retry changes nothing.
        let chunksBefore = try await count(r, "SELECT COUNT(*) FROM chunks WHERE source_version_id = ?;", svid)
        try await r.c.resumeStreamedIngest(sourceVersionID: svid)
        #expect(try await count(r, "SELECT COUNT(*) FROM chunks WHERE source_version_id = ?;", svid) == chunksBefore)
    }

    /// A loader that emits two records, then fails — a loader-level (not record-level) failure.
    private struct FailingStreamer: StreamingIngestor {
        nonisolated var supportedTypes: Set<SourceType> { [.txt] }
        nonisolated func streamsRecords(type: SourceType) -> Bool { true }
        struct Broken: Error {}
        func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject {
            KnowledgeObject(sourceFile: url, sourceType: .txt, content: "whole")
        }
        func streamRecords(fileAt url: URL, type: SourceType, budget: StreamBatchBudget,
                           emit: ([KnowledgeObject]) async throws -> Void) async throws {
            for i in 1...2 {
                try await emit([KnowledgeObject(sourceFile: url, sourceType: .txt, content: "Streamed part \(i) of the notes file.")])
            }
            throw Broken()
        }
    }

    @Test("A loader that fails mid-stream keeps committed records and reports partial text, distinct from a record failure")
    func loaderLevelFailure() async throws {
        let plugin = ExistingParserPluginAdapter(pluginID: "test.failing-stream", pluginVersion: "1", supportedTypes: [.txt],
                                                 executionMode: .immediate, loader: FailingStreamer(), structural: nil,
                                                 enforceLoaderTypeSupport: false, declaredSurfaces: [.text])
        let fallback = ExistingParserPluginAdapter(pluginID: "test.fallback", pluginVersion: "1", supportedTypes: [.unknown],
                                                   executionMode: .immediate, loader: TextLoader(), structural: nil,
                                                   enforceLoaderTypeSupport: false, declaredSurfaces: [.text])
        let r = try await rig(registry: try UniversalParserRegistry(plugins: [plugin], unknownFallback: fallback))
        let url = r.dir.appendingPathComponent("notes.txt")
        try String(repeating: "notes line\n", count: 20).write(to: url, atomically: true, encoding: .utf8)
        let svid = try #require(try await r.c.ingest(fileAt: url).sourceVersionID)
        let outcomes = try await r.c.streamRecordOutcomes(sourceVersionID: svid)
        #expect(outcomes.count == 2 && outcomes.allSatisfy { $0.state == .committed }, "records before the loader failure stay committed")
        let text = try await SourceReadinessRepository(database: r.db).snapshot(sourceVersionID: svid).dimension(.textExtraction)
        #expect(text?.state == .partial)
        #expect(text?.detail?.contains("stream stopped") == true, "a loader failure is reported as the stream stopping")
    }
}
