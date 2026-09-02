//
//  HistorySubject.swift
//  Kalsmritikosh
//
//  HIST-010/011 (Universal History program, Phase 1). Canonical, ID-based subject
//  identity for history reconstruction. NAMES ARE DISPLAY VALUES; IDENTITY IS AN ID.
//  This closes the trust hole where a named person could silently resolve to global
//  archive activity — a Dossier passes a resolved Entity.ID straight to the engine,
//  never a free-text string.
//
//  No model names / capability discipline: this is pure domain identity, no LLM.
//

import Foundation

/// What a history is *about*. Every entity-bearing case carries a canonical
/// `Entity.ID`; `topic`/`folder`/`corpus` are scope selectors without an entity.
public nonisolated enum HistorySubject: Sendable, Hashable, Codable {
    case entity(Entity.ID)
    case project(Entity.ID)
    case organization(Entity.ID)
    case person(Entity.ID)
    case place(Entity.ID)
    case asset(Entity.ID)
    case topic(UUID)
    case folder(String)
    case corpus

    /// The backing canonical entity id, when this subject is entity-scoped.
    public var entityID: Entity.ID? {
        switch self {
        case .entity(let id), .project(let id), .organization(let id),
             .person(let id), .place(let id), .asset(let id):
            return id
        case .topic, .folder, .corpus:
            return nil
        }
    }

    /// Stable tag for persistence (`history_artifacts.subject_kind`).
    public var kindTag: String {
        switch self {
        case .entity:       return "entity"
        case .project:      return "project"
        case .organization: return "organization"
        case .person:       return "person"
        case .place:        return "place"
        case .asset:        return "asset"
        case .topic:        return "topic"
        case .folder:       return "folder"
        case .corpus:       return "corpus"
        }
    }

    /// Map a canonical entity to the most specific subject case. Pure/deterministic.
    /// Unknown kinds fall back to `.entity` (still ID-scoped, never global).
    public static func forEntity(_ entity: Entity) -> HistorySubject {
        forKind(entity.kind, id: entity.id)
    }

    public static func forKind(_ kind: Entity.Kind, id: Entity.ID) -> HistorySubject {
        switch kind {
        case .person:
            return .person(id)
        case .organization, .vendor, .client:
            return .organization(id)
        case .project, .deliverable:
            return .project(id)
        case .address, .city, .country, .location:
            return .place(id)
        case .money, .currency, .invoiceNumber, .paymentID:
            return .asset(id)
        case .emailAddress, .phoneNumber, .date, .deadline, .milestone, .identifierAnchor, .other:
            return .entity(id)   // V3 anchors are ID-scoped subjects; History wiring is Phase A (scope fence)
        }
    }
}

/// A competing identity when a free-text query does not resolve to exactly one
/// subject. The resolver returns these instead of GUESSING (trust rule 3).
public struct SubjectCandidate: Sendable, Hashable, Identifiable {
    public let id: Entity.ID
    public let displayName: String
    public let kind: Entity.Kind
    public let mentionCount: Int
    public let score: Double
    public nonisolated init(id: Entity.ID, displayName: String, kind: Entity.Kind, mentionCount: Int, score: Double) {
        self.id = id; self.displayName = displayName; self.kind = kind
        self.mentionCount = mentionCount; self.score = score
    }
}

/// The resolved subject handed to the reconstruction engine.
public struct ResolvedHistorySubject: Sendable, Hashable {
    public let subject: HistorySubject
    public let displayName: String
    public let canonicalEntityID: Entity.ID?
    public let aliases: [String]
    public let resolutionConfidence: Double
    public let matchedEvidenceObjectIDs: [KnowledgeObject.ID]
    public let ambiguityCandidates: [SubjectCandidate]

    public nonisolated init(
        subject: HistorySubject,
        displayName: String,
        canonicalEntityID: Entity.ID?,
        aliases: [String] = [],
        resolutionConfidence: Double,
        matchedEvidenceObjectIDs: [KnowledgeObject.ID] = [],
        ambiguityCandidates: [SubjectCandidate] = []
    ) {
        self.subject = subject
        self.displayName = displayName
        self.canonicalEntityID = canonicalEntityID
        self.aliases = aliases
        self.resolutionConfidence = resolutionConfidence
        self.matchedEvidenceObjectIDs = matchedEvidenceObjectIDs
        self.ambiguityCandidates = ambiguityCandidates
    }
}

/// Outcome of resolving a FREE-TEXT subject query. Ambiguity is a first-class
/// result — the Dossier shows candidates and the user picks; the engine is never
/// invoked on a guess.
public enum HistoryResolution: Sendable {
    case resolved(ResolvedHistorySubject)
    case ambiguous([SubjectCandidate])
    case notFound(query: String)
}
