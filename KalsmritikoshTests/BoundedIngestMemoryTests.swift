//
//  BoundedIngestMemoryTests.swift
//  KalsmritikoshTests
//
//  F01 — ingest must not require the whole file (or all of its records) resident at once.
//

import Foundation
import SQLite3
import Testing
@testable import Kalsmritikosh

@Suite("F01 — bounded-memory ingest")
struct BoundedIngestMemoryTests {

    private func tempFile(_ name: String, _ data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test("Snapshot bytes are memory-mapped, byte-identical, and an empty file still reads")
    func snapshotBytesMapped() throws {
        let body = Data((0..<200_000).map { UInt8($0 % 251) })
        let url = try tempFile("big.bin", body)
        #expect(try ExistingParserPluginAdapter.snapshotBytes(url) == body)
        let empty = try tempFile("empty.bin", Data())
        #expect(try ExistingParserPluginAdapter.snapshotBytes(empty).isEmpty)
    }

    // MARK: - F01b streaming loader contract

    /// A record's identity for comparison: content plus metadata, minus fields that embed the
    /// per-run KO UUID (structured entities carry `sourceObjectID`).
    private func fingerprint(_ ko: KnowledgeObject) -> String {
        let meta = ko.metadata
            .filter { $0.key != EmailLoader.structuredEntitiesMetaKey }
            .map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ";")
        return ko.content + "\u{1}" + meta
    }

    private func streamed(_ loader: some StreamingIngestor, _ url: URL, _ type: SourceType,
                          _ budget: StreamBatchBudget) async throws -> [[KnowledgeObject]] {
        var batches: [[KnowledgeObject]] = []
        try await loader.streamRecords(fileAt: url, type: type, budget: budget) { batches.append($0) }
        return batches
    }

