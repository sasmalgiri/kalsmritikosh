//
//  InvestigationHypothesis.swift
//  Kalsmritikosh
//
//  INV-04..07 — the Investigator analytical-spine domain (schema v99). Persona reasoning state bounded to a
//  case. These value types REFERENCE canonical evidence (source versions + knowledge objects) by id; they
//  fork no Claim / contradiction / gap authority. Four truth boundaries this model preserves:
//    • an idea is never a fact          (a lead/hypothesis is typed reasoning, not a Claim)
//    • proposal ≠ hypothesis            (a lead is PROMOTED into a hypothesis by a human decision)
//    • unsupported stays a proposal     (a hypothesis is CONFIRMED by a human, never auto-won)
//    • an unknown is never fabricated   (a 5W1H cell either cites exact evidence or is marked unknown)
//

import Foundation

// MARK: - INV-04 leads / INV-07 hypotheses

/// A lead is a captured idea (INV-04); it is promoted into a hypothesis (INV-07). Same table, one discriminator.
public nonisolated enum HypothesisKind: String, Codable, Sendable, Equatable, CaseIterable {
    case lead
    case hypothesis
}

/// The human decision status. A hypothesis is never auto-confirmed; an unsupported one stays `proposed`.
public nonisolated enum HypothesisStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case proposed
    case confirmed
    case rejected
    case dismissed
}

public nonisolated struct InvestigationHypothesis: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID
    public let kind: HypothesisKind
    public let statement: String
    public let status: HypothesisStatus
    public let originHypothesisID: UUID?     // a promoted hypothesis links back to the lead it came from
    public let revision: Int
    public let actor: String
    public let createdAt: Date
    public let updatedAt: Date

    public nonisolated init(id: UUID, caseID: UUID, kind: HypothesisKind, statement: String, status: HypothesisStatus,
                            originHypothesisID: UUID?, revision: Int, actor: String, createdAt: Date, updatedAt: Date) {
        self.id = id; self.caseID = caseID; self.kind = kind; self.statement = statement; self.status = status
        self.originHypothesisID = originHypothesisID; self.revision = revision; self.actor = actor
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

/// A for/against evidence link (INV-07). Cites EXACT evidence — a source version + knowledge object.
public nonisolated enum EvidenceStance: String, Codable, Sendable, Equatable, CaseIterable {
    case supporting = "for"
    case opposing = "against"
}

public nonisolated struct HypothesisEvidenceLink: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let hypothesisID: UUID
    public let stance: EvidenceStance
    public let sourceVersionID: UUID
    public let knowledgeObjectID: UUID
    public let note: String?
    public let addedBy: String
    public let createdAt: Date

    public nonisolated init(id: UUID, hypothesisID: UUID, stance: EvidenceStance, sourceVersionID: UUID,
                            knowledgeObjectID: UUID, note: String?, addedBy: String, createdAt: Date) {
        self.id = id; self.hypothesisID = hypothesisID; self.stance = stance; self.sourceVersionID = sourceVersionID
        self.knowledgeObjectID = knowledgeObjectID; self.note = note; self.addedBy = addedBy; self.createdAt = createdAt
    }
}

/// The counted evidence profile for a hypothesis (INV-07 "compute evidence profile"). Deterministic counts,
/// never a verdict — `isSupported` is a factual "more for than against", not a decision to confirm.
public nonisolated struct HypothesisEvidenceProfile: Sendable, Equatable {
    public let forCount: Int
    public let againstCount: Int
    public nonisolated init(forCount: Int, againstCount: Int) { self.forCount = forCount; self.againstCount = againstCount }
    public nonisolated var total: Int { forCount + againstCount }
    /// A hypothesis with no supporting evidence is UNSUPPORTED and may not be confirmed (it stays a proposal).
    public nonisolated var isSupported: Bool { forCount > 0 && forCount >= againstCount }
}

// MARK: - INV-06 evidence requests

public nonisolated enum EvidenceRequestStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case open
    case confirmed
    case fulfilled
    case cancelled
}

public nonisolated struct EvidenceRequest: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID
    public let hypothesisID: UUID?
    public let description: String
    public let status: EvidenceRequestStatus
    public let revision: Int
    public let actor: String
    public let createdAt: Date
    public let updatedAt: Date

    public nonisolated init(id: UUID, caseID: UUID, hypothesisID: UUID?, description: String, status: EvidenceRequestStatus,
                            revision: Int, actor: String, createdAt: Date, updatedAt: Date) {
        self.id = id; self.caseID = caseID; self.hypothesisID = hypothesisID; self.description = description
        self.status = status; self.revision = revision; self.actor = actor; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

// MARK: - INV-05 5W1H worksheet

public nonisolated enum WorksheetDimension: String, Codable, Sendable, Equatable, CaseIterable {
    case who, what, when, `where`, why, how
}

public nonisolated enum WorksheetCellStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case unknown
    case answered
}

/// One 5W1H cell. An `answered` cell carries an answer AND a cited (sourceVersion, knowledgeObject); an
/// `unknown` cell carries none of them — an unknown is never fabricated.
public nonisolated struct WorksheetCell: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID
    public let dimension: WorksheetDimension
    public let status: WorksheetCellStatus
    public let answerText: String?
    public let sourceVersionID: UUID?
    public let knowledgeObjectID: UUID?
    public let revision: Int
    public let actor: String
    public let updatedAt: Date

    public nonisolated init(id: UUID, caseID: UUID, dimension: WorksheetDimension, status: WorksheetCellStatus,
                            answerText: String?, sourceVersionID: UUID?, knowledgeObjectID: UUID?,
                            revision: Int, actor: String, updatedAt: Date) {
        self.id = id; self.caseID = caseID; self.dimension = dimension; self.status = status
        self.answerText = answerText; self.sourceVersionID = sourceVersionID; self.knowledgeObjectID = knowledgeObjectID
        self.revision = revision; self.actor = actor; self.updatedAt = updatedAt
    }
}

// MARK: - Errors

public nonisolated enum InvestigationHypothesisError: Error, Sendable, Equatable {
    case caseNotFound(UUID)
    case caseClosed(UUID)
    case hypothesisNotFound(UUID)
    case notALead(UUID)                    // only a lead can be promoted
    case notAHypothesis(UUID)              // only a hypothesis can be confirmed/rejected
    case notProposed(UUID)                 // only a proposed hypothesis can be confirmed/rejected
    case unsupportedCannotConfirm(UUID)    // an unsupported hypothesis stays a proposal (INV-07)
    case evidenceOutOfScope(sourceVersionID: UUID)   // a citation outside the case's authorized scope
    case evidenceObjectMismatch(knowledgeObjectID: UUID, sourceVersionID: UUID)  // KO not in that version
    case requestNotFound(UUID)
    case cellAnswerRequiresEvidence(WorksheetDimension)   // answering a 5W1H cell needs a citation
    case blankStatement
    case blankActor
    case revisionConflict(expected: Int, actual: Int)
}
