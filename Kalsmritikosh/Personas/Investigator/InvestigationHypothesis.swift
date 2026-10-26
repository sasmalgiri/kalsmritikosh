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

/// The evidence profile for a hypothesis (INV-07; implementation brief §8). A DESCRIPTION, never a
/// verdict: neither a count majority nor the absence of contradiction proves a hypothesis. Copies of one
/// document are one evidential lineage (HIST-035 independence grouping), so `forLineages` /
/// `againstLineages` count distinct sources, not citations.
public nonisolated struct HypothesisEvidenceProfile: Sendable, Equatable {
    public let forCount: Int
    public let againstCount: Int
    public let forLineages: Int
    public let againstLineages: Int
    /// Links that nobody has yet assessed for source reliability and diagnostic relevance.
    public let unassessedCount: Int
    public nonisolated init(forCount: Int, againstCount: Int, forLineages: Int? = nil, againstLineages: Int? = nil,
                            unassessedCount: Int = 0) {
        self.forCount = forCount; self.againstCount = againstCount
        self.forLineages = forLineages ?? forCount; self.againstLineages = againstLineages ?? againstCount
        self.unassessedCount = unassessedCount
    }
    public nonisolated var total: Int { forCount + againstCount }
    /// At least one supporting citation exists. A hypothesis without one stays a proposal. This is NOT
    /// sufficiency — confirmation is a human judgment recorded with its rationale (HypothesisDecision).
    public nonisolated var isSupported: Bool { forCount > 0 }

    /// Plain description shown beside the hypothesis.
    public nonisolated var summary: String {
        func part(_ n: Int, _ lineages: Int, _ word: String) -> String {
            let cites = "\(n) citation\(n == 1 ? "" : "s") \(word)"
            return lineages == n ? cites : "\(cites) from \(lineages) independent source\(lineages == 1 ? "" : "s")"
        }
        var s = "\(part(forCount, forLineages, "for")); \(part(againstCount, againstLineages, "against"))."
        if unassessedCount > 0 { s += " \(unassessedCount) not yet assessed for reliability and relevance." }
        return s + " Counts describe the evidence; they do not decide the hypothesis."
    }
}

/// How far the source of one citation can be trusted (brief §8 "record source reliability").
public nonisolated enum SourceReliability: String, Codable, Sendable, Equatable, CaseIterable {
    case high, medium, low, unknown
}

/// How well one citation distinguishes this hypothesis from its alternatives (brief §8 "diagnostic
/// relevance") — evidence consistent with every hypothesis has no diagnostic value.
public nonisolated enum DiagnosticRelevance: String, Codable, Sendable, Equatable, CaseIterable {
    case high, medium, low, none
}

/// A reviewer's assessment of one evidence link.
public nonisolated struct HypothesisEvidenceAssessment: Sendable, Equatable {
    public let linkID: UUID
    public let reliability: SourceReliability
    public let relevance: DiagnosticRelevance
    public let note: String?
    public let assessedBy: String
    public let assessedAt: Date
    public nonisolated init(linkID: UUID, reliability: SourceReliability, relevance: DiagnosticRelevance, note: String?,
                            assessedBy: String, assessedAt: Date) {
        self.linkID = linkID; self.reliability = reliability; self.relevance = relevance; self.note = note
        self.assessedBy = assessedBy; self.assessedAt = assessedAt
    }
}

/// The human explanation a confirmation must carry (brief §8): why, what the contrary evidence is and
/// why it does not defeat the hypothesis, and which alternatives were considered.
public nonisolated struct HypothesisConfirmationReason: Sendable, Equatable {
    public let rationale: String
    public let contraryEvidence: String
    public let alternatives: String
    public nonisolated init(rationale: String, contraryEvidence: String, alternatives: String) {
        self.rationale = rationale; self.contraryEvidence = contraryEvidence; self.alternatives = alternatives
    }
}

/// One recorded, append-only hypothesis decision with the evidence profile at the time it was made.
public nonisolated struct HypothesisDecision: Sendable, Equatable {
    public let id: UUID
    public let hypothesisID: UUID
    public let decision: HypothesisStatus
    public let rationale: String
    public let contraryEvidence: String?
    public let alternatives: String?
    public let profile: HypothesisEvidenceProfile
    public let actor: String
    public let decidedAt: Date
    public nonisolated init(id: UUID, hypothesisID: UUID, decision: HypothesisStatus, rationale: String, contraryEvidence: String?,
                            alternatives: String?, profile: HypothesisEvidenceProfile, actor: String, decidedAt: Date) {
        self.id = id; self.hypothesisID = hypothesisID; self.decision = decision; self.rationale = rationale
        self.contraryEvidence = contraryEvidence; self.alternatives = alternatives; self.profile = profile
        self.actor = actor; self.decidedAt = decidedAt
    }
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
    case confirmationRationaleRequired     // a confirmation must say why (brief §8)
    case contraryEvidenceNotAddressed      // … and address the contrary evidence
    case alternativesNotAddressed          // … and the alternatives considered
    case evidenceLinkNotFound(UUID)
    case evidenceOutOfScope(sourceVersionID: UUID)   // a citation outside the case's authorized scope
    case evidenceObjectMismatch(knowledgeObjectID: UUID, sourceVersionID: UUID)  // KO not in that version
    case requestNotFound(UUID)
    case cellAnswerRequiresEvidence(WorksheetDimension)   // answering a 5W1H cell needs a citation
    case blankStatement
    case blankActor
    case revisionConflict(expected: Int, actual: Int)
}
