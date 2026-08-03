//
//  DecisionMethodPack.swift
//  Kalsmritikosh
//
//  Stage B / PM-010 — the decision methods (MET-15 Risk Matrix, MET-16 Decision Matrix), completing
//  the professional-method catalog (MET-01..16). The program may CALCULATE and RECOMMEND, but never
//  makes the final professional decision:
//
//    MET-15 Risk Matrix    — each rated item cites the basis for its likelihood/impact; the method
//                            records no finding, so a rating is never presented as a certain outcome.
//    MET-16 Decision Matrix — each option's scores cite their basis; a selected option is admitted
//                            ONLY as the outcome of a recorded HUMAN decision targeting it (same gate
//                            as Root-Cause). The app never selects the winning option itself.
//

import Foundation

// MARK: - MET-15 Risk Matrix

public nonisolated struct RiskMatrixMethod: ConcreteProfessionalMethod {
    public nonisolated init() {}
    public static let id = ProfessionalMethodDefinitionID(rawValue: "com.kalsmritikosh.method.risk-matrix")
    public static let riskItem = MethodNodeKind(rawValue: "riskItem")
    public static let reviewKey = "confirmRatings"
    public var definition: ProfessionalMethodDefinition {
        ProfessionalMethodDefinition(
            id: Self.id, version: 1, label: "Risk Matrix", category: .decision,
            requiredInputRoles: [], allowedNodeKinds: [Self.riskItem], allowedEdgeKinds: [],
            requiredReviews: [MethodRequiredReview(reviewKey: Self.reviewKey, label: "Confirm each risk rating")],
            validationIdentifiers: [RiskMatrixValidator.identifier],
            outputContract: MethodOutputContract(allowedFindingKinds: [], mayProduceWorkProduct: true))
    }
    public var validators: [any ProfessionalMethodValidating] { [RiskMatrixValidator()] }
}

/// Enforces: at least one rated item, and every item cites the basis for its rating. No finding is
/// admitted, so a rating is never presented as a certain outcome. Deterministic.
public nonisolated struct RiskMatrixValidator: ProfessionalMethodValidating {
    public static let identifier = "method.risk-matrix.v1"
    public nonisolated init() {}
    public var validatorID: String { Self.identifier }
    public var validatorVersion: String { "1" }
    public func validate(context: ProfessionalMethodValidationContext) async throws -> [ProfessionalMethodValidationIssue] {
        var issues: [ProfessionalMethodValidationIssue] = []
        let items = context.aggregate.nodes.filter { $0.nodeKind == RiskMatrixMethod.riskItem }
        if items.isEmpty {
            issues.append(.init(severity: .blocking, code: "NO_RISK_ITEM",
                                message: "A risk matrix needs at least one rated item.", subjectKind: .run))
        }
        let cited = Set(context.aggregate.evidenceLinks.filter { $0.role == .supporting && $0.nodeID != nil }.compactMap { $0.nodeID })
        for item in items where !cited.contains(item.id) {
            issues.append(.init(severity: .blocking, code: "RATING_WITHOUT_BASIS",
                                message: "Each rated item must cite the basis for its likelihood and impact; a rating is not a certain outcome.",
                                subjectKind: .node, subjectID: item.id))
        }
        if issues.isEmpty {
            issues.append(.init(severity: .info, code: "OK", message: "\(items.count) rated item(s), each citing its basis.", subjectKind: .run))
        }
        return issues
    }
}

// MARK: - MET-16 Decision Matrix

public nonisolated struct DecisionMatrixMethod: ConcreteProfessionalMethod {
    public nonisolated init() {}
    public static let id = ProfessionalMethodDefinitionID(rawValue: "com.kalsmritikosh.method.decision-matrix")
    public static let option = MethodNodeKind(rawValue: "option")
    public static let selectedOption = MethodFindingKind(rawValue: "selectedOption")
    public static let decisionReviewKey = "decisionRecorded"
    public var definition: ProfessionalMethodDefinition {
        ProfessionalMethodDefinition(
            id: Self.id, version: 1, label: "Decision Matrix", category: .decision,
            requiredInputRoles: [], allowedNodeKinds: [Self.option], allowedEdgeKinds: [],
            requiredReviews: [MethodRequiredReview(reviewKey: Self.decisionReviewKey, label: "Human decision recorded")],
            validationIdentifiers: [DecisionMatrixValidator.identifier],
            outputContract: MethodOutputContract(allowedFindingKinds: [Self.selectedOption], mayProduceWorkProduct: true))
    }
    public var validators: [any ProfessionalMethodValidating] { [DecisionMatrixValidator()] }
}

/// Enforces: at least one option; every option's scores cite their basis; and any selected-option
/// finding is backed by a HUMAN decision review targeting that finding at the current content
/// revision. The app never makes the final decision itself. Deterministic.
public nonisolated struct DecisionMatrixValidator: ProfessionalMethodValidating {
    public static let identifier = "method.decision-matrix.v1"
    public nonisolated init() {}
    public var validatorID: String { Self.identifier }
    public var validatorVersion: String { "1" }
    public func validate(context: ProfessionalMethodValidationContext) async throws -> [ProfessionalMethodValidationIssue] {
        var issues: [ProfessionalMethodValidationIssue] = []
        let agg = context.aggregate
        let options = agg.nodes.filter { $0.nodeKind == DecisionMatrixMethod.option }
        if options.isEmpty {
            issues.append(.init(severity: .blocking, code: "NO_OPTION",
                                message: "A decision matrix needs at least one option.", subjectKind: .run))
        }
        let cited = Set(agg.evidenceLinks.filter { $0.role == .supporting && $0.nodeID != nil }.compactMap { $0.nodeID })
        for option in options where !cited.contains(option.id) {
            issues.append(.init(severity: .blocking, code: "SCORE_WITHOUT_BASIS",
                                message: "Each option's scores must cite their basis.",
                                subjectKind: .node, subjectID: option.id))
        }
        for finding in agg.findings.filter({ $0.findingKind == DecisionMatrixMethod.selectedOption }) {
            let decided = agg.reviews.contains {
                $0.reviewKey == DecisionMatrixMethod.decisionReviewKey
                    && $0.findingID == finding.id
                    && $0.actorKind == .human
                    && $0.action == .acceptForWorkflow
                    && $0.reviewedContentRevision == context.contentRevision
            }
            if !decided {
                issues.append(.init(severity: .blocking, code: "OPTION_SELECTED_WITHOUT_HUMAN_DECISION",
                                    message: "A selected option requires a recorded human decision; the app never makes the final decision.",
                                    subjectKind: .finding, subjectID: finding.id))
            }
        }
        if issues.isEmpty {
            issues.append(.init(severity: .info, code: "OK", message: "\(options.count) option(s), each scored with a cited basis.", subjectKind: .run))
        }
        return issues
    }
}
