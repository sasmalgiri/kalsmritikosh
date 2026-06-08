//
//  RelationshipExtractor.swift
//  Kalsmritikosh
//
//  Tier 1 graph extraction. Given the canonical entities + events for a
//  newly ingested KO, plus optional email participant hints, returns the
//  edges to upsert. Pure logic — caller persists via RelationshipsRepository.
//

import Foundation

public struct Tier1RelationshipExtractor: Sendable {
    /// Max canonical entities considered for co_occurs per KO. Above this
    /// the extractor picks the top-K by mention frequency. Caps the
    /// quadratic explosion on archive-shaped KOs (e.g. a mbox concatenated
    /// into one KO yielded ~6,500 distinct canonicals → 21M pairs without
    /// this guard). 30 → at most C(30,2) = 435 pairs per KO.
    public static let defaultCoOccurrenceCap = 30

    public struct Edge: Sendable, Hashable {
        public let kind: Relationship.Kind
        public let from: Entity.ID
        public let to: Entity.ID
        public let viaEventID: Event.ID?

        public init(
            kind: Relationship.Kind,
            from: Entity.ID,
            to: Entity.ID,
            viaEventID: Event.ID? = nil
        ) {
            self.kind = kind
            self.from = from
            self.to = to
            self.viaEventID = viaEventID
        }
    }

    public init() {}

    /// Produce edges for one KO.
    ///
    /// - canonicalEntityIDs: canonical entity ids appearing in this KO.
    /// - entityMentionFrequencies: mention count per canonical id in this
    ///   KO. When provided AND the distinct-canonical set exceeds
    ///   `coOccurrenceCap`, the extractor keeps only the top-K most-mentioned
    ///   canonicals for co_occurs edges. If empty, the first
    ///   `coOccurrenceCap` canonicals (in uuid order) are kept — deterministic
    ///   but signal-agnostic.
    /// - events: events extracted from this KO with their entity ids
    ///   already canonicalized.
    /// - emailParticipants: optional sender/recipients for email KOs.
    public func extract(
        objectID: KnowledgeObject.ID,
        canonicalEntityIDs: [Entity.ID],
        entityMentionFrequencies: [Entity.ID: Int] = [:],
        coOccurrenceCap: Int = Tier1RelationshipExtractor.defaultCoOccurrenceCap,
        events: [Event],
        emailParticipants: EmailParticipants? = nil
    ) -> [Edge] {
        var out: [Edge] = []

        // 1. Co-occurrence: each unordered pair of distinct canonicals,
        // capped to top-K by mention frequency to keep things sub-quadratic
        // on archive-shaped KOs.
        let distinct = Array(Set(canonicalEntityIDs))
        let capped: [Entity.ID]
        if distinct.count <= coOccurrenceCap {
            capped = distinct
        } else if entityMentionFrequencies.isEmpty {
            capped = Array(distinct.prefix(coOccurrenceCap))
        } else {
            capped = distinct
                .sorted {
                    let lf = entityMentionFrequencies[$0] ?? 0
                    let rf = entityMentionFrequencies[$1] ?? 0
                    if lf != rf { return lf > rf }
                    return $0.uuidString < $1.uuidString
                }
                .prefix(coOccurrenceCap)
                .map { $0 }
        }
        let sortedAll = capped.sorted { $0.uuidString < $1.uuidString }
        for i in 0..<sortedAll.count {
            for j in (i + 1)..<sortedAll.count {
                out.append(Edge(kind: .coOccurs, from: sortedAll[i], to: sortedAll[j]))
            }
        }

        // 2. Event-linked: pairs of entities that share an Event.
        // Already bounded by per-event entity count — no cap needed.
        for event in events {
            let evDistinct = Array(Set(event.entityIDs))
                .sorted { $0.uuidString < $1.uuidString }
            for i in 0..<evDistinct.count {
                for j in (i + 1)..<evDistinct.count {
                    out.append(Edge(
                        kind: .eventLinked,
                        from: evDistinct[i],
                        to: evDistinct[j],
                        viaEventID: event.id
                    ))
                }
            }
        }

        // 3. Email participants — sender → recipients (emailed) and
        // sender → sender-domain org (affiliated).
        if let p = emailParticipants {
            for recipient in p.recipientIDs where recipient != p.senderID {
                out.append(Edge(kind: .emailed, from: p.senderID, to: recipient))
            }
            if let orgID = p.senderDomainOrgID, orgID != p.senderID {
                out.append(Edge(kind: .affiliated, from: p.senderID, to: orgID))
            }
        }

        _ = objectID  // present in signature for future provenance use
        return out
    }

    /// Optional inputs for email-typed edges. Caller is responsible for
    /// resolving the canonical ids; if any of these are missing the
    /// corresponding edges simply aren't produced.
    public struct EmailParticipants: Sendable {
        public let senderID: Entity.ID
        public let recipientIDs: [Entity.ID]
        public let senderDomainOrgID: Entity.ID?

        public init(
            senderID: Entity.ID,
            recipientIDs: [Entity.ID],
            senderDomainOrgID: Entity.ID? = nil
        ) {
            self.senderID = senderID
            self.recipientIDs = recipientIDs
            self.senderDomainOrgID = senderDomainOrgID
        }
    }
}
