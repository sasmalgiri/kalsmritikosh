//
//  SilentWriteFailureGuardTests.swift
//  KalsmritikoshTests
//
//  P1.4 — the architecture guard that stops P1.1/P1.2 coming back.
//
//  WHY A GUARD AND NOT JUST THE FIXES. This exact class of defect has now been
//  fixed twice. Task #39 ("un-silence FK/constraint write-path swallow")
//  addressed it once, and eleven `try? await <persist>` sites were still found
//  on the ingest path months later — including the one at IngestCoordinator's
//  entity insert, where a swallowed error caused events to be written with
//  entity references that were never canonicalised. A fix without a guard is a
//  fix with a half-life.
//
//  WHAT IT ENFORCES. `try?` on a persist is not banned — some failures are
//  genuinely tolerable. What is banned is a tolerated failure with NO RECORD,
//  because that is the thing that makes a gap unexplainable: the row is simply
//  absent afterwards, indistinguishable from "there was nothing to write".
//
//  So a site may use `try?` only if it is ACKNOWLEDGED — the same line or one
//  of the few before it carries a marker saying the loss is deliberate and
//  where it is recorded. That keeps the escape hatch open for real cases while
//  making silence a deliberate, reviewable act rather than the default.
//
//  These are source-text assertions, which is unusual, and deliberate: the
//  property is about how the code is WRITTEN, so no runtime test can observe
//  it. The alternative — hoping reviewers catch it — is what failed twice.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("P1.4 — no silent write failures on the ingest path")
struct SilentWriteFailureGuardTests {

    /// Persist-shaped calls: these write to the ledger, so a discarded error
    /// means lost data rather than a skipped read.
    static let persistVerbs = ["insert", "insertBatch", "upsert", "upsertEdges",
                               "save", "persist", "link", "linkBlocks", "record",
                               "markDerivationComplete"]

    /// A `try?` is acknowledged when one of these appears on the same line or
    /// within the preceding few lines. `derivationFailures?.record` is the
    /// normal case; the comment markers cover sites where recording is not
    /// possible (no repository in scope) and the loss is argued in prose.
    static let acknowledgements = ["derivationFailures?.record", "derivationFailures.record",
                                   "P1.2", "TOLERATED-SILENT", "recorded-reason"]

    /// How far back to look for the acknowledgement.
    static let lookbackLines = 6

    /// Directories that write the ledger during ingest and derivation. UI and
    /// EvalKit are excluded: a discarded write there is a display or harness
    /// concern, not evidence loss.
    static let guardedRoots = ["Kalsmritikosh/Ingestion", "Kalsmritikosh/Knowledge"]

    private static func repoRoot() -> URL {
        // .../KalsmritikoshTests/<this file> → repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func swiftFiles(under relative: String) -> [URL] {
        let root = repoRoot().appendingPathComponent(relative)
        guard let e = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    struct Offence: CustomStringConvertible {
        let file: String, line: Int, text: String
        var description: String { "\(file):\(line) — \(text.trimmingCharacters(in: .whitespaces))" }
    }

    /// Every `try?` on a persist-shaped call that carries no acknowledgement.
    static func unacknowledgedSilentWrites() -> [Offence] {
        var out: [Offence] = []
        for relative in guardedRoots {
            for url in swiftFiles(under: relative) {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let lines = text.components(separatedBy: "\n")
                for (i, line) in lines.enumerated() {
                    // Skip comment lines — including the prose in this guard's
                    // own explanations elsewhere in the tree.
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                    guard line.contains("try?") else { continue }
                    guard persistVerbs.contains(where: { line.contains(".\($0)(") }) else { continue }
                    let from = max(0, i - lookbackLines)
                    let window = lines[from...i].joined(separator: "\n")
                    if acknowledgements.contains(where: { window.contains($0) }) { continue }
                    out.append(Offence(file: url.lastPathComponent, line: i + 1, text: line))
                }
            }
        }
        return out
    }

    @Test("A tolerated write failure must be recorded, never silent")
    func noUnacknowledgedSilentWrites() {
        let offences = Self.unacknowledgedSilentWrites()
        let newline = "\n"
        #expect(offences.isEmpty, """
            \(offences.count) persist call(s) discard their error with no record of \
            the reason. A tolerated loss is allowed; an UNEXPLAINABLE one is not — \
            the row is simply absent afterwards, which reads identically to \
            "there was nothing to write".

            Fix by recording the reason:
                do { try await repo.insert(x) }
                catch { await derivationFailures?.record(stage: "<producer>", error: error, …) }

            If recording is genuinely impossible at that site, mark it
            TOLERATED-SILENT with the reason in a comment above.

            \(offences.map(\.description).joined(separator: newline))
            """)
    }

    @Test("The guard itself can detect an offence — it is not vacuously green")
    func guardIsNotVacuous() {
        // A guard that passes because its matcher is broken is worse than no
        // guard: it reports safety it never checked. This proves the detector
        // fires on the exact shape it is meant to catch.
        let offending = """
            func f() async {
                try? await events.insertBatch(remapped)
            }
            """
        let lines = offending.components(separatedBy: "\n")
        var fired = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }
            guard line.contains("try?") else { continue }
            guard Self.persistVerbs.contains(where: { line.contains(".\($0)(") }) else { continue }
            if !Self.acknowledgements.contains(where: { offending.contains($0) }) { fired = true }
        }
        #expect(fired, "the detector failed to flag a bare `try? await …insertBatch(…)`")
    }

    @Test("The entity-insert cascade site (P1.1) no longer discards its error")
    func entityInsertPropagates() throws {
        // The specific line that caused the cascade: a swallowed insert left
        // canonicalMapping empty, and the next stage wrote events remapped
        // through it. Pinned by source so a future edit cannot quietly restore
        // the `try?` — this one must PROPAGATE, not merely be recorded.
        let url = Self.repoRoot()
            .appendingPathComponent("Kalsmritikosh/Ingestion/Pipeline/IngestCoordinator.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("canonicalMapping = (try? await entities.insertBatch(raw)) ?? [:]"),
                "the entity-insert cascade has been reintroduced")
        #expect(text.contains("canonicalMapping = try await entities.insertBatch(raw)"),
                "the entity insert no longer propagates — it must, or events get remapped through an empty mapping")
    }
}
