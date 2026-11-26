//
//  CaseOwnershipTests.swift
//  KalsmritikoshTests
//
//  Implementation brief §3 (P0): every mutation guarded by case A that names a child record of
//  case B is refused — without changing either case and without writing a success line to the
//  action log. A closed case takes no new work until reopened; an attestation of a statement that
//  changed in between is refused.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Case ownership on every mutation")
struct CaseOwnershipTests {

    struct Two {
        let db: Database
        let file: CaseFileRepository
        let cases: InvestigationCaseRepository
        let a: UUID, b: UUID
    }

    static func two() async throws -> Two {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let workspaces = WorkspaceRepository(database: db)
        let ws = Workspace(title: "WS")
        try await workspaces.upsert(ws)
        let cases = InvestigationCaseRepository(database: db)
        let a = try await cases.createCase(workspaceID: ws.id, title: "Case A", actor: "Ada", at: Date())
        let b = try await cases.createCase(workspaceID: ws.id, title: "Case B", actor: "Ada", at: Date())
        let svc = CaseFileService(database: db, cases: cases, workspaces: workspaces)
        return Two(db: db, file: svc.file, cases: cases, a: a.id, b: b.id)
    }

    func actionCount(_ t: Two, _ caseID: UUID) async throws -> Int {
        try await t.file.actions(caseID: caseID).count
    }

    @Test("Case A cannot touch case B's allegation, evidence link, person, interview, exhibit, hold or batch")
    func crossCaseRefused() async throws {
        let t = try await Self.two()
        let allegationB = try await t.file.addAllegation(caseID: t.b, text: "B's allegation", actor: "Ada")
        let sourceB = try #require(try await CaseFileTestSources.inScope(t.db, cases: t.cases, caseID: t.b).first)
        try await t.file.addAllegationEvidence(caseID: t.b, allegationID: allegationB, evidenceRef: sourceB, label: nil, stance: .supports, note: nil, actor: "Ada")
        let linkB = try #require(try await t.file.allegationEvidence(caseID: t.b).first).id
        let personB = try await t.file.addPerson(caseID: t.b, name: "Bea", role: .witness, entityID: nil, contact: nil, notes: nil, actor: "Ada")
        let interviewB = try await t.file.addInterview(caseID: t.b, personID: personB, questions: nil, actor: "Ada")
        var iv = try #require(try await t.file.interview(id: interviewB))
        iv.statementText = "I saw it."
        try await t.file.updateInterview(iv, actor: "Ada")
        let journalB = try await t.file.addJournal(caseID: t.b, kind: .note, text: "B note", eventDate: nil, evidenceRef: nil, actor: "Ada")
        _ = try await t.file.addExhibit(caseID: t.b, number: nil, description: "B exhibit", sourceRef: nil, sha256: nil, collectedBy: nil, collectedAt: nil, collectedWhere: nil, actor: "Ada")
        let exhibitB = try #require(try await t.file.exhibits(caseID: t.b).first).id
        try await t.file.issueHold(caseID: t.b, custodian: "IT", personID: nil, noticeText: "Keep it", reminderDue: nil, actor: "Ada")
        let holdB = try #require(try await t.file.holdNotices(caseID: t.b).first).id
        _ = try await t.file.createBatches(caseID: t.b, sourceRefs: [sourceB], size: 5, reviewer: "Ada", actor: "Ada")
        let batchB = try #require(try await t.file.reviewBatches(caseID: t.b).first).id

        let beforeA = try await actionCount(t, t.a), beforeB = try await actionCount(t, t.b)
        let attempts: [() async throws -> Void] = [
            { try await t.file.addAllegationEvidence(caseID: t.a, allegationID: allegationB, evidenceRef: "note:A says otherwise", label: nil, stance: .contradicts, note: nil, actor: "Ada") },
            { try await t.file.decide(allegationID: allegationB, caseID: t.a, disposition: .substantiated, rationale: "x", actor: "Ada") },
            { try await t.file.retractAllegationEvidence(caseID: t.a, id: linkB, actor: "Ada") },
            { try await t.file.retractJournal(caseID: t.a, id: journalB, actor: "Ada") },
            { try await t.file.retractPerson(caseID: t.a, id: personB, actor: "Ada") },
            { try await t.file.addContact(caseID: t.a, personID: personB, at: Date(), mode: "phone", note: nil, actor: "Ada") },
            { _ = try await t.file.addInterview(caseID: t.a, personID: personB, questions: nil, actor: "Ada") },
            { try await t.file.attest(interviewID: interviewB, caseID: t.a, attestedBy: "Bea", actor: "Ada") },
            { try await t.file.addCredibility(caseID: t.a, interviewID: interviewB, factor: CredibilityFactor.allCases[0], assessment: CredibilityAssessment.allCases[0], note: nil, evidenceRef: nil, actor: "Ada") },
            { try await t.file.withdrawExhibit(caseID: t.a, id: exhibitB, actor: "Ada") },
            { try await t.file.acknowledgeHold(caseID: t.a, id: holdB, acknowledgedAt: Date(), actor: "Ada") },
            { try await t.file.releaseHold(caseID: t.a, id: holdB, reason: "done", actor: "Ada") },
            { try await t.file.advanceBatch(caseID: t.a, id: batchB, to: ReviewBatchStatus.allCases[1], qcNote: nil, actor: "Bob") },
        ]
        for attempt in attempts {
            await #expect(throws: CaseFileError.self) { try await attempt() }
        }
        // Nothing changed in either case, and no success was logged.
        #expect(try await actionCount(t, t.a) == beforeA)
        #expect(try await actionCount(t, t.b) == beforeB)
        #expect(try await t.file.allegationEvidence(caseID: t.b).count == 1)
        #expect(try await t.file.allegations(caseID: t.b).first?.disposition == .pending)
        #expect(try await t.file.interview(id: interviewB)?.status != .attested)
        #expect(try await t.file.exhibits(caseID: t.b).count == 1)
    }

