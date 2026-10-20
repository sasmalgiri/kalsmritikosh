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

        let state = await AppState(bookmarks: BookmarkStore())
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
        let state = await AppState(bookmarks: BookmarkStore())
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
}
