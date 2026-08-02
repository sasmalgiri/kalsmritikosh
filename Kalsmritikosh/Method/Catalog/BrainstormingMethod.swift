//
//  BrainstormingMethod.swift
//  Kalsmritikosh
//
//  Stage B / PM-005 — MET-01 Brainstorming. A persistent, reopenable, evidence-anchored proposal
//  space. Every item is TYPED as a proposal (idea / question / assumption / hypothesis / lead /
//  known-Claim reference / evidence need / possible cause) and stays in the proposal layer: the
//  method deliberately produces NO findings (its output contract allows none), so the conformance
//  gate rejects any attempt to record a "finding" here, and the validator blocks any item that has
//  been flipped to human-accepted-for-workflow inside the method. Promotion of an item into a
//  canonical Claim happens ONLY through the existing human-reviewed workflow, never inside a
//  brainstorm. The brainstorm is anchored to the case context it is about (a required evidence
//  link), which satisfies the foundation's "a completed method connects to evidence" invariant
//  without upgrading a single proposal.
//

import Foundation

public nonisolated struct BrainstormingMethod: ConcreteProfessionalMethod {

    public nonisolated init() {}

    public static let id = ProfessionalMethodDefinitionID(rawValue: "com.kalsmritikosh.method.brainstorming")
    public static let version = 1

    /// The one required anchor: the case context / open question the brainstorm is about.
    public static let caseContextRole = MethodInputRole(rawValue: "caseContext")

    /// The typed item vocabulary (each brainstorm item is a node of one of these kinds).
    public static let idea = MethodNodeKind(rawValue: "idea")
    public static let question = MethodNodeKind(rawValue: "question")
    public static let assumption = MethodNodeKind(rawValue: "assumption")
    public static let hypothesis = MethodNodeKind(rawValue: "hypothesis")
    public static let lead = MethodNodeKind(rawValue: "lead")
    public static let knownClaim = MethodNodeKind(rawValue: "knownClaim")
    public static let evidenceNeed = MethodNodeKind(rawValue: "evidenceNeed")
    public static let possibleCause = MethodNodeKind(rawValue: "possibleCause")
    public static let relatesTo = MethodEdgeKind(rawValue: "relatesTo")

    public static let allItemKinds: [MethodNodeKind] =
        [idea, question, assumption, hypothesis, lead, knownClaim, evidenceNeed, possibleCause]

    public var definition: ProfessionalMethodDefinition {
        ProfessionalMethodDefinition(
            id: Self.id,
            version: Self.version,
            label: "Brainstorming",
            category: .analysis,
            requiredInputRoles: [Self.caseContextRole],
            allowedNodeKinds: Self.allItemKinds,
            allowedEdgeKinds: [Self.relatesTo],
            requiredReviews: [],                                   // items stay proposals; no in-method promotion gate
            validationIdentifiers: [BrainstormingValidator.identifier],
            outputContract: MethodOutputContract(allowedFindingKinds: [], mayProduceWorkProduct: true))
    }

    public var validators: [any ProfessionalMethodValidating] { [BrainstormingValidator()] }
}

/// Enforces the two brainstorming rules: at least one typed item, and no item silently treated as a
/// fact (flipped to human-accepted-for-workflow) inside the method. Deterministic, no I/O.
public nonisolated struct BrainstormingValidator: ProfessionalMethodValidating {
    public static let identifier = "method.brainstorming.v1"
    public nonisolated init() {}
    public var validatorID: String { Self.identifier }
    public var validatorVersion: String { "1" }

    public func validate(context: ProfessionalMethodValidationContext) async throws -> [ProfessionalMethodValidationIssue] {
        var issues: [ProfessionalMethodValidationIssue] = []
        let nodes = context.aggregate.nodes
        if nodes.isEmpty {
            issues.append(.init(severity: .blocking, code: "NO_ITEMS",
                                message: "A brainstorm needs at least one typed item before it can be completed.",
                                subjectKind: .run))
        }
        // Proposals are not upgraded inside the method — an item accepted-for-workflow here would be
        // a fact promotion without the reviewed workflow path.
        for node in nodes where node.workingState == .humanAcceptedForWorkflow {
            issues.append(.init(severity: .blocking, code: "ITEM_PROMOTED_IN_METHOD",
                                message: "A brainstorm item cannot be promoted to a fact inside the method; use the reviewed workflow.",
                                subjectKind: .node, subjectID: node.id))
        }
        if issues.isEmpty {
            issues.append(.init(severity: .info, code: "OK",
                                message: "\(nodes.count) proposal item(s); none promoted in-method.",
                                subjectKind: .run))
        }
        return issues
    }
}
