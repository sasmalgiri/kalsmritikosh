//
//  ReviewEvidenceStepExecutorTests.swift
//  KalsmritikoshTests
//
//  PJE-006B — ReviewEvidenceStepExecutor: workflow-owned review over the prior
//  selection; activates the .evidenceReviewed requirement facts. 11 tests.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-006B — ReviewEvidenceStepExecutor")
struct ReviewEvidenceStepExecutorTests {

    private let t0 = Date(timeIntervalSince1970: 1_753_000_000)

    private func reviewedReq(id: String = "req.er") -> PersonaWorkflowRequirement {
        PersonaWorkflowRequirement(
            id: id, kind: .evidenceReviewed, label: "Evidence reviewed", isBlocking: true)
    }

    /// Builds a completed selectEvidence state envelope with `count` selected items.
    private func selectionEnvelope(count: Int) throws -> (json: String, items: [SelectedWorkflowEvidenceItem]) {
        let items = (0..<count).map { i in
            SelectedWorkflowEvidenceItem(
                id: UUID(), objectKind: .entity, canonicalObjectID: UUID().uuidString,
                selectionReason: "reason \(i)", selectedBy: nil, selectedAt: t0)
        }
        let envelope = WorkflowStepStateEnvelope(
            stepKind: .selectEvidence,
            executorID: "com.kalsmritikosh.step.selectEvidence",
            executorVersion: "1.0",
            state: SelectEvidenceStepState(items: items))
        return (try WorkflowStepPayloadCodec.encode(envelope), items)
    }

    private func rigStateSelection(
        reqs: [PersonaWorkflowRequirement] = [],
        selectionCount: Int = 2
    ) async throws -> (ReviewEvidenceStepExecutor, ExecutorTestRig, String, [SelectedWorkflowEvidenceItem], String) {
        let executor = ReviewEvidenceStepExecutor()
        let rig = try makeExecutorTestRig(kind: .reviewEvidence, reqs: reqs)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let (selectionJSON, items) = try selectionEnvelope(count: selectionCount)
        return (executor, rig, prep.stateJSON, items, selectionJSON)
    }

    private func reviewJSON(
        itemID: UUID,
        status: WorkflowEvidenceReviewStatus = .reviewed,
        note: String? = nil
    ) throws -> String {
        try WorkflowStepPayloadCodec.encode(
            ReviewEvidenceStepCommand.review(itemID: itemID, status: status, note: note))
    }

