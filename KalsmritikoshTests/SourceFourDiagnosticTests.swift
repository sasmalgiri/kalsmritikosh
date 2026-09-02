//
//  SourceFourDiagnosticTests.swift
//  KalsmritikoshTests
//
//  Source-#4 diagnostic protocol (owner, 2026-08-31): the unit-A seal left
//  ONE residual — Q7's confidence moved ±0.002 with the clock pinned and
//  evidence byte-identical. Suspects: (a) AEE round-count under wall-clock
//  variance (code inspection already found NO time-based budgets — call
//  counts only), (b) CoreML reranker numeric jitter, with the owner's
//  sub-hypothesis: a FRESH mlpackage compile per score() call may select
//  different execution plans run-to-run, in which case unit B's load-once
//  IS the #4 fix and must predict Q7 stabilizing.
//
//  All comparisons are Float64 bitPattern — never `==`.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Source #4 — reranker bitwise matrix + Q7 confidence distribution", .serialized)
@MainActor
struct SourceFourDiagnosticTests {

    static let question = "what is the capital of France"
    static let passage = """
    KHURANA & KHURANA, ADVOCATES AND IP ATTORNEYS Corporate Address E-13, \
    UPSIDC Site-IV, Kasna Road, Greater Noida – 201308, India P: +91.120.4296878 \
    Please note services provided by the firm of advocates by way of legal \
    services are to be paid by the recipient of the service on reverse charge basis.
    """

    @Test("Bitwise matrix: same-instance repeat vs fresh-compile-per-call")
    func rerankerBitwiseMatrix() async {
        let tier = CoreMLCrossEncoderTier()
        // (b1) SAME call, duplicated candidate → one compiled instance runs
        // the identical input twice. Any bit divergence here = pure
        // hardware/scheduler nondeterminism within one loaded model.
        guard let sameCall = await tier.score(question: Self.question,
                                              candidates: [Self.passage, Self.passage]) else {
            print("S4 MATRIX: model not bundled — matrix not measurable in this host")
            return
        }
        let b0 = sameCall[0].bitPattern, b1 = sameCall[1].bitPattern
        print("S4 MATRIX same-instance: \(String(b0, radix: 16)) vs \(String(b1, radix: 16)) → \(b0 == b1 ? "BITWISE-IDENTICAL" : "DIVERGED")")

        // (b2) THREE separate score() calls → three fresh compiles of the
        // same mlpackage on the same input. Divergence here (with b1
        // stable) = the fresh-compile disease: execution-plan selection
        // varies per compile → unit B (load-once) is the #4 fix.
        var freshBits: [UInt64] = []
        for i in 0..<3 {
            if let s = await tier.score(question: Self.question, candidates: [Self.passage]) {
                freshBits.append(s[0].bitPattern)
                print("S4 MATRIX fresh-compile[\(i)]: \(String(s[0].bitPattern, radix: 16))")
            }
        }
        let freshStable = Set(freshBits).count <= 1
        print("S4 MATRIX verdict: same-instance=\(b0 == b1 ? "stable" : "JITTERS") fresh-compile=\(freshStable ? "stable" : "JITTERS") (\(Set(freshBits).count) distinct of \(freshBits.count))")
        #expect(!sameCall.isEmpty)
    }

