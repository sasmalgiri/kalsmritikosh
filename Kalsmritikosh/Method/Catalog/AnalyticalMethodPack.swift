//
//  AnalyticalMethodPack.swift
//  Kalsmritikosh
//
//  Stage B / PM-009 — the analytical method pack (MET-10..MET-14). Five concrete methods that
//  organise evidence without ever asserting a conclusion of their own: every one has an EMPTY output
//  contract (no findings), so none can average accounts, pick a winner, imply wrongdoing, invent a
//  date, or conclude fraud. Each enforces its own citation discipline through a deterministic
//  validator and confirms inclusion through a required human review.
//
//    MET-10 Contradiction Matrix — each conflict preserves BOTH sides (≥2 evidence links); no winner.
//    MET-11 Gap Analysis        — each gap states a reason; the searched scope is stated; absence of
//                                 evidence never implies wrongdoing (no findings).
//    MET-12 Timeline Analysis   — each row is cited OR explicitly marked undated; no invented dates.
//    MET-13 Relationship Analysis — each asserted edge cites evidence.
//    MET-14 Transaction Flow    — each transaction's amount traces to a source; no fraud conclusion.
//

import Foundation

// MARK: - MET-10 Contradiction Matrix

public nonisolated struct ContradictionMatrixMethod: ConcreteProfessionalMethod {
    public nonisolated init() {}
    public static let id = ProfessionalMethodDefinitionID(rawValue: "com.kalsmritikosh.method.contradiction-matrix")
    public static let conflict = MethodNodeKind(rawValue: "contradiction")
    public static let reviewKey = "confirmConflicts"
    public var definition: ProfessionalMethodDefinition {
        ProfessionalMethodDefinition(
            id: Self.id, version: 1, label: "Contradiction Matrix", category: .analysis,
            requiredInputRoles: [], allowedNodeKinds: [Self.conflict], allowedEdgeKinds: [],
            requiredReviews: [MethodRequiredReview(reviewKey: Self.reviewKey, label: "Confirm or dismiss each conflict")],
            validationIdentifiers: [ContradictionMatrixValidator.identifier],
            outputContract: MethodOutputContract(allowedFindingKinds: [], mayProduceWorkProduct: true))
    }
    public var validators: [any ProfessionalMethodValidating] { [ContradictionMatrixValidator()] }
}

public nonisolated struct ContradictionMatrixValidator: ProfessionalMethodValidating {
    public static let identifier = "method.contradiction-matrix.v1"
    public nonisolated init() {}
    public var validatorID: String { Self.identifier }
    public var validatorVersion: String { "1" }
    public func validate(context: ProfessionalMethodValidationContext) async throws -> [ProfessionalMethodValidationIssue] {
        var issues: [ProfessionalMethodValidationIssue] = []
        let conflicts = context.aggregate.nodes.filter { $0.nodeKind == ContradictionMatrixMethod.conflict }
        if conflicts.isEmpty {
            issues.append(.init(severity: .blocking, code: "NO_CONFLICT",
                                message: "A contradiction matrix needs at least one conflict.", subjectKind: .run))
        }
        var sideCount: [UUID: Int] = [:]
        for link in context.aggregate.evidenceLinks { if let n = link.nodeID { sideCount[n, default: 0] += 1 } }
        for conflict in conflicts where (sideCount[conflict.id] ?? 0) < 2 {
            issues.append(.init(severity: .blocking, code: "CONFLICT_MISSING_A_SIDE",
                                message: "Every contradiction must preserve both sides (cite evidence for each account); the app never picks a winner.",
                                subjectKind: .node, subjectID: conflict.id))
        }
        if issues.isEmpty {
            issues.append(.init(severity: .info, code: "OK", message: "\(conflicts.count) conflict(s), both sides preserved.", subjectKind: .run))
        }
        return issues
    }
}

// MARK: - MET-11 Gap Analysis

public nonisolated struct GapAnalysisMethod: ConcreteProfessionalMethod {
    public nonisolated init() {}
    public static let id = ProfessionalMethodDefinitionID(rawValue: "com.kalsmritikosh.method.gap-analysis")
    public static let gap = MethodNodeKind(rawValue: "gap")
    public static let searchedScopeRole = MethodInputRole(rawValue: "searchedScope")
    public static let reviewKey = "confirmGaps"
    public var definition: ProfessionalMethodDefinition {
        ProfessionalMethodDefinition(
            id: Self.id, version: 1, label: "Gap Analysis", category: .analysis,
            requiredInputRoles: [Self.searchedScopeRole], allowedNodeKinds: [Self.gap], allowedEdgeKinds: [],
            requiredReviews: [MethodRequiredReview(reviewKey: Self.reviewKey, label: "Confirm or dismiss each gap")],
            validationIdentifiers: [GapAnalysisValidator.identifier],
            outputContract: MethodOutputContract(allowedFindingKinds: [], mayProduceWorkProduct: true))
    }
    public var validators: [any ProfessionalMethodValidating] { [GapAnalysisValidator()] }
}

