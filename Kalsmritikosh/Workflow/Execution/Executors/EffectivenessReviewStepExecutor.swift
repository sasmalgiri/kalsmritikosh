//
//  EffectivenessReviewStepExecutor.swift
//  Kalsmritikosh
//
//  PJE-006C — Handles the `effectivenessReview` step kind.
//
//  The assessment vocabulary is WORKFLOW-REVIEW vocabulary — it is not an
//  evidence-status enum and is never mapped to a confirmed Claim, root-cause
//  confirmation, CAPA closure, legal conclusion, or publication approval.
//  Only a HUMAN actor may record the final assessment; the executor organizes
//  criteria and observations but never judges autonomously.
//  Commands: setSubject, addCriterion, addObservation, recordAssessment, complete.
//

import Foundation

// MARK: - Assessment vocabulary (workflow review, NOT canonical truth)

public enum WorkflowEffectivenessAssessment: String, Codable, CaseIterable, Sendable {
    case effective
    case partiallyEffective
    case ineffective
    case inconclusive
}

// MARK: - Criterion / observation

public nonisolated struct EffectivenessCriterion: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let expectedCondition: String

    public nonisolated init(id: String, label: String, expectedCondition: String) {
        self.id = id
        self.label = label
        self.expectedCondition = expectedCondition
    }
}

public nonisolated struct EffectivenessObservation: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let criterionID: String
    public let observation: String
    public let evidenceReferences: [WorkflowMethodProvenanceReference]

    public nonisolated init(
        id: UUID,
        criterionID: String,
        observation: String,
        evidenceReferences: [WorkflowMethodProvenanceReference]
    ) {
        self.id = id
        self.criterionID = criterionID
        self.observation = observation
        self.evidenceReferences = evidenceReferences
    }
}

// MARK: - State

public nonisolated struct EffectivenessReviewStepState: Codable, Hashable, Sendable {
    public let subjectReferenceKind: String
    public let subjectReferenceID: String
    public let criteria: [EffectivenessCriterion]
    public let observations: [EffectivenessObservation]
    public let assessment: WorkflowEffectivenessAssessment?
    public let rationale: String?
    public let reviewedBy: String?
    public let reviewedAt: Date?
    public let followUpRequired: Bool
    public let followUpNote: String?

    public nonisolated init(
        subjectReferenceKind: String = "",
        subjectReferenceID: String = "",
        criteria: [EffectivenessCriterion] = [],
        observations: [EffectivenessObservation] = [],
        assessment: WorkflowEffectivenessAssessment? = nil,
        rationale: String? = nil,
        reviewedBy: String? = nil,
        reviewedAt: Date? = nil,
        followUpRequired: Bool = false,
        followUpNote: String? = nil
    ) {
        self.subjectReferenceKind = subjectReferenceKind
        self.subjectReferenceID = subjectReferenceID
        self.criteria = criteria
        self.observations = observations
        self.assessment = assessment
        self.rationale = rationale
        self.reviewedBy = reviewedBy
        self.reviewedAt = reviewedAt
        self.followUpRequired = followUpRequired
        self.followUpNote = followUpNote
    }
}

// MARK: - Command

public enum EffectivenessReviewStepCommand: Sendable, Equatable {
    case setSubject(referenceKind: String, referenceID: String)
    case addCriterion(EffectivenessCriterion)
    case addObservation(criterionID: String, observation: String,
                        evidenceReferences: [WorkflowMethodProvenanceReference])
    case recordAssessment(assessment: WorkflowEffectivenessAssessment, rationale: String,
                          followUpRequired: Bool, followUpNote: String?)
    case complete
}

extension EffectivenessReviewStepCommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, referenceKind, referenceID, criterion
        case criterionID, observation, evidenceReferences
        case assessment, rationale, followUpRequired, followUpNote
    }

    public nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "setSubject":
            self = .setSubject(
                referenceKind: try c.decode(String.self, forKey: .referenceKind),
                referenceID: try c.decode(String.self, forKey: .referenceID))
        case "addCriterion":
            self = .addCriterion(try c.decode(EffectivenessCriterion.self, forKey: .criterion))
        case "addObservation":
            self = .addObservation(
                criterionID: try c.decode(String.self, forKey: .criterionID),
                observation: try c.decode(String.self, forKey: .observation),
                evidenceReferences: try c.decodeIfPresent(
                    [WorkflowMethodProvenanceReference].self, forKey: .evidenceReferences) ?? [])
        case "recordAssessment":
            self = .recordAssessment(
                assessment: try c.decode(WorkflowEffectivenessAssessment.self, forKey: .assessment),
                rationale: try c.decode(String.self, forKey: .rationale),
                followUpRequired: try c.decode(Bool.self, forKey: .followUpRequired),
                followUpNote: try c.decodeIfPresent(String.self, forKey: .followUpNote))
        case "complete":
            self = .complete
        default:
            throw WorkflowStepExecutionError.malformedCommandJSON
        }
    }

    public nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .setSubject(let referenceKind, let referenceID):
            try c.encode("setSubject", forKey: .type)
            try c.encode(referenceKind, forKey: .referenceKind)
            try c.encode(referenceID, forKey: .referenceID)
        case .addCriterion(let criterion):
            try c.encode("addCriterion", forKey: .type)
            try c.encode(criterion, forKey: .criterion)
        case .addObservation(let criterionID, let observation, let evidenceReferences):
            try c.encode("addObservation", forKey: .type)
            try c.encode(criterionID, forKey: .criterionID)
            try c.encode(observation, forKey: .observation)
            try c.encode(evidenceReferences, forKey: .evidenceReferences)
        case .recordAssessment(let assessment, let rationale, let followUpRequired, let followUpNote):
            try c.encode("recordAssessment", forKey: .type)
            try c.encode(assessment, forKey: .assessment)
            try c.encode(rationale, forKey: .rationale)
            try c.encode(followUpRequired, forKey: .followUpRequired)
            if let followUpNote = followUpNote { try c.encode(followUpNote, forKey: .followUpNote) }
        case .complete:
            try c.encode("complete", forKey: .type)
        }
    }
}

// MARK: - Executor

