//
//  ProfessionalMethodLifecycleEngine.swift
//  Kalsmritikosh
//
//  PM-004 — the generic runtime governing every persistent MethodRun: the closed
//  lifecycle state machine, deterministic validation batches, definition-keyed
//  human-only review gates, definition-conformance + input-role + evidence +
//  validation + review completion gates, and human-authorized reopening (which
//  invalidates stale gate decisions via a content-revision bump without deleting
//  history). It builds MethodLifecyclePlans and applies them through the ONE
//  authoritative writer (MethodRunRepository). It never confirms a Claim, mutates
//  canonical evidence, rewrites a Stage-3 method-result snapshot, or lets a
//  deterministic validator impersonate a human reviewer.
//

import Foundation

public struct ProfessionalMethodLifecycleEngine: Sendable {

    let repository: MethodRunRepository
    let registry: ProfessionalMethodRegistry
    let validators: ProfessionalMethodValidatorRegistry

    public init(
        repository: MethodRunRepository,
        registry: ProfessionalMethodRegistry,
        validators: ProfessionalMethodValidatorRegistry
    ) {
        self.repository = repository
        self.registry = registry
        self.validators = validators
    }

    // MARK: - Simple transitions

    public func start(runID: UUID, actor: MethodLifecycleActor, now: Date) async throws -> MethodRunAggregate {
        let run = try await precheckRun(runID, .start, actor)
        _ = try resolveDefinition(run)
        return try await apply(runID, run.revision, .init(action: .start,
            patch: .init(toStatus: .active), actorKind: actor.kind, actorIdentifier: actor.identifier), now: now)
    }

    public func pause(runID: UUID, actor: MethodLifecycleActor, now: Date) async throws -> MethodRunAggregate {
        let run = try await precheckRun(runID, .pause, actor)
        return try await apply(runID, run.revision, .init(action: .pause,
            patch: .init(toStatus: .paused), actorKind: actor.kind, actorIdentifier: actor.identifier), now: now)
    }

    public func resume(runID: UUID, actor: MethodLifecycleActor, now: Date) async throws -> MethodRunAggregate {
        let run = try await precheckRun(runID, .resume, actor)
        return try await apply(runID, run.revision, .init(action: .resume,
            patch: .init(toStatus: .active), actorKind: actor.kind, actorIdentifier: actor.identifier), now: now)
    }

    public func block(runID: UUID, reason: String, actor: MethodLifecycleActor, now: Date) async throws -> MethodRunAggregate {
        try requireReason(reason)
        let run = try await precheckRun(runID, .block, actor)
        return try await apply(runID, run.revision, .init(action: .block,
            patch: .init(toStatus: .blocked), actorKind: actor.kind, actorIdentifier: actor.identifier, reason: reason), now: now)
    }

    public func unblock(runID: UUID, reason: String, actor: MethodLifecycleActor, now: Date) async throws -> MethodRunAggregate {
        try requireReason(reason)
        let run = try await precheckRun(runID, .unblock, actor)
        return try await apply(runID, run.revision, .init(action: .unblock,
            patch: .init(toStatus: .active), actorKind: actor.kind, actorIdentifier: actor.identifier, reason: reason), now: now)
    }

    public func cancel(runID: UUID, reason: String, actor: MethodLifecycleActor, now: Date) async throws -> MethodRunAggregate {
        try requireReason(reason)
        let run = try await precheckRun(runID, .cancel, actor)
        return try await apply(runID, run.revision, .init(action: .cancel,
            patch: .init(toStatus: .cancelled), actorKind: actor.kind, actorIdentifier: actor.identifier, reason: reason), now: now)
    }

    // MARK: - Human-review request / continue

    public func requestHumanReview(runID: UUID, actor: MethodLifecycleActor, now: Date) async throws -> MethodRunAggregate {
        let run = try await precheckRun(runID, .requestHumanReview, actor)
        let def = try resolveDefinition(run)
        guard !def.requiredReviews.isEmpty else {
            throw ProfessionalMethodLifecycleError.invalidTransition(from: run.status, action: .requestHumanReview)
        }
        return try await apply(runID, run.revision, .init(action: .requestHumanReview,
            patch: .init(toStatus: .waitingForHuman), actorKind: actor.kind, actorIdentifier: actor.identifier), now: now)
    }