    private func makeSQLite(rows: Int) throws -> URL {
        let url = try tempFile("stream.db", Data())
        try? FileManager.default.removeItem(at: url)
        var h: OpaquePointer?
        guard sqlite3_open_v2(url.path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(h) }
        var sql = "CREATE TABLE m(id INTEGER PRIMARY KEY, v TEXT); BEGIN;"
        for i in 1...rows { sql += "INSERT INTO m VALUES(\(i),'row-\(i)');" }
        sql += "COMMIT;"
        guard sqlite3_exec(h, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    private func makeMbox(messages: Int) throws -> URL {
        // A leading blank piece must not shift the messageIndex of the messages after it.
        var text = "\n\n"
        for i in 0..<messages {
            text += "From sender\(i)@example.com Mon Jan  1 00:00:00 2024\n"
            text += "From: Sender \(i) <sender\(i)@example.com>\nSubject: Message \(i)\n"
            text += "Date: Mon, 1 Jan 2024 10:\(String(format: "%02d", i % 60)):00 +0000\n\n"
            text += "Body of message number \(i).\n\n"
        }
        return try tempFile("stream.mbox", Data(text.utf8))
    }

    @Test("SQLite streams every page, in order, identical to ingestMany, one page per batch")
    func sqliteStreamsPages() async throws {
        let url = try makeSQLite(rows: 1_750)   // 4 pages of ≤500 rows
        let loader = SQLiteLoader()
        #expect(loader.streamsRecords(type: .sqlite))
        let reference = try await loader.ingestMany(fileAt: url, type: .sqlite)
        let batches = try await streamed(loader, url, .sqlite, StreamBatchBudget(maxObjects: 1, maxContentBytes: .max))
        #expect(reference.count == 4)
        #expect(batches.count == 4)
        #expect(batches.allSatisfy { $0.count == 1 })
        #expect(batches.flatMap { $0 }.map(fingerprint) == reference.map(fingerprint))
    }

    @Test("Per-message mbox streams in bounded batches with the same messageIndex as ingestMany")
    func mboxStreamsMessages() async throws {
        let url = try makeMbox(messages: 10)
        let loader = EmailLoader()
        try #require(loader.streamsRecords(type: .mbox), "per-message mode is the default")
        let reference = try await loader.ingestMany(fileAt: url, type: .mbox)
        let batches = try await streamed(loader, url, .mbox, StreamBatchBudget(maxObjects: 3, maxContentBytes: .max))
        #expect(reference.count == 10)
        #expect(batches.map(\.count) == [3, 3, 3, 1])
        #expect(batches.flatMap { $0 }.map(fingerprint) == reference.map(fingerprint))
    }

    @Test("A byte ceiling flushes a batch before the object ceiling")
    func byteCeilingFlushes() async throws {
        let url = try makeMbox(messages: 6)
        let one = try await EmailLoader().ingestMany(fileAt: url, type: .mbox)[0].content.utf8.count
        let batches = try await streamed(EmailLoader(), url, .mbox,
                                         StreamBatchBudget(maxObjects: 100, maxContentBytes: one + 1))
        #expect(batches.count == 3)
        #expect(batches.allSatisfy { $0.count <= 2 })
    }

    // MARK: - F01c coordinator streaming path

    private struct Rig { let coordinator: IngestCoordinator; let readiness: SourceReadinessRepository; let db: Database; let dir: URL }

    @MainActor
    private func makeRig(_ budget: IngestMemoryBudget?) async throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bim-rig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let readiness = SourceReadinessRepository(database: db)
        let intake = UniversalSourceIntakeCoordinator(repository: CanonicalSourceIntakeRepository(
            database: db, vault: EvidenceVault(root: dir.appendingPathComponent("vault", isDirectory: true))))
        let coordinator = IngestCoordinator(
            universalRegistry: try UniversalParserRegistryBuilder.standard(ocr: VisionOCR()),
            files: FilesRepository(database: db), objects: KnowledgeObjectRepository(database: db),
            chunks: ChunksRepository(database: db), evidenceStore: EvidenceStore(database: db),
            ingestAttempts: IngestAttemptsRepository(database: db),
            readiness: readiness, intakeCoordinator: intake, custodyModeOverride: .referenced)
        if let budget { await coordinator.setMemoryBudget(budget) }
        return Rig(coordinator: coordinator, readiness: readiness, db: db, dir: dir)
    }

    /// Every file streams; batches of 3 records.
    private let tinyBudget = IngestMemoryBudget(streamAboveBytes: 1, deferWholeFileAboveBytes: .max,
                                                batch: StreamBatchBudget(maxObjects: 3, maxContentBytes: .max))

    private func count(_ rig: Rig, _ sql: String, _ id: UUID) async throws -> Int {
        Int(try await rig.db.query(sql, [.uuid(id)]).first?.int(0) ?? 0)
    }

    @Test("A streamed mbox commits every message, searchable, exactly as the whole-file path does")
    @MainActor func streamedMboxMatchesWholeFile() async throws {
        let mbox = try makeMbox(messages: 10)
        var shapes: [[Int]] = []
        for budget in [nil, tinyBudget] {
            let rig = try await makeRig(budget)
            let result = try await rig.coordinator.ingest(fileAt: mbox)
            let v = try #require(result.sourceVersionID)
            let kos = try await count(rig, "SELECT COUNT(*) FROM knowledge_objects WHERE file_id = ?;", result.fileRecord.id)
            let chunks = try await count(rig, "SELECT COUNT(*) FROM chunks WHERE source_version_id = ?;", v)
            for i in 0..<10 {
                let hits = try await count(rig, "SELECT COUNT(*) FROM chunks WHERE source_version_id = ? AND text LIKE '%message number \(i).%';", v)
                #expect(hits >= 1, "message \(i) must be committed and chunked")
            }
            let fts = try await rig.readiness.ftsCoverage(sourceVersionID: v)
            #expect(result.processingStatus == nil)
            #expect(chunks > 0 && fts.eligible == chunks && fts.indexed == chunks)
            let text = try await rig.readiness.snapshot(sourceVersionID: v).dimension(.textExtraction)
            #expect(text?.state == .ready)
            // Chunk counts legitimately differ: whole-file chunks from structural blocks, the stream
            // (structure blocked) from record text. The RECORDS committed must be identical.
            let metas = try await rig.db.query(
                "SELECT metadata_json FROM knowledge_objects WHERE file_id = ?;", [.uuid(result.fileRecord.id)])
            let indices = metas.compactMap { $0.string(0) }.compactMap { json -> Int? in
                guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
                return (obj["messageIndex"] as? NSNumber)?.intValue
            }
            shapes.append([kos] + indices.sorted())
        }
        #expect(shapes[0] == [10] + Array(0..<10), "every message committed with its messageIndex")
        #expect(shapes[0] == shapes[1], "streamed and whole-file ingest must commit the same records")
    }

    @Test("A streamed database records structure as blocked by a resource limit, never ready")
    @MainActor func streamedSQLiteBlocksStructure() async throws {
        let rig = try await makeRig(tinyBudget)
        let url = try makeSQLite(rows: 1_750)
        let result = try await rig.coordinator.ingest(fileAt: url)
        let v = try #require(result.sourceVersionID)
        #expect(try await count(rig, "SELECT COUNT(*) FROM knowledge_objects WHERE file_id = ?;", result.fileRecord.id) == 4)
        #expect(try await count(rig, "SELECT COUNT(*) FROM chunks WHERE source_version_id = ? AND text LIKE '%row-1750%';", v) >= 1)
        let structure = try await rig.readiness.snapshot(sourceVersionID: v).dimension(.structuralExtraction)
        #expect(structure?.state == .blocked)
        #expect(structure?.condition == .resourceLimit)
    }

    @Test("An oversize file that cannot stream is deferred with custody kept, not loaded whole")
    @MainActor func oversizeNonStreamableDefers() async throws {
        let rig = try await makeRig(IngestMemoryBudget(streamAboveBytes: 8, deferWholeFileAboveBytes: 16))
        let url = rig.dir.appendingPathComponent("notes.txt")
        try String(repeating: "A plain text note that cannot be streamed. ", count: 20).write(to: url, atomically: true, encoding: .utf8)
        let result = try await rig.coordinator.ingest(fileAt: url)
        let v = try #require(result.sourceVersionID)
        #expect(result.processingStatus == .deferred)
        #expect(try await count(rig, "SELECT COUNT(*) FROM source_versions WHERE id = ?;", v) == 1)
        #expect(try await count(rig, "SELECT COUNT(*) FROM chunks WHERE source_version_id = ?;", v) == 0)
        let text = try await rig.readiness.snapshot(sourceVersionID: v).dimension(.textExtraction)
        #expect(text?.state == .blocked)
        #expect(text?.condition == .resourceLimit)
    }
}
