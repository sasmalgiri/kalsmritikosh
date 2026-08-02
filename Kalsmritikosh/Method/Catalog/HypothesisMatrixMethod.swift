//
//  HypothesisMatrixMethod.swift
//  Kalsmritikosh
//
//  Stage B / PM-006 — MET-03 Hypothesis Matrix. Each hypothesis is a node; its evidence profile is
//  the set of evidence links attached to it, typed by role: supporting (FOR), contradicting
//  (AGAINST), contextual (NEUTRAL). The completion rule is that EVERY hypothesis carries an evidence
//  profile (at least one link). The app never selects the true hypothesis: the output contract
//  allows no findings, so no "winner" can be recorded here — a hypothesis becomes a confirmed Claim
//  only through the reviewed workflow. Each hypothesis is confirmed or rejected by a required human
//  review.
//

import Foundation

public nonisolated struct HypothesisMatrixMethod: ConcreteProfessionalMethod {

    public nonisolated init() {}

    public static let id = ProfessionalMethodDefinitionID(rawValue: "com.kalsmritikosh.method.hypothesis-matrix")
    public static let version = 1

    public static let hypothesis = MethodNodeKind(rawValue: "hypothesis")
    public static let confirmReviewKey = "confirmHypotheses"

    public var definition: ProfessionalMethodDefinition {
        ProfessionalMethodDefinition(
            id: Self.id,
            version: Self.version,
            label: "Hypothesis Matrix",
            category: .analysis,
            requiredInputRoles: [],                        // the per-hypothesis evidence profile is the anchor
            allowedNodeKinds: [Self.hypothesis],
            allowedEdgeKinds: [],
            requiredReviews: [MethodRequiredReview(reviewKey: Self.confirmReviewKey,
                                                   label: "Confirm or reject each hypothesis")],
            validationIdentifiers: [HypothesisMatrixValidator.identifier],
            outputContract: MethodOutputContract(allowedFindingKinds: [], mayProduceWorkProduct: true))
    }

    public var validators: [any ProfessionalMethodValidating] { [HypothesisMatrixValidator()] }
}

/// Enforces: at least one hypothesis, and every hypothesis carries an evidence profile (at least one
/// evidence link, of any role). Deterministic, no I/O. The "no auto-winner" rule is structural — the
/// method's output contract allows no findings.
public nonisolated struct HypothesisMatrixValidator: ProfessionalMethodValidating {
    public static let identifier = "method.hypothesis-matrix.v1"
    public nonisolated init() {}
    public var validatorID: String { Self.identifier }
    public var validatorVersion: String { "1" }

    public func validate(context: ProfessionalMethodValidationContext) async throws -> [ProfessionalMethodValidationIssue] {
        var issues: [ProfessionalMethodValidationIssue] = []
        let hypotheses = context.aggregate.nodes.filter { $0.nodeKind == HypothesisMatrixMethod.hypothesis }
        if hypotheses.isEmpty {
            issues.append(.init(severity: .blocking, code: "NO_HYPOTHESIS",
                                message: "A hypothesis matrix needs at least one hypothesis.",
                                subjectKind: .run))
        }
        let profiledNodes = Set(context.aggregate.evidenceLinks.compactMap { $0.nodeID })
        for hypothesis in hypotheses where !profiledNodes.contains(hypothesis.id) {
            issues.append(.init(severity: .blocking, code: "HYPOTHESIS_WITHOUT_EVIDENCE_PROFILE",
                                message: "Every hypothesis must carry an evidence profile (for / against / neutral) before completion.",
                                subjectKind: .node, subjectID: hypothesis.id))
        }
        if issues.isEmpty {
            issues.append(.init(severity: .info, code: "OK",
                                message: "\(hypotheses.count) hypothesis/es, each with an evidence profile.",
                                subjectKind: .run))
        }
        return issues
    }
}
