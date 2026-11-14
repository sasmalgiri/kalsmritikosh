//
//  SmartMapAcceptanceJourneyTests.swift
//  KalsmritikoshTests
//
//  Smart-map S13 (QA, milestone M6): the decisive acceptance journey of docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md
//  §G, as ONE service-level test over the supplier fixture INV-104, AI off, no network, on a throwaway ledger booted through
//  AppState (real intake). The money, report and identity expectations come from the hand-written answer key
//  Resources/Fixtures/AcceptanceSupplierINV104/inv104-expected-results.json; the expectations for the later steps
//  (history, review case, restore) are written by hand below from the fixture's documents, never read back from the code.
//
//  Steps of §G that need real team accounts (authenticated distinct users) or a model are NOT faked: each is a recorded
//  skip with its reason (printed as JOURNEY_SKIP lines and checked). The local-role variants that the code supports
//  are exercised in the second test, with the hostile/failure variants the TODO lists that are feasible on one Mac.
//  Dates that matter are built in UTC (CI runs in UTC; this Mac may not).
//

import CryptoKit
import Foundation
import Testing
@testable import Kalsmritikosh

@MainActor
private func journeyDefaults() -> UserDefaults {
    let name = "casemap.journey.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name) ?? .standard
    d.removePersistentDomain(forName: name)
    return d
}

private enum Journey {
    static var fixtureFolder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Kalsmritikosh/Resources/Fixtures/\(SupplierINV104Fixture.folderName)", isDirectory: true)
    }
    static func key() throws -> [String: Any] {
        let data = try Data(contentsOf: fixtureFolder.appendingPathComponent(SupplierINV104Fixture.expectedName))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    static func dec(_ s: String?) -> Decimal? { s.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) } }
    static func count(_ db: Database, _ sql: String, _ binds: [SQLValue] = []) async throws -> Int { Int(try await db.query(sql, binds).first?.int(0) ?? -1) }
    static let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC") ?? .gmt; return c }()
    static func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int) -> Date { utc.date(from: DateComponents(year: y, month: m, day: d, hour: h)) ?? Date(timeIntervalSince1970: 0) }
    static func sha(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }

    /// A §G step that cannot be run honestly here, with the reason.
    struct Skip: CustomStringConvertible {
        let step: Int
        let reason: String
        var description: String { "JOURNEY_SKIP step \(step): \(reason)" }
    }
}

@MainActor
@Suite("Smart map S13 — the decisive acceptance journey (TODO §G), AI off", .serialized)
struct SmartMapAcceptanceJourneyTests {

