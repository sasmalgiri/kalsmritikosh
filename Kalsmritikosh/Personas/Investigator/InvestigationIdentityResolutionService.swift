//
//  InvestigationIdentityResolutionService.swift
//  Kalsmritikosh
//
//  INV-03 — the real Investigator "Identity resolution" entry point. Orchestration only: it forks NO merge
//  authority. It composes the SHARED EntitiesRepository merge/unmerge (already soft + reversible) behind a
//  human gate, records every step in the durable InvestigationIdentityDecisionRepository, and bounds both
//  entities to the case's authorized scope (CaseRetrievalScopeResolver + CaseScopedEntityResolver).
//
//  The two invariants this enforces, not merely documents:
//    • NO AUTO-MERGE. `entities.merge` is called from EXACTLY ONE place — `confirmMerge` — and only after a
//      matching human `mergeProposed` decision exists for the pair. Proposing records intent and mutates
//      nothing; rejecting records a refusal and mutates nothing.
//    • MERGE REVERSIBLE; DECISION RECORDED. A confirmed merge can be reversed via the shared `unmerge`, and
//      every proposal / confirmation / rejection / reversal is an append-only decision row (a reversal never
//      erases the confirmation it undoes).
//

import Foundation

public actor InvestigationIdentityResolutionService {
    private let cases: InvestigationCaseRepository
    private let resolver: CaseRetrievalScopeResolver
    private let scopedEntities: CaseScopedEntityResolver
    private let entities: EntitiesRepository
    private let decisions: InvestigationIdentityDecisionRepository

    public init(cases: InvestigationCaseRepository, resolver: CaseRetrievalScopeResolver,
                scopedEntities: CaseScopedEntityResolver, entities: EntitiesRepository,
                decisions: InvestigationIdentityDecisionRepository) {
        self.cases = cases; self.resolver = resolver; self.scopedEntities = scopedEntities
        self.entities = entities; self.decisions = decisions
    }

    // MARK: - Propose (record only, no mutation)

    /// Propose merging `loserEntityID` into `winnerEntityID`. Records intent ONLY — the canonical entities
    /// are untouched. Both entities must exist, be the same kind, be distinct, and have evidence inside the
    /// case scope. A pair with an open proposal or an active confirmed merge cannot be re-proposed.
    @discardableResult
    public func proposeMerge(caseID: UUID, winnerEntityID: UUID, loserEntityID: UUID, rationale: String?,
                             actor: String, at date: Date) async throws -> IdentityResolutionDecision {
        let scope = try await requireOpenCaseScope(caseID)
        try await validatePair(winnerEntityID: winnerEntityID, loserEntityID: loserEntityID, scope: scope)
        switch try await pairState(caseID: caseID, winner: winnerEntityID, loser: loserEntityID) {
        case .none, .rejected, .reversed:
            return try await decisions.record(caseID: caseID, kind: .mergeProposed, winnerEntityID: winnerEntityID,
                                              loserEntityID: loserEntityID, rationale: rationale, actor: actor,
                                              priorDecisionID: nil, at: date)
        case .proposed, .confirmed:
            throw IdentityResolutionError.alreadyResolved(winner: winnerEntityID, loser: loserEntityID)
        }
    }

    // MARK: - Confirm (the ONLY merge site) / Reject

    /// Confirm a proposed merge: performs the SHARED reversible `entities.merge` and records `mergeConfirmed`
    /// linked to the proposal. Requires an OPEN proposal for the pair — there is no way to reach a merge
    /// without a prior human proposal (no auto-merge). Re-validates scope because this mutates canonical data.
    @discardableResult
    public func confirmMerge(caseID: UUID, winnerEntityID: UUID, loserEntityID: UUID,
                             actor: String, at date: Date) async throws -> IdentityResolutionDecision {
        let scope = try await requireOpenCaseScope(caseID)
        try await validatePair(winnerEntityID: winnerEntityID, loserEntityID: loserEntityID, scope: scope)
        guard let proposal = try await lastDecision(caseID: caseID, winner: winnerEntityID, loser: loserEntityID),
              proposal.kind == .mergeProposed else {
            throw IdentityResolutionError.noPendingProposal(winner: winnerEntityID, loser: loserEntityID)
        }
        do {
            try await entities.merge(loserID: loserEntityID, winnerID: winnerEntityID)
        } catch {
            throw IdentityResolutionError.mergeFailed(String(describing: error))
        }
        return try await decisions.record(caseID: caseID, kind: .mergeConfirmed, winnerEntityID: winnerEntityID,
                                          loserEntityID: loserEntityID, rationale: nil, actor: actor,
                                          priorDecisionID: proposal.id, at: date)
    }

    /// Reject a proposed merge (record only, no mutation). Requires an open proposal for the pair.
    @discardableResult
    public func rejectMerge(caseID: UUID, winnerEntityID: UUID, loserEntityID: UUID, rationale: String?,
                            actor: String, at date: Date) async throws -> IdentityResolutionDecision {
        _ = try await requireOpenCaseScope(caseID)
        guard let proposal = try await lastDecision(caseID: caseID, winner: winnerEntityID, loser: loserEntityID),
              proposal.kind == .mergeProposed else {
            throw IdentityResolutionError.noPendingProposal(winner: winnerEntityID, loser: loserEntityID)
        }
        return try await decisions.record(caseID: caseID, kind: .mergeRejected, winnerEntityID: winnerEntityID,
                                          loserEntityID: loserEntityID, rationale: rationale, actor: actor,
                                          priorDecisionID: proposal.id, at: date)
    }

    // MARK: - Reverse (undo a confirmed merge)

    /// Reverse a confirmed merge: performs the SHARED `entities.unmerge` and records `mergeReversed` linked
    /// to the confirmation. Requires the pair's last decision to be a `mergeConfirmed`.
    @discardableResult
    public func reverseMerge(caseID: UUID, winnerEntityID: UUID, loserEntityID: UUID, rationale: String?,
                             actor: String, at date: Date) async throws -> IdentityResolutionDecision {
        _ = try await requireOpenCaseScope(caseID)
        guard let confirmation = try await lastDecision(caseID: caseID, winner: winnerEntityID, loser: loserEntityID),
              confirmation.kind == .mergeConfirmed else {
            throw IdentityResolutionError.notConfirmed(winner: winnerEntityID, loser: loserEntityID)
        }
        do {
            try await entities.unmerge(loserID: loserEntityID)
        } catch {
            throw IdentityResolutionError.mergeFailed(String(describing: error))
        }
        return try await decisions.record(caseID: caseID, kind: .mergeReversed, winnerEntityID: winnerEntityID,
                                          loserEntityID: loserEntityID, rationale: rationale, actor: actor,
                                          priorDecisionID: confirmation.id, at: date)
    }

    /// The case's full identity-resolution decision log, in order.
    public func decisionLog(caseID: UUID) async throws -> [IdentityResolutionDecision] {
        try await decisions.decisions(caseID: caseID)
    }

    // MARK: - Internals

    private enum PairState { case none, proposed, confirmed, rejected, reversed }

    private func lastDecision(caseID: UUID, winner: UUID, loser: UUID) async throws -> IdentityResolutionDecision? {
        try await decisions.decisions(caseID: caseID, winnerEntityID: winner, loserEntityID: loser).last
    }

    private func pairState(caseID: UUID, winner: UUID, loser: UUID) async throws -> PairState {
        switch try await lastDecision(caseID: caseID, winner: winner, loser: loser)?.kind {
        case .none: return .none
        case .mergeProposed: return .proposed
        case .mergeConfirmed: return .confirmed
        case .mergeRejected: return .rejected
        case .mergeReversed: return .reversed
        }
    }

    /// The case must exist and be non-closed; returns its authorized scope. Fail-closed.
    private func requireOpenCaseScope(_ caseID: UUID) async throws -> RetrievalSourceScope {
        guard let record = try await cases.fetch(caseID: caseID) else { throw IdentityResolutionError.caseNotFound(caseID) }
        guard record.caseHeader.status != .closed else { throw IdentityResolutionError.caseClosed(caseID) }
        return try await resolver.scope(for: record)
    }

    /// Both entities exist, are the same kind, are distinct, and have in-scope evidence.
    private func validatePair(winnerEntityID: UUID, loserEntityID: UUID, scope: RetrievalSourceScope) async throws {
        guard winnerEntityID != loserEntityID else { throw IdentityResolutionError.sameEntity }
        guard let winner = try await entities.find(byID: winnerEntityID) else { throw IdentityResolutionError.entityNotFound(winnerEntityID) }
        guard let loser = try await entities.find(byID: loserEntityID) else { throw IdentityResolutionError.entityNotFound(loserEntityID) }
        guard winner.kind == loser.kind else { throw IdentityResolutionError.differentKind }
        guard try await scopedEntities.isInScope(entityID: winnerEntityID, scope: scope) else {
            throw IdentityResolutionError.entityOutOfScope(winnerEntityID)
        }
        guard try await scopedEntities.isInScope(entityID: loserEntityID, scope: scope) else {
            throw IdentityResolutionError.entityOutOfScope(loserEntityID)
        }
    }
}
