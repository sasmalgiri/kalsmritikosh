//
//  RootCauseAssessmentMethod.swift
//  Kalsmritikosh
//
//  Stage B / PM-008 — MET-07 Root-Cause Assessment. Candidate causes are nodes, each carrying an
//  evidence profile. UNLIKE Five Whys / Fishbone, this method may record a confirmed root cause — but
//  ONLY as the recorded outcome of an explicit HUMAN decision, never by the app itself. The
//  confirmedRootCause finding is admitted by the output contract, and the validator refuses to
//  complete unless every such finding is backed by a human `rootCauseDecision` review that targets
//  that exact finding at the current content revision. So: candidate root cause ≠ confirmed root
//  cause; only a recorded human decision selects it.
//

import Foundation

public nonisolated struct RootCauseAssessmentMethod: ConcreteProfessionalMethod {

    public nonisolated init() {}

    public static let id = ProfessionalMethodDefinitionID(rawValue: "com.kalsmritikosh.method.root-cause")
    public static let version = 1

    public static let candidateCause = MethodNodeKind(rawValue: "candidateCause")
    public static let confirmedRootCause = MethodFindingKind(rawValue: "confirmedRootCause")
    public static let decisionReviewKey = "rootCauseDecision"

    public var definition: ProfessionalMethodDefinition {
        ProfessionalMethodDefinition(
            id: Self.id,
            version: Self.version,
            label: "Root-Cause Assessment",
            category: .assessment,
            requiredInputRoles: [],                        // the per-candidate evidence profiles are the anchor
            allowedNodeKinds: [Self.candidateCause],
            allowedEdgeKinds: [],
            requiredReviews: [MethodRequiredReview(reviewKey: Self.decisionReviewKey,
                                                   label: "Human root-cause decision")],
            validationIdentifiers: [RootCauseValidator.identifier],
            outputContract: MethodOutputContract(allowedFindingKinds: [Self.confirmedRootCause],
                                                 mayProduceWorkProduct: true))
    }

    public var validators: [any ProfessionalMethodValidating] { [RootCauseValidator()] }
}

/// Enforces: at least one candidate cause; every candidate carries an evidence profile; and every
/// confirmed-root-cause finding is backed by a HUMAN decision review targeting that finding at the
/// current content revision. Deterministic, no I/O — the app never confirms a root cause itself.
public nonisolated struct RootCauseValidator: ProfessionalMethodValidating {
    public static let identifier = "method.root-cause.v1"
    public nonisolated init() {}
    public var validatorID: String { Self.identifier }
    public var validatorVersion: String { "1" }

    public func validate(context: ProfessionalMethodValidationContext) async throws -> [ProfessionalMethodValidationIssue] {
        var issues: [ProfessionalMethodValidationIssue] = []
        let agg = context.aggregate
        let candidates = agg.nodes.filter { $0.nodeKind == RootCauseAssessmentMethod.candidateCause }
        if candidates.isEmpty {
            issues.append(.init(severity: .blocking, code: "NO_CANDIDATE",
                                message: "A root-cause assessment needs at least one candidate cause.",
                                subjectKind: .run))
        }
        let profiled = Set(agg.evidenceLinks.compactMap { $0.nodeID })
        for candidate in candidates where !profiled.contains(candidate.id) {
            issues.append(.init(severity: .blocking, code: "CANDIDATE_WITHOUT_EVIDENCE_PROFILE",
                                message: "Every candidate cause must carry an evidence profile.",
                                subjectKind: .node, subjectID: candidate.id))
        }
        // The confirmed root cause is admitted ONLY as the outcome of a recorded human decision.
        let confirmations = agg.findings.filter { $0.findingKind == RootCauseAssessmentMethod.confirmedRootCause }
        for finding in confirmations {
            let decided = agg.reviews.contains {
                $0.reviewKey == RootCauseAssessmentMethod.decisionReviewKey
                    && $0.findingID == finding.id
                    && $0.actorKind == .human
                    && $0.action == .acceptForWorkflow
                    && $0.reviewedContentRevision == context.contentRevision
            }
            if !decided {
                issues.append(.init(severity: .blocking, code: "ROOT_CAUSE_WITHOUT_HUMAN_DECISION",
                                    message: "A confirmed root cause requires a recorded human decision selecting it; the app cannot confirm it.",
                                    subjectKind: .finding, subjectID: finding.id))
            }
        }
        if issues.isEmpty {
            issues.append(.init(severity: .info, code: "OK",
                                message: "\(candidates.count) candidate(s) profiled; \(confirmations.count) human-confirmed root cause(s).",
                                subjectKind: .run))
        }
        return issues
    }
}
