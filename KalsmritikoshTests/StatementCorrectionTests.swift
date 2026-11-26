//
//  StatementCorrectionTests.swift
//  KalsmritikoshTests
//
//  Implementation brief §9: a confirmed statement is never edited. Its person, recording, transcript
//  and when/how/where are locked; a correction is an append-only addendum linked to it, with its own
//  fingerprint and reason, confirmed at most once, and shown with the statement when it is exported.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Confirmed statements are corrected by addenda, never edited")
struct StatementCorrectionTests {

    struct Rig {
        let db: Database
        let svc: CaseFileService
        let caseID: UUID
        let interviewID: UUID
        let other: UUID
    }

    static func rig() async throws -> Rig {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let workspaces = WorkspaceRepository(database: db)
        let ws = Workspace(title: "WS")
        try await workspaces.upsert(ws)
        let cases = InvestigationCaseRepository(database: db)
        let c = try await cases.createCase(workspaceID: ws.id, title: "Complaint", actor: "Ada", at: Date())
        let svc = CaseFileService(database: db, cases: cases, workspaces: workspaces)
        let person = try await svc.file.addPerson(caseID: c.id, name: "Bea", role: .witness, entityID: nil, contact: nil, notes: nil, actor: "Ada")
        let other = try await svc.file.addPerson(caseID: c.id, name: "Cal", role: .witness, entityID: nil, contact: nil, notes: nil, actor: "Ada")
        let iv = try await svc.file.addInterview(caseID: c.id, personID: person, questions: nil, actor: "Ada")
        var interview = try #require(try await svc.file.interview(id: iv))
        interview.statementText = "I saw the transfer on Monday."
        interview.location = "Room 4"
        try await svc.file.updateInterview(interview, actor: "Ada")
        return Rig(db: db, svc: svc, caseID: c.id, interviewID: iv, other: other)
    }

    @Test("Before confirmation a statement takes no addendum; after it, provenance fields are locked")
    func lockedAfterConfirmation() async throws {
        let r = try await Self.rig()
        await #expect(throws: CaseFileError.notAttested) {
            try await r.svc.file.addStatementAddendum(caseID: r.caseID, interviewID: r.interviewID, text: "x", reason: "y", actor: "Ada")
        }
        try await r.svc.file.attest(interviewID: r.interviewID, caseID: r.caseID, attestedBy: "Bea", actor: "Ada")
        let confirmed = try #require(try await r.svc.file.interview(id: r.interviewID))
        var moved = confirmed; moved.personID = r.other
        await #expect(throws: CaseFileError.attestedFieldLocked("interviewee")) { try await r.svc.file.updateInterview(moved, actor: "Ada") }
        var relocated = confirmed; relocated.location = "Room 9"
        await #expect(throws: CaseFileError.attestedFieldLocked("location")) { try await r.svc.file.updateInterview(relocated, actor: "Ada") }
        var rerecorded = confirmed; rerecorded.recordingRef = "other-recording"
        await #expect(throws: CaseFileError.attestedFieldLocked("recording")) { try await r.svc.file.updateInterview(rerecorded, actor: "Ada") }
        // The investigator's own summary is still theirs to write.
        var summarised = confirmed; summarised.summary = "Saw the transfer."
        try await r.svc.file.updateInterview(summarised, actor: "Ada")
        let after = try #require(try await r.svc.file.interview(id: r.interviewID))
        #expect(after.personID == confirmed.personID && after.location == "Room 4" && after.statementIntact)
    }

    @Test("A correction is linked, fingerprinted, confirmed once, append-only, and exported with the statement")
    func addendumLifecycle() async throws {
        let r = try await Self.rig()
        try await r.svc.file.attest(interviewID: r.interviewID, caseID: r.caseID, attestedBy: "Bea", actor: "Ada")
        let id = try await r.svc.file.addStatementAddendum(caseID: r.caseID, interviewID: r.interviewID,
                                                           text: "It was Tuesday, not Monday.", reason: "Interviewee checked her diary", actor: "Ada")
        try await r.svc.file.confirmAddendum(caseID: r.caseID, id: id, confirmedBy: "Bea", actor: "Ada")
        await #expect(throws: CaseFileError.addendumAlreadyConfirmed) {
            try await r.svc.file.confirmAddendum(caseID: r.caseID, id: id, confirmedBy: "Someone else", actor: "Ada")
        }
        let addenda = try await r.svc.file.addenda(caseID: r.caseID)
        #expect(addenda.count == 1 && addenda[0].intact && addenda[0].confirmedBy == "Bea")
        // The ledger itself refuses rewriting a correction.
        await #expect(throws: (any Error).self) {
            try await r.db.exec("UPDATE case_statement_addenda SET text = 'Monday after all';")
        }
        // The confirmed statement is unchanged, and the export shows statement then correction.
        let snap = try #require(try await r.svc.snapshot(caseID: r.caseID, custody: []))
        let iv = try #require(snap.interviews.first { $0.id == r.interviewID })
        #expect(iv.statementText == "I saw the transfer on Monday." && iv.statementIntact)
        let doc = CaseFileDocuments.statement(snap, interview: iv, by: "Ada")
        let statementAt = try #require(doc.range(of: "I saw the transfer on Monday."))
        let correctionAt = try #require(doc.range(of: "It was Tuesday, not Monday."))
        #expect(statementAt.lowerBound < correctionAt.lowerBound)
        #expect(doc.contains("Reason: Interviewee checked her diary") && doc.contains("Confirmed by Bea"))
        // Both acts are in the case log.
        let actions = try await r.svc.file.actions(caseID: r.caseID).map(\.action)
        #expect(actions.contains("statementCorrected") && actions.contains("correctionConfirmed"))
    }
}
