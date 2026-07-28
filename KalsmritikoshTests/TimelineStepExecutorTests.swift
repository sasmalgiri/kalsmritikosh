//
//  TimelineStepExecutorTests.swift
//  KalsmritikoshTests
//
//  PJE-006B — TimelineStepExecutor: canonical-referenced entries with explicit
//  precision, undated and conflicting-date labelling, scenario overlays. 12 tests.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-006B — TimelineStepExecutor")
struct TimelineStepExecutorTests {

    private func rigAndState(
        gate: FixtureEvidenceGate = FixtureEvidenceGate()
    ) async throws -> (TimelineStepExecutor, ExecutorTestRig, String) {
        let executor = TimelineStepExecutor(gate: gate)
        let rig = try makeExecutorTestRig(kind: .timeline)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        return (executor, rig, prep.stateJSON)
    }

    private func addEntryJSON(
        kind: WorkflowEvidenceObjectKind = .event,
        id: UUID = UUID(),
        label: String = "Filing received",
        date: String? = "2025-03-11T00:00:00Z",
        precision: DatePrecision? = .day,
        uncertainty: String? = nil,
        conflicts: [WorkflowTimelineDateCandidate] = []
    ) throws -> String {
        try WorkflowStepPayloadCodec.encode(TimelineStepCommand.addEntry(
            objectKind: kind, canonicalObjectID: id.uuidString, label: label,
            dateISO8601: date, datePrecision: precision,
            uncertaintyNote: uncertainty, conflictingDates: conflicts))
    }

    @Test("addEntry preserves the exact canonical ID, date, and precision")
    func addEntryPreservesIDs() async throws {
        let (executor, rig, stateJSON) = try await rigAndState()
        let objectID = UUID()
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        let r = try await executor.execute(
            context: ctx,
            commandJSON: try addEntryJSON(kind: .claim, id: objectID, precision: .day))
        let state = try decodeEnvelopeState(TimelineStepState.self, from: r.stateJSON)
        #expect(state.entries.count == 1)
        #expect(state.entries[0].objectKind == .claim)
        #expect(state.entries[0].canonicalObjectID == objectID.uuidString)
        #expect(state.entries[0].dateISO8601 == "2025-03-11T00:00:00Z")
        #expect(state.entries[0].datePrecision == .day)
        #expect(state.entries[0].isUndated == false)
        #expect(state.entries[0].hasDateConflict == false)
    }

    @Test("undated entry is explicitly labelled isUndated")
    func undatedEntryLabelled() async throws {
        let (executor, rig, stateJSON) = try await rigAndState()
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        let r = try await executor.execute(
            context: ctx,
            commandJSON: try addEntryJSON(date: nil, precision: nil, uncertainty: "No date in source"))
        let state = try decodeEnvelopeState(TimelineStepState.self, from: r.stateJSON)
        #expect(state.entries[0].isUndated == true)
        #expect(state.entries[0].dateISO8601 == nil)
        #expect(state.entries[0].uncertaintyNote == "No date in source")
    }

