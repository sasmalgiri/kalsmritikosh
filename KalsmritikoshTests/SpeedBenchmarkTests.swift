//
//  SpeedBenchmarkTests.swift
//  KalsmritikoshTests
//
//  Speed program PERF-33 (owner 2026-11-23, docs/SPEED_PROGRAM_2026-11-23.md) — the before/after benchmark of the
//  app's data-heavy processes, on a GENERATED corpus (SpeedBenchCorpus) in a throwaway ledger. Never the owner's ledger.
//
//  The full run is OFF unless SPEED_BENCH=1 reaches the test process (xcodebuild forwards TEST_RUNNER_SPEED_BENCH=1)
//  or the git-ignored trigger file build/perf/RUN_SPEED_BENCH exists (a run from Xcode, which passes no variables), so
//  CI never runs it. Size: SPEED_BENCH_SIZE=small|medium, or the trigger file's first word (default small).
//
//  Phases, each timed with the process's peak physical footprint (phys_footprint, sampled every 250 ms):
//    import        the folder through the app's own entry (BookmarkStore.register + AppState.ingestAllRoots, as the
//                  Add Folder button does), files/min;
//    embeddings    what the import left without a vector, drained by IngestCoordinator.drainEmbeddingsNow, vectors/s;
//    ledger        the ledger drain and the boot backfills (LedgerDrainCoordinator, chunk reindex, subject spine, term
//                  salience, topic tree, email participants, claim projection), each timed;
//    indexes       HNSW build (in memory) and IVF rebuild (disk), from the stored vectors;
//    backup        ledger snapshot + complete backup write + verify (BackupService.inspect);
//    contradictions  the case contradiction check's document load and rules over 400 documents;
//    retrieval     20 questions: HybridRetriever over every layer, and the whole Brain answer, p50/p95;
//    data lab      the Data Lab grid's per-redraw work over a 20,000-row dataset (headless);
//    AI case read  a 6-part case read through OnlineCloudProvider and the network helper door, the helper replaced by
//                  a scripted stand-in with 300 ms latency: requests, helper launches, XPC connections, total time.
//
//  The sandboxed host cannot write into the repository: the JSON and markdown are printed between
//  ===SPEED_BENCH_BEGIN <name>=== / ===SPEED_BENCH_END=== markers and also written to SPEED_BENCH_OUT (when set) and
//  to <tmp>/speed-bench-report/. The generated corpus and ledger are removed at the end of the run.
//

import Foundation
import os
import Testing
@testable import Kalsmritikosh

private let speedBenchTrigger: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("build/perf/RUN_SPEED_BENCH")

private let speedBenchEnabled: Bool = {
    if ProcessInfo.processInfo.environment["SPEED_BENCH"] == "1" { return true }
    return FileManager.default.fileExists(atPath: speedBenchTrigger.path)
}()

