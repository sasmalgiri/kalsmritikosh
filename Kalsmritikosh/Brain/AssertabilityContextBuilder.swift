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

public struct AssertabilityContextBuilder: Sendable {
    private let grouper = SourceIndependenceGrouper()
    public init() {}

    /// Build the context deterministically.
    /// - evidenceObjectIDs: the object ids of the claim's EXACT evidence references.
    /// - independenceKeys: object id → its independence key (content hash / message id /
    ///   lineage). Missing/empty keys do NOT contribute independence.
    /// - hasExactLocator: does at least one evidence reference carry an exact block locator?
    /// - hasReproducibleDerivation: for deterministically-derived claims, do the inputs reproduce it?
    /// - derivedConflict: a conflict established from a REAL contradiction relation; when
    ///   supplied it overrides the assessment's stored conflict.
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

        // Effective conflict: a real contradiction relation wins over the stored value.
        let effectiveConflict = derivedConflict ?? assessment.conflict
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
