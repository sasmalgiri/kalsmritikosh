//
//  CaseDeconflictionTests.swift
//  KalsmritikoshTests
//
//  N1 — cross-case deconfliction. Four cases over one ledger: A (this case), B (open), C (closed) and
//  D (erased). Proves an entity shared with B and C is listed with the right case names, stages and
//  document counts; an entity only in A is not listed; documents in no case are counted (including a
//  document B explicitly excluded and the erased case's document); the erased case never appears; a
//  merged spelling counts for the winner; a rejected entity is never listed; and the person auto-link
//  rule links on exactly one exact match only (0, 1, 2 matches). Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("N1 — cross-case deconfliction (counts and case names only)", .serialized)
struct CaseDeconflictionTests {

    private let t0 = Date(timeIntervalSince1970: 1_767_200_000)

    struct Rig {
        let db: Database
        let tool: CaseDeconfliction
        let caseA: UUID, caseB: UUID, caseC: UUID, caseD: UUID
        let dana: UUID, solo: UUID, acme: UUID, rejected: UUID, email: UUID, samA: UUID, samB: UUID, outsider: UUID
    }

    private func rig() async throws -> Rig {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(ws), .text("Matter"), .real(1), .real(1)])
        // Documents: one KO each, except fA1 which holds two (a mailbox counts once).
        let (vA1, fA1) = try await seedSourceVersion(db)
        let (vA2, fA2) = try await seedSourceVersion(db)     // in A and B
        let (vB1, fB1) = try await seedSourceVersion(db)
        let (vBx, fBx) = try await seedSourceVersion(db)     // B excludes it explicitly
        let (vC1, fC1) = try await seedSourceVersion(db)
        let (vD1, fD1) = try await seedSourceVersion(db)     // D's, D is erased
        let (_, fN1) = try await seedSourceVersion(db)       // no case
        let (_, fN2) = try await seedSourceVersion(db)       // no case
        let koA1 = try await seedKO(db, logical: fA1), koA1b = try await seedKO(db, logical: fA1)
        let koA2 = try await seedKO(db, logical: fA2), koB1 = try await seedKO(db, logical: fB1)
        let koBx = try await seedKO(db, logical: fBx), koC1 = try await seedKO(db, logical: fC1)
        let koD1 = try await seedKO(db, logical: fD1), koN1 = try await seedKO(db, logical: fN1)
        let koN2 = try await seedKO(db, logical: fN2)

        let dana = UUID(), solo = UUID(), acme = UUID(), rejected = UUID(), email = UUID()
        let samA = UUID(), samB = UUID(), outsider = UUID(), danaVariant = UUID()
        try await seedEntity(db, id: dana, kind: "person", value: "Dana Ivar", ko: koA1)
        for ko in [koA1, koA1b, koA2, koB1, koBx, koC1, koD1, koN1] { try await seedMention(db, entity: dana, kind: "person", surface: "Dana Ivar", ko: ko) }
        // A merged spelling of Dana, mentioned in a no-case document: counts for Dana.
        try await seedEntity(db, id: danaVariant, kind: "person", value: "D. Ivar", ko: koN2)
        try await seedMention(db, entity: danaVariant, kind: "person", surface: "D. Ivar", ko: koN2)
        try await db.exec("UPDATE entities SET merged_into = ? WHERE id = ?;", [.uuid(dana), .uuid(danaVariant)])
        try await seedEntity(db, id: solo, kind: "person", value: "Solo Person", ko: koA1)
        try await seedMention(db, entity: solo, kind: "person", surface: "Solo Person", ko: koA1)
        try await seedEntity(db, id: acme, kind: "organization", value: "Acme Ltd", ko: koA1)
        for ko in [koA1, koN2] { try await seedMention(db, entity: acme, kind: "organization", surface: "Acme Ltd", ko: ko) }
        try await seedEntity(db, id: rejected, kind: "organization", value: "Rejected Org", ko: koA1)
        for ko in [koA1, koB1] { try await seedMention(db, entity: rejected, kind: "organization", surface: "Rejected Org", ko: ko) }
        try await db.exec("UPDATE entities SET review_status = 'rejected' WHERE id = ?;", [.uuid(rejected)])
        try await seedEntity(db, id: email, kind: "emailAddress", value: "dana@example.com", ko: koA1)
        try await seedMention(db, entity: email, kind: "emailAddress", surface: "dana@example.com", ko: koA1)
        // Two in-scope entities that both answer to "Sam Lee" exactly (one by value, one by alias).
        try await seedEntity(db, id: samA, kind: "person", value: "Sam Lee", ko: koA1)
        try await seedMention(db, entity: samA, kind: "person", surface: "Sam Lee", ko: koA1)
        try await seedEntity(db, id: samB, kind: "person", value: "Samuel Lee", ko: koA2)
        try await seedMention(db, entity: samB, kind: "person", surface: "Samuel Lee", ko: koA2)
        try await db.exec("INSERT INTO entity_aliases (entity_id, alias_normalized, source) VALUES (?,?,?);", [.uuid(samB), .text("sam lee"), .text("test")])
        // Named only outside case A.
        try await seedEntity(db, id: outsider, kind: "person", value: "Out Sider", ko: koB1)
        try await seedMention(db, entity: outsider, kind: "person", surface: "Out Sider", ko: koB1)

        let cases = InvestigationCaseRepository(database: db)
        func open(_ title: String, _ versions: [UUID], excluded: [UUID] = []) async throws -> UUID {
            var c = try await cases.createCase(workspaceID: ws, title: title, actor: "analyst", at: t0)
            for v in versions {
                c = try await cases.includeSource(caseID: c.id, expectedRevision: c.revision, sourceRef: v.uuidString, sourceKind: .sourceVersion, actor: "analyst", at: t0)
            }
            for v in excluded {
                c = try await cases.excludeSource(caseID: c.id, expectedRevision: c.revision, sourceRef: v.uuidString, sourceKind: .sourceVersion, actor: "analyst", at: t0)
            }
            return c.id
        }
        let a = try await open("Case A", [vA1, vA2])
        let b = try await open("Case B", [vA2, vB1], excluded: [vBx])
        let c = try await open("Case C", [vC1])
        let d = try await open("Case D", [vD1])
        try await db.exec("UPDATE investigation_cases SET status = 'closed' WHERE id = ?;", [.uuid(c)])
        let erased = try await CaseEraser(database: db).erase(caseID: d, sourceVersionIDs: [vD1], eraseExclusiveSources: false,
                                                              reason: "test", legalBasis: nil, actor: "analyst", at: t0)
        #expect(erased.refused == nil, "\(erased.refused ?? "")")
        return Rig(db: db, tool: CaseDeconfliction(database: db), caseA: a, caseB: b, caseC: c, caseD: d,
                   dana: dana, solo: solo, acme: acme, rejected: rejected, email: email, samA: samA, samB: samB, outsider: outsider)
    }

    @Test("A shared person is listed with the other cases' names, stages and document counts, and the documents in no case")
    func overlapFound() async throws {
        let r = try await rig()
        let report = try await r.tool.report(caseID: r.caseA)
        let dana = try #require(report.entities.first { $0.entityID == r.dana })
        #expect(report.entities.first?.entityID == r.dana, "the entity in the most other cases ranks first")
        #expect(dana.documentsInThisCase == 2)                         // fA1 (two KOs, one document) + fA2
        #expect(dana.otherCases.map(\.title) == ["Case B", "Case C"])
        let b = try #require(dana.otherCases.first { $0.caseID == r.caseB })
        #expect(b.documents == 2 && b.status == "open" && !b.closed)  // fA2 + fB1; B's excluded document is not B's
        let c = try #require(dana.otherCases.first { $0.caseID == r.caseC })
        #expect(c.documents == 1 && c.closed && c.status == "closed")
        // No case: fN1, B's excluded fBx, the erased case's fD1, and fN2 via the merged spelling.
        #expect(dana.documentsInNoCase == 4)
        #expect(dana.summary == "Case B (open, 2 documents) · Case C (closed, 1 document) · 4 documents in no case")
        // Only counts and titles leave the other cases: the struct carries no text but the entity's own name.
        #expect(!dana.summary.contains("Out Sider"))
    }

    @Test("An entity only in this case is not listed; a no-case-only overlap is; a rejected entity never is; the erased case never appears")
    func filtering() async throws {
        let r = try await rig()
        let report = try await r.tool.report(caseID: r.caseA)
        let ids = Set(report.entities.map(\.entityID))
        #expect(!ids.contains(r.solo) && !ids.contains(r.email) && !ids.contains(r.samA))
        #expect(!ids.contains(r.rejected))
        let acme = try #require(report.entities.first { $0.entityID == r.acme })
        #expect(acme.otherCases.isEmpty && acme.documentsInNoCase == 1)
        #expect(report.entities.allSatisfy { e in e.otherCases.allSatisfy { $0.caseID != r.caseD && $0.caseID != r.caseA } })
        // Samuel Lee is named in fA2, which case B also holds: one other case, one document.
        let sam = try #require(report.entities.first { $0.entityID == r.samB })
        #expect(sam.otherCases.map(\.caseID) == [r.caseB] && sam.otherCases.first?.documents == 1 && sam.documentsInNoCase == 0)
        #expect(report.entities.map(\.entityID) == [r.dana, r.samB, r.acme], "most other cases first, then documents")
        #expect(report.totalOverlapping == 3 && !report.capped)
        // Capped: says so.
        let capped = try await r.tool.report(caseID: r.caseA, limit: 1)
        #expect(capped.capped && capped.entities.count == 1 && capped.totalOverlapping == 3)
        // From case B's side, A is listed for Dana and the outsider (only B) is not.
        let fromB = try await r.tool.report(caseID: r.caseB)
        #expect(fromB.entities.first { $0.entityID == r.dana }?.otherCases.contains { $0.caseID == r.caseA } == true)
        #expect(!fromB.entities.contains { $0.entityID == r.outsider })
    }

    @Test("A case person links on exactly one exact match: none → nil, one → linked, two → the person chooses")
    func autoLinkRule() async throws {
        let r = try await rig()
        let ctx = try await r.tool.prepare(caseID: r.caseA)
        #expect(try await r.tool.autoLinkEntity(ctx, name: "Dana Ivar", contact: nil) == r.dana)
        #expect(try await r.tool.autoLinkEntity(ctx, name: "  dana ivar ", contact: nil) == r.dana)    // case-insensitive
        #expect(try await r.tool.autoLinkEntity(ctx, name: "D. Ivar", contact: nil) == r.dana)         // merged spelling → winner
        #expect(try await r.tool.autoLinkEntity(ctx, name: "Dana", contact: nil) == nil)               // never a partial match
        #expect(try await r.tool.autoLinkEntity(ctx, name: "Nobody Here", contact: nil) == nil)        // 0 matches
        #expect(try await r.tool.autoLinkEntity(ctx, name: "Out Sider", contact: nil) == nil)          // only outside this case
        #expect(try await r.tool.autoLinkEntity(ctx, name: "Rejected Org", contact: nil) == nil)       // rejected
        let sam = try await r.tool.matches(ctx, name: "Sam Lee", contact: nil)                         // 2 matches
        #expect(Set(sam.byName.map(\.id)) == [r.samA, r.samB])
        #expect(CaseDeconfliction.autoLink(byName: sam.byName, byContact: sam.byContact) == nil)
        #expect(CaseDeconfliction.choices(byName: sam.byName, byContact: sam.byContact).count == 2)
        // A contact links when the name matches nothing.
        #expect(try await r.tool.autoLinkEntity(ctx, name: "Unknown caller", contact: "DANA@example.com") == r.email)
        // A linked person's counts: the same numbers as the report.
        let o = try await r.tool.overlaps(ctx, entityIDs: [r.dana, r.solo])
        #expect(o[r.dana]?.otherCases.count == 2)
        #expect(o[r.solo]?.isOnlyInThisCase == true)
    }

    @Test("The case file stores the auto-linked entity on the person")
    func personStoresLink() async throws {
        let r = try await rig()
        let ctx = try await r.tool.prepare(caseID: r.caseA)
        let file = CaseFileRepository(database: r.db)
        let entity = try await r.tool.autoLinkEntity(ctx, name: "Dana Ivar", contact: nil)
        _ = try await file.addPerson(caseID: r.caseA, name: "Dana Ivar", role: .subject, entityID: entity, contact: nil, notes: nil, actor: "analyst")
        let ambiguous = try await r.tool.autoLinkEntity(ctx, name: "Sam Lee", contact: nil)
        _ = try await file.addPerson(caseID: r.caseA, name: "Sam Lee", role: .witness, entityID: ambiguous, contact: nil, notes: nil, actor: "analyst")
        let people = try await file.people(caseID: r.caseA)
        #expect(people.first { $0.name == "Dana Ivar" }?.entityID == r.dana)
        #expect(people.first { $0.name == "Sam Lee" }?.entityID == nil)
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
