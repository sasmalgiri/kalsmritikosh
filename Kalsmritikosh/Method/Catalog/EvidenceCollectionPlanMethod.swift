//
//  EvidenceCollectionPlanMethod.swift
//  Kalsmritikosh
//
//  Stage B / PM-006 — MET-04 Evidence Collection Plan. Each node is a REQUEST: a described need for
//  evidence that does not yet exist, with a status. The plan is anchored to the case context it
//  supplements. The completion rule is that every request states a need. The prohibited conclusion —
//  "asserting the requested evidence exists" — is enforced by the validator: a request may not carry
//  a supporting evidence link keyed to itself (that would claim the sought evidence is already in
//  hand), and its output contract allows no findings. Requests are confirmed by a required human
//  review; producing the actual evidence request/task uses the existing ProfessionalTask path, not a
//  second action system.
//

import Foundation

public nonisolated struct EvidenceCollectionPlanMethod: ConcreteProfessionalMethod {

    public nonisolated init() {}

    public static let id = ProfessionalMethodDefinitionID(rawValue: "com.kalsmritikosh.method.evidence-collection-plan")
    public static let version = 1

    public static let request = MethodNodeKind(rawValue: "evidenceRequest")
    public static let caseContextRole = MethodInputRole(rawValue: "caseContext")
    public static let confirmReviewKey = "confirmRequests"

    public var definition: ProfessionalMethodDefinition {
        ProfessionalMethodDefinition(
            id: Self.id,
            version: Self.version,
            label: "Evidence Collection Plan",
            category: .planning,
            requiredInputRoles: [Self.caseContextRole],
            allowedNodeKinds: [Self.request],
            allowedEdgeKinds: [],
            requiredReviews: [MethodRequiredReview(reviewKey: Self.confirmReviewKey,
                                                   label: "Confirm each evidence request")],
            validationIdentifiers: [EvidenceCollectionPlanValidator.identifier],
            outputContract: MethodOutputContract(allowedFindingKinds: [], mayProduceWorkProduct: true))
    }

    public var validators: [any ProfessionalMethodValidating] { [EvidenceCollectionPlanValidator()] }
}

/// Enforces: at least one request; every request states a need (non-blank body); and no request
/// asserts that the evidence it seeks already exists (a per-request supporting evidence link is
/// rejected). Deterministic, no I/O.
public nonisolated struct EvidenceCollectionPlanValidator: ProfessionalMethodValidating {
    public static let identifier = "method.evidence-collection-plan.v1"
    public nonisolated init() {}
    public var validatorID: String { Self.identifier }
    public var validatorVersion: String { "1" }

    public func validate(context: ProfessionalMethodValidationContext) async throws -> [ProfessionalMethodValidationIssue] {
        var issues: [ProfessionalMethodValidationIssue] = []
        let requests = context.aggregate.nodes.filter { $0.nodeKind == EvidenceCollectionPlanMethod.request }
        if requests.isEmpty {
            issues.append(.init(severity: .blocking, code: "NO_REQUESTS",
                                message: "An evidence collection plan needs at least one request.",
                                subjectKind: .run))
        }
        // A request that "supports" itself with a cited source would be asserting the sought evidence
        // already exists — the plan is for evidence NOT yet in hand.
        let assertedNodes = Set(context.aggregate.evidenceLinks
            .filter { $0.role == .supporting && $0.nodeID != nil }
            .compactMap { $0.nodeID })
        for request in requests {
            let need = (request.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if need.isEmpty {
                issues.append(.init(severity: .blocking, code: "REQUEST_WITHOUT_NEED",
                                    message: "Each request must describe the evidence need it seeks.",
                                    subjectKind: .node, subjectID: request.id))
            }
            if assertedNodes.contains(request.id) {
                issues.append(.init(severity: .blocking, code: "REQUEST_ASSERTS_EXISTING_EVIDENCE",
                                    message: "A request must not cite the evidence it seeks as already existing.",
                                    subjectKind: .node, subjectID: request.id))
            }
        }
        if issues.isEmpty {
            issues.append(.init(severity: .info, code: "OK",
                                message: "\(requests.count) evidence request(s); none assert the sought evidence exists.",
                                subjectKind: .run))
        }
        return issues
    }
}