    @Test("§G journey over INV-104, AI off: intake → brief → report/point/question/action/result/deeper point → conflicting accounts → money → amendment and source change → history and prior case → solo self-review → brief, search with receipt → retries and budget stop → close → export through the output door with read-back → backup, erase, restore without resurrection → reopen")
    func decisiveJourney() async throws {
        let key = try Journey.key()
        var skips: [Journey.Skip] = []
        let actor = "Priya Nair"

        // ── Step 1: create the mother case and import the mixed material ─────────────────────────────────────────
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("journey-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let files = try SupplierINV104Fixture.materialise(from: Journey.fixtureFolder, into: temp.appendingPathComponent("documents", isDirectory: true))
        let state = AppState(bookmarks: BookmarkStore(ephemeral: true))
        let ledgerURL = temp.appendingPathComponent("ledger.sqlite")
        await state.boot(databaseURL: ledgerURL)
        let ingest = try #require(state.ingest)
        let db = try #require(state.database)

        var versions: [String: UUID] = [:], logical: [String: UUID] = [:], fileIDs: [String: UUID] = [:]
        for name in SupplierINV104Fixture.documentNames {
            let r = try await ingest.ingest(fileAt: try #require(files[name]))
            #expect(r.processingStatus != .failed && r.chunkCount > 0, "\(name): \(String(describing: r.processingStatus))")
            versions[name] = r.sourceVersionID; logical[name] = r.logicalSourceID; fileIDs[name] = r.fileRecord.id
        }
        let copy = try await ingest.ingest(fileAt: try #require(files[SupplierINV104Fixture.bankCopy]))
        #expect([SourceIntakeOutcome.aliased, .unchanged, .moved].contains(copy.intakeOutcome ?? .newLogicalSource), "the byte-identical copy is not a new source")
        let scan = try await ingest.ingest(fileAt: try #require(files[SupplierINV104Fixture.scanName]))
        #expect(scan.processingStatus == .failed && scan.chunkCount == 0, "the unreadable scan is a recorded failure")
        var unsupportedState = ""
        var binID: UUID?
        do {
            let bin = try await ingest.ingest(fileAt: try #require(files[SupplierINV104Fixture.unsupportedName]))
            #expect(bin.chunkCount == 0 && bin.processingStatus != .passCompleted && bin.processingStatus != .queryable)
            unsupportedState = bin.processingStatus?.rawValue ?? "no status"
            binID = bin.fileRecord.id
        } catch {
            unsupportedState = "refused: \(error.localizedDescription)"
        }
        #expect(!unsupportedState.isEmpty, "the unsupported attachment has an explicit state")
        // Originals preserved: every processed original's bytes are unchanged on disk (the answer key's hashes).
        for d in try #require(key["documents"] as? [[String: Any]]) {
            guard let name = d["name"] as? String, let sha = d["sha256"] as? String, let url = files[name] else { continue }
            #expect(try Journey.sha(url) == sha, "\(name) was altered by intake")
        }
        #expect(try await Journey.count(db, "SELECT COUNT(*) FROM source_versions WHERE logical_source_id = ?;", [.uuid(try #require(logical[SupplierINV104Fixture.bankStatement]))]) == 1,
                "the copy added no second version of the statement")

        let ws = UUID(), now = Date()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(ws), .text("Northwind / Kestrel"), .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970)])
        let coordinator = try #require(state.workspaceSourceCoordinator)
        // S14 (QA-15): the failed scan (and the unsupported attachment, when the app holds it) is offered and admitted in a
        // "not read" state with its reason; it is never projected or counted as read.
        let offered = try await coordinator.candidates(for: ws)
        #expect(offered.first { $0.fileID == scan.fileRecord.id }?.readState.isRead == false, "the failed scan is offered as not read")
        let added = try await coordinator.addSources(Set(fileIDs.values).union([scan.fileRecord.id]).union(binID.map { [$0] } ?? []), to: ws, at: now)
        #expect(added.added.contains(scan.fileRecord.id) && added.notRead[scan.fileRecord.id]?.isEmpty == false,
                "the failed scan is admitted as not read, with its reason: \(added.notRead)")
        for id in fileIDs.values { #expect(added.added.contains(id) && added.notRead[id] == nil, "a readable document is admitted as read") }
        let binAdmitted = binID.map { added.added.contains($0) } ?? false
        let cases = try #require(state.investigationCases)
        let disc = try #require(key["discrepancy"] as? [String: Any])
        let questionText = try #require(disc["question"] as? String)
        // "Start from a question": the question is the case's purpose and the map's question (HELP-01).
        let mother = try await cases.createCase(workspaceID: ws, title: FirstCaseEntry.title(question: questionText, typed: ""), purpose: questionText, actor: actor, at: now).id
        let intake = try #require(state.investigationWorkspaceIntake)
        let included = try await intake.includeWorkspaceSources(caseID: mother, actor: actor, at: now).included
        #expect(included >= SupplierINV104Fixture.documentNames.count, "every selected processed item is in the case (\(included))")
        let svc = try #require(state.caseFiles)
        let f = CaseFileTests.Fixture(db: db, cases: cases, workspaces: try #require(state.workspaces), svc: svc, workspaceID: ws, caseID: mother)
        let file = f.file
        func node(_ kind: CaseMapRecordKind, _ id: UUID) -> CaseMapNodeID { CaseMapNodeID(caseID: mother, kind: kind, id: id) }
        func projection() async throws -> CaseMapProjection { try #require(await caseMapLoad(f).projection) }
        // Solo: one investigator holds every role, and self-review is disclosed.
        let solo = try #require(try await svc.soloBinding(caseID: mother, actor: actor))
        #expect(solo.person == actor && solo.note.contains("self-review"))
        skips.append(.init(step: 1, reason: "retrying the failed scan after OCR is not run: the scan has no text layer and OCR of a blank page is not part of this fixture"))

        // ── Step 2: the initial brief — purpose, no premature position, no loss total ─────────────────────────────
        let question = try await file.addAllegation(caseID: mother, text: questionText, actor: actor)
        let qn = node(.allegation, question)
        var p = try await projection()
        let brief0 = CaseMapBrief.compute(p, changed: [])
        #expect(brief0.purpose == questionText, "the brief states the case's purpose: \(String(describing: brief0.purpose))")
        #expect((brief0.section("position")?.entries ?? []).isEmpty, "no position before any work")
        #expect(brief0.section("unresolved")?.entries.contains { $0.node == qn } == true, "the question is listed as unresolved")
        #expect(!brief0.allEntries.contains { $0.why.lowercased().contains("loss") }, "no loss is asserted")

        // ── Step 3: report → point → question → action → result → deeper point (and deeper), with exact return ────
        let rk = try #require(key["report"] as? [String: Any])
        let report = try await svc.file.addReport(caseID: mother, CaseReportDetails(
            title: "Forensic accounting report FR-12", sourceVersionID: versions["inv104-forensic-report-FR-12.md"],
            producer: rk["producer"] as? String, author: rk["author"] as? String, examinedMaterial: "Statement 3391; invoice INV-104",
            reportDateText: rk["report_date_text"] as? String, methods: "Matched debits to invoices", limitations: "No timezone in the export"), actor: actor)
        var points: [Int: UUID] = [:]
        var quotes: [Int: String] = [:]
        for pk in try #require(rk["points"] as? [[String: Any]]) {
            let ord = try #require(pk["ordinal"] as? Int), quote = try #require(pk["quote"] as? String)
            quotes[ord] = quote
            points[ord] = try await svc.addPoint(caseID: mother, reportID: report, kind: CaseReportPointKind(rawValue: try #require(pk["kind"] as? String)) ?? .claim,
                                                 statement: quote, quote: quote, actor: actor)
        }
        let p1 = try #require(points[1]), p2 = try #require(points[2])
        let qk = try #require(rk["qualification"] as? [String: Any])
        try await file.addQualification(caseID: mother, pointID: p1, kind: CaseQualificationKind(rawValue: try #require(qk["kind"] as? String)) ?? .uncertainty,
                                        text: "the bank's times have no stated timezone", quote: qk["quote"] as? String, actor: actor)
        // The question is raised from point 2 (the duplicate claim); the parent discrepancy action from the same point.
        _ = try await file.addWorkLink(caseID: mother, work: .allegation, workID: question, target: .point, targetID: p2, role: .raisedFrom,
                                       purpose: "The report says the second debit duplicates the first", actor: actor)
        let ak = try #require(key["actions"] as? [String: Any])
        let parentKey = try #require(ak["parent"] as? [String: Any])
        let childKeys = try #require(ak["children"] as? [[String: Any]])
        let parent = try await svc.createAction(caseID: mother, .init(title: try #require(parentKey["title"] as? String), purpose: "Reconcile the accounts",
                                                                    deliverable: try #require(parentKey["deliverable"] as? String), responsible: actor,
                                                                    fromPoint: p2, servesQuestions: [question]), actor: actor)
        let finKey = try #require(childKeys.first { $0["kind"] as? String == "financial" })
        let talkKey = try #require(childKeys.first { $0["kind"] as? String == "interview" })
        let fin = try await svc.createAction(caseID: mother, .init(title: try #require(finKey["title"] as? String), purpose: "Part of the discrepancy",
                                                                 deliverable: try #require(finKey["deliverable"] as? String), responsible: actor,
                                                                 parentTaskID: parent, servesQuestions: [question]), actor: actor)
        let finResult = try await svc.recordResult(caseID: mother, taskID: fin, title: "Trace of KS-77985", methods: "Purchase ledger and PO file", actor: actor)
        let deeper = try await svc.addPoint(caseID: mother, reportID: finResult, kind: .finding, statement: "KS-77985 settles PO-561 (invoice INV-109), a separate delivery",
                                            quote: nil, actor: actor)
        let talk = try await svc.createAction(caseID: mother, .init(title: try #require(talkKey["title"] as? String), purpose: "Who approved the second payment",
                                                                  deliverable: try #require(talkKey["deliverable"] as? String), responsible: actor,
                                                                  parentTaskID: parent, fromPoint: deeper, servesQuestions: [question]), actor: actor)
        _ = try await file.addDependency(caseID: mother, taskID: talk, dependsOn: fin, reason: "ask about the second PO", actor: actor)
        let talkResult = try await svc.recordResult(caseID: mother, taskID: talk, title: "Re-interview note, Meera Shah", actor: actor)
        let deeper2 = try await svc.addPoint(caseID: mother, reportID: talkResult, kind: .claim, statement: "She does not remember approving KS-77985", quote: nil, actor: actor)
        p = try await projection()
        let path = [node(.report, report), node(.reportPoint, p2), node(.task, parent), node(.task, fin), node(.report, finResult),
                    node(.reportPoint, deeper), node(.task, talk), node(.report, talkResult), node(.reportPoint, deeper2)]
        for n in path { #expect(p.node(n) != nil, "\(n) is on the map") }
        let service = CaseMapService(sources: caseMapSources(f))
        let model = CaseMapWorkspaceModel(caseID: mother, workspace: CaseWorkspaceHolder(caseID: mother, defaults: journeyDefaults()))
        await model.refresh(service)
        model.select(.node(qn))
        let rootViewport = CaseMapViewport(scale: 0.8, originX: -5, originY: 12)
        model.setViewport(rootViewport)
        let rootPlacements = model.placements
        for (i, anchor) in path.enumerated() {
            await model.openFrame(anchor, service: service)
            #expect(model.frameStack.count == i + 1 && model.frame?.anchor == anchor, "frame \(i + 1) opens on \(anchor)")
        }
        #expect(model.frameStack.count == path.count && path.count >= 6, "at least six meaningful levels, no depth ceiling")
        await model.returnToFrame(depth: 0, service: service)
        #expect(model.frameStack.isEmpty && model.selection == .node(qn) && model.viewport() == rootViewport && model.placements == rootPlacements,
                "exact return to the case map as it was left")
        // Back to source: the point opens the passage of FR-12's own version.
        let ledger1 = try await file.reportLedger(caseID: mother)
        #expect(ledger1.point(p1)?.isVerified == true && ledger1.point(p1)?.sourceVersionID == versions["inv104-forensic-report-FR-12.md"])

        // ── Step 4: the same witness and the same transaction in two branches — one canonical record each ──────────
        let meera = try await file.addPerson(caseID: mother, name: "Meera Shah", role: .witness, entityID: nil, contact: nil, notes: nil, actor: actor)
        let mn = node(.person, meera)
        _ = try await file.placeInFrame(caseID: mother, frame: qn, member: mn, purpose: "her account", actor: actor)
        _ = try await file.placeInFrame(caseID: mother, frame: node(.task, talk), member: mn, purpose: "to be re-interviewed", actor: actor)

        // ── Step 8 (money; needed for step 4's transaction): accounts, the statement's rows, the invoice ───────────
        let money = try #require(key["money"] as? [String: Any])
        let cur = try #require(money["currency"] as? String)
        let vStmt = try #require(versions[SupplierINV104Fixture.bankStatement])
        let a3391 = try await file.addMoneyAccount(caseID: mother, identifier: "3391", institution: "Western Coast Bank", currency: "INR", sourceVersionID: vStmt, actor: actor)
        let a8804 = try await file.addMoneyAccount(caseID: mother, identifier: "8804", institution: "Western Coast Bank", currency: "INR",
                                                   sourceVersionID: versions["inv104-account-ownership-8804.md"], actor: actor)
        let st = try await file.addMoneyStatement(caseID: mother, accountID: a3391, periodStart: "2026-03-01", periodEnd: "2026-03-31", opening: nil, closing: nil,
                                                  currency: "INR", sourceVersionID: vStmt, sourceName: SupplierINV104Fixture.bankStatement, actor: actor)
        let stmtText = try String(contentsOf: try #require(files[SupplierINV104Fixture.bankStatement]), encoding: .utf8)
        let rows = try await file.importStatementRows(caseID: mother, statementID: st, text: stmtText, actor: actor)
        let lines = try #require(key["bank_lines"] as? [[String: Any]])
        #expect(rows.count == lines.count)
        var invoice = CaseMoneyRecordInput(kind: .invoice, amountText: "INR 50,000")
        invoice.date = "2026-03-04"; invoice.reference = "INV-104"; invoice.payeeAccountID = a8804; invoice.sourceVersionID = versions["inv104-invoice.md"]
        _ = try await file.recordMoney(caseID: mother, invoice, actor: actor)
        var ml = try await file.moneyLedger(caseID: mother)
        let second = try #require(ml.records.first { $0.reference?.contains("KS-77985") == true }, "the second settlement row")
        let tx = node(.moneyRecord, second.id)
        _ = try await file.placeInFrame(caseID: mother, frame: qn, member: tx, purpose: "the second debit", actor: actor)
        _ = try await file.placeInFrame(caseID: mother, frame: node(.task, fin), member: tx, purpose: "traced here", actor: actor)
        p = try await projection()
        #expect(p.nodes.filter { $0.id == mn }.count == 1 && p.nodes.filter { $0.id == tx }.count == 1, "one canonical record per witness and transaction")
        for (frameAnchor, member) in [(qn, mn), (node(.task, talk), mn), (qn, tx), (node(.task, fin), tx)] {
            #expect(try #require(CaseMapFrames.frame(of: frameAnchor, in: p)).contains(member), "\(member) appears in \(frameAnchor)'s frame")
        }
        // Money against the answer key: gross 100,000 / returned 50,000 / net 50,000, not a loss; two equal settlements stay two.
        ml = try await file.moneyLedger(caseID: mother)
        let o = try #require(ml.outcomes().byCurrency[cur])
        #expect(o.grossPaid.amount == Journey.dec(money["gross_paid"] as? String) && o.returned.amount == Journey.dec(money["returned"] as? String)
                && o.netOutflow == Journey.dec(money["net_outflow"] as? String), "\(o)")
        #expect(o.grossPaid.transactions == money["distinct_settlements"] as? Int)
        #expect(ml.mentions.contains { $0.reference == "INV-104" } && (money["invoice_is_a_movement"] as? Bool) == false, "the invoice is a mention, not a movement")
        let moneyText = CaseMoneyReport.markdown(ml)
        #expect(moneyText.contains("INR 100,000.00") && moneyText.contains(CaseMoneyOutcome.netLabel) && !moneyText.lowercased().contains("loss"),
                "net outflow is not labelled a loss")

        // ── Step 5: the witness account against the two bank entries — a possible discrepancy, both sources kept ──
        let map = CaseMapRepository(database: db)
        let witnessDoc = node(.document, try #require(logical["inv104-witness-statement-meera-shah.md"]))
        let bankDoc = node(.document, try #require(logical[SupplierINV104Fixture.bankStatement]))
        _ = try await map.addLink(caseID: mother, type: .challenges, from: witnessDoc, to: qn, rationale: "“\(try #require(disc["witness_quote"] as? String))”", actor: actor)
        _ = try await map.addLink(caseID: mother, type: .supports, from: bankDoc, to: qn,
                                  rationale: "Two debits: \((disc["bank_entries"] as? [String] ?? []).joined(separator: ", "))", actor: actor)
        p = try await projection()
        #expect(p.links(of: qn).contains { $0.type == .challenges && $0.from == witnessDoc } && p.links(of: qn).contains { $0.type == .supports && $0.from == bankDoc })

        // ── Step 6: parent and children each have a deliverable and an owner (checked) ────────────────────────────
        let contracts = try await file.reportLedger(caseID: mother)
        for t in [parent, fin, talk] {
            #expect(contracts.contract(t)?.deliverable.isEmpty == false && contracts.contract(t)?.responsible == actor, "\(t) has a deliverable and an owner")
        }
        #expect(contracts.contract(fin)?.parentTaskID == parent && contracts.contract(talk)?.parentTaskID == parent)
        let brief1 = CaseMapBrief.compute(p, changed: [])
        #expect(brief1.section("next")?.entries.contains { $0.node == node(.task, fin) } == true, "the next work is listed with a reason")
        skips.append(.init(step: 6, reason: "'existing equivalent work is reused' is checked for automation (coalesced/alreadyDone, step 12) and AI proposals (S10); a person creating a second identical action by hand is allowed and not deduplicated"))

        // ── Step 7: distinct identities ─────────────────────────────────────────────────────────────────────────
        skips.append(.init(step: 7, reason: "an examiner and a limited contributor with authenticated distinct identities need a sign-in service (QA-07, needs b); local roles are exercised in hostileAndFailureVariants, not as team verification"))

        // ── Step 9: return one result for correction, then accept its new revision (solo self-review, labelled) ──
        let tSubmit1 = Journey.at(2026, 4, 3, 9), tReturn = Journey.at(2026, 4, 3, 15), tSubmit2 = Journey.at(2026, 4, 4, 9), tAccept = Journey.at(2026, 4, 4, 16)
        _ = try await file.recordActionResult(caseID: mother, taskID: fin, kind: .report, outcome: .successful, summary: "KS-77985 settles PO-561",
                                              inputs: [.source(vStmt, "bank statement")], actor: actor, at: tSubmit1)
        #expect(try await file.reviewActionResult(caseID: mother, taskID: fin, revision: 1, accept: false, rationale: "Attach the purchase order", actor: actor, at: tReturn) == .selfReview)
        #expect(try await file.reportLedger(caseID: mother).contract(fin)?.review == .returned)
        let r2 = try await file.recordActionResult(caseID: mother, taskID: fin, kind: .record, outcome: .successful, summary: "KS-77985 settles PO-561; PO attached",
                                                   inputs: [.source(vStmt, "bank statement")], actor: actor, at: tSubmit2)
        #expect(r2.revision == 2)
        await #expect(throws: CaseActionWorkError.staleRevision(latest: 2)) {
            _ = try await file.reviewActionResult(caseID: mother, taskID: fin, revision: 1, accept: true, rationale: "stale", actor: actor)
        }
        #expect(try await file.reviewActionResult(caseID: mother, taskID: fin, revision: 2, accept: true, rationale: "PO matches", actor: actor, at: tAccept) == .selfReview)
        let reviews = try await file.actionResultReviews(caseID: mother, taskID: fin)
        #expect(reviews.map(\.accepted) == [false, true] && reviews.allSatisfy { $0.kind == .selfReview }, "review history kept, self-review labelled")
        try await file.recordOutcome(caseID: mother, taskID: fin, outcome: .discrepancyExplained, note: "KS-77985 settles PO-561", actor: actor)
        try await file.completeAction(caseID: mother, taskID: fin, actor: actor)
        // The interview examined the witness statement as it is now (version 1), and is finished.
        let witnessV1 = try #require(versions["inv104-witness-statement-meera-shah.md"])
        _ = try await file.recordActionResult(caseID: mother, taskID: talk, kind: .report, outcome: .inconclusive, summary: "She does not remember the second approval",
                                              inputs: [.source(witnessV1, "witness statement")], actor: actor)
        try await file.completeAction(caseID: mother, taskID: talk, actor: actor)
        #expect(try await file.allegations(caseID: mother).first { $0.id == question }?.disposition == .pending, "completed work does not decide the question")

        // ── Step 10: the prior case — exact account overlap, an authorised reference; the namesake rejected ───────
        let prior = try await cases.createCase(workspaceID: ws, title: "Closed case 2025-17", actor: "Ravi Menon", at: now).id
        let priorRev = try #require(try await cases.fetch(caseID: prior)?.caseHeader.revision)
        _ = try await cases.includeSource(caseID: prior, expectedRevision: priorRev, sourceRef: try #require(versions["inv104-prior-case-2025-17-summary.md"]).uuidString,
                                          sourceKind: .sourceVersion, actor: "Ravi Menon", at: now)
        let priorQ = try await file.addAllegation(caseID: prior, text: "A payment of INR 18,000 to account 8804 was disputed", actor: "Ravi Menon")
        _ = try await file.addMoneyAccount(caseID: prior, identifier: "A/c 8804", institution: "Western Coast Bank", actor: "Ravi Menon")
        let historyReview = CaseHistoryReviewService(database: db, file: file, map: service)
        _ = try await file.chooseOverlapIdentifier(caseID: mother, kind: .accountNumber, value: "8804", actor: actor)
        let overlaps = try await historyReview.identifierOverlaps(caseID: mother)
        let exact = try #require(overlaps.first { $0.identifier.value == "8804" })
        #expect(exact.basis == .exactIdentifier && exact.otherCases.map(\.caseID) == [prior], "account 8804 is found in the prior case by exact token")
        #expect(!exact.summary.contains("18,000") && !exact.summary.contains("credit note"), "counts and case names only, never a passage of the other case")
        let historySource = try await file.addHistorySource(caseID: mother, kind: .case, originCaseID: prior, purpose: "Earlier dispute on 8804", scope: .records, actor: actor)
        let priorRef = try await file.addCrossReference(caseID: mother, historySourceID: historySource, origin: CaseMapNodeID(caseID: prior, kind: .allegation, id: priorQ),
                                                        mode: .live, purpose: "Compare with the earlier dispute", actor: actor)
        let view = try await historyReview.resolve(caseID: mother, referenceID: priorRef)
        #expect(view.isAvailable && view.title?.contains("18,000") == true && view.sources.isEmpty, "records scope: the record, not its passages")
        let comparison = try await historyReview.compare(caseID: mother, historySourceID: historySource)
        #expect(comparison.similarities.contains { $0.aspect == "Account identifier" && $0.note.contains("exact") })
        // The unrelated same-name person: assessed as a weak candidate at most, then recorded as different people.
        let signatory = try await file.addPerson(caseID: mother, name: "Arjun Mehta", role: .other, entityID: nil, contact: nil, notes: "authorised signatory of account 8804", actor: actor)
        let namesake = try await file.addPerson(caseID: mother, name: "Arjun Mehta", role: .other, entityID: nil, contact: nil, notes: "named in a trade newsletter", actor: actor)
        let assessment = try await file.assessSamePerson(caseID: mother, personA: signatory, personB: namesake, actor: actor)
        #expect(assessment.verdict != .strongCandidate, "a same name is never more than a weak candidate")
        try await file.recordIdentityDecision(caseID: mother, personA: signatory, personB: namesake, decision: .differentPeople,
                                              rationale: "The newsletter's Arjun Mehta is a cricket coach in Pune; the signatory is Kestrel's director", actor: actor)
        p = try await projection()
        #expect(p.count(.person) >= 3 && !p.links.contains { $0.type == .samePersonDecided }, "two Arjun Mehtas stay two")
        #expect(try await Journey.count(db, "SELECT COUNT(*) FROM investigation_identity_decisions WHERE case_id = ?;", [.uuid(mother)]) == 0, "no automatic identity decision")

        // ── Step 11: the amended report, and a changed source ────────────────────────────────────────────────────
        let amendKey = try #require(rk["amendment"] as? [String: Any])
        let amendment = try await svc.file.addReport(caseID: mother, CaseReportDetails(
            title: "Amendment A to FR-12", kind: .amendment, amendsReportID: report, sourceVersionID: versions["inv104-forensic-report-FR-12-amendment.md"],
            producer: rk["producer"] as? String, author: rk["author"] as? String, reportDateText: amendKey["date_text"] as? String), actor: actor)
        // The amendment keeps findings 1 and 3 (recorded with the original words) and withdraws finding 2.
        _ = try await svc.addPoint(caseID: mother, reportID: amendment, kind: .finding, statement: try #require(quotes[1]), quote: quotes[1], actor: actor)
        _ = try await svc.addPoint(caseID: mother, reportID: amendment, kind: .finding, statement: "Finding 2 is withdrawn", quote: try #require(amendKey["quote"] as? String), actor: actor)
        _ = try await svc.addPoint(caseID: mother, reportID: amendment, kind: .finding, statement: try #require(quotes[3]), quote: quotes[3], actor: actor)
        let (_, cmp) = try await svc.compareReports(caseID: mother, earlier: report, later: amendment, actor: actor)
        #expect(cmp.changedPoints.contains { $0.earlierPointID == p2 }, "finding 2 is marked changed: \(cmp.lines)")
        // Finding 1 keeps its words; its timezone qualification was recorded on the original only, so it reads "requalified" (the
        // amendment does not restate it) — never "reworded". Finding 3 is unchanged.
        #expect(cmp.points.first { $0.earlierPointID == p1 }?.change == .requalified && cmp.points.first { $0.earlierPointID == points[3] }?.change == .unchanged,
                "\(cmp.lines)")
        #expect(cmp.affectedWork.contains { $0.workID == parent }, "the work raised from finding 2 is flagged for review")
        let afterAmend = try await file.reportLedger(caseID: mother)
        #expect(afterAmend.point(p2)?.isActive == true && afterAmend.report(report)?.isActive == true, "the earlier report and its point stay inspectable")
        // A summary bound to its inputs before the source changes.
        let pBefore = try await projection()
        let summaryID = UUID()
        _ = try await file.bindDerivation(caseID: mother, derived: .summary, derivedID: summaryID.uuidString, label: "Case summary for the director",
                                          inputs: [witnessDoc.key, qn.key], projection: pBefore, actor: actor)
        await model.refresh(service)
        let placedBefore = model.placements
        // The witness's statement is re-supplied with a correction: a new version of the same source, approved into the case.
        let witnessURL = try #require(files["inv104-witness-statement-meera-shah.md"])
        let corrected = try String(contentsOf: witnessURL, encoding: .utf8) + "\nCorrection, 2 April 2026: I may have approved a second instruction on 11 March; I am not sure.\n"
        try Data(corrected.utf8).write(to: witnessURL)
        let reingest = try await ingest.ingest(fileAt: witnessURL)
        #expect(reingest.intakeOutcome == .newVersion, "a changed file is a new version: \(String(describing: reingest.intakeOutcome))")
        let witnessV2 = try #require(reingest.sourceVersionID)
        #expect(witnessV2 != witnessV1 && reingest.logicalSourceID == logical["inv104-witness-statement-meera-shah.md"])
        _ = try await intake.include(caseID: mother, approved: [witnessV2], actor: actor, at: Date())
        #expect(try await Journey.count(db, "SELECT COUNT(*) FROM investigation_case_sources WHERE case_id = ? AND upper(source_ref) = upper(?) AND in_scope = 1;",
                                        [.uuid(mother), .text(witnessV2.uuidString)]) == 1, "the new version is in the case after approval")
        let pAfter = try await projection()
        let bindings = try await file.derivationBindings(caseID: mother)
        let stale = try #require(CaseDerivation.staleness(of: "summary:" + summaryID.uuidString.lowercased(), bindings: bindings, in: pAfter))
        #expect(stale.isStale, "the summary resting on the witness statement says it is stale: \(stale.reasons)")
        let reach = CaseDependencyTraversal.trace(from: witnessDoc, in: pAfter, derivations: bindings)
        #expect(reach.nodes.contains(qn) && !reach.nodes.contains(node(.moneyAccount, a3391)), "the change reaches the question, not the unrelated account")
        let reopen = try await file.proposeReopenings(caseID: mother)
        #expect(reopen.filter { $0.taskID == talk }.count == 1, "one reopen proposal for the work that examined the old version: \(reopen)")
        await model.refresh(service)
        #expect(placedBefore.allSatisfy { model.placements[$0.key]?.point == $0.value.point }, "unrelated positions stay where they were")
        // Original points and the old version stay inspectable.
        #expect(try await file.reportLedger(caseID: mother).point(p1)?.sourceVersionID == versions["inv104-forensic-report-FR-12.md"])

        // ── Step 12: retry, duplicate delivery and the generation budget ────────────────────────────────────────
        let auto = try #require(state.caseAutomation)
        var prof = try await file.profile(caseID: mother); prof.owner = actor
        try await file.saveProfile(prof, actor: actor)
        let observed = await auto.observeSourceVersion(witnessV2)
        guard case .queued(let reviewRow) = try #require(observed.first { if case .queued = $0 { return true }; return false }) else {
            Issue.record("the changed source did not queue a review: \(observed)"); return
        }
        #expect(await auto.observeSourceVersion(witnessV2).contains(.alreadyDone(reviewRow)), "re-delivery of the same version creates nothing")
        let recipe = CaseAutomationRecipe.changedEvidenceReview
        func trigger(_ event: String, _ inputs: [CaseExaminedInput]) -> CaseAutomationTrigger {
            CaseAutomationTrigger(recipeID: recipe.id, causeAction: recipe.triggers[0], eventKey: event, title: "Review changed evidence",
                                  purpose: "Check earlier work against the corrected statement", inputs: inputs, requestedBy: actor)
        }
        var policy = CaseAutomationPolicy.standard; policy.budgets.newActionsPerRun = 1
        _ = try await auto.setPolicy(caseID: mother, policy, actor: actor)
        let b1 = try await auto.observe(caseID: mother, trigger("b1", [.source(witnessV2), CaseExaminedInput(kind: "task", id: fin.uuidString)]))
        let dup = try await auto.observe(caseID: mother, trigger("b1-again", [.source(witnessV2), CaseExaminedInput(kind: "task", id: fin.uuidString)]))
        guard case .queued(let b1ID) = b1 else { Issue.record("not queued: \(b1)"); return }
        #expect(dup == .coalesced(b1ID), "a duplicate submission folds into the waiting work")
        _ = try await auto.observe(caseID: mother, trigger("b2", [.source(witnessV2), CaseExaminedInput(kind: "task", id: parent.uuidString)]))
        let run = try await auto.dispatch(caseID: mother, actor: actor)
        #expect(run.done.count == 1 && run.held.count == 1, "the budget stops the second piece of work: \(run)")
        let budget = try await auto.budgetStatus(caseID: mother)
        #expect(budget.held == 1 && budget.lines.contains { $0.contains("held by a budget") }, "a visible, resumable state")
        let heldReason = try await auto.queue(caseID: mother).first { $0.state == .held }?.stateReason ?? ""
        #expect(heldReason.contains("resume"), "\(heldReason)")
        // One more piece of work left queued (not yet run) when the backup is made (step 17).
        guard case .queued(let pendingAtBackup) = try await auto.observe(caseID: mother, trigger("b3", [.source(witnessV2), CaseExaminedInput(kind: "allegation", id: question.uuidString)])) else {
            Issue.record("the last trigger did not queue"); return
        }

        // ── Step 13: revoke access while a send/export is pending ───────────────────────────────────────────────
        skips.append(.init(step: 13, reason: "revocation of a real account needs authenticated users (needs b); the local-role race (role removed after an export was prepared refuses the release) runs in hostileAndFailureVariants"))

        // ── Step 14: investigator work and time history — performer, recorder, software, event, receipt, review ──
        let examiner = try await file.recordActor(caseID: mother, kind: .reportedExternal, displayName: try #require((key["identities"] as? [String: Any])?["external_performer"] as? String), actor: actor)
        let work = try await file.reportLedger(caseID: mother)
        #expect(work.actors.first { $0.id == examiner }?.kind == .reportedExternal && work.actors.first { $0.id == examiner }?.isAuthenticated == false, "reported performer")
        #expect(work.actors.first { $0.displayName == actor } != nil, "the person who recorded the work")
        let finContract = try #require(work.contract(fin))
        #expect(finContract.submittedAt == tSubmit2 && finContract.reviewedAt == tAccept && finContract.submittedAt != finContract.reviewedAt, "receipt time and review time are separate")
        #expect(work.report(report)?.times.first { $0.kind == .event }?.text == rk["report_date_text"] as? String, "the event time as the report states it")
        let softwareRow = try #require(try await auto.queue(caseID: mother).first { $0.id == reviewRow })
        #expect(softwareRow.recipeID == recipe.id && softwareRow.executionID != nil, "software activity is its own record (recipe, execution)")

        // ── Step 15: a separate review case examines pinned decisions without changing the original ─────────────
        let history = CaseHistoryService(database: db, map: service)
        let checkpoint = try await history.record(caseID: mother, kind: .milestone, name: "Before closure", actor: actor)
        let motherFence = try await map.revisionFence(caseID: mother)
        let reviewCase = try await cases.createCase(workspaceID: ws, title: "Review of the INV-104 investigation", actor: "Sunil Rao", at: Date()).id
        let started = try await file.startReview(caseID: reviewCase, of: mother, purpose: "Was the discrepancy handled properly?", actor: "Sunil Rao")
        let pinned = try await historyReview.pinAsKnownAt(caseID: reviewCase, historySourceID: started.historySource, origin: qn,
                                                          at: checkpoint.recordedAt.addingTimeInterval(1), purpose: "What the investigator had", actor: "Sunil Rao")
        let pinnedView = try await historyReview.resolve(caseID: reviewCase, referenceID: pinned)
        #expect(pinnedView.isAvailable && pinnedView.title?.contains("Kestrel") == true && pinnedView.asOf.contains("Recorded state"), "\(pinnedView.state)")
        _ = try await file.recordReviewFinding(caseID: reviewCase, referenceID: pinned, assessment: .incomplete, text: "The purchase order was obtained late.", actor: "Sunil Rao")
        #expect(try await map.revisionFence(caseID: mother) == motherFence, "the review changed nothing in the original case")
        #expect(try await historyReview.reviewExport(caseID: reviewCase).contains("changed nothing in the original case"))

        // ── Step 16: close with explicit unresolved items; search with receipt; export through the output door ───
        let unresolved = ["Who approved the second payment (KS-77985)", "The timezone of the bank's times"]
        let closure = try #require(state.investigationClosure)
        let rev = try #require(try await svc.caseHeader(mother)).revision
        _ = try await closure.closeCase(caseID: mother, expectedRevision: rev, rationale: "Two distinct settlements; refund received; approval unresolved",
                                        unresolvedItems: unresolved, workProductRunID: nil, receiptSeal: nil, actor: actor, at: Date())
        try await file.markClosed(caseID: mother, reopened: false, actor: actor)
        let position = try await history.recordClosurePosition(caseID: mother, disposition: "Not substantiated as a duplicate payment; approval unresolved",
                                                               authorizedBy: actor, waived: [], unresolved: unresolved, actor: actor)
        #expect(position.checkpointID != nil)
        await #expect(throws: (any Error).self) { _ = try await file.addAllegation(caseID: mother, text: "Late question", actor: actor) }
        // Search with a receipt (a closed case stays searchable).
        var searchSources = CaseSearchSources.live(database: db)
        let mapSources = caseMapSources(f)
        searchSources.records = { id in await CaseMapService(sources: mapSources).load(caseID: id, generation: 1).projection }
        let search = CaseSearchService(sources: searchSources)
        let found = try #require(await search.run(caseID: mother, text: "exact:\"KS-77985\"", options: CaseSearchOptions(timeZoneID: "UTC")).run)
        #expect(found.hits.contains { $0.name == SupplierINV104Fixture.bankStatement } && found.hits.contains { $0.name == "inv104-forensic-report-FR-12-amendment.md" })
        #expect(!found.hits.contains { $0.name == SupplierINV104Fixture.bankCopy }, "the copy is not a second hit")
        #expect(found.storedResult.receiptLines.contains { $0.hasPrefix("Searched ") } && found.records != nil, "the receipt names what was searched")
        // S14 (QA-15, was the S13 finding): the unreadable scan is in the case's workspace and scope as NOT READ — the
        // receipt names it as not searched with its reason, the coverage lists it as not read, the brief and the map name it,
        // and it is never counted as searched or read.
        let scanInWorkspace = try await Journey.count(db, "SELECT COUNT(*) FROM workspace_sources WHERE workspace_id = ? AND upper(file_id) = upper(?);",
                                                      [.uuid(ws), .text(scan.fileRecord.id.uuidString)])
        #expect(scanInWorkspace == 1, "the failed scan is in the workspace")
        let scanLine = found.receipt.items.first { $0.name == SupplierINV104Fixture.scanName }
        #expect(scanLine != nil && scanLine?.category != .partlySearched && scanLine?.category != .excluded && scanLine?.reason.isEmpty == false,
                "the receipt names the failed scan as not searched, with its reason: \(found.receipt.lines)")
        #expect(!found.hits.contains { $0.name == SupplierINV104Fixture.scanName }, "the failed scan is never a hit")
        #expect(found.receipt.headline.contains("not searched"), "\(found.receipt.headline)")
        if binAdmitted {
            #expect(found.receipt.items.contains { $0.name == SupplierINV104Fixture.unsupportedName && $0.category != .partlySearched },
                    "the unsupported attachment is named as not searched: \(found.receipt.lines)")
        } else {
            skips.append(.init(step: 1, reason: "the unsupported attachment (\(unsupportedState)) left no custody record, so there is nothing a case can hold; its state is the intake record"))
        }
        let scopeNow = Set(try #require(try await cases.fetch(caseID: mother)).sources.filter(\.inScope).compactMap { UUID(uuidString: $0.sourceRef) })
        let coverageNow = try await CaseCoverageReadout.load(database: db, workspaceID: ws, scope: scopeNow, caseID: mother)
        #expect(coverageNow.notRead.contains { $0.name == SupplierINV104Fixture.scanName } && !coverageNow.isComplete,
                "coverage lists the failed scan as not read: \(coverageNow.entryLines)")
        let mapNow = try #require(await service.load(caseID: mother, generation: 10).projection)
        let scanNode = mapNow.nodes.first { $0.id.kind == .document && $0.title == SupplierINV104Fixture.scanName }
        #expect(scanNode?.status.kind == .failed && scanNode?.status.text.contains("not read") == true, "the map shows the scan as not read: \(String(describing: scanNode?.status))")
        let briefNow = CaseMapBrief.compute(mapNow, changed: [])
        #expect(briefNow.scope.contains { $0.contains(SupplierINV104Fixture.scanName) && $0.contains("could not be read") }, "the brief names the scan: \(briefNow.scope)")
        _ = try await search.save(found, name: "Second settlement", kind: .receipt, actor: actor)
        // Exports: the case package, the map and the money report through the one door, each read back after writing.
        let outputs = try #require(state.caseOutputs)
        let outDir = temp.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let pkg = try await outputs.preparePackage(caseID: mother, selection: .wholeCase, actor: actor) { id in await service.load(caseID: id, generation: 11) }
        let pkgURL = outDir.appendingPathComponent("INV-104.html")
        let pkgReceipt = await outputs.write(pkg, to: pkgURL)
        #expect(pkgReceipt.status == .written && pkgReceipt.recorded, "\(pkgReceipt.detail ?? "")")
        let read = CasePortablePackageReader.read(try String(contentsOf: pkgURL, encoding: .utf8))
        #expect(read.violations.isEmpty && read.brokenAnchors.isEmpty, "\(read.violations) \(read.brokenAnchors)")
        let manifest = try #require(read.manifest)
        #expect(manifest.revisionFence == pkg.manifest?.revisionFence && read.rows["item"] == manifest.counts["items"])
        #expect(read.sectionText["money"]?.contains("100,000") == true && read.sectionText["money"]?.lowercased().contains("loss") == false)
        #expect(read.sectionText["open-work"] != nil && read.sectionText["disclosures"]?.contains("Originals") == true)
        #expect(CaseOutputArtifactCheck.problem(try Data(contentsOf: pkgURL), manifest: manifest) == nil, "the written file matches its frozen manifest")
        let load = await service.load(caseID: mother, generation: 12)
        let shown = CaseMapViewFilter.apply(try #require(load.projection), view: .overview, filter: CaseMapFilter(collapsed: []))
        let req = CaseMapExportRequest(projection: try #require(load.projection), placements: load.placements, shown: shown.shown, links: shown.links, selection: nil,
                                       viewTitle: "Overview", state: .current(Date()), scopeFingerprint: "journey")
        let csv = try await outputs.prepareMap(req, format: .csv, route: .file, actor: actor)
        let csvURL = outDir.appendingPathComponent("map.csv")
        #expect(await outputs.write(csv, to: csvURL).status == .written)
        #expect(CaseOutputArtifactCheck.problem(try Data(contentsOf: csvURL), manifest: try #require(csv.manifest)) == nil)
        let moneyPkg = try await outputs.prepareMoneyReport(caseID: mother, actor: actor)
        let moneyURL = outDir.appendingPathComponent("money.md")
        #expect(await outputs.write(moneyPkg, to: moneyURL).status == .written)
        let moneyRead = try String(contentsOf: moneyURL, encoding: .utf8)
        #expect(moneyRead == moneyPkg.text && moneyRead.contains("INR 100,000.00") && moneyRead.contains("INR 50,000.00"), "the money report read back")
        let written = Set(try await outputs.outputs(caseID: mother).filter { $0.status == .written }.map(\.kind))
        #expect(written.isSuperset(of: [.casePackage, .moneyReport]) && written.count >= 3)
        skips.append(.init(step: 16, reason: "a new human reviewer following the reasoning cannot be automated; the package is read back by a fresh reader with nothing but its bytes instead"))

        // ── Step 17: back up, erase a case opened in error, restore — no resurrection; the case reopens intact ───
        let scratch = try await cases.createCase(workspaceID: ws, title: "Opened in error — duplicate of INV-104", actor: actor, at: Date()).id
        _ = try await file.addAllegation(caseID: scratch, text: "Duplicate entry", actor: actor)
        let layoutBefore = try await map.layout(caseID: mother)
        let pointsBefore = try await file.reportLedger(caseID: mother).points.map(\.id).sorted()
        let originals = try await db.query("SELECT id, url FROM files;", []).compactMap { r -> (fileID: UUID, url: URL)? in
            guard let id = r.uuid(0), let u = r.string(1).flatMap(URL.init(string:)), FileManager.default.fileExists(atPath: u.path) else { return nil }
            return (id, u)
        }
        let snapDir = temp.appendingPathComponent("snap", isDirectory: true)
        try FileManager.default.createDirectory(at: snapDir, withIntermediateDirectories: true)
        let snap = snapDir.appendingPathComponent("knowledge.sqlite")
        try await db.backupSnapshot(to: snap)
        let backup = temp.appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        _ = try BackupService().createCompleteBackup(databaseSnapshot: snap, originals: originals, notIncluded: [], destination: backup,
                                                     schemaVersion: SchemaMigrations.latestVersion, nowEpoch: Date().timeIntervalSince1970 - 60, besideLedger: temp)
        let erased = try await state.eraseCase(scratch, eraseExclusiveSources: false, reason: "Opened in error", legalBasis: nil, actor: actor)
        #expect(erased.report.refused == nil)
        let restoredFolder = temp.appendingPathComponent("restored", isDirectory: true)
        try FileManager.default.createDirectory(at: restoredFolder, withIntermediateDirectories: true)
        let restoredLedger = restoredFolder.appendingPathComponent("knowledge.sqlite")
        try FileManager.default.copyItem(at: ErasureRegister.url(besideLedgerAt: ledgerURL), to: ErasureRegister.url(besideLedgerAt: restoredLedger))
        let restoreMap = try await BackupService().restoreComplete(backupFolder: backup, into: restoredFolder)
        #expect((restoreMap.pausedOutbox ?? 0) >= 1, "work queued at backup time is paused, not replayed")
        let state2 = AppState(bookmarks: BookmarkStore(ephemeral: true))
        await state2.boot(databaseURL: restoredLedger)
        guard case .ready = state2.phase, let db2 = state2.database, let svc2 = state2.caseFiles, let cases2 = state2.investigationCases else {
            Issue.record("the restored ledger did not open"); return
        }
        #expect(try await Journey.count(db2, "SELECT COUNT(*) FROM investigation_cases WHERE id = ?;", [.uuid(scratch)]) == 0, "the erased case did not come back")
        for c in [mother, prior, reviewCase] { #expect(try await Journey.count(db2, "SELECT COUNT(*) FROM investigation_cases WHERE id = ?;", [.uuid(c)]) == 1) }
        #expect(state2.restoreNotice?.contains("erased again") == true, "\(state2.restoreNotice ?? "nil")")
        let held = try await Journey.count(db2, "SELECT COUNT(*) FROM case_automation_outbox WHERE id = ? AND state = 'held' AND state_reason LIKE 'Paused after a restore%';",
                                           [.uuid(pendingAtBackup)])
        #expect(held == 1, "the queued work is held for a person, never run again blindly")
        let f2 = CaseFileTests.Fixture(db: db2, cases: cases2, workspaces: try #require(state2.workspaces), svc: svc2, workspaceID: ws, caseID: mother)
        #expect(try await f2.file.reportLedger(caseID: mother).points.map(\.id).sorted() == pointsBefore, "every point keeps its id")
        #expect(try await CaseMapRepository(database: db2).layout(caseID: mother) == layoutBefore, "positions survive")
        let o2 = try #require(try await f2.file.moneyLedger(caseID: mother).outcomes().byCurrency[cur])
        #expect(o2.grossPaid.amount == o.grossPaid.amount && o2.returned.amount == o.returned.amount && o2.netOutflow == o.netOutflow)
        let bankFileID = try #require(fileIDs[SupplierINV104Fixture.bankStatement])
        let bankRow = try await db2.query("SELECT url FROM files WHERE id = ?;", [.uuid(bankFileID)])
        let restoredBank = try #require(bankRow.first?.string(0).flatMap(URL.init(string:)))
        let restoredSHA = try Journey.sha(restoredBank), originalSHA = try Journey.sha(try #require(files[SupplierINV104Fixture.bankStatement]))
        #expect(restoredBank.path.hasPrefix(restoredFolder.path) && restoredSHA == originalSHA,
                "the original is restored beside the ledger with the same bytes")
        let review2 = CaseHistoryReviewService(database: db2, file: f2.file, map: CaseMapService(sources: caseMapSources(f2)))
        #expect(try await review2.resolve(caseID: mother, referenceID: priorRef).isAvailable, "the prior-case reference resolves after restore")
        // Reopen and navigate deep again in the restored ledger.
        let closure2 = try #require(state2.investigationClosure)
        let rev2 = try #require(try await svc2.caseHeader(mother)).revision
        _ = try await closure2.reopenCase(caseID: mother, expectedRevision: rev2, rationale: "Bank's answer on the approval arrived", actor: actor, at: Date())
        try await f2.file.markClosed(caseID: mother, reopened: true, actor: actor)
        _ = try await f2.file.addJournal(caseID: mother, kind: .note, text: "Bank answer received", eventDate: nil, evidenceRef: nil, actor: actor)
        #expect(try await CaseHistoryService(database: db2, map: CaseMapService(sources: caseMapSources(f2))).closurePositions(caseID: mother).map(\.id) == [position.id],
                "the closure position survives reopening")
        let service2 = CaseMapService(sources: caseMapSources(f2))
        let model2 = CaseMapWorkspaceModel(caseID: mother, workspace: CaseWorkspaceHolder(caseID: mother, defaults: journeyDefaults()))
        await model2.refresh(service2)
        for anchor in path { await model2.openFrame(anchor, service: service2) }
        #expect(model2.frameStack.count == path.count && model2.frame?.anchor == path.last, "deep navigation survives the restore")
        skips.append(.init(step: 17, reason: "the restore runs into a fresh folder on this Mac with this Mac's erasure register beside it; a second Mac that never saw the erasure is RECOVERY-04 (blocked: second device)"))

        // ── Step 18: modes ──────────────────────────────────────────────────────────────────────────────────────
        skips.append(.init(step: 18, reason: "suggestion and configured-execution AI modes need a model (AI quality work is out of scope; S10 tests the controls with a scripted fake); team mode needs real accounts. This run is solo, AI off"))
        // AI off: nothing was sent anywhere, on either ledger.
        let sent1 = try await Journey.count(db, "SELECT COUNT(*) FROM outbound_log;"), sent2 = try await Journey.count(db2, "SELECT COUNT(*) FROM outbound_log;")
        #expect(sent1 == 0 && sent2 == 0)
        // No conclusion was invented.
        let allText = (try await f2.file.allegations(caseID: mother).map(\.text) + (try await f2.file.reportLedger(caseID: mother)).points.map(\.statement)).joined(separator: " ").lowercased()
        #expect(!allText.contains("fraud") && !allText.contains("guilty"))

        for s in skips { print(s) }
        #expect(skips.map(\.step) == [1, 6, 7, 13, 16, 17, 18], "the recorded skips are exactly the ones stated")
        await db2.close()
    }

    @Test("§G hostile and failure variants feasible on one Mac: local-role revocation during a pending export, a malformed statement refused whole, a stale or required-independent review refused, an erased case takes no late write or export, a tampered backup manifest refused")
    func hostileAndFailureVariants() async throws {
        let f = try await CaseFileTests.fixture(title: "Was Kestrel Supplies paid twice for invoice INV-104?")
        let c = f.caseID
        let doc = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: c, name: SupplierINV104Fixture.bankStatement,
                                                            text: try String(contentsOf: Journey.fixtureFolder.appendingPathComponent(SupplierINV104Fixture.bankStatement), encoding: .utf8))
        // A malformed statement (one bad line) is refused whole: nothing of it is written.
        let acct = try await f.file.addMoneyAccount(caseID: c, identifier: "3391", actor: "Ada")
        let st = try await f.file.addMoneyStatement(caseID: c, accountID: acct, periodStart: "2026-03-01", periodEnd: "2026-03-31", opening: nil, closing: nil, currency: "INR", actor: "Ada")
        await #expect(throws: (any Error).self) {
            _ = try await f.file.importStatementRows(caseID: c, statementID: st, text: "Date,Description,Debit,Credit\n2026-03-06,Transfer,50000,\n2026-03-11,Note,,", actor: "Ada")
        }
        #expect(try await f.file.moneyLedger(caseID: c).records.isEmpty)
        // An action whose policy requires independent review: self-review is an unmet state, never a fabricated approval.
        let q = try await f.file.addAllegation(caseID: c, text: "Was Kestrel paid twice?", actor: "Ada")
        let t = try await f.svc.createAction(caseID: c, .init(title: "Trace KS-77985", purpose: "Second debit", deliverable: "The PO", responsible: "Ada", servesQuestions: [q]), actor: "Ada")
        let auto = CaseAutomationService(database: f.db, caseFiles: f.svc, recipes: CaseAutomationRecipe.builtIn, aiPermitted: { _ in false }, lease: 300)
        var p = CaseAutomationPolicy.standard; p.requireIndependentReview = true
        _ = try await auto.setPolicy(caseID: c, p, actor: "Ada")
        _ = try await f.file.recordActionResult(caseID: c, taskID: t, kind: .report, outcome: .successful, summary: "PO-561", inputs: [.source(doc.version)], actor: "Ada")
        await #expect(throws: CaseActionWorkError.independentReviewRequired) {
            _ = try await f.file.reviewActionResult(caseID: c, taskID: t, revision: 1, accept: true, rationale: "mine", actor: "Ada")
        }
        #expect(try await f.svc.soloBinding(caseID: c, actor: "Ada")?.note.contains("requires independent review") == true)
        // Local roles (not authenticated accounts): a role removed after an export was prepared refuses the release.
        let ben = try await f.file.grantAccess(caseID: c, to: "Ben", role: .investigator, reason: "Examiner", actor: "Ada")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("journey-hostile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let outputs = CaseOutputService(database: f.db, caseFiles: f.svc, custody: { _ in [] }, pendingDirectory: temp.appendingPathComponent("pending"))
        let pkg = try await outputs.prepareText(caseID: c, kind: .achReport, route: .file, actor: "Ben", citations: [], text: "Reconciliation notes")
        try await f.file.revokeAccess(caseID: c, grantID: ben, reason: "Removed during export", transferTo: "Ada", actor: "Ada")
        let out = temp.appendingPathComponent("late.txt")
        #expect(await outputs.write(pkg, to: out).status == .refused && !FileManager.default.fileExists(atPath: out.path), "no late disclosure")
        // A tampered backup manifest is refused before anything is restored.
        // (An encrypted ledger, as shipped: a plaintext one cannot show whose key signed it — RECOVERY-07.)
        let key = LedgerKey.random()
        let snap = try await SmartMapS11Tests().encryptedLedger(key, marker: "journey")
        let backup = temp.appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        _ = try BackupService().createCompleteBackup(databaseSnapshot: snap, originals: [], notIncluded: [], destination: backup,
                                                     schemaVersion: SchemaMigrations.latestVersion, nowEpoch: 10, signingKey: key)
        let manifestURL = backup.appendingPathComponent(BackupService.manifestName)
        let m = try JSONDecoder().decode(BackupManifest.self, from: Data(contentsOf: manifestURL))
        let forged = BackupManifest(createdAtEpoch: 999_999, schemaVersion: m.schemaVersion, entries: m.entries, coverage: .complete, inventory: m.inventory)
        try JSONEncoder().encode(forged).write(to: manifestURL)
        #expect(try BackupService().inspect(backupFolder: backup, ledgerKey: key).verdict.signature == .invalid, "a changed manifest does not verify")
        let target = temp.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        #expect(throws: BackupService.BackupError.self) { try BackupService().restore(backupFolder: backup, into: target, ledgerKey: key) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty, "nothing was restored")
        // Erased: no late write and no export of the erased case.
        let report = try await CaseEraser(database: f.db).erase(caseID: c, sourceVersionIDs: [], eraseExclusiveSources: false, reason: "Retention ended", legalBasis: nil, actor: "Ada")
        #expect(report.refused == nil)
        await #expect(throws: (any Error).self) { _ = try await f.file.addAllegation(caseID: c, text: "Late", actor: "Ada") }
        await #expect(throws: (any Error).self) { _ = try await outputs.prepareText(caseID: c, kind: .achReport, route: .file, actor: "Ada", citations: [], text: "x") }
    }
}
