//
//  SourceReadinessRepositoryTests.swift
//  KalsmritikoshTests
//
//  USF-002 — the authoritative readiness writer: exact bootstrap, optimistic CAS, atomic
//  multi-dimension plans, the closed transition rules, append-only contiguous events,
//  invalidation, exact close/reopen reconstruction, source-version isolation, and fail-closed
//  writes. Callers move individual dimensions; the completion state is derived, never set.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("USF-002 — readiness repository", .serialized)
struct SourceReadinessRepositoryTests {

    private func rigWithVersion(type: String = "txt", preservation: String = "referenceRecorded")
    async throws -> (rig: USF002Rig, id: UUID) {
        let rig = try await USF002Fixtures.makeRig()
        let id = try await USF002Fixtures.seedVersion(rig, type: type, preservation: preservation)
        _ = try await rig.repo.bootstrap(sourceVersionID: id, detectedType: SourceType(rawValue: type) ?? .txt,
                                         preservationStatus: SourcePreservationStatus(rawValue: preservation) ?? .referenceRecorded,
                                         at: USF002Fixtures.t0)
        return (rig, id)
    }

    @Test("Bootstrap creates one aggregate, ten dimensions and ten initialize events")
    func exactBootstrap() async throws {
        let (rig, id) = try await rigWithVersion()
        #expect(try await rig.db.query("SELECT COUNT(*) FROM source_readiness_aggregates WHERE source_version_id = ?;", [.uuid(id)]).first?.int(0) == 1)
        #expect(try await rig.db.query("SELECT COUNT(*) FROM source_readiness_dimensions WHERE source_version_id = ?;", [.uuid(id)]).first?.int(0) == 10)
        #expect(try await rig.inspector.eventCount(sourceVersionID: id) == 10)
        let snap = try await rig.repo.snapshot(sourceVersionID: id)
        #expect(snap.dimensions.count == 10)
        #expect(snap.aggregateRevision == 1)
    }