public nonisolated struct EffectivenessReviewStepExecutor: WorkflowStepExecutor {

    public nonisolated let executorID = WorkflowStepExecutorID(
        rawValue: "com.kalsmritikosh.step.effectiveness-review"
    )
    public nonisolated let executorVersion = WorkflowStepExecutorVersion(rawValue: "1")
    public nonisolated let handledKind: WorkflowStepKind = .effectivenessReview

    private let gate: any WorkflowEvidenceReferenceGating

    public nonisolated init(gate: any WorkflowEvidenceReferenceGating) {
        self.gate = gate
    }

    public func prepare(
        context: WorkflowStepPreparationContext
    ) async throws -> WorkflowStepPreparationResult {
        guard context.step.kind == handledKind else {
            throw WorkflowStepExecutionError.executorKindMismatch(
                executor: executorID, expected: handledKind, actual: context.step.kind
            )
        }
        let (json, sha) = try makeEnvelope(state: EffectivenessReviewStepState(), stepKind: handledKind)
        return WorkflowStepPreparationResult(
            inputJSON: "{}", stateJSON: json, stateSHA256: sha,
            executorID: executorID, executorVersion: executorVersion
        )
    }

    public func execute(
        context: WorkflowStepExecutionContext,
        commandJSON: String
    ) async throws -> WorkflowStepExecutionResult {
        guard context.step.kind == handledKind else {
            throw WorkflowStepExecutionError.executorKindMismatch(
                executor: executorID, expected: handledKind, actual: context.step.kind
            )
        }
        let state = try decodeCurrentState(EffectivenessReviewStepState.self, from: context.stepRun)
        let command: EffectivenessReviewStepCommand
        do {
            command = try WorkflowStepPayloadCodec.decode(
                EffectivenessReviewStepCommand.self, from: commandJSON)
        } catch {
            throw WorkflowStepExecutionError.malformedCommandJSON
        }

        func save(_ newState: EffectivenessReviewStepState) throws -> WorkflowStepExecutionResult {
            let (json, sha) = try makeEnvelope(state: newState, stepKind: handledKind)
            return WorkflowStepExecutionResult(stateJSON: json, stateSHA256: sha, disposition: .remainActive)
        }

        switch command {
        case .setSubject(let referenceKind, let referenceID):
            guard !referenceKind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !referenceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "subject", reason: "Subject reference must not be blank")
            }
            return try save(EffectivenessReviewStepState(
                subjectReferenceKind: referenceKind, subjectReferenceID: referenceID,
                criteria: state.criteria, observations: state.observations,
                assessment: state.assessment, rationale: state.rationale,
                reviewedBy: state.reviewedBy, reviewedAt: state.reviewedAt,
                followUpRequired: state.followUpRequired, followUpNote: state.followUpNote))

        case .addCriterion(let criterion):
            guard !criterion.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !criterion.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "criterion", reason: "Criterion ID and label must not be blank")
            }
            guard !state.criteria.contains(where: { $0.id == criterion.id }) else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "criterion", reason: "Criterion IDs must be unique")
            }
            return try save(EffectivenessReviewStepState(
                subjectReferenceKind: state.subjectReferenceKind,
                subjectReferenceID: state.subjectReferenceID,
                criteria: state.criteria + [criterion], observations: state.observations,
                assessment: state.assessment, rationale: state.rationale,
                reviewedBy: state.reviewedBy, reviewedAt: state.reviewedAt,
                followUpRequired: state.followUpRequired, followUpNote: state.followUpNote))

        case .addObservation(let criterionID, let observation, let evidenceReferences):
            guard state.criteria.contains(where: { $0.id == criterionID }) else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "criterionID", reason: "Observation must reference a declared criterion")
            }
            guard !observation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "observation", reason: "Observation must not be blank")
            }
            // Canonical evidence references are workspace-gated.
            for ref in evidenceReferences {
                guard let kind = WorkflowEvidenceObjectKind(rawValue: ref.objectKind),
                      let objectUUID = UUID(uuidString: ref.canonicalObjectID) else {
                    throw WorkflowStepExecutionError.validationFailed(
                        field: "evidenceReferences", reason: "Invalid canonical reference")
                }
                let verdict = await gate.verdict(
                    kind: kind, canonicalObjectID: objectUUID,
                    workspaceID: context.aggregate.run.workspaceID)
                guard case .permitted = verdict else {
                    if case .denied(let why) = verdict {
                        throw WorkflowStepExecutionError.validationFailed(
                            field: "evidenceReferences", reason: why)
                    }
                    throw WorkflowStepExecutionError.validationFailed(
                        field: "evidenceReferences", reason: "Reference denied")
                }
            }
            let newObservation = EffectivenessObservation(
                id: UUID(), criterionID: criterionID,
                observation: observation, evidenceReferences: evidenceReferences)
            return try save(EffectivenessReviewStepState(
                subjectReferenceKind: state.subjectReferenceKind,
                subjectReferenceID: state.subjectReferenceID,
                criteria: state.criteria, observations: state.observations + [newObservation],
                assessment: state.assessment, rationale: state.rationale,
                reviewedBy: state.reviewedBy, reviewedAt: state.reviewedAt,
                followUpRequired: state.followUpRequired, followUpNote: state.followUpNote))

        case .recordAssessment(let assessment, let rationale, let followUpRequired, let followUpNote):
            // ONLY a human actor may record the final assessment.
            guard context.actor.kind == .human,
                  let reviewer = context.actor.identifier,
                  !reviewer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "actor",
                    reason: "Only an identified human reviewer may record the effectiveness assessment")
            }
            guard !rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "rationale", reason: "Assessment rationale must not be blank")
            }
            if followUpRequired {
                guard let note = followUpNote,
                      !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw WorkflowStepExecutionError.validationFailed(
                        field: "followUpNote",
                        reason: "A follow-up note is required when follow-up is required")
                }
            }
            return try save(EffectivenessReviewStepState(
                subjectReferenceKind: state.subjectReferenceKind,
                subjectReferenceID: state.subjectReferenceID,
                criteria: state.criteria, observations: state.observations,
                assessment: assessment, rationale: rationale,
                reviewedBy: reviewer, reviewedAt: context.executedAt,
                followUpRequired: followUpRequired, followUpNote: followUpNote))

        case .complete:
            guard state.assessment != nil,
                  state.rationale != nil,
                  let reviewer = state.reviewedBy,
                  !reviewer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind,
                    reason: "A human-recorded assessment with rationale is required before completion")
            }
            if state.followUpRequired,
               (state.followUpNote ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind, reason: "Follow-up note is required")
            }
            guard let firstTransition = context.step.transitions.first else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind, reason: "No transitions declared")
            }
            // Output explicitly identifies the assessment as workflow review, not canonical truth.
            let outputJSON = try WorkflowStepPayloadCodec.encode([
                "kind": "workflowEffectivenessReview",
                "assessment": state.assessment?.rawValue ?? "",
                "note": "Workflow review judgment — not canonical evidence status"
            ])
            let (json, sha) = try makeEnvelope(state: state, stepKind: handledKind)
            return WorkflowStepExecutionResult(
                stateJSON: json, stateSHA256: sha, outputJSON: outputJSON,
                disposition: .advance(.label(firstTransition.label))
            )
        }
    }
}
