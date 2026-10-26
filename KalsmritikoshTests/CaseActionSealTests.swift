//
//  CaseActionSealTests.swift
//  KalsmritikoshTests
//
//  Implementation brief §5 (P0): the case-action log is append-only (UPDATE and DELETE refused by
//  the ledger itself) and every action since the v153 seal boundary is an audit-chain event.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Case-action log sealed")
struct CaseActionSealTests {

    @Test("UPDATE and DELETE on case_actions are refused; actions are audit-chain events")
    func appendOnlyAndChained() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let workspaces = WorkspaceRepository(database: db)
        let ws = Workspace(title: "WS")
        try await workspaces.upsert(ws)
        let cases = InvestigationCaseRepository(database: db)
        let c = try await cases.createCase(workspaceID: ws.id, title: "Case", actor: "Ada", at: Date())
        let file = CaseFileService(database: db, cases: cases, workspaces: workspaces).file
        _ = try await file.addAllegation(caseID: c.id, text: "Shouting", actor: "Ada")
        await #expect(throws: (any Error).self) { try await db.exec("UPDATE case_actions SET actor = 'Mallory';") }
        await #expect(throws: (any Error).self) { try await db.exec("DELETE FROM case_actions;") }
        #expect(try await file.actions(caseID: c.id).first?.actor == "Ada")
        let events = try await file.auditChainEvents()
        #expect(events.count == 1)
        #expect(events.first?.source == .caseAction)
        #expect(events.first?.canonicalPayload.contains("action=") == true)
        #expect(events.first?.canonicalPayload.contains("Shouting") == false)   // detail enters as a digest
    }
}
