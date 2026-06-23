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
//
//  Slot-aware bonds (party_a, party_b, amends, issued_by/_to,
//  invoice_for, delivers_for, owns, delivered_by) need the slot
//  extractors landing in G3.13/14 before they can be derived
//  reliably. The constructor skips them for now — they'll be added
//  in a follow-on commit once slot values are populated.
//
//  Idempotency is provided by the FactBondsRepository UNIQUE INDEX on
//  (bond_name, from_fact_id, to_fact_id); re-ingesting the same KO
//  bumps the weight + appends the source KO id to the evidence list.
//

import Foundation
import OSLog

public actor BondConstructor {

    public struct Context: Sendable {
        public let object: KnowledgeObject
        public let entities: [Entity]
        public let events: [Event]
        /// Pre-canonicalised entity ids — bond writes always use the
        /// canonical id, never a raw extractor id.
        public let canonicalMapping: [Entity.ID: Entity.ID]
        /// Optional — present only when the KO is an email AND the
        /// EmailLoader populated structured headers.
        public let emailParticipants: Tier1RelationshipExtractor.EmailParticipants?

        public nonisolated init(
            object: KnowledgeObject,
            entities: [Entity],
            events: [Event],
            canonicalMapping: [Entity.ID: Entity.ID],
            emailParticipants: Tier1RelationshipExtractor.EmailParticipants?
        ) {
            self.object = object
            self.entities = entities
            self.events = events
            self.canonicalMapping = canonicalMapping
            self.emailParticipants = emailParticipants
        }
    }

    private let repository: FactBondsRepository
    private let classifier: FactTypeClassifier
    private let minConfidence: Double

    public init(
        repository: FactBondsRepository,
        classifier: FactTypeClassifier = FactTypeClassifier(),
        minConfidence: Double = 0.5
    ) {
        self.repository = repository
        self.classifier = classifier
        self.minConfidence = minConfidence
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

            case .invoice, .delivery, .amendment, .person, .organization, .project:
                // Slot-driven bonds (issued_by, issued_to, invoice_for,
                // delivers_for, amends, owns, delivered_by) need the
                // slot extractor — wired in a follow-on G3.13/14 commit.
                continue
            }
        }

        guard !bonds.isEmpty else { return 0 }

        let deduped = dedupe(bonds)

        do {
            try await repository.upsertBonds(
                deduped,
                sourceObjectID: context.object.id,
                confidence: .medium
            )
            AtlasLog.knowledge.debug("BondConstructor: KO \(context.object.id.uuidString.prefix(8), privacy: .public) wrote \(deduped.count, privacy: .public) bond(s)")
            return deduped.count
        } catch {
            AtlasLog.knowledge.error("BondConstructor: upsert failed for KO \(context.object.id.uuidString.prefix(8), privacy: .public): \(String(describing: error), privacy: .public)")
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