    @Test("Q7 ×5 under parity conditions: confidence distribution (env-gated live)")
    func q7ConfidenceDistribution() async throws {
        guard ProcessInfo.processInfo.environment["S4_LIVE"] == "1" else {
            print("S4 Q7: S4_LIVE not set — skipping (operator-invoked only).")
            return
        }
        let liveURL = DatabaseLocations.defaultDatabaseURL
        guard FileManager.default.fileExists(atPath: liveURL.path) else { return }
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("s4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let copyURL = workDir.appendingPathComponent("ledger-copy.sqlite")
        do {
            let src = try Database(url: liveURL)
            let escaped = copyURL.path.replacingOccurrences(of: "'", with: "''")
            try await src.exec("VACUUM main INTO '\(escaped)';", [])
            await src.close()
        }
        let state = AppState(bookmarks: BookmarkStore(ephemeral: true))
        await state.boot(databaseURL: copyURL)
        guard case .ready = state.phase else { await state.shutdown(); return }
        // Canonical ledger guard (owner 2026-09-02): never grade a phantom container.
        guard await DiagnosticLedger.assertPopulated(state.database, label: "S4") else {
            await state.shutdown(); return
        }
        // Quiescence-in-fact — the ×3 probe below is the GRADER for the
        // transferred 4b prediction: post-true-quiescence, 1-of-3 on all
        // seven; anything less is the STOP that names the residual.
        let settled = await BaselineCaptureHarness.quiesceInFact(state: state, label: "S4")
        if !settled { Issue.record("quiescence did not settle — probe would grade a moving target") }
        // Owner ruling: log ConfidenceReport components for ALL SEVEN
        // questions ×3 — scoping whether the varying-integer class touches
        // answerable paths or only the out-of-scope corner. The component
        // that moves when the confidence moves NAMES source #4.
        // Pre-C probe (owner binding): the live ledger has ZERO memory_objects,
        // so the +1 distinct source between asks is written DURING the run —
        // name the writer TABLE by diffing row counts around every ask.
        let watched = ["knowledge_objects", "memory_objects", "generic_facts",
                       "events", "chunks", "entities", "answer_revision_events",
                       "memory_changes"]
        func tableCounts() async -> [String: Int] {
            var out: [String: Int] = [:]
            for t in watched {
                if let n = try? await state.database?.query("SELECT COUNT(*) FROM \(t)", []).first?.int(0) {
                    out[t] = Int(n)
                }
            }
            return out
        }
        var prevCounts = await tableCounts()
        // Unit-E permutation axis: anomaly follows ask INDEX = consumption;
        // follows the QUESTION regardless of position = conditional sampling.
        // Unit-E hunt axis (owner): Q7 SOLO in a fresh process — still
        // accumulating = self-feeding (its own asks deposit what the next
        // ask inhales); stable solo = fed by the other questions' processing.
        // Discriminator generalization (owner 2026-09-02, Q2 tripwire): any
        // single question can be soloed ×5 to grade stable-vs-toggling. Q2 =
        // "what is the application number" runs the comparator-vs-residual
        // discriminator; PROBE_SOLO_Q7 stays as the legacy alias.
        let soloQuestion = ProcessInfo.processInfo.environment["PROBE_SOLO_QUESTION"]
        let solo = ProcessInfo.processInfo.environment["PROBE_SOLO_Q7"] == "1" || soloQuestion != nil
        let questions: [String] = soloQuestion.map { [$0] }
            ?? (ProcessInfo.processInfo.environment["PROBE_SOLO_Q7"] == "1"
                ? ["what is the capital of France"]
                : (ProcessInfo.processInfo.environment["PROBE_REVERSED"] == "1"
                   ? BaselineCaptureHarness.questions.reversed().map { $0 }
                   : BaselineCaptureHarness.questions))
        let asksPerQuestion = ProcessInfo.processInfo.environment["PROBE_ASKS"].flatMap(Int.init)
            ?? (solo ? 5 : 3)
        for q in questions {
            var bits: [UInt64] = []
            for i in 0..<asksPerQuestion {
                let a = await state.brain.answer(question: q,
                                                 access: SensitiveAccessContext(scope: .globalOwnerRetrieval()))
                bits.append(a.confidence.value.bitPattern)
                let now = await tableCounts()
                let deltas = now.compactMap { k, v -> String? in
                    let d = v - (prevCounts[k] ?? v); return d != 0 ? "\(k)+\(d)" : nil
                }.sorted()
                if !deltas.isEmpty { print("S4 WRITER ask-delta q=\"\(q.prefix(28))\"[\(i)]: \(deltas.joined(separator: " "))") }
                prevCounts = now
                // Unit-E discriminator: identical inter-ask procedure to the
                // capture — async writers land BEFORE the next ask.
                await BaselineCaptureHarness.settleBetweenAsks(db: state.database)
                let r = a.report
                print("S4 COMP q=\"\(q.prefix(28))\" ask=\(i) conf=\(a.confidence.value)"
                      + " dropped=\(r?.droppedUnverifiable ?? -1)"
                      + " agree=\(r?.agreementScore ?? -1)"
                      + " sources=\(r?.sourceCount ?? -1)/\(r?.distinctSourceObjectIDs ?? -1)"
                      + " fresh=\(r?.freshness.map { String($0) } ?? "nil")"
                      + " cover=\(r?.coverage.map { String($0) } ?? "nil")"
                      + " ingest=\(r?.ingestCoverage ?? -1)"
                      + " cits=\(a.citations.count)")
                // SOURCESET dump (owner discriminator): the sorted citation
                // set per ask, so a source consolidation (v0 spelling pair now
                // comparing canonical-equal → one fewer distinct source) is
                // visible and diffable against the seal's recorded citations.
                let sourceSet = a.citations.map { String(describing: $0) }.sorted()
                print("S4 SOURCESET q=\"\(q.prefix(28))\" ask=\(i) [\(sourceSet.count)]: \(sourceSet.joined(separator: " | "))")
            }
            print("S4 COMP verdict q=\"\(q.prefix(28))\": \(Set(bits).count) distinct of \(bits.count)")
        }
        await state.shutdown()
    }
}
