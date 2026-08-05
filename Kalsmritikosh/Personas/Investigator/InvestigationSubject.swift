//
//  InvestigationSubject.swift
//  Kalsmritikosh
//
//  INV-02 (Subject dossier) + INV-03 (Identity resolution) — persona domain over the ONE canonical entity
//  engine. The Investigator is a LENS: a subject and an identity-resolution decision REFERENCE canonical
//  `entities` by id and compose the SHARED EntitiesRepository merge/unmerge (which is already soft +
//  reversible). They fork no second entity, alias, or merge authority.
//
//  Truth boundaries preserved here:
//    • available in workspace        ≠ authorized for this investigation (scope-bounded to the case)
//    • proposed subject identity      ≠ confirmed subject identity        (INV-02 human decision)
//    • proposed merge                 ≠ confirmed merge                   (INV-03 human decision, no auto-merge)
//    • a merge is always REVERSIBLE and the decision is always RECORDED   (INV-03 validation invariant)
//
//  A Subject Dossier is a factual assembly that CITES EXACT EVIDENCE (each item carries the source version
//  + knowledge object it was observed in, within the case's authorized scope). It states no conclusion of
//  guilt — the persona records what the evidence says, never a verdict.
//

import Foundation

// MARK: - INV-02 Subject dossier

/// A subject's identity is PROPOSED when nominated and only CONFIRMED by an explicit human decision; it may
/// also be REJECTED. `confirmed` is the only status that carries a confirmer.
public nonisolated enum SubjectIdentityStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case proposed
    case confirmed
    case rejected
}

