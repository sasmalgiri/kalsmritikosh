//
//  InvestigationSubjectDossierService.swift
//  Kalsmritikosh
//
//  INV-02 — the real Investigator "Subject dossier" entry point. Orchestration only: it does NOT own the
//  canonical entity engine or invent a second one. It composes the SHARED EntitiesRepository + the ONE
//  CaseRetrievalScopeResolver + CaseScopedEntityResolver + the durable InvestigationSubjectRepository to:
//    • nominate a canonical entity as a subject ONLY when it has evidence inside the case's authorized scope
//      (available-in-workspace ≠ authorized-for-this-case),
//    • record the human "confirm subject identity" decision (proposed ≠ confirmed),
//    • assemble a Subject Dossier that CITES EXACT EVIDENCE — each item anchored to its source version +
//      knowledge object within the case scope, stamped with the ONE case-scope fingerprint.
//
//  The dossier carries no verdict: it states what the authorized evidence says, never a conclusion of guilt.
//

import Foundation

public actor InvestigationSubjectDossierService {
    private let cases: InvestigationCaseRepository
    private let resolver: CaseRetrievalScopeResolver
    private let subjects: InvestigationSubjectRepository
    private let entities: EntitiesRepository
    private let scopedEntities: CaseScopedEntityResolver

    public init(cases: InvestigationCaseRepository, resolver: CaseRetrievalScopeResolver,
                subjects: InvestigationSubjectRepository, entities: EntitiesRepository,
                scopedEntities: CaseScopedEntityResolver) {
        self.cases = cases; self.resolver = resolver; self.subjects = subjects
        self.entities = entities; self.scopedEntities = scopedEntities
    }

    /// Nominate a canonical entity as a subject of the active case. Fails closed if the case is missing, the
    /// entity does not exist, or the entity has NO mention inside the case's authorized sources (the persona
    /// never widens to the workspace to justify a subject).
    public func nominateSubject(caseID: UUID, canonicalEntityID: UUID, label: String,
                                actor: String, at date: Date) async throws -> InvestigationSubject {
        guard let record = try await cases.fetch(caseID: caseID) else { throw InvestigationSubjectError.caseNotFound(caseID) }
        guard try await entities.find(byID: canonicalEntityID) != nil else {
            throw InvestigationSubjectError.entityNotFound(canonicalEntityID)
        }
        let scope = try await resolver.scope(for: record)
        guard try await scopedEntities.isInScope(entityID: canonicalEntityID, scope: scope) else {
            throw InvestigationSubjectError.entityOutOfScope(canonicalEntityID)
        }
        return try await subjects.createSubject(caseID: caseID, canonicalEntityID: canonicalEntityID,
                                                label: label, actor: actor, at: date)
    }

    /// The human decision that confirms a proposed subject's identity.
    public func confirmSubjectIdentity(subjectID: UUID, expectedRevision: Int, actor: String, at date: Date) async throws -> InvestigationSubject {
        try await subjects.confirmIdentity(subjectID: subjectID, expectedRevision: expectedRevision, actor: actor, at: date)
    }

    /// Reject a proposed subject identity (recorded, not deleted).
    public func rejectSubjectIdentity(subjectID: UUID, expectedRevision: Int, actor: String, at date: Date) async throws -> InvestigationSubject {
        try await subjects.rejectIdentity(subjectID: subjectID, expectedRevision: expectedRevision, actor: actor, at: date)
    }

    /// The subjects of a case (durable, reopen-safe).
    public func subjects(caseID: UUID) async throws -> [InvestigationSubject] {
        try await subjects.subjects(caseID: caseID)
    }

    /// Assemble the Subject Dossier: the subject, its canonical display label, and the in-scope cited
    /// evidence items, stamped with the case-scope fingerprint the dossier was produced under. Every item
    /// cites an exact authorized source version — an unauthorized source can never appear.
    public func assembleDossier(caseID: UUID, subjectID: UUID) async throws -> InvestigationSubjectDossier {
        guard let record = try await cases.fetch(caseID: caseID) else { throw InvestigationSubjectError.caseNotFound(caseID) }
        guard let subject = try await subjects.fetch(subjectID: subjectID), subject.caseID == caseID else {
            throw InvestigationSubjectError.subjectNotFound(subjectID)
        }
        let scope = try await resolver.scope(for: record)
        let fingerprint = CaseScopeFingerprinter.fingerprint(
            caseID: caseID, caseRevision: record.caseHeader.revision, scope: scope)
        let items = try await scopedEntities.inScopeMentions(entityID: subject.canonicalEntityID, scope: scope)
        let label = (try await entities.find(byID: subject.canonicalEntityID))?.value ?? subject.label
        return InvestigationSubjectDossier(subject: subject, entityLabel: label, items: items, scopeFingerprint: fingerprint)
    }
}
