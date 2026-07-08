//
//  MemoryObject.swift
//  Kalsmritikosh
//
//  The Knowledge Memory layer. One MemoryObject per subject (project,
//  organization, person, deliverable, topic). Holds the distilled state
//  of everything Kalsmritikosh knows about that subject so the brain can answer
//  questions without re-reading hundreds of source documents.
//
//  Persisted as the latest snapshot per subject; mutations append a
//  MemoryChange row so the brain can later answer "what changed?".
//

import Foundation

public struct MemoryObject: Codable, Identifiable, Hashable, Sendable {
    public typealias ID = UUID

    public let id: ID
    public let subjectKind: SubjectKind
    public let subjectIdentifier: String   // normalized entity value
    public let keyDecisions: [Decision]
    public let keyEventIDs: [Event.ID]
    public let importantRelationshipIDs: [Relationship.ID]
    public let risks: [Risk]
    public let status: String
    public let narrative: String           // LLM-generated; refreshed on change
    public let sourceObjectIDs: [KnowledgeObject.ID]
    public let confidence: Confidence
    public let version: Int
    public let createdAt: Date
    public let updatedAt: Date
    /// HISTORY Phase A — best (highest-trust) tier across this
    /// subject's contributing events. T1 if any event is T1, else
    /// T2 if any event is T2, else T3.
    public let qualityTier: QualityTier

    public nonisolated init(
        id: ID = UUID(),
        subjectKind: SubjectKind,
        subjectIdentifier: String,
        keyDecisions: [Decision] = [],
        keyEventIDs: [Event.ID] = [],
        importantRelationshipIDs: [Relationship.ID] = [],
        risks: [Risk] = [],
        status: String = "active",
        narrative: String = "",
        sourceObjectIDs: [KnowledgeObject.ID] = [],
        confidence: Confidence = .medium,
        version: Int = 1,
        createdAt: Date = .init(),
        updatedAt: Date = .init(),
        qualityTier: QualityTier = .t2
    ) {
        self.id = id
        self.subjectKind = subjectKind
        self.subjectIdentifier = subjectIdentifier
        self.keyDecisions = keyDecisions
        self.keyEventIDs = keyEventIDs
        self.importantRelationshipIDs = importantRelationshipIDs
        self.risks = risks
        self.status = status
        self.narrative = narrative
        self.sourceObjectIDs = sourceObjectIDs
        self.confidence = confidence
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.qualityTier = qualityTier
    }

    public enum SubjectKind: String, Codable, Sendable, CaseIterable, Hashable {
        case project
        case organization
        case person
        case deliverable
        case topic
    }

    public struct Decision: Codable, Sendable, Hashable {
        public let summary: String
        public let madeOn: Date?
        public let sourceObjectID: KnowledgeObject.ID?
        public let confidence: Confidence

        public nonisolated init(
            summary: String,
            madeOn: Date? = nil,
            sourceObjectID: KnowledgeObject.ID? = nil,
            confidence: Confidence = .medium
        ) {
            self.summary = summary
            self.madeOn = madeOn
            self.sourceObjectID = sourceObjectID
            self.confidence = confidence
        }
    }

    public struct Risk: Codable, Sendable, Hashable {
        public let description: String
        public let severity: Severity
        public let sourceObjectIDs: [KnowledgeObject.ID]
        public let confidence: Confidence

        public nonisolated init(
            description: String,
            severity: Severity,
            sourceObjectIDs: [KnowledgeObject.ID] = [],
            confidence: Confidence = .medium
        ) {
            self.description = description
            self.severity = severity
            self.sourceObjectIDs = sourceObjectIDs
            self.confidence = confidence
        }

        public enum Severity: String, Codable, Sendable, CaseIterable, Hashable, Comparable {
            case low, medium, high, critical
            private var rank: Int {
                switch self {
                case .low: return 0; case .medium: return 1
                case .high: return 2; case .critical: return 3
                }
            }
            public static func < (lhs: Severity, rhs: Severity) -> Bool {
                lhs.rank < rhs.rank
            }
        }
    }
}
