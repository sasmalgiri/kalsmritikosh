//
//  AcceptanceCaseTests.swift
//  KalsmritikoshTests
//
//  Investigator workflow review 2026-10-30 — the one realistic acceptance case, run through the
//  PRODUCTION services on a throwaway ledger: a supplier alleged to have been paid twice. Expected
//  behaviour, from the review: invoice copies do not become payments; gross ₹10,000 and net ₹8,000
//  are kept apart and neither is a loss; competing accounts and attribution uncertainty are exposed;
//  missing and unreadable material stays visibly incomplete; new evidence enters through an explicit
//  scope review; the investigator requests the missing material, records the explanation and updates
//  the finding; the report tells established, disputed and unknown apart with reopenable citations;
//  every action survives reopening without retyping. An acceptance scenario, not a measured result.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Acceptance case — supplier paid twice", .serialized)
struct AcceptanceCaseTests {

    /// The fixture folder in the source tree (the bundle flattens resources; the tree is authoritative).
    private static var sourceFolder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Kalsmritikosh/Resources/Fixtures/\(AcceptanceCaseFixture.folderName)", isDirectory: true)
    }

    private func access(_ ws: UUID) -> SensitiveAccessContext {
        SensitiveAccessContext(scope: SensitiveScope(workspaceID: ws, maximumSensitivity: .restricted, permitsPrivilegedMaterial: false, purpose: .export))
    }

    @Test("The case runs end to end through the production services with the review's expected behaviour")
    func supplierPaidTwice() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("acceptance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let docs = temp.appendingPathComponent("documents", isDirectory: true)
        let files = try AcceptanceCaseFixture.materialise(from: Self.sourceFolder, into: docs, excluding: [AcceptanceCaseFixture.laterDocument])
        #expect(files.count == AcceptanceCaseFixture.fixtureNames.count)   // 9 documents + the unreadable scan

        let state = await AppState(bookmarks: BookmarkStore(ephemeral: true))
        await state.boot(databaseURL: temp.appendingPathComponent("ledger.sqlite"))
        let ingest = try #require(await state.ingest)
        let db = try #require(await state.database)
        let coordinator = try #require(await state.workspaceSourceCoordinator)
        let cases = try #require(await state.investigationCases)
        let intake = try #require(await state.investigationWorkspaceIntake)
        let service = try #require(await state.personaJobs)
        let results = JobResultRepository(database: db)
        let caseFiles = try #require(await state.caseFiles)
        let now = Date()

        // 1. Ingest. The unreadable scan is refused and the refusal is on record — not silently absent.
        var fileIDs: [String: UUID] = [:]
        for (name, url) in files where name != AcceptanceCaseFixture.scanName {
            fileIDs[name] = try await ingest.ingest(fileAt: url).fileRecord.id
        }
        let scan = try #require(files[AcceptanceCaseFixture.scanName])
        let scanResult = try await ingest.ingest(fileAt: scan)
        #expect(scanResult.processingStatus == .failed && scanResult.processingStage == "parser", "a scan with no text is recorded as a failed parse, not as an empty document")
        #expect(scanResult.completionSnapshot?.completionState == .failed && scanResult.completionSnapshot?.isEvidenceReady == false)
        #expect(scanResult.completionSnapshot?.limitations.contains("textExtraction: failed") == true, "\(scanResult.completionSnapshot?.limitations ?? [])")
        #expect(scanResult.chunkCount == 0, "nothing readable is pretended")

        // 2. Workspace, case, scope.
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(ws), .text("Dalmia Traders payment"), .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970)])
        try await coordinator.addSources(Set(fileIDs.values), to: ws, at: now)
        let c = try await cases.createCase(workspaceID: ws, title: "Was Dalmia Traders paid twice?", actor: "Priya Nair", at: now)
        let (_, included) = try await intake.includeWorkspaceSources(caseID: c.id, actor: "Priya Nair", at: now)
        #expect(included >= 9, "the nine readable documents are in scope: \(included)")

        func run(_ persona: ApplicationDefinitionID, _ jobID: String) async throws -> JobResultRecord {
            let job = try #require(await service.jobs(forPersona: persona).first { $0.id == jobID }, "job \(jobID)")
            _ = try await service.launch(job, context: PersonaJobLaunchContext(caseID: c.id, access: access(ws), actor: "Priya Nair", at: now))
            return try #require(try await results.latest(caseID: c.id, jobID: jobID), "no result for \(jobID)")
        }

        // 3. Invoice copies are one statement, not three payments; totals are stated amounts, not payments or losses.
        let money = try await run(ForensicAccountantPersonaPackage.applicationID, "fa.funds-tracing")
        #expect(money.state == .draft)
        let tenK = money.content.rows.filter { JobDeliverableText.normalisedAmount($0.title) == "INR 10000" }
        #expect(tenK.count >= 3, "the invoice, its two copies and the bank debit each state ₹10,000 — every statement kept with its quote: \(tenK.map { $0.detail ?? "" })")
        #expect(tenK.filter { $0.flags.contains { $0.hasPrefix("repeats the same statement") } }.count >= 1, "the second e-mail copy repeats the first's statement word for word")
        let total = try #require(money.content.rows.first { $0.title.hasPrefix("Stated amounts in INR") })
        #expect(total.title.contains("distinct") && total.title.contains("counting every mention"), "the repeated statement is counted once in the distinct figure: \(total.title)")
        #expect(total.flags.contains { $0.contains("not a loss, damages, payment or recovery figure") })
        #expect(!money.content.rows.contains { $0.title.lowercased().contains("fraud") || $0.title.lowercased().contains("loss:") })

        // 4. Classified cash flows: gross ₹10,000, returned ₹2,000, net ₹8,000 — the invoice is not a movement; nothing is labelled a loss.
        var engagement = ForensicEngagement(title: "Dalmia Traders", now: now)
        var payment = FATransaction(); payment.date = "2026-03-05"; payment.descriptionText = "Transfer to Dalmia Traders"; payment.amount = "₹10,000"
        payment.kind = .payment; payment.reference = "UTR 55021"; payment.sourceDoc = "bank-statement-7718-march.md"; payment.account = "7718"
        var refund = FATransaction(); refund.date = "2026-03-09"; refund.descriptionText = "Credit from Dalmia Traders"; refund.amount = "₹2,000"
        refund.kind = .refund; refund.reference = "UTR 55340"; refund.sourceDoc = "bank-statement-7718-march.md"; refund.account = "7718"
        var invoice = FATransaction(); invoice.date = "2026-03-03"; invoice.descriptionText = "Invoice INV-2041"; invoice.amount = "₹10,000"
        invoice.kind = .invoice; invoice.reference = "INV-2041"; invoice.sourceDoc = "invoice-INV-2041.md"
        var copy = FATransaction(); copy.date = "2026-03-03"; copy.descriptionText = "Invoice INV-2041 (e-mail copy)"; copy.amount = "₹10,000"
        copy.kind = .invoice; copy.reference = "INV-2041"; copy.sourceDoc = "email-invoice-resend-1.eml"
        engagement.schedule = [payment, refund, invoice, copy]
        let summary = engagement.summary
        #expect(summary.byCurrency["INR"]?.gross == 10_000 && summary.byCurrency["INR"]?.returned == 2_000 && summary.byCurrency["INR"]?.net == 8_000)
        #expect(summary.notMovements.contains(invoice.id) && summary.notMovements.contains(copy.id), "invoices are statements of a claim, not money moving")
        #expect(summary.duplicateCopies.isEmpty && summary.possibleDuplicates.isEmpty, "one payment, one refund — no duplicate movement")

        // 5. Competing accounts and attribution: Asha asserts, Vikram denies; the sentence naming Asha first is Vikram's.
        let statements = try await run(CompliancePersonaPackage.applicationID, "hr.statements")
        #expect(statements.state == .draft, "\(statements.content.limitations)")
        let rows = statements.content.rows
        let asha = rows.filter { $0.fields?["witness"] == "Asha Rao" }, vikram = rows.filter { $0.fields?["witness"] == "Vikram Rao" }
        #expect(!asha.isEmpty && !vikram.isEmpty, "both accounts are present: \(rows.map(\.title))")
        #expect(vikram.contains { $0.flags.contains("denial") }, "Vikram's denial is marked")
        #expect(rows.contains { ($0.fields?["witness"] == "Asha Rao" && $0.flags.contains { $0.hasPrefix("asserts what Vikram Rao denies") })
                                || ($0.fields?["witness"] == "Vikram Rao" && $0.flags.contains { $0.hasPrefix("denies what Asha Rao asserts") }) },
                "the shared ₹10,000 is not called agreement: \(rows.flatMap(\.flags))")
        #expect(!asha.contains { ($0.detail ?? "").contains("approval came after") }, "the sentence naming Asha first is not Asha's statement")
        #expect(vikram.contains { ($0.detail ?? "").contains("approval came after") }, "it is Vikram's — the reporting verb decides")
        #expect(!rows.contains { ($0.detail ?? "").contains("booked the riverside hall") }, "the picnic memo has no attributed statement")

        // 6. Repeated reports are one shared-text family; the unrelated memo sharing only the footer is not grouped; nothing is called independent.
        let sources = try await run(JournalistPersonaPackage.applicationID, "jrn.source-map")
        func family(_ name: String) -> String? { sources.content.rows.first { $0.title == name }?.fields?["family"] }
        #expect(family("report-generator-service-1.md") == family("report-generator-service-2.md") && family("report-generator-service-1.md")?.hasSuffix(SourceFamilyExecutor.sharedText) == true)
        #expect(family("email-invoice-resend-1.eml") == family("email-invoice-resend-2.eml"), "two copies of one invoice share text")
        #expect(family("memo-staff-picnic.md") == SourceFamilyExecutor.unassessedFamily, "a shared footer is boilerplate, not a relationship")
        #expect(!sources.content.rows.contains { ($0.fields?["family"] ?? "").lowercased().contains("independent by") })

        // 7. The namesake is one more name form; the app merges no identity on its own.
        let parties = try await run(LawyerPersonaPackage.applicationID, "law.parties-issues")
        #expect(parties.content.rows.contains { $0.title == "Asha Rao" && !$0.flags.contains("merged by a person") })

        // 8. The missing attachment is visible in the evidence register.
        let register = try await run(CompliancePersonaPackage.applicationID, "hr.evidence-register")
        let resend2 = try #require(register.content.rows.first { $0.title.contains("email-invoice-resend-2") || ($0.detail ?? "").contains("email-invoice-resend-2") || $0.fields?["document"]?.contains("resend-2") == true },
                                   "the second e-mail is in the register: \(register.content.rows.map(\.title))")
        #expect(resend2.flags.contains(InventoryExecutor.attachmentFlag), "the e-mail says 'see the attached receipt' and nothing is attached: \(resend2.flags)")

        // 9. The case file: the allegation, the witness rows carried in, the request for the missing receipt.
        let a = try await caseFiles.file.addAllegation(caseID: c.id, text: "Dalmia Traders was paid twice for invoice INV-2041", actor: "Priya Nair")
        let ashaIndex = try #require(rows.firstIndex { $0.fields?["witness"] == "Asha Rao" && !$0.refs.isEmpty })
        let vikramIndex = try #require(rows.firstIndex { $0.fields?["witness"] == "Vikram Rao" && $0.flags.contains("denial") && !$0.refs.isEmpty })
        try await JobResultHandoff.addToAllegation(statements, row: ashaIndex, allegationID: a, stance: .supports, note: nil, file: caseFiles.file, actor: "Priya Nair")
        try await JobResultHandoff.addToAllegation(statements, row: vikramIndex, allegationID: a, stance: .contradicts, note: nil, file: caseFiles.file, actor: "Priya Nair")
        try await JobResultHandoff.addToReport(statements, row: vikramIndex, include: true, allegationID: a, file: caseFiles.file, actor: "Priya Nair")
        _ = try await caseFiles.addTask(caseID: c.id, workspaceID: ws, title: "Request the receipt referred to in the 6 March e-mail (not attached)",
                                        assignee: "Priya Nair", due: now.addingTimeInterval(7 * 86_400), actor: "Priya Nair")
        // An adverse finding is refused until the response is recorded.
        await #expect(throws: CaseFileError.self) {
            try await caseFiles.file.decide(allegationID: a, caseID: c.id, disposition: .substantiated, rationale: "Two invoices", actor: "Priya Nair")
        }

        // 10. New evidence enters only through the explicit scope review.
        let laterURL = docs.appendingPathComponent(AcceptanceCaseFixture.laterDocument)
        try FileManager.default.copyItem(at: Self.sourceFolder.appendingPathComponent(AcceptanceCaseFixture.laterDocument), to: laterURL)
        let laterID = try await ingest.ingest(fileAt: laterURL).fileRecord.id
        try await coordinator.addSources([laterID], to: ws, at: now.addingTimeInterval(60))
        #expect(try #require(try await cases.fetch(caseID: c.id)).sources.filter(\.inScope).count == included, "nothing widened by itself")
        let preview = try await intake.preview(caseID: c.id)
        #expect(preview.pending.map(\.label) == [AcceptanceCaseFixture.laterDocument])
        _ = try await intake.include(caseID: c.id, approved: Set(preview.pending.map(\.id)), actor: "Priya Nair", at: now.addingTimeInterval(120))
        let afterInclusion = try await run(CompliancePersonaPackage.applicationID, "hr.statements")
        #expect(afterInclusion.content.rows.contains { $0.fields?["witness"] == "Vikram Rao" && ($0.detail ?? "").contains("resend of the same invoice") },
                "the innocent explanation is read as Vikram's statement")

        // 11. The explanation is recorded as the response; the finding is updated; the report keeps established, disputed and unknown apart.
        try await caseFiles.file.recordResponse(allegationID: a, caseID: c.id,
                                                response: "The second copy was a resend of the same invoice; the bank shows one debit of ₹10,000 and a refund of ₹2,000.", actor: "Priya Nair")
        try await caseFiles.file.decide(allegationID: a, caseID: c.id, disposition: .unsubstantiated,
                                        rationale: "One debit on the bank statement; the second invoice is a resend; the refund is a supplier correction.", actor: "Priya Nair")
        let snapshot = try #require(try await caseFiles.snapshot(caseID: c.id, custody: []))
        let report = CaseFileDocuments.caseFileReport(snapshot, by: "Priya Nair")
        #expect(report.contains("**Unsubstantiated**") && report.contains("Response: “The second copy was a resend"))
        #expect(report.contains("Supports:\n- ") && report.contains("Contradicts:\n- "), "both accounts are in the report with their passages")
        #expect(report.contains("(from job:hr.statements:"), "the carried rows name the result revision they came from")
        #expect(report.contains("## Reviewed results included in this report"))
        #expect(report.contains("## Unresolved questions and limitations"))
        #expect(!report.lowercased().contains("fraud"))
        #expect(report.contains("## Tasks\n- [ ] Request the receipt"))

        // 12. Everything survives reopening: a fresh service over the same ledger reads the same record.
        let workspaces = try #require(await state.workspaces)
        let reopened = try #require(try await CaseFileService(database: db, cases: cases, workspaces: workspaces).snapshot(caseID: c.id, custody: []))
        #expect(reopened.allegations.first?.disposition == .unsubstantiated && reopened.allegations.first?.response == snapshot.allegations.first?.response)
        #expect(reopened.grid.count == 2 && reopened.grid.allSatisfy { $0.quote != nil && $0.origin != nil })
        #expect(reopened.reportItems.count == 1 && reopened.tasks.count == 1)
        #expect(CaseFileDocuments.caseFileReport(reopened, by: "Priya Nair").replacingOccurrences(of: #"Produced by .*"#, with: "", options: .regularExpression)
                == report.replacingOccurrences(of: #"Produced by .*"#, with: "", options: .regularExpression))
    }
}
