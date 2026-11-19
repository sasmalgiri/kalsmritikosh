//
//  SupplierINV104AcceptanceTests.swift
//  KalsmritikoshTests
//
//  Smart-map BASE-08 / QA-01 / QA-02 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md §G): the supplier
//  acceptance case INV-104, run through the PRODUCTION services on a throwaway ledger, AI off, no network. Every
//  expected value comes from the hand-written answer key Resources/Fixtures/AcceptanceSupplierINV104/
//  inv104-expected-results.json — never from what the code produced. Covered here: intake states (duplicate copy,
//  unreadable scan, unsupported attachment), money (gross 100,000, returned 50,000, net 50,000 — not a loss; two equal
//  settlements stay two; the copy's rows are not counted twice), the forensic report's points verified in their source
//  and its amendment kept beside it, the witness/bank discrepancy recorded with both sources and left open, the parent
//  discrepancy action with financial and interview children (one waiting for the other) whose completion does not
//  decide the question, one canonical witness in two branches, the namesake not merged, the external performer recorded
//  as reported. Later milestones (prior-case reference, contributors, automation) are listed in the answer key as pending.
//

import Foundation
import CryptoKit
import Testing
@testable import Kalsmritikosh

@Suite("Acceptance case — supplier INV-104 (smart-map §G)", .serialized)
struct SupplierINV104AcceptanceTests {

