//
//  BaselineCaptureHarness.swift
//  KalsmritikoshTests
//
//  Phase 0b closeout — the rc13 regression baseline (v1.1 program). Captures
//  the answers the SHIPPED tree (c1b0623) produces on the owner's REAL ledger,
//  through the exact UI entry path (`brain.answer(question:access:)`,
//  AskView.swift:809) — not a lower API, because the rc12 defect lived in that
//  gap. The live ledger is only READ (VACUUM INTO a throwaway copy); the copy
//  is booted by the full real AppState (ephemeral bookmarks → no re-ingest).
//  The artifact is self-describing and deterministic (stable question order,
//  sorted-key JSON, header with tree hash + schema/DB identity) so a diff many
//  phases from now is attributable, not archaeology.
//
//  Tooling only — never the app target. Run single-clone (parallel destinations
//  double CPU contention and skew the latency table):
//    TEST_RUNNER_BASELINE_TREE_HASH=<stamp> xcodebuild test \
//      -only-testing:KalsmritikoshTests/BaselineCaptureHarness \
//      -parallel-testing-enabled NO
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Baseline capture (rc13 = c1b0623 regression anchor)", .serialized)
@MainActor
struct BaselineCaptureHarness {

    /// The exact tree the capture ran against, passed in at invocation, so the
    /// artifact header is attributable rather than a stale constant. xcodebuild
    /// only forwards env vars prefixed `TEST_RUNNER_` to the test-host process
    /// (the bare var stamped "unknown" on the first capture attempt), so invoke:
    ///   TEST_RUNNER_BASELINE_TREE_HASH=<stamp> xcodebuild test ...
    static let treeHash = ProcessInfo.processInfo.environment["BASELINE_TREE_HASH"] ?? "unknown"

    /// Fixed, ordered — the order is part of the artifact contract. Spread
    /// across promise rows: slot (Q1), the NF/grant-date case, entity profile
    /// (Q2), aggregate (Q4), existence (Q8), out-of-scope (Q0).
    static let questions: [String] = [
        "what is the granted patent number",
        "what is the application number",
        "on which date was the patent granted",
        "who is Shirshendu Sasmal",
        "how many hearings were there",
        "is there any invoice from Khurana and Khurana",
        "what is the capital of France",
    ]

    struct Record: Codable {
        let question: String
        let refused: Bool
        let confidence: Double
        let intentKind: String?
        let answerText: String?
        let body: String
        let citationCount: Int
        let citations: [String]
        /// Per-question wall-clock — the I-6 "before" latency table. This
        /// capture is the only chance to record the pre-fix cost.
        let secondsWallClock: Double
        /// The ask-start ledger-state stamp (C-ii) — like-stamp comparison
        /// is adjudicated per QUESTION, not per artifact. Optional so older
        /// artifacts decode.
        let ledgerState: Int64?
    }
    struct Drain: Codable {
        let embedderDimension: Int
        let sampleCount: Int
        let sourceBytes: Int
        let seconds: Double
        let embeddingsPerSecond: Double
        let estGBPerHour: Double
        /// Which provider actually served (disposition 1: the rc0 artifact's
        /// dim=300 was CapabilityResolvedEmbedder.dimension — pinned to the
        /// NLEmbedder fallback — not the provider that answered). Optional so
        /// the rc0 artifact still decodes.
        let providerID: String?
    }
    struct Header: Codable {
        let treeHash: String
        let schemaVersion: Int
        let capturedAtISO: String
        let dbCopyRowCounts: [String: Int]
        /// True when the capture awaited drain-quiescence + a discarded
        /// warm-up ask before the question set — the STEADY-STATE baseline
        /// (I-6 splits first-answer-after-launch vs steady-state). Optional
        /// so the rc0 (unquiesced, first-answer) artifact still decodes.
        let quiesced: Bool?
        /// The pinned freshness clock (KALSMRITIKOSH_REFERENCE_NOW, epoch
        /// seconds) the answers were computed against — part of the seal's
        /// identity; without it, time-sensitive confidences drift between
        /// runs and cross-time comparisons smear (unit-A binding #3).
        let referenceNowEpoch: String?
        /// What this baseline blesses: DETERMINISM, not quality. Content
        /// quality is governed separately by V0's recorded reds, which
        /// flip on their own schedule (owner binding, reseal ruling).
        let blesses: String?
        /// The confidence representation contract (nondeterminism class 5):
        /// confidences are canonically rounded at source to this precision,
        /// so "byte-identical" includes the scalar by construction. Travels
        /// with the seal so every future comparison knows what it includes.
        let confidencePrecision: String?
    }
    struct Artifact: Codable {
        let header: Header
        let records: [Record]
        let drain: Drain?
    }

