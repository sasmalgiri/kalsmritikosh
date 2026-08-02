//
//  MMIIdentityFastPathTests.swift
//  KalsmritikoshTests
//
//  MMI-FINAL — the deterministic identity fast path in MasterBrain: an identity question is
//  answered with ZERO generative calls from a located, source-backed typed field, cited to the
//  owning KnowledgeObject and gated by the caller's SensitiveScope. Ambiguity returns
//  candidates (never a guess); a non-identity question falls through. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("MMI-FINAL — identity fast path", .serialized)
struct MMIIdentityFastPathTests {

    private struct Rig {
        let brain: MasterBrain; let db: Database; let typed: TypedFieldRepository
        let scope: SensitiveScopeRepository; let sv: UUID; let ko: UUID; let block: UUID
    }

    private func seedDoc(_ db: Database) async throws -> (sv: UUID, ko: UUID, block: UUID) {
        let f = UUID(), sv = UUID(), ko = UUID(), block = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                         [.uuid(f), .text("file:///x/\(f.uuidString)"), .text("txt"), .text("available")])
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(sv), .uuid(f), .text(String(repeating: "a", count: 64)), .real(100), .integer(1), .real(100),
                  .text("id.txt"), .text("txt"), .text("magicBytes"), .integer(1), .text("referenced"), .text("referenceRecorded"), .real(100)])
        try await db.exec("INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);",
                         [.uuid(ko), .uuid(f), .text("txt"), .text("identity document body"), .real(100), .real(100)])
        try await db.exec("""
            INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text, extraction_method, extraction_confidence)
            VALUES (?,?,?,?,?,?,?,?,?);
            """, [.uuid(block), .uuid(UUID()), .uuid(sv), .integer(0), .text("paragraph"), .text("t"), .text("t"), .text("native"), .real(1.0)])
        return (sv, ko, block)
    }

    private func makeRig() async throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mmi-fast-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db); try await db.exec("PRAGMA foreign_keys = ON;")
        let (sv, ko, block) = try await seedDoc(db)
        let typed = TypedFieldRepository(database: db)
        let scope = SensitiveScopeRepository(database: db)
        let brain = MasterBrain(typedFields: typed, sensitiveScope: scope)
        return Rig(brain: brain, db: db, typed: typed, scope: scope, sv: sv, ko: ko, block: block)
    }

    private func add(_ rig: Rig, _ type: TypedFieldType, _ value: String, conf: Double = 0.9, sv: UUID? = nil, block: UUID? = nil) async throws {
        let v = sv ?? rig.sv, b = block ?? rig.block
        try await rig.typed.replaceFields(sourceVersionID: v, producerID: "mmi.typed-field", producerVersion: "1",
            fields: [TypedField(sourceVersionID: v, evidenceBlockID: b, fieldType: type, rawValue: value,
                                normalizedValue: value.lowercased(), confidence: conf, extractionMethod: .native,
                                locator: SourceLocator(evidenceBlockID: b, page: 1), producerID: "mmi.typed-field", producerVersion: "1")])
    }
    private let intent = UserIntent(kind: .factualLookup, scope: .global, rawQuestion: "q")

    @Test("A name question is answered deterministically and cited to the owning document")
    func deterministicName() async throws {
        let rig = try await makeRig()
        try await add(rig, .personName, "Jane Roe")
        let ans = try #require(await rig.brain.identityFieldFastPath(question: "What is the name in this document?", intent: intent, access: .testUnrestricted()))
        #expect(ans.body.contains("Jane Roe"))
        #expect(!ans.refused)
        #expect(ans.citations.first?.objectID == rig.ko)
    }

    @Test("A document-number and an issue-date question are answered deterministically")
    func documentNumberAndIssueDate() async throws {
        let rig = try await makeRig()
        try await rig.typed.replaceFields(sourceVersionID: rig.sv, producerID: "mmi.typed-field", producerVersion: "1", fields: [
            TypedField(sourceVersionID: rig.sv, evidenceBlockID: rig.block, fieldType: .documentNumber, rawValue: "A1234567",
                       normalizedValue: "a1234567", confidence: 0.9, extractionMethod: .native, locator: SourceLocator(page: 1),
                       producerID: "mmi.typed-field", producerVersion: "1"),
            TypedField(sourceVersionID: rig.sv, evidenceBlockID: rig.block, fieldType: .issueDate, rawValue: "01 Jan 2020",
                       normalizedValue: "01 jan 2020", confidence: 0.9, extractionMethod: .native, locator: SourceLocator(page: 1),
                       producerID: "mmi.typed-field", producerVersion: "1")])
        let doc = try #require(await rig.brain.identityFieldFastPath(question: "What is the document number?", intent: intent, access: .testUnrestricted()))
        #expect(doc.body.contains("A1234567"))
        let issue = try #require(await rig.brain.identityFieldFastPath(question: "What is the date of issue?", intent: intent, access: .testUnrestricted()))
        #expect(issue.body.contains("01 Jan 2020"))
    }

    @Test("A non-identity question falls through (nil) — no fabricated fast answer")
    func nonIdentityFallsThrough() async throws {
        let rig = try await makeRig()
        try await add(rig, .personName, "Jane Roe")
        #expect(await rig.brain.identityFieldFastPath(question: "Why did the project fail?", intent: intent, access: .testUnrestricted()) == nil)
    }

    @Test("No typed fields → the fast path returns nil")
    func noFieldsNil() async throws {
        let rig = try await makeRig()
        #expect(await rig.brain.identityFieldFastPath(question: "What is the name?", intent: intent, access: .testUnrestricted()) == nil)
    }

    @Test("Two documents with different names return candidates, never a single guess")
    func ambiguousCandidates() async throws {
        let rig = try await makeRig()
        let (sv2, _, block2) = try await seedDoc(rig.db)
        try await add(rig, .personName, "Jane Roe")
        try await add(rig, .personName, "John Roe", sv: sv2, block: block2)
        let ans = try #require(await rig.brain.identityFieldFastPath(question: "What is the name?", intent: intent, access: .testUnrestricted()))
        #expect(ans.body.contains("Jane Roe"))
        #expect(ans.body.contains("John Roe"))
        #expect(ans.body.lowercased().contains("ambiguous"))
    }

    @Test("A low-confidence header-name candidate is not answered deterministically")
    func lowConfidenceNotAnswered() async throws {
        let rig = try await makeRig()
        try await add(rig, .personName, "Possibly Name", conf: 0.45)   // below the resolver floor
        #expect(await rig.brain.identityFieldFastPath(question: "What is the name?", intent: intent, access: .testUnrestricted()) == nil)
    }

    @Test("A restricted identity field is excluded for an access that may not see it")
    func sensitiveRestrictedExcluded() async throws {
        let rig = try await makeRig()
        try await add(rig, .documentNumber, "A1234567")
        // Restrict the owning KnowledgeObject.
        _ = try await rig.scope.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: rig.ko),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: false), reason: nil)
        // An access whose ceiling is internal cannot see a restricted field → excluded → nil.
        let restricted = SensitiveAccessContext(scope: SensitiveScope(
            workspaceID: UUID(), maximumSensitivity: .internalLevel, permitsPrivilegedMaterial: false, purpose: .retrieval))
        #expect(await rig.brain.identityFieldFastPath(question: "What is the document number?", intent: intent, access: restricted) == nil)
        // An unrestricted access still sees it.
        #expect(await rig.brain.identityFieldFastPath(question: "What is the document number?", intent: intent, access: .testUnrestricted()) != nil)
    }
}
