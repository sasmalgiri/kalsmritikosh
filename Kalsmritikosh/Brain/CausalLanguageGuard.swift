//
//  CausalLanguageGuard.swift
//  Kalsmritikosh
//
//  CLM-002 — causal-language verification. A pack-core truth rule: "temporal adjacency
//  is never presented as causation." When an answer claim asserts a CAUSAL link
//  ("X caused Y", "because", "led to", "due to"), the supporting evidence must itself
//  assert causation — not merely place two facts near each other in time. If the
//  evidence shows only sequence/adjacency, the causal claim is unsupported and must be
//  flagged (and softened), never presented as established cause.
//
//  Deterministic, offline. This guard does NOT delete evidence or fabricate; it detects
//  an over-claim and produces a neutral caution the answer layer can surface.
//

import Foundation

public struct CausalLanguageGuard: Sendable {
    public nonisolated init() {}

    /// Causal connectives that assert cause, not mere sequence.
    nonisolated static let causalMarkers: [String] = [
        "because", "caused", "cause of", "led to", "leads to", "due to", "resulted in",
        "result of", "as a result", "consequently", "therefore", "thereby", "so that",
        "brought about", "triggered", "gave rise to", "owing to", "on account of"
    ]

    /// Purely temporal markers — sequence, not cause.
    nonisolated static let temporalMarkers: [String] = [
        "after", "before", "then", "subsequently", "following", "later", "prior to",
        "once", "when", "meanwhile", "next", "earlier", "at the same time"
    ]

    public struct Verdict: Sendable, Hashable {
        public let claimIsCausal: Bool
        public let evidenceSupportsCausation: Bool
        /// True when the claim asserts cause but the evidence shows only sequence.
        public var isUnsupportedCausalClaim: Bool { claimIsCausal && !evidenceSupportsCausation }
        public let caution: String
    }

    /// Assess a single claim against its supporting evidence text.
    public nonisolated func assess(claim: String, evidenceTexts: [String]) -> Verdict {
        let c = claim.lowercased()
        let claimCausal = Self.causalMarkers.contains { c.contains($0) }
        guard claimCausal else {
            return Verdict(claimIsCausal: false, evidenceSupportsCausation: false, caution: "")
        }
        let evidence = evidenceTexts.joined(separator: " ").lowercased()
        let evidenceCausal = Self.causalMarkers.contains { evidence.contains($0) }
        let caution = (claimCausal && !evidenceCausal)
            ? "Caution: a causal link is stated, but the evidence shows only that the events "
              + "occurred in sequence — sequence is not proof of cause."
            : ""
        return Verdict(claimIsCausal: true, evidenceSupportsCausation: evidenceCausal, caution: caution)
    }

    /// Assess a set of claims; returns a single caution if ANY claim over-states cause.
    public nonisolated func assess(claims: [String], evidenceTexts: [String]) -> String {
        for claim in claims {
            let v = assess(claim: claim, evidenceTexts: evidenceTexts)
            if v.isUnsupportedCausalClaim { return v.caution }
        }
        return ""
    }
}
