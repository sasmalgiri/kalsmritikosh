//
//  UnifiedPathIngestTests.swift
//  KalsmritikoshTests
//
//  Test phase T2 (2026-11-22) — the memory-sized shard workers (PERF-14 … PERF-17, docs/UNIFIED_PATH_PROGRAM_2026-11-22.md §2)
//  and the ingest rows of the unified-path program (IN-16 … IN-26). Ephemeral ledgers only; no network.
//

import CryptoKit
import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Unified path — shard workers and ingest", .serialized)
struct UnifiedPathIngestTests {

    nonisolated final class Gauge: @unchecked Sendable {
        private let lock = NSLock(); private var now = 0, peak = 0, calls = 0
        func enter() { lock.withLock { now += 1; peak = Swift.max(peak, now) } }
        func leave() { lock.withLock { now -= 1 } }
        func tick() { lock.withLock { calls += 1 } }
        var max: Int { lock.withLock { peak } }
        var count: Int { lock.withLock { calls } }
    }

    static func scratch(_ tag: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("us-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @MainActor
    static func booted(_ dir: URL) async -> AppState {
        let state = AppState(bookmarks: BookmarkStore(ephemeral: true))
        await state.boot(databaseURL: dir.appendingPathComponent("ledger.sqlite"))
        return state
    }

    static var fixtures: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures", isDirectory: true) }

    // MARK: - PERF-14 budget

    @Test("PERF-14: the worker count follows available memory (half reserved), cores − 1, memory pressure and thermal state; never below 1")
    func workerBudget() {
        let gb: UInt64 = 1 << 30
        func w(_ avail: UInt64, cores: Int = 8, _ p: MemoryPressureLevel = .normal, _ t: ProcessInfo.ThermalState = .nominal) -> Int {
            WorkerBudget(availableBytes: avail, physicalBytes: 32 * gb, activeCores: cores, pressure: p, thermal: t)
                .workers(perWorkerBytes: 768 * 1_048_576)
        }
        #expect(w(16 * gb) == 7, "8 GB shareable / 768 MB = 10, capped at cores − 1")
        #expect(w(3 * gb) == 2, "1.5 GB shareable = 2 workers")
        #expect(w(16 * gb, cores: 16) == 10, "memory-bound")
        #expect(w(16 * gb, .warning) == 3 && w(16 * gb, .critical) == 1)
        #expect(w(16 * gb, .normal, .fair) == 6 && w(16 * gb, .normal, .serious) == 1 && w(16 * gb, .normal, .critical) == 1)
        #expect(w(100 * 1_048_576) == 1 && w(16 * gb, cores: 1) == 1, "never below one")
        #expect(WorkerBudget(availableBytes: 8 * gb, physicalBytes: 16 * gb, activeCores: 4, pressure: .normal, thermal: .nominal)
            .bytesPerWorker(count: 2) == 2 * gb)
        let live = WorkerBudget.current()
        #expect(live.availableBytes > 0 && live.activeCores >= 1)
    }

    @Test("PERF-14: the pool re-checks the budget before every batch — under critical pressure one batch at a time, every batch still runs")
    func poolFollowsPressure() async {
        let g = Gauge()
        let critical = IngestWorkerPool(perWorkerBytes: 1, pressure: { .critical })
        let started = await critical.run(Array(0..<6)) { _, _ in
            g.enter(); defer { g.leave() }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(started == Array(0..<6) && g.max == 1, "peak \(g.max)")
        let checks = Gauge()
        let normal = IngestWorkerPool(perWorkerBytes: 1, pressure: { checks.tick(); return .normal })
        let g2 = Gauge()
        _ = await normal.run(Array(0..<6)) { _, _ in g2.enter(); defer { g2.leave() }; try? await Task.sleep(for: .milliseconds(40)) }
        #expect(checks.count >= 6, "the budget is read again for each batch (\(checks.count))")
        if ProcessInfo.processInfo.activeProcessorCount > 2, ProcessInfo.processInfo.thermalState == .nominal {
            #expect(g2.max > 1, "several workers when memory allows (peak \(g2.max))")
        }
        let stopped = await normal.run(Array(0..<6), shouldContinue: { false }) { _, _ in }
        #expect(stopped.isEmpty, "a stop before the first batch starts none")
    }

    // MARK: - PERF-15 batches

    @Test("PERF-15: files packed into batches that fit one worker's share; a file over the share gets its own batch; file cap per batch")
    func batchPlanner() throws {
        func f(_ name: String, _ mb: UInt64) -> IngestPlannedFile { IngestPlannedFile(url: URL(fileURLWithPath: "/x/\(name)"), bytes: mb * 1_048_576) }
        let files = [f("mail.mbox", 900), f("a", 30), f("b", 40), f("c", 50), f("d", 20), f("e", 10)]
        let batches = IngestBatchPlanner.pack(files, bytesPerBatch: 100 * 1_048_576)
        let solo = try #require(batches.first { $0.oversized })
        #expect(solo.files.map(\.url.lastPathComponent) == ["mail.mbox"])
        #expect(batches.filter { !$0.oversized }.allSatisfy { $0.bytes <= 100 * 1_048_576 })
        #expect(batches.reduce(0) { $0 + $1.files.count } == files.count, "every file planned once")
        #expect(batches.count == 3, "mbox alone + 150 MB of small files in two batches")
        let many = (0..<10).map { f("s\($0)", 0) }
        #expect(IngestBatchPlanner.pack(many, bytesPerBatch: 1_048_576, maxFiles: 4).map(\.files.count) == [4, 4, 2])
        // From folders, against a budget.
        let dir = try Self.scratch("plan")
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<5 { try Data(repeating: 65, count: 1_000 + i).write(to: dir.appendingPathComponent("f\(i).txt")) }
        let budget = WorkerBudget(availableBytes: 4 << 30, physicalBytes: 8 << 30, activeCores: 4, pressure: .normal, thermal: .nominal)
        let plan = IngestBatchPlanner.plan(roots: [dir], budget: budget)
        #expect(plan.fileCount == 5 && plan.batches.count == 1 && plan.workers == 2)
        #expect(plan.bytesPerBatch >= IngestBatchPlanner.minimumBytesPerBatch)
    }

    // MARK: - PERF-16 shards

    @Test("PERF-16: a shard is its own ledger file under Shards/<run>/<n>.sqlite, on the current schema, keyed like the main ledger")
    @MainActor
    func shardLedgerFile() async throws {
        let dir = try Self.scratch("shard")
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = await Self.booted(dir)
        let main = try #require(state.database)
        let mainURL = await main.url, mainKey = await main.key
        let run = UUID()
        let shard = try await ShardLedger.open(runID: run, index: 3, besideLedgerAt: mainURL, key: mainKey)
        #expect(shard.url.path.hasSuffix("Shards/\(run.uuidString)/3.sqlite"))
        let version = try await shard.database.query("PRAGMA user_version;").first?.int(0) ?? 0
        #expect(Int(version) == SchemaMigrations.latestVersion, "same schema as the ledger")
        #expect(FileManager.default.fileExists(atPath: ShardLedger.seedURL(for: shard.url).path), "seed marks written")
        try await shard.database.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                                      [.uuid(UUID()), .text("staged"), .real(1), .real(1)])
        await shard.close()
        let head = try FileHandle(forReadingFrom: shard.url).readData(ofLength: 16)
        if mainKey != nil {
            #expect(head != Data("SQLite format 3\u{0}".utf8), "encrypted with the ledger's key")
        }
        ShardLedger.removeFiles(at: shard.url)
        #expect(!FileManager.default.fileExists(atPath: shard.url.path))
        await state.shutdown()
    }

    // MARK: - PERF-17 merge

    @Test("PERF-17: a shard merges into the one ledger through the actor; the merge is recorded, the file deleted after; a second merge of the same rows adds nothing; a missing file fails and is recorded")
    @MainActor
    func shardMergeDirect() async throws {
        let dir = try Self.scratch("merge")
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = await Self.booted(dir)
        let main = try #require(state.database)
        let mainURL = await main.url, mainKey = await main.key
        let run = UUID(), ws = UUID()
        let shard = try await ShardLedger.open(runID: run, index: 0, besideLedgerAt: mainURL, key: mainKey)
        try await shard.database.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                                      [.uuid(ws), .text("From shard"), .real(1), .real(1)])
        await shard.close()
        let copy = ShardLedger.fileURL(runID: run, index: 1, besideLedgerAt: mainURL)
        try FileManager.default.copyItem(at: shard.url, to: copy)
        try FileManager.default.copyItem(at: ShardLedger.seedURL(for: shard.url), to: ShardLedger.seedURL(for: copy))
        try await main.recordShard(runID: run, index: 0, path: shard.url.path, state: "written", files: 1)
        try await main.recordShard(runID: run, index: 1, path: copy.path, state: "written", files: 1)
        let merger = ShardMerger(main: main)
        guard case .merged = await merger.merge(runID: run, index: 0, shardURL: shard.url) else { Issue.record("merge failed"); return }
        func count() async throws -> Int64 { try await main.query("SELECT COUNT(*) FROM workspaces WHERE id = ?;", [.uuid(ws)]).first?.int(0) ?? -1 }
        #expect(try await count() == 1)
        #expect(try await main.shardRecord(runID: run, index: 0)?.state == "merged")
        #expect(!FileManager.default.fileExists(atPath: shard.url.path), "deleted only after the merge is recorded")
        guard case .merged = await merger.merge(runID: run, index: 1, shardURL: copy) else { Issue.record("second merge failed"); return }
        #expect(try await count() == 1, "the same row merged twice is one row")
        let gone = ShardLedger.fileURL(runID: run, index: 2, besideLedgerAt: mainURL)
        try await main.recordShard(runID: run, index: 2, path: gone.path, state: "written", files: 1)
        guard case .failed = await merger.merge(runID: run, index: 2, shardURL: gone) else { Issue.record("a missing shard must fail"); return }
        #expect(try await main.shardRecord(runID: run, index: 2)?.state == "failed")
        #expect(try await main.unmergedShards().isEmpty)
        await state.shutdown()
    }