    @Test("Bootstrapping twice is rejected")
    func duplicateBootstrapRejected() async throws {
        let (rig, id) = try await rigWithVersion()
        await #expect(throws: SourceReadinessError.self) {
            _ = try await rig.repo.bootstrap(sourceVersionID: id, detectedType: .txt, preservationStatus: .referenceRecorded, at: USF002Fixtures.t0)
        }
    }

    @Test("A plan applied at the expected revision succeeds and bumps the aggregate revision")
    func casSuccess() async throws {
        let (rig, id) = try await rigWithVersion()
        let snap = try await rig.repo.apply(USF002Fixtures.plan(id, expectedRevision: 1,
            [USF002Fixtures.update(.textExtraction, .running, action: .begin)]))
        #expect(snap.aggregateRevision == 2)
        #expect(snap.dimension(.textExtraction)?.state == .running)
    }

    @Test("A plan at the wrong revision conflicts and writes nothing")
    func casConflict() async throws {
        let (rig, id) = try await rigWithVersion()
        await #expect(throws: SourceReadinessError.self) {
            _ = try await rig.repo.apply(USF002Fixtures.plan(id, expectedRevision: 99,
                [USF002Fixtures.update(.textExtraction, .running, action: .begin)]))
        }
        let snap = try await rig.repo.snapshot(sourceVersionID: id)
        #expect(snap.aggregateRevision == 1)
        #expect(snap.dimension(.textExtraction)?.state == .notStarted)
    }

    @Test("A multi-dimension plan is one atomic revision with contiguous events")
    func atomicBatch() async throws {
        let (rig, id) = try await rigWithVersion()
        _ = try await rig.repo.apply(USF002Fixtures.plan(id, expectedRevision: 1, [
            USF002Fixtures.update(.textExtraction, .ready, action: .satisfy, c: 5, t: 5),
            USF002Fixtures.update(.indexing, .ready, action: .satisfy, c: 5, t: 5),
            USF002Fixtures.update(.basicQuestionAnswering, .partial, action: .partiallySatisfy, c: 1, t: 5),
        ]))
        let snap = try await rig.repo.snapshot(sourceVersionID: id)
        #expect(snap.aggregateRevision == 2)                                   // ONE bump for the batch
        #expect(try await rig.inspector.eventCount(sourceVersionID: id) == 13) // 10 init + 3
        let events = try await rig.inspector.events(sourceVersionID: id)
        #expect(events.map(\.sequence) == Array(0..<13))                       // contiguous
    }

    @Test("A duplicate dimension in one plan is rejected")
    func duplicateDimensionRejected() async throws {
        let (rig, id) = try await rigWithVersion()
        await #expect(throws: SourceReadinessError.self) {
            _ = try await rig.repo.apply(USF002Fixtures.plan(id, expectedRevision: 1, [
                USF002Fixtures.update(.textExtraction, .running, action: .begin),
                USF002Fixtures.update(.textExtraction, .ready, action: .satisfy),
            ]))
        }
    }

    @Test("Representative legal transitions all succeed")
    func legalTransitions() async throws {
        let (rig, id) = try await rigWithVersion()
        // notStarted → running → partial → ready
        _ = try await rig.repo.apply(USF002Fixtures.plan(id, expectedRevision: 1, [USF002Fixtures.update(.textExtraction, .running, action: .begin)]))
        _ = try await rig.repo.apply(USF002Fixtures.plan(id, expectedRevision: 2, [USF002Fixtures.update(.textExtraction, .partial, action: .partiallySatisfy, c: 1, t: 3)]))
        let snap = try await rig.repo.apply(USF002Fixtures.plan(id, expectedRevision: 3, [USF002Fixtures.update(.textExtraction, .ready, action: .satisfy, c: 3, t: 3)]))
        #expect(snap.dimension(.textExtraction)?.state == .ready)
    }

    @Test("An illegal transition is rejected")
    func illegalTransitionRejected() async throws {
        let (rig, id) = try await rigWithVersion()
        _ = try await rig.repo.apply(USF002Fixtures.plan(id, expectedRevision: 1, [USF002Fixtures.update(.textExtraction, .ready, action: .satisfy, c: 3, t: 3)]))
        // ready → partial is not allowed (must invalidate to running first).
        await #expect(throws: SourceReadinessError.self) {
            _ = try await rig.repo.apply(USF002Fixtures.plan(id, expectedRevision: 2, [USF002Fixtures.update(.textExtraction, .partial, action: .partiallySatisfy, c: 1, t: 3)]))
        }
    }

    @Test("A blocked update without a condition is rejected")
    func blockingConditionRequired() async throws {
        let (rig, id) = try await rigWithVersion()
        await #expect(throws: SourceReadinessError.self) {
            _ = try await rig.repo.apply(USF002Fixtures.plan(id, expectedRevision: 1, [USF002Fixtures.update(.textExtraction, .blocked, action: .block)]))
        }
    }

    @Test("Malformed coverage units are rejected")
    func invalidCoverageUnits() async throws {
        let (rig, id) = try await rigWithVersion()
        await #expect(throws: SourceReadinessError.self) {
            _ = try await rig.repo.apply(USF002Fixtures.plan(id, expectedRevision: 1, [USF002Fixtures.update(.textExtraction, .partial, action: .partiallySatisfy, c: 5, t: 2)]))
        }
    }

    @Test("A basis reference from a different source version is rejected")
    func basisOwnershipMismatch() async throws {
        let (rig, id) = try await rigWithVersion()
        let otherID = try await USF002Fixtures.seedVersion(rig)
        let foreignBlock = try await USF002Fixtures.seedBlock(rig, versionID: otherID)
        await #expect(throws: SourceReadinessError.self) {
            _ = try await rig.repo.apply(USF002Fixtures.plan(id, expectedRevision: 1, [
                USF002Fixtures.update(.structuralExtraction, .ready, action: .satisfy, c: 1, t: 1,
                                      basis: SourceReadinessBasis(kind: .evidenceBlock, identifier: foreignBlock.uuidString))]))
        }
    }

    @Test("A blank producer id is rejected")
    func blankProducerRejected() async throws {
        let (rig, id) = try await rigWithVersion()
        let bad = SourceReadinessUpdatePlan(sourceVersionID: id, expectedRevision: 1,
            updates: [USF002Fixtures.update(.textExtraction, .running, action: .begin)],
            producerID: "  ", producerVersion: "1", occurredAt: USF002Fixtures.t0)
        await #expect(throws: SourceReadinessError.self) { _ = try await rig.repo.apply(bad) }
    }

    @Test("Events stay contiguous across multiple plans")
    func eventOrderingAcrossPlans() async throws {
        let (rig, id) = try await rigWithVersion()
        _ = try await rig.repo.apply(USF002Fixtures.plan(id, expectedRevision: 1, [USF002Fixtures.update(.textExtraction, .running, action: .begin)]))
        _ = try await rig.repo.apply(USF002Fixtures.plan(id, expectedRevision: 2, [USF002Fixtures.update(.indexing, .running, action: .begin)]))
        let events = try await rig.inspector.events(sourceVersionID: id)
        #expect(events.map(\.sequence) == Array(0..<12))
        #expect(events.last?.aggregateRevision == 3)
    }

    @Test("An invalidation reopens a ready dimension only with a reason")
    func invalidationRequiresReason() async throws {
        let (rig, id) = try await rigWithVersion()
        _ = try await rig.repo.apply(USF002Fixtures.plan(id, expectedRevision: 1, [USF002Fixtures.update(.textExtraction, .ready, action: .satisfy, c: 3, t: 3)]))
        // invalidate without detail → rejected
        await #expect(throws: SourceReadinessError.self) {
            _ = try await rig.repo.apply(USF002Fixtures.plan(id, expectedRevision: 2, [USF002Fixtures.update(.textExtraction, .running, action: .invalidate)]))
        }
        // invalidate with a reason → accepted
        let snap = try await rig.repo.apply(USF002Fixtures.plan(id, expectedRevision: 2,
            [USF002Fixtures.update(.textExtraction, .running, action: .invalidate, detail: "producer v2 supersedes")]))
        #expect(snap.dimension(.textExtraction)?.state == .running)
    }

    @Test("Readiness reconstructs exactly after a database reopen")
    func reopenReconstruction() async throws {
        let (rig, id) = try await rigWithVersion()
        _ = try await rig.repo.apply(USF002Fixtures.plan(id, expectedRevision: 1, [
            USF002Fixtures.update(.textExtraction, .ready, action: .satisfy, c: 5, t: 5),
            USF002Fixtures.update(.indexing, .ready, action: .satisfy, c: 5, t: 5),
        ]))
        let before = try await rig.repo.snapshot(sourceVersionID: id)
        let reopened = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion, at: rig.dbURL)
        let after = try await SourceReadinessRepository(database: reopened).snapshot(sourceVersionID: id)
        #expect(before == after)
    }

    @Test("The completion state is DERIVED from dimension moves, never caller-set")
    func completionStateDerived() async throws {
        let (rig, id) = try await rigWithVersion()
        // Initially preservedOnly (nothing searchable).
        #expect(try await rig.repo.snapshot(sourceVersionID: id).completionState == .preservedOnly)
        // Make it searchable purely by moving dimensions → completion becomes searchablePartial.
        _ = try await rig.repo.apply(USF002Fixtures.plan(id, expectedRevision: 1, [
            USF002Fixtures.update(.textExtraction, .ready, action: .satisfy, c: 5, t: 5),
            USF002Fixtures.update(.indexing, .ready, action: .satisfy, c: 5, t: 5),
        ]))
        #expect(try await rig.repo.snapshot(sourceVersionID: id).completionState == .searchablePartial)
    }

    @Test("Updating one source version never touches another")
    func sourceVersionIsolation() async throws {
        let (rig, id) = try await rigWithVersion()
        let otherID = try await USF002Fixtures.seedVersion(rig)
        _ = try await rig.repo.bootstrap(sourceVersionID: otherID, detectedType: .txt, preservationStatus: .referenceRecorded, at: USF002Fixtures.t0)
        _ = try await rig.repo.apply(USF002Fixtures.plan(id, expectedRevision: 1, [USF002Fixtures.update(.textExtraction, .ready, action: .satisfy, c: 1, t: 1)]))
        let other = try await rig.repo.snapshot(sourceVersionID: otherID)
        #expect(other.aggregateRevision == 1)
        #expect(other.dimension(.textExtraction)?.state == .notStarted)
    }

    @Test("A plan that fails validation mid-way writes nothing")
    func failedPlanWritesNothing() async throws {
        let (rig, id) = try await rigWithVersion()
        await #expect(throws: SourceReadinessError.self) {
            _ = try await rig.repo.apply(USF002Fixtures.plan(id, expectedRevision: 1, [
                USF002Fixtures.update(.textExtraction, .ready, action: .satisfy, c: 5, t: 5),   // valid
                USF002Fixtures.update(.indexing, .partial, action: .partiallySatisfy, c: 9, t: 2), // invalid units
            ]))
        }
        let snap = try await rig.repo.snapshot(sourceVersionID: id)
        #expect(snap.aggregateRevision == 1)                              // nothing committed
        #expect(snap.dimension(.textExtraction)?.state == .notStarted)    // first update rolled back too
        #expect(try await rig.inspector.eventCount(sourceVersionID: id) == 10)
    }
}
