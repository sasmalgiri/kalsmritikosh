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
        // The chain accepts and seals it (the chain table once refused every source but three).
        let chain = AuditChainService(database: db, secret: Data("test-secret".utf8), eventProvider: { try await file.auditChainEvents() })
        #expect(try await chain.seal() == 1)
        #expect(try await chain.verify().isIntact)
    }

    @Test("Case events and findings approvals are fixed once written and sealed; removing one breaks the chain")
    func caseHistorySealed() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let workspaces = WorkspaceRepository(database: db)
        let ws = Workspace(title: "WS")
        try await workspaces.upsert(ws)
        let cases = InvestigationCaseRepository(database: db)
        let c = try await cases.createCase(workspaceID: ws.id, title: "Case", actor: "Ada", at: Date())
        let source = try await CaseFileTestSources.seed(db)
        _ = try await cases.includeSource(caseID: c.id, expectedRevision: c.revision, sourceRef: source.uuidString,
                                          sourceKind: .sourceVersion, actor: "Ada", at: Date())
        let approvals = InvestigationFindingsApprovalRepository(database: db)
        _ = try await approvals.approve(caseID: c.id, workProductRunID: UUID(), receiptSeal: "seal",
                                        scopeFingerprint: CaseScopeFingerprint(value: String(repeating: "a", count: 64)),
                                        rationale: "Standard of proof applied: Preponderance.", actor: "Ada", at: Date())
        // Edits in place are refused by the ledger.
        await #expect(throws: (any Error).self) { try await db.exec("UPDATE investigation_case_events SET actor = 'Mallory';") }
        await #expect(throws: (any Error).self) { try await db.exec("UPDATE investigation_findings_approvals SET rationale = 'none';") }
        // Both histories are chain events: source membership (with its digest, not its text) and the approval.
        let caseEvents = try await cases.auditChainEvents()
        let approvalEvents = try await approvals.auditChainEvents()
        #expect(caseEvents.contains { $0.source == .caseEvent && $0.canonicalPayload.contains("action=sourceIncluded") })
        #expect(approvalEvents.count == 1 && approvalEvents[0].source == .findingsApproval)
        let chain = AuditChainService(database: db, secret: Data("test-secret".utf8), eventProvider: {
            (try await cases.auditChainEvents()) + (try await approvals.auditChainEvents())
        })
        _ = try await chain.seal()
        #expect(try await chain.verify().isIntact)
        // Deleting a sealed source-membership event (which the update guard does not block) is detected.
        try await db.exec("DELETE FROM investigation_case_events WHERE action = 'sourceIncluded';")
        #expect(try await chain.verify().isIntact == false)
    }
}
