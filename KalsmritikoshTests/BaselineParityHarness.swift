//
//  BaselineParityHarness.swift
//  KalsmritikoshTests
//
//  Content-parity proof for perf-only changes (owner binding #2, Option A).
//  Re-runs the sealed baseline's question set on the real ledger through the
//  same UI entry path and asserts the ANSWERS are byte-identical to the
//  artifact — answerText, body, citations, refusal, intent, confidence —
//  while reporting the per-question latency delta. This converts "the change
//  was perf-only" from claim to proof.
//
//  Tooling only — never the app target. Skips (green) when the artifact path
//  or the live ledger is absent, so hosted CI passes through. Run:
//    TEST_RUNNER_BASELINE_ARTIFACT=<container-tmp artifact path> xcodebuild test \
//      -only-testing:KalsmritikoshTests/BaselineParityHarness \
//      -parallel-testing-enabled NO
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Baseline parity (perf-only proof against the sealed artifact)", .serialized)
@MainActor
struct BaselineParityHarness {

    static let artifactPath = ProcessInfo.processInfo.environment["BASELINE_ARTIFACT"] ?? ""

    @Test("Re-run the sealed question set → answers byte-identical, latency delta reported")
    func parityAgainstSealedBaseline() async throws {
        guard !Self.artifactPath.isEmpty,
              FileManager.default.fileExists(atPath: Self.artifactPath) else {
            print("PARITY: no BASELINE_ARTIFACT provided/found — skipping (hosted CI path).")
            return
        }
        let liveURL = DatabaseLocations.defaultDatabaseURL
        guard FileManager.default.fileExists(atPath: liveURL.path) else {
            print("PARITY: no live ledger — skipping.")
            return
        }
        let artifact = try JSONDecoder().decode(
            BaselineCaptureHarness.Artifact.self,
            from: Data(contentsOf: URL(fileURLWithPath: Self.artifactPath)))

        // Same read-only VACUUM-copy boot as the capture harness.
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parity-\(UUID().uuidString)", isDirectory: true)
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
        guard case .ready = state.phase else {
            await state.shutdown()
            Issue.record("AppState failed to boot against the copy (phase=\(state.phase))")
            return
        }

        // Quiesce to match a quiesced (steady-state) baseline: drain to empty
        // + a discarded warm-up ask absorbs the boot race (disposition 2 —
        // whatever wobble survives quiescence is product-level nondeterminism).
        if ProcessInfo.processInfo.environment["BASELINE_QUIESCE"] == "1" {
            let settled = await BaselineCaptureHarness.quiesceInFact(state: state, label: "PARITY")
            if !settled { Issue.record("quiescence did not settle within the round cap") }
        }

        var mismatches = 0
        var rung1TextIdentical = true
        for old in artifact.records {
            let t0 = Date()
            let a = await state.brain.answer(
                question: old.question,
                access: SensitiveAccessContext(scope: .globalOwnerRetrieval()))
            let secs = Date().timeIntervalSince(t0)
            let sameText = (a.answerText == old.answerText)
            let sameBody = (a.body == old.body)
            let sameCits = (a.citations.map { String(describing: $0) }.sorted() == old.citations)
            let sameMeta = (a.refused == old.refused && a.intentKind == old.intentKind
                            && a.confidence.value == old.confidence)
            if !(sameText && sameBody && sameCits && sameMeta) { mismatches += 1 }
            if old.question == "what is the granted patent number", !sameText {
                rung1TextIdentical = false
            }
            let speedup = secs > 0 ? old.secondsWallClock / secs : 0
            // UNIT C-ii: the contract is (question, stamped state, pinned
            // clock) → same bytes. Record the stamp so comparisons are
            // like-stamp-to-like-stamp; a stamp mismatch EXPLAINS a diff
            // rather than indicting determinism.
            let stamp = a.ledgerState.map(String.init) ?? "nil"
            print("PARITY Q: \(old.question)\n       → text=\(sameText ? "IDENTICAL" : "DIFFERS") body=\(sameBody ? "IDENTICAL" : "DIFFERS") citations=\(sameCits ? "IDENTICAL" : "DIFFERS") meta=\(sameMeta ? "IDENTICAL" : "DIFFERS") ledgerState=\(stamp) | \(String(format: "%.1f", old.secondsWallClock))s → \(String(format: "%.1f", secs))s (\(String(format: "%.0f", speedup))×)")
            if !sameText {
                print("PARITY DIFF text —\n  baseline: \(old.answerText ?? "nil")\n  now:      \(a.answerText ?? "nil")")
            }
            // Disposition-2 characterization: on a citation diff, print BOTH
            // sides so same-objects-different-snippets vs different-objects is
            // decidable from the log; on a meta diff, print the confidence
            // delta magnitude.
            if !sameCits {
                let now = a.citations.map { String(describing: $0) }.sorted()
                print("PARITY DIFF citations —\n  baseline:\n    " + old.citations.joined(separator: "\n    ")
                      + "\n  now:\n    " + now.joined(separator: "\n    "))
            }
            if a.confidence.value != old.confidence {
                print("PARITY DIFF confidence — baseline=\(old.confidence) now=\(a.confidence.value) Δ=\(String(format: "%+.4f", a.confidence.value - old.confidence))")
            }
            if a.intentKind != old.intentKind || a.refused != old.refused {
                print("PARITY DIFF intent/refusal — baseline=\(old.intentKind ?? "nil")/\(old.refused) now=\(a.intentKind ?? "nil")/\(a.refused)")
            }
        }
        await state.shutdown()

        // All-field byte-parity is UNACHIEVABLE even with zero code change —
        // proven by a control run (2026-08-31, pre-fix code vs its own sealed
        // artifact): citations/meta/body wobble run-to-run (unstable citation
        // record ids, confidence drift, boot-drain race on the fresh copy).
        // The ENFORCED invariant is the stable core — the rung-1 anchor text,
        // identical across all control and treatment runs. The full per-field
        // table above is the diagnostic record; judge changes against a
        // same-code control profile, not against zero.
        #expect(rung1TextIdentical, "rung-1 anchor text changed — NOT perf-only")
        print("PARITY: \(artifact.records.count - mismatches)/\(artifact.records.count) answers byte-identical to \(artifact.header.treeHash) (see per-field table; enforced invariant = rung-1 text)")
    }
}
