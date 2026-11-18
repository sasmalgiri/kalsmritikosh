//
//  CaseScreensRenderTests.swift
//  KalsmritikoshTests
//
//  Background screen evidence (2026-11-18): the screens added for the case-methods plan, drawn off-screen with the app's
//  real state on a temporary ledger — the AppState the app boots, its services, a case with documents, people, a team
//  and money — in an NSHostingView inside a borderless window that is never shown. Each screen's own loading runs; the
//  picture is written to docs/evidence/case-screens-2026-11-18/ and must have ink. It drives nothing on the shared
//  screen (no clicks, no focus), so it runs beside anything else on this Mac. It is not an interactive walk: it shows the
//  screens render with real records, not that a person can operate them.
//

import Foundation
import SwiftUI
import AppKit
import Testing
@testable import Kalsmritikosh

@MainActor
@Suite("Case screens drawn off-screen with real records (background evidence)", .serialized)
struct CaseScreensRenderTests {

    /// The test host is sandboxed: pictures go to its own temporary folder, and each path is printed ("CASE-SCREEN name
    /// path") so they can be copied into docs/evidence/case-screens-2026-11-18/.
    static let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("case-screens", isDirectory: true)

    /// Draw `view` with the app state in an off-screen window, letting its loading run first, and write NAME.png.
    static func render<V: View>(_ name: String, _ view: V, state: AppState, width: CGFloat = 860, height: CGFloat = 1100) async throws -> Int {
        let host = NSHostingView(rootView: view.environment(state).frame(width: width, height: height, alignment: .topLeading))
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = frame
        // The screen's own .task loads run on the main actor; give them time, laying out between.
        for _ in 0..<12 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
        }
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 0 }
        host.cacheDisplay(in: host.bounds, to: rep)
        window.contentView = nil
        window.close()
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        if let png = rep.representation(using: .png, properties: [:]) {
            let url = outDir.appendingPathComponent(name + ".png")
            try png.write(to: url)
            // The shell cannot read the sandbox folder: the picture also goes to the test log, base64 in numbered lines
            // ("CASE-SCREEN-B64 name n data"), and scripts rebuild it into docs/evidence.
            let b64 = png.base64EncodedString()
            var i = 0, n = 0
            while i < b64.count {
                let start = b64.index(b64.startIndex, offsetBy: i), end = b64.index(start, offsetBy: min(4_000, b64.count - i))
                print("CASE-SCREEN-B64 \(name) \(n) \(b64[start..<end])")
                i += 4_000; n += 1
            }
        }
        guard let cg = rep.cgImage else { return 0 }
        return S17.inked(cg)
    }

    @Test("The new case tools, drawn with a case's real people, team, money and documents")
    func caseTools() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("screens-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let state = AppState(bookmarks: BookmarkStore(ephemeral: true))
        await state.boot(databaseURL: temp.appendingPathComponent("ledger.sqlite"))
        let db = try #require(state.database)
        let cases = try #require(state.investigationCases)
        let svc = try #require(state.caseFiles)
        let ws = UUID(), now = Date()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(ws), .text("Supplier payments"), .date(now), .date(now)])
        let c = try await cases.createCase(workspaceID: ws, title: "Was the supplier paid twice for invoice INV-2041?", actor: "Ada", at: now).id
        let stmt = try await CaseFileTestSources.seedPassage(db, cases: cases, caseID: c, name: "bank-statement-7718-march.md",
                                                             text: "Statement 7718. 5 March 2026: debit INR 10,000 to Dalmia Traders, ref INV-2041. 19 March 2026: refund INR 2,000.")
        _ = try await CaseFileTestSources.seedPassage(db, cases: cases, caseID: c, name: "statement-asha-rao.md",
                                                      text: "Asha Rao said Vikram Rao approved the second payment on 9 March 2026.")
        let file = svc.file
        // People in the case
        let ravi: UUID
        switch try await file.addPersonOrRole(caseID: c, name: "Vikram Rao", role: .witness, context: "approver of payments", entityID: nil, actor: "Ada") {
        case .added(let id): ravi = id
        case .roleAdded(let p, _): ravi = p
        }
        _ = try await file.addPersonRole(caseID: c, personID: ravi, role: .accountHolder, context: "account ending 7718", actor: "Ada")
        _ = try await file.addPersonAttribute(caseID: c, personID: ravi, kind: .organisation, value: "Dalmia Traders (accounts)", origin: .source,
                                              sourceVersionID: stmt.version, quote: "Dalmia Traders", actor: "Ada")
        _ = try await file.addPersonAttribute(caseID: c, personID: ravi, kind: .background, value: "Joined in 2019", origin: .supplied, suppliedBy: "HR file", actor: "Ada")
        _ = try await file.recordLocationObservation(caseID: c, personID: ravi, place: "Pune office", observedFrom: now.addingTimeInterval(-9 * 86_400),
                                                     timePrecision: .day, placePrecision: .street, basis: .source, sourceVersionID: stmt.version,
                                                     uncertainty: "visitor log time not checked", actor: "Ada", at: now)
        // Team and work
        _ = try await file.addTeamMember(caseID: c, member: "Ada", role: .lead, actor: "Ada")
        _ = try await file.addTeamMember(caseID: c, member: "Ben", role: .investigator, actor: "Ada")
        _ = try await file.declareCapability(investigator: "Ben", capability: "Financial analysis", basis: "CA certificate supplied", actor: "Ada")
        // Money
        let acct = try await file.addMoneyAccount(caseID: c, identifier: "7718", institution: "City Bank", actor: "Ada")
        let st = try await file.addMoneyStatement(caseID: c, accountID: acct, periodStart: "2026-03-01", periodEnd: "2026-03-31", opening: nil, closing: nil,
                                                  currency: "INR", actor: "Ada")
        _ = try await file.importStatementRows(caseID: c, statementID: st, text: "Date,Description,Reference,Debit,Credit\n2026-03-05,Dalmia Traders,INV-2041,\"10,000.00\",\n2026-03-19,Refund,INV-2041,,\"2,000.00\"\n", actor: "Ada")
        _ = try await file.recordConversionRate(caseID: c, from: "INR", to: "EUR", rate: "0.011", rateDate: "2026-03-05", rateSource: "ECB reference rate",
                                                method: "rate on the payment day", actor: "Ada")
        _ = try await file.recordAccountRelation(caseID: c, accountID: acct, holderName: "Vikram Rao", relation: .signatory, basis: .supplied, suppliedBy: "bank letter", actor: "Ada")
        _ = try await file.syncMoneyGapProposals(caseID: c, actor: "Ada")

        var ink: [String: Int] = [:]
        ink["people-in-the-case"] = try await Self.render("people-in-the-case", ScrollView { CasePeopleInCaseTool(caseID: c, actor: "Ada").padding(16) }, state: state)
        ink["team-and-work"] = try await Self.render("team-and-work", ScrollView { CaseTeamWorkTool(caseID: c, actor: "Ada").padding(16) }, state: state)
        ink["closing-and-reopening"] = try await Self.render("closing-and-reopening", ScrollView { CaseMapClosingTool(caseID: c, actor: "Ada", service: nil).padding(16) }, state: state)
        ink["money"] = try await Self.render("money", ScrollView { CaseMoneyTool(caseID: c, actor: "Ada").padding(16) }, state: state, height: 2200)
        ink["history-set"] = try await Self.render("history-set", ScrollView { CaseHistorySetTool(caseID: c, actor: "Ada").padding(16) }, state: state)
        let model = CaseFileModel(caseID: c, workspaceID: ws)
        ink["tools-panel"] = try await Self.render("tools-panel", CaseMapToolsPanel(model: model, projection: nil, service: nil, tool: .casePeople, close: {}), state: state, width: 860, height: 600)
        for (name, n) in ink.sorted(by: { $0.key < $1.key }) { #expect(n > 2_000, "\(name) drew almost nothing (\(n))") }
        await state.shutdown()
    }
}