/// A candidate identifier for a subject (INV-03 required input). A soft descriptor — name, email, phone,
/// account — used when proposing/merging identities; never a canonical row itself.
public nonisolated struct Identifier: Sendable, Equatable, Codable, Hashable {
    public let kind: String
    public let value: String

    public nonisolated init(kind: String, value: String) {
        self.kind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        self.value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// The normalized comparison form used to match identifiers across mentions.
    public nonisolated var normalized: String { value.lowercased() }
}

/// The persona-specific state for a subject of an investigation, anchored to one canonical entity id.
/// `canonicalEntityID` is a soft reference into `entities` (which may itself soft-merge); the subject never
/// copies or mutates the canonical row.
public nonisolated struct InvestigationSubject: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID
    public let canonicalEntityID: UUID
    public let label: String
    public let identityStatus: SubjectIdentityStatus
    public let confirmedBy: String?
    public let confirmedAt: Date?
    public let revision: Int
    public let actor: String
    public let createdAt: Date
    public let updatedAt: Date

    public nonisolated init(id: UUID, caseID: UUID, canonicalEntityID: UUID, label: String,
                            identityStatus: SubjectIdentityStatus, confirmedBy: String?, confirmedAt: Date?,
                            revision: Int, actor: String, createdAt: Date, updatedAt: Date) {
        self.id = id; self.caseID = caseID; self.canonicalEntityID = canonicalEntityID; self.label = label
        self.identityStatus = identityStatus; self.confirmedBy = confirmedBy; self.confirmedAt = confirmedAt
        self.revision = revision; self.actor = actor; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

/// One cited item in a subject dossier — a fact observed IN a specific authorized source version. The
/// evidence anchor is exact (source version + knowledge object + surface form), never a bare assertion.
public nonisolated struct InvestigationDossierItem: Sendable, Equatable {
    public let sourceVersionID: UUID
    public let knowledgeObjectID: UUID
    public let surface: String

    public nonisolated init(sourceVersionID: UUID, knowledgeObjectID: UUID, surface: String) {
        self.sourceVersionID = sourceVersionID; self.knowledgeObjectID = knowledgeObjectID; self.surface = surface
    }
}

/// The assembled dossier: the subject, the canonical entity display label, and the cited evidence items —
/// all within the case's authorized scope, stamped with the scope fingerprint it was produced under. It
/// carries no verdict field by design (prohibited outcome: assert guilt without evidence).
public nonisolated struct InvestigationSubjectDossier: Sendable, Equatable {
    public let subject: InvestigationSubject
    public let entityLabel: String
    public let items: [InvestigationDossierItem]
    public let scopeFingerprint: CaseScopeFingerprint

    public nonisolated init(subject: InvestigationSubject, entityLabel: String,
                            items: [InvestigationDossierItem], scopeFingerprint: CaseScopeFingerprint) {
        self.subject = subject; self.entityLabel = entityLabel; self.items = items; self.scopeFingerprint = scopeFingerprint
    }
    /// The distinct authorized source versions the dossier cites.
    public nonisolated var citedSourceVersionIDs: [UUID] {
        Array(Set(items.map(\.sourceVersionID))).sorted { $0.uuidString < $1.uuidString }
    }
}

public nonisolated enum InvestigationSubjectError: Error, Sendable, Equatable {
    case caseNotFound(UUID)
    case caseClosed(UUID)
    case entityNotFound(UUID)
    case entityOutOfScope(UUID)          // the entity has no mention within the case's authorized sources
    case subjectNotFound(UUID)
    case subjectAlreadyExists(caseID: UUID, entityID: UUID)
    case notProposed(UUID)               // only a PROPOSED subject can be confirmed/rejected
    case blankLabel
    case blankActor
    case revisionConflict(expected: Int, actual: Int)
}

// MARK: - INV-03 Identity resolution

/// The recorded lifecycle of a proposed identity merge. Append-only: every step is a new row, so the
/// decision history is fully auditable and a reversal never erases the confirmation it undoes.
public nonisolated enum IdentityDecisionKind: String, Codable, Sendable, Equatable, CaseIterable {
    case mergeProposed
    case mergeConfirmed
    case mergeRejected
    case mergeReversed
}

/// One recorded identity-resolution decision: a proposed / confirmed / rejected / reversed merge of the
/// `loserEntityID` into the `winnerEntityID`, both soft references into canonical `entities`. `priorDecisionID`
/// links a confirmation to its proposal and a reversal to its confirmation.
public nonisolated struct IdentityResolutionDecision: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID
    public let sequence: Int
    public let kind: IdentityDecisionKind
    public let winnerEntityID: UUID
    public let loserEntityID: UUID
    public let rationale: String?
    public let actor: String
    public let priorDecisionID: UUID?
    public let occurredAt: Date

    public nonisolated init(id: UUID, caseID: UUID, sequence: Int, kind: IdentityDecisionKind,
                            winnerEntityID: UUID, loserEntityID: UUID, rationale: String?, actor: String,
                            priorDecisionID: UUID?, occurredAt: Date) {
        self.id = id; self.caseID = caseID; self.sequence = sequence; self.kind = kind
        self.winnerEntityID = winnerEntityID; self.loserEntityID = loserEntityID; self.rationale = rationale
        self.actor = actor; self.priorDecisionID = priorDecisionID; self.occurredAt = occurredAt
    }
}

public nonisolated enum IdentityResolutionError: Error, Sendable, Equatable {
    case caseNotFound(UUID)
    case caseClosed(UUID)
    case entityNotFound(UUID)
    case entityOutOfScope(UUID)               // an entity outside the case's authorized sources
    case sameEntity                           // cannot merge an entity into itself
    case differentKind                        // a person and an organization are not the same subject
    case noPendingProposal(winner: UUID, loser: UUID)   // cannot confirm/reject without an open proposal
    case notConfirmed(winner: UUID, loser: UUID)        // cannot reverse a merge that was never confirmed
    case alreadyResolved(winner: UUID, loser: UUID)     // the pair already has a terminal decision
    case blankActor
    case mergeFailed(String)                  // the shared canonical merge/unmerge refused (reason forwarded)
}
