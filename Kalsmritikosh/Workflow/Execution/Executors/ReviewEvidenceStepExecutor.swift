//
//  ReviewEvidenceStepExecutor.swift
//  Kalsmritikosh
//
//  PJE-006B — Evidence and Analytical Step Executors.
//  Handles the `reviewEvidence` step kind.
//
//  Reviews the canonical references selected by the run's prior selectEvidence step.
//  Review progress and notes are WORKFLOW-OWNED state: canonical evidence status,
//  source independence, and Claims are never touched, and a reviewer note is never
//  converted into a Claim.
//
//  Produces WorkflowStepRequirementFact entries for `.evidenceReviewed` requirements —
//  this activates the requirement kind that PJE-005 deferred.
//  Commands: review, clearReview, complete.
//

import Foundation

// MARK: - Review status

/// Workflow-owned review disposition for one selected item. Closed vocabulary.
public enum WorkflowEvidenceReviewStatus: String, Codable, Sendable, CaseIterable, Equatable {
    case reviewed
    case needsFollowUp
    case excludedFromThisWorkflow
}

// MARK: - Review record

public nonisolated struct WorkflowEvidenceReviewRecord: Codable, Sendable, Equatable {
    public let itemID: UUID
    public let status: WorkflowEvidenceReviewStatus
    public let note: String?
    public let reviewedBy: String?
    public let reviewedAt: Date

    public nonisolated init(
        itemID: UUID,
        status: WorkflowEvidenceReviewStatus,
        note: String?,
        reviewedBy: String?,
        reviewedAt: Date
    ) {
        self.itemID = itemID
        self.status = status
        self.note = note
        self.reviewedBy = reviewedBy
        self.reviewedAt = reviewedAt
    }
}

// MARK: - State

public nonisolated struct ReviewEvidenceStepState: Codable, Sendable {
    /// Keyed by selected item UUID string (JSON dictionary keys must be strings).
    public var reviews: [String: WorkflowEvidenceReviewRecord]

    public nonisolated init(reviews: [String: WorkflowEvidenceReviewRecord] = [:]) {
        self.reviews = reviews
    }
}

// MARK: - Command

public enum ReviewEvidenceStepCommand: Sendable, Equatable {
    case review(itemID: UUID, status: WorkflowEvidenceReviewStatus, note: String?)
    case clearReview(itemID: UUID)
    case complete
}

extension ReviewEvidenceStepCommand: Codable {
    private enum CodingKeys: String, CodingKey { case type, itemID, status, note }

    public nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "review":
            self = .review(
                itemID: try c.decode(UUID.self, forKey: .itemID),
                status: try c.decode(WorkflowEvidenceReviewStatus.self, forKey: .status),
                note: try c.decodeIfPresent(String.self, forKey: .note)
            )
        case "clearReview":
            self = .clearReview(itemID: try c.decode(UUID.self, forKey: .itemID))
        case "complete":
            self = .complete
        default:
            throw WorkflowStepExecutionError.malformedCommandJSON
        }
    }

    public nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .review(let itemID, let status, let note):
            try c.encode("review", forKey: .type)
            try c.encode(itemID, forKey: .itemID)
            try c.encode(status, forKey: .status)
            if let note = note { try c.encode(note, forKey: .note) }
        case .clearReview(let itemID):
            try c.encode("clearReview", forKey: .type)
            try c.encode(itemID, forKey: .itemID)
        case .complete:
            try c.encode("complete", forKey: .type)
        }
    }
}

// MARK: - Executor

