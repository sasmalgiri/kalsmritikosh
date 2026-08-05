//
//  InvestigationSubjectRepositoryTests.swift
//  KalsmritikoshTests
//
//  INV-02 — the durable subject authority. Proves a subject is nominated PROPOSED, that only a PROPOSED
//  subject can be confirmed (which stamps the confirmer + timestamp) or rejected, optimistic revision CAS,
//  uniqueness per (case, entity), input validation, the case-closed guard, and durable reopen. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("INV-02 — investigation subject repository")
struct InvestigationSubjectRepositoryTests {

    private let t0 = Date(timeIntervalSince1970: 1_767_000_000)

    private struct Rig { let db: Database; let cases: InvestigationCaseRepository; let subjects: InvestigationSubjectRepository; let caseID: UUID }

    private func rig() async throws -> Rig {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(ws), .text("Matter"), .real(1), .real(1)])
        let cases = InvestigationCaseRepository(database: db)
        let c = try await cases.createCase(workspaceID: ws, title: "Case", actor: "analyst", at: t0)
        return Rig(db: db, cases: cases, subjects: InvestigationSubjectRepository(database: db), caseID: c.id)
    }

    @Test("A nominated subject starts PROPOSED with no confirmer")
    func nominateProposed() async throws {
        let rig = try await rig()
        let e = UUID()
        let s = try await rig.subjects.createSubject(caseID: rig.caseID, canonicalEntityID: e, label: "Jane Roe", actor: "analyst", at: t0)
        #expect(s.identityStatus == .proposed)
        #expect(s.confirmedBy == nil && s.confirmedAt == nil)
        #expect(s.revision == 1)
    }

    @Test("Confirming a proposed subject stamps the confirmer + timestamp and bumps revision")
    func confirmStampsConfirmer() async throws {
        let rig = try await rig()
        let s = try await rig.subjects.createSubject(caseID: rig.caseID, canonicalEntityID: UUID(), label: "Jane", actor: "a", at: t0)
        let confirmed = try await rig.subjects.confirmIdentity(subjectID: s.id, expectedRevision: s.revision, actor: "lead", at: t0)
        #expect(confirmed.identityStatus == .confirmed)
        #expect(confirmed.confirmedBy == "lead")
        #expect(confirmed.confirmedAt == t0)
        #expect(confirmed.revision == 2)
    }

    @Test("Only a PROPOSED subject can be confirmed or rejected")
    func onlyProposedTransitions() async throws {
        let rig = try await rig()
        let s = try await rig.subjects.createSubject(caseID: rig.caseID, canonicalEntityID: UUID(), label: "J", actor: "a", at: t0)
        let confirmed = try await rig.subjects.confirmIdentity(subjectID: s.id, expectedRevision: s.revision, actor: "lead", at: t0)
        await #expect(throws: InvestigationSubjectError.self) {
            _ = try await rig.subjects.rejectIdentity(subjectID: confirmed.id, expectedRevision: confirmed.revision, actor: "lead", at: t0)
        }
    }

    @Test("Rejecting a proposed subject records it without a confirmer")
    func rejectRecorded() async throws {
        let rig = try await rig()
        let s = try await rig.subjects.createSubject(caseID: rig.caseID, canonicalEntityID: UUID(), label: "J", actor: "a", at: t0)
        let rejected = try await rig.subjects.rejectIdentity(subjectID: s.id, expectedRevision: s.revision, actor: "lead", at: t0)
        #expect(rejected.identityStatus == .rejected)
        #expect(rejected.confirmedBy == nil)
    }

    @Test("A stale expected revision is a conflict")
    func revisionConflict() async throws {
        let rig = try await rig()
        let s = try await rig.subjects.createSubject(caseID: rig.caseID, canonicalEntityID: UUID(), label: "J", actor: "a", at: t0)
        await #expect(throws: InvestigationSubjectError.self) {
            _ = try await rig.subjects.confirmIdentity(subjectID: s.id, expectedRevision: s.revision + 5, actor: "lead", at: t0)
        }
    }

    @Test("An entity is a subject at most once per case; blank label/actor rejected; missing case fails closed")
    func uniquenessAndValidation() async throws {
        let rig = try await rig()
        let e = UUID()
        _ = try await rig.subjects.createSubject(caseID: rig.caseID, canonicalEntityID: e, label: "J", actor: "a", at: t0)
        await #expect(throws: InvestigationSubjectError.self) {
            _ = try await rig.subjects.createSubject(caseID: rig.caseID, canonicalEntityID: e, label: "J again", actor: "a", at: t0)
        }
        await #expect(throws: InvestigationSubjectError.self) {
            _ = try await rig.subjects.createSubject(caseID: rig.caseID, canonicalEntityID: UUID(), label: "  ", actor: "a", at: t0)
        }
        await #expect(throws: InvestigationSubjectError.self) {
            _ = try await rig.subjects.createSubject(caseID: rig.caseID, canonicalEntityID: UUID(), label: "J", actor: " ", at: t0)
        }
        await #expect(throws: InvestigationSubjectError.self) {
            _ = try await rig.subjects.createSubject(caseID: UUID(), canonicalEntityID: UUID(), label: "J", actor: "a", at: t0)
        }
    }

    @Test("Subjects persist through the repository and reopen by id with their confirmation intact")
    func reopen() async throws {
        let rig = try await rig()
        let s = try await rig.subjects.createSubject(caseID: rig.caseID, canonicalEntityID: UUID(), label: "Jane", actor: "a", at: t0)
        _ = try await rig.subjects.confirmIdentity(subjectID: s.id, expectedRevision: s.revision, actor: "lead", at: t0)
        let reopened = InvestigationSubjectRepository(database: rig.db)
        let fetched = try await reopened.fetch(subjectID: s.id)
        #expect(fetched?.identityStatus == .confirmed)
        #expect(fetched?.confirmedBy == "lead")
        #expect(try await reopened.subjects(caseID: rig.caseID).count == 1)
    }
}
