//
//  ExpertRelevanceScorer.swift
//  Kalsmritikosh
//
//  Mixture-of-Experts gating. Given the evidence ALREADY retrieved for a
//  query, pick the experts worth running so a simple factual lookup doesn't
//  fire all seven. Deliberately conservative — recall over cost:
//
//    * Generalist experts (research, ocr) always stay.
//    * A domain expert is kept if the intent calls for its domain OR the
//      retrieval surfaced concrete evidence for it (events/entities of the
//      right kind). A domain expert with ZERO evidence and no intent match
//      would produce nothing anyway, so dropping it can't lose an answer.
//    * If fewer than two experts survive, fall back to ALL (never starve).
//
//  Pure + Sendable; no model, no I/O.
//

import Foundation

public enum ExpertRelevanceScorer {

    public static func select(
        from experts: [any Expert],
        intent: UserIntent,
        retrieval: RetrievalResult
    ) -> [any Expert] {
        let intentDomains = domains(for: intent)
        let evidence = Evidence(retrieval)
        let kept = experts.filter { expert in
            if !expert.domains.isDisjoint(with: intentDomains) { return true }
            return expert.domains.contains { evidence.hasEvidence(for: $0) }
        }
        return kept.count >= 2 ? kept : experts
    }

    /// Which domains have concrete supporting evidence in the retrieval set.
    private struct Evidence {
        let contract: Bool
        let finance: Bool
        let project: Bool
        let email: Bool
        let anyEvents: Bool

        init(_ r: RetrievalResult) {
            let eventKinds = Set(r.events.map(\.kind))
            let entityKinds = Set(r.entities.map(\.kind))
            contract = eventKinds.contains(.contractSigned) || eventKinds.contains(.contractModified)
            finance = eventKinds.contains(.invoiceIssued) || eventKinds.contains(.invoicePaid)
                || !entityKinds.isDisjoint(with: [.money, .currency, .invoiceNumber, .paymentID])
            project = eventKinds.contains(.taskAssigned) || eventKinds.contains(.deliveryDelayed)
                || eventKinds.contains(.deliveryCompleted) || eventKinds.contains(.meetingHeld)
                || !entityKinds.isDisjoint(with: [.project, .deliverable, .milestone])
            email = eventKinds.contains(.emailSent) || eventKinds.contains(.emailReceived)
                || entityKinds.contains(.emailAddress)
            anyEvents = !r.events.isEmpty
        }

        func hasEvidence(for domain: ExpertDomain) -> Bool {
            switch domain {
            case .legal:     return contract
            case .financial: return finance
            case .project:   return project
            case .timeline:  return anyEvents
            case .email:     return email
            case .research, .ocr: return true   // generalists — always relevant
            }
        }
    }

    /// Mirror of ExpertRegistry.domains(for:) — kept local so the scorer is
    /// self-contained. If that intent→domain mapping changes, update both.
    private static func domains(for intent: UserIntent) -> Set<ExpertDomain> {
        switch intent.kind {
        case .reconstructTimeline, .reconstructProject: return [.timeline, .project, .email]
        case .reconstructRelationship:                  return [.email, .timeline, .project, .financial]
        case .executiveBriefing:                        return [.project, .financial, .legal, .email]
        case .riskDetection:                            return [.legal, .financial, .project]
        case .missingInformation:                       return [.project, .timeline]
        case .factualLookup, .semanticSearch, .unknown: return []
        }
    }
}