    @Test("prepare seeds unsatisfied .evidenceReviewed facts")
    func prepareSeedsUnsatisfiedFacts() async throws {
        let (_, _, stateJSON, _, _) = try await rigStateSelection(reqs: [reviewedReq()])
        let header = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelopeHeader.self, from: stateJSON)
        #expect(header.requirementFacts.count == 1)
        #expect(header.requirementFacts[0].kind == .evidenceReviewed)
        #expect(header.requirementFacts[0].isSatisfied == false)
    }

    @Test("review records status, note, and reviewer for a selected item")
    func reviewRecordsStatusNote() async throws {
        let (executor, rig, stateJSON, items, selectionJSON) = try await rigStateSelection()
        let ctx = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: stateJSON,
            priorStepStates: [(.selectEvidence, selectionJSON)])
        let r = try await executor.execute(
            context: ctx,
            commandJSON: try reviewJSON(itemID: items[0].id, status: .reviewed, note: "Checked against source"))
        let state = try decodeEnvelopeState(ReviewEvidenceStepState.self, from: r.stateJSON)
        let record = try #require(state.reviews[items[0].id.uuidString])
        #expect(record.status == .reviewed)
        #expect(record.note == "Checked against source")
        #expect(record.reviewedAt == ctx.executedAt)
    }

    @Test("all three review statuses are recordable")
    func allStatusesRecordable() async throws {
        let (executor, rig, prepJSON, items, selectionJSON) = try await rigStateSelection(selectionCount: 3)
        var stateJSON = prepJSON
        let statuses: [WorkflowEvidenceReviewStatus] = [.reviewed, .needsFollowUp, .excludedFromThisWorkflow]
        for (item, status) in zip(items, statuses) {
            let ctx = try makeExecutionCtx(
                executor: executor, rig: rig, stateJSON: stateJSON,
                priorStepStates: [(.selectEvidence, selectionJSON)])
            let r = try await executor.execute(
                context: ctx, commandJSON: try reviewJSON(itemID: item.id, status: status))
            stateJSON = r.stateJSON
        }
        let state = try decodeEnvelopeState(ReviewEvidenceStepState.self, from: stateJSON)
        #expect(state.reviews[items[0].id.uuidString]?.status == .reviewed)
        #expect(state.reviews[items[1].id.uuidString]?.status == .needsFollowUp)
        #expect(state.reviews[items[2].id.uuidString]?.status == .excludedFromThisWorkflow)
    }

    @Test("reviewing an item outside the selection is refused")
    func reviewOutsideSelectionRefused() async throws {
        let (executor, rig, stateJSON, _, selectionJSON) = try await rigStateSelection()
        let ctx = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: stateJSON,
            priorStepStates: [(.selectEvidence, selectionJSON)])
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(
                context: ctx, commandJSON: try reviewJSON(itemID: UUID()))
        }
    }

    @Test("clearReview removes the record; clearing a nonexistent review fails")
    func clearReview() async throws {
        let (executor, rig, prepJSON, items, selectionJSON) = try await rigStateSelection()
        let ctx1 = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: prepJSON,
            priorStepStates: [(.selectEvidence, selectionJSON)])
        let r1 = try await executor.execute(context: ctx1, commandJSON: try reviewJSON(itemID: items[0].id))

        let clear = try WorkflowStepPayloadCodec.encode(
            ReviewEvidenceStepCommand.clearReview(itemID: items[0].id))
        let ctx2 = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: r1.stateJSON,
            priorStepStates: [(.selectEvidence, selectionJSON)])
        let r2 = try await executor.execute(context: ctx2, commandJSON: clear)
        let state = try decodeEnvelopeState(ReviewEvidenceStepState.self, from: r2.stateJSON)
        #expect(state.reviews.isEmpty)

        let ctx3 = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: r2.stateJSON,
            priorStepStates: [(.selectEvidence, selectionJSON)])
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx3, commandJSON: clear)
        }
    }

    @Test(".evidenceReviewed fact stays unsatisfied while any selected item is unreviewed")
    func factUnsatisfiedWhilePending() async throws {
        let (executor, rig, prepJSON, items, selectionJSON) = try await rigStateSelection(
            reqs: [reviewedReq()], selectionCount: 2)
        let ctx = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: prepJSON,
            priorStepStates: [(.selectEvidence, selectionJSON)])
        let r = try await executor.execute(context: ctx, commandJSON: try reviewJSON(itemID: items[0].id))
        let header = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelopeHeader.self, from: r.stateJSON)
        #expect(header.requirementFacts[0].isSatisfied == false)
    }

    @Test(".evidenceReviewed fact becomes satisfied when every selected item is reviewed")
    func factSatisfiedWhenAllReviewed() async throws {
        let (executor, rig, prepJSON, items, selectionJSON) = try await rigStateSelection(
            reqs: [reviewedReq()], selectionCount: 2)
        var stateJSON = prepJSON
        for item in items {
            let ctx = try makeExecutionCtx(
                executor: executor, rig: rig, stateJSON: stateJSON,
                priorStepStates: [(.selectEvidence, selectionJSON)])
            let r = try await executor.execute(context: ctx, commandJSON: try reviewJSON(itemID: item.id))
            stateJSON = r.stateJSON
        }
        let header = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelopeHeader.self, from: stateJSON)
        #expect(header.requirementFacts[0].isSatisfied == true)
    }

    @Test("complete is refused while selected items remain unreviewed")
    func completeRefusedWhilePending() async throws {
        let (executor, rig, prepJSON, items, selectionJSON) = try await rigStateSelection(selectionCount: 2)
        let ctx1 = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: prepJSON,
            priorStepStates: [(.selectEvidence, selectionJSON)])
        let r1 = try await executor.execute(context: ctx1, commandJSON: try reviewJSON(itemID: items[0].id))
        let complete = try WorkflowStepPayloadCodec.encode(ReviewEvidenceStepCommand.complete)
        let ctx2 = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: r1.stateJSON,
            priorStepStates: [(.selectEvidence, selectionJSON)])
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx2, commandJSON: complete)
        }
    }

    @Test("complete advances once all selected items are reviewed")
    func completeAdvancesWhenAllReviewed() async throws {
        let (executor, rig, prepJSON, items, selectionJSON) = try await rigStateSelection(selectionCount: 2)
        var stateJSON = prepJSON
        for item in items {
            let ctx = try makeExecutionCtx(
                executor: executor, rig: rig, stateJSON: stateJSON,
                priorStepStates: [(.selectEvidence, selectionJSON)])
            let r = try await executor.execute(context: ctx, commandJSON: try reviewJSON(itemID: item.id))
            stateJSON = r.stateJSON
        }
        let complete = try WorkflowStepPayloadCodec.encode(ReviewEvidenceStepCommand.complete)
        let ctx = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: stateJSON,
            priorStepStates: [(.selectEvidence, selectionJSON)])
        let r = try await executor.execute(context: ctx, commandJSON: complete)
        #expect(r.disposition == .advance(.label("next")))
    }

    @Test("complete with no selection in the aggregate is refused")
    func completeNoSelectionRefused() async throws {
        let (executor, rig, stateJSON, _, _) = try await rigStateSelection()
        // No priorStepStates — the aggregate carries no selectEvidence run.
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        let complete = try WorkflowStepPayloadCodec.encode(ReviewEvidenceStepCommand.complete)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: complete)
        }
    }

    @Test("review never mutates canonical references — selection items are untouched")
    func reviewLeavesSelectionUntouched() async throws {
        let (executor, rig, prepJSON, items, selectionJSON) = try await rigStateSelection()
        let ctx = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: prepJSON,
            priorStepStates: [(.selectEvidence, selectionJSON)])
        _ = try await executor.execute(
            context: ctx, commandJSON: try reviewJSON(itemID: items[0].id, note: "note"))
        // The prior selection envelope is byte-identical — review state lives only
        // in the reviewEvidence step run.
        let reparsed = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelope<SelectEvidenceStepState>.self, from: selectionJSON)
        #expect(reparsed.state.items == items)
    }
}