    public func continueAfterReview(runID: UUID, actor: MethodLifecycleActor, now: Date) async throws -> MethodRunAggregate {
        try actor.validated()
        guard let aggregate = try await repository.aggregate(runID: runID) else {
            throw ProfessionalMethodLifecycleError.runNotFound(runID)
        }
        let run = aggregate.run
        guard !run.status.isTerminal else { throw ProfessionalMethodLifecycleError.terminalRunImmutable(run.status) }
        guard MethodLifecycleStateMachine.target(from: run.status, action: .continueAfterReview) != nil else {
            throw ProfessionalMethodLifecycleError.invalidTransition(from: run.status, action: .continueAfterReview)
        }
        let def = try resolveDefinition(run)
        try evaluateReviewGate(def, aggregate)          // all required reviews currently accepted
        return try await apply(runID, run.revision, .init(action: .continueAfterReview,
            patch: .init(toStatus: .active), actorKind: actor.kind, actorIdentifier: actor.identifier), now: now)
    }

    // MARK: - Record a human review

    public func recordReview(
        runID: UUID, reviewKey: String, nodeID: UUID?, findingID: UUID?,
        action: MethodReviewAction, comment: String?, actor: MethodLifecycleActor, now: Date
    ) async throws -> MethodRunAggregate {
        guard actor.isHuman else { throw ProfessionalMethodLifecycleError.humanActorRequired }
        try actor.validated()
        guard action != .reopen else {
            throw ProfessionalMethodLifecycleError.malformedReview("reopen is produced only by the lifecycle reopen operation")
        }
        guard let aggregate = try await repository.aggregate(runID: runID) else {
            throw ProfessionalMethodLifecycleError.runNotFound(runID)
        }
        let run = aggregate.run
        guard run.status != .completed, !run.status.isTerminal else {
            throw ProfessionalMethodLifecycleError.terminalRunImmutable(run.status)
        }
        let def = try resolveDefinition(run)
        guard def.requiredReviews.contains(where: { $0.reviewKey == reviewKey }) else {
            throw ProfessionalMethodLifecycleError.unknownReviewKey(reviewKey)
        }
        let review = MethodReview(
            methodRunID: runID, nodeID: nodeID, findingID: findingID,
            reviewKey: reviewKey, reviewedContentRevision: run.contentRevision,
            action: action, actorKind: .human, actorIdentifier: actor.identifier ?? "",
            comment: comment, reviewedAt: now)
        do { try review.validate() }
        catch { throw ProfessionalMethodLifecycleError.malformedReview("\(error)") }
        return try await apply(runID, run.revision, .init(action: .reviewRecorded,
            patch: .init(toStatus: run.status), review: review,
            actorKind: .human, actorIdentifier: actor.identifier), now: now)
    }

    // MARK: - Validation

