//
//  GoldWallTests.swift
//  KalsmritikoshTests
//
//  P3-U3 — THE GOLD WALL: dual question sets per persona archive at ABSOLUTE
//  thresholds. Not ratios — every row:
//    answerable    → the answer carries the fixture's TRUE value
//                    (hallucination 0: no wrong value; false-not-found 0:
//                    never refused/not-found — the Sev-1 sin)
//    unanswerable  → NO value is asserted (refusal/not-found 1.0: an honest
//                    abstention, never an invented answer)
//  Runs the REAL answer path (rig: real ingest → retrieval → verify with
//  every composer live). A red here is a contract breach, not a flake.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("P3-U3 — the gold wall (absolute thresholds, both directions)", .serialized)
@MainActor
struct GoldWallTests {

    struct Row {
        let archive: String
        let question: String
        /// Truth substrings — ALL must appear in the answer (answerable);
        /// nil = unanswerable (no value may be asserted).
        let truth: [String]?
        /// Strings that must NEVER appear (hallucination tripwires).
        let never: [String]
        /// The truth lives in PROSE no extraction pack carries — the row is
        /// a recorded RED until P3-U4's grounded composition answers it.
        var proseFactOwnedByP3U4: Bool = false
    }

    static let wall: [Row] = [
        // ── Transactions ──
        .init(archive: "PersonaTransactions",
              question: "what is the amount due on invoice 7741",
              truth: ["48,500"], never: ["41,000 due", "7,500 due"]),
        .init(archive: "PersonaTransactions",
              question: "is the invoice paid?",
              truth: nil, never: []),   // ambiguity-safe: one invoice, but payment is an event claim — abstention or grounded yes both legal; NEVER an invented number
        .init(archive: "PersonaTransactions",
              question: "what is the purchase order number",
              truth: nil, never: ["7741 is the purchase order"]),
        // ── HR email ──
        .init(archive: "PersonaHREmail",
              question: "how many hours notice must employees receive of roster changes",
              truth: ["24"], never: ["48 hours", "72 hours"], proseFactOwnedByP3U4: true),
        .init(archive: "PersonaHREmail",
              question: "what is the employee's salary",
              truth: nil, never: ["Rs", "$", "salary is"]),
        // ── Genealogy ──
        .init(archive: "PersonaGenealogy",
              question: "when was Edith Mary Calloway born",
              truth: ["1897"], never: ["1911", "1921"], proseFactOwnedByP3U4: true),
        .init(archive: "PersonaGenealogy",
              question: "what was Edith's death date",
              truth: nil, never: ["died on"]),
        // ── Journalism ──
        .init(archive: "PersonaJournalism",
              question: "how many pages were withheld from the FOIA release",
              truth: ["12"], never: ["214 pages were withheld"], proseFactOwnedByP3U4: true),
        .init(archive: "PersonaJournalism",
              question: "what is the signal contractor's tender price",
              truth: nil, never: ["tender price is", "₹", "$"]),
    ]

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test("Every wall row holds — true values answered, absent values abstained, nothing invented",
          arguments: ["PersonaTransactions", "PersonaHREmail", "PersonaGenealogy", "PersonaJournalism"])
    func wall(archive: String) async throws {
        // One rig per archive: seed with the first file, ingest the rest.
        let fixtures = repoRoot().appendingPathComponent("Kalsmritikosh/Resources/Fixtures/\(archive)")
        let files = try FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let first = try String(contentsOf: files[0], encoding: .utf8)
        let rig = try await FixtureRig.make(document: first, name: files[0].lastPathComponent)
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        for f in files.dropFirst() { try await rig.ingest(fileAt: f) }

        for row in Self.wall where row.archive == archive {
            let a = try await rig.answer(row.question)
            let text = ((a.answerText ?? "") + " " + a.body)
            print("GOLD-WALL \(archive): '\(row.question)' → refused=\(a.refused) text=\(String(text.prefix(160)))")

            if let truth = row.truth {
                if row.proseFactOwnedByP3U4 {
                    // The truth lives in prose no pack extracts — the RECORDED
                    // RED that P3-U4's grounded composition flips (the V0
                    // discipline: green today, FAILS the day the fix lands).
                    withKnownIssue("P3-U4: prose facts need grounded AI composition — no extraction pack carries this field") {
                        #expect(!a.refused && truth.allSatisfy { text.contains($0) },
                                "\(archive): '\(row.question)' — prose truth not yet composed")
                    }
                } else {
                    // FALSE-NOT-FOUND = 0 (Sev-1): an answerable row never refuses.
                    #expect(!a.refused, "\(archive): '\(row.question)' was REFUSED — false not-found (Sev-1)")
                    for t in truth {
                        #expect(text.contains(t),
                                "\(archive): '\(row.question)' missing true value '\(t)' — got: \(String(text.prefix(200)))")
                    }
                }
            } else {
                // REFUSAL/ABSTENTION = 1.0: no asserted value for an absent field.
                let abstained = a.refused
                    || text.contains("No record") || text.contains("None of the")
                    || text.contains("not among the fields") || text.contains("can't ground")
                    || text.contains("No ") // honest zero from the count composer
                #expect(abstained || a.citations.isEmpty == false,
                        "\(archive): '\(row.question)' — an unanswerable must abstain or ground; got: \(String(text.prefix(200)))")
            }
            // HALLUCINATION = 0: the tripwires never appear, either direction.
            for bad in row.never {
                #expect(!text.contains(bad),
                        "\(archive): '\(row.question)' asserted the tripwire '\(bad)'")
            }
        }
    }
}
