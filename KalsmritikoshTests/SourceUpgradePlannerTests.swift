//
//  SourceUpgradePlannerTests.swift
//  KalsmritikoshTests
//
//  USF-M3 (USF-009 §24/§25) — minimal deterministic upgrade planning + typed blockers. The planner picks
//  the least work to reach a goal (never deep-study when only OCR + structure is needed) and refuses
//  impossible targets. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("USF-M3 — source upgrade planner", .serialized)
struct SourceUpgradePlannerTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Rig { let db: Database; let readiness: SourceReadinessRepository }

    private func makeRig() async throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usfm3-plan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db); try await db.exec("PRAGMA foreign_keys = ON;")
        return Rig(db: db, readiness: SourceReadinessRepository(database: db))
    }

    private func makeVersion(_ rig: Rig, type: SourceType) async throws -> UUID {
        let id = UUID()
        try await rig.db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                             [.uuid(id), .text("file:///x/\(id.uuidString)"), .text(type.rawValue), .text("available")])
        try await rig.db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(id), .text(String(repeating: "a", count: 64)), .real(100), .integer(1), .real(100),
                  .text("f"), .text(type.rawValue), .text("magicBytes"), .integer(1), .text("referenced"), .text("referenceRecorded"), .real(100)])
        _ = try await rig.readiness.bootstrap(sourceVersionID: id, detectedType: type, preservationStatus: .referenceRecorded, at: t0)
        return id
    }

    private func apply(_ rig: Rig, _ id: UUID, _ u: [SourceReadinessDimensionUpdate]) async throws {
        let s = try await rig.readiness.snapshot(sourceVersionID: id)
        _ = try await rig.readiness.apply(SourceReadinessUpdatePlan(sourceVersionID: id, expectedRevision: s.aggregateRevision, updates: u, producerID: "t", producerVersion: "1", occurredAt: t0))
    }

    private func makeSearchable(_ rig: Rig, _ id: UUID) async throws {
        let ko = UUID()
        try await rig.db.exec("INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);",
                             [.uuid(ko), .uuid(id), .text("txt"), .text("b"), .real(0), .real(0)])
        for i in 0..<3 {
            try await rig.db.exec("INSERT INTO chunks (id, object_id, ordinal, text, char_start, char_end, created_at, source_version_id) VALUES (?,?,?,?,?,?,?,?);",
                                 [.uuid(UUID()), .uuid(ko), .integer(Int64(i)), .text("c\(i)"), .integer(0), .integer(5), .real(0), .uuid(id)])
        }
        try await apply(rig, id, [
            SourceReadinessDimensionUpdate(dimension: .textExtraction, state: .ready, action: .satisfy, completedUnits: 3, totalUnits: 3),
            SourceReadinessDimensionUpdate(dimension: .indexing, state: .ready, action: .satisfy, completedUnits: 3, totalUnits: 3,
                                           basis: SourceReadinessBasis(kind: .ftsIndex, identifier: id.uuidString))])
    }

    private func snap(_ rig: Rig, _ id: UUID) async throws -> SourceReadinessSnapshot { try await rig.readiness.snapshot(sourceVersionID: id) }

    @Test("Search-ready already satisfied yields an empty plan")
    func searchAlreadySatisfied() async throws {
        let rig = try await makeRig(); let id = try await makeVersion(rig, type: .txt); try await makeSearchable(rig, id)
        let plan = try SourceUpgradePlanner.plan(sourceVersionID: id, goal: .searchReady, detectedType: .txt, readiness: try await snap(rig, id))
        #expect(plan.alreadySatisfied)
    }

    @Test("Search on an un-extracted text doc plans structural extraction + indexing")
    func searchPlansTextAndIndex() async throws {
        let rig = try await makeRig(); let id = try await makeVersion(rig, type: .txt)
        let plan = try SourceUpgradePlanner.plan(sourceVersionID: id, goal: .searchReady, detectedType: .txt, readiness: try await snap(rig, id))
        #expect(plan.kinds == [.structuralExtraction, .indexing])
    }

    @Test("Search on an image plans OCR + indexing (essential OCR)")
    func searchImagePlansOCR() async throws {
        let rig = try await makeRig(); let id = try await makeVersion(rig, type: .png)
        let plan = try SourceUpgradePlanner.plan(sourceVersionID: id, goal: .searchReady, detectedType: .png, readiness: try await snap(rig, id))
        #expect(plan.kinds == [.ocr, .indexing])
    }

    @Test("Evidence on a searchable doc plans only structural work — never embeddings/deepStudy")
    func evidencePlansStructuralOnly() async throws {
        let rig = try await makeRig(); let id = try await makeVersion(rig, type: .txt); try await makeSearchable(rig, id)
        let plan = try SourceUpgradePlanner.plan(sourceVersionID: id, goal: .evidenceReady, detectedType: .txt, readiness: try await snap(rig, id))
        #expect(plan.kinds == [.structuralExtraction])
        #expect(!plan.kinds.contains(.embedding))
        #expect(!plan.kinds.contains(.deepStudy))
    }

    @Test("Analytical planning includes the analytical kinds")
    func analyticalPlansAnalytical() async throws {
        let rig = try await makeRig(); let id = try await makeVersion(rig, type: .txt); try await makeSearchable(rig, id)
        let plan = try SourceUpgradePlanner.plan(sourceVersionID: id, goal: .analyticallyReady, detectedType: .txt, readiness: try await snap(rig, id))
        #expect(plan.kinds.contains(.embedding))
        #expect(plan.kinds.contains(.entityReconciliation))
        #expect(plan.kinds.contains(.analyticalReadiness))
    }

    @Test("Audio cannot reach search readiness — transcription is unsupported")
    func audioSearchBlocked() async throws {
        let rig = try await makeRig(); let id = try await makeVersion(rig, type: .mp3)
        let s = try await snap(rig, id)
        #expect(throws: SourceUpgradeError.unsupportedCapability(.transcription)) {
            _ = try SourceUpgradePlanner.plan(sourceVersionID: id, goal: .searchReady, detectedType: .mp3, readiness: s)
        }
    }

    @Test("An encrypted source blocks evidence planning")
    func encryptedBlocked() async throws {
        let rig = try await makeRig(); let id = try await makeVersion(rig, type: .txt)
        try await apply(rig, id, [SourceReadinessDimensionUpdate(dimension: .textExtraction, state: .blocked, action: .block, condition: .encrypted)])
        let s = try await snap(rig, id)
        #expect(throws: SourceUpgradeError.self) {
            _ = try SourceUpgradePlanner.plan(sourceVersionID: id, goal: .evidenceReady, detectedType: .txt, readiness: s)
        }
    }

    @Test("Container inspection is planned for an uninspected archive and skipped once inspected")
    func containerInspectionPlan() async throws {
        let rig = try await makeRig(); let id = try await makeVersion(rig, type: .zip)
        let s = try await snap(rig, id)
        #expect(try SourceUpgradePlanner.plan(sourceVersionID: id, goal: .containerInspection, detectedType: .zip, readiness: s).kinds == [.containerInspection])
        #expect(try SourceUpgradePlanner.plan(sourceVersionID: id, goal: .containerInspection, detectedType: .zip, readiness: s, containerStatus: .complete).alreadySatisfied)
    }

    @Test("Container inspection on a non-container is blocked")
    func nonContainerInspectionBlocked() async throws {
        let rig = try await makeRig(); let id = try await makeVersion(rig, type: .txt)
        let s = try await snap(rig, id)
        #expect(throws: SourceUpgradeError.self) {
            _ = try SourceUpgradePlanner.plan(sourceVersionID: id, goal: .containerInspection, detectedType: .txt, readiness: s)
        }
    }

    @Test("specificDimension without an explicit kind is refused")
    func specificDimensionThrows() async throws {
        let rig = try await makeRig(); let id = try await makeVersion(rig, type: .txt)
        let s = try await snap(rig, id)
        #expect(throws: SourceUpgradeError.self) {
            _ = try SourceUpgradePlanner.plan(sourceVersionID: id, goal: .specificDimension, detectedType: .txt, readiness: s)
        }
    }
}
