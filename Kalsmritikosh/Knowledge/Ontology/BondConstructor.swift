//
//  BondConstructor.swift
//  Kalsmritikosh
//
//  G3.10/G3.12 — walk the per-KO context against `Ontology.rules` and
//  construct typed bonds: who is bonded to whom, and by which rule.
//  Pure derivation logic; persistence is delegated to
//  `FactBondsRepository.upsertBonds`.
//
//  The MVP focuses on the bonds we can build cheaply at ingest time
//  from already-extracted structured signals:
//
//    - affiliated_with(Person→Organization)
//      Source: email sender's domain → org alias (already wired in
//      IngestCoordinator.writeDomainAliases).
//
//    - sent_by(Email-event→Person)         via emailParticipants.senderID
//    - received_by(Email-event→Person)     via emailParticipants.recipientIDs
//    - discusses(Email-event→Project)      via project entity in event.entityIDs
//    - about(Meeting-event→Project)        via project entity in event.entityIDs
//    - attended_by(Meeting-event→Person)   via person entity in event.entityIDs
//    - signed_by(Contract-event→Person)    via person entity in event.entityIDs
//    - made_by(Decision-event→Person)      via person entity in event.entityIDs
//    - issued_by(Invoice-event→Org)        via sender domain org (email path)
//    - issued_to(Invoice-event→Org)        via org entity in event.entityIDs
//    - invoice_for(Invoice-event→Project)  via project entity in event.entityIDs
//    - delivers_for(Delivery-event→Project) via project entity in event.entityIDs
//    - delivered_by(Project→Org)           via org entity in delivery event
//    - amends(Amendment-event→Contract)    via same-KO contract event
//    - party_a(Contract-event→Org)         via first org in canonical id order
//    - party_b(Contract-event→Org)         via second org in canonical id order
//
//  Only `owns` (Person → Project) is still deferred — it genuinely
//  needs Project.owner_person populated by the G3.14 LLM slot extractor.
//  16 of 17 v1 bonds are wired here at ingest; cross-KO amends
//  (the typical multi-document case) is left for a future backfill pass.
//
//  Idempotency is provided by the FactBondsRepository UNIQUE INDEX on
//  (bond_name, from_fact_id, to_fact_id); re-ingesting the same KO
//  bumps the weight + appends the source KO id to the evidence list.
//

import Foundation
import OSLog

