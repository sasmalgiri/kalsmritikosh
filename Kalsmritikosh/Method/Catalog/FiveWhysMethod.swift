//
//  FiveWhysMethod.swift
//  Kalsmritikosh
//
//  Stage B / PM-007 — MET-05 Five Whys. Each "why" is a node; a deeper level is a child (its
//  parentNodeID points at the shallower why it explains). The professional-truth rule: you may only
//  go DEEPER from a why that is itself supported — by a supporting evidence link or an EXPLICIT
//  assumption. A non-leaf why with no support blocks completion ("forcing five levels without
//  supporting evidence"). A leaf why with no support is the HONEST STOP — the analysis ends when
//  evidence runs out, it is not padded. Five Whys proposes candidate causes only; it never confirms
//  a root cause (no findings allowed — that is MET-07 Root-Cause Assessment). Each level is confirmed
//  by a required human review.
//

import Foundation

public nonisolated struct FiveWhysMethod: ConcreteProfessionalMethod {

    public nonisolated init() {}

    public static let id = ProfessionalMethodDefinitionID(rawValue: "com.kalsmritikosh.method.five-whys")
    public static let version = 1

    public static let why = MethodNodeKind(rawValue: "why")
    public static let problemRole = MethodInputRole(rawValue: "problemStatement")
    public static let confirmReviewKey = "confirmLevels"

    public var definition: ProfessionalMethodDefinition {
        ProfessionalMethodDefinition(
            id: Self.id,
            version: Self.version,
            label: "Five Whys",
            category: .causal,
            requiredInputRoles: [Self.problemRole],
            allowedNodeKinds: [Self.why],
            allowedEdgeKinds: [],                          // depth is expressed by parentNodeID
            requiredReviews: [MethodRequiredReview(reviewKey: Self.confirmReviewKey,
                                                   label: "Confirm each Why level")],
            validationIdentifiers: [FiveWhysValidator.identifier],
            outputContract: MethodOutputContract(allowedFindingKinds: [], mayProduceWorkProduct: true))
    }

    public var validators: [any ProfessionalMethodValidating] { [FiveWhysValidator()] }
}

/// Enforces: at least one why, and every NON-LEAF why (one the chain deepens beyond) is supported by
/// a supporting evidence link or an explicit assumption. Deterministic, no I/O.
public nonisolated struct FiveWhysValidator: ProfessionalMethodValidating {
    public static let identifier = "method.five-whys.v1"
    public nonisolated init() {}
    public var validatorID: String { Self.identifier }
    public var validatorVersion: String { "1" }

    public func validate(context: ProfessionalMethodValidationContext) async throws -> [ProfessionalMethodValidationIssue] {
        var issues: [ProfessionalMethodValidationIssue] = []
        let whys = context.aggregate.nodes.filter { $0.nodeKind == FiveWhysMethod.why }
        if whys.isEmpty {
            issues.append(.init(severity: .blocking, code: "NO_WHY",
                                message: "A Five Whys analysis needs at least one why.",
                                subjectKind: .run))
        }
        // A why is non-leaf when another why deepens from it (that why's parentNodeID points here).
        let nonLeaf = Set(whys.compactMap { $0.parentNodeID })
        let supportedByEvidence = Set(context.aggregate.evidenceLinks
            .filter { $0.role == .supporting && $0.nodeID != nil }.compactMap { $0.nodeID })
        let backedByAssumption = Set(context.aggregate.assumptions.compactMap { $0.nodeID })

        for why in whys where nonLeaf.contains(why.id) {
            if !supportedByEvidence.contains(why.id) && !backedByAssumption.contains(why.id) {
                issues.append(.init(severity: .blocking, code: "WHY_DEEPENED_WITHOUT_SUPPORT",
                                    message: "This level is deepened further but is not supported by evidence or an explicit assumption; support it or stop the chain here.",
                                    subjectKind: .node, subjectID: why.id))
            }
        }
        if issues.isEmpty {
            issues.append(.init(severity: .info, code: "OK",
                                message: "\(whys.count) why level(s); every deepened level is supported.",
                                subjectKind: .run))
        }
        return issues
    }
}
