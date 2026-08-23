//
//  HistoryMaterial.swift
//  Kalsmritikosh
//
//  HIST-030 (Universal History program, Phase 2). The complete, ID-scoped bundle of
//  raw material collected for a resolved subject — events, assertions, typed facts,
//  relationships — plus the union of evidence object ids and a provenance record of
//  WHY the set has the shape it does. This is the deterministic input to temporal
//  projection and reconciliation; it never contains "recent global" activity.
//

import Foundation

public nonisolated struct HistoryMaterial: Sendable {
    public let subject: ResolvedHistorySubject
    public let events: [Event]
    public let assertions: [Assertion]
    public let genericFacts: [GenericFact]
    public let relationships: [Relationship]
    /// Union of every source KnowledgeObject the material touches (deduped, stable order).
    public let evidenceObjectIDs: [KnowledgeObject.ID]
    /// First-degree related entity ids (from relationships), for optional expansion.
    public let firstDegreeEntityIDs: [Entity.ID]
    public let provenance: MaterialProvenance

    public var isEmpty: Bool {
        events.isEmpty && assertions.isEmpty && genericFacts.isEmpty && relationships.isEmpty
    }
    public var totalItems: Int {
        events.count + assertions.count + genericFacts.count + relationships.count
    }

    public nonisolated init(
        subject: ResolvedHistorySubject,
        events: [Event] = [],
        assertions: [Assertion] = [],
        genericFacts: [GenericFact] = [],
        relationships: [Relationship] = [],
        evidenceObjectIDs: [KnowledgeObject.ID] = [],
        firstDegreeEntityIDs: [Entity.ID] = [],
        provenance: MaterialProvenance
    ) {
        self.subject = subject
        self.events = events
        self.assertions = assertions
        self.genericFacts = genericFacts
        self.relationships = relationships
        self.evidenceObjectIDs = evidenceObjectIDs
        self.firstDegreeEntityIDs = firstDegreeEntityIDs
        self.provenance = provenance
    }
}

/// Records how the material set was assembled (collection rule 9: "record why each
/// item entered"). Kept as a structured summary, not per-item, for Phase 2.
public struct MaterialProvenance: Sendable, Hashable {
    public let canonicalEntityID: Entity.ID?
    public let eventCount: Int
    public let assertionCount: Int
    public let genericFactCount: Int
    public let relationshipCount: Int
    /// True when the subject had no canonical id (topic/folder/corpus) — collection
    /// is deferred to a later phase and the material is empty by design, NOT a
    /// silent global fallback.
    public let unscopedSubject: Bool

    public nonisolated init(
        canonicalEntityID: Entity.ID?, eventCount: Int, assertionCount: Int,
        genericFactCount: Int, relationshipCount: Int, unscopedSubject: Bool
    ) {
        self.canonicalEntityID = canonicalEntityID
        self.eventCount = eventCount
        self.assertionCount = assertionCount
        self.genericFactCount = genericFactCount
        self.relationshipCount = relationshipCount
        self.unscopedSubject = unscopedSubject
    }
}
