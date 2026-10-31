//
//  InvestigationWorkspaceIntakeTests.swift
//  KalsmritikoshTests
//
//  Case bench 2026-10-20: a case opened over a workspace had no sources in scope, and an included
//  email authorized only the email — never the report attached to it. Opening the case now takes
//  in the workspace's documents and their attachments, each inclusion recorded.
//

import AppKit
import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Case intake takes in the workspace's documents and their attachments", .serialized)
struct InvestigationWorkspaceIntakeTests {

    /// A one-page text PDF.
    private func pdf(_ text: String) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        ctx.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
            .draw(in: CGRect(x: 54, y: 54, width: 504, height: 684))
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage(); ctx.closePDF()
        return data as Data
    }

    private func email(attaching report: Data) -> String {
        let b64 = report.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn])
        return """
        From: Records <records@agency.example>\r
        To: Investigator <investigator@firm.example>\r
        Subject: Records for accident 220962021\r
        Date: Tue, 20 Oct 2026 10:00:00 +0000\r
        Message-ID: <intake-test@agency.example>\r
        MIME-Version: 1.0\r
        Content-Type: multipart/mixed; boundary="b1"\r
        \r
        --b1\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        Please find the investigation summary attached.\r
        --b1\r
        Content-Type: application/pdf; name="investigation-summary.pdf"\r
        Content-Disposition: attachment; filename="investigation-summary.pdf"\r
        Content-Transfer-Encoding: base64\r
        \r
        \(b64)\r
        --b1--\r

        """
    }

    @Test("An email in the workspace brings its attached report into the case")
    func emailAndAttachment() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("intake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let report = pdf("OSHA accident investigation summary 220962021\nEvent date: June 8, 2017\nAn employee was overcome by chemical fumes and hospitalized.")
        let eml = temp.appendingPathComponent("records.eml")
        try email(attaching: report).write(to: eml, atomically: true, encoding: .utf8)

        let state = await AppState(bookmarks: BookmarkStore(ephemeral: true))
        await state.boot(databaseURL: temp.appendingPathComponent("ledger.sqlite"))
        let ingest = try #require(await state.ingest)
        let db = try #require(await state.database)
        let ingested = try await ingest.ingest(fileAt: eml)

        let ws = UUID(), now = Date()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(ws), .text("Accident 220962021"), .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970)])
        try await #require(await state.workspaceSourceCoordinator).addSources([ingested.fileRecord.id], to: ws, at: now)

        let cases = try #require(await state.investigationCases)
        let intake = try #require(await state.investigationWorkspaceIntake)
        let c = try await cases.createCase(workspaceID: ws, title: "Accident 220962021", actor: "test", at: now)
        let (updated, included) = try await intake.includeWorkspaceSources(caseID: c.id, actor: "test", at: now)
        #expect(included >= 2, "the email and its attachment")
        #expect(updated.revision > c.revision)

        // Asked inside the case, the date comes from the attached report.
        let answers = try #require(await state.investigationAnswers)
        let answer = try await answers.answer(caseID: c.id, question: "When did the accident happen?",
                                              access: SensitiveAccessContext(scope: SensitiveScope(
                                                workspaceID: ws, maximumSensitivity: .restricted,
                                                permitsPrivilegedMaterial: false, purpose: .retrieval))).verified
        #expect(answer.body.contains("2017"), "\(answer.body.prefix(300))")

        // Re-running takes in nothing new; an inclusion is never repeated.
        let (_, again) = try await intake.includeWorkspaceSources(caseID: c.id, actor: "test", at: now)
        #expect(again == 0)
    }

    @Test("A ZIP in the workspace brings its files into the case")
    func zipMembers() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("intake-zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let zip = try ZIPTestFixture.writeZIP([
            ZIPTestFixture.stored("decision.txt", "SMITH v. JONES. No. 4781. Supreme Court of Texas. Dec. 16, 1927. Affirmed."),
            ZIPTestFixture.stored("notes.txt", "Investigator notes: the deed was recorded on May 2, 1925."),
        ], named: "case-bundle.zip")
        let state = await AppState(bookmarks: BookmarkStore(ephemeral: true))
        await state.boot(databaseURL: temp.appendingPathComponent("ledger.sqlite"))
        let ingest = try #require(await state.ingest)
        let db = try #require(await state.database)
        let ingested = try await ingest.ingest(fileAt: zip)
        let ws = UUID(), now = Date()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(ws), .text("Smith v. Jones"), .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970)])
        try await #require(await state.workspaceSourceCoordinator).addSources([ingested.fileRecord.id], to: ws, at: now)
        let cases = try #require(await state.investigationCases)
        let c = try await cases.createCase(workspaceID: ws, title: "Smith v. Jones", actor: "test", at: now)
        let (_, included) = try await #require(await state.investigationWorkspaceIntake).includeWorkspaceSources(caseID: c.id, actor: "test", at: now)
        #expect(included == 3, "the ZIP and its two files")
    }

    // MARK: Investigator workflow review 2026-10-30, I1

    @Test("A document added to the workspace later is previewed, not included, until approved; the approved document answers with its citation; repeating adds nothing twice; an excluded source stays excluded")
    func laterDocumentsNeedExplicitApproval() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("intake-later-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let first = temp.appendingPathComponent("opening-memo.txt")
        try "Opening memo. The supplier Dalmia Traders invoiced ₹10,000 on 3 March 2026 for the generator service.".write(to: first, atomically: true, encoding: .utf8)
        let state = await AppState(bookmarks: BookmarkStore(ephemeral: true))
        await state.boot(databaseURL: temp.appendingPathComponent("ledger.sqlite"))
        let ingest = try #require(await state.ingest)
        let db = try #require(await state.database)
        let coordinator = try #require(await state.workspaceSourceCoordinator)
        let ws = UUID(), now = Date()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(ws), .text("Supplier payment"), .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970)])
        let ingestedFirst = try await ingest.ingest(fileAt: first)
        try await coordinator.addSources([ingestedFirst.fileRecord.id], to: ws, at: now)

        let cases = try #require(await state.investigationCases)
        let intake = try #require(await state.investigationWorkspaceIntake)
        let c = try await cases.createCase(workspaceID: ws, title: "Supplier payment", actor: "test", at: now)
        let (opened, firstIncluded) = try await intake.includeWorkspaceSources(caseID: c.id, actor: "test", at: now)
        #expect(firstIncluded == 1)

        // A second document arrives in the workspace after the case was opened.
        let later = temp.appendingPathComponent("bank-statement.txt")
        try "Bank statement. A refund of ₹2,000 from Dalmia Traders was credited on 9 March 2026.".write(to: later, atomically: true, encoding: .utf8)
        let ingestedLater = try await ingest.ingest(fileAt: later)
        try await coordinator.addSources([ingestedLater.fileRecord.id], to: ws, at: now.addingTimeInterval(60))

        // Reopening (fetching) the case widens nothing: the preview shows the new file as pending.
        let reopened = try #require(try await cases.fetch(caseID: c.id))
        #expect(reopened.caseHeader.revision == opened.revision, "reopening alone must not change the scope")
        #expect(reopened.sources.filter(\.inScope).count == 1)
        let preview = try await intake.preview(caseID: c.id)
        #expect(preview.inScope == 1 && preview.excluded.isEmpty && preview.pending.count == 1)
        #expect(preview.pending.first?.label == "bank-statement.txt" && preview.pending.first?.isRoot == true)
        #expect(preview.hasChanges)
        // Still nothing included by previewing.
        #expect(try #require(try await cases.fetch(caseID: c.id)).sources.filter(\.inScope).count == 1)

        // Approve it through the explicit control: the case now answers from it, with its citation.
        let newVersion = try #require(preview.pending.first?.sourceVersionID)
        let (afterApproval, added) = try await intake.include(caseID: c.id, approved: [newVersion], actor: "test", at: now.addingTimeInterval(120))
        #expect(added == 1 && afterApproval.revision > opened.revision)
        let record = try #require(try await cases.fetch(caseID: c.id))
        #expect(record.sources.filter(\.inScope).map(\.sourceRef).contains(newVersion.uuidString))
        #expect(record.events.contains { $0.action == .sourceIncluded && $0.detail == newVersion.uuidString })
        let answers = try #require(await state.investigationAnswers)
        let access = SensitiveAccessContext(scope: SensitiveScope(workspaceID: ws, maximumSensitivity: .restricted,
                                                                  permitsPrivilegedMaterial: false, purpose: .retrieval))
        let answer = try await answers.answer(caseID: c.id, question: "When was the refund credited?", access: access).verified
        #expect(answer.body.contains("2026") || answer.body.contains("March"), "\(answer.body.prefix(300))")
        #expect(!answer.citations.isEmpty, "the answer from the added file carries a citation")

        // Repeating the review adds nothing and duplicates nothing.
        let again = try await intake.preview(caseID: c.id)
        #expect(again.pending.isEmpty && again.inScope == 2)
        let (_, repeated) = try await intake.include(caseID: c.id, approved: nil, actor: "test", at: now.addingTimeInterval(180))
        #expect(repeated == 0)
        #expect(try #require(try await cases.fetch(caseID: c.id)).sources.filter { $0.sourceRef == newVersion.uuidString }.count == 1)

        // A deliberately excluded source stays excluded: it is listed as such, never pending, never re-included.
        let current = try #require(try await cases.fetch(caseID: c.id)).caseHeader
        _ = try await cases.excludeSource(caseID: c.id, expectedRevision: current.revision, sourceRef: newVersion.uuidString,
                                          sourceKind: .sourceVersion, note: "Out of period", actor: "test", at: now.addingTimeInterval(240))
        let afterExclusion = try await intake.preview(caseID: c.id)
        #expect(afterExclusion.pending.isEmpty && afterExclusion.inScope == 1)
        #expect(afterExclusion.excluded.map(\.label) == ["bank-statement.txt"] && afterExclusion.excluded.first?.note == "Out of period")
        let (_, afterExcluded) = try await intake.include(caseID: c.id, approved: nil, actor: "test", at: now.addingTimeInterval(300))
        #expect(afterExcluded == 0)
        #expect(try #require(try await cases.fetch(caseID: c.id)).sources.first { $0.sourceRef == newVersion.uuidString }?.inScope == false)
    }
}
