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
    /// - events: events extracted from this KO with their entity ids
    ///   already canonicalized.
    /// - emailParticipants: optional sender/recipients for email KOs.
    public func extract(
        objectID: KnowledgeObject.ID,
        canonicalEntityIDs: [Entity.ID],
        events: [Event],
        emailParticipants: EmailParticipants? = nil
    ) -> [Edge] {
        var out: [Edge] = []

        // 1. Co-occurrence: each unordered pair of distinct canonicals.
        let distinct = Array(Set(canonicalEntityIDs))
        let sortedAll = distinct.sorted { $0.uuidString < $1.uuidString }
        for i in 0..<sortedAll.count {
            for j in (i + 1)..<sortedAll.count {
                out.append(Edge(kind: .coOccurs, from: sortedAll[i], to: sortedAll[j]))
            }
        }

        // 2. Event-linked: pairs of entities that share an Event.
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
