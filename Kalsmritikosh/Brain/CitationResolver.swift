//
//  CitationResolver.swift
//  Kalsmritikosh
//
//  P1 citation-integrity closure (release gate F3). The canonical resolution
//  authority for answer citations: every material citation emitted to a user
//  must resolve to a real canonical evidence/source identity through one of
//  the APPROVED RETRIEVAL LAYERS. A claim can legitimately be supported by a
//  chunk, an Event, a Relationship, a deterministic ClaimEvaluation, or an
//  authority document — so validity is membership in the UNION of those
//  layers, never the chunk-score map alone (the previously rejected unsafe
//  fix discarded valid entity/event/memory-layer citations merely because
//  they carried no chunk score).
//
//  Scope enforcement composes by construction: the RetrievalResult handed to
//  the verifier was already filtered by SensitiveRetrievalPolicy under the
//  request's SensitiveAccessContext, so an objectID pointing at a real but
//  scope-denied / wrong-workspace object cannot appear in the union and is
//  rejected here without re-querying the ledger.
//
//  The optional ledger probes close the remaining gap ("deleted/broken
//  target"): when wired (AppState), a citation must ALSO still exist in the
//  ledger at verification time. When a probe is nil (pure unit tests), the
//  union is the sole authority.
//

import Foundation

public struct CitationResolver: Sendable {
    /// Outcome of resolving one answer's citation list.
    public struct Resolution: Sendable {
        /// Citations that resolved to a real canonical source identity
        /// (order preserved; phantom eventID annotations scrubbed).
        public let citations: [VerifiedAnswer.Citation]
        /// objectIDs that resolved through NO approved layer — phantom
        /// citations, dropped from the answer.
        public let rejectedObjectIDs: [KnowledgeObject.ID]
        /// eventIDs that were attached to an otherwise-valid citation but
        /// do not resolve to a real Event — the annotation is removed, the
        /// citation itself survives on its objectID authority.
        public let scrubbedEventIDs: [Event.ID]
    }

    /// Ledger existence probe for KnowledgeObject IDs — returns the subset of
    /// the input that exists. nil → union-only resolution (unit tests).
    private let ledgerObjectProbe: (@Sendable (Set<KnowledgeObject.ID>) async -> Set<KnowledgeObject.ID>)?
    /// Ledger existence probe for Event IDs — returns the subset that exists.
    private let ledgerEventProbe: (@Sendable (Set<Event.ID>) async -> Set<Event.ID>)?

    public init(
        ledgerObjectProbe: (@Sendable (Set<KnowledgeObject.ID>) async -> Set<KnowledgeObject.ID>)? = nil,
        ledgerEventProbe: (@Sendable (Set<Event.ID>) async -> Set<Event.ID>)? = nil
    ) {
        self.ledgerObjectProbe = ledgerObjectProbe
        self.ledgerEventProbe = ledgerEventProbe
    }

    /// The union of source identities the retrieval layers actually returned
    /// for THIS request — the set of objectIDs a citation may legitimately
    /// carry. Layers: chunk retrieval, dated Events, Relationships,
    /// deterministic ClaimEvaluations (GenericFact evidence), and the
    /// document-fitness authority list (RET-009).
    public static func authorityUnion(of retrieval: RetrievalResult) -> Set<KnowledgeObject.ID> {
        var union = Set<KnowledgeObject.ID>()
        for rc in retrieval.chunks { union.insert(rc.chunk.objectID) }
        for event in retrieval.events { union.insert(event.sourceObjectID) }
        for rel in retrieval.relationships { union.insert(rel.sourceObjectID) }
        for eval in retrieval.claimEvaluations {
            for evidence in eval.evidence { union.insert(evidence.objectID) }
        }
        union.formUnion(retrieval.authorityObjectIDs)
        return union
    }

    /// Resolve a citation list against the approved layers of `retrieval`.
    /// Order is preserved for survivors so downstream ranking (reranker,
    /// MMR, intent caps) sees the same sequence it built.
    public func resolve(
        _ citations: [VerifiedAnswer.Citation],
        retrieval: RetrievalResult
    ) async -> Resolution {
        guard !citations.isEmpty else {
            return Resolution(citations: [], rejectedObjectIDs: [], scrubbedEventIDs: [])
        }

        let union = Self.authorityUnion(of: retrieval)
        var survivors: [VerifiedAnswer.Citation] = []
        var rejected: [KnowledgeObject.ID] = []
        for citation in citations {
            if union.contains(citation.objectID) {
                survivors.append(citation)
            } else {
                rejected.append(citation.objectID)
            }
        }

        // Deleted/broken-target guard: the union proves the ID came from this
        // request's scope-filtered retrieval; the probe proves the target is
        // still a real ledger row at verification time.
        if let ledgerObjectProbe, !survivors.isEmpty {
            let existing = await ledgerObjectProbe(Set(survivors.map(\.objectID)))
            var stillValid: [VerifiedAnswer.Citation] = []
            for citation in survivors {
                if existing.contains(citation.objectID) {
                    stillValid.append(citation)
                } else {
                    rejected.append(citation.objectID)
                }
            }
            survivors = stillValid
        }

        // Event-annotation integrity: an eventID must name a real Event —
        // either one this retrieval returned, or (when the probe is wired)
        // one that exists in the ledger. A phantom eventID is scrubbed but
        // the citation keeps its objectID authority.
        var knownEventIDs = Set(retrieval.events.map(\.id))
        let unproven = Set(survivors.compactMap(\.eventID)).subtracting(knownEventIDs)
        if !unproven.isEmpty, let ledgerEventProbe {
            knownEventIDs.formUnion(await ledgerEventProbe(unproven))
        }
        var scrubbed: [Event.ID] = []
        let resolved = survivors.map { citation -> VerifiedAnswer.Citation in
            guard let eventID = citation.eventID, !knownEventIDs.contains(eventID) else {
                return citation
            }
            scrubbed.append(eventID)
            return VerifiedAnswer.Citation(
                objectID: citation.objectID,
                chunkID: citation.chunkID,
                eventID: nil,
                snippet: citation.snippet
            )
        }

        return Resolution(
            citations: resolved,
            rejectedObjectIDs: rejected,
            scrubbedEventIDs: scrubbed
        )
    }
}