public nonisolated struct GapAnalysisValidator: ProfessionalMethodValidating {
    public static let identifier = "method.gap-analysis.v1"
    public nonisolated init() {}
    public var validatorID: String { Self.identifier }
    public var validatorVersion: String { "1" }
    public func validate(context: ProfessionalMethodValidationContext) async throws -> [ProfessionalMethodValidationIssue] {
        var issues: [ProfessionalMethodValidationIssue] = []
        let gaps = context.aggregate.nodes.filter { $0.nodeKind == GapAnalysisMethod.gap }
        if gaps.isEmpty {
            issues.append(.init(severity: .blocking, code: "NO_GAP",
                                message: "A gap analysis needs at least one gap.", subjectKind: .run))
        }
        for gap in gaps where (gap.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(severity: .blocking, code: "GAP_WITHOUT_REASON",
                                message: "Each gap must state why the missing evidence matters (absence never implies wrongdoing).",
                                subjectKind: .node, subjectID: gap.id))
        }
        if issues.isEmpty {
            issues.append(.init(severity: .info, code: "OK", message: "\(gaps.count) categorised gap(s); searched scope stated.", subjectKind: .run))
        }
        return issues
    }
}

// MARK: - MET-12 Timeline Analysis

public nonisolated struct TimelineAnalysisMethod: ConcreteProfessionalMethod {
    public nonisolated init() {}
    public static let id = ProfessionalMethodDefinitionID(rawValue: "com.kalsmritikosh.method.timeline-analysis")
    public static let row = MethodNodeKind(rawValue: "timelineRow")
    public static let reviewKey = "confirmInclusion"
    public static let undatedMarker = "undated"
    public var definition: ProfessionalMethodDefinition {
        ProfessionalMethodDefinition(
            id: Self.id, version: 1, label: "Timeline Analysis", category: .analysis,
            requiredInputRoles: [], allowedNodeKinds: [Self.row], allowedEdgeKinds: [],
            requiredReviews: [MethodRequiredReview(reviewKey: Self.reviewKey, label: "Confirm each row's inclusion")],
            validationIdentifiers: [TimelineAnalysisValidator.identifier],
            outputContract: MethodOutputContract(allowedFindingKinds: [], mayProduceWorkProduct: true))
    }
    public var validators: [any ProfessionalMethodValidating] { [TimelineAnalysisValidator()] }
    static func isUndated(_ node: MethodNode) -> Bool {
        node.workingState == .gap || (node.body ?? "").lowercased().contains(undatedMarker)
    }
}

public nonisolated struct TimelineAnalysisValidator: ProfessionalMethodValidating {
    public static let identifier = "method.timeline-analysis.v1"
    public nonisolated init() {}
    public var validatorID: String { Self.identifier }
    public var validatorVersion: String { "1" }
    public func validate(context: ProfessionalMethodValidationContext) async throws -> [ProfessionalMethodValidationIssue] {
        var issues: [ProfessionalMethodValidationIssue] = []
        let rows = context.aggregate.nodes.filter { $0.nodeKind == TimelineAnalysisMethod.row }
        if rows.isEmpty {
            issues.append(.init(severity: .blocking, code: "NO_ROW",
                                message: "A timeline needs at least one row.", subjectKind: .run))
        }
        let cited = Set(context.aggregate.evidenceLinks.filter { $0.role == .supporting && $0.nodeID != nil }.compactMap { $0.nodeID })
        for row in rows where !TimelineAnalysisMethod.isUndated(row) && !cited.contains(row.id) {
            issues.append(.init(severity: .blocking, code: "DATED_ROW_WITHOUT_CITATION",
                                message: "A dated row must cite its source, or be explicitly marked undated; dates are never invented or padded.",
                                subjectKind: .node, subjectID: row.id))
        }
        if issues.isEmpty {
            issues.append(.init(severity: .info, code: "OK", message: "\(rows.count) row(s); every dated row cited, undated rows labelled.", subjectKind: .run))
        }
        return issues
    }
}

// MARK: - MET-13 Relationship Analysis

