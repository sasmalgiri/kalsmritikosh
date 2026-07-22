//
//  HistoryMaterialCollector.swift
//  Kalsmritikosh
//
//  HIST-030 (Universal History program, Phase 2). Gathers ALL material connected to
//  a resolved subject BY CANONICAL ENTITY ID — events, assertions, typed facts,
//  first-degree relationships — and unions their evidence footprint. Deterministic
//  and LLM-free (capability discipline). Query-by-id first; never "recent global
//  events" as a hidden fallback (trust rule 3 / collection rule 10). Topic/folder/
//  corpus subjects have no canonical id yet — they return empty material flagged
//  `unscopedSubject`, NOT global activity.
//

import Foundation

public struct HistoryMaterialCollector: Sendable {
    private let events: EventsRepository
    private let assertions: AssertionsRepository
    private let genericFacts: GenericFactRepository
    private let relationships: RelationshipsRepository

    private let eventLimit: Int
    private let assertionLimit: Int
    private let relationshipLimit: Int

    public init(
        events: EventsRepository,
        assertions: AssertionsRepository,
        genericFacts: GenericFactRepository,
        relationships: RelationshipsRepository,
        eventLimit: Int = 5_000,
        assertionLimit: Int = 5_000,
        relationshipLimit: Int = 500
    ) {
        self.events = events
        self.assertions = assertions
        self.genericFacts = genericFacts
        self.relationships = relationships
        self.eventLimit = eventLimit
        self.assertionLimit = assertionLimit
        self.relationshipLimit = relationshipLimit
    }

    public func collect(for subject: ResolvedHistorySubject) async throws -> HistoryMaterial {
        guard let id = subject.canonicalEntityID else {
            // Topic/folder/corpus scope: deferred (later phase). Empty, but flagged —
            // NEVER substituted with global archive activity.
            return HistoryMaterial(
                subject: subject,
                provenance: MaterialProvenance(
                    canonicalEntityID: nil, eventCount: 0, assertionCount: 0,
                    genericFactCount: 0, relationshipCount: 0, unscopedSubject: true))
        }

        let evs = try await events.allForEntity(id, pageSize: eventLimit)
        let asserts = try await assertions.assertions(subjectKind: .entity, subjectID: id, limit: assertionLimit)
        let facts = try await genericFacts.facts(subjectID: id)
        let rels = try await relationships.neighbors(of: id, limit: relationshipLimit)

        // Union the evidence footprint across every material type, deterministic order.
        var seen = Set<KnowledgeObject.ID>()
        var evidence: [KnowledgeObject.ID] = []
        func add(_ oid: KnowledgeObject.ID) { if seen.insert(oid).inserted { evidence.append(oid) } }
        subject.matchedEvidenceObjectIDs.forEach(add)
        evs.forEach { add($0.sourceObjectID) }
        asserts.forEach { $0.evidenceObjectIDs.forEach(add) }
        rels.forEach { add($0.sourceObjectID) }
        evidence.sort { $0.uuidString < $1.uuidString }

        // First-degree neighbours (the "other end" of each relationship).
        var neighbourSeen = Set<Entity.ID>()
        var neighbours: [Entity.ID] = []
        for r in rels {
            let other = r.fromEntityID == id ? r.toEntityID : r.fromEntityID
            if other != id, neighbourSeen.insert(other).inserted { neighbours.append(other) }
        }
        neighbours.sort { $0.uuidString < $1.uuidString }

        return HistoryMaterial(
            subject: subject,
            events: evs,
            assertions: asserts,
            genericFacts: facts,
            relationships: rels,
            evidenceObjectIDs: evidence,
            firstDegreeEntityIDs: neighbours,
            provenance: MaterialProvenance(
                canonicalEntityID: id, eventCount: evs.count, assertionCount: asserts.count,
                genericFactCount: facts.count, relationshipCount: rels.count, unscopedSubject: false))
    }
}
