//
//  InvestigationFindingsService.swift
//  Kalsmritikosh
//
//  INV-19 — the real Investigator "Findings & export" entry point. Orchestration only: it composes the case's
//  findings as a case-scoped work product over the SHARED WorkProductAssemblyService (there is NO second
//  reporting authority), persists it through the SHARED WorkProductRunRepository (immutable run), seals it
//  through the SHARED WorkProductReceiptBuilder (report==receipt), and records the explicit human approval
//  through the durable InvestigationFindingsApprovalRepository.
//
//  Scope discipline (the hard boundary): the usable evidence set is `case-authorized ∩ SensitiveScope`.
//    • case-authorized  — resolved by the ONE CaseRetrievalScopeResolver into an exact source-version set,
//                          passed to compose() as `caseAuthorizedVersionIDs` (version-exact, fail-closed).
//    • ∩ SensitiveScope  — enforced by the assembly service's existing scope filter.
//  There is NO workspace fallback and NO widening during report, receipt, or export: a source outside the
//  case scope is structurally absent from the findings, the citations, the manifest, and the sealed receipt.
//
//  Truth boundary: a finding is not a confirmed fact; approving findings authorizes the report, it neither
//  verifies the world nor closes the case (closing is the separate human decision in INV-20).
//

import Foundation

public actor InvestigationFindingsService {
    private let cases: InvestigationCaseRepository
    private let resolver: CaseRetrievalScopeResolver
    private let workspaces: WorkspaceRepository
    private let assembly: WorkProductAssemblyService
    private let runs: WorkProductRunRepository
    private let approvals: InvestigationFindingsApprovalRepository
    private let receiptBuilder = WorkProductReceiptBuilder()

    public init(cases: InvestigationCaseRepository, resolver: CaseRetrievalScopeResolver,
                workspaces: WorkspaceRepository, assembly: WorkProductAssemblyService,
                runs: WorkProductRunRepository, approvals: InvestigationFindingsApprovalRepository) {
        self.cases = cases; self.resolver = resolver; self.workspaces = workspaces
        self.assembly = assembly; self.runs = runs; self.approvals = approvals
    }

    /// Build the case's findings work product over the shared assembly path, restricted to
    /// `case-authorized ∩ SensitiveScope`, persist it as an immutable run, and seal its receipt. This does NOT
    /// approve or close anything — approval is a separate recorded human decision (`approveFindings`).
    public func buildFindings(caseID: UUID, access: SensitiveAccessContext,
                              actor: String, at date: Date) async throws -> InvestigationFindings {
        guard let record = try await cases.fetch(caseID: caseID) else { throw InvestigationFindingsError.caseNotFound(caseID) }
        let workspaceID = record.caseHeader.workspaceID
        guard let workspace = try await workspaces.find(workspaceID) else {
            throw InvestigationFindingsError.workspaceNotFound(workspaceID)
        }
        let scope = try await resolver.scope(for: record)
        let authorized = scope.authorizedSourceVersionIDs
        let fingerprint = CaseScopeFingerprinter.fingerprint(caseID: caseID, caseRevision: record.caseHeader.revision, scope: scope)

        let assembled = try await assembly.compose(
            workspace: workspace, template: .investigationFindings,
            subjectLabel: record.caseHeader.title, corpusSnapshotID: nil,
            access: access, caseAuthorizedVersionIDs: authorized)

        let run = try await runs.save(assembled, workspaceID: workspaceID, subjectLabel: record.caseHeader.title)
        let receipt = try receiptBuilder.build(from: assembled)

        return InvestigationFindings(
            caseID: caseID, assembled: assembled, run: run, receipt: receipt, scopeFingerprint: fingerprint,
            authorizedSourceVersionIDs: authorized.sorted(by: { $0.uuidString < $1.uuidString }))
    }

    /// Record the explicit human approval of a specific findings run as the case's findings. Pins the sealed
    /// receipt seal (report==receipt integrity) and the case scope fingerprint (no export-time widening).
    @discardableResult
    public func approveFindings(caseID: UUID, findings: InvestigationFindings, rationale: String,
                                actor: String, at date: Date) async throws -> InvestigationFindingsApproval {
        try await approvals.approve(caseID: caseID, workProductRunID: findings.run.id,
                                    receiptSeal: findings.receipt.seal, scopeFingerprint: findings.scopeFingerprint,
                                    rationale: rationale, actor: actor, at: date)
    }

    /// Approve findings under an EXPLICIT standard of proof (INV-19 gap fix). The chosen standard is stamped
    /// into the recorded rationale so the approval states, on its face, the evidentiary threshold applied — an
    /// approval can never be recorded without one. Scope, receipt and fingerprint behaviour are unchanged; this
    /// only composes the rationale and delegates to the base recorder.
    @discardableResult
    public func approveFindings(caseID: UUID, findings: InvestigationFindings, proofStandard: EvidentiaryStandard,
                                rationale: String, actor: String, at date: Date) async throws -> InvestigationFindingsApproval {
        let why = rationale.trimmingCharacters(in: .whitespacesAndNewlines)
        let composed = why.isEmpty ? proofStandard.rationaleLine : "\(proofStandard.rationaleLine) \(why)"
        return try await approveFindings(caseID: caseID, findings: findings, rationale: composed, actor: actor, at: date)
    }

    /// Withdraw approval of a findings run (a new recorded decision; the prior approval is preserved).
    @discardableResult
    public func withdrawApproval(caseID: UUID, findings: InvestigationFindings, rationale: String,
                                 actor: String, at date: Date) async throws -> InvestigationFindingsApproval {
        try await approvals.withdraw(caseID: caseID, workProductRunID: findings.run.id,
                                     receiptSeal: findings.receipt.seal, scopeFingerprint: findings.scopeFingerprint,
                                     rationale: rationale, actor: actor, at: date)
    }

    /// Reopen the exact findings run that was persisted (the immutable work product) — deterministic reopen.
    public func reopenFindings(runID: UUID) async throws -> AssembledWorkProduct { try await runs.reopen(runID) }

    public func approvalHistory(caseID: UUID) async throws -> [InvestigationFindingsApproval] { try await approvals.approvals(caseID: caseID) }
    public func latestApproval(caseID: UUID) async throws -> InvestigationFindingsApproval? { try await approvals.latest(caseID: caseID) }
}
