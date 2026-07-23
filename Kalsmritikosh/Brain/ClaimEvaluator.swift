//
//  ClaimEvaluator.swift
//  Kalsmritikosh
//
//  S0.5 item 2, Commit C2 (decision wiring). The ONE place that turns GenericFacts + the
//  retrieved chunks into canonical ClaimEvaluations. Retrieval calls this to produce the
//  envelopes it threads to the expert/brain; tests call the identical function — so there
//  is a single evaluation definition and no consumer can diverge. Pure, deterministic,
//  LLM-free; no repository or network access (block→object comes from the in-memory chunks).
//

import Foundation

public enum ClaimEvaluator {

    /// Evaluate each fact ONCE against real evidence: its blocks are resolved to objects via
    /// the already-retrieved chunks (never invented), independence keys are supplied by the
    /// caller (nil ⇒ no corroboration), and the shared policy decides. `refuse` decisions are
    /// dropped. `claimID` is the fact's own ledger id.
    public nonisolated static func evaluate(
        facts: [GenericFact],
        chunks: [RetrievedChunk],
        independenceKeys: [KnowledgeObject.ID: String] = [:]
    ) -> [ClaimEvaluation] {
        guard !facts.isEmpty, !chunks.isEmpty else { return [] }
        var blockToObject: [UUID: KnowledgeObject.ID] = [:]
        for c in chunks where c.chunk.evidenceBlockID != nil {
            let b = c.chunk.evidenceBlockID!
            if blockToObject[b] == nil { blockToObject[b] = c.chunk.objectID }
        }
        let builder = AssertabilityContextBuilder()
        var out: [ClaimEvaluation] = []
        for f in facts {
            let evidence = f.sourceBlockIDs.compactMap { b -> AssertabilityEvidence? in
                guard let obj = blockToObject[b] else { return nil }   // exact matches only
                return AssertabilityEvidence(objectID: obj, blockID: b, independenceKey: independenceKeys[obj])
            }
            let (ctx, decision) = builder.decision(assessment: f.assessment, evidence: evidence)
            guard decision.maySurface else { continue }                // refuse → exclude
            out.append(ClaimEvaluation(id: f.id, claimKind: .genericFact,
                assessment: ctx.assessment, evidence: evidence, context: ctx, decision: decision))
        }
        return out
    }
}