private func speedBenchSize() -> SpeedBenchCorpusSize {
    if let s = ProcessInfo.processInfo.environment["SPEED_BENCH_SIZE"], !s.isEmpty { return .named(s) }
    let word = (try? String(contentsOf: speedBenchTrigger, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").first.map(String.init)
    return .named(word)
}

/// Samples phys_footprint every 250 ms while a phase runs; the peak is kept.
nonisolated final class FootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private var samples = 0
    private var task: Task<Void, Never>?

    func start() {
        note()
        task = Task.detached(priority: .high) { [self] in
            while !Task.isCancelled {
                self.note()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func note() {
        let b = ProcessFootprint.bytes()
        lock.withLock { peak = max(peak, b); samples += 1 }
    }

    func stop() -> (peak: UInt64, samples: Int) {
        task?.cancel()
        note()
        return lock.withLock { (peak, samples) }
    }
}

/// One measured phase.
nonisolated struct SpeedBenchPhase: Codable, Sendable {
    var name: String
    var seconds: Double
    var startFootprintMB: Double
    var peakFootprintMB: Double
    var samples: Int
    var metrics: [String: Double] = [:]
    var notes: [String] = []
}

nonisolated struct SpeedBenchReport: Codable, Sendable {
    var environment: [String: String]
    var corpus: SpeedBenchCorpusManifest
    var phases: [SpeedBenchPhase]
}

/// Counts what the scripted helper stand-in received.
nonisolated final class SpeedBenchAICounter: @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0, inFlight = 0, maxInFlight = 0
    func enter() { lock.withLock { requests += 1; inFlight += 1; maxInFlight = max(maxInFlight, inFlight) } }
    func leave() { lock.withLock { inFlight -= 1 } }
    var snapshot: (requests: Int, maxInFlight: Int) { lock.withLock { (requests, maxInFlight) } }
}

@MainActor
@Suite("Speed program PERF-33 — benchmark over a generated corpus", .serialized)
struct SpeedBenchmarkTests {

    static let mb = 1_048_576.0

    /// Run `body` as one phase: wall time and peak footprint.
    static func phase(_ name: String, _ body: (inout SpeedBenchPhase) async throws -> Void) async rethrows -> SpeedBenchPhase {
        let sampler = FootprintSampler()
        let start = Double(ProcessFootprint.bytes()) / mb
        var p = SpeedBenchPhase(name: name, seconds: 0, startFootprintMB: start, peakFootprintMB: start, samples: 0)
        sampler.start()
        let t = DispatchTime.now().uptimeNanoseconds
        do {
            try await body(&p)
        } catch {
            let s = sampler.stop()
            p.peakFootprintMB = Double(s.peak) / mb
            KalsmritikoshLog.app.error("Speed bench phase \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw error
        }
        p.seconds = Double(DispatchTime.now().uptimeNanoseconds - t) / 1e9
        let s = sampler.stop()
        p.peakFootprintMB = Double(s.peak) / mb
        p.samples = s.samples
        print("SPEED_BENCH phase \(name): \(String(format: "%.2f", p.seconds)) s, peak \(String(format: "%.0f", p.peakFootprintMB)) MB, \(p.metrics)")
        return p
    }

    static func ms(_ body: () async throws -> Void) async rethrows -> Double {
        let t = DispatchTime.now().uptimeNanoseconds
        try await body()
        return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
    }

    /// The ANN dimension exactly as AppState.performBoot chooses it.
    static func indexDimension(_ modelID: String) -> Int { modelID == "bge-small.v1" ? 384 : NLEmbedder().dimension }

    static func count(_ db: Database, _ table: String) async -> Double {
        do { return Double(try await db.query("SELECT COUNT(*) FROM \(table);", []).first?.int(0) ?? 0) } catch {
            KalsmritikoshLog.app.error("Speed bench: count \(table, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return -1
        }
    }

    // MARK: - The questions

    static let questions: [String] = [
        "When did Ann Lee approve the payment for the warehouse lease?",
        "How much was paid to Bluefin Logistics?",
        "Who signed the contract for the freight contract?",
        "What did Rahul Mehta say about the audit fee?",
        "Which invoices did Northwind Supplies Ltd send?",
        "Was the supplier rebate paid twice?",
        "Who met Priya Nair in Singapore?",
        "What amount did Harbor Bank transfer to Apex Holdings?",
        "When was the software licence contract signed?",
        "Who forwarded the invoice from Crescent Engineering?",
        "What happened with the insurance claim at Granite Insurance?",
        "Which payments did Wei Chen approve?",
        "What did Maria Gomez discuss in London?",
        "How much was paid for the site renovation?",
        "Who is Fatima Khan?",
        "What was the loan repayment amount to Redwood Capital?",
        "When did Kestrel Construction receive payment?",
        "Who asked whether the consulting retainer was paid twice?",
        "What did Orchid Pharma pay for the equipment purchase?",
        "Summarise the dealings between Summit Advisory and Pioneer Freight.",
    ]

    // MARK: - Data Lab (headless): the grid's per-redraw work, exactly as DataLabView computes it

    static func dataLabPhase() async -> SpeedBenchPhase {
        await phase("data lab: 20,000-row dataset, grid redraw") { p in
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            let ds = UUID()
            let dataset = WorkbenchDataset(id: ds, workspaceID: UUID(), title: "Bench ledger", mode: .advanced, revision: 1, createdAt: t0, updatedAt: t0)
            let names = ["date", "payer", "payee", "amount", "invoice"]
            let fields = names.enumerated().map { WorkbenchField(id: UUID(), datasetID: ds, name: $1, valueShape: .text, ordinal: $0, createdAt: t0) }
            var r = SpeedBenchRandom(seed: 0xDA7A_1AB)
            var rows: [WorkbenchRow] = [], cells: [WorkbenchCell] = []
            let rowCount = 20_000
            rows.reserveCapacity(rowCount); cells.reserveCapacity(rowCount * fields.count)
            var buildMS = 0.0
            buildMS = await ms {
                for i in 0..<rowCount {
                    let row = WorkbenchRow(id: UUID(), datasetID: ds, ordinal: i, createdAt: t0)
                    rows.append(row)
                    let values = [SpeedBenchCorpus.date(&r), r.pick(SpeedBenchCorpus.orgs), r.pick(SpeedBenchCorpus.orgs),
                                  SpeedBenchCorpus.amount(&r), "INV-\(10_000 + r.int(90_000))"]
                    for (k, f) in fields.enumerated() {
                        cells.append(WorkbenchCell(id: UUID(), datasetID: ds, rowID: row.id, fieldID: f.id, kind: .sourceValue,
                                                   value: values[k], status: .directlyObserved, createdAt: t0))
                    }
                }
            }
            let rec = WorkbenchDatasetRecord(dataset: dataset, fields: fields, rows: rows.shuffled(using: &r), cells: cells,
                                             bindings: [], savedViews: [], events: [])
            // An active scenario with 50 overrides and 20 row exclusions (the view's activeProjection()).
            var ops: [WorkbenchScenarioOperation] = []
            for k in 0..<70 {
                let row = rows[(k * 271) % rows.count]
                ops.append(WorkbenchScenarioOperation(id: UUID(), scenarioID: UUID(), sequence: k + 1,
                                                      kind: k < 50 ? .valueOverride : .rowExclusion, targetKind: k < 50 ? .cell : .row,
                                                      rowID: row.id, fieldID: k < 50 ? fields[3].id : nil, beforeValue: nil,
                                                      afterValue: k < 50 ? "$1.00" : nil, reason: "bench", status: .live, actor: "bench", createdAt: t0))
            }
            // Speed test phase (PERF-31, 2026-11-23): the grid's per-redraw work exactly as DataLabView now does it — the
            // projection, row order and cell map come from its DataLabMemo (built once per change), and a projected value
            // is a keyed lookup.
            let memo = DataLabMemo()
            let scenarioID = UUID()
            var projection: WorkbenchScenarioProjection?
            let projectionMS = await ms { projection = memo.projection(record: rec, scenarioID: scenarioID, ops: ops) }
            // orderedVisibleRows: sort by ordinal, then drop excluded rows (the projection comes from the memo).
            var visible: [WorkbenchRow] = []
            let orderMS = await ms {
                var rs = rec.rows.sorted { $0.ordinal < $1.ordinal }
                let proj = memo.projection(record: rec, scenarioID: scenarioID, ops: ops)
                rs = rs.filter { !proj.excludedRows.contains($0.id) }
                visible = rs
            }
            // grid(): the cell-by-key dictionary (memoised).
            var cellByKey: [String: WorkbenchCell] = [:]
            let keyMS = await ms { cellByKey = memo.cellMap(rec) }
            // gridCell(): per cell, activeProjection() (memo hit) and the projected value. Every visible cell is timed
            // when the run allows (the full grid), else a sample extrapolated.
            let gridCells = Double(visible.count * fields.count)
            let sample = visible.count * fields.count
            var shown = 0
            let cellMS = await ms {
                for i in 0..<sample {
                    let row = visible[i / fields.count], field = fields[i % fields.count]
                    let proj = memo.projection(record: rec, scenarioID: scenarioID, ops: ops)
                    let key = "\(row.id.uuidString)|\(field.id.uuidString)"
                    let display = proj.projectedValue(rowID: row.id, fieldID: field.id) ?? cellByKey[key]?.value
                    if display != nil { shown += 1 }
                }
            }
            p.metrics["projection builds during the redraw"] = Double(memo.projectionBuilds)
            let perCell = cellMS / Double(max(1, sample))
            p.metrics["rows"] = Double(rowCount)
            p.metrics["cells"] = Double(rec.cells.count)
            p.metrics["dataset build ms (generator, not app work)"] = buildMS
            p.metrics["projection build ms (once)"] = projectionMS
            p.metrics["orderedVisibleRows ms"] = orderMS
            p.metrics["cellByKey ms"] = keyMS
            p.metrics["per-cell gridCell work ms (sampled \(sample))"] = perCell
            p.metrics["full grid redraw ms (measured: every one of \(Int(gridCells)) cells)"] = cellMS + orderMS + keyMS
            p.notes.append("Headless: the computations DataLabView.grid/gridCell/orderedVisibleRows make, not SwiftUI layout or rendering.")
            p.notes.append("After PERF-31: the projection and cell map come from DataLabMemo (built once per change) and a base value is a keyed lookup; every visible cell was timed (no extrapolation). The baseline rebuilt the projection per cell and scanned every base cell per read (300 cells timed, extrapolated).")
            #expect(shown == sample && projection != nil)
        }
    }

    // MARK: - The 6-part AI case read (scripted helper, 300 ms)

    static func aiCaseReadPhase(db: Database) async throws -> SpeedBenchPhase {
        try await phase("AI: 6-part case read, scripted helper (300 ms)") { p in
            // 30 documents of ~6,000 tokens each; the part budget packs them into 6 parts.
            var r = SpeedBenchRandom(seed: 0xCA5E_2EAD)
            var docs: [CaseReader.Document] = []
            var versions: [UUID: Set<UUID>] = [:]
            for i in 0..<30 {
                var t = ""
                while CaseReader.estimatedTokens([t]) < 6_000 { t += SpeedBenchCorpus.paragraph(&r, i) + "\n\n" }
                let o = UUID(), v = UUID()
                versions[o] = [v] as Set<UUID>
                docs.append(CaseReader.Document(objectID: o, sourceVersionID: v, fileName: "case-doc-\(i).txt", text: t))
            }
            let total = CaseReader.estimatedTokens(docs.map(\.text))
            // Five documents per part: 30 documents → 6 parts.
            let largest = docs.map { CaseReader.estimatedTokens([$0.text]) }.max() ?? 6_000
            let parts = CaseReader.parts(docs, budgetTokens: largest * 5 + 5)
            let caseID = UUID()
            let ordered = versions
            let binding = CloudScopeBinding(scopeID: caseID) { ordered }
            let clearance = await CloudSourceGate(resolve: { _ in .resolved(ProtectionLabel(sensitivity: .internalLevel, privileged: false)) },
                                                  legacyPrivileged: { [] }).bound(to: binding).clear(docs.map(\.objectID), purpose: "case.reading").clearance
            let snapshot = OnlineSnapshot(cloudAllowed: true, kind: .anthropic, model: "bench-model", apiKey: "bench-key",
                                          confirmedDocumentTerms: OnlineProviderKind.anthropic.documentTermsVersion, dailyByteCap: nil)
            let permissions = CaseReadPermissionStore.inMemory()
            permissions.grant(caseID: caseID, fingerprint: CaseReadPermission.fingerprint(caseID: caseID, versions: clearance.versions), documentCount: docs.count)
            // The production transport: the network helper door. Its helper process is the scripted stand-in.
            var seams = OnlineCloudProvider.Seams(settings: { snapshot }, consent: { _ in false }, transport: { try await NetworkHelperClient.send($0) })
            seams.casePermission = { id, fp in permissions.isGranted(caseID: id, fingerprint: fp) }
            seams.ownKeyRefusal = { _ in nil }
            seams.ownKeyTally = { _, _ in }
            seams.ownKeyBatchTally = { _, _ in }
            let provider = OnlineCloudProvider(outboundLog: OutboundLogRepository(database: db), knownNames: { [] }, seams: seams)
            let counter = SpeedBenchAICounter()
            let quote = String(docs[0].text.prefix(80))
            let inner = try String(decoding: JSONSerialization.data(withJSONObject: [
                "status": "answered", "answer": "A payment was approved.",
                "claims": [["text": "A payment was approved.", "quote": quote, "document": 1]]]), as: UTF8.self)
            let reply = try JSONSerialization.data(withJSONObject: [
                "content": [["type": "text", "text": inner]],
                "usage": ["input_tokens": 10, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0, "output_tokens": 5]])
            NetworkHelperDebugCounters.reset()
            NetworkHelperDebugCounters.setStandIn { _ in
                counter.enter(); defer { counter.leave() }
                try await Task.sleep(for: .milliseconds(300))
                return OutboundHTTPResponse(status: 200, body: reply)
            }
            defer { NetworkHelperDebugCounters.setStandIn(nil) }
            let reader = CaseReader { send in
                let out = try await provider.readCase(send)
                return CaseReader.Reply(text: out.text, usage: out.usage)
            }
            let concurrency = WorkerBudget.current().workers(perWorkerBytes: 64 * 1_048_576)
            let prefixes = parts.enumerated().map { CaseReader.partPrefix(briefing: "", documents: docs, part: $1, index: $0, count: parts.count) }
            var look: String?
            let readMS = try await ms {
                let out = try await reader.readCase(parts: prefixes, question: "Was the supplier paid twice?", related: [],
                                                    context: .init(concurrency: concurrency)) { prefix, suffix in
                    try await reader.send(CaseReadSend(caseID: caseID, prefix: prefix, suffix: suffix, ttl: .fiveMinutes,
                                                       purpose: "case.question", clearance: clearance))
                }
                look = out.secondLook
            }
            let c = NetworkHelperDebugCounters.snapshot
            let s = counter.snapshot
            p.metrics["parts"] = Double(parts.count)
            p.metrics["case tokens (estimated)"] = Double(total)
            p.metrics["path concurrency (WorkerBudget)"] = Double(concurrency)
            p.metrics["requests at the helper door"] = Double(c.requests)
            p.metrics["requests the scripted helper answered"] = Double(s.requests)
            p.metrics["max requests in flight"] = Double(s.maxInFlight)
            p.metrics["helper process launches"] = Double(c.helperLaunches)
            p.metrics["XPC connections"] = Double(c.connections)
            p.metrics["second look ran"] = look == nil ? 0 : 1
            p.metrics["total read ms"] = readMS
            p.metrics["ms per request (wall / requests)"] = s.requests > 0 ? readMS / Double(s.requests) : 0
            p.notes.append("Scripted helper: 300 ms per request, nothing leaves the Mac. The stand-in takes the helper's place inside NetworkHelperClient.sendViaHelper, after the door's own checks; launches and connections are counted where that function makes them (one of each per request in this code).")
            #expect(c.requests == s.requests && s.requests >= parts.count && parts.count == 6)
        }
    }

    // MARK: - Smoke (always runs; cheap)

    @Test("PERF-33 smoke (always): the generator is deterministic and writes every kind; the footprint sampler reads")
    func smoke() async throws {
        let tiny = SpeedBenchCorpusSize(label: "tiny", documents: 6, emailsPerSmallMailbox: 2, emailsInLargeMailbox: 2, largeMailboxBytes: 20_000,
                                        pdfs: 2, longPDFs: 1, longPDFPages: 3, imageOnlyPDFs: 1, csvs: 1, csvRows: 5, zipMembers: 3)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("speedbench-smoke-\(UUID().uuidString)", isDirectory: true)
        defer {
            do { try FileManager.default.removeItem(at: base) } catch {
                KalsmritikoshLog.app.error("Speed bench smoke: cleanup failed: \(String(describing: error), privacy: .public)")
            }
        }
        let a = try SpeedBenchCorpus.generate(tiny, into: base.appendingPathComponent("a"))
        let b = try SpeedBenchCorpus.generate(tiny, into: base.appendingPathComponent("b"))
        #expect(a.files == 6 + 3 + 3 + 1 + 1 && a.files == b.files && a.bytes == b.bytes)
        #expect(Set(a.byKind.keys) == ["md", "txt", "mbox", "pdf", "pdf-image", "csv", "zip"])
        let pdfA = try Data(contentsOf: base.appendingPathComponent("a/pdf/report-0.pdf"))
        #expect(pdfA.starts(with: Data("%PDF".utf8)))
        #expect(ProcessFootprint.bytes() > 0)
    }

    // MARK: - The full run

    @Test("PERF-33 full benchmark over a generated corpus (SPEED_BENCH=1 or build/perf/RUN_SPEED_BENCH only)",
          .enabled(if: speedBenchEnabled), .timeLimit(.minutes(60)))
    func fullBenchmark() async throws {
        let size = speedBenchSize()
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("speedbench-\(UUID().uuidString)", isDirectory: true)
        let corpusURL = base.appendingPathComponent("corpus", isDirectory: true)
        let ledgerDir = base.appendingPathComponent("ledger", isDirectory: true)
        try fm.createDirectory(at: ledgerDir, withIntermediateDirectories: true)
        let loadStart = CaseMapPerf.loadAverage()
        print("SPEED_BENCH start: size \(size.label), folder \(base.path)")

        var phases: [SpeedBenchPhase] = []
        var manifest = SpeedBenchCorpusManifest(size: size)
        let gen = try await Self.phase("generate corpus (not app work)") { p in
            manifest = try SpeedBenchCorpus.generate(size, into: corpusURL)
            p.metrics["files"] = Double(manifest.files)
            p.metrics["MB"] = Double(manifest.bytes) / Self.mb
        }
        phases.append(gen)

        // Speed torrent test phase (2026-11-23): the content cache (PERF-34) as the app runs it — the ledger's own store.
        ContentResults.TestOverride.ledgerStoreInTestHost.withLock { $0 = true }
        defer { ContentResults.TestOverride.ledgerStoreInTestHost.withLock { $0 = false } }
        let state = AppState(bookmarks: BookmarkStore(ephemeral: true))
        await state.boot(databaseURL: ledgerDir.appendingPathComponent("bench.sqlite"), suppressAutoReingest: true)
        guard case .ready = state.phase, let ingest = state.ingest, let db = state.database, let objects = state.objects,
              let vectors = state.vectorStore, let entities = state.entities, let events = state.events,
              let facts = state.genericFacts, let evidence = state.evidenceStore, let chunks = state.chunks else {
            Issue.record("the bench ledger did not boot")
            return
        }

        // 1. Import through the app's own folder entry.
        let shardPlanned = await state.shardImportPlan(for: [corpusURL]) != nil
        try state.bookmarks.register(url: corpusURL)
        // The background embedding drain is held during the import (the pressure pause, which the import does not reset)
        // so the import and the embedding drain are measured apart; the drain phase then embeds every chunk.
        await ingest.setPressurePaused(true)
        let importPhase = await Self.phase("import: folder through ingestAllRoots") { p in
            let succeeded = await ImportAIPermission.$scope.withValue(ImportAIPermission.Grant(allowed: false)) {
                await state.ingestAllRoots()
            }
            p.metrics["files in corpus"] = Double(manifest.files)
            p.metrics["files reported read"] = Double(succeeded)
            p.metrics["failures"] = Double(state.lastIngestSummary?.failures.count ?? 0)
        }
        var imp = importPhase
        imp.metrics["files/min"] = Double(manifest.files) / max(imp.seconds, 0.001) * 60
        imp.metrics["MB/min"] = Double(manifest.bytes) / Self.mb / max(imp.seconds, 0.001) * 60
        imp.metrics["shard workers used"] = shardPlanned ? 1 : 0
        Self.noteReadLanes(&imp)
        for t in ["files", "knowledge_objects", "chunks", "entities", "events", "generic_facts", "chunk_embeddings"] {
            imp.metrics["rows: \(t)"] = await Self.count(db, t)
        }
        imp.notes.append("Includes what ingestAllRoots runs after the files (topic build, post-ingest checks). The background embedding drain was held (pressure pause) so vectors are measured in the next phase.")
        phases.append(imp)

        // 2. Embedding drain of whatever the import left.
        await ingest.stopEmbeddingDrain()
        await ingest.setPressurePaused(false)
        let before = (try? await vectors.count()) ?? 0
        var emb = await Self.phase("embeddings: drain what the import left") { _ in await ingest.drainEmbeddingsNow() }
        let after = (try? await vectors.count()) ?? 0
        emb.metrics["vectors before"] = Double(before)
        emb.metrics["vectors after"] = Double(after)
        emb.metrics["vectors/s"] = Double(after - before) / max(emb.seconds, 0.001)
        emb.metrics["chunks still missing a vector"] = Double((try? await chunks.countChunksMissingVector(modelID: vectors.embeddingModelID)) ?? -1)
        emb.notes.append("Embedder: \(vectors.embeddingModelID) (index dimension \(Self.indexDimension(vectors.embeddingModelID))).")
        phases.append(emb)

        // 3. Ledger drain and the boot backfills, each timed.
        let ledger = try await Self.phase("ledger: drain + backfills") { p in
            p.metrics["LedgerDrainCoordinator.drain ms"] = try await Self.ms {
                _ = try await LedgerDrainCoordinator(database: db, objects: objects, entities: entities, events: events,
                                                     facts: facts, evidence: evidence).drain()
            }
            // Vector gap (owner 2026-11-23) — not tested yet: the reindex drops the embeddings of the chunks it re-cuts or
            // re-prefixes (the background drain re-embeds them in the app); record how many so the index phase can explain it.
            var reindex = ChunkReindexReceipt()
            p.metrics["ChunkReindexCoordinator ms"] = try await Self.ms { reindex = try await ChunkReindexCoordinator(database: db).run() }
            p.metrics["reindex: embeddings dropped (packed + split)"] = Double(reindex.embeddingsDropped)
            p.metrics["reindex: template prefixes stamped"] = Double(reindex.prefixesStamped)
            p.metrics["SubjectSpine ms"] = try await Self.ms { _ = try await SubjectSpine(database: db).run() }
            p.metrics["TermSalienceComputer ms"] = try await Self.ms { _ = try await TermSalienceComputer(database: db).run() }
            p.metrics["TopicTreeBuilder ms"] = try await Self.ms { _ = try await TopicTreeBuilder(database: db).run() }
            p.metrics["EmailParticipantBackfill ms"] = await Self.ms {
                _ = await EmailParticipantBackfill(occurrences: EmailParticipantRepository(database: db), entities: entities, database: db).run(pageSize: 10_000)
            }
            if let projection = state.claimProjection {
                p.metrics["ClaimProjectionBackfill ms"] = await Self.ms { await projection.run(at: Date()) }
            }
            p.notes.append("The drain runs without the schema inducer (no model call). On a fresh import most rows are current, so these are the per-pass costs of an up-to-date ledger.")
        }
        phases.append(ledger)

        // Vector gap (owner 2026-11-23) — not tested yet. The baseline indexed 752 of 1,010 vectors: the paging was not the
        // cause (IVF reads by rowid keyset, HNSW by listAll, both saw 752). The ledger phase's ChunkReindexCoordinator re-cut
        // and re-prefixed chunks and DELETED their embeddings (the app's background drain re-embeds them; the bench had
        // stopped that drain), so 258 vectors were gone before the index phase. Re-drain here so the indexes cover every
        // chunk, and record the counts so a gap shows.
        let vectorsAfterLedger = (try? await vectors.count()) ?? 0
        let reembedStarted = Date()
        await ingest.drainEmbeddingsNow()
        let reembedMs = Date().timeIntervalSince(reembedStarted) * 1000
        let vectorsAtIndex = (try? await vectors.count()) ?? 0

        // 4. Vector indexes.
        let dimension = Self.indexDimension(vectors.embeddingModelID)
        let idx = try await Self.phase("indexes: HNSW build + IVF rebuild") { p in
            let hnsw = HNSWVectorIndex()
            var loaded = 0
            p.metrics["HNSW build ms"] = await Self.ms { loaded = await hnsw.build(from: vectors).vectorsLoaded }
            p.metrics["HNSW vectors"] = Double(loaded)
            p.metrics["vectors after the ledger phase (before re-embed)"] = Double(vectorsAfterLedger)
            p.metrics["re-embed of reindexed chunks ms"] = reembedMs
            p.metrics["vectors stored at index time"] = Double(vectorsAtIndex)
            let repo = ANNIndexRepository(database: db)
            try await repo.ensureMeta(modelID: vectors.embeddingModelID, dimension: dimension, at: Date())
            let ivf = IVFDiskVectorIndex(repository: repo, modelID: vectors.embeddingModelID, dimension: dimension)
            p.metrics["IVF rebuild ms"] = try await Self.ms { try await ivf.rebuild(seed: 0x516B_5F9E_A3C1_D7B2) }
            p.metrics["IVF vectors"] = Double(await ivf.size())
            // Speed test phase (2026-11-23): the first after-run indexed 0 IVF vectors in 3 ms — the stored vector sizes
            // (IVF skips rows whose size is not the index dimension) and the meta state say why.
            if let rows = try? await db.query("SELECT length(q), COUNT(*) FROM chunk_embeddings WHERE model_id = ? GROUP BY 1;",
                                              [.text(vectors.embeddingModelID)]) {
                for r in rows { p.metrics["stored vectors of \(r.int(0) ?? -1) bytes"] = Double(r.int(1) ?? 0) }
            }
            if let types = try? await db.query("SELECT typeof(scale), typeof(q), COUNT(*) FROM chunk_embeddings WHERE model_id = ? GROUP BY 1, 2;",
                                               [.text(vectors.embeddingModelID)]) {
                p.notes.append("Stored vector column types: " + types.map { "scale \($0.string(0) ?? "?") / q \($0.string(1) ?? "?") × \($0.int(2) ?? -1)" }.joined(separator: ", "))
            }
            p.metrics["IVF input: embeddingCount"] = Double((try? await repo.embeddingCount(for: vectors.embeddingModelID)) ?? -1)
            p.metrics["IVF input: first page rows"] = Double((try? await repo.embeddingPage(for: vectors.embeddingModelID, afterRowid: 0, limit: 4096).count) ?? -1)
            if let meta = try? await db.query("SELECT model_id, state, cell_count FROM ann_index_meta;", []) {
                p.notes.append("ANN meta after the rebuild: " + meta.map { "\($0.string(0) ?? "?")=\($0.string(1) ?? "?")/\($0.int(2) ?? -1) cells" }.joined(separator: ", "))
            }
        }
        phases.append(idx)

        // 5. Backup write + verify.
        let backupDir = base.appendingPathComponent("backup", isDirectory: true)
        let bak = try await Self.phase("backup: snapshot + complete backup + verify") { p in
            let scratch = base.appendingPathComponent("backup-scratch", isDirectory: true)
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
            let snap = scratch.appendingPathComponent("knowledge.sqlite")
            p.metrics["ledger snapshot ms"] = try await Self.ms { try await db.backupSnapshot(to: snap) }
            var originals: [(fileID: UUID, url: URL)] = [], missing: [String] = [], hashes: [UUID: String] = [:]
            for row in try await db.query("SELECT id, url, content_hash FROM files;", []) {
                guard let id = row.uuid(0), let url = row.string(1).flatMap(URL.init(string:)) else { continue }
                if let h = row.string(2) { hashes[id] = h }
                if url.isFileURL, fm.isReadableFile(atPath: url.path) { originals.append((id, url)) } else { missing.append(url.absoluteString) }
            }
            var manifestOut: BackupManifest?
            p.metrics["complete backup write ms"] = try await Self.ms {
                manifestOut = try BackupService().createCompleteBackup(
                    databaseSnapshot: snap, originals: originals, notIncluded: missing, destination: backupDir,
                    schemaVersion: SchemaMigrations.latestVersion, nowEpoch: Date().timeIntervalSince1970,
                    besideLedger: ledgerDir, expectedHashes: hashes, signingKey: nil)
            }
            var ok = false
            p.metrics["verify (inspect) ms"] = try await Self.ms { ok = try BackupService().inspect(backupFolder: backupDir).verdict.ok }
            var bytes: Int64 = 0
            if let e = fm.enumerator(at: backupDir, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let u as URL in e { bytes += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            }
            p.metrics["backup MB"] = Double(bytes) / Self.mb
            p.metrics["originals copied"] = Double(originals.count)
            p.metrics["entries"] = Double(manifestOut?.entries.count ?? 0)
            p.metrics["verified ok"] = ok ? 1 : 0
            do { try fm.removeItem(at: scratch) } catch {
                KalsmritikoshLog.app.error("Speed bench: scratch cleanup failed: \(String(describing: error), privacy: .public)")
            }
        }
        phases.append(bak)
        do { try fm.removeItem(at: backupDir) } catch {
            KalsmritikoshLog.app.error("Speed bench: backup cleanup failed: \(String(describing: error), privacy: .public)")
        }

        // 6. Case contradiction check over 400 documents.
        let con = try await Self.phase("contradictions: 400-document case") { p in
            let rows = try await db.query("""
                SELECT sv.id FROM source_versions sv WHERE sv.is_current = 1
                  AND EXISTS (SELECT 1 FROM knowledge_objects k WHERE k.id = sv.document_id OR k.file_id = sv.logical_source_id)
                ORDER BY sv.id LIMIT 400;
                """, [])
            var ids = Set(rows.compactMap { $0.uuid(0) })
            if ids.count < 400 {
                ids.formUnion(try await db.query("SELECT id FROM source_versions WHERE is_current = 1 ORDER BY id LIMIT 400;", []).compactMap { $0.uuid(0) })
            }
            let versions = ids
            var docs: [CaseContradictionFinder.Document] = []
            p.metrics["document load ms"] = try await Self.ms {
                docs = try await AppState.caseContradictionDocuments(objects: objects, versions: versions, from: 0)
            }
            var found = 0
            let snapshot = docs
            p.metrics["rules ms"] = await Self.ms { found = CaseContradictionFinder.ruleFindings(snapshot).count }
            p.metrics["source versions"] = Double(versions.count)
            p.metrics["documents compared"] = Double(docs.count)
            p.metrics["findings"] = Double(found)
        }
        phases.append(con)

        // 7. Retrieval latency: 20 questions.
        let ret = await Self.phase("retrieval: 20 questions") { p in
            guard let retriever = state.retriever else { p.notes.append("no retriever"); return }
            let brain = state.brain
            let access = SensitiveAccessContext(scope: .globalOwnerRetrieval())
            var retrieve: [Double] = [], answer: [Double] = []
            var refused = 0
            for q in Self.questions {
                let intent = (try? await RuleIntentDetector().detect(question: q)) ?? UserIntent(kind: .factualLookup, scope: .global, rawQuestion: q)
                let t = await Self.ms {
                    do { _ = try await retriever.retrieve(for: intent, layers: RetrievalLayer.allCases) } catch {
                        KalsmritikoshLog.app.error("Speed bench: retrieval failed: \(String(describing: error), privacy: .public)")
                    }
                }
                retrieve.append(t)
                var a: VerifiedAnswer?
                answer.append(await Self.ms { a = await brain.answer(question: q, access: access) })
                if a?.refused == true { refused += 1 }
            }
            p.metrics["retrieve p50 ms"] = CaseMapPerf.percentile(retrieve, 0.5)
            p.metrics["retrieve p95 ms"] = CaseMapPerf.percentile(retrieve, 0.95)
            p.metrics["answer p50 ms"] = CaseMapPerf.percentile(answer, 0.5)
            p.metrics["answer p95 ms"] = CaseMapPerf.percentile(answer, 0.95)
            p.metrics["answers refused"] = Double(refused)
            p.notes.append("retrieve = HybridRetriever over every layer; answer = MasterBrain.answer (the whole ask, AI not configured in the bench).")
        }
        phases.append(ret)

        // 8. Data Lab.
        phases.append(await Self.dataLabPhase())

        // 9. The AI case read.
        phases.append(try await Self.aiCaseReadPhase(db: db))

        // Report.
        var env: [String: String] = [
            "machine": CaseMapPerf.sysctlString("hw.model"),
            "chip": CaseMapPerf.sysctlString("machdep.cpu.brand_string"),
            "cores": "\(CaseMapPerf.sysctlInt("hw.ncpu"))",
            "performance cores": "\(CaseMapPerf.sysctlInt("hw.perflevel0.physicalcpu"))",
            "efficiency cores": "\(CaseMapPerf.sysctlInt("hw.perflevel1.physicalcpu"))",
            "RAM GB": String(format: "%.0f", Double(CaseMapPerf.sysctlInt("hw.memsize")) / 1_073_741_824),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "build": "Debug test host (XCTest process)",
            "build_sha": CaseMapPerf.buildSHA(),
            "schema": "\(SchemaMigrations.latestVersion)",
            "measured_utc": ISO8601DateFormatter().string(from: Date()),
            "size": size.label,
            "load average at start (1/5/15)": loadStart.map { String(format: "%.1f", $0) }.joined(separator: "/"),
            "load average at end (1/5/15)": CaseMapPerf.loadAverage().map { String(format: "%.1f", $0) }.joined(separator: "/"),
        ]
        // The ledger file and its WAL on disk (the PRAGMA page count read 0 through the encrypted connection in the baseline run).
        let ledgerFiles = ["bench.sqlite", "bench.sqlite-wal"].map { ledgerDir.appendingPathComponent($0).path }
        let ledgerBytes = ledgerFiles.reduce(Int64(0)) { $0 + ((try? fm.attributesOfItem(atPath: $1)[.size] as? Int64) ?? 0) }
        env["ledger MB"] = String(format: "%.1f", Double(ledgerBytes) / Self.mb)
        let report = SpeedBenchReport(environment: env, corpus: manifest, phases: phases)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = String(decoding: try enc.encode(report), as: UTF8.self)
        let md = Self.markdown(report)
        print("===SPEED_BENCH_BEGIN report.json===\n" + json + "\n===SPEED_BENCH_END===")
        print("===SPEED_BENCH_BEGIN report.md===\n" + md + "===SPEED_BENCH_END===")
        var outs = [fm.temporaryDirectory.appendingPathComponent("speed-bench-report", isDirectory: true)]
        if let o = ProcessInfo.processInfo.environment["SPEED_BENCH_OUT"], !o.isEmpty { outs.append(URL(fileURLWithPath: o, isDirectory: true)) }
        for dir in outs {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try json.write(to: dir.appendingPathComponent("speed-bench-\(size.label).json"), atomically: true, encoding: .utf8)
                try md.write(to: dir.appendingPathComponent("speed-bench-\(size.label).md"), atomically: true, encoding: .utf8)
                print("SPEED_BENCH report written to \(dir.path)")
            } catch {
                KalsmritikoshLog.app.error("Speed bench: report not written to \(dir.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        // Clean up: the app first, then its folder (corpus, ledger).
        await state.shutdown()
        do { try fm.removeItem(at: base) } catch {
            KalsmritikoshLog.app.error("Speed bench: cleanup failed: \(String(describing: error), privacy: .public)")
        }
        print("SPEED_BENCH removed \(base.path): \(!fm.fileExists(atPath: base.path))")
        #expect(imp.metrics["files reported read", default: 0] > 0)
    }

    // MARK: - The re-import run (speed torrent test phase, PERF-34/35)

    /// The same generated corpus with its large mailbox at 14 MB (a piece map needs ≥ 12 MiB; the plain small corpus's is 10 MB).
    static let reimportSize = SpeedBenchCorpusSize(label: "small-reimport", documents: 400, emailsPerSmallMailbox: 10, emailsInLargeMailbox: 40,
                                                   largeMailboxBytes: 14_000_000, pdfs: 40, longPDFs: 1, longPDFPages: 50, imageOnlyPDFs: 2,
                                                   csvs: 10, csvRows: 400, zipMembers: 50)

    /// PERF-38: each disk lane's width and best measured bytes/s after a phase.
    static func noteReadLanes(_ p: inout SpeedBenchPhase) {
        for l in VolumeReadLanes.snapshot() {
            p.metrics["read lane \(l.profile.kind.rawValue): width now"] = Double(l.limit)
            p.metrics["read lane \(l.profile.kind.rawValue): best MB/s"] = l.bytesPerSecond / mb
        }
    }

    static func sql(_ db: Database, _ q: String) async -> Double {
        Double((try? await db.query(q, []).first?.int(0)) ?? -1)
    }

    @Test("PERF-34/35 re-import benchmark: a fresh import, the same corpus re-scanned, then edited copies of every document plus the large mailbox grown (SPEED_BENCH=1 or build/perf/RUN_SPEED_BENCH only)",
          .enabled(if: speedBenchEnabled), .timeLimit(.minutes(60)))
    func reimportBenchmark() async throws {
        let size = Self.reimportSize
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("speedbench-reimport-\(UUID().uuidString)", isDirectory: true)
        let corpusURL = base.appendingPathComponent("corpus", isDirectory: true)
        let ledgerDir = base.appendingPathComponent("ledger", isDirectory: true)
        try fm.createDirectory(at: ledgerDir, withIntermediateDirectories: true)
        let loadStart = CaseMapPerf.loadAverage()
        print("SPEED_BENCH reimport start: folder \(base.path)")
        var phases: [SpeedBenchPhase] = []
        var manifest = SpeedBenchCorpusManifest(size: size)
        phases.append(try await Self.phase("generate corpus (not app work)") { p in
            manifest = try SpeedBenchCorpus.generate(size, into: corpusURL)
            p.metrics["files"] = Double(manifest.files)
            p.metrics["MB"] = Double(manifest.bytes) / Self.mb
        })
        ContentResults.TestOverride.ledgerStoreInTestHost.withLock { $0 = true }
        defer { ContentResults.TestOverride.ledgerStoreInTestHost.withLock { $0 = false } }
        let state = AppState(bookmarks: BookmarkStore(ephemeral: true))
        await state.boot(databaseURL: ledgerDir.appendingPathComponent("bench.sqlite"), suppressAutoReingest: true)
        guard case .ready = state.phase, let ingest = state.ingest, let db = state.database, let vectors = state.vectorStore else {
            Issue.record("the bench ledger did not boot")
            return
        }
        try state.bookmarks.register(url: corpusURL)
        func caches() async -> [String: Double] {
            [
                "content cache: OCR entries": await Self.sql(db, "SELECT COUNT(*) FROM content_result_cache WHERE kind = 'ocr';"),
                "content cache: typed-field entries": await Self.sql(db, "SELECT COUNT(*) FROM content_result_cache WHERE kind = 'typedFields';"),
                "content cache: origins (derived or reused by a document)": await Self.sql(db, "SELECT COUNT(*) FROM content_result_origins;"),
                "embedding cache rows": await Self.sql(db, "SELECT COUNT(*) FROM embedding_cache;"),
                "vectors": Double((try? await vectors.count()) ?? -1),
                "source versions": await Self.sql(db, "SELECT COUNT(*) FROM source_versions;"),
                "piece maps": await Self.sql(db, "SELECT COUNT(*) FROM source_piece_maps;"),
                // PERF-35 (owner 2026-11-23): kept mailbox message decodes; PERF-28: vectors of another size under a label.
                "content cache: mail message decodes": await Self.sql(db, "SELECT COUNT(*) FROM content_result_cache WHERE kind = 'mailMessage';"),
                "vectors of another size under the active label (PERF-28)": Double((try? await vectors.mislabeledCount()) ?? -1),
                "vectors under the fallback label": await Self.sql(db, "SELECT COUNT(*) FROM chunk_embeddings WHERE model_id = 'apple.nl.v1';"),
            ]
        }
        func importPhase(_ name: String) async -> SpeedBenchPhase {
            await ingest.setPressurePaused(true)
            let before = await caches()
            var p = await Self.phase(name) { p in
                let n = await ImportAIPermission.$scope.withValue(ImportAIPermission.Grant(allowed: false)) { await state.ingestAllRoots() }
                p.metrics["files reported read"] = Double(n)
                p.metrics["failures"] = Double(state.lastIngestSummary?.failures.count ?? 0)
            }
            let after = await caches()
            for (k, v) in after { p.metrics["\(k) (+ during)"] = v - (before[k] ?? 0) }
            Self.noteReadLanes(&p)
            await ingest.stopEmbeddingDrain()
            await ingest.setPressurePaused(false)
            return p
        }
        func embedPhase(_ name: String) async -> SpeedBenchPhase {
            let before = await caches()
            var p = await Self.phase(name) { _ in await ingest.drainEmbeddingsNow() }
            let after = await caches()
            let added = (after["vectors"] ?? 0) - (before["vectors"] ?? 0)
            let computed = (after["embedding cache rows"] ?? 0) - (before["embedding cache rows"] ?? 0)
            p.metrics["vectors added"] = added
            p.metrics["vectors computed (new embedding-cache rows)"] = computed
            p.metrics["vectors reused from the embedding cache"] = max(0, added - computed)
            return p
        }

        // 1. Fresh.
        var fresh = await importPhase("fresh import: folder through ingestAllRoots")
        fresh.metrics["MB/min"] = Double(manifest.bytes) / Self.mb / max(fresh.seconds, 0.001) * 60
        phases.append(fresh)
        phases.append(await embedPhase("fresh embeddings: drain"))

        // 2. The same corpus again, unchanged (a folder re-read).
        phases.append(await importPhase("re-import 1: the same corpus re-read, unchanged"))

        // 3. Edited copies of every text/markdown document (one line added at the end: new bytes, the same paragraphs) and
        //    the large mailbox grown by 25 messages (a watched mailbox that received mail).
        let docs = corpusURL.appendingPathComponent("docs", isDirectory: true)
        let copies = corpusURL.appendingPathComponent("docs-received-again", isDirectory: true)
        var copied = 0, copiedBytes: Int64 = 0
        for u in ((fm.enumerator(at: docs, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []) where ["txt", "md"].contains(u.pathExtension) {
            let rel = String(u.path.dropFirst(docs.path.count + 1))
            let dst = copies.appendingPathComponent(rel)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            let d = try Data(contentsOf: u) + Data("\nReceived again from the second custodian on 2026-11-23.\n".utf8)
            try d.write(to: dst)
            copied += 1; copiedBytes += Int64(d.count)
        }
        let mailbox = corpusURL.appendingPathComponent("mail/archive-large.mbox")
        let oldMailboxBytes = Int64((try fm.attributesOfItem(atPath: mailbox.path)[.size] as? Int) ?? 0)
        var appended = ""
        for i in 0..<25 {
            appended += "From new\(i)@example.com Mon Jan  1 00:00:00 2024\nFrom: New Sender \(i) <new\(i)@example.com>\nTo: Desk <desk@example.com>\n"
            appended += "Subject: New mail \(i)\nDate: Mon, 23 Nov 2026 10:\(String(format: "%02d", i)):00 +0000\nMessage-ID: <reimport-\(i)@example.com>\n\n"
            appended += "A new message number \(i) about invoice INV-\(3000 + i) for INR \(1000 * (i + 1)).\n\n"
        }
        let h = try FileHandle(forWritingTo: mailbox)
        try h.seekToEnd(); try h.write(contentsOf: Data(appended.utf8)); try h.close()
        try? await Task.sleep(for: .seconds(1))   // a new modification time for the folder re-read
        var r2 = await importPhase("re-import 2: edited copies of \(copied) documents + the large mailbox grown by 25 messages")
        r2.metrics["copied documents"] = Double(copied)
        r2.metrics["copied MB"] = Double(copiedBytes) / Self.mb
        r2.metrics["mailbox MB before"] = Double(oldMailboxBytes) / Self.mb
        // The piece map of the grown mailbox against its previous version.
        let maps = (try? await db.query("""
            SELECT piece_bytes, file_bytes, piece_digests, record_offsets, record_digests FROM source_piece_maps
            WHERE logical_source_id IN (SELECT logical_source_id FROM source_piece_maps GROUP BY logical_source_id HAVING COUNT(*) >= 2)
            ORDER BY created_at;
            """, [])) ?? []
        if maps.count >= 2, let pb = maps[0].int(0), let ob = maps[0].int(1), let od = maps[0].string(2), let nd = maps[1].string(2) {
            let old = od.split(separator: ","), new = nd.split(separator: ",")
            var same = 0
            while same < min(old.count, new.count), old[same] == new[same] { same += 1 }
            let oldOffsets = PieceMaps.offsets(maps[0].blob(3))
            let proven = oldOffsets.count >= 2 ? (0..<(oldOffsets.count - 1)).filter { oldOffsets[$0 + 1] + 5 <= ob }.count : 0
            r2.metrics["piece map: pieces of the previous version unchanged"] = Double(same)
            r2.metrics["piece map: previous version pieces"] = Double(old.count)
            r2.metrics["piece map: proven unchanged MB (whole pieces)"] = Double(Int64(same) * pb) / Self.mb
            r2.metrics["mailbox: previous message ranges kept"] = Double(oldOffsets.count)
            r2.metrics["mailbox: message ranges taken from the index (not scanned)"] = Double(proven)
            // PERF-35: the previous version's message fingerprints; a proven message with one has its decode reused.
            let oldDigests = PieceMaps.digests(maps[0].blob(4), offsets: oldOffsets)
            let reusable = oldOffsets.count >= 2 ? (0..<(oldOffsets.count - 1)).filter { oldOffsets[$0 + 1] + 5 <= ob && oldDigests[oldOffsets[$0]] != nil }.count : 0
            r2.metrics["mailbox: previous message fingerprints kept"] = Double(oldDigests.count)
            r2.metrics["mailbox: message decodes reused (proven + fingerprint kept)"] = Double(reusable)
            r2.metrics["mailbox: messages parsed (new version's messages − reused)"] = Double(PieceMaps.offsets(maps[1].blob(3)).count - reusable)
        } else {
            r2.notes.append("No second piece map was kept for the grown mailbox (\(maps.count) row(s)): the delta could not be measured.")
        }
        phases.append(r2)
        phases.append(await embedPhase("re-import 2 embeddings: drain"))

        var env: [String: String] = [
            "machine": CaseMapPerf.sysctlString("hw.model"), "chip": CaseMapPerf.sysctlString("machdep.cpu.brand_string"),
            "cores": "\(CaseMapPerf.sysctlInt("hw.ncpu"))", "build": "Debug test host (XCTest process)", "build_sha": CaseMapPerf.buildSHA(),
            "schema": "\(SchemaMigrations.latestVersion)", "measured_utc": ISO8601DateFormatter().string(from: Date()), "size": size.label,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "load average at start (1/5/15)": loadStart.map { String(format: "%.1f", $0) }.joined(separator: "/"),
            "load average at end (1/5/15)": CaseMapPerf.loadAverage().map { String(format: "%.1f", $0) }.joined(separator: "/"),
        ]
        env["content cache"] = "the ledger's own store (as the app)"
        env["embedding health at end (PERF-28)"] = EmbeddingHealth.line ?? "healthy"
        let report = SpeedBenchReport(environment: env, corpus: manifest, phases: phases)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = String(decoding: try enc.encode(report), as: UTF8.self)
        print("===SPEED_BENCH_BEGIN reimport.json===\n" + json + "\n===SPEED_BENCH_END===")
        print("===SPEED_BENCH_BEGIN reimport.md===\n" + Self.markdown(report) + "===SPEED_BENCH_END===")
        await state.shutdown()
        do { try fm.removeItem(at: base) } catch {
            KalsmritikoshLog.app.error("Speed bench: cleanup failed: \(String(describing: error), privacy: .public)")
        }
        print("SPEED_BENCH removed \(base.path): \(!fm.fileExists(atPath: base.path))")
        #expect(fresh.metrics["files reported read", default: 0] > 0)
    }

    // MARK: - Markdown

    static func markdown(_ r: SpeedBenchReport) -> String {
        var s = "# Speed benchmark (PERF-33) — \(r.environment["size"] ?? "")\n\n"
        s += "Generated by `KalsmritikoshTests/SpeedBenchmarkTests.swift` over the generated corpus of `KalsmritikoshTests/Support/SpeedBenchCorpus.swift` in a throwaway ledger (never the owner's).\n\n"
        s += "## Machine\n\n| Item | Value |\n|---|---|\n"
        for k in r.environment.keys.sorted() { s += "| \(k) | \(r.environment[k] ?? "") |\n" }
        let c = r.corpus
        s += "\n## Corpus\n\n\(c.files) files, \(String(format: "%.1f", Double(c.bytes) / mb)) MB: "
        s += c.byKind.keys.sorted().map { "\($0) \(c.byKind[$0] ?? 0) (\(String(format: "%.1f", Double(c.bytesByKind[$0] ?? 0) / mb)) MB)" }.joined(separator: ", ")
        s += "; \(c.emails) emails, \(c.pdfPages) PDF pages, \(c.csvRows) CSV rows, \(c.zipMembers) ZIP members.\n\n"
        s += "## Phases\n\n| Phase | Wall time | Peak footprint | Start footprint |\n|---|---|---|---|\n"
        for p in r.phases {
            s += String(format: "| %@ | %.2f s | %.0f MB | %.0f MB |\n", p.name, p.seconds, p.peakFootprintMB, p.startFootprintMB)
        }
        for p in r.phases {
            s += "\n### \(p.name)\n\n| Metric | Value |\n|---|---|\n"
            for k in p.metrics.keys.sorted() {
                let v = p.metrics[k] ?? 0
                s += "| \(k) | \(v == v.rounded() && abs(v) < 1e12 ? String(Int(v)) : String(format: "%.2f", v)) |\n"
            }
            for n in p.notes { s += "\n- \(n)" }
            if !p.notes.isEmpty { s += "\n" }
        }
        s += "\n## Limits\n\n- Debug (unoptimised) test host in the XCTest process, not a signed Release app; one run, no repeats.\n"
        s += "- The boot ran with suppressAutoReingest (the eval isolation), so no boot-time maintenance overlaps the phases; the import's own after-work does run.\n"
        s += "- Peak footprint is the whole test process (phys_footprint sampled every 250 ms), not the phase alone.\n"
        s += "- The AI phase uses a scripted helper stand-in (300 ms per request); no network was used.\n"
        return s
    }
}
