//
//  InvestigationReliabilityService.swift
//  Kalsmritikosh
//
//  INV-08 — the case Source Reliability desk. Orchestration only: it REUSES the shared
//  SourceReliabilityAssessmentRepository (OPS-006) for the actual ratings and records the case's human
//  confirmation in the thin InvestigationDeskReviewRepository. It never forks the reliability authority and
//  never turns a rating into a fact — a reliability rating is a judgement about a source, not a verified
//  claim. The schedule is bounded to the case's authorized source versions and flags a single-source case.
//

import Foundation

public actor InvestigationReliabilityService {
    private let cases: InvestigationCaseRepository
    private let resolver: CaseRetrievalScopeResolver
    private let reliability: SourceReliabilityAssessmentRepository
    private let reviews: InvestigationDeskReviewRepository

    public init(cases: InvestigationCaseRepository, resolver: CaseRetrievalScopeResolver,
                reliability: SourceReliabilityAssessmentRepository, reviews: InvestigationDeskReviewRepository) {
        self.cases = cases; self.resolver = resolver; self.reliability = reliability; self.reviews = reviews
    }

    /// The case Source Reliability Schedule: one entry per authorized source version, carrying its effective
    /// shared assessment (nil = not yet rated), the case's confirmation, and the single-source flag.
    public func schedule(caseID: UUID) async throws -> [ReliabilityScheduleEntry] {
        guard let record = try await cases.fetch(caseID: caseID) else { throw InvestigationDeskError.caseNotFound(caseID) }
        let scope = try await resolver.scope(for: record)
        let versions = scope.authorizedSourceVersionIDs.sorted { $0.uuidString < $1.uuidString }
        let isSingleSource = versions.count == 1
        let effective = try await reliability.assessments(forSourceVersionIDs: versions)
        let caseReviews = try await reviews.reviewsByItem(caseID: caseID, itemKind: .reliability)
        return versions.map { v in
            ReliabilityScheduleEntry(sourceVersionID: v, assessment: effective[v],
                                     review: caseReviews[v.uuidString], isSingleSource: isSingleSource)
        }
    }

    /// Rate a source version's reliability and record the case's confirmation. The rating goes through the
    /// SHARED assessment repository (append-only, audited); the confirmation is a case-scoped desk review.
    /// Fails closed if the source version is not authorized for the case.
    @discardableResult
    public func assessAndConfirm(caseID: UUID, sourceVersionID: UUID, reliability rating: ReliabilityRating,
                                 independence: IndependenceStatus, rationale: String?, actor: String,
                                 at date: Date) async throws -> (assessment: SourceReliabilityAssessment, review: InvestigationDeskReview) {
        let scope = try await requireOpenCaseScope(caseID)
        guard scope.authorizedSourceVersionIDs.contains(sourceVersionID) else {
            throw InvestigationDeskError.sourceOutOfScope(sourceVersionID)
        }
        let assessment = try await reliability.assess(sourceVersionID: sourceVersionID, reliability: rating,
                                                      independence: independence, rationale: rationale, assessedBy: actor, at: date)
        let review = try await reviews.record(caseID: caseID, itemKind: .reliability, itemID: sourceVersionID.uuidString,
                                              decision: .confirmed, note: rationale, actor: actor, at: date)
        return (assessment, review)
    }

    private func requireOpenCaseScope(_ caseID: UUID) async throws -> RetrievalSourceScope {
        guard let record = try await cases.fetch(caseID: caseID) else { throw InvestigationDeskError.caseNotFound(caseID) }
        guard record.caseHeader.status != .closed else { throw InvestigationDeskError.caseClosed(caseID) }
        return try await resolver.scope(for: record)
    }
}
