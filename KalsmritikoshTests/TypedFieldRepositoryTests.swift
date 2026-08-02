//
//  TypedFieldRepositoryTests.swift
//  KalsmritikoshTests
//
//  MMI-FINAL — the typed-field store: atomic per-producer replace, exact-version reads,
//  provenance round-trip (locator + bounding box), and conflict surfacing (two located values
//  of one field type disagreeing are both preserved, never resolved). Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("MMI-FINAL — typed-field repository", .serialized)
struct TypedFieldRepositoryTests {

    private struct Rig { let repo: TypedFieldRepository; let db: Database; let sv: UUID; let block: UUID }
    private func makeRig() async throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mmi-tf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db); try await db.exec("PRAGMA foreign_keys = ON;")
        let sv = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                         [.uuid(sv), .text("file:///x/\(sv.uuidString)"), .text("txt"), .text("available")])
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(sv), .uuid(sv), .text(String(repeating: "a", count: 64)), .real(100), .integer(1), .real(100),
                  .text("f.txt"), .text("txt"), .text("magicBytes"), .integer(1), .text("referenced"), .text("referenceRecorded"), .real(100)])
        let block = UUID()
        try await db.exec("""
            INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text, extraction_method, extraction_confidence)
            VALUES (?,?,?,?,?,?,?,?,?);
            """, [.uuid(block), .uuid(UUID()), .uuid(sv), .integer(0), .text("paragraph"), .text("t"), .text("t"), .text("native"), .real(1.0)])
        return Rig(repo: TypedFieldRepository(database: db), db: db, sv: sv, block: block)
    }
    private func field(_ rig: Rig, _ type: TypedFieldType, _ value: String, conf: Double = 0.9,
                       producer: String = "mmi.typed-field", version: String = "1",
                       locator: SourceLocator? = nil, bbox: [Double]? = nil, ocr: Double? = nil) -> TypedField {
        TypedField(sourceVersionID: rig.sv, evidenceBlockID: rig.block, fieldType: type, rawValue: value,
                   normalizedValue: value.lowercased(), confidence: conf, extractionMethod: ocr == nil ? .native : .ocr,
                   locator: locator ?? SourceLocator(evidenceBlockID: rig.block, page: 2), ocrConfidence: ocr, boundingBox: bbox,
                   producerID: producer, producerVersion: version)
    }

    @Test("replaceFields persists and exact-version read returns them")
    func replaceAndRead() async throws {
        let rig = try await makeRig()
        try await rig.repo.replaceFields(sourceVersionID: rig.sv, producerID: "mmi.typed-field", producerVersion: "1",
            fields: [field(rig, .personName, "Jane Roe"), field(rig, .documentNumber, "X123")])
        let read = try await rig.repo.fields(forVersion: rig.sv)
        #expect(read.count == 2)
        #expect(read.contains { $0.fieldType == .personName && $0.normalizedValue == "jane roe" })
    }

    @Test("Re-running the same producer replaces its output, never doubling it")
    func idempotentReplace() async throws {
        let rig = try await makeRig()
        try await rig.repo.replaceFields(sourceVersionID: rig.sv, producerID: "mmi.typed-field", producerVersion: "1",
            fields: [field(rig, .personName, "Jane Roe")])
        try await rig.repo.replaceFields(sourceVersionID: rig.sv, producerID: "mmi.typed-field", producerVersion: "1",
            fields: [field(rig, .personName, "Jane Roe")])
        #expect(try await rig.repo.count() == 1)
    }

    @Test("A different producer version coexists (replace only touches its own rows)")
    func producersCoexist() async throws {
        let rig = try await makeRig()
        try await rig.repo.replaceFields(sourceVersionID: rig.sv, producerID: "mmi.typed-field", producerVersion: "1",
            fields: [field(rig, .personName, "Jane Roe", version: "1")])
        try await rig.repo.replaceFields(sourceVersionID: rig.sv, producerID: "mmi.typed-field", producerVersion: "2",
            fields: [field(rig, .personName, "Jane Roe", version: "2")])
        #expect(try await rig.repo.count() == 2)
    }

    @Test("Typed fields can be read by type")
    func readByType() async throws {
        let rig = try await makeRig()
        try await rig.repo.replaceFields(sourceVersionID: rig.sv, producerID: "mmi.typed-field", producerVersion: "1",
            fields: [field(rig, .personName, "Jane Roe"), field(rig, .email, "a@b.co")])
        #expect(try await rig.repo.fields(forVersion: rig.sv, type: .email).count == 1)
        #expect(try await rig.repo.fields(forVersion: rig.sv, type: .amount).isEmpty)
    }

    @Test("Two disagreeing values of one field type surface as a conflict (both preserved)")
    func conflictSurfaced() async throws {
        let rig = try await makeRig()
        try await rig.repo.replaceFields(sourceVersionID: rig.sv, producerID: "mmi.typed-field", producerVersion: "1",
            fields: [field(rig, .dateOfBirth, "1990-03-14"), field(rig, .dateOfBirth, "1991-03-14")])
        let conflicts = try await rig.repo.conflicts(forVersion: rig.sv)
        #expect(conflicts.count == 1)
        #expect(conflicts.first?.fieldType == .dateOfBirth)
        #expect(conflicts.first?.distinctValues.count == 2)
    }

    @Test("Identical values of one field type are not a conflict")
    func noConflictSameValue() async throws {
        let rig = try await makeRig()
        try await rig.repo.replaceFields(sourceVersionID: rig.sv, producerID: "mmi.typed-field", producerVersion: "1",
            fields: [field(rig, .email, "a@b.co"), field(rig, .email, "a@b.co")])
        #expect(try await rig.repo.conflicts(forVersion: rig.sv).isEmpty)
    }

    @Test("Provenance round-trips: locator (page) and bounding box survive persistence")
    func provenanceRoundTrip() async throws {
        let rig = try await makeRig()
        let loc = SourceLocator(evidenceBlockID: rig.block, page: 3, boundingBox: [1, 2, 3, 4])
        try await rig.repo.replaceFields(sourceVersionID: rig.sv, producerID: "mmi.typed-field", producerVersion: "1",
            fields: [field(rig, .personName, "Jane Roe", locator: loc, bbox: [1, 2, 3, 4])])
        let read = try #require(try await rig.repo.fields(forVersion: rig.sv).first)
        #expect(read.locator.page == 3)
        #expect(read.boundingBox == [1, 2, 3, 4])
        #expect(read.evidenceBlockID == rig.block)
    }

    @Test("OCR confidence round-trips")
    func ocrRoundTrip() async throws {
        let rig = try await makeRig()
        try await rig.repo.replaceFields(sourceVersionID: rig.sv, producerID: "mmi.typed-field", producerVersion: "1",
            fields: [field(rig, .personName, "Jane Roe", ocr: 0.6)])
        #expect(try await rig.repo.fields(forVersion: rig.sv).first?.ocrConfidence == 0.6)
    }

    @Test("Replacing with an empty set clears that producer's rows")
    func replaceEmptyClears() async throws {
        let rig = try await makeRig()
        try await rig.repo.replaceFields(sourceVersionID: rig.sv, producerID: "mmi.typed-field", producerVersion: "1",
            fields: [field(rig, .personName, "Jane Roe")])
        try await rig.repo.replaceFields(sourceVersionID: rig.sv, producerID: "mmi.typed-field", producerVersion: "1", fields: [])
        #expect(try await rig.repo.count() == 0)
    }
}
