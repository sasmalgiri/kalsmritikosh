//
//  DuplicateSourceIndependenceTests.swift
//  KalsmritikoshTests
//
//  Release gate T3 (macro F / QUALITY-002) — duplicate evidence counted as
//  independent corroboration must be ZERO. AssertabilityPolicyTests already
//  pins the policy given pre-computed counts; this suite proves the counts
//  THEMSELVES through the shared AssertabilityContextBuilder — the one path
//  all three decision points (retrieval, MasterBrain, WorkProductValidator)
//  use — so forwarded/duplicate copies can never fake a second independent
//  source anywhere. Production wiring note: HybridRetriever batch-resolves
//  independence keys (content hash / message id / lineage) per retrieval and
//  hands them to ClaimEvaluator, which routes through this same builder.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("T3 — duplicate-source independence through the shared builder")
struct DuplicateSourceIndependenceTests {

    private let builder = AssertabilityContextBuilder()
    private let sourceAsserted = EvidenceAssessment(basis: .sourceAsserted, origin: .sourceExtraction)

    private func evidence(_ id: UUID, key: String?) -> AssertabilityEvidence {
        AssertabilityEvidence(objectID: id, blockID: UUID(), independenceKey: key)
    }

    @Test("Five forwarded copies (one shared independence key) collapse to ONE group — attribution, never corroboration")
    func duplicatesCollapseToOneGroup() {
        // Five distinct KnowledgeObjects (the original email + four forwards)
        // that all resolve to the SAME independence key.
        let items = (0..<5).map { _ in evidence(UUID(), key: "thread-q3-revenue") }
        let ctx = builder.build(assessment: sourceAsserted, evidence: items)
        #expect(ctx.exactEvidenceCount == 5)                 // all five are real citations
        #expect(ctx.independentEvidenceGroupCount == 1)      // but ONE independent source
        #expect(AssertabilityPolicy.evaluate(ctx) == .assertWithAttribution)
    }

    @Test("Two genuinely independent sources corroborate")
    func independentSourcesCorroborate() {
        let items = [evidence(UUID(), key: "contract-hash-abc"),
                     evidence(UUID(), key: "invoice-msgid-123")]
        let ctx = builder.build(assessment: sourceAsserted, evidence: items)
        #expect(ctx.independentEvidenceGroupCount == 2)
        #expect(AssertabilityPolicy.evaluate(ctx) == .assertAsCorroborated)
    }

    @Test("Unkeyed evidence never contributes independence — many citations, zero verified groups")
    func unkeyedNeverCorroborates() {
        let items = (0..<4).map { _ in evidence(UUID(), key: nil) }
        let ctx = builder.build(assessment: sourceAsserted, evidence: items)
        #expect(ctx.exactEvidenceCount == 4)
        #expect(ctx.independentEvidenceGroupCount == 0)
        #expect(AssertabilityPolicy.evaluate(ctx) == .assertWithAttribution)
    }

    @Test("Whitespace-only keys are as unreliable as no key")
    func blankKeysDoNotCount() {
        let items = [evidence(UUID(), key: "  "), evidence(UUID(), key: "\n"),
                     evidence(UUID(), key: "real-key")]
        let ctx = builder.build(assessment: sourceAsserted, evidence: items)
        #expect(ctx.independentEvidenceGroupCount == 1)
        #expect(AssertabilityPolicy.evaluate(ctx) == .assertWithAttribution)
    }

    @Test("A pile of duplicates plus ONE independent source is exactly two groups — corroborated, but the pile added nothing")
    func duplicatePileAddsNothing() {
        var items = (0..<3).map { _ in evidence(UUID(), key: "same-thread") }
        items.append(evidence(UUID(), key: "independent-doc"))
        let ctx = builder.build(assessment: sourceAsserted, evidence: items)
        #expect(ctx.independentEvidenceGroupCount == 2)
        #expect(AssertabilityPolicy.evaluate(ctx) == .assertAsCorroborated)

        // Control: the SAME pile without the independent doc stays attribution —
        // growing the pile can never substitute for independence.
        let pileOnly = (0..<10).map { _ in evidence(UUID(), key: "same-thread") }
        let pileCtx = builder.build(assessment: sourceAsserted, evidence: pileOnly)
        #expect(AssertabilityPolicy.evaluate(pileCtx) == .assertWithAttribution)
    }

    @Test("One object cited many times is ONE exact citation, one group")
    func repeatedObjectIsOneCitation() {
        let id = UUID()
        let items = (0..<5).map { _ in evidence(id, key: "k") }
        let ctx = builder.build(assessment: sourceAsserted, evidence: items)
        #expect(ctx.exactEvidenceCount == 1)
        #expect(ctx.independentEvidenceGroupCount == 1)
        #expect(AssertabilityPolicy.evaluate(ctx) == .assertWithAttribution)
    }
}