public nonisolated struct ReviewEvidenceStepExecutor: WorkflowStepExecutor {

    public nonisolated let executorID = WorkflowStepExecutorID(
        rawValue: "com.kalsmritikosh.step.reviewEvidence"
    )
    public nonisolated let executorVersion = WorkflowStepExecutorVersion(rawValue: "1.0")
    public nonisolated let handledKind: WorkflowStepKind = .reviewEvidence

    public nonisolated init() {}

    public func prepare(
        context: WorkflowStepPreparationContext
    ) async throws -> WorkflowStepPreparationResult {
        guard context.step.kind == handledKind else {
            throw WorkflowStepExecutionError.executorKindMismatch(
                executor: executorID, expected: handledKind, actual: context.step.kind
            )
        }
        // Selection is not visible at prepare time (no aggregate) — facts start unsatisfied.
        let reviewReqs = context.step.requirements.filter { $0.kind == .evidenceReviewed }
        let initialFacts = reviewReqs.map { req in
            WorkflowStepRequirementFact(
                requirementID: req.id, kind: .evidenceReviewed, isSatisfied: false,
                detail: "No evidence reviewed yet"
            )
        }
        let (json, sha) = try makeEnvelope(
            state: ReviewEvidenceStepState(),
            stepKind: handledKind,
            requirementFacts: initialFacts
        )
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
        var state = try decodeCurrentState(ReviewEvidenceStepState.self, from: context.stepRun)
        let selection = Self.selectedItems(in: context.aggregate)
        let command: ReviewEvidenceStepCommand
        do {
            command = try WorkflowStepPayloadCodec.decode(ReviewEvidenceStepCommand.self, from: commandJSON)
        } catch {
            throw WorkflowStepExecutionError.malformedCommandJSON
        }

        func save() throws -> WorkflowStepExecutionResult {
            let facts = Self.buildFacts(state: state, selection: selection, step: context.step)
            let (json, sha) = try makeEnvelope(
                state: state, stepKind: handledKind, requirementFacts: facts
            )
            return WorkflowStepExecutionResult(stateJSON: json, stateSHA256: sha, disposition: .remainActive)
        }

        switch command {
        case .review(let itemID, let status, let note):
            guard selection.contains(where: { $0.id == itemID }) else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "itemID", reason: "Item is not part of this run's evidence selection"
                )
            }
            state.reviews[itemID.uuidString] = WorkflowEvidenceReviewRecord(
                itemID: itemID,
                status: status,
                note: note,
                reviewedBy: context.actor.identifier,
                reviewedAt: context.executedAt
            )
            return try save()

        case .clearReview(let itemID):
            guard state.reviews.removeValue(forKey: itemID.uuidString) != nil else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "itemID", reason: "No review recorded for this item"
                )
            }
            return try save()

        case .complete:
            guard !selection.isEmpty else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind, reason: "No evidence selection found to review"
                )
            }
            let unreviewed = selection.filter { state.reviews[$0.id.uuidString] == nil }
            guard unreviewed.isEmpty else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind,
                    reason: "\(unreviewed.count) selected item(s) not yet reviewed"
                )
            }
            guard let firstTransition = context.step.transitions.first else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind, reason: "No transitions declared"
                )
            }
            let facts = Self.buildFacts(state: state, selection: selection, step: context.step)
            let (json, sha) = try makeEnvelope(
                state: state, stepKind: handledKind, requirementFacts: facts
            )
            return WorkflowStepExecutionResult(
                stateJSON: json, stateSHA256: sha,
                disposition: .advance(.label(firstTransition.label))
            )
        }
    }

    // MARK: - Selection discovery

    /// The most recent selectEvidence step run's selection, decoded from the aggregate.
    /// Deterministic: highest sequence wins. Returns [] when no selection state exists.
    static nonisolated func selectedItems(
        in aggregate: ReopenedWorkflowRun
    ) -> [SelectedWorkflowEvidenceItem] {
        let candidates = aggregate.stepRuns
            .filter { $0.stepKind == .selectEvidence }
            .sorted { $0.sequence > $1.sequence }
        for stepRun in candidates {
            guard
                let header = try? WorkflowStepPayloadCodec.decode(
                    WorkflowStepStateEnvelopeHeader.self, from: stepRun.stateJSON
                ),
                header.stepKind == .selectEvidence,
                let envelope = try? WorkflowStepPayloadCodec.decode(
                    WorkflowStepStateEnvelope<SelectEvidenceStepState>.self,
                    from: stepRun.stateJSON
                )
            else { continue }
            return envelope.state.items
        }
        return []
    }

    // MARK: - Requirement facts

    /// One fact per `.evidenceReviewed` requirement: satisfied only when a non-empty
    /// selection exists AND every selected item carries a review record.
    private static nonisolated func buildFacts(
        state: ReviewEvidenceStepState,
        selection: [SelectedWorkflowEvidenceItem],
        step: PersonaWorkflowStepDefinition
    ) -> [WorkflowStepRequirementFact] {
        step.requirements
            .filter { $0.kind == .evidenceReviewed }
            .map { req in
                guard !selection.isEmpty else {
                    return WorkflowStepRequirementFact(
                        requirementID: req.id, kind: .evidenceReviewed, isSatisfied: false,
                        detail: "No evidence selection found"
                    )
                }
                let unreviewed = selection.filter { state.reviews[$0.id.uuidString] == nil }
                if unreviewed.isEmpty {
                    return WorkflowStepRequirementFact(
                        requirementID: req.id, kind: .evidenceReviewed, isSatisfied: true
                    )
                }
                return WorkflowStepRequirementFact(
                    requirementID: req.id, kind: .evidenceReviewed, isSatisfied: false,
                    detail: "\(unreviewed.count) selected item(s) not yet reviewed"
                )
            }
    }
}
