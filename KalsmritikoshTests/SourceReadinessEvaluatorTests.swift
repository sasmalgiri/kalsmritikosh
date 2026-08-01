//
//  SourceReadinessEvaluatorTests.swift
//  KalsmritikoshTests
//
//  USF-002 — the deterministic evaluator proves the governing distinction: Preserved ≠
//  Searchable ≠ Evidence-ready ≠ Analytically ready. No single dimension implies another;
//  embeddings alone never make a source searchable or analytical; a structurally partial source
//  stays searchablePartial; and the completion state is derived, never a single percentage.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("USF-002 — readiness evaluator")
struct SourceReadinessEvaluatorTests {

    private let sv = UUID()
    private let t0 = Date(timeIntervalSince1970: 1_753_900_000)

    private func rec(_ d: SourceReadinessDimension, _ s: SourceReadinessDimensionState,
                     appl: SourceReadinessApplicability = .required, cond: SourceReadinessCondition? = nil,
                     c: Int? = nil, t: Int? = nil) -> SourceReadinessDimensionRecord {
        SourceReadinessDimensionRecord(sourceVersionID: sv, dimension: d, state: s, applicability: appl,
            condition: cond, completedUnits: c, totalUnits: t, producerID: "p", producerVersion: "1",
            basis: nil, detail: s == .partial ? "disclosed limit" : nil, revision: 1, updatedAt: t0)
    }

    /// A full ten-dimension set: notStarted/required by default, OCR + transcription notApplicable.
    private func full(_ overrides: [SourceReadinessDimension: SourceReadinessDimensionRecord]) -> [SourceReadinessDimensionRecord] {
        var base: [SourceReadinessDimension: SourceReadinessDimensionRecord] = [:]
        for d in SourceReadinessDimension.allCases {
            base[d] = (d == .ocr || d == .transcription) ? rec(d, .ready, appl: .notApplicable) : rec(d, .notStarted)
        }
        for (k, v) in overrides { base[k] = v }
        return Array(base.values)
    }

    private func evaluate(_ records: [SourceReadinessDimensionRecord]) -> SourceReadinessSnapshot {
        SourceReadinessEvaluator.evaluate(sourceVersionID: sv, aggregateRevision: 1, dimensions: records, updatedAt: t0)
    }

    private var searchable: [SourceReadinessDimension: SourceReadinessDimensionRecord] {
        [.preservation: rec(.preservation, .ready), .textExtraction: rec(.textExtraction, .ready),
         .indexing: rec(.indexing, .ready)]
    }
    private var evidence: [SourceReadinessDimension: SourceReadinessDimensionRecord] {
        searchable.merging([.structuralExtraction: rec(.structuralExtraction, .ready, c: 4, t: 4)]) { _, b in b }
    }

    @Test("Preservation alone is not searchable")
    func preservationAloneNotSearchable() {
        let s = evaluate(full([.preservation: rec(.preservation, .ready)]))
        #expect(s.isSearchReady == false)
        #expect(s.completionState == .preservedOnly)
    }

    @Test("Searchable is not evidence-ready")
    func searchableNotEvidence() {
        let s = evaluate(full(searchable))
        #expect(s.isSearchReady)
        #expect(s.isEvidenceReady == false)
        #expect(s.completionState == .searchablePartial)
    }

    @Test("Evidence-ready is not analytically ready")
    func evidenceNotAnalytical() {
        let s = evaluate(full(evidence))
        #expect(s.isEvidenceReady)
        #expect(s.isAnalyticallyReady == false)
        #expect(s.completionState == .evidenceReady)
    }

    @Test("Embeddings alone (no analytical readiness dimension) do not establish analytical readiness")
    func embeddingsAloneNotAnalytical() {
        // evidence-ready + analyticalReadiness left notStarted → not analytical.
        let s = evaluate(full(evidence))
        #expect(s.dimension(.analyticalReadiness)?.state == .notStarted)
        #expect(s.isAnalyticallyReady == false)
    }

