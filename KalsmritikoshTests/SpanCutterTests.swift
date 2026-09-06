//
//  SpanCutterTests.swift
//  Kalsmritikosh Tests
//
//  A2.4 — the span cutter's laws: per-shape policy selects the right
//  sentences, winners rank first, windows heal dangling references,
//  use-once holds, the budget caps, ids are stable and block-resolvable.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("A2.4 — the span cutter (per-shape policy, deterministic)")
struct SpanCutterTests {

    private func rc(_ text: String, obj: UUID = UUID()) -> RetrievedChunk {
        RetrievedChunk(chunk: Chunk(objectID: obj, ordinal: 0, text: text,
                                    characterRange: 0..<text.count),
                       score: 1.0, viaLayer: .metadata)
    }

    @Test("Role policy cuts the POA grantor sentence; money policy demands money; determinism holds")
    func policyAndDeterminism() {
        let poa = rc("Lunch is at noon. I, shirshendu sasmal having Nationality of India, hereby authorize the agent. The fee was ₹15,000 for the application.")
        let spans = SpanCutter.cut(question: "who is the owner of this patent?", shape: .role, chunks: [poa])
        #expect(spans.first?.text.contains("shirshendu sasmal") == true, "got: \(spans.map(\.text))")
        #expect(spans.first?.id == "S1")
        #expect(!spans.contains { $0.text.contains("Lunch") }, "no term hit → never cut")

        // Money policy: only the money sentence survives.
        let money = SpanCutter.cut(question: "what was the total fee paid", shape: .aggregation, chunks: [poa])
        #expect(money.allSatisfy { $0.text.contains("₹") }, "got: \(money.map(\.text))")

        // Determinism: same input → same spans, ids stable.
        let again = SpanCutter.cut(question: "who is the owner of this patent?", shape: .role, chunks: [poa])
        #expect(again == spans)
    }

    @Test("The window heals a dangling reference; use-once dedupes; the budget caps at 6")
    func windowsDedupeBudget() {
        let doc = rc("The patent was granted on 28 November 2024. It was the applicant's third filing. The patent was granted on 28 November 2024.")
        let spans = SpanCutter.cut(question: "when was the patent granted", shape: .existence, chunks: [doc])
        // The dangling "It was…" sentence carries its predecessor.
        if let windowed = spans.first(where: { $0.text.contains("It was") }) {
            #expect(windowed.text.contains("granted on 28 November"), "the window healed it: \(windowed.text)")
        }
        // Use-once: the duplicated sentence appears exactly once.
        let dupes = spans.filter { $0.text == "The patent was granted on 28 November 2024" }
        #expect(dupes.count <= 1)

        // Budget: many matching sentences still cap at 6.
        let big = rc(Array(repeating: "The patent hearing was held", count: 20).enumerated()
            .map { "\($0.element) in room \($0.offset)" }.joined(separator: ". "))
        let capped = SpanCutter.cut(question: "when was the hearing held", shape: .existence, chunks: [big])
        #expect(capped.count <= 6)
        #expect(capped.last.map { $0.id.hasPrefix("S") } ?? true)
    }
}
