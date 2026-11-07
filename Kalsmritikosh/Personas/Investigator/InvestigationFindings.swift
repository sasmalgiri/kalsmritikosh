//
//  InvestigationFindings.swift
//  Kalsmritikosh
//
//  INV-19 (Findings & export) — the durable human approval decision for a case's FINDINGS work product
//  (schema v102). The findings work product itself is the SHARED WorkProductRun (no second reporting
//  authority); this model records only the explicit human decision that a specific, immutable findings run
//  is APPROVED as the case's findings. Truth boundaries this model preserves:
//    • finding ≠ confirmed fact              (approval authorizes the report, it does not verify the world)
//    • export ≠ permission to widen scope    (the scope fingerprint pins the reviewed case scope, nothing wider)
//    • case complete ≠ professional correctness
//  Approval is NEVER inferred: building findings, a completed workflow / method, high confidence, or the
//  absence of a contradiction do not approve anything.
//

import Foundation

public nonisolated enum FindingsApprovalKind: String, Codable, Sendable, Equatable, CaseIterable {
    case approved
    case withdrawn
}

/// One recorded findings approval/withdrawal decision. `workProductRunID` references the immutable findings
/// run being approved; `receiptSeal` pins the sealed receipt at approval (report==receipt integrity);
/// `scopeFingerprint` pins the exact case scope the findings were built under (no export-time widening).
public nonisolated struct InvestigationFindingsApproval: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID
    public let sequence: Int
    public let decision: FindingsApprovalKind
    public let workProductRunID: UUID
    public let receiptSeal: String
    public let scopeFingerprint: CaseScopeFingerprint
    public let rationale: String
    public let actor: String
    public let createdAt: Date

    public nonisolated init(id: UUID, caseID: UUID, sequence: Int, decision: FindingsApprovalKind,
                            workProductRunID: UUID, receiptSeal: String, scopeFingerprint: CaseScopeFingerprint,
                            rationale: String, actor: String, createdAt: Date) {
        self.id = id; self.caseID = caseID; self.sequence = sequence; self.decision = decision
        self.workProductRunID = workProductRunID; self.receiptSeal = receiptSeal
        self.scopeFingerprint = scopeFingerprint; self.rationale = rationale; self.actor = actor
        self.createdAt = createdAt
    }
}

/// The result of building a case-scoped findings work product: the assembled product + its immutable
/// persisted run + the sealed receipt, all pinned to the case scope. Building does NOT approve — approval is
/// a separate recorded human decision (see `InvestigationFindingsService.approveFindings`).
public nonisolated struct InvestigationFindings: Sendable {
    public let caseID: UUID
    public let assembled: AssembledWorkProduct
    public let run: WorkProductRun
    public let receipt: SealedReceipt
    public let scopeFingerprint: CaseScopeFingerprint
    /// The case-authorized source versions actually in scope for these findings (deterministic order).
    public let authorizedSourceVersionIDs: [UUID]

    public nonisolated init(caseID: UUID, assembled: AssembledWorkProduct, run: WorkProductRun,
                            receipt: SealedReceipt, scopeFingerprint: CaseScopeFingerprint,
                            authorizedSourceVersionIDs: [UUID]) {
        self.caseID = caseID; self.assembled = assembled; self.run = run; self.receipt = receipt
        self.scopeFingerprint = scopeFingerprint; self.authorizedSourceVersionIDs = authorizedSourceVersionIDs
    }

    /// The export manifest for these findings — derived from the composed product (case-scoped), so its
    /// `sourceVersionIDs` / `sourceHashes` reflect exactly the authorized evidence that entered the report.
    public nonisolated var manifest: ExportManifest { assembled.manifest }
}

public nonisolated enum InvestigationFindingsError: Error, Sendable, Equatable {
    case caseNotFound(UUID)
    case workspaceNotFound(UUID)
    case blankRationale
    case blankActor
    case blankReceiptSeal
    case revisionConflict(expected: Int, actual: Int)
    case findingsCaseMismatch(findingsCase: UUID, approvingCase: UUID)   // case A's report never approves case B
    case staleFindings                     // the case scope changed after these findings were built
    case receiptIntegrityFailed            // the receipt no longer verifies against the persisted run
    case blankPolicyJustification          // "not applicable" must say why
}

/// K5 — the same plain sentence wherever the error is shown (`localizedDescription`).
extension InvestigationFindingsError: LocalizedError {
    public nonisolated var errorDescription: String? { description }
}

extension InvestigationFindingsError: CustomStringConvertible {
    public nonisolated var description: String {
        switch self {
        case .caseNotFound: return "The case was not found."
        case .workspaceNotFound: return "The case's workspace was not found."
        case .blankRationale: return "Give a rationale."
        case .blankActor: return "The reviewer's name is missing."
        case .blankReceiptSeal: return "The findings have no sealed receipt."
        case .revisionConflict: return "Someone else changed this record; reload and try again."
        case .findingsCaseMismatch: return "These findings were built for a different case."
        case .staleFindings: return "The case's sources changed after these findings were built. Rebuild the findings, then approve."
        case .receiptIntegrityFailed: return "The findings' receipt no longer matches the saved report. Rebuild the findings."
        case .blankPolicyJustification: return "Say why no standard of proof applies."
        }
    }
}

/// The decision policy every findings approval declares (implementation brief §6): a named standard of
/// proof, or an explicitly justified statement that no standard applies (e.g. a fact-finding review that
/// makes no determination). There is no approval without one.
public nonisolated enum FindingsDecisionPolicy: Sendable, Equatable {
    case standard(EvidentiaryStandard)
    case notApplicable(justification: String)

    /// The line stamped at the head of the recorded rationale.
    public var rationaleLine: String {
        switch self {
        case .standard(let s): return s.rationaleLine
        case .notApplicable(let why):
            return "No standard of proof applied: \(why.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}
