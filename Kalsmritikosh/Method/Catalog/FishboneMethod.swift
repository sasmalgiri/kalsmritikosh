//
//  FishboneMethod.swift
//  Kalsmritikosh
//
//  Stage B / PM-007 — MET-06 Fishbone / Ishikawa. Two node kinds: a `branch` (a causal category) and
//  a `candidateCause` (a child whose parentNodeID is its branch). Both are proposal-layer: a bone is
//  a CANDIDATE cause, never a confirmed root cause — the method allows no findings, so no bone can be
//  recorded as the answer (root-cause confirmation is MET-07). Completion requires at least one
//  branch populated with at least one candidate cause. Branch relevance is confirmed by a required
//  human review.
//

import Foundation

public nonisolated struct FishboneMethod: ConcreteProfessionalMethod {

    public nonisolated init() {}

    public static let id = ProfessionalMethodDefinitionID(rawValue: "com.kalsmritikosh.method.fishbone")
    public static let version = 1

    public static let branch = MethodNodeKind(rawValue: "branch")
    public static let candidateCause = MethodNodeKind(rawValue: "candidateCause")
    public static let problemRole = MethodInputRole(rawValue: "problemStatement")
    public static let confirmReviewKey = "confirmBranches"

    public var definition: ProfessionalMethodDefinition {
        ProfessionalMethodDefinition(
            id: Self.id,
            version: Self.version,
            label: "Fishbone / Ishikawa",
            category: .causal,
            requiredInputRoles: [Self.problemRole],
            allowedNodeKinds: [Self.branch, Self.candidateCause],
            allowedEdgeKinds: [],                          // a candidate cause is a child of its branch (parentNodeID)
            requiredReviews: [MethodRequiredReview(reviewKey: Self.confirmReviewKey,
                                                   label: "Confirm branch relevance")],
            validationIdentifiers: [FishboneValidator.identifier],
            outputContract: MethodOutputContract(allowedFindingKinds: [], mayProduceWorkProduct: true))
    }

    public var validators: [any ProfessionalMethodValidating] { [FishboneValidator()] }
}

/// Enforces: at least one branch, and at least one branch populated with a candidate cause. The
/// "no bone is the confirmed root cause" rule is structural (no findings allowed). Deterministic.
public nonisolated struct FishboneValidator: ProfessionalMethodValidating {
    public static let identifier = "method.fishbone.v1"
    public nonisolated init() {}
    public var validatorID: String { Self.identifier }
    public var validatorVersion: String { "1" }

    public func validate(context: ProfessionalMethodValidationContext) async throws -> [ProfessionalMethodValidationIssue] {
        var issues: [ProfessionalMethodValidationIssue] = []
        let branches = context.aggregate.nodes.filter { $0.nodeKind == FishboneMethod.branch }
        let causes = context.aggregate.nodes.filter { $0.nodeKind == FishboneMethod.candidateCause }
        if branches.isEmpty {
            issues.append(.init(severity: .blocking, code: "NO_BRANCH",
                                message: "A fishbone needs at least one branch.",
                                subjectKind: .run))
        }
        let branchIDs = Set(branches.map(\.id))
        let populatedBranches = Set(causes.compactMap { $0.parentNodeID }).intersection(branchIDs)
        if !branches.isEmpty && populatedBranches.isEmpty {
            issues.append(.init(severity: .blocking, code: "NO_POPULATED_BRANCH",
                                message: "At least one branch must contain a candidate cause before completion.",
                                subjectKind: .run))
        }
        if issues.isEmpty {
            issues.append(.init(severity: .info, code: "OK",
                                message: "\(branches.count) branch(es), \(populatedBranches.count) populated with candidate causes.",
                                subjectKind: .run))
        }
        return issues
    }
}