    private static var sourceFolder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Kalsmritikosh/Resources/Fixtures/\(SupplierINV104Fixture.folderName)", isDirectory: true)
    }

    private static func expected() throws -> [String: Any] {
        let data = try Data(contentsOf: sourceFolder.appendingPathComponent(SupplierINV104Fixture.expectedName))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Bank lines read from a statement's table (Date | Time | Description | Reference | Debit | Credit).
    private static func bankRows(_ url: URL) throws -> [FATransaction] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").compactMap { line -> FATransaction? in
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 8, cells[1].range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
            var t = FATransaction()
            t.date = cells[1]; t.descriptionText = cells[3]; t.reference = cells[4]; t.account = "3391"; t.sourceDoc = url.lastPathComponent; t.currency = "INR"
            let debit = cells[5], credit = cells[6]
            if !debit.isEmpty { t.amount = debit; t.kind = .payment; t.payer = "Northwind Components Ltd"; t.payee = "Kestrel Supplies Pvt Ltd" }
            else { t.amount = credit; t.kind = .refund; t.payer = "Kestrel Supplies Pvt Ltd"; t.payee = "Northwind Components Ltd" }
            return t
        }
    }

    @Test("INV-104 runs through the production services and matches the hand-written answer key")
    func supplierINV104() async throws {
        let key = try Self.expected()
        let docs = try #require(key["documents"] as? [[String: Any]])
        // 0. The fixture is fixed: every original's bytes match the answer key's hash.
        for d in docs {
            guard let name = d["name"] as? String, let sha = d["sha256"] as? String else { continue }
            let data = try Data(contentsOf: Self.sourceFolder.appendingPathComponent(name))
            #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == sha, "\(name) changed after the answer key was written")
        }

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("inv104-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let files = try SupplierINV104Fixture.materialise(from: Self.sourceFolder, into: temp.appendingPathComponent("documents", isDirectory: true))
        #expect(Set(files.keys) == Set(docs.compactMap { $0["name"] as? String }), "every item the answer key lists is materialised")
        let copyBytes = try Data(contentsOf: try #require(files[SupplierINV104Fixture.bankCopy]))
        #expect(copyBytes == (try Data(contentsOf: try #require(files[SupplierINV104Fixture.bankStatement]))), "the copy is byte-identical")

        let state = await AppState(bookmarks: BookmarkStore(ephemeral: true))
        await state.boot(databaseURL: temp.appendingPathComponent("ledger.sqlite"))
        let ingest = try #require(await state.ingest)
        let db = try #require(await state.database)

        // 1. Intake: every item is accounted for with an explicit state.
        var versions: [String: UUID] = [:], logical: [String: UUID] = [:], fileIDs: [String: UUID] = [:]
        var intake: [String: String] = [:]
        for name in SupplierINV104Fixture.documentNames {
            let r = try await ingest.ingest(fileAt: try #require(files[name]))
            #expect(r.processingStatus != .failed && r.chunkCount > 0, "\(name): \(String(describing: r.processingStatus)) \(r.processingDetail ?? "")")
            versions[name] = r.sourceVersionID; logical[name] = r.logicalSourceID; fileIDs[name] = r.fileRecord.id
            intake[name] = "processed"
        }
        let copy = try await ingest.ingest(fileAt: try #require(files[SupplierINV104Fixture.bankCopy]))
        #expect([SourceIntakeOutcome.aliased, .unchanged, .moved].contains(copy.intakeOutcome ?? .newLogicalSource),
                "same bytes are not a new source: \(String(describing: copy.intakeOutcome)) \(String(describing: copy.processingStatus))")
        intake[SupplierINV104Fixture.bankCopy] = copy.intakeOutcome?.rawValue
        let scan = try await ingest.ingest(fileAt: try #require(files[SupplierINV104Fixture.scanName]))
        #expect(scan.processingStatus == .failed && scan.chunkCount == 0, "the unreadable scan is a recorded failure, not an empty document")
        intake[SupplierINV104Fixture.scanName] = "failed"
        do {
            let bin = try await ingest.ingest(fileAt: try #require(files[SupplierINV104Fixture.unsupportedName]))
            #expect(bin.chunkCount == 0 && bin.processingStatus != .passCompleted && bin.processingStatus != .queryable,
                    "an unsupported attachment never becomes searchable text: \(String(describing: bin.processingStatus))")
            intake[SupplierINV104Fixture.unsupportedName] = bin.processingStatus?.rawValue ?? "no status"
        } catch {
            intake[SupplierINV104Fixture.unsupportedName] = "refused: \(error.localizedDescription)"
        }
        #expect(intake.count == docs.count, "every listed item has a state: \(intake)")

        // 2. The mother case and its scope.
        let ws = UUID(), now = Date()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(ws), .text("Northwind / Kestrel"), .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970)])
        let coordinator = try #require(await state.workspaceSourceCoordinator)
        try await coordinator.addSources(Set(fileIDs.values), to: ws, at: now)
        let cases = try #require(await state.investigationCases)
        let disc = try #require(key["discrepancy"] as? [String: Any])
        let c = try await cases.createCase(workspaceID: ws, title: try #require(disc["question"] as? String), actor: "Priya Nair", at: now)
        _ = try await #require(await state.investigationWorkspaceIntake).includeWorkspaceSources(caseID: c.id, actor: "Priya Nair", at: now)
        let svc = try #require(await state.caseFiles)
        let f = CaseFileTests.Fixture(db: db, cases: cases, workspaces: try #require(await state.workspaces), svc: svc, workspaceID: ws, caseID: c.id)

        // 3. Money, against the answer key: two equal settlements stay two, the copy's rows are not counted again, the
        //    invoice is not a movement, and the net outflow is not called a loss.
        let money = try #require(key["money"] as? [String: Any])
        let lines = try #require(key["bank_lines"] as? [[String: Any]])
        let original = try Self.bankRows(try #require(files[SupplierINV104Fixture.bankStatement]))
        let copied = try Self.bankRows(try #require(files[SupplierINV104Fixture.bankCopy]))
        #expect(original.map(\.date) == lines.compactMap { $0["date"] as? String })
        #expect(original.map { $0.reference ?? "" } == lines.compactMap { $0["reference"] as? String })
        #expect(original.map { $0.kind?.rawValue ?? "" } == lines.compactMap { $0["kind"] as? String })
        #expect(original.map { $0.amountDecimal.map { "\($0)" } ?? "" } == lines.compactMap { $0["amount"] as? String })
        var invoice = FATransaction(); invoice.date = "2026-03-04"; invoice.amount = "INR 50,000"; invoice.kind = .invoice
        invoice.reference = "INV-104"; invoice.sourceDoc = "inv104-invoice.md"; invoice.currency = "INR"
        var engagement = ForensicEngagement(title: "Kestrel Supplies", now: now)
        engagement.schedule = original + copied + [invoice]
        let s = engagement.summary
        let cur = try #require(money["currency"] as? String)
        let totals = try #require(s.byCurrency[cur])
        #expect("\(totals.gross)" == money["gross_paid"] as? String && "\(totals.returned)" == money["returned"] as? String
                && "\(totals.net)" == money["net_outflow"] as? String, "\(totals)")
        #expect(s.duplicateCopies.count == money["copy_rows_excluded"] as? Int, "the copy's rows are excluded as copies: \(s.duplicateCopies.count)")
        #expect(s.possibleDuplicates.isEmpty, "two settlements with their own references are distinct, not look-alikes")
        let settlements = original.filter { $0.kind == .payment }
        let settlementIDs = Set(settlements.map(\.id))
        let settlementExcluded = s.duplicateCopies.contains { settlementIDs.contains($0.row) }
        #expect(settlements.count == money["distinct_settlements"] as? Int && !settlementExcluded)
        #expect(s.notMovements.contains(invoice.id) == !(money["invoice_is_a_movement"] as? Bool ?? true))
        let rendered = FAReportRenderer.totals(engagement).lowercased()
        #expect(!rendered.contains("loss") || (money["net_outflow_is_labelled_loss"] as? Bool) == true, "net outflow is not labelled a loss")

        // 4. The forensic report: its identity, its points verified in its own version, the timezone uncertainty, and the
        //    amendment kept BESIDE it (the original and its second point stay inspectable, unchanged).
        let rk = try #require(key["report"] as? [String: Any])
        let report = try await svc.file.addReport(caseID: c.id, CaseReportDetails(
            title: "Forensic accounting report FR-12", sourceVersionID: versions["inv104-forensic-report-FR-12.md"],
            producer: rk["producer"] as? String, author: rk["author"] as? String, examinedMaterial: "Statement 3391; invoice INV-104",
            reportDateText: rk["report_date_text"] as? String, methods: "Matched debits to invoices", limitations: "No timezone in the export"), actor: "Priya Nair")
        var pointIDs: [Int: UUID] = [:]
        for pk in try #require(rk["points"] as? [[String: Any]]) {
            let quote = try #require(pk["quote"] as? String)
            pointIDs[try #require(pk["ordinal"] as? Int)] = try await svc.addPoint(caseID: c.id, reportID: report,
                kind: CaseReportPointKind(rawValue: try #require(pk["kind"] as? String)) ?? .claim, statement: quote, quote: quote, actor: "Priya Nair")
        }
        let qk = try #require(rk["qualification"] as? [String: Any])
        try await svc.file.addQualification(caseID: c.id, pointID: try #require(pointIDs[1]), kind: CaseQualificationKind(rawValue: try #require(qk["kind"] as? String)) ?? .uncertainty,
                                            text: "the bank's times have no stated timezone", quote: qk["quote"] as? String, actor: "Priya Nair")
        let ak = try #require(rk["amendment"] as? [String: Any])
        let amendment = try await svc.file.addReport(caseID: c.id, CaseReportDetails(
            title: "Amendment A to FR-12", kind: .amendment, amendsReportID: report, sourceVersionID: versions["inv104-forensic-report-FR-12-amendment.md"],
            producer: rk["producer"] as? String, author: rk["author"] as? String, reportDateText: ak["date_text"] as? String), actor: "Priya Nair")
        let withdrawal = try await svc.addPoint(caseID: c.id, reportID: amendment, kind: .finding, statement: "Finding 2 is withdrawn",
                                                quote: try #require(ak["quote"] as? String), actor: "Priya Nair")
        let amendedOrdinal = try #require(ak["withdraws_point"] as? Int)
        let map = CaseMapRepository(database: db)
        _ = try await map.addLink(caseID: c.id, type: .supersedes, from: CaseMapNodeID(caseID: c.id, kind: .reportPoint, id: withdrawal),
                                  to: CaseMapNodeID(caseID: c.id, kind: .reportPoint, id: try #require(pointIDs[amendedOrdinal])),
                                  rationale: "The amendment withdraws finding 2", actor: "Priya Nair")
        var ledger = try await svc.file.reportLedger(caseID: c.id)
        let fr12Points = ledger.points.filter { $0.reportID == report }
        let allVerified = fr12Points.allSatisfy(\.isVerified)
        #expect(fr12Points.count == 3 && allVerified, "every quoted point is found in FR-12's own version")
        #expect(ledger.point(withdrawal)?.isVerified == true)
        #expect(ledger.report(amendment)?.amendsReportID == report && ledger.report(report)?.isActive == true)
        #expect(ledger.point(try #require(pointIDs[amendedOrdinal]))?.isActive == true, "the amended point is not overwritten or removed")
        #expect(ledger.report(report)?.times.first { $0.kind == .event }?.text == rk["report_date_text"] as? String)
        #expect(ledger.qualifications.contains { $0.kind == .uncertainty && $0.quote == qk["quote"] as? String })

        // 5. The discrepancy: the witness's one payment against the bank's two debits — recorded with both sources, left open.
        let question = try await svc.file.addAllegation(caseID: c.id, text: try #require(disc["question"] as? String), actor: "Priya Nair")
        let qn = CaseMapNodeID(caseID: c.id, kind: .allegation, id: question)
        let witnessDoc = CaseMapNodeID(caseID: c.id, kind: .document, id: try #require(logical["inv104-witness-statement-meera-shah.md"]))
        let bankDoc = CaseMapNodeID(caseID: c.id, kind: .document, id: try #require(logical[SupplierINV104Fixture.bankStatement]))
        _ = try await map.addLink(caseID: c.id, type: .challenges, from: witnessDoc, to: qn,
                                  rationale: "“\(try #require(disc["witness_quote"] as? String))”", actor: "Priya Nair")
        _ = try await map.addLink(caseID: c.id, type: .supports, from: bankDoc, to: qn,
                                  rationale: "Two debits: \((disc["bank_entries"] as? [String] ?? []).joined(separator: ", "))", actor: "Priya Nair")

        // 6. The parent discrepancy action and its financial and interview children (the interview waits for the trace).
        let ak2 = try #require(key["actions"] as? [String: Any])
        let pk = try #require(ak2["parent"] as? [String: Any])
        let parent = try await svc.createAction(caseID: c.id, .init(title: try #require(pk["title"] as? String), purpose: "Reconcile the accounts",
                                                                   deliverable: try #require(pk["deliverable"] as? String), responsible: "Priya Nair",
                                                                   servesQuestions: [question]), actor: "Priya Nair")
        var children: [String: UUID] = [:]
        for ch in try #require(ak2["children"] as? [[String: Any]]) {
            children[try #require(ch["kind"] as? String)] = try await svc.createAction(caseID: c.id, .init(
                title: try #require(ch["title"] as? String), purpose: "Part of the discrepancy", deliverable: try #require(ch["deliverable"] as? String),
                responsible: "Priya Nair", reviewer: "Sunil Rao", parentTaskID: parent, servesQuestions: [question]), actor: "Priya Nair")
        }
        let fin = try #require(children["financial"]), talk = try #require(children["interview"])
        _ = try await svc.file.addDependency(caseID: c.id, taskID: talk, dependsOn: fin, reason: "ask about the second PO", actor: "Priya Nair")

        // 7. One witness, two branches: the same canonical record in the question's frame and in the interview's.
        let meera = try await svc.file.addPerson(caseID: c.id, name: "Meera Shah", role: .witness, entityID: nil, contact: nil, notes: nil, actor: "Priya Nair")
        let mn = CaseMapNodeID(caseID: c.id, kind: .person, id: meera)
        _ = try await svc.file.placeInFrame(caseID: c.id, frame: qn, member: mn, purpose: "her account", actor: "Priya Nair")
        _ = try await svc.file.placeInFrame(caseID: c.id, frame: CaseMapNodeID(caseID: c.id, kind: .task, id: talk), member: mn, purpose: "to be re-interviewed", actor: "Priya Nair")

        // 8. Identities: the signatory is recorded; the namesake is not merged by the app; the external examiner is reported.
        let ik = try #require(key["identities"] as? [String: Any])
        _ = try await svc.file.addPerson(caseID: c.id, name: try #require(ik["signatory"] as? String), role: .other, entityID: nil, contact: nil,
                                         notes: "authorised signatory of account 8804", actor: "Priya Nair")
        let examiner = try await svc.file.recordActor(caseID: c.id, kind: .reportedExternal, displayName: try #require(ik["external_performer"] as? String), actor: "Priya Nair")

        // 9. The work is done, submitted and accepted by the reviewer — and the question stays open, with no finding of guilt.
        for t in [fin, talk] {
            try await svc.completeTask(caseID: c.id, taskID: t, actor: "Priya Nair")
            try await svc.file.submitAction(caseID: c.id, taskID: t, note: nil, actor: "Priya Nair")
            #expect(try await svc.file.reviewAction(caseID: c.id, taskID: t, accept: true, note: nil, actor: "Sunil Rao") == .independent)
        }
        try await svc.file.recordOutcome(caseID: c.id, taskID: fin, outcome: .discrepancyExplained, note: "KS-77985 settles PO-561", actor: "Priya Nair")

        // The answer key, observed through the canonical records and the map projection.
        let p = try #require(await caseMapLoad(f).projection)
        #expect(p.links(of: qn).contains { $0.type == .challenges && $0.from == witnessDoc } && p.links(of: qn).contains { $0.type == .supports && $0.from == bankDoc },
                "both sources are kept on the question")
        let disposition = try await svc.file.allegations(caseID: c.id).first { $0.id == question }?.disposition
        #expect(disposition == .pending && (ak2["question_stays_open_after_work_completes"] as? Bool) == true, "resolution stays open")
        let inQuestion = try #require(CaseMapFrames.frame(of: qn, in: p)).contains(mn)
        let inInterview = try #require(CaseMapFrames.frame(of: CaseMapNodeID(caseID: c.id, kind: .task, id: talk), in: p)).contains(mn)
        #expect(inQuestion && inInterview)
        #expect(p.nodes.filter { $0.id == mn }.count == 1, "one canonical witness, two appearances")
        #expect(p.links(of: CaseMapNodeID(caseID: c.id, kind: .task, id: talk)).contains { $0.type == .dependsOn && $0.to == CaseMapNodeID(caseID: c.id, kind: .task, id: fin) })
        ledger = try await svc.file.reportLedger(caseID: c.id)
        #expect(ledger.contract(fin)?.parentTaskID == parent && ledger.contract(talk)?.parentTaskID == parent)
        #expect(ledger.contract(fin)?.deliverable == (ak2["children"] as? [[String: Any]])?.first?["deliverable"] as? String)
        let people = try await svc.file.people(caseID: c.id)
        #expect(people.filter { $0.name == ik["signatory"] as? String }.count == 1, "the namesake document created no second person")
        #expect(try await SmartMapContractsTests.count(db, "SELECT COUNT(*) FROM investigation_identity_decisions WHERE case_id = ?;", [.uuid(c.id)])
                == ik["automatic_identity_decisions"] as? Int)
        let ext = try #require(ledger.actors.first { $0.id == examiner })
        #expect(ext.kind == .reportedExternal && ext.isAuthenticated == (ik["external_performer_is_authenticated"] as? Bool))
        #expect(ledger.actors.first { $0.displayName == "Priya Nair" }?.isLegacyName == true)
        // No conclusion is invented anywhere in the case's own records.
        let allText = (try await svc.file.allegations(caseID: c.id).map(\.text) + ledger.points.map(\.statement)).joined(separator: " ").lowercased()
        #expect(!allText.contains("fraud") && !allText.contains("guilty"))
        // The pending later-milestone items are declared in the answer key, not silently skipped.
        #expect((key["pending_later_milestones"] as? [String])?.count == 3)
    }
}
