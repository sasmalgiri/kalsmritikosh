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

    public let id: ID
    public let subjectKind: SubjectKind
    public let subjectID: UUID
    public let predicate: String   // e.g. "works_for", "located_in", "has_role"
    public let object: Object
    public let confidence: Double
    public let evidenceObjectIDs: [KnowledgeObject.ID]
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
        self.agent = agent
        self.reason = reason
        self.recordedAt = recordedAt
        self.retractedAt = retractedAt
    }

    public var isRetracted: Bool { retractedAt != nil }
}
