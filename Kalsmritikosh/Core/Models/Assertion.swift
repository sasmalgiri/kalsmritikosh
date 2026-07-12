//
//  Assertion.swift
//  Kalsmritikosh
//
//  Phase J.19 — Vol 17 §A3 Assertion substrate. A subject-predicate-
//  object triple that sits between raw extraction and the typed
//  Event / Entity / Relationship tables. The full V17 §A3 refactor
//  would re-derive events from assertions; this slice ships the
//  substrate as ADDITIVE so user-asserted claims + future LLM
//  extractions can land without disturbing the existing pipeline.
//
//  Polymorphic object: an assertion's predicate can target another
//  entity ("Alice WORKS_FOR Acme"), an event ("Alice ATTENDED
//  meeting-2025-03-14"), or a literal value ("Alice HAS_TITLE
//  'Director'"). Exactly one of object_entity_id / object_event_id
//  / object_value is populated; the polymorphism stays out of the
//  application code by using `Object` cases.
//

import Foundation

public nonisolated struct Assertion: Sendable, Identifiable, Hashable {
    public typealias ID = UUID

    public enum SubjectKind: String, Codable, Sendable, Hashable {
        case entity
        case event
        case claim
    }

    public enum Object: Sendable, Hashable {
        case entity(Entity.ID)
        case event(Event.ID)
        case literal(String)

        public var kindRaw: String {
            switch self {
            case .entity:  return "entity"
            case .event:   return "event"
            case .literal: return "literal"
            }
        }
    }

    /// A5.2 — how this assertion came to be, the coarse epistemic origin that
    /// A5.5's full vocabulary refines. `sourceAsserted`: a source document
    /// states it. `directlyObserved`: the block IS the fact (e.g. a header
    /// field). `deterministicallyDerived`: computed by rule from evidence with
    /// no model. `inferred`: a model proposed it (lower trust).
    public enum Provenance: String, Codable, Sendable, Hashable {
        case sourceAsserted = "source_asserted"
        case directlyObserved = "directly_observed"
        case deterministicallyDerived = "deterministically_derived"
        case inferred = "inferred"
    }

    public let id: ID
    public let subjectKind: SubjectKind
    public let subjectID: UUID
    public let predicate: String   // e.g. "works_for", "located_in", "has_role"
    public let object: Object
    public let confidence: Double
    public let evidenceObjectIDs: [KnowledgeObject.ID]
    /// A5.2 — the specific structural evidence blocks that support this claim.
    public let evidenceBlockIDs: [EvidenceBlock.ID]
    /// A5.2 — the verbatim span from the source that carries the claim.
    public let directQuote: String?
    /// A5.2 — the source (version) that asserted it, distinct from `agent`
    /// (which is the extractor/actor that recorded the assertion).
    public let assertingSourceID: UUID?
    /// A5.2 — asserted-vs-derived origin.
    public let provenance: Provenance
    /// A5.2 — the extractor version that produced this assertion.
    public let extractorVersion: String
    public let agent: String       // "user", "system.llm", "system.ontology", …
    public let reason: String?
    public let recordedAt: Date
    public let retractedAt: Date?

    public nonisolated init(
        id: ID = UUID(),
        subjectKind: SubjectKind,
        subjectID: UUID,
        predicate: String,
        object: Object,
        confidence: Double = 0.5,
        evidenceObjectIDs: [KnowledgeObject.ID] = [],
        evidenceBlockIDs: [EvidenceBlock.ID] = [],
        directQuote: String? = nil,
        assertingSourceID: UUID? = nil,
        provenance: Provenance = .sourceAsserted,
        extractorVersion: String = "v1",
        agent: String = "user",
        reason: String? = nil,
        recordedAt: Date = Date(),
        retractedAt: Date? = nil
    ) {
        self.id = id
        self.subjectKind = subjectKind
        self.subjectID = subjectID
        self.predicate = predicate.lowercased()
        self.object = object
        self.confidence = max(0.0, min(1.0, confidence))
        self.evidenceObjectIDs = evidenceObjectIDs
        self.evidenceBlockIDs = evidenceBlockIDs
        self.directQuote = directQuote
        self.assertingSourceID = assertingSourceID
        self.provenance = provenance
        self.extractorVersion = extractorVersion
        self.agent = agent
        self.reason = reason
        self.recordedAt = recordedAt
        self.retractedAt = retractedAt
    }

    public var isRetracted: Bool { retractedAt != nil }
}
