//
//  CaseRequestDeliveryTests.swift
//  KalsmritikoshTests
//
//  Case plan 2026-11-16 (ADAPT-10, local part): a request's delivery is prepared once, handed over by the person, and
//  confirmed — a copied or prepared draft is never shown as sent, and a second hand-over waits for the first's outcome.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Evidence request delivery — prepared, handed over, confirmed", .serialized)
struct CaseRequestDeliveryTests {

    @Test("Prepared is not sent; one delivery however often prepared; a second hand-over waits; confirmed sent is final")
    func deliveryStates() async throws {
        let f = try await CaseFileTests.fixture(title: "Statements for account 3391")
        let auto = CaseAutomationService(database: f.db, caseFiles: f.svc, aiPermitted: { _ in false })
        let analysis = InvestigationAnalysisRepository(database: f.db)
        _ = try await analysis.createRequest(caseID: f.caseID, details: EvidenceRequestDetails(description: "Statements for account 3391, March 2026",
                                                                                               custodian: "Western Coast Bank"), actor: "Ada", at: Date())
        let file = try #require(try await analysis.requestFiles(caseID: f.caseID).first)
        #expect(CaseRequestDelivery.line(nil).contains("not recorded as sent"))
        let e1 = try await auto.prepareRequestDelivery(caseID: f.caseID, request: file, channel: "letter", text: "Dear Sir…", actor: "Ada")
        let e2 = try await auto.prepareRequestDelivery(caseID: f.caseID, request: file, channel: "letter", text: "Dear Sir…", actor: "Ada")
        #expect(e1.id == e2.id && e1.state == .prepared, "preparing again changes nothing")
        #expect(CaseRequestDelivery.line(e1).contains("not handed over"))
        try await auto.markHandedOver(caseID: f.caseID, effectID: e1.id, providerRef: "RM123", actor: "Ada")
        await #expect(throws: CaseAutomationError.outcomeUnknown) {
            try await auto.markHandedOver(caseID: f.caseID, effectID: e1.id, providerRef: nil, actor: "Ada")
        }
        var now = try #require(try await auto.requestDelivery(caseID: f.caseID, request: file.request))
        #expect(now.state == .handedOver && CaseRequestDelivery.line(now).contains("not yet known"))
        try await auto.reconcileExternalEffect(caseID: f.caseID, effectID: e1.id, sent: true, note: "Bank acknowledged on 5 Nov", actor: "Ada")
        now = try #require(try await auto.requestDelivery(caseID: f.caseID, request: file.request))
        #expect(now.state == .confirmedSent)
        await #expect(throws: CaseAutomationError.alreadySent) {
            try await auto.markHandedOver(caseID: f.caseID, effectID: e1.id, providerRef: nil, actor: "Ada")
        }
    }

    @Test("A request with no custodian cannot be prepared for sending")
    func needsCustodian() async throws {
        let f = try await CaseFileTests.fixture(title: "No custodian")
        let auto = CaseAutomationService(database: f.db, caseFiles: f.svc, aiPermitted: { _ in false })
        let analysis = InvestigationAnalysisRepository(database: f.db)
        _ = try await analysis.createRequest(caseID: f.caseID, hypothesisID: nil, description: "The rota", actor: "Ada", at: Date())
        let file = try #require(try await analysis.requestFiles(caseID: f.caseID).first)
        await #expect(throws: (any Error).self) {
            _ = try await auto.prepareRequestDelivery(caseID: f.caseID, request: file, channel: "letter", text: "x", actor: "Ada")
        }
    }
}
