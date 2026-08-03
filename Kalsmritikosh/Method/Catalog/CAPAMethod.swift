//
//  CAPAMethod.swift
//  Kalsmritikosh
//
//  Stage B / PM-008 — MET-08 CAPA (Corrective And Preventive Action). Each node is a corrective or
//  preventive action that MUST link the cause it addresses. Closing a CAPA is a human decision — the
//  method produces no effectiveness finding (action completion ≠ effectiveness; that judgement is
//  MET-09 Effectiveness Review). The validator refuses to complete unless every action links a cause;
//  closure is gated by a required human review. Actual execution of an action uses the existing
//  ProfessionalTask / deadline infrastructure — this method never becomes a second action system.
//

import Foundation

public nonisolated struct CAPAMethod: ConcreteProfessionalMethod {

    public nonisolated init() {}

    public static let id = ProfessionalMethodDefinitionID(rawValue: "com.kalsmritikosh.method.capa")
    public static let version = 1

    public static let correctiveAction = MethodNodeKind(rawValue: "correctiveAction")
    public static let preventiveAction = MethodNodeKind(rawValue: "preventiveAction")
    public static let actionKinds: [MethodNodeKind] = [correctiveAction, preventiveAction]
    public static let closureReviewKey = "capaClosure"

    public var definition: ProfessionalMethodDefinition {
        ProfessionalMethodDefinition(
            id: Self.id,
            version: Self.version,
            label: "CAPA",
            category: .planning,
            requiredInputRoles: [],                        // each action links the cause it addresses
            allowedNodeKinds: Self.actionKinds,
            allowedEdgeKinds: [],
            requiredReviews: [MethodRequiredReview(reviewKey: Self.closureReviewKey,
                                                   label: "Human CAPA closure")],
            validationIdentifiers: [CAPAValidator.identifier],
            outputContract: MethodOutputContract(allowedFindingKinds: [], mayProduceWorkProduct: true))
    }

    public var validators: [any ProfessionalMethodValidating] { [CAPAValidator()] }
}

/// Enforces: at least one action, and every action links the cause it addresses (an evidence link).
/// Closure is a human decision (required review). No effectiveness is asserted here. Deterministic.
public nonisolated struct CAPAValidator: ProfessionalMethodValidating {
    public static let identifier = "method.capa.v1"
    public nonisolated init() {}
    public var validatorID: String { Self.identifier }
    public var validatorVersion: String { "1" }

    public func validate(context: ProfessionalMethodValidationContext) async throws -> [ProfessionalMethodValidationIssue] {
        var issues: [ProfessionalMethodValidationIssue] = []
        let agg = context.aggregate
        let actions = agg.nodes.filter { CAPAMethod.actionKinds.contains($0.nodeKind) }
        if actions.isEmpty {
            issues.append(.init(severity: .blocking, code: "NO_ACTION",
                                message: "A CAPA register needs at least one corrective or preventive action.",
                                subjectKind: .run))
        }
        let linked = Set(agg.evidenceLinks.compactMap { $0.nodeID })
        for action in actions where !linked.contains(action.id) {
            issues.append(.init(severity: .blocking, code: "ACTION_WITHOUT_CAUSE",
                                message: "Every CAPA action must link the cause it addresses.",
                                subjectKind: .node, subjectID: action.id))
        }
        if issues.isEmpty {
            issues.append(.init(severity: .info, code: "OK",
                                message: "\(actions.count) action(s), each linked to a cause; closure awaits human review.",
                                subjectKind: .run))
        }
        return issues
    }
}