    @Test("Evidence references resolve in the case: in-scope sources, live exhibits, labelled notes; the rest is queued for repair")
    func referencesResolve() async throws {
        let t = try await Self.two()
        let allegation = try await t.file.addAllegation(caseID: t.a, text: "A's allegation", actor: "Ada")
        let inA = try #require(try await CaseFileTestSources.inScope(t.db, cases: t.cases, caseID: t.a).first)
        let inB = try #require(try await CaseFileTestSources.inScope(t.db, cases: t.cases, caseID: t.b).first)
        let nowhere = try await CaseFileTestSources.seed(t.db).uuidString
        func link(_ ref: String) async throws {
            try await t.file.addAllegationEvidence(caseID: t.a, allegationID: allegation, evidenceRef: ref, label: nil, stance: .supports, note: nil, actor: "Ada")
        }
        try await link(inA)
        try await link("note:The manager told me in person")
        let exhibit = try await t.file.addExhibit(caseID: t.a, number: nil, description: "Laptop", sourceRef: nil, sha256: nil,
                                                  collectedBy: nil, collectedAt: nil, collectedWhere: nil, actor: "Ada")
        try await link("exhibit:\(exhibit)")
        // Another case's source, a source in no case, a missing exhibit and free text are refused — no scope widening.
        for bad in [inB, nowhere, "exhibit:EX-999", "doc-1", UUID().uuidString] {
            await #expect(throws: CaseFileError.self, "\(bad) should be refused") { try await link(bad) }
        }
        // A batch takes only sources; a journal entry's evidence must resolve too.
        await #expect(throws: CaseFileError.self) {
            _ = try await t.file.createBatches(caseID: t.a, sourceRefs: ["note:x"], size: 5, reviewer: "Ada", actor: "Ada")
        }
        await #expect(throws: CaseFileError.self) {
            _ = try await t.file.addJournal(caseID: t.a, kind: .note, text: "n", eventDate: nil, evidenceRef: inB, actor: "Ada")
        }
        #expect(try await t.file.allegationEvidence(caseID: t.a).count == 3)
        #expect(try await t.file.unresolvedReferences(caseID: t.a).isEmpty)
        // A legacy free-text row (written before references were checked) and a source taken out of
        // scope are listed for repair, as written.
        try await t.db.exec("INSERT INTO case_journal (id, case_id, entry_kind, event_date, text, evidence_ref, author, created_at) VALUES (?,?,?,?,?,?,?,?);",
                            [.uuid(UUID()), .uuid(t.a), .text("note"), .null, .text("old"), .text("the blue folder"), .text("Ada"), .real(1)])
        let header = try #require(try await t.cases.fetch(caseID: t.a)).caseHeader
        _ = try await t.cases.excludeSource(caseID: t.a, expectedRevision: header.revision, sourceRef: inA, sourceKind: .sourceVersion,
                                            note: "wrong custodian", actor: "Ada", at: Date())
        let queue = try await t.file.unresolvedReferences(caseID: t.a)
        #expect(queue.contains { $0.ref == "the blue folder" && $0.record == "Journal" })
        #expect(queue.contains { $0.ref == inA && $0.problem.contains("not in this case's scope") })
    }

    @Test("A closed case takes no new work until it is reopened")
    func closedCase() async throws {
        let t = try await Self.two()
        try await t.file.markClosed(caseID: t.a, reopened: false, actor: "Ada")
        await #expect(throws: CaseFileError.caseClosed) {
            _ = try await t.file.addAllegation(caseID: t.a, text: "late", actor: "Ada")
        }
        // Recording a read or export of a closed case is still allowed.
        try await t.file.logAction(caseID: t.a, action: "viewed", detail: nil, actor: "Ada")
        try await t.file.markClosed(caseID: t.a, reopened: true, actor: "Ada")
        _ = try await t.file.addAllegation(caseID: t.a, text: "after reopening", actor: "Ada")
    }
}