    public func validate(runID: UUID, actor: MethodLifecycleActor, now: Date) async throws -> MethodRunAggregate {
        try actor.validated()
        guard let aggregate = try await repository.aggregate(runID: runID) else {
            throw ProfessionalMethodLifecycleError.runNotFound(runID)
        }
        let run = aggregate.run
        guard run.status != .draft, !run.status.isTerminal else {
            throw ProfessionalMethodLifecycleError.invalidTransition(from: run.status, action: .validationRecorded)
        }
        let def = try resolveDefinition(run)
        let context = ProfessionalMethodValidationContext(
            definition: def, aggregate: aggregate, runID: runID, workspaceID: run.workspaceID,
            runRevision: run.revision, contentRevision: run.contentRevision)
        let batchID = UUID()
        var batch: [MethodValidationResult] = []
        for validatorID in def.validationIdentifiers {
            guard let validator = validators.validator(id: validatorID) else {
                throw ProfessionalMethodLifecycleError.validatorNotRegistered(validatorID)
            }
            let issues: [ProfessionalMethodValidationIssue]
            do { issues = try await validator.validate(context: context) }
            catch { throw ProfessionalMethodLifecycleError.validatorFailed(id: validatorID, message: "\(error)") }
            guard !issues.isEmpty else { throw ProfessionalMethodLifecycleError.validatorReturnedNoResult(validatorID) }
            for issue in issues {
                guard !issue.code.trimmingCharacters(in: .whitespaces).isEmpty,
                      !issue.message.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw ProfessionalMethodLifecycleError.malformedValidatorResult(validatorID)
                }
                try requireSubjectOwnership(issue.subjectKind, issue.subjectID, aggregate)
                batch.append(MethodValidationResult(
                    methodRunID: runID, validatorID: validator.validatorID, validatorVersion: validator.validatorVersion,
                    severity: issue.severity, code: issue.code, message: issue.message,
                    subjectKind: issue.subjectKind, subjectID: issue.subjectID,
                    validationBatchID: batchID, evaluatedContentRevision: run.contentRevision, createdAt: now))
            }
        }
        return try await apply(runID, run.revision, .init(action: .validationRecorded,
            patch: .init(toStatus: run.status), validationBatch: batch,
            actorKind: actor.kind, actorIdentifier: actor.identifier), now: now)
    }

    // MARK: - Complete

    public func complete(runID: UUID, actor: MethodLifecycleActor, now: Date) async throws -> MethodRunAggregate {
        try actor.validated()
        guard let aggregate = try await repository.aggregate(runID: runID) else {
            throw ProfessionalMethodLifecycleError.runNotFound(runID)
        }
        let run = aggregate.run
        guard !run.status.isTerminal else { throw ProfessionalMethodLifecycleError.terminalRunImmutable(run.status) }
        guard MethodLifecycleStateMachine.target(from: run.status, action: .complete) != nil else {
            throw ProfessionalMethodLifecycleError.invalidTransition(from: run.status, action: .complete)
        }
        let def = try resolveDefinition(run)
        try evaluateConformanceGate(def, aggregate)
        try evaluateInputRoleGate(def, aggregate)
        try evaluateValidationGate(def, aggregate)
        try evaluateReviewGate(def, aggregate)
        return try await apply(runID, run.revision, .init(action: .complete,
            patch: .init(toStatus: .completed, setCompletedAt: true),
            actorKind: actor.kind, actorIdentifier: actor.identifier), now: now)
    }

    // MARK: - Supersede

    public func supersede(
        runID: UUID, successorID: UUID, actor: MethodLifecycleActor, now: Date
    ) async throws -> MethodRunAggregate {
        let run = try await precheckRun(runID, .supersede, actor)
        guard successorID != runID, let successor = try await repository.run(id: successorID) else {
            throw ProfessionalMethodLifecycleError.invalidSuccessor(successorID)
        }
        guard successor.workspaceID == run.workspaceID else {
            throw ProfessionalMethodLifecycleError.successorWorkspaceMismatch(successorID)
        }
        guard successor.methodDefinitionID == run.methodDefinitionID,
              successor.methodDefinitionVersion >= run.methodDefinitionVersion else {
            throw ProfessionalMethodLifecycleError.successorDefinitionMismatch(successorID)
        }
        guard !successor.status.isTerminal else { throw ProfessionalMethodLifecycleError.invalidSuccessor(successorID) }
        return try await apply(runID, run.revision, .init(action: .supersede,
            patch: .init(toStatus: .superseded, supersededByRunID: successorID),
            actorKind: actor.kind, actorIdentifier: actor.identifier), now: now)
    }

    // MARK: - Human reopen of a completed run

    public func reopenCompletedRun(
        runID: UUID, reason: String, actor: MethodLifecycleActor, now: Date
    ) async throws -> MethodRunAggregate {
        guard actor.isHuman else { throw ProfessionalMethodLifecycleError.humanActorRequired }
        try actor.validated()
        try requireReason(reason)
        guard let run = try await repository.run(id: runID) else {
            throw ProfessionalMethodLifecycleError.runNotFound(runID)
        }
        guard run.status == .completed else {
            throw ProfessionalMethodLifecycleError.invalidTransition(from: run.status, action: .reopen)
        }
        // The reopen review is stamped at the NEW content revision, deliberately
        // invalidating the prior required-review acceptances and validation batches.
        let newContentRevision = run.contentRevision + 1
        let reopenReview = MethodReview(
            methodRunID: runID, reviewKey: MethodReview.reopenKey,
            reviewedContentRevision: newContentRevision, action: .reopen,
            actorKind: .human, actorIdentifier: actor.identifier ?? "", comment: reason, reviewedAt: now)
        return try await apply(runID, run.revision, .init(action: .reopen,
            patch: .init(toStatus: .active, contentChanged: true, clearCompletedAt: true),
            review: reopenReview, actorKind: .human, actorIdentifier: actor.identifier, reason: reason), now: now)
    }

    // MARK: - Gates

    func evaluateConformanceGate(_ def: ProfessionalMethodDefinition, _ agg: MethodRunAggregate) throws {
        for node in agg.nodes where !def.allowedNodeKinds.contains(node.nodeKind) {
            throw ProfessionalMethodLifecycleError.unsupportedNodeKind(node.nodeKind.rawValue)
        }
        for edge in agg.edges where !def.allowedEdgeKinds.contains(edge.edgeKind) {
            throw ProfessionalMethodLifecycleError.unsupportedEdgeKind(edge.edgeKind.rawValue)
        }
        for finding in agg.findings where !def.outputContract.allowedFindingKinds.contains(finding.findingKind) {
            throw ProfessionalMethodLifecycleError.unsupportedFindingKind(finding.findingKind.rawValue)
        }
        guard !agg.evidenceLinks.isEmpty else { throw ProfessionalMethodLifecycleError.evidenceRequired }
    }

    func evaluateInputRoleGate(_ def: ProfessionalMethodDefinition, _ agg: MethodRunAggregate) throws {
        for role in def.requiredInputRoles
        where !agg.evidenceLinks.contains(where: { $0.inputRole == role }) {
            throw ProfessionalMethodLifecycleError.requiredInputRoleMissing(role.rawValue)
        }
    }

    func evaluateValidationGate(_ def: ProfessionalMethodDefinition, _ agg: MethodRunAggregate) throws {
        guard !def.validationIdentifiers.isEmpty else { return }
        let currentRev = agg.run.contentRevision
        let atRev = agg.validationResults.filter { $0.evaluatedContentRevision == currentRev }
        guard let latestBatchID = atRev.max(by: { $0.createdAt < $1.createdAt })?.validationBatchID else {
            throw ProfessionalMethodLifecycleError.staleValidationBatch
        }
        let batch = atRev.filter { $0.validationBatchID == latestBatchID }
        if let blocker = batch.first(where: { $0.blocksCompletion }) {
            throw ProfessionalMethodLifecycleError.blockingValidation(code: blocker.code)
        }
        for validatorID in def.validationIdentifiers {
            guard let validator = validators.validator(id: validatorID) else {
                throw ProfessionalMethodLifecycleError.validatorNotRegistered(validatorID)
            }
            let results = batch.filter { $0.validatorID == validatorID }
            guard !results.isEmpty else { throw ProfessionalMethodLifecycleError.staleValidationBatch }
            guard results.allSatisfy({ $0.validatorVersion == validator.validatorVersion }) else {
                throw ProfessionalMethodLifecycleError.staleValidationBatch
            }
        }
    }

    func evaluateReviewGate(_ def: ProfessionalMethodDefinition, _ agg: MethodRunAggregate) throws {
        let currentRev = agg.run.contentRevision
        for required in def.requiredReviews {
            let decisions = agg.reviews.filter {
                $0.reviewKey == required.reviewKey
                    && $0.reviewedContentRevision == currentRev
                    && $0.actorKind == .human
                    && $0.action != .comment
                    && $0.reviewKey != MethodReview.legacyUnkeyedKey
                    && $0.reviewKey != MethodReview.reopenKey
            }.sorted { ($0.reviewedAt, $0.id.uuidString) < ($1.reviewedAt, $1.id.uuidString) }
            guard let latest = decisions.last else {
                throw ProfessionalMethodLifecycleError.requiredReviewMissing(required.reviewKey)
            }
            switch latest.action {
            case .acceptForWorkflow: continue
            case .reject:            throw ProfessionalMethodLifecycleError.reviewRejected(required.reviewKey)
            case .requestRevision:   throw ProfessionalMethodLifecycleError.reviewRevisionRequested(required.reviewKey)
            case .comment, .reopen:  throw ProfessionalMethodLifecycleError.requiredReviewMissing(required.reviewKey)
            }
        }
    }

    // MARK: - Helpers

    private func apply(_ runID: UUID, _ expectedRevision: Int, _ plan: MethodLifecyclePlan, now: Date) async throws -> MethodRunAggregate {
        do {
            return try await repository.applyLifecyclePlan(runID: runID, expectedRevision: expectedRevision, plan: plan, now: now)
        } catch let error as MethodPersistenceError {
            switch error {
            case .revisionConflict(let id, let expected):
                throw ProfessionalMethodLifecycleError.revisionConflict(runID: id, expected: expected)
            case .runNotFound(let id):
                throw ProfessionalMethodLifecycleError.runNotFound(id)
            default:
                throw error
            }
        }
    }

    private func precheckRun(_ runID: UUID, _ action: MethodLifecycleUserAction, _ actor: MethodLifecycleActor) async throws -> MethodRun {
        try actor.validated()
        guard let run = try await repository.run(id: runID) else { throw ProfessionalMethodLifecycleError.runNotFound(runID) }
        guard !run.status.isTerminal else { throw ProfessionalMethodLifecycleError.terminalRunImmutable(run.status) }
        guard MethodLifecycleStateMachine.target(from: run.status, action: action) != nil else {
            throw ProfessionalMethodLifecycleError.invalidTransition(from: run.status, action: action.eventAction)
        }
        return run
    }

    private func resolveDefinition(_ run: MethodRun) throws -> ProfessionalMethodDefinition {
        if let def = registry.definition(id: run.methodDefinitionID, version: run.methodDefinitionVersion) { return def }
        if registry.latest(id: run.methodDefinitionID) == nil {
            throw ProfessionalMethodLifecycleError.definitionNotFound(run.methodDefinitionID.rawValue)
        }
        throw ProfessionalMethodLifecycleError.definitionVersionNotFound(
            id: run.methodDefinitionID.rawValue, version: run.methodDefinitionVersion)
    }

    private func requireReason(_ reason: String) throws {
        guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProfessionalMethodLifecycleError.invalidLifecycleReason
        }
    }

    private func requireSubjectOwnership(
        _ kind: MethodValidationSubjectKind, _ subjectID: UUID?, _ agg: MethodRunAggregate
    ) throws {
        switch kind {
        case .run:
            if let id = subjectID, id != agg.run.id {
                throw ProfessionalMethodLifecycleError.malformedValidatorResult("run subject id must be the run id")
            }
        case .node, .edge, .assumption, .finding, .evidenceLink:
            guard let id = subjectID else {
                throw ProfessionalMethodLifecycleError.malformedValidatorResult("\(kind.rawValue) subject requires an id")
            }
            let owned: Bool
            switch kind {
            case .node:         owned = agg.nodes.contains { $0.id == id }
            case .edge:         owned = agg.edges.contains { $0.id == id }
            case .assumption:   owned = agg.assumptions.contains { $0.id == id }
            case .finding:      owned = agg.findings.contains { $0.id == id }
            case .evidenceLink: owned = agg.evidenceLinks.contains { $0.id == id }
            case .run:          owned = true
            }
            guard owned else { throw ProfessionalMethodLifecycleError.malformedValidatorResult("subject \(id) not in run") }
        }
    }
}