    /// QUIESCENCE-IN-FACT, shared by capture/parity/probe: drain enrichment,
    /// then repeat the discarded warm-up ask until its wall clock settles
    /// under `threshold` (boot rebuild no longer starving retrieval), capped
    /// at `maxRounds`. Returns whether it settled.
    static func quiesceInFact(state: AppState, label: String,
                              threshold: TimeInterval = 10, maxRounds: Int = 12) async -> Bool {
        _ = await state.enrichmentDrainer?.drainAll()
        // A6 (parity finding #3): the BOOT MAINTENANCE PASS writes on the
        // fresh ledger copy (drain to current eras, twins to frontier-empty,
        // tree build). The asks must not race it — poll every frontier to
        // ZERO before the first question, so all stamps read the same
        // post-maintenance world (like-stamp-to-like-stamp).
        if let db = state.database {
            for poll in 0..<240 {   // cap ~20 min; the pass is minutes on 716 docs
                let row = (try? await db.query("""
                SELECT (SELECT COUNT(*) FROM generic_facts WHERE COALESCE(producer_version,0) != \(DerivedProducerVersions.facts)),
                       (SELECT COUNT(*) FROM events WHERE COALESCE(producer_version,0) != \(DerivedProducerVersions.events)),
                       (SELECT COUNT(*) FROM entities WHERE COALESCE(producer_version,0) != \(DerivedProducerVersions.entities)),
                       (SELECT COUNT(*) FROM entities e WHERE e.kind IN ('person','organization') AND e.merged_into IS NULL
                          AND NOT EXISTS (SELECT 1 FROM fact_reviews fr WHERE fr.subject_id = e.id AND fr.reviewer = 'twin.entity')),
                       (SELECT COUNT(*) FROM knowledge_objects ko
                          WHERE NOT EXISTS (SELECT 1 FROM fact_reviews fr WHERE fr.subject_id = ko.id AND fr.reviewer = 'twin.event'));
                """, []).first)
                let parts = (0..<5).map { Int(row?.int($0) ?? 0) }
                let open = parts.reduce(0, +)
                if open == 0 { print("\(label) QUIESCE: maintenance frontiers empty after \(poll) poll(s)"); break }
                if poll % 15 == 0 { print("\(label) QUIESCE: \(open) open (facts \(parts[0]) · events \(parts[1]) · entities \(parts[2]) · twinE \(parts[3]) · twinK \(parts[4]))") }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        for round in 0..<maxRounds {
            let t0 = Date()
            _ = await state.brain.answer(
                question: "warmup discard",
                access: SensitiveAccessContext(scope: .globalOwnerRetrieval()))
            let secs = Date().timeIntervalSince(t0)
            print("\(label) QUIESCE round \(round): warm-up \(String(format: "%.1f", secs))s")
            if secs < threshold { return true }
        }
        return false
    }

    /// Poll the watched tables until two consecutive polls agree — async
    /// between-ask writers have landed. Capped; sub-second when quiet.
    static func settleBetweenAsks(db: Database?) async {
        guard let db else { return }
        var last = -1
        for _ in 0..<60 {
            let counts = (try? await db.liveQuery(
                "SELECT (SELECT COUNT(*) FROM memory_objects) + (SELECT COUNT(*) FROM answer_revision_events) + (SELECT COUNT(*) FROM generic_facts) + (SELECT COUNT(*) FROM events)", []))?.first?.int(0)
            let now = Int(counts ?? -2)
            if now == last { return }
            last = now
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    @Test("Capture rc13 answers on the real ledger → deterministic artifact")
    func captureBaseline() async throws {
        // Operator-invoked ONLY: without the tree-hash stamp this must skip.
        // On hosted CI earlier suite tests create a ledger at the default
        // location, so a file-existence check alone does NOT gate — the
        // harness then captures the runner's fixture ledger and the rung-1
        // anchor assert fails (adcd4b7's hosted run). The stamp doubles as
        // the invocation switch.
        guard Self.treeHash != "unknown" else {
            print("BASELINE: no TEST_RUNNER_BASELINE_TREE_HASH — operator capture only; skipping (CI path).")
            return
        }
        let liveURL = DatabaseLocations.defaultDatabaseURL
        guard FileManager.default.fileExists(atPath: liveURL.path) else {
            print("BASELINE: no live ledger at \(liveURL.path) — nothing to anchor; skipping.")
            return
        }

        // 1) VACUUM INTO a throwaway copy — live ledger is READ only.
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("baseline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let copyURL = workDir.appendingPathComponent("ledger-copy.sqlite")
        do {
            let src = try Database(url: liveURL)
            let escaped = copyURL.path.replacingOccurrences(of: "'", with: "''")
            try await src.exec("VACUUM main INTO '\(escaped)';", [])
            await src.close()
        }
        print("BASELINE: VACUUM copy at \(copyURL.path)")

        // Row-count identity of the copy (deterministic fingerprint of what we captured).
        var counts: [String: Int] = [:]
        do {
            let c = try Database(url: copyURL)
            for (k, sql) in [
                ("knowledge_objects", "SELECT COUNT(*) FROM knowledge_objects"),
                ("chunks", "SELECT COUNT(*) FROM chunks"),
                ("chunk_embeddings", "SELECT COUNT(*) FROM chunk_embeddings"),
                ("generic_facts", "SELECT COUNT(*) FROM generic_facts"),
                ("entities", "SELECT COUNT(*) FROM entities"),
                ("events", "SELECT COUNT(*) FROM events"),
            ] {
                counts[k] = Int((try await c.query(sql, [])).first?.int(0) ?? 0)
            }
            await c.close()
        }

        // 2) Boot the FULL real AppState against the copy. Ephemeral bookmarks →
        //    no watched roots → no re-ingest that could change the copy under us.
        let state = AppState(bookmarks: BookmarkStore(ephemeral: true))
        await state.boot(databaseURL: copyURL)
        guard case .ready = state.phase else {
            await state.shutdown()
            Issue.record("AppState failed to boot against the copy (phase=\(state.phase))")
            return
        }

        // 2b) QUIESCENCE-IN-FACT (owner redefinition, per the 301s stage-table
        //     spec): drainAll() returns BEFORE the boot rebuild tasks finish
        //     (HNSW/community/causal — the in-RAM writers class-4b named), so
        //     a single warm-up does not guarantee quiescence. True quiescence
        //     is SELF-MEASURED: repeat the discarded warm-up ask until its
        //     wall clock falls under the settled threshold — boot work no
        //     longer starves foreground retrieval — capped so a regression
        //     can't hang the harness.
        let quiesce = ProcessInfo.processInfo.environment["BASELINE_QUIESCE"] == "1"
        if quiesce {
            let settled = await Self.quiesceInFact(state: state, label: "BASELINE")
            if !settled { Issue.record("quiescence did not settle within the round cap — boot work still starving retrieval") }
        }

        // 3) Ask the fixed set through the exact UI entry path.
        var records: [Record] = []
        for q in Self.questions {
            let t0 = Date()
            let a = await state.brain.answer(
                question: q,
                access: SensitiveAccessContext(scope: .globalOwnerRetrieval()))
            let secs = Date().timeIntervalSince(t0)
            records.append(Record(
                question: q,
                refused: a.refused,
                confidence: a.confidence.value,
                intentKind: a.intentKind,
                answerText: a.answerText,
                body: a.body,
                citationCount: a.citations.count,
                citations: a.citations.map { String(describing: $0) }.sorted(),
                secondsWallClock: secs,
                ledgerState: a.ledgerState))
            // INTER-ASK SETTLE (adjudication step 2): the boot settle-loop
            // principle extended to ask boundaries — async between-ask
            // writers (distillation, revision commits) land BEFORE the next
            // ask starts, so stamp sequences are run-stable and like-stamp
            // comparison is automatic.
            await Self.settleBetweenAsks(db: state.database)
            print("BASELINE Q: \(q)\n         → refused=\(a.refused) conf=\(String(format: "%.2f", a.confidence.value)) secs=\(String(format: "%.1f", secs)) text=\(a.answerText ?? "nil")")
        }

        // 4) Drain measurement (spike c) — time PRODUCTION's embedder over a
        //    fixed sample of real chunk texts, recording the provider that
        //    actually served. Disposition 1: the rc0 run went through
        //    CapabilityResolvedEmbedder, whose `dimension` is pinned to the
        //    NLEmbedder fallback (300) no matter who answers — the label was
        //    wrong, not necessarily the timing. Pin to CoreMLEmbedderProvider
        //    (bge-small.v1, what the live ledger's 9,632 vectors carry) and
        //    fall back honestly.
        var drain: Drain? = nil
        do {
            let sample = (try? await ChunksRepository(database: Database(url: copyURL)).sample(limit: 200)) ?? []
            let texts = sample.map(\.text).filter { !$0.isEmpty }
            if !texts.isEmpty {
                let bytes = texts.reduce(0) { $0 + $1.utf8.count }
                let bge = CoreMLEmbedderProvider()
                var vectors: [[Float]] = []
                var providerID = "unresolved"
                let t0 = Date()
                if await bge.isAvailable(), let v = try? await bge.embedBatch(texts: texts) {
                    vectors = v
                    providerID = "bge-small.v1"
                } else {
                    vectors = await NLEmbedder().embedBatch(texts)
                    providerID = "apple.nl.v1(fallback)"
                }
                let secs = Date().timeIntervalSince(t0)
                let dim = vectors.first?.count ?? 0
                let eps = secs > 0 ? Double(texts.count) / secs : 0
                let gbph = secs > 0 ? (Double(bytes) / secs) * 3600.0 / 1_000_000_000.0 : 0
                drain = Drain(embedderDimension: dim, sampleCount: texts.count,
                              sourceBytes: bytes, seconds: secs,
                              embeddingsPerSecond: eps, estGBPerHour: gbph,
                              providerID: providerID)
                print("BASELINE DRAIN: provider=\(providerID) dim=\(dim) sample=\(texts.count) secs=\(String(format: "%.2f", secs)) eps=\(String(format: "%.1f", eps)) estGB/h=\(String(format: "%.3f", gbph))")
            }
        }

        await state.shutdown()

        // 5) Deterministic serialization.
        let iso = ISO8601DateFormatter()
        let header = Header(
            treeHash: Self.treeHash,
            schemaVersion: SchemaMigrations.latestVersion,
            capturedAtISO: iso.string(from: Date()),
            dbCopyRowCounts: counts,
            quiesced: quiesce,
            referenceNowEpoch: ProcessInfo.processInfo.environment["KALSMRITIKOSH_REFERENCE_NOW"],
            blesses: "determinism-not-quality: reproducibility contract only; content quality is governed by V0's recorded reds, which flip separately",
            confidencePrecision: "1e-12")
        let artifact = Artifact(header: header, records: records, drain: drain)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try enc.encode(artifact)
        // The test host is the SANDBOXED app: homeDirectoryForCurrentUser is
        // the container home and its Downloads is not writable (Cocoa 513 on
        // the first capture attempt). Write to the container tmp — always
        // writable — and print the path; the caller copies it out.
        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kalsmritikosh-baseline-\(Self.treeHash).json")
        try data.write(to: outURL)
        print("BASELINE ARTIFACT: \(outURL.path)  (\(data.count) bytes, \(records.count) questions, drain=\(drain != nil))")

        // 6) Green/red signal — the rung-1 anchor must be present and correct.
        #expect(!records.isEmpty)
        let patent = records.first { $0.question == "what is the granted patent number" }
        #expect(patent != nil)
        #expect(patent?.answerText?.contains("555489") == true,
                "rung-1 patent anchor drifted: \(patent?.answerText ?? "nil")")
    }
}
