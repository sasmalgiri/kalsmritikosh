//
//  InvestigationClosureService.swift
//  Kalsmritikosh
//
//  INV-20 — the real Investigator "Close case" entry point. Orchestration only: it composes the durable
//  InvestigationClosureRepository with the ONE CaseRetrievalScopeResolver + CaseScopeFingerprinter so a
//  closure decision is stamped with the exact case scope it was made under. Closure is a HUMAN decision:
//    • the ONLY way a case reaches 'closed' is this explicit call (no task/method completion, export, or
//      confidence auto-closes a case),
//    • closure is HONEST — the accepted unresolved items are recorded and retained, never erased,
//    • reopening is a NEW recorded decision that never rewrites the closure it follows.
//

import Foundation

public actor InvestigationClosureService {
    private let cases: InvestigationCaseRepository
    private let resolver: CaseRetrievalScopeResolver
    private let closures: InvestigationClosureRepository

    public init(cases: InvestigationCaseRepository, resolver: CaseRetrievalScopeResolver, closures: InvestigationClosureRepository) {
        self.cases = cases; self.resolver = resolver; self.closures = closures
    }

    /// Close a case by a recorded human decision. `unresolvedItems` are the limitations the human accepts at
    /// closure (kept visible). Optionally references the sealed findings work product + its receipt seal.
    @discardableResult
    public func closeCase(caseID: UUID, expectedRevision: Int, rationale: String, unresolvedItems: [String],
                          workProductRunID: UUID?, receiptSeal: String?, actor: String, at date: Date) async throws -> InvestigationClosureDecision {
        let fingerprint = try await scopeFingerprint(caseID: caseID)
        return try await closures.close(caseID: caseID, expectedRevision: expectedRevision, rationale: rationale,
                                        workProductRunID: workProductRunID, scopeFingerprint: fingerprint,
                                        unresolvedItems: unresolvedItems, receiptSeal: receiptSeal, actor: actor, at: date)
    }

    /// Reopen a closed case by a recorded human decision; the prior closure is preserved.
    @discardableResult
    public func reopenCase(caseID: UUID, expectedRevision: Int, rationale: String, actor: String, at date: Date) async throws -> InvestigationClosureDecision {
        let fingerprint = try await scopeFingerprint(caseID: caseID)
        return try await closures.reopen(caseID: caseID, expectedRevision: expectedRevision, rationale: rationale,
                                         scopeFingerprint: fingerprint, actor: actor, at: date)
    }

    /// The full closure/reopen decision genealogy for a case, in order.
    public func closureHistory(caseID: UUID) async throws -> [InvestigationClosureDecision] { try await closures.closures(caseID: caseID) }
    public func latestClosure(caseID: UUID) async throws -> InvestigationClosureDecision? { try await closures.latest(caseID: caseID) }

    // MARK: - Internals

    private func scopeFingerprint(caseID: UUID) async throws -> CaseScopeFingerprint {
        guard let record = try await cases.fetch(caseID: caseID) else { throw InvestigationClosureError.caseNotFound(caseID) }
        let scope = try await resolver.scope(for: record)
        return CaseScopeFingerprinter.fingerprint(caseID: caseID, caseRevision: record.caseHeader.revision, scope: scope)
    }
}