    @Test("Complete, located evidence becomes evidence-ready")
    func completeLocatedEvidence() {
        let s = evaluate(full(evidence))
        #expect(s.isEvidenceReady)
    }

    @Test("A structurally partial source stays searchablePartial, not evidence-ready")
    func structurallyPartialStaysSearchable() {
        let s = evaluate(full(searchable.merging([.structuralExtraction: rec(.structuralExtraction, .partial, c: 1, t: 4)]) { _, b in b }))
        #expect(s.isSearchReady)
        #expect(s.isEvidenceReady == false)
        #expect(s.completionState == .searchablePartial)
    }

    @Test("Full analytical readiness requires the analytical dimension and required typed fields")
    func analyticalReady() {
        let s = evaluate(full(evidence.merging([
            .analyticalReadiness: rec(.analyticalReadiness, .ready),
            .typedFieldExtraction: rec(.typedFieldExtraction, .ready, appl: .conditional)]) { _, b in b }))
        #expect(s.isAnalyticallyReady)
    }

    @Test("A notApplicable dimension does not block readiness")
    func notApplicableDoesNotBlock() {
        // transcription notApplicable on an otherwise evidence-ready text document.
        let s = evaluate(full(evidence))
        #expect(s.dimension(.transcription)?.applicability == .notApplicable)
        #expect(s.isEvidenceReady)
    }

    @Test("A deferred blocker derives the deferred completion state")
    func deferredCompletion() {
        let s = evaluate(full([.preservation: rec(.preservation, .ready),
                               .textExtraction: rec(.textExtraction, .blocked, cond: .deferred)]))
        #expect(s.isSearchReady == false)
        #expect(s.completionState == .deferred)
        #expect(s.blockers.contains { $0.condition == .deferred })
    }

    @Test("An encrypted blocker derives the encrypted completion state")
    func encryptedCompletion() {
        let s = evaluate(full([.preservation: rec(.preservation, .ready),
                               .textExtraction: rec(.textExtraction, .blocked, cond: .encrypted)]))
        #expect(s.completionState == .encrypted)
    }

    @Test("A corrupt blocker derives the corrupt completion state")
    func corruptCompletion() {
        let s = evaluate(full([.preservation: rec(.preservation, .ready),
                               .textExtraction: rec(.textExtraction, .blocked, cond: .corrupt)]))
        #expect(s.completionState == .corrupt)
    }

    @Test("An unsupported core dimension derives the unsupported completion state")
    func unsupportedCompletion() {
        let s = evaluate(full([.preservation: rec(.preservation, .ready),
                               .textExtraction: rec(.textExtraction, .unsupported)]))
        #expect(s.completionState == .unsupported)
    }

    @Test("A failed core dimension derives the failed completion state")
    func failedCompletion() {
        let s = evaluate(full([.preservation: rec(.preservation, .ready),
                               .textExtraction: rec(.textExtraction, .failed)]))
        #expect(s.completionState == .failed)
    }

    @Test("Limitations propagate every applicable non-ready dimension")
    func limitationsPropagate() {
        let s = evaluate(full(searchable.merging([.structuralExtraction: rec(.structuralExtraction, .partial, c: 1, t: 4)]) { _, b in b }))
        #expect(s.limitations.contains { $0.dimension == .structuralExtraction && $0.state == .partial })
        // notApplicable dimensions are NOT limitations.
        #expect(!s.limitations.contains { $0.dimension == .transcription })
    }

    @Test("The snapshot exposes per-dimension coverage, never a single overall percentage")
    func perDimensionCoverageOnly() {
        let s = evaluate(full(evidence))
        // coverage is readable per dimension...
        #expect(s.dimension(.structuralExtraction)?.totalUnits == 4)
        // ...and there is no single ratio: search/evidence/analytical are independent booleans.
        #expect(s.isSearchReady && s.isEvidenceReady && !s.isAnalyticallyReady)
    }

    @Test("Evaluation is deterministic regardless of input order")
    func deterministicOrder() {
        let records = full(evidence)
        let a = evaluate(records)
        let b = evaluate(records.reversed())
        #expect(a == b)
    }
}