public actor BondConstructor {

    public struct Context: Sendable {
        /// The source KO id all bonds in this batch attribute back to.
        /// Was `object: KnowledgeObject` in earlier revisions; BondBackfill
        /// only has the id (not the full object), so the contract is
        /// narrowed to the id since that's the only field the
        /// constructor actually reads.
        public let objectID: KnowledgeObject.ID
        public let entities: [Entity]
        public let events: [Event]
        /// Pre-canonicalised entity ids — bond writes always use the
        /// canonical id, never a raw extractor id.
        public let canonicalMapping: [Entity.ID: Entity.ID]
        /// Optional — present only when the KO is an email AND the
        /// EmailLoader populated structured headers.
        public let emailParticipants: Tier1RelationshipExtractor.EmailParticipants?

        public nonisolated init(
            objectID: KnowledgeObject.ID,
            entities: [Entity],
            events: [Event],
            canonicalMapping: [Entity.ID: Entity.ID],
            emailParticipants: Tier1RelationshipExtractor.EmailParticipants?
        ) {
            self.objectID = objectID
            self.entities = entities
            self.events = events
            self.canonicalMapping = canonicalMapping
            self.emailParticipants = emailParticipants
        }
    }

    private let repository: FactBondsRepository
    private let classifier: FactTypeClassifier
    private let minConfidence: Double
    /// Optional cache patch — when wired, every successfully written
    /// bond also lands in the in-memory adjacency so newly-ingested
    /// KOs are walkable immediately (no wait for next cold boot).
    private let cache: InMemoryBondGraph?

    public init(
        repository: FactBondsRepository,
        classifier: FactTypeClassifier = FactTypeClassifier(),
        minConfidence: Double = 0.5,
        cache: InMemoryBondGraph? = nil
    ) {
        self.repository = repository
        self.classifier = classifier
        self.minConfidence = minConfidence
        self.cache = cache
    }

    /// Build the bond set for this KO and upsert in a single batched
    /// transaction. Returns the count of bond rows written/updated.
    @discardableResult
    public func construct(_ context: Context) async -> Int {
        var bonds: [FactBondsRepository.BondUpsert] = []

        // Classify entities once — the bond engine only needs FactType
        // to decide whether an entity can stand on the `to` side of a
        // rule (e.g. discusses → Project requires the target to classify
        // as .project).
        var entityFactTypes: [Entity.ID: FactType] = [:]
        for entity in context.entities {
            let canonical = context.canonicalMapping[entity.id] ?? entity.id
            if let result = classifier.classify(entity: entity),
               result.confidence >= minConfidence {
                entityFactTypes[canonical] = result.type
            }
        }

        // 1. affiliated_with — sender Person → sender domain Org.
        //    We treat the senderID (emailAddress entity) as standing in
        //    for the Person fact (1:1 in the v1 ontology where Person
        //    isn't reliably named in headers). Schema-aware retrieval
        //    can still walk `affiliated_with` by bond name.
        if let participants = context.emailParticipants,
           let orgID = participants.senderDomainOrgID {
            bonds.append(.init(
                bondName: "affiliated_with",
                fromKind: .entity,
                fromID: participants.senderID,
                toKind: .entity,
                toID: orgID
            ))
        }

        // 2. Event-anchored bonds. Walk each event whose kind classifies
        //    as a recognised FactType and emit the bonds whose `from`
        //    side matches the event's FactType.
        for event in context.events {
            guard let eventType = classifier.classify(event: event)?.type else {
                continue
            }

            switch eventType {
            case .email:
                if let participants = context.emailParticipants {
                    bonds.append(.init(
                        bondName: "sent_by",
                        fromKind: .event,
                        fromID: event.id,
                        toKind: .entity,
                        toID: participants.senderID
                    ))
                    for recipientID in participants.recipientIDs {
                        bonds.append(.init(
                            bondName: "received_by",
                            fromKind: .event,
                            fromID: event.id,
                            toKind: .entity,
                            toID: recipientID
                        ))
                    }
                }
                for projectID in projectEntityIDs(in: event, factTypes: entityFactTypes) {
                    bonds.append(.init(
                        bondName: "discusses",
                        fromKind: .event,
                        fromID: event.id,
                        toKind: .entity,
                        toID: projectID
                    ))
                }

            case .meeting:
                for projectID in projectEntityIDs(in: event, factTypes: entityFactTypes) {
                    bonds.append(.init(
                        bondName: "about",
                        fromKind: .event,
                        fromID: event.id,
                        toKind: .entity,
                        toID: projectID
                    ))
                }
                for personID in personEntityIDs(in: event, factTypes: entityFactTypes) {
                    bonds.append(.init(
                        bondName: "attended_by",
                        fromKind: .event,
                        fromID: event.id,
                        toKind: .entity,
                        toID: personID
                    ))
                }

            case .contract:
                for personID in personEntityIDs(in: event, factTypes: entityFactTypes) {
                    bonds.append(.init(
                        bondName: "signed_by",
                        fromKind: .event,
                        fromID: event.id,
                        toKind: .entity,
                        toID: personID
                    ))
                }
                // party_a / party_b — the first two distinct
                // Organization entities (by canonical id order) become
                // the contract's two counterparties. Cardinality
                // .zeroOrOne per bond ensures we never emit more than
                // one of each.
                let orgs = organizationEntityIDs(in: event, factTypes: entityFactTypes)
                    .sorted(by: { $0.uuidString < $1.uuidString })
                if let a = orgs.first {
                    bonds.append(.init(
                        bondName: "party_a",
                        fromKind: .event,
                        fromID: event.id,
                        toKind: .entity,
                        toID: a
                    ))
                }
                if orgs.count >= 2 {
                    bonds.append(.init(
                        bondName: "party_b",
                        fromKind: .event,
                        fromID: event.id,
                        toKind: .entity,
                        toID: orgs[1]
                    ))
                }

            case .decision:
                for personID in personEntityIDs(in: event, factTypes: entityFactTypes) {
                    bonds.append(.init(
                        bondName: "made_by",
                        fromKind: .event,
                        fromID: event.id,
                        toKind: .entity,
                        toID: personID
                    ))
                }

            case .invoice:
                // issued_by / issued_to come from the email participants
                // when the invoice was carried by an email — the sender's
                // org issued it, the recipients' org received it. The KO
                // pipeline writes a domain-org alias at ingest time
                // (writeDomainAliases) so the org entity is available.
                if let participants = context.emailParticipants,
                   let orgID = participants.senderDomainOrgID {
                    bonds.append(.init(
                        bondName: "issued_by",
                        fromKind: .event,
                        fromID: event.id,
                        toKind: .entity,
                        toID: orgID
                    ))
                }
                for orgID in organizationEntityIDs(in: event, factTypes: entityFactTypes) {
                    // The sender's org also lands in event.entityIDs via
                    // the EmailLoader; skip it to avoid double-counting
                    // it as the recipient.
                    if let participants = context.emailParticipants,
                       participants.senderDomainOrgID == orgID {
                        continue
                    }
                    bonds.append(.init(
                        bondName: "issued_to",
                        fromKind: .event,
                        fromID: event.id,
                        toKind: .entity,
                        toID: orgID
                    ))
                }
                for projectID in projectEntityIDs(in: event, factTypes: entityFactTypes) {
                    bonds.append(.init(
                        bondName: "invoice_for",
                        fromKind: .event,
                        fromID: event.id,
                        toKind: .entity,
                        toID: projectID
                    ))
                }

            case .delivery:
                for projectID in projectEntityIDs(in: event, factTypes: entityFactTypes) {
                    bonds.append(.init(
                        bondName: "delivers_for",
                        fromKind: .event,
                        fromID: event.id,
                        toKind: .entity,
                        toID: projectID
                    ))
                    // delivered_by — Project → Organization. Pulls org
                    // from the delivery event's participants OR from
                    // the sender's domain when an email carries the
                    // delivery notification.
                    var orgs = organizationEntityIDs(in: event, factTypes: entityFactTypes)
                    if let domainOrg = context.emailParticipants?.senderDomainOrgID,
                       !orgs.contains(domainOrg) {
                        orgs.append(domainOrg)
                    }
                    for orgID in orgs {
                        bonds.append(.init(
                            bondName: "delivered_by",
                            fromKind: .entity,
                            fromID: projectID,
                            toKind: .entity,
                            toID: orgID
                        ))
                    }
                }

            case .amendment:
                // Same-KO amends — when a single document produces BOTH
                // a contract event and an amendment event, the
                // amendment likely amends that contract. Cross-KO
                // amends (the typical case, e.g. amendment-7.md
                // amending contract.md) requires a backfill traversal
                // and is left for a future Ontology pass.
                let sameKOContracts = context.events.filter { other in
                    other.id != event.id
                        && classifier.classify(event: other)?.type == .contract
                }
                for contract in sameKOContracts {
                    bonds.append(.init(
                        bondName: "amends",
                        fromKind: .event,
                        fromID: event.id,
                        toKind: .event,
                        toID: contract.id
                    ))
                }

            case .person, .organization, .project:
                // `owns` (Person → Project) needs Project.owner_person
                // populated by the G3.14 LLM extractor. Deferred.
                continue
            }
        }

        guard !bonds.isEmpty else { return 0 }

        let deduped = dedupe(bonds)

        do {
            let newlyWritten = try await repository.upsertBonds(
                deduped,
                sourceObjectID: context.objectID,
                confidence: .medium
            )
            // Patch the in-memory adjacency for every NEWLY-inserted
            // bond so retrieval queries on the just-ingested KO walk
            // the live graph instead of waiting for next cold boot.
            if let cache, !newlyWritten.isEmpty {
                for bond in newlyWritten {
                    await cache.noteBond(bond)
                }
            }
            KalsmritikoshLog.knowledge.debug("BondConstructor: KO \(context.objectID.uuidString.prefix(8), privacy: .public) wrote \(deduped.count, privacy: .public) bond(s), \(newlyWritten.count, privacy: .public) new")
            return deduped.count
        } catch {
            KalsmritikoshLog.knowledge.error("BondConstructor: upsert failed for KO \(context.objectID.uuidString.prefix(8), privacy: .public): \(String(describing: error), privacy: .public)")
            return 0
        }
    }

    // MARK: - Helpers

    /// Project entities participating in this event (canonical ids).
    private func projectEntityIDs(
        in event: Event,
        factTypes: [Entity.ID: FactType]
    ) -> [Entity.ID] {
        event.entityIDs.filter { factTypes[$0] == .project }
    }

    /// Person-like entities. We accept either an entity that classifies
    /// as Person (e.g. NLTagger-tagged proper noun) OR an emailAddress
    /// (Person stand-in in v1). Bonds emitted against emailAddress can
    /// be re-pointed at a true Person entity in v2 once slot extraction
    /// populates Email.sender_person.
    private func personEntityIDs(
        in event: Event,
        factTypes: [Entity.ID: FactType]
    ) -> [Entity.ID] {
        // Person-classified ids.
        let people = event.entityIDs.filter { factTypes[$0] == .person }
        guard people.isEmpty else { return people }
        // No Person in the event — no fallback. Email events use the
        // explicit emailParticipants path; other event kinds without a
        // Person participant emit nothing.
        return []
    }

    /// Organization entities participating in this event (canonical
    /// ids). Used by Invoice → issued_by / issued_to.
    private func organizationEntityIDs(
        in event: Event,
        factTypes: [Entity.ID: FactType]
    ) -> [Entity.ID] {
        event.entityIDs.filter { factTypes[$0] == .organization }
    }

    /// Bonds can repeat within a single KO context (a Person mentioned
    /// twice on a meeting, etc.). The UNIQUE INDEX in the repo would
    /// merge them anyway, but pre-deduping saves a UPDATE round-trip.
    private func dedupe(_ bonds: [FactBondsRepository.BondUpsert]) -> [FactBondsRepository.BondUpsert] {
        var seen = Set<String>()
        var out: [FactBondsRepository.BondUpsert] = []
        for bond in bonds {
            let key = "\(bond.bondName)|\(bond.fromID.uuidString)|\(bond.toID.uuidString)"
            if seen.insert(key).inserted {
                out.append(bond)
            }
        }
        return out
    }
}