    @Test("a dated entry without precision is rejected — precision travels with the date")
    func dateWithoutPrecisionRejected() async throws {
        let (executor, rig, stateJSON) = try await rigAndState()
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(
                context: ctx, commandJSON: try addEntryJSON(precision: nil))
        }
    }

    @Test("precision without a date is rejected")
    func precisionWithoutDateRejected() async throws {
        let (executor, rig, stateJSON) = try await rigAndState()
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(
                context: ctx, commandJSON: try addEntryJSON(date: nil, precision: .month))
        }
    }

    @Test("conflicting-date entry keeps all candidates and no resolved date")
    func conflictEntryKeepsCandidates() async throws {
        let (executor, rig, stateJSON) = try await rigAndState()
        let conflicts = [
            WorkflowTimelineDateCandidate(dateISO8601: "2025-03-11T00:00:00Z", precision: .day, sourceNote: "Email header"),
            WorkflowTimelineDateCandidate(dateISO8601: "2025-04-02T00:00:00Z", precision: .day, sourceNote: "PDF stamp")
        ]
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        let r = try await executor.execute(
            context: ctx,
            commandJSON: try addEntryJSON(date: nil, precision: nil, conflicts: conflicts))
        let state = try decodeEnvelopeState(TimelineStepState.self, from: r.stateJSON)
        #expect(state.entries[0].hasDateConflict == true)
        #expect(state.entries[0].isUndated == false)
        #expect(state.entries[0].dateISO8601 == nil)
        #expect(state.entries[0].conflictingDates == conflicts)
    }

    @Test("a single conflict candidate is not a conflict — rejected")
    func singleCandidateRejected() async throws {
        let (executor, rig, stateJSON) = try await rigAndState()
        let one = [WorkflowTimelineDateCandidate(
            dateISO8601: "2025-03-11T00:00:00Z", precision: .day, sourceNote: "x")]
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(
                context: ctx, commandJSON: try addEntryJSON(date: nil, precision: nil, conflicts: one))
        }
    }

    @Test("a conflicting-date entry with a resolved date is rejected — no silent resolution")
    func conflictWithResolvedDateRejected() async throws {
        let (executor, rig, stateJSON) = try await rigAndState()
        let conflicts = [
            WorkflowTimelineDateCandidate(dateISO8601: "2025-03-11T00:00:00Z", precision: .day, sourceNote: "a"),
            WorkflowTimelineDateCandidate(dateISO8601: "2025-04-02T00:00:00Z", precision: .day, sourceNote: "b")
        ]
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(
                context: ctx, commandJSON: try addEntryJSON(conflicts: conflicts))
        }
    }

    @Test("gate denial blocks the entry")
    func gateDenialBlocksEntry() async throws {
        let deniedID = UUID()
        let (executor, rig, stateJSON) = try await rigAndState(
            gate: FixtureEvidenceGate(deniedIDs: [deniedID]))
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: try addEntryJSON(id: deniedID))
        }
    }

    @Test("overlay must reference existing entries, without duplicates")
    func overlayValidation() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let ctx1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prepJSON)
        let r1 = try await executor.execute(context: ctx1, commandJSON: try addEntryJSON())
        let state1 = try decodeEnvelopeState(TimelineStepState.self, from: r1.stateJSON)
        let entryID = state1.entries[0].id

        // Unknown entry ID → refused
        let badOverlay = try WorkflowStepPayloadCodec.encode(
            TimelineStepCommand.addOverlay(name: "Alt", orderedEntryIDs: [UUID()]))
        let ctx2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx2, commandJSON: badOverlay)
        }

        // Duplicate IDs → refused
        let dupOverlay = try WorkflowStepPayloadCodec.encode(
            TimelineStepCommand.addOverlay(name: "Dup", orderedEntryIDs: [entryID, entryID]))
        let ctx3 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx3, commandJSON: dupOverlay)
        }
    }

    @Test("overlays are proposal-layer orderings, added and removed without touching entries")
    func overlayAddRemove() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let ctx1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prepJSON)
        let r1 = try await executor.execute(context: ctx1, commandJSON: try addEntryJSON())
        let ctx2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        let r2 = try await executor.execute(context: ctx2, commandJSON: try addEntryJSON())
        let state2 = try decodeEnvelopeState(TimelineStepState.self, from: r2.stateJSON)
        let ids = state2.entries.map(\.id)

        let overlay = try WorkflowStepPayloadCodec.encode(
            TimelineStepCommand.addOverlay(name: "Reversed", orderedEntryIDs: ids.reversed()))
        let ctx3 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r2.stateJSON)
        let r3 = try await executor.execute(context: ctx3, commandJSON: overlay)
        let state3 = try decodeEnvelopeState(TimelineStepState.self, from: r3.stateJSON)
        #expect(state3.overlays.count == 1)
        #expect(state3.overlays[0].orderedEntryIDs == ids.reversed())
        #expect(state3.entries.map(\.id) == ids, "Overlay must not reorder the entries themselves")

        let remove = try WorkflowStepPayloadCodec.encode(
            TimelineStepCommand.removeOverlay(overlayID: state3.overlays[0].id))
        let ctx4 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r3.stateJSON)
        let r4 = try await executor.execute(context: ctx4, commandJSON: remove)
        let state4 = try decodeEnvelopeState(TimelineStepState.self, from: r4.stateJSON)
        #expect(state4.overlays.isEmpty)
        #expect(state4.entries.count == 2)
    }

    @Test("removing an entry drops overlays that referenced it")
    func removeEntryDropsReferencingOverlays() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let ctx1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prepJSON)
        let r1 = try await executor.execute(context: ctx1, commandJSON: try addEntryJSON())
        let state1 = try decodeEnvelopeState(TimelineStepState.self, from: r1.stateJSON)
        let entryID = state1.entries[0].id

        let overlay = try WorkflowStepPayloadCodec.encode(
            TimelineStepCommand.addOverlay(name: "Only", orderedEntryIDs: [entryID]))
        let ctx2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        let r2 = try await executor.execute(context: ctx2, commandJSON: overlay)

        let remove = try WorkflowStepPayloadCodec.encode(
            TimelineStepCommand.removeEntry(entryID: entryID))
        let ctx3 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r2.stateJSON)
        let r3 = try await executor.execute(context: ctx3, commandJSON: remove)
        let state3 = try decodeEnvelopeState(TimelineStepState.self, from: r3.stateJSON)
        #expect(state3.entries.isEmpty)
        #expect(state3.overlays.isEmpty)
    }

    @Test("complete requires at least one entry, then advances")
    func completeRequiresEntry() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let complete = try WorkflowStepPayloadCodec.encode(TimelineStepCommand.complete)
        let ctx1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prepJSON)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx1, commandJSON: complete)
        }
        let ctx2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prepJSON)
        let r1 = try await executor.execute(context: ctx2, commandJSON: try addEntryJSON())
        let ctx3 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        let r2 = try await executor.execute(context: ctx3, commandJSON: complete)
        #expect(r2.disposition == .advance(.label("next")))
    }
}
