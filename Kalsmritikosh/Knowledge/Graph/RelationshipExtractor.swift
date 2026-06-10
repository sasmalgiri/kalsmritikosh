//
//  RelationshipExtractor.swift
//  Kalsmritikosh
//
//  Tier 1 graph extraction. Given the canonical entities + events for a
//  newly ingested KO, plus optional email participant hints, returns the
//  edges to upsert. Pure logic — caller persists via RelationshipsRepository.
//

import Foundation
import OSLog

public struct Tier1RelationshipExtractor: Sendable {
    /// Above this many distinct canonical entities in one KO, the
    /// extractor skips co_occurs entirely for that KO rather than emit
    /// pairwise edges. Co-occurrence is a document-level signal; a
    /// concatenated multi-year mbox isn't a document, so its pairwise
    /// edges are meaningless anyway. Once T13 splits mbox per message,
    /// per-message KOs always have <50 entities, the guard never fires,
    /// and full per-message co_occurrence comes back automatically.
    /// Replaced the original top-K-by-frequency cap because the highest-
    /// frequency tokens on an email archive are the garbage (Gmail,
    /// SMTP, Message-ID, weekdays, server names) — ranking by frequency
    /// kept exactly the noise and discarded the real, low-frequency
    /// people and companies. See UPDATE_04_REVISED.
    public static let coOccurrenceSkipThreshold = 200

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
    /// - skipThreshold: above this many distinct canonical entities, the
    ///   extractor skips co_occurs generation for this KO entirely
    ///   (event_linked / emailed / affiliated still fire). See
    ///   `coOccurrenceSkipThreshold`.
    /// - events: events extracted from this KO with their entity ids
    ///   already canonicalized.
    /// - emailParticipants: optional sender/recipients for email KOs.
    public func extract(
        objectID: KnowledgeObject.ID,
        canonicalEntityIDs: [Entity.ID],
        skipThreshold: Int = Tier1RelationshipExtractor.coOccurrenceSkipThreshold,
        events: [Event],
        emailParticipants: EmailParticipants? = nil
    ) -> [Edge] {
        var out: [Edge] = []

        // 1. Co-occurrence: each unordered pair of distinct canonicals
        // when the KO is document-shaped. Oversized KOs (e.g. a
        // concatenated mbox pre-T13) skip co_occurs entirely — their
        // pairwise edges aren't a real document-level signal anyway.
        let distinct = Array(Set(canonicalEntityIDs))
        if distinct.count > skipThreshold {
            AtlasLog.brain.info("skipped co_occurs: \(distinct.count, privacy: .public) entities in oversized KO \(objectID.uuidString, privacy: .public)")
        } else {
            let sortedAll = distinct.sorted { $0.uuidString < $1.uuidString }
            for i in 0..<sortedAll.count {
                for j in (i + 1)..<sortedAll.count {
                    out.append(Edge(kind: .coOccurs, from: sortedAll[i], to: sortedAll[j]))
                }
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
