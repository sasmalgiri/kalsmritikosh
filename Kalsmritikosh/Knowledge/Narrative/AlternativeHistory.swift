//
//  AlternativeHistory.swift
//  Kalsmritikosh
//
//  A7.3 — when the archive supports two incompatible accounts of the same fact
//  (a detected Contradiction), a reconstruction must present BOTH honestly, not
//  silently pick one. Each alternative lists its competing accounts (claim +
//  evidence), the unresolved conflict, and the DECISIVE MISSING EVIDENCE — the
//  specific thing that, if found, would settle it. Deterministic, built from the
//  contradiction ledger (A5.6); no model. A "leading" account is named only when
//  one side is strictly better corroborated — never fabricated when balanced.
//

import Foundation

public struct AlternativeHistory: Sendable, Hashable, Identifiable {
    public struct Account: Sendable, Hashable {
        public let claim: String
        public let evidenceObjectID: KnowledgeObject.ID?
        /// Distinct corroborating sources known for this account (≥1).
        public let corroboration: Int
    }

    public let id: UUID
    public let subject: String              // what's disputed
    public let kind: Contradiction.Kind
    public let accounts: [Account]          // the competing accounts (≥2)
    /// The claim index (into `accounts`) that is better corroborated, or nil
    /// when the evidence is balanced — then it's genuinely unresolved.
    public let leadingIndex: Int?
    public let unresolvedConflict: String
    public let decisiveMissingEvidence: String

    public var isBalanced: Bool { leadingIndex == nil }
}

public struct AlternativeHistoryBuilder: Sendable {

    public nonisolated init() {}

    /// Build alternative histories from detected contradictions. `corroboration`
    /// maps an evidence object id to how many DISTINCT sources back that claim
    /// (default 1 each). When one side's corroboration strictly exceeds the
    /// other's, it's marked leading; otherwise the conflict stays balanced.
    public func build(
        contradictions: [Contradiction],
        corroboration: [KnowledgeObject.ID: Int] = [:]
    ) -> [AlternativeHistory] {
        contradictions.map { c in
            let corrA = c.evidenceA.map { corroboration[$0] ?? 1 } ?? 1
            let corrB = c.evidenceB.map { corroboration[$0] ?? 1 } ?? 1
            let accounts = [
                AlternativeHistory.Account(claim: c.claimA, evidenceObjectID: c.evidenceA, corroboration: corrA),
                AlternativeHistory.Account(claim: c.claimB, evidenceObjectID: c.evidenceB, corroboration: corrB)
            ]
            let leading: Int? = corrA == corrB ? nil : (corrA > corrB ? 0 : 1)
            return AlternativeHistory(
                id: c.id,
                subject: c.description,
                kind: c.kind,
                accounts: accounts,
                leadingIndex: leading,
                unresolvedConflict: "\(c.claimA)   vs.  \(c.claimB)",
                decisiveMissingEvidence: Self.decisiveMissingEvidence(for: c.kind)
            )
        }
    }

    /// What piece of evidence would settle a conflict of this kind — stated
    /// specifically so the user knows what to look for.
    static func decisiveMissingEvidence(for kind: Contradiction.Kind) -> String {
        switch kind {
        case .date:
            return "An independent, timestamped source (e.g. an email header or system log) fixing the date would resolve this."
        case .amount:
            return "An authoritative financial record (a signed invoice or a bank/payment confirmation) stating the figure would resolve this."
        case .location:
            return "A source that unambiguously fixes the place (an itinerary, a signed venue record) would resolve this."
        case .signature, .identity:
            return "The executed original (or a witnessed/notarized copy) identifying the signatory would resolve this."
        case .causation, .sequence, .eventOccurrence:
            return "A source that directly states the order or cause — rather than leaving it to inference — would resolve this."
        case .payment:
            return "A payment confirmation or receipt tying the payment to the invoice would resolve this."
        case .documentVersion:
            return "The final, version-marked document (superseding earlier drafts) would resolve this."
        case .status, .testimony, .sentReceived, .other:
            return "An independent corroborating source is needed to resolve this; the archive alone cannot."
        }
    }
}
