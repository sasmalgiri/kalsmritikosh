//
//  EffectivenessReviewMethod.swift
//  Kalsmritikosh
//
//  Stage B / PM-008 — MET-09 Effectiveness Review. Each node is a check of whether a (closed) CAPA
//  action actually worked. The professional-truth rule: effectiveness is NEVER inferred from the
//  fact that a CAPA task closed — every check must be backed by its own evidence, and the outcome
//  (effective / partially effective / ineffective) is recorded through an independent HUMAN review.
//  The validator refuses to complete unless every check cites supporting evidence. Because the
//  foundation invalidates prior reviews on a content-revision bump (human reopen), a stale
//  effectiveness decision does not survive a change to the underlying checks.
//

import Foundation

public nonisolated struct EffectivenessReviewMethod: ConcreteProfessionalMethod {

    public nonisolated init() {}

    public static let id = ProfessionalMethodDefinitionID(rawValue: "com.kalsmritikosh.method.effectiveness-review")
    public static let version = 1

    public static let check = MethodNodeKind(rawValue: "effectivenessCheck")
    public static let decisionReviewKey = "effectivenessDecision"

    public var definition: ProfessionalMethodDefinition {
        ProfessionalMethodDefinition(
            id: Self.id,
            version: Self.version,
            label: "Effectiveness Review",
            category: .review,
            requiredInputRoles: [],                        // each check cites its own effectiveness evidence
            allowedNodeKinds: [Self.check],
            allowedEdgeKinds: [],
            requiredReviews: [MethodRequiredReview(reviewKey: Self.decisionReviewKey,
                                                   label: "Independent effectiveness decision")],
            validationIdentifiers: [EffectivenessReviewValidator.identifier],
            outputContract: MethodOutputContract(allowedFindingKinds: [], mayProduceWorkProduct: true))
    }

    public var validators: [any ProfessionalMethodValidating] { [EffectivenessReviewValidator()] }
}

/// Enforces: at least one check, and every check is evidence-backed (a supporting evidence link).
/// The effective / partial / ineffective outcome is an independent human review — never inferred
/// from CAPA closure. Deterministic, no I/O.
public nonisolated struct EffectivenessReviewValidator: ProfessionalMethodValidating {
    public static let identifier = "method.effectiveness-review.v1"
    public nonisolated init() {}
    public var validatorID: String { Self.identifier }
    public var validatorVersion: String { "1" }

    public func validate(context: ProfessionalMethodValidationContext) async throws -> [ProfessionalMethodValidationIssue] {
        var issues: [ProfessionalMethodValidationIssue] = []
        let agg = context.aggregate
        let checks = agg.nodes.filter { $0.nodeKind == EffectivenessReviewMethod.check }
        if checks.isEmpty {
            issues.append(.init(severity: .blocking, code: "NO_CHECK",
                                message: "An effectiveness review needs at least one check.",
                                subjectKind: .run))
        }
        let evidenced = Set(agg.evidenceLinks
            .filter { $0.role == .supporting && $0.nodeID != nil }.compactMap { $0.nodeID })
        for check in checks where !evidenced.contains(check.id) {
            issues.append(.init(severity: .blocking, code: "CHECK_WITHOUT_EVIDENCE",
                                message: "Effectiveness cannot be declared without evidence; every check must cite supporting evidence.",
                                subjectKind: .node, subjectID: check.id))
        }
        if issues.isEmpty {
            issues.append(.init(severity: .info, code: "OK",
                                message: "\(checks.count) evidence-backed check(s); the outcome awaits an independent human decision.",
                                subjectKind: .run))
        }
        return issues
    }
}
