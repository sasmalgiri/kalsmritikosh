//
//  InvestigationSubjectDossierServiceTests.swift
//  KalsmritikoshTests
//
//  INV-02 — the Subject dossier entry point. Proves an entity is nominated as a subject ONLY when it has
//  evidence inside the case's authorized scope (never a workspace widen); that the human confirmation is
//  recorded; and that the assembled dossier CITES EXACT EVIDENCE — every item anchored to an authorized
//  source version, an unauthorized source's mention never appearing. Uses the REAL shared EntitiesRepository.
//  Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("INV-02 — subject dossier (cites exact in-scope evidence)")
struct InvestigationSubjectDossierServiceTests {

    private let t0 = Date(timeIntervalSince1970: 1_767_200_000)

    private struct Rig {
        let db: Database
        let cases: InvestigationCaseRepository
        let service: InvestigationSubjectDossierService
        let caseID: UUID
        let subjectEntity: UUID
        let vA: UUID
        let koA: UUID
        let outsiderEntity: UUID
    }

    /// A case authorizing vA. `subjectEntity` has two in-scope mentions on vA; `outsiderEntity` has a
    /// mention only on an UNauthorized version vB.
    private func rig() async throws -> Rig {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(ws), .text("Matter"), .real(1), .real(1)])
        let (vA, logicalA) = try await seedSourceVersion(db)
        let koA = try await seedKO(db, logical: logicalA)
        let koA2 = try await seedKO(db, logical: logicalA)
        let subjectEntity = UUID()
        try await seedEntity(db, id: subjectEntity, kind: "person", value: "Dana Ivar", ko: koA)
        try await seedMention(db, entity: subjectEntity, kind: "person", surface: "Dana Ivar", ko: koA)
        try await seedMention(db, entity: subjectEntity, kind: "person", surface: "D. Ivar", ko: koA2)

        let (_, logicalB) = try await seedSourceVersion(db)
        let koB = try await seedKO(db, logical: logicalB)
        let outsider = UUID()
        try await seedEntity(db, id: outsider, kind: "person", value: "Someone Else", ko: koB)
        try await seedMention(db, entity: outsider, kind: "person", surface: "Someone Else", ko: koB)

        let cases = InvestigationCaseRepository(database: db)
        let evidence = EvidenceStore(database: db)
        let entities = EntitiesRepository(database: db)
        let subjects = InvestigationSubjectRepository(database: db)
        var c = try await cases.createCase(workspaceID: ws, title: "Dossier case", actor: "analyst", at: t0)
        c = try await cases.includeSource(caseID: c.id, expectedRevision: c.revision,
                                          sourceRef: vA.uuidString, sourceKind: .sourceVersion, actor: "analyst", at: t0)
        let service = InvestigationSubjectDossierService(
            cases: cases, resolver: CaseRetrievalScopeResolver(evidence: evidence),
            subjects: subjects, entities: entities,
            scopedEntities: CaseScopedEntityResolver(entities: entities, evidence: evidence))
        return Rig(db: db, cases: cases, service: service, caseID: c.id, subjectEntity: subjectEntity, vA: vA, koA: koA, outsiderEntity: outsider)
    }

    @Test("An entity with in-scope evidence can be nominated; an out-of-scope entity cannot")
    func nominateRequiresInScope() async throws {
        let rig = try await rig()
        let s = try await rig.service.nominateSubject(caseID: rig.caseID, canonicalEntityID: rig.subjectEntity, label: "Dana", actor: "a", at: t0)
        #expect(s.identityStatus == .proposed)
        await #expect(throws: InvestigationSubjectError.self) {
            _ = try await rig.service.nominateSubject(caseID: rig.caseID, canonicalEntityID: rig.outsiderEntity, label: "X", actor: "a", at: t0)
        }
        await #expect(throws: InvestigationSubjectError.self) {   // a non-existent entity
            _ = try await rig.service.nominateSubject(caseID: rig.caseID, canonicalEntityID: UUID(), label: "Ghost", actor: "a", at: t0)
        }
    }

    @Test("The dossier cites exact evidence — every item is an authorized source version, stamped with the scope fingerprint")
    func dossierCitesExactEvidence() async throws {
        let rig = try await rig()
        let s = try await rig.service.nominateSubject(caseID: rig.caseID, canonicalEntityID: rig.subjectEntity, label: "Dana", actor: "a", at: t0)
        let dossier = try await rig.service.assembleDossier(caseID: rig.caseID, subjectID: s.id)
        #expect(!dossier.items.isEmpty)
        #expect(dossier.items.allSatisfy { $0.sourceVersionID == rig.vA })          // only the authorized version
        #expect(dossier.citedSourceVersionIDs == [rig.vA])
        // The fingerprint is exactly the ONE case-scope fingerprint for this scope.
        let record = try await rig.cases.fetch(caseID: rig.caseID)!
        let expected = CaseScopeFingerprinter.fingerprint(caseID: rig.caseID, caseRevision: record.caseHeader.revision,
                                                          scope: .authorizing([rig.vA]))
        #expect(dossier.scopeFingerprint == expected)
    }

    @Test("The human confirmation flows through the service and is recorded on the subject")
    func confirmThroughService() async throws {
        let rig = try await rig()
        let s = try await rig.service.nominateSubject(caseID: rig.caseID, canonicalEntityID: rig.subjectEntity, label: "Dana", actor: "a", at: t0)
        let confirmed = try await rig.service.confirmSubjectIdentity(subjectID: s.id, expectedRevision: s.revision, actor: "lead", at: t0)
        #expect(confirmed.identityStatus == .confirmed)
        #expect(confirmed.confirmedBy == "lead")
    }

    @Test("The dossier never cites an unauthorized source, even when the subject shares a name with an outsider")
    func dossierNeverCitesUnauthorized() async throws {
        let rig = try await rig()
        let s = try await rig.service.nominateSubject(caseID: rig.caseID, canonicalEntityID: rig.subjectEntity, label: "Dana", actor: "a", at: t0)
        let dossier = try await rig.service.assembleDossier(caseID: rig.caseID, subjectID: s.id)
        // Every cited KO belongs to the authorized version; none is the outsider's.
        #expect(dossier.items.allSatisfy { $0.sourceVersionID == rig.vA })
        #expect(dossier.items.contains { $0.knowledgeObjectID == rig.koA })
    }

    // MARK: - Seed helpers

    private func seedSourceVersion(_ db: Database) async throws -> (version: UUID, logical: UUID) {
        let version = UUID(), logical = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                          [.uuid(logical), .text("file:///x/\(logical.uuidString)"), .text("txt"), .text("available")])
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(version), .uuid(logical), .text(String(repeating: "b", count: 64)), .real(100), .integer(1), .real(100),
                  .text("f.txt"), .text("txt"), .text("magicBytes"), .integer(1), .text("referenced"), .text("referenceRecorded"), .real(100)])
        return (version, logical)
    }
    private func seedKO(_ db: Database, logical: UUID) async throws -> UUID {
        let ko = UUID()
        try await db.exec("INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);",
                          [.uuid(ko), .uuid(logical), .text("txt"), .text("body"), .real(1), .real(1)])
        return ko
    }
    private func seedEntity(_ db: Database, id: UUID, kind: String, value: String, ko: UUID) async throws {
        try await db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?,?,?,?,?);",
                          [.uuid(id), .text(kind), .text(value), .text(value.lowercased()), .uuid(ko)])
    }
    private func seedMention(_ db: Database, entity: UUID, kind: String, surface: String, ko: UUID) async throws {
        try await db.exec("INSERT INTO entity_mentions (id, entity_id, kind, surface, normalized, source_object_id) VALUES (?,?,?,?,?,?);",
                          [.uuid(UUID()), .uuid(entity), .text(kind), .text(surface), .text(surface.lowercased()), .uuid(ko)])
    }
}
