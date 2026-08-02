//
//  FiveW1HMethod.swift
//  Kalsmritikosh
//
//  Stage B / PM-005 — MET-02 5W1H. Six slots (who / what / when / where / why / how). Each slot is a
//  node whose body is the answer. The professional-truth rule the validator enforces: a slot that
//  carries an answer must cite at least one supporting evidence link, OR be explicitly marked
//  unknown (working state `.gap`, or the body literally "unknown"). A fabricated answer for an
//  unknown slot — a value with no evidence, not marked unknown — blocks completion. Each answered
//  slot is confirmed through the required human review. The method produces no findings; the answers
//  stay source-linked slot values, never auto-promoted Claims.
//

import Foundation

public nonisolated struct FiveW1HMethod: ConcreteProfessionalMethod {

    public nonisolated init() {}

    public static let id = ProfessionalMethodDefinitionID(rawValue: "com.kalsmritikosh.method.5w1h")
    public static let version = 1

    /// The subject material (sources / Claims) the worksheet analyses — the required evidence anchor.
    public static let subjectRole = MethodInputRole(rawValue: "subjectContext")

    public static let who = MethodNodeKind(rawValue: "who")
    public static let what = MethodNodeKind(rawValue: "what")
    public static let when = MethodNodeKind(rawValue: "when")
    public static let where_ = MethodNodeKind(rawValue: "where")
    public static let why = MethodNodeKind(rawValue: "why")
    public static let how = MethodNodeKind(rawValue: "how")
    public static let slotKinds: [MethodNodeKind] = [who, what, when, where_, why, how]

    /// The required review confirming each answered slot.
    public static let confirmReviewKey = "confirmSlots"

    /// The sentinel a reviewer writes to mark a slot honestly unanswered.
    public static let unknownMarker = "unknown"

    public var definition: ProfessionalMethodDefinition {
        ProfessionalMethodDefinition(
            id: Self.id,
            version: Self.version,
            label: "5W1H",
            category: .analysis,
            requiredInputRoles: [Self.subjectRole],
            allowedNodeKinds: Self.slotKinds,
            allowedEdgeKinds: [],
            requiredReviews: [MethodRequiredReview(reviewKey: Self.confirmReviewKey,
                                                   label: "Confirm each answered slot")],
            validationIdentifiers: [FiveW1HValidator.identifier],
            outputContract: MethodOutputContract(allowedFindingKinds: [], mayProduceWorkProduct: true))
    }

    public var validators: [any ProfessionalMethodValidating] { [FiveW1HValidator()] }

    /// True when a slot node counts as honestly unanswered (marked unknown or left blank).
    static func isUnknown(_ node: MethodNode) -> Bool {
        if node.workingState == .gap { return true }
        let body = (node.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty || body.lowercased() == unknownMarker
    }
}

/// Enforces: at least one slot present, and every ANSWERED slot cites supporting evidence (else it is
/// a fabricated answer). Deterministic, no I/O.
public nonisolated struct FiveW1HValidator: ProfessionalMethodValidating {
    public static let identifier = "method.5w1h.v1"
    public nonisolated init() {}
    public var validatorID: String { Self.identifier }
    public var validatorVersion: String { "1" }

    public func validate(context: ProfessionalMethodValidationContext) async throws -> [ProfessionalMethodValidationIssue] {
        var issues: [ProfessionalMethodValidationIssue] = []
        let nodes = context.aggregate.nodes
        if nodes.isEmpty {
            issues.append(.init(severity: .blocking, code: "NO_SLOTS",
                                message: "A 5W1H worksheet needs at least one slot before it can be completed.",
                                subjectKind: .run))
        }
        // A supporting evidence link, keyed to a specific slot node, is what makes an answer real.
        let supportingByNode = Set(context.aggregate.evidenceLinks
            .filter { $0.role == .supporting && $0.nodeID != nil }
            .compactMap { $0.nodeID })

        for node in nodes where !FiveW1HMethod.isUnknown(node) {
            if !supportingByNode.contains(node.id) {
                issues.append(.init(severity: .blocking, code: "SLOT_ANSWERED_WITHOUT_EVIDENCE",
                                    message: "The \(node.nodeKind.rawValue) slot has an answer but cites no supporting evidence; cite a source or mark it unknown.",
                                    subjectKind: .node, subjectID: node.id))
            }
        }
        if issues.isEmpty {
            issues.append(.init(severity: .info, code: "OK",
                                message: "Every answered slot cites supporting evidence.",
                                subjectKind: .run))
        }
        return issues
    }
}
