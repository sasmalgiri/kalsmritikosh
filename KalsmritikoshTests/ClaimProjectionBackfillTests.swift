//
//  ClaimProjectionBackfillTests.swift
//  KalsmritikoshTests
//
//  PA-PROD Commit B2 — the durable, resumable, single-flight projection backfill. Proves:
//  full independent per-kind passes, keyset resume from the exact last successful source,
//  repeat-without-duplicate, malformed-source skip-and-advance, producer-version isolation,
//  and single-flight concurrency.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PA-PROD B2 — projection backfill + durable progress")
struct ClaimProjectionBackfillTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Rig {
        let db: Database
        let genericFacts: GenericFactRepository
        let temporalClaims: TemporalClaimRepository
        let assertions: AssertionsRepository
        let events: EventsRepository
        let claims: ClaimRepository
        let progress: ClaimProjectionProgressRepository
        let workspaces: WorkspaceRepository
        let producer: ClaimProducer
        let membership: WorkspaceMembershipDeriver
        func coordinator(version: String = ClaimProducer.producerVersion, pageSize: Int = 500) -> ClaimProjectionBackfill {
            ClaimProjectionBackfill(producer: producer, progress: progress, membership: membership,
                                    genericFacts: genericFacts, temporalClaims: temporalClaims,
                                    assertions: assertions, events: events, pageSize: pageSize, version: version)
        }
    }

    private func rig() async throws -> Rig {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("b2-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)
        let gf = GenericFactRepository(database: db)
        let tcs = TemporalClaimRepository(database: db)
        let asrt = AssertionsRepository(database: db)
        let ev = EventsRepository(database: db)
        let claims = ClaimRepository(database: db)
        let store = EvidenceStore(database: db)
        let ws = WorkspaceRepository(database: db)
        let producer = ClaimProducer(genericFacts: gf, assertions: asrt, temporalClaims: tcs, events: ev, claims: claims, evidence: store)
        return Rig(db: db, genericFacts: gf, temporalClaims: tcs, assertions: asrt, events: ev, claims: claims,
                   progress: ClaimProjectionProgressRepository(database: db), workspaces: ws, producer: producer,
                   membership: WorkspaceMembershipDeriver(database: db, workspaces: ws))
    }

    private func seedSubject(_ r: Rig, subject: UUID) async throws -> UUID {
        let fileID = UUID(), koID = UUID()
        try await r.db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                            [.uuid(fileID), .text("file://\(fileID)"), .text("txt")])
        try await r.db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);
        """, [.uuid(koID), .uuid(fileID), .text("txt"), .text("c"), .real(0), .real(0)])
        try await r.db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?,?,?,?,?);",
                            [.uuid(subject), .text("person"), .text("S"), .text(subject.uuidString.lowercased()), .uuid(koID)])
        return koID
    }

    private func saveFact(_ r: Rig, id: UUID, subject: UUID, value: String) async throws {
        try await r.genericFacts.upsert(GenericFact(
            id: id, subjectID: subject, subjectLabel: "S", field: "employer", value: value,
            assessment: EvidenceAssessment(basis: .sourceAsserted, origin: .sourceExtraction),
            confidence: 0.8, sourceBlockIDs: []))
    }

    // MARK: - Full pass

    @Test("A full pass projects every source kind and marks each kind independently complete")
    func fullPassAllKinds() async throws {
        let r = try await rig()
        let subject = UUID()
        let ko = try await seedSubject(r, subject: subject)
        try await saveFact(r, id: UUID(), subject: subject, value: "Orchid")
        try await r.temporalClaims.insert(TemporalClaim(subjectID: subject, predicate: "worked_for",
            object: .literal("Orchid"), status: .sourceAsserted, confidence: 0.7,
            extractorID: "x", extractorVersion: "1", createdAt: t0))
        try await r.assertions.insert(Assertion(subjectKind: .entity, subjectID: subject,
            predicate: "works_for", object: .literal("Orchid"), provenance: .sourceAsserted))
        try await r.events.insertBatch([Event(id: UUID(), kind: .other, date: t0, title: "Kickoff",
            entityIDs: [subject], sourceObjectID: ko, datePrecision: .day)])

        await r.coordinator().run(at: t0)

        let produced = try await r.claims.claims(subjectID: subject)
        let kinds = Set(produced.compactMap { $0.derivedFrom.first?.kind })
        #expect(kinds == [.genericFact, .temporalClaim, .assertion, .event])
        for kind in ClaimProjectionBackfill.Kind.allCases {
            #expect(try await r.progress.cursor(version: ClaimProducer.producerVersion, kind: kind.rawValue).complete)
        }
    }

    // MARK: - Resume + no duplicate

    @Test("Backfill resumes from the exact last successful source (keyset cursor)")
    func resumesFromCursor() async throws {
        let r = try await rig()
        let subject = UUID()
        _ = try await seedSubject(r, subject: subject)
        let ids = [UUID(), UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        for (i, id) in ids.enumerated() { try await saveFact(r, id: id, subject: subject, value: "v\(i)") }
        // Simulate an interrupted pass that already processed ids[0] and ids[1].
        try await r.progress.advance(version: ClaimProducer.producerVersion, kind: "genericFact", lastSourceID: ids[1], at: t0)
        await r.coordinator().run(at: t0)
        let produced = try await r.claims.claims(subjectID: subject)
        // Only the source AFTER the cursor (ids[2]) is projected.
        #expect(produced.count == 1)
        #expect(produced.first?.derivedFrom.first?.id == ids[2])
    }

    @Test("Re-running a completed kind (cursor reset) repeats sources without duplicating Claims")
    func repeatNoDuplicate() async throws {
        let r = try await rig()
        let subject = UUID()
        _ = try await seedSubject(r, subject: subject)
        let ids = [UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        for (i, id) in ids.enumerated() { try await saveFact(r, id: id, subject: subject, value: "v\(i)") }
        await r.coordinator().run(at: t0)
        #expect(try await r.claims.count() == 2)
        // Reset the cursor as if a crash lost progress; re-run repeats ids[1] (id > ids[0]).
        try await r.progress.advance(version: ClaimProducer.producerVersion, kind: "genericFact", lastSourceID: ids[0], at: t0)
        await r.coordinator().run(at: t0.addingTimeInterval(50))
        #expect(try await r.claims.count() == 2)                 // UPSERT → no duplicate
    }

    // MARK: - Skip malformed

    @Test("A malformed source is skipped and the pass still completes")
    func malformedSkippedAdvances() async throws {
        let r = try await rig()
        let subject = UUID()
        _ = try await seedSubject(r, subject: subject)
        try await saveFact(r, id: UUID(), subject: subject, value: "Orchid")
        try await saveFact(r, id: UUID(), subject: subject, value: "")     // malformed → skipped
        try await saveFact(r, id: UUID(), subject: subject, value: "Labs")
        await r.coordinator().run(at: t0)
        #expect(try await r.claims.count() == 2)                 // the two valid facts
        #expect(try await r.progress.cursor(version: ClaimProducer.producerVersion, kind: "genericFact").complete)
    }

    // MARK: - Producer version isolation

    @Test("A new producer version runs a fresh pass without touching the old version's progress")
    func producerVersionFreshPass() async throws {
        let r = try await rig()
        let subject = UUID()
        _ = try await seedSubject(r, subject: subject)
        try await saveFact(r, id: UUID(), subject: subject, value: "Orchid")
        await r.coordinator(version: "vA").run(at: t0)
        #expect(try await r.progress.cursor(version: "vA", kind: "genericFact").complete)

        await r.coordinator(version: "vB").run(at: t0.addingTimeInterval(100))
        #expect(try await r.progress.cursor(version: "vB", kind: "genericFact").complete)   // fresh pass ran
        #expect(try await r.progress.cursor(version: "vA", kind: "genericFact").complete)   // old untouched
        #expect(try await r.claims.count() == 1)                 // idempotent across versions
    }

    // MARK: - Single flight

    @Test("Concurrent run() calls perform a single effective pass (no duplicate Claims)")
    func singleFlightConcurrent() async throws {
        let r = try await rig()
        let subject = UUID()
        _ = try await seedSubject(r, subject: subject)
        try await saveFact(r, id: UUID(), subject: subject, value: "Orchid")
        try await saveFact(r, id: UUID(), subject: subject, value: "Labs")
        let coord = r.coordinator()
        async let a: Void = coord.run(at: t0)
        async let b: Void = coord.run(at: t0)
        _ = await (a, b)
        #expect(try await r.claims.count() == 2)
    }

    // MARK: - Cancellation

    private actor Counter { var n = 0; func next() -> Int { n += 1; return n } }

    @Test("Cancellation mid-page halts the pass, leaves the cursor at the last completed source, and resumes safely")
    func cancelMidPageResumes() async throws {
        let r = try await rig()
        let subject = UUID()
        _ = try await seedSubject(r, subject: subject)
        let ids = [UUID(), UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        for (i, id) in ids.enumerated() { try await saveFact(r, id: id, subject: subject, value: "v\(i)") }
        let coord = r.coordinator(pageSize: 10)             // all three fit in one page
        let counter = Counter()
        // Request cancellation right BEFORE the second source is projected → exactly one projected.
        await coord.setBeforeEachProject {
            if await counter.next() == 2 { await coord.requestCancel() }
        }
        await coord.run(at: t0)
        // Only ids[0] was projected; the cursor sits at it and the kind is NOT complete.
        #expect(try await r.claims.count() == 1)
        let cur = try await r.progress.cursor(version: ClaimProducer.producerVersion, kind: "genericFact")
        #expect(cur.lastSourceID == ids[0])
        #expect(cur.complete == false)
        // Resume: a fresh pass finishes the remaining sources from the cursor and completes.
        await coord.run(at: t0.addingTimeInterval(10))
        #expect(try await r.claims.count() == 3)
        #expect(try await r.progress.cursor(version: ClaimProducer.producerVersion, kind: "genericFact").complete)
    }

    // MARK: - Progress repository semantics

    @Test("Progress cursor defaults to start, advances, completes, and isolates by version")
    func progressSemantics() async throws {
        let r = try await rig()
        #expect(try await r.progress.cursor(version: "v1", kind: "genericFact") == .init(lastSourceID: nil, complete: false))
        let id = UUID()
        try await r.progress.advance(version: "v1", kind: "genericFact", lastSourceID: id, at: t0)
        #expect(try await r.progress.cursor(version: "v1", kind: "genericFact").lastSourceID == id)
        #expect(try await r.progress.cursor(version: "v1", kind: "genericFact").complete == false)
        try await r.progress.markComplete(version: "v1", kind: "genericFact", at: t0)
        #expect(try await r.progress.cursor(version: "v1", kind: "genericFact").complete == true)
        #expect(try await r.progress.cursor(version: "v2", kind: "genericFact") == .init(lastSourceID: nil, complete: false))
    }
}