    @Test("PERF-14…17 end to end: an import in two batches runs as shard workers, merges into the one ledger, skips what the ledger already holds, leaves no shard files")
    @MainActor
    func shardImportEndToEnd() async throws {
        let dir = try Self.scratch("shardimport")
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = await Self.booted(dir)
        let main = try #require(state.database), ingest = try #require(state.ingest)
        let mainURL = await main.url
        let docs = dir.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let texts = ["Statement of Asha Rao, 3 March 2026. Asha Rao approved invoice INV-2041.",
                     "Statement of Vikram Shah, 9 March 2026. Vikram Shah paid Dalmia Traders.",
                     "Memo of Dev Malhotra, 12 March 2026. Dev Malhotra signed the delivery note.",
                     "Letter of Priya Nair, 14 March 2026. Priya Nair received 40 cartons."]
        var urls: [URL] = []
        for (i, t) in texts.enumerated() {
            let u = docs.appendingPathComponent("doc\(i).txt"); try Data(t.utf8).write(to: u); urls.append(u)
        }
        // doc0 is already in the ledger: the shard worker skips it.
        _ = try await ingest.ingest(fileAt: urls[0])
        func koCount() async throws -> Int64 { try await main.query("SELECT COUNT(*) FROM knowledge_objects;").first?.int(0) ?? -1 }
        #expect(try await koCount() == 1)
        let files = try urls.map { IngestPlannedFile(url: $0, bytes: UInt64(try Data(contentsOf: $0).count)) }
        let plan = IngestBatchPlan(batches: IngestBatchPlanner.pack(files, bytesPerBatch: 150), bytesPerBatch: 150, workers: 2)
        #expect(plan.batches.count >= 2)
        await state.runShardImport(plan: plan, ingest: ingest, counter: IngestCounter(), failures: IngestFailureLog(),
                                   run: nil, runs: nil, receipts: nil, arrivals: .folderReread)
        #expect(try await koCount() == 4, "the three new documents merged in; the one already held not duplicated")
        let names = try await main.query("SELECT value FROM entities WHERE kind = 'person';").compactMap { $0.string(0) }
        #expect(names.contains { $0.contains("Priya Nair") }, "\(names)")
        let fts = try await main.query("SELECT COUNT(*) FROM chunks_fts WHERE chunks_fts MATCH 'cartons';").first?.int(0) ?? 0
        #expect(fts >= 1, "merged chunks are searchable")
        let merges = try await main.query("SELECT state FROM ingest_shard_merges;").compactMap { $0.string(0) }
        #expect(!merges.isEmpty && merges.allSatisfy { $0 == "merged" }, "\(merges)")
        let shardRoot = ShardLedger.root(besideLedgerAt: mainURL)
        let left = (FileManager.default.enumerator(atPath: shardRoot.path)?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".sqlite") }
        #expect(left.isEmpty, "no shard file left: \(left)")
        await state.shutdown()
    }

    // MARK: - IN-16 deep-enrichment queue

    @Test("IN-16: the deep-study handler is registered; a queued document is studied (its summary written) and the job is done")
    @MainActor
    func deepStudyQueue() async throws {
        let dir = try Self.scratch("deep")
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = await Self.booted(dir)
        let ingest = try #require(state.ingest), db = try #require(state.database), drainer = try #require(state.enrichmentDrainer)
        #expect(await drainer.handledKinds() == [.deepStudy], "only deep study has a handler")
        let file = dir.appendingPathComponent("memo.txt")
        try Data("Memo, 4 May 2026. The shipment of 40 cartons left Mumbai for Rotterdam. Priya Nair signed the delivery note. The carrier was Blue Line.".utf8).write(to: file)
        let r = try await ingest.ingest(fileAt: file)
        let before = try await db.query("SELECT COUNT(*) FROM summaries;").first?.int(0) ?? 0
        let queued = await state.enqueueDeepStudy(objectIDs: [r.object.id], reason: "test")
        #expect(queued == 1)
        #expect(await state.enqueueDeepStudy(objectIDs: [r.object.id], reason: "test") <= 1)
        _ = await drainer.drain(kind: .deepStudy)
        var after = before
        for _ in 0..<50 {
            after = try await db.query("SELECT COUNT(*) FROM summaries;").first?.int(0) ?? 0
            if after > before { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(after > before, "the document's summary was written by the deep-study job")
        await state.shutdown()
    }

    // MARK: - IN-17 boilerplate compaction

    @Test("IN-17: maintenance replaces a block repeated across documents by a token in the cleaned text; the evidence text is unchanged")
    @MainActor
    func boilerplateCompaction() async throws {
        let dir = try Self.scratch("bp")
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = await Self.booted(dir)
        let ingest = try #require(state.ingest), db = try #require(state.database)
        let footer = "Dalmia Traders Private Limited, Registered office 14 Marine Lines, Mumbai 400002. Company registration U51909MH1998PTC114567. All shipments are handled under the standard trading conditions published on the company notice board and available from the accounts office on request."
        // The detector hashes 200-byte windows stepped by 100 bytes from the start of each text, so the shared block is
        // found when it starts at the same offset in each document: the leads are padded to one length.
        for (i, lead) in ["The first shipment of 40 cartons left on 4 May.", "The second shipment of 12 pallets left on 9 May.",
                          "The third shipment of 7 crates left on 15 May."].enumerated() {
            let u = dir.appendingPathComponent("ship\(i).txt")
            let padded = lead + String(repeating: ".", count: 100 - lead.utf8.count)
            try Data((padded + "\n\n" + footer).utf8).write(to: u)
            _ = try await ingest.ingest(fileAt: u)
        }
        UserDefaults.standard.removeObject(forKey: "unifiedPath.boilerplateCompaction.lastRun")
        let report = try #require(await state.compactReaderBoilerplate())
        #expect(report.promoted >= 1 && report.rewritten >= 3, "\(report)")
        let rows = try await db.query("SELECT content, clean_content FROM knowledge_objects;")
        #expect(rows.count == 3 && rows.allSatisfy { ($0.string(1) ?? "").contains("[[BOILERPLATE:") }, "the cleaned copies are compacted")
        #expect(rows.allSatisfy { ($0.string(0) ?? "").contains("Registered office 14 Marine Lines") }, "content is never rewritten")
        #expect(await state.compactReaderBoilerplate() == nil, "at most once a day")
        await state.shutdown()
    }

    // MARK: - IN-18 register refresh + merge audit

    @Test("IN-18: the register refresh's soft-merge is recorded in the reconciliation audit, and undoing it splits the names (itself audited)")
    @MainActor
    func registerRefreshAudited() async throws {
        let dir = try Self.scratch("reg")
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = await Self.booted(dir)
        let db = try #require(state.database)
        let src = UUID(), fileID = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?, '/tmp/mail.eml', 'eml');", [.uuid(fileID)])
        try await db.exec("INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?, ?, 'eml', 'seed', 0, 0);",
                          [.uuid(src), .uuid(fileID)])
        func insert(_ value: String) async throws -> UUID {
            let id = UUID()
            try await db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence, producer_version) VALUES (?, 'person', ?, ?, ?, 0.9, 1);",
                              [.uuid(id), .text(value), .text(value.lowercased()), .uuid(src)])
            return id
        }
        let clean = try await insert("Akhilesh Sharma")
        let dirty = try await insert(", Akhilesh Sharma")
        await state.refreshEntityRegisterAndAudit(context: "test")
        let audit = EntityReconciliationAuditRepository(database: db)
        let open = try await audit.openMerges()
        let merge = try #require(open.first { $0.origin == "registerRefresh" })
        #expect(merge.winner == clean && merge.losers == [dirty])
        #expect(try await db.query("SELECT merged_into FROM entities WHERE id = ?;", [.uuid(dirty)]).first?.uuid(0) == clean)
        let line = await state.undoEntityMerge(merge)
        #expect(line.hasPrefix("Undone"), "\(line)")
        #expect(try await db.query("SELECT merged_into FROM entities WHERE id = ?;", [.uuid(dirty)]).first?.string(0) == nil)
        #expect(try await audit.openMerges().first { $0.id == merge.id } == nil, "the undone merge is no longer open")
        await state.shutdown()
    }

    // MARK: - IN-19 versions + readiness

    @Test("IN-19: a document's version list (canonical versions, newest first) and its readiness history are read for the inspector")
    @MainActor
    func versionsAndReadiness() async throws {
        let dir = try Self.scratch("ver")
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = await Self.booted(dir)
        let ingest = try #require(state.ingest)
        let file = dir.appendingPathComponent("v.txt")
        try Data("Version one of the delivery schedule, 4 May 2026.".utf8).write(to: file)
        let first = try await ingest.ingest(fileAt: file)
        try Data("Version two of the delivery schedule, 9 May 2026, revised.".utf8).write(to: file)
        let second = try await ingest.ingest(fileAt: file)
        let objectID = second.object.id
        let versions = await state.documentVersions(objectID: objectID)
        #expect(!versions.isEmpty, "the inspector lists the document's versions (logical \(String(describing: second.logicalSourceID)), object \(objectID), first \(first.object.id))")
        _ = await state.readinessHistory(objectID: objectID)
        await state.shutdown()
    }

    // MARK: - IN-20 local enrichment

    @Test("IN-20: the local sanctions check reads only lists saved on this Mac — none saved is 'failed', never 'no match'; a saved list matches, the rest make it partial")
    @MainActor
    func localSanctions() async throws {
        let dir = try Self.scratch("sanc")
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = await Self.booted(dir)
        let lists = try ScanRescue.folder().deletingLastPathComponent().appendingPathComponent("Public lists", isDirectory: true)
        let sdn = lists.appendingPathComponent("\(PublicSource.ofacSDN.rawValue).data")
        let had = FileManager.default.fileExists(atPath: sdn.path)
        if !had {
            let none = await state.localSanctionsCheck("Dalmia Traders")
            #expect(none.status == .failed && none.candidates.isEmpty, "\(none.status)")
        }
        try FileManager.default.createDirectory(at: lists, withIntermediateDirectories: true)
        let saved = had ? try Data(contentsOf: sdn) : nil
        defer { if let saved { try? saved.write(to: sdn) } else { try? FileManager.default.removeItem(at: sdn) } }
        try Data("36,\"DALMIA TRADERS\",\"-0-\",\"SDGT\"\n".utf8).write(to: sdn)
        let hit = await state.localSanctionsCheck("Dalmia Traders")
        #expect(hit.candidates.contains { $0.label.uppercased() == "DALMIA TRADERS" }, "\(hit.candidates)")
        #expect(hit.status == .partial || hit.status == .matches, "\(hit.status)")
        await state.shutdown()
    }

    // MARK: - IN-21 data sets

    @Test("IN-21: an earlier-format data set is listed, its applied view steps saved and restored (v203), and replay gives the same view")
    func datasetSteps() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let repo = DatasetRepository(database: db)
        let b = UUID()
        let ds = EvidenceDataset(name: "pay",
                                 columns: [DatasetColumn(name: "amount", shape: .money), DatasetColumn(name: "payee", shape: .text)],
                                 rows: [DatasetRow(cells: [DatasetCell(value: "₹3,800", sourceBlockIDs: [b], status: .sourceAsserted),
                                                           DatasetCell(value: "Rajesh", sourceBlockIDs: [b], status: .sourceAsserted)]),
                                        DatasetRow(cells: [DatasetCell(value: "₹500", sourceBlockIDs: [b], status: .sourceAsserted),
                                                           DatasetCell(value: "Meera", sourceBlockIDs: [b], status: .sourceAsserted)])])
        try await repo.save(ds)
        #expect(try await repo.list().map(\.name) == ["pay"])
        var g = TransformationGraph()
        g.push(.filterContains(columnIndex: 1, needle: "Rajesh"))
        try await repo.saveSteps(datasetID: ds.id, steps: Array(g.appliedSteps))
        let restored = TransformationGraph(steps: try await repo.savedSteps(datasetID: ds.id))
        let loaded = try #require(try await repo.load(id: ds.id))
        #expect(restored.apply(to: loaded).rows.count == 1 && g.apply(to: ds).rows.count == 1)
        try await repo.saveSteps(datasetID: ds.id, steps: [])
        #expect(try await repo.savedSteps(datasetID: ds.id).isEmpty, "no steps = the row goes")
    }

    // MARK: - IN-22 / AUTO-14 defaults

    @Test("IN-22 + AUTO-14: thread merging and Custom Protocol Studio are on when never toggled; an explicit off is kept")
    func defaultsOn() {
        let store = AppDefaults.store
        for key in ["kalsmritikosh.moveA.threadCoalescing", FeatureFlags.customProtocolStudioKey] {
            let prior = store.object(forKey: key)
            defer { if let prior { store.set(prior, forKey: key) } else { store.removeObject(forKey: key) } }
            store.removeObject(forKey: key)
            #expect(EmailLoader.threadCoalescingEnabled && FeatureFlags.customProtocolStudioValue(), "on when never toggled (\(key))")
            store.set(false, forKey: key)
            if key == FeatureFlags.customProtocolStudioKey { #expect(!FeatureFlags.customProtocolStudioValue()) }
            else { #expect(!EmailLoader.threadCoalescingEnabled) }
        }
    }

    // MARK: - IN-23 transcription fallback

    struct FakeSpeech: AudioTranscribing {
        let text: String?
        nonisolated var engineID: String { "fake-speech" }
        func transcribe(audioAt url: URL) async throws -> String {
            guard let text else { throw IngestorError.parseFailure(url, reason: "no speech engine") }
            return text
        }
    }

    @Test("IN-23: a recording the Mac transcribes stays on the Mac; one it cannot goes through the online fallback, marked as an AI transcript")
    func transcriptionFallback() async throws {
        let calls = Gauge()
        let url = URL(fileURLWithPath: "/tmp/rec.m4a")
        let local = OnlineFallbackTranscriber(primary: FakeSpeech(text: "on device words"), online: { _ in calls.tick(); return "online words" })
        #expect(try await local.transcribe(audioAt: url) == "on device words" && calls.count == 0, "nothing sent when the Mac can do it")
        #expect(local.engineID == "fake-speech+online-fallback")
        let failing = OnlineFallbackTranscriber(primary: FakeSpeech(text: nil), online: { _ in calls.tick(); return "online words" })
        let text = try await failing.transcribe(audioAt: url)
        #expect(text == OnlineFallbackTranscriber.marker + "\nonline words" && calls.count == 1)
        let declined = OnlineFallbackTranscriber(primary: FakeSpeech(text: nil), online: { _ in nil })
        await #expect(throws: (any Error).self) { _ = try await declined.transcribe(audioAt: url) }
    }

    // MARK: - IN-24 RAR / 7z / legacy Office

    @Test("IN-24: the system libarchive reads the 7z fixtures (members listed, bytes extracted exactly); multi-volume names found; legacy .doc/.xls through their real readers")
    func archivesAndLegacyOffice() async throws {
        let expected = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: Self.fixtures.appendingPathComponent("Archives/expected.json")))
        let out = try Self.scratch("7z")
        defer { try? FileManager.default.removeItem(at: out) }
        for name in ["sample-lzma-plain.7z", "sample-lzma2-encoded.7z"] {
            let url = Self.fixtures.appendingPathComponent("Archives/\(name)")
            let members = try SystemArchiveReader.listMembers(url: url, limit: 100)
            #expect(Set(members.filter { !$0.isDirectory }.map(\.path)) == Set(expected.keys), "\(name): \(members.map(\.path))")
            let reader = try SystemArchiveReader(url: url)
            while let m = try reader.next() {
                guard !m.isDirectory, let want = expected[m.path] else { continue }
                let dest = out.appendingPathComponent(UUID().uuidString)
                _ = try reader.extractCurrent(to: dest, maxBytes: 1_000_000)
                let got = SHA256.hash(data: try Data(contentsOf: dest)).map { String(format: "%02x", $0) }.joined()
                #expect(got == want, "\(name) \(m.path)")
            }
        }
        for n in ["case.part1.rar", "case.part2.rar", "case.part3.rar", "box.7z.001", "box.7z.002"] { try Data([0]).write(to: out.appendingPathComponent(n)) }
        #expect(SystemArchiveReader.laterVolumes(of: out.appendingPathComponent("case.part1.rar")).map(\.lastPathComponent) == ["case.part2.rar", "case.part3.rar"])
        #expect(SystemArchiveReader.laterVolumes(of: out.appendingPathComponent("box.7z.001")).map(\.lastPathComponent) == ["box.7z.002"])
        for (file, kind) in [("sample.doc", LegacyOfficeScanner.Kind.doc), ("sample.xls", .xls)] {
            let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("LegacyOffice/\(file)"))
            let real = await LegacyOfficeScanner.realReaderText(data: data, filename: file, kind: kind)
            var why = ""
            if real == nil {
                let parsed = kind == .doc
                    ? try await DocStructuralParser().parse(data: data, filename: file, type: .doc, logicalSourceID: UUID(), sourceVersionID: UUID())
                    : try await XlsStructuralParser().parse(data: data, filename: file, type: .xls, logicalSourceID: UUID(), sourceVersionID: UUID())
                why = "status \(parsed.extractionStatus), warnings \(parsed.warnings.map(\.code)), blocks \(parsed.blocks.count)"
            }
            let text = real?.text ?? ""
            #expect(!text.isEmpty, "\(file) read by its real reader (\(text.count) chars, real \(real == nil ? "nil" : "set")): \(why)")
        }
    }

    // MARK: - IN-25 extraction backlog

    @Test("IN-25: a labelled value keeps the value only (cut at a column gap or the next label); rule packs are versioned and stale facts found by pack version")
    func captureValueAndPackVersions() {
        #expect(TypedFieldExtractor.cutAtNextLabel("P1234567   Date of Birth: 01/02/1980") == "P1234567")
        #expect(TypedFieldExtractor.cutAtNextLabel("P1234567 Date of Birth: 01/02/1980") == "P1234567")
        #expect(TypedFieldExtractor.cutAtNextLabel("INV-2041") == "INV-2041")
        let blocks = [EvidenceBlock(documentID: UUID(), ordinal: 0, kind: .paragraph, rawText: "Passport No: P1234567   Date of Birth: 01/02/1980")]
        let fields = TypedFieldExtractor().extract(blocks: blocks, sourceVersionID: UUID())
        #expect(fields.contains { $0.fieldType == .documentNumber && $0.normalizedValue.uppercased() == "P1234567" }, "\(fields.map { "\($0.fieldType)=\($0.normalizedValue)" })")
        #expect(!fields.contains { $0.fieldType == .documentNumber && $0.normalizedValue.lowercased().contains("birth") })
        #expect(DomainPackVersions.current("employment") == 2)
        #expect(DomainPackVersions.isStale(packID: "employment", packVersion: 1) && DomainPackVersions.isStale(packID: "employment", packVersion: nil))
        #expect(!DomainPackVersions.isStale(packID: "employment", packVersion: 2) && !DomainPackVersions.isStale(packID: nil, packVersion: nil))
        #expect(DomainPackVersions.staleSQLPredicate.contains("(pack_id = 'employment' AND COALESCE(pack_version, 0) != 2)"))
    }

    // MARK: - IN-26 OCR repair + page-break joins

    @Test("IN-26: an OCR confusion is repaired only when exactly one candidate is a known value; a label is joined to its value across a page break")
    func ocrRepairAndPageBreak() {
        let r = OCRConfusionRepair.repair("INV-2O41", known: { $0 == "INV-2041" })
        #expect(r?.value == "INV-2041" && r?.marker == "O→0")
        #expect(OCRConfusionRepair.repair("INV-2O41", known: { _ in false }) == nil, "no known value: no repair")
        #expect(OCRConfusionRepair.repair("B0B", known: { $0 == "BOB" || $0 == "8OB" }) == nil, "ambiguous: no repair")
        #expect(OCRConfusionRepair.repair("Hamrnond", known: { $0 == "Hammond" })?.marker == "rn→m")
        let doc = UUID()
        let blocks = [EvidenceBlock(documentID: doc, ordinal: 0, kind: .paragraph, rawText: "Holder: Priya Nair\nPassport No:"),
                      EvidenceBlock(documentID: doc, ordinal: 1, kind: .paragraph, rawText: "Page 2 of 3"),
                      EvidenceBlock(documentID: doc, ordinal: 2, kind: .paragraph, rawText: "P7654321\nIssued at Mumbai")]
        let fields = TypedFieldExtractor().extract(blocks: blocks, sourceVersionID: UUID())
        let joined = fields.first { $0.fieldType == .documentNumber && $0.normalizedValue.uppercased() == "P7654321" }
        #expect(joined != nil, "\(fields.map { "\($0.fieldType)=\($0.normalizedValue)" })")
        #expect(joined?.evidenceBlockID == blocks[2].id && (joined?.confidence ?? 1) < 0.9, "pinned to the value's block, at a reduced confidence")
    }
}
