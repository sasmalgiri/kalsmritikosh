//
//  WorkProductHandoffService.swift
//  Kalsmritikosh
//
//  #146 (Handoff / Review) — the persona-neutral read model that lets a reviewer see, in one place, the
//  handoff state of a matter: whether its findings work product has been approved, whether the matter has
//  been closed, and its evidence/custody manifest. Orchestration ONLY: it forks NO authority and owns NO
//  data. It composes the SHARED case authorities already wired at boot —
//    • InvestigationFindingsService  (INV-19) — findings work product + the recorded human approval log,
//    • InvestigationClosureService   (INV-20) — the recorded human closure/reopen decision log,
//    • InvestigationCustodyService   (INV-18) — the per-authorized-version content hash + custody chain,
//    • InvestigationCaseRepository   (INV-01) — the case header (status + revision).
//
//  It is a LENS shared by every persona (the Investigation* services are the persona-neutral matter engine),
//  and it enforces no new truth boundary — it only surfaces the ones those services already guarantee:
//    • approval is never inferred (a snapshot shows "not approved" until a human recorded an approval),
//    • closure is never inferred (a snapshot shows the recorded decision, with unresolved items retained),
//    • only case-authorized source versions appear in the custody manifest.
//

import Foundation

/// A read-only aggregate of a matter's handoff/review state, assembled from the shared case authorities.
/// Nothing here is computed or judged; each field is the current recorded state of the matter.
public nonisolated struct CaseHandoffSnapshot: Sendable {
    public let caseID: UUID
    public let workspaceID: UUID
    public let title: String
    public let status: InvestigationCaseStatus
    /// The case revision (the value a close/reopen must pass as `expectedRevision`).
    public let revision: Int
    /// The most recent findings approval/withdrawal decision, or nil if a human never recorded one.
    public let latestApproval: InvestigationFindingsApproval?
    /// The full findings approval/withdrawal genealogy, in order.
    public let approvalHistory: [InvestigationFindingsApproval]
    /// The most recent closure/reopen decision, or nil if the matter was never closed.
    public let latestClosure: InvestigationClosureDecision?
    /// The full closure/reopen genealogy, in order.
    public let closureHistory: [InvestigationClosureDecision]
    /// The case evidence/custody manifest — one entry per authorized source version.
    public let custody: [CustodyManifestEntry]

    public nonisolated init(caseID: UUID, workspaceID: UUID, title: String, status: InvestigationCaseStatus,
                            revision: Int, latestApproval: InvestigationFindingsApproval?,
                            approvalHistory: [InvestigationFindingsApproval], latestClosure: InvestigationClosureDecision?,
                            closureHistory: [InvestigationClosureDecision], custody: [CustodyManifestEntry]) {
        self.caseID = caseID; self.workspaceID = workspaceID; self.title = title; self.status = status
        self.revision = revision; self.latestApproval = latestApproval; self.approvalHistory = approvalHistory
        self.latestClosure = latestClosure; self.closureHistory = closureHistory; self.custody = custody
    }

    /// Whether the current findings decision is an approval (not withdrawn, not absent).
    public var isApproved: Bool { latestApproval?.decision == .approved }
    /// Whether the matter is currently closed (its most recent decision was a closure).
    public var isClosed: Bool { status == .closed }
}

public nonisolated enum WorkProductHandoffError: Error, Sendable, Equatable {
    case caseNotFound(UUID)
}

/// Reads a matter's handoff/review state from the shared case authorities. Read-only orchestration.
public actor WorkProductHandoffService {
    private let cases: InvestigationCaseRepository
    private let findings: InvestigationFindingsService
    private let closure: InvestigationClosureService
    private let custody: InvestigationCustodyService

    public init(cases: InvestigationCaseRepository, findings: InvestigationFindingsService,
                closure: InvestigationClosureService, custody: InvestigationCustodyService) {
        self.cases = cases; self.findings = findings; self.closure = closure; self.custody = custody
    }

    /// Assemble the current handoff snapshot for a matter from the shared authorities. Reads only.
    public func snapshot(caseID: UUID) async throws -> CaseHandoffSnapshot {
        guard let record = try await cases.fetch(caseID: caseID) else { throw WorkProductHandoffError.caseNotFound(caseID) }
        let header = record.caseHeader
        let approvals = try await findings.approvalHistory(caseID: caseID)
        let closures = try await closure.closureHistory(caseID: caseID)
        let manifest = try await custody.manifest(caseID: caseID)
        return CaseHandoffSnapshot(
            caseID: caseID, workspaceID: header.workspaceID, title: header.title, status: header.status,
            revision: header.revision, latestApproval: approvals.last, approvalHistory: approvals,
            latestClosure: closures.last, closureHistory: closures, custody: manifest)
    }
}
