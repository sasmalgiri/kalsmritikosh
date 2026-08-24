//
//  AssertabilityContextBuilder.swift
//  Kalsmritikosh
//
//  S0.5 item 2, Commit C2 (infra). ONE builder that turns a claim's assessment + its exact
//  evidence into the AssertabilityContext consumed by ALL THREE decision points (retrieval,
//  MasterBrain, WorkProductValidator). Because they share this builder, they compute
//  IDENTICAL context — so their AssertabilityPolicy decisions cannot diverge. No consumer
//  may estimate these values independently.
//
//  Corroboration strength uses the CONSERVATIVE verified independent-source count
//  (SourceIndependenceGrouper.verifiedIndependentCount): unkeyed / duplicate / forwarded
//  copies never raise it. Deterministic; LLM-free.
//

import Foundation

/// A normalized, self-describing evidence item. Carrying `blockID` and `independenceKey`
/// HERE means the builder derives locator presence and independence itself — no consumer
/// passes a separately-computed `hasExactLocator`, so all three decision points that share
/// this builder cannot disagree on the context.
public nonisolated struct AssertabilityEvidence: Sendable, Hashable, Codable {
    public let objectID: KnowledgeObject.ID
    public let blockID: EvidenceBlock.ID?
    public let independenceKey: String?
    public nonisolated init(objectID: KnowledgeObject.ID, blockID: EvidenceBlock.ID? = nil,
                            independenceKey: String? = nil) {
        self.objectID = objectID; self.blockID = blockID; self.independenceKey = independenceKey
    }
}

public nonisolated struct AssertabilityContextBuilder: Sendable {
    private let grouper = SourceIndependenceGrouper()
    public init() {}

    // MARK: - Shared behavioural path (evidence-derived; NO caller-supplied locator)

    /// Build the context from normalized evidence. Locator presence and independence keys
    /// are DERIVED here, so retrieval / MasterBrain / validator produce identical context
    /// from the same evidence. This is the API the three decision points must use.
    public func build(
        assessment: EvidenceAssessment,
        evidence: [AssertabilityEvidence],
        hasReproducibleDerivation: Bool = false,
        derivedConflict: ConflictStatus? = nil
    ) -> AssertabilityContext {
        let hasExactLocator = evidence.contains { $0.blockID != nil }
        let keys = Dictionary(evidence.compactMap { e -> (KnowledgeObject.ID, String)? in
            guard let k = e.independenceKey else { return nil }
            return (e.objectID, k)
        }, uniquingKeysWith: { a, _ in a })
        return build(assessment: assessment, evidenceObjectIDs: evidence.map(\.objectID),
                     independenceKeys: keys, hasExactLocator: hasExactLocator,
                     hasReproducibleDerivation: hasReproducibleDerivation, derivedConflict: derivedConflict)
    }

    /// Build from history/citation `EvidenceReference`s + an independence-key lookup. Block
    /// locators come from the references; keys come from `independenceKeys[objectID]`.
    public func build(
        assessment: EvidenceAssessment,
        references: [EvidenceReference],
        independenceKeys: [KnowledgeObject.ID: String],
        hasReproducibleDerivation: Bool = false,
        derivedConflict: ConflictStatus? = nil
    ) -> AssertabilityContext {
        let evidence = references.map {
            AssertabilityEvidence(objectID: $0.objectID, blockID: $0.blockID,
                                  independenceKey: independenceKeys[$0.objectID])
        }
        return build(assessment: assessment, evidence: evidence,
                     hasReproducibleDerivation: hasReproducibleDerivation, derivedConflict: derivedConflict)
    }

    /// Build AND decide from normalized evidence (the pairing the consumers use).
    public func decision(
        assessment: EvidenceAssessment,
        evidence: [AssertabilityEvidence],
        hasReproducibleDerivation: Bool = false,
        derivedConflict: ConflictStatus? = nil
    ) -> (context: AssertabilityContext, decision: AssertabilityDecision) {
        let ctx = build(assessment: assessment, evidence: evidence,
                        hasReproducibleDerivation: hasReproducibleDerivation, derivedConflict: derivedConflict)
        return (ctx, AssertabilityPolicy.evaluate(ctx))
    }

    /// Build the context deterministically.
    /// - evidenceObjectIDs: the object ids of the claim's EXACT evidence references.
    /// - independenceKeys: object id → its independence key (content hash / message id /
    ///   lineage). Missing/empty keys do NOT contribute independence.
    /// - hasExactLocator: does at least one evidence reference carry an exact block locator?
    /// - hasReproducibleDerivation: for deterministically-derived claims, do the inputs reproduce it?
    /// - derivedConflict: a conflict established from a REAL contradiction relation; when
    ///   supplied it overrides the assessment's stored conflict.
    // MARK: - Low-level primitive (locator supplied). Prefer the evidence-based `build`
    // above on the behavioural path; this underlies it and is used by unit tests.

    public func build(
        assessment: EvidenceAssessment,
        evidenceObjectIDs: [KnowledgeObject.ID],
        independenceKeys: [KnowledgeObject.ID: String],
        hasExactLocator: Bool,
        hasReproducibleDerivation: Bool = false,
        derivedConflict: ConflictStatus? = nil
    ) -> AssertabilityContext {
        // Distinct objects: a single source cited twice is one exact citation, not two.
        let distinctObjects = Array(Set(evidenceObjectIDs))
        let exactCount = distinctObjects.count
        let verifiedGroups = grouper.verifiedIndependentCount(objectIDs: distinctObjects, keys: independenceKeys)

        // Effective conflict: a MEANINGFUL derived contradiction wins; `.none` is not an
        // override and must not erase a stored/legacy contradicted state.
        let effectiveConflict = EvidenceAssessmentRowDecoder.meaningfulDerivedConflict(derivedConflict) ?? assessment.conflict
        let effective = EvidenceAssessment(
            basis: assessment.basis, review: assessment.review, origin: assessment.origin,
            availability: assessment.availability, conflict: effectiveConflict,
            legacyStatus: assessment.legacyStatus)

        return AssertabilityContext(
            assessment: effective,
            exactEvidenceCount: exactCount,
            independentEvidenceGroupCount: verifiedGroups,
            hasExactLocator: hasExactLocator,
            hasReproducibleDerivation: hasReproducibleDerivation)
    }

    /// Convenience: build AND decide in one step, so a consumer can't accidentally pair a
    /// context with a different policy call.
    public func decision(
        assessment: EvidenceAssessment,
        evidenceObjectIDs: [KnowledgeObject.ID],
        independenceKeys: [KnowledgeObject.ID: String],
        hasExactLocator: Bool,
        hasReproducibleDerivation: Bool = false,
        derivedConflict: ConflictStatus? = nil
    ) -> (context: AssertabilityContext, decision: AssertabilityDecision) {
        let ctx = build(assessment: assessment, evidenceObjectIDs: evidenceObjectIDs,
                        independenceKeys: independenceKeys, hasExactLocator: hasExactLocator,
                        hasReproducibleDerivation: hasReproducibleDerivation, derivedConflict: derivedConflict)
        return (ctx, AssertabilityPolicy.evaluate(ctx))
    }
}
