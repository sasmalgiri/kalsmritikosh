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

    /// F09 — per-kind TOTAL budgets (a guard against pathological subjects), NOT a page size: the
    /// collector pages through everything up to the budget, and any remainder is COUNTED into
    /// provenance as deferred — never silently truncated at a fixed first page.
    private let eventLimit: Int
    private let assertionLimit: Int
    private let relationshipLimit: Int
    private let pageSize: Int

    public init(
        events: EventsRepository,
        assertions: AssertionsRepository,
        genericFacts: GenericFactRepository,
        relationships: RelationshipsRepository,
        eventLimit: Int = 100_000,
        assertionLimit: Int = 100_000,
        relationshipLimit: Int = 20_000,
        pageSize: Int = 1_000
    ) {
        self.events = events
        self.assertions = assertions
        self.genericFacts = genericFacts
        self.relationships = relationships
        self.eventLimit = eventLimit
        self.assertionLimit = assertionLimit
        self.relationshipLimit = relationshipLimit
        self.pageSize = max(1, pageSize)
    }

    /// Page `fetch(offset, size)` until a short page or `budget` rows; returns rows + whether the
    /// budget stopped it (so the caller counts the remainder).
    private func pageAll<T>(budget: Int, _ fetch: (Int, Int) async throws -> [T]) async throws -> (rows: [T], capped: Bool) {
        var out: [T] = []
        while out.count < budget {
            let size = min(pageSize, budget - out.count)
            let page = try await fetch(out.count, size)
            out.append(contentsOf: page)
            if page.count < size { return (out, false) }
        }
        return (out, true)
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

        let evPaged = try await pageAll(budget: eventLimit) { try await events.allForEntity(id, offset: $0, pageSize: $1) }
        let asPaged = try await pageAll(budget: assertionLimit) {
            try await assertions.assertions(subjectKind: .entity, subjectID: id, offset: $0, pageSize: $1)
        }
        let relPaged = try await pageAll(budget: relationshipLimit) { try await relationships.neighbors(of: id, offset: $0, pageSize: $1) }
        let evs = evPaged.rows, asserts = asPaged.rows, rels = relPaged.rows
        let facts = try await genericFacts.facts(subjectID: id)
        let deferredEvents = evPaged.capped ? max(0, try await events.countForEntity(id) - evs.count) : 0
        let deferredAssertions = asPaged.capped ? max(0, try await assertions.count(subjectKind: .entity, subjectID: id) - asserts.count) : 0
        let deferredRelationships = relPaged.capped ? max(0, try await relationships.neighborCount(of: id) - rels.count) : 0

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
                genericFactCount: facts.count, relationshipCount: rels.count, unscopedSubject: false,
                deferredEventCount: deferredEvents, deferredAssertionCount: deferredAssertions,
                deferredRelationshipCount: deferredRelationships))
    }
}