public nonisolated struct RelationshipAnalysisMethod: ConcreteProfessionalMethod {
    public nonisolated init() {}
    public static let id = ProfessionalMethodDefinitionID(rawValue: "com.kalsmritikosh.method.relationship-analysis")
    public static let relationship = MethodNodeKind(rawValue: "relationship")
    public static let reviewKey = "confirmEdges"
    public var definition: ProfessionalMethodDefinition {
        ProfessionalMethodDefinition(
            id: Self.id, version: 1, label: "Relationship Analysis", category: .analysis,
            requiredInputRoles: [], allowedNodeKinds: [Self.relationship], allowedEdgeKinds: [],
            requiredReviews: [MethodRequiredReview(reviewKey: Self.reviewKey, label: "Confirm each relationship edge")],
            validationIdentifiers: [RelationshipAnalysisValidator.identifier],
            outputContract: MethodOutputContract(allowedFindingKinds: [], mayProduceWorkProduct: true))
    }
    public var validators: [any ProfessionalMethodValidating] { [RelationshipAnalysisValidator()] }
}

public nonisolated struct RelationshipAnalysisValidator: ProfessionalMethodValidating {
    public static let identifier = "method.relationship-analysis.v1"
    public nonisolated init() {}
    public var validatorID: String { Self.identifier }
    public var validatorVersion: String { "1" }
    public func validate(context: ProfessionalMethodValidationContext) async throws -> [ProfessionalMethodValidationIssue] {
        var issues: [ProfessionalMethodValidationIssue] = []
        let edges = context.aggregate.nodes.filter { $0.nodeKind == RelationshipAnalysisMethod.relationship }
        if edges.isEmpty {
            issues.append(.init(severity: .blocking, code: "NO_RELATIONSHIP",
                                message: "A relationship analysis needs at least one relationship.", subjectKind: .run))
        }
        let cited = Set(context.aggregate.evidenceLinks.filter { $0.role == .supporting && $0.nodeID != nil }.compactMap { $0.nodeID })
        for edge in edges where !cited.contains(edge.id) {
            issues.append(.init(severity: .blocking, code: "RELATIONSHIP_WITHOUT_EVIDENCE",
                                message: "Each asserted relationship must cite evidence.",
                                subjectKind: .node, subjectID: edge.id))
        }
        if issues.isEmpty {
            issues.append(.init(severity: .info, code: "OK", message: "\(edges.count) relationship(s), each cited.", subjectKind: .run))
        }
        return issues
    }
}

// MARK: - MET-14 Transaction Flow

public nonisolated struct TransactionFlowMethod: ConcreteProfessionalMethod {
    public nonisolated init() {}
    public static let id = ProfessionalMethodDefinitionID(rawValue: "com.kalsmritikosh.method.transaction-flow")
    public static let party = MethodNodeKind(rawValue: "party")
    public static let transaction = MethodNodeKind(rawValue: "transaction")
    public static let reviewKey = "confirmFlow"
    public var definition: ProfessionalMethodDefinition {
        ProfessionalMethodDefinition(
            id: Self.id, version: 1, label: "Transaction Flow", category: .analysis,
            requiredInputRoles: [], allowedNodeKinds: [Self.party, Self.transaction], allowedEdgeKinds: [],
            requiredReviews: [MethodRequiredReview(reviewKey: Self.reviewKey, label: "Confirm the transaction flow")],
            validationIdentifiers: [TransactionFlowValidator.identifier],
            outputContract: MethodOutputContract(allowedFindingKinds: [], mayProduceWorkProduct: true))
    }
    public var validators: [any ProfessionalMethodValidating] { [TransactionFlowValidator()] }
}

public nonisolated struct TransactionFlowValidator: ProfessionalMethodValidating {
    public static let identifier = "method.transaction-flow.v1"
    public nonisolated init() {}
    public var validatorID: String { Self.identifier }
    public var validatorVersion: String { "1" }
    public func validate(context: ProfessionalMethodValidationContext) async throws -> [ProfessionalMethodValidationIssue] {
        var issues: [ProfessionalMethodValidationIssue] = []
        let transactions = context.aggregate.nodes.filter { $0.nodeKind == TransactionFlowMethod.transaction }
        if transactions.isEmpty {
            issues.append(.init(severity: .blocking, code: "NO_TRANSACTION",
                                message: "A transaction flow needs at least one transaction.", subjectKind: .run))
        }
        let traced = Set(context.aggregate.evidenceLinks.filter { $0.role == .supporting && $0.nodeID != nil }.compactMap { $0.nodeID })
        for txn in transactions where !traced.contains(txn.id) {
            issues.append(.init(severity: .blocking, code: "AMOUNT_WITHOUT_SOURCE",
                                message: "Each transaction's amount must trace to a source; the flow never concludes fraud on its own.",
                                subjectKind: .node, subjectID: txn.id))
        }
        if issues.isEmpty {
            issues.append(.init(severity: .info, code: "OK", message: "\(transactions.count) transaction(s), each traced to source.", subjectKind: .run))
        }
        return issues
    }
}
