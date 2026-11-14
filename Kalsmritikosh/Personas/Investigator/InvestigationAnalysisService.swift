//
//  InvestigationAnalysisService.swift
//  Kalsmritikosh
//
//  INV-04..07 — the real Investigator entry point for the analytical spine (Brainstorm board, 5W1H
//  worksheet, Evidence collection plan, Hypothesis matrix). Orchestration only: it composes the durable
//  InvestigationAnalysisRepository with the ONE CaseRetrievalScopeResolver + the shared EvidenceStore, and
//  enforces the persona invariants that the repository cannot see:
//    • every cited (source version + knowledge object) must be inside the case's authorized scope AND the
//      object must actually belong to that version — no unauthorized or mismatched evidence (INV-05/07),
//    • a hypothesis is CONFIRMED only by a human who records why, how the contrary evidence was weighed
//      and which alternatives were considered; one with no supporting citation stays a proposal (INV-07,
//      brief §8) — counts describe the evidence, the engine never picks a winner,
//    • the human decisions (promote a lead, confirm/reject a hypothesis, confirm an evidence request) are
//      recorded, never taken autonomously.
//

import Foundation

public actor InvestigationAnalysisService {
    private let cases: InvestigationCaseRepository
    private let resolver: CaseRetrievalScopeResolver
    private let evidence: EvidenceStore
    private let analysis: InvestigationAnalysisRepository

    public init(cases: InvestigationCaseRepository, resolver: CaseRetrievalScopeResolver,
                evidence: EvidenceStore, analysis: InvestigationAnalysisRepository) {
        self.cases = cases; self.resolver = resolver; self.evidence = evidence; self.analysis = analysis
    }

    // MARK: - INV-04 Brainstorm board

    public func captureLead(caseID: UUID, statement: String, actor: String, at date: Date) async throws -> InvestigationHypothesis {
        try await analysis.captureLead(caseID: caseID, statement: statement, actor: actor, at: date)
    }
    public func captureHypothesis(caseID: UUID, statement: String, actor: String, at date: Date) async throws -> InvestigationHypothesis {
        try await analysis.captureHypothesis(caseID: caseID, statement: statement, actor: actor, at: date)
    }
    /// The human decision that promotes a lead into a hypothesis.
    public func promoteLead(hypothesisID: UUID, expectedRevision: Int, actor: String, at date: Date) async throws -> InvestigationHypothesis {
        try await analysis.promoteToHypothesis(hypothesisID: hypothesisID, expectedRevision: expectedRevision, actor: actor, at: date)
    }
    public func dismissLead(hypothesisID: UUID, expectedRevision: Int, actor: String, at date: Date) async throws -> InvestigationHypothesis {
        try await analysis.setHypothesisStatus(hypothesisID: hypothesisID, expectedRevision: expectedRevision, to: .dismissed, actor: actor, at: date)
    }
    public func hypotheses(caseID: UUID) async throws -> [InvestigationHypothesis] { try await analysis.hypotheses(caseID: caseID) }

    // MARK: - INV-07 Hypothesis matrix

    /// Attach a for/against evidence citation to a hypothesis. The citation must be inside the case scope
    /// and the object must belong to the cited version.
    @discardableResult
    public func addEvidence(caseID: UUID, hypothesisID: UUID, stance: EvidenceStance, sourceVersionID: UUID,
                            knowledgeObjectID: UUID, note: String?, actor: String, at date: Date) async throws -> HypothesisEvidenceLink {
        let scope = try await requireOpenCaseScope(caseID)
        try await validateCitation(sourceVersionID: sourceVersionID, knowledgeObjectID: knowledgeObjectID, scope: scope)
        guard let h = try await analysis.fetchHypothesis(hypothesisID), h.caseID == caseID else {
            throw InvestigationHypothesisError.hypothesisNotFound(hypothesisID)
        }
        return try await analysis.addEvidence(hypothesisID: h.id, stance: stance, sourceVersionID: sourceVersionID,
                                              knowledgeObjectID: knowledgeObjectID, note: note, addedBy: actor, at: date)
    }

    /// The counted evidence profile for a hypothesis (deterministic, never a verdict).
    public func profile(hypothesisID: UUID) async throws -> HypothesisEvidenceProfile { try await analysis.profile(hypothesisID: hypothesisID) }
    public func evidence(hypothesisID: UUID) async throws -> [HypothesisEvidenceLink] { try await analysis.evidence(hypothesisID: hypothesisID) }

    public func assessEvidence(linkID: UUID, reliability: SourceReliability, relevance: DiagnosticRelevance, note: String?,
                               actor: String, at date: Date) async throws {
        try await analysis.assess(linkID: linkID, reliability: reliability, relevance: relevance, note: note, assessedBy: actor, at: date)
    }
    public func assessments(hypothesisID: UUID) async throws -> [HypothesisEvidenceAssessment] { try await analysis.assessments(hypothesisID: hypothesisID) }
    public func decisions(hypothesisID: UUID) async throws -> [HypothesisDecision] { try await analysis.decisions(hypothesisID: hypothesisID) }

    /// Confirm a hypothesis — the human decision (brief §8). Counts never decide it: a confirmation needs at
    /// least one supporting citation AND the reviewer's written rationale, how the contrary evidence was
    /// weighed, and which alternatives were considered. The reasons and the evidence profile at that moment
    /// are recorded with the decision; the engine never confirms autonomously.
    public func confirmHypothesis(hypothesisID: UUID, expectedRevision: Int, reason: HypothesisConfirmationReason,
                                  actor: String, at date: Date) async throws -> InvestigationHypothesis {
        func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let cleaned = HypothesisConfirmationReason(rationale: clean(reason.rationale), contraryEvidence: clean(reason.contraryEvidence),
                                                   alternatives: clean(reason.alternatives))
        guard !cleaned.rationale.isEmpty else { throw InvestigationHypothesisError.confirmationRationaleRequired }
        guard !cleaned.contraryEvidence.isEmpty else { throw InvestigationHypothesisError.contraryEvidenceNotAddressed }
        guard !cleaned.alternatives.isEmpty else { throw InvestigationHypothesisError.alternativesNotAddressed }
        let profile = try await analysis.profile(hypothesisID: hypothesisID)
        guard profile.isSupported else { throw InvestigationHypothesisError.unsupportedCannotConfirm(hypothesisID) }
        return try await analysis.setHypothesisStatus(hypothesisID: hypothesisID, expectedRevision: expectedRevision, to: .confirmed,
                                                      actor: actor, at: date, decision: (cleaned, profile))
    }
    public func rejectHypothesis(hypothesisID: UUID, expectedRevision: Int, actor: String, at date: Date) async throws -> InvestigationHypothesis {
        try await analysis.setHypothesisStatus(hypothesisID: hypothesisID, expectedRevision: expectedRevision, to: .rejected, actor: actor, at: date)
    }

    // MARK: - INV-06 Evidence collection plan

    public func createEvidenceRequest(caseID: UUID, hypothesisID: UUID?, description: String, actor: String, at date: Date) async throws -> EvidenceRequest {
        if let hypothesisID {
            guard let h = try await analysis.fetchHypothesis(hypothesisID), h.caseID == caseID else {
                throw InvestigationHypothesisError.hypothesisNotFound(hypothesisID)
            }
        }
        return try await analysis.createRequest(caseID: caseID, hypothesisID: hypothesisID, description: description, actor: actor, at: date)
    }
    /// The human decision that confirms an evidence request should be pursued.
    public func confirmRequest(requestID: UUID, expectedRevision: Int, actor: String, at date: Date) async throws -> EvidenceRequest {
        try await analysis.setRequestStatus(requestID: requestID, expectedRevision: expectedRevision, to: .confirmed, actor: actor, at: date)
    }
    public func fulfillRequest(requestID: UUID, expectedRevision: Int, actor: String, at date: Date) async throws -> EvidenceRequest {
        try await decideRequest(requestID: requestID, expectedRevision: expectedRevision, status: .fulfilled, note: nil, actor: actor, at: date)
    }
    public func cancelRequest(requestID: UUID, expectedRevision: Int, actor: String, at date: Date) async throws -> EvidenceRequest {
        try await analysis.setRequestStatus(requestID: requestID, expectedRevision: expectedRevision, to: .cancelled, actor: actor, at: date)
    }
    public func requests(caseID: UUID) async throws -> [EvidenceRequest] { try await analysis.requests(caseID: caseID) }

    // MARK: - P1-B: requests that can be followed through (v170)

    /// A request with its linked allegation or question, custodian, period, due date and expected items.
    /// A linked allegation must belong to this case (checked in the write's savepoint).
    public func createEvidenceRequest(caseID: UUID, details: EvidenceRequestDetails, actor: String, at date: Date) async throws -> EvidenceRequest {
        if let hypothesisID = details.hypothesisID {
            guard let h = try await analysis.fetchHypothesis(hypothesisID), h.caseID == caseID else {
                throw InvestigationHypothesisError.hypothesisNotFound(hypothesisID)
            }
        }
        return try await analysis.createRequest(caseID: caseID, details: details, actor: actor, at: date)
    }

    /// The person's decision about a request. Fulfilled while expected items are still missing needs a
    /// note saying why it is accepted as complete; refused and "cannot be obtained" need the reason; partial
    /// needs either something received or a note. Arrivals never set any of these.
    public func decideRequest(requestID: UUID, expectedRevision: Int, status: EvidenceRequestStatus, note: String?,
                              actor: String, at date: Date) async throws -> EvidenceRequest {
        let why = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let request = try await analysis.request(id: requestID) else { throw InvestigationHypothesisError.requestNotFound(requestID) }
        _ = try await requireOpenCaseScope(request.caseID)
        let progress = EvidenceRequestProgress.compute(items: try await analysis.items(requestID: requestID),
                                                       receipts: try await analysis.receipts(requestID: requestID))
        switch status {
        case .fulfilled:
            if !progress.outstanding.isEmpty, why.isEmpty {
                throw InvestigationHypothesisError.requestItemsOutstanding(progress.outstanding.map(\.label))
            }
        case .refused, .unobtainable:
            if why.isEmpty { throw InvestigationHypothesisError.decisionNoteRequired(status) }
        case .partial:
            if progress.received.isEmpty, progress.unassigned == 0, why.isEmpty { throw InvestigationHypothesisError.decisionNoteRequired(status) }
        case .open, .confirmed, .cancelled:
            break
        }
        return try await analysis.setRequestStatus(requestID: requestID, expectedRevision: expectedRevision, to: status,
                                                   note: why.isEmpty ? nil : why, actor: actor, at: date)
    }

    /// Record that the request was sent, what the custodian replied, or a note (the app sends nothing).
    public func recordRequestEvent(requestID: UUID, kind: EvidenceRequestEventKind, detail: String?, actor: String, at date: Date) async throws {
        try await analysis.recordRequestEvent(requestID: requestID, kind: kind, detail: detail, actor: actor, at: date)
    }

    /// Link a document received for the request. The version must be inside the case's authorized scope
    /// and the object (when given) must belong to it. The request's status is not changed.
    @discardableResult
    public func linkReceivedSource(requestID: UUID, itemID: UUID?, sourceVersionID: UUID, knowledgeObjectID: UUID?,
                                   origin: EvidenceReceiptOrigin = .manual, note: String? = nil,
                                   actor: String, at date: Date) async throws -> EvidenceRequestReceipt {
        guard let request = try await analysis.request(id: requestID) else { throw InvestigationHypothesisError.requestNotFound(requestID) }
        let scope = try await requireOpenCaseScope(request.caseID)
        if let knowledgeObjectID {
            try await validateCitation(sourceVersionID: sourceVersionID, knowledgeObjectID: knowledgeObjectID, scope: scope)
        } else if !scope.authorizedSourceVersionIDs.contains(sourceVersionID) {
            throw InvestigationHypothesisError.evidenceOutOfScope(sourceVersionID: sourceVersionID)
        }
        return try await analysis.linkReceipt(requestID: requestID, itemID: itemID, sourceVersionID: sourceVersionID,
                                              knowledgeObjectID: knowledgeObjectID, origin: origin, note: note, actor: actor, at: date)
    }

    public func withdrawReceivedSource(receiptID: UUID, reason: String, actor: String, at date: Date) async throws {
        try await analysis.withdrawReceipt(receiptID: receiptID, reason: reason, actor: actor, at: date)
    }

    public func requestFiles(caseID: UUID) async throws -> [EvidenceRequestFile] { try await analysis.requestFiles(caseID: caseID) }

    // MARK: - INV-05 5W1H worksheet

    /// Answer a 5W1H cell — requires a citation inside the case scope that belongs to the cited version.
    public func answerCell(caseID: UUID, dimension: WorksheetDimension, answer: String, sourceVersionID: UUID,
                           knowledgeObjectID: UUID, actor: String, at date: Date) async throws -> WorksheetCell {
        let scope = try await requireOpenCaseScope(caseID)
        try await validateCitation(sourceVersionID: sourceVersionID, knowledgeObjectID: knowledgeObjectID, scope: scope)
        let clean = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw InvestigationHypothesisError.cellAnswerRequiresEvidence(dimension) }
        return try await analysis.setCell(caseID: caseID, dimension: dimension, status: .answered, answerText: clean,
                                          sourceVersionID: sourceVersionID, knowledgeObjectID: knowledgeObjectID, actor: actor, at: date)
    }
    /// Mark a 5W1H cell explicitly unknown (an unknown is never fabricated).
    public func markCellUnknown(caseID: UUID, dimension: WorksheetDimension, actor: String, at date: Date) async throws -> WorksheetCell {
        _ = try await requireOpenCaseScope(caseID)
        return try await analysis.setCell(caseID: caseID, dimension: dimension, status: .unknown, answerText: nil,
                                          sourceVersionID: nil, knowledgeObjectID: nil, actor: actor, at: date)
    }
    public func cells(caseID: UUID) async throws -> [WorksheetCell] { try await analysis.cells(caseID: caseID) }

    // MARK: - Internals

    private func requireOpenCaseScope(_ caseID: UUID) async throws -> RetrievalSourceScope {
        guard let record = try await cases.fetch(caseID: caseID) else { throw InvestigationHypothesisError.caseNotFound(caseID) }
        guard record.caseHeader.status != .closed else { throw InvestigationHypothesisError.caseClosed(caseID) }
        return try await resolver.scope(for: record)
    }

    /// A citation is valid iff its source version is authorized for the case AND the knowledge object
    /// actually resolves to that source version (no unauthorized or mismatched evidence).
    private func validateCitation(sourceVersionID: UUID, knowledgeObjectID: UUID, scope: RetrievalSourceScope) async throws {
        guard scope.authorizedSourceVersionIDs.contains(sourceVersionID) else {
            throw InvestigationHypothesisError.evidenceOutOfScope(sourceVersionID: sourceVersionID)
        }
        let resolved = try await evidence.currentVersionID(forObject: knowledgeObjectID)
        guard resolved == sourceVersionID else {
            throw InvestigationHypothesisError.evidenceObjectMismatch(knowledgeObjectID: knowledgeObjectID, sourceVersionID: sourceVersionID)
        }
    }
}
