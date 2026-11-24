//
//  ALCOAGroup4Tests.swift
//  KalsmritikoshTests
//
//  ALCOA++ program, group 4 (owner 2026-11-24; docs/ALCOA_PROGRAM_2026-11-24.md): ALC-13 data integrity report,
//  ALC-17 certified copy + versioned cleaned text, ALC-18 legible (rejected AI writes kept, Ask transcripts retracted),
//  ALC-19 one export date style, ALC-20 archival PDF + retention register, ALC-21 key rotation, sealed exports, capture
//  hosts. No model, no network, no API spend.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("ALCOA group 4 — ALC-13/17/18/19/20/21", .serialized)
struct ALCOAGroup4Tests {

    // MARK: - ALC-19 consistent

    @Test("ALC-19: a day is '3 Aug 2026', a time is ISO 8601 with the zone stated, money always carries its ISO code")
    func oneExportDateStyle() throws {
        let kolkata = try #require(TimeZone(identifier: "Asia/Kolkata"))
        var c = Calendar(identifier: .gregorian); c.timeZone = kolkata
        let at = try #require(c.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 14, minute: 5, second: 9)))
        #expect(ExportDateStyle.day(at, zone: kolkata) == "3 Aug 2026")
        #expect(ExportDateStyle.stamp(at, zone: kolkata) == "2026-08-03T14:05+05:30 (Asia/Kolkata)")
        #expect(ExportDateStyle.stamp(at, zone: kolkata, seconds: true) == "2026-08-03T14:05:09+05:30 (Asia/Kolkata)")
        let utc = try #require(TimeZone(identifier: "UTC"))
        #expect(ExportDateStyle.stamp(at, zone: utc).hasSuffix("Z (\(utc.identifier))"))
        #expect(ExportDateStyle.zoneStatement(zone: kolkata, at: at).contains("Asia/Kolkata, UTC+05:30"))
        #expect(ExportDateStyle.money(Decimal(string: "50000")!, currency: "INR") == "INR 50,000.00")
        #expect(ExportDateStyle.money(Decimal(string: "12.5")!, currency: "") == "12.5 (currency not stated)")
        #expect(ExportDateStyle.money(Decimal(string: "7")!, currency: "$").contains("currency not stated"))
        #expect(CaseMapMoney(amount: Decimal(string: "18400.3")!, currency: "USD").display == "USD 18,400.30")
        // The case report's day and stamp, the chronology drafter and the persona report builders read the same style.
        #expect(CaseFileDocuments.d(at) == ExportDateStyle.day(at))
        #expect(CaseFileDocuments.t(at) == ExportDateStyle.stamp(at))
        #expect(ChronologyDrafter.day(at) == ExportDateStyle.day(at))
        #expect(ExportDateStyle.stampWriter.string(from: at) == ExportDateStyle.stamp(at))
        #expect(CaseFileDocuments.footer("Asha", at).contains("ISO 8601 with the zone stated"))
    }

    @Test("ALC-19: no report builder still uses a locale date style")
    func noLocaleDateStyleInReports() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Kalsmritikosh")
        for name in ["Investigate/ACHAnalysis.swift", "Investigate/RootCauseAnalysis.swift", "Investigate/PersonaDeliverables2.swift",
                     "Investigate/SIUReferral.swift", "Investigate/FactCheckMemo.swift", "Investigate/PrivilegeLog.swift",
                     "Investigate/DisputeFile.swift", "Investigate/WorkplaceInvestigation.swift", "Investigate/StudioAudit.swift",
                     "Investigate/CaseFile/CaseFileDocuments.swift", "Export/ChronologyDrafter.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            #expect(!text.contains("dateStyle = .long") && !text.contains("dateStyle = .medium"), "\(name)")
        }
    }

    // MARK: - ALC-17 original

    @Test("ALC-17: the cleaned text names its cleaner and SHA-256; a change keeps the earlier text; the same text is no new version; erasure removes them")
    func cleanTextVersioned() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let row = try #require(try await f.db.query("SELECT id, clean_content, clean_cleaner_version, clean_sha256 FROM knowledge_objects WHERE file_id = ? LIMIT 1;",
                                                    [.uuid(f.exclusiveFile)]).first)
        let id = try #require(row.uuid(0))
        let first = try #require(row.string(1))
        #expect(row.string(2) == ReaderTextCleaner.version, "ingest stores the cleaner version")
        #expect(row.string(3) == CertifiedCopy.sha256(Data(first.utf8)), "and the SHA-256 of the cleaned text")
        let repo = KnowledgeObjectRepository(database: f.db)
        try await repo.setCleanContent(first, forID: id)
        #expect(try await repo.cleanTextVersions(id: id).count == 1, "the same text again is not a new version")
        try await repo.setCleanContent("A later cleaner's text.", forID: id, cleanerVersion: "reader-clean-2")
        let versions = try await repo.cleanTextVersions(id: id)
        #expect(versions.count == 2)
        #expect(versions[0].body == "A later cleaner's text." && versions[0].cleanerVersion == "reader-clean-2" && versions[0].replacedAt == nil)
        #expect(versions[1].body == first && versions[1].cleanerVersion == ReaderTextCleaner.version && versions[1].sha256 == CertifiedCopy.sha256(Data(first.utf8)))
        #expect(versions[1].replacedAt != nil)
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE clean_content_versions SET body = 'x';", []) }
        await #expect(throws: (any Error).self) { try await f.db.exec("DELETE FROM clean_content_versions;", []) }
        // The erasure of the case and its own documents removes the object and its kept cleaned texts.
        let out = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: true, reason: "Client request", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil, "\(out.report.refused ?? "")")
        #expect(try await CaseErasureTests.count(f.db, "SELECT COUNT(*) FROM clean_content_versions WHERE object_id = ?;", [.uuid(id)]) == 0)
        await f.state.shutdown()
    }

    @Test("ALC-17: a certified copy names its SHA-256 (read back), sources, producer, time + zone; a changed file reads MISMATCH; the certification is kept")
    func certifiedCopy() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let url = f.temp.appendingPathComponent("report.md")
        CertifiedCopy.ledger.set(f.db)
        let written = await ProtectedExport.writeRechecked("# Report\nKestrel was paid.", to: url, refuseIfPresent: false, names: { [] })
        guard case .success(let text) = written else { Issue.record("not written"); return }
        let side = try String(contentsOf: CertifiedCopy.sidecarURL(for: url), encoding: .utf8)
        let fields = CertifiedCopy.fields(ofSidecar: side)
        #expect(fields["sha256"] == CertifiedCopy.sha256(Data(text.utf8)))
        #expect(fields["copy_kind"] == "derived" && fields["verify_result"]?.hasPrefix("verified") == true)
        #expect(fields["producer"]?.hasPrefix("Investigations Made Easy") == true && fields["time_zone"] == TimeZone.current.identifier)
        #expect(fields["produced_at"]?.contains("(\(TimeZone.current.identifier))") == true)
        #expect(side.contains("not an e-signature") && !side.lowercased().contains("compliant"))
        let kept = try await f.db.query("SELECT sha256, copy_kind, sidecar_written, recorded_tz FROM export_certifications WHERE file_name = 'report.md';", [])
        #expect(kept.count == 1 && kept.first?.string(0) == fields["sha256"] && kept.first?.int(2) == 1)
        await #expect(throws: (any Error).self) { try await f.db.exec("DELETE FROM export_certifications;", []) }
        // A file changed after writing does not verify.
        try Data("changed".utf8).write(to: url)
        let again = CertifiedCopy.certify(fileAt: url, kind: .derived, sources: ["v1"], producedBy: "Asha", expectedSHA256: fields["sha256"])
        #expect(again.verifyResult.hasPrefix("MISMATCH"))
        // An original copied out verifies against its intake SHA-256.
        let orig = f.temp.appendingPathComponent("original.txt")
        try Data("original bytes".utf8).write(to: orig)
        let o = CertifiedCopy.certify(fileAt: orig, kind: .original, sources: ["v9"], producedBy: "Asha",
                                      originalSHA256: CertifiedCopy.sha256(Data("original bytes".utf8)))
        #expect(o.verifyResult.contains("the same as the original recorded at intake") && o.text.contains("original_sha256_at_intake"))
        CertifiedCopy.ledger.clear(ifSame: f.db)
        await f.state.shutdown()
    }

    // MARK: - ALC-18 legible

    @Test("ALC-18: a write the checker refuses is kept with its reason, listed in Review AI findings, append-only, and erased with the case")
    func refusedWritesKept() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let agent = CaseAgentTools(documents: [CaseReader.Document(objectID: UUID(), fileName: "bank.txt", text: "Debit INR 50,000 to Kestrel on 3 Aug 2026.")])
        let bad = CaseAgent.Call(tool: "record_fact", fields: ["text": .string("Kestrel was paid INR 90,000"), "quote": .string("Credit INR 90,000 to Kestrel"),
                                                                "document": .number(1)])
        let out = await agent.run([bad], reply: .init(served: "model-x", request: nil))
        #expect(out.contains("REJECTED"))
        let kept = agent.rejectedWrites
        #expect(kept.count == 1 && kept.first?.tool == "record_fact" && kept.first?.modelServed == "model-x" && kept.first?.reason.isEmpty == false)
        let repo = CaseAIRecordRepository(database: f.db)
        try await repo.recordRejected(runID: nil, caseID: f.caseA, kept)
        let rows = try await repo.rejected(caseID: f.caseA)
        #expect(rows.count == 1 && rows.first?.text == "Kestrel was paid INR 90,000")
        let line = CaseAIReviewText.refused(try #require(rows.first))
        #expect(line.hasPrefix("Refused record_fact") && line.contains("reason: \(kept[0].reason)"))
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_ai_rejected_writes SET reason = 'x';", []) }
        await #expect(throws: (any Error).self) { try await f.db.exec("DELETE FROM case_ai_rejected_writes;", []) }
        let erased = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: false, reason: "Client request", legalBasis: nil, actor: "Tester")
        #expect(erased.report.refused == nil)
        #expect(try await CaseErasureTests.count(f.db, "SELECT COUNT(*) FROM case_ai_rejected_writes;", []) == 0)
        await f.state.shutdown()
    }

    @Test("ALC-18: a refused write naming a person is removed by that person's erasure")
    func refusedWritesPersonErasure() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let row = try #require(try await f.db.query("SELECT id, value FROM entities WHERE kind = 'person' AND value LIKE '%Roberts%' LIMIT 1;", []).first)
        let person = try #require(row.string(0).flatMap(UUID.init(uuidString:)))
        let name = try #require(row.string(1))
        let repo = CaseAIRecordRepository(database: f.db)
        try await repo.recordRejected(runID: nil, caseID: f.caseB, [
            .init(tool: "record_fact", document: 1, text: "\(name) signed", quote: "x", reason: "the quote is not in Document 1", modelServed: nil),
            .init(tool: "record_fact", document: 1, text: "Other wording", quote: "y", reason: "the quote is not in Document 1", modelServed: nil)])
        let out = try await f.state.erasePerson(person, reason: "Subject request", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil)
        let left = try await repo.rejected(caseID: f.caseB)
        #expect(left.map(\.text) == ["Other wording"], "\(left.map(\.text))")
        await f.state.shutdown()
    }

    @Test("ALC-18: Retract keeps an Ask transcript (hidden from the list, listed as retracted); a case erasure still removes it")
    func askTranscriptRetracted() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let repo = ConversationsRepository(database: f.db)
        let conv = try await repo.create(title: "Who paid Kestrel?", caseID: f.caseA)
        try await repo.appendTurn(ConversationTurn(conversationID: conv.id, ordinal: 0, role: .user, body: "Who paid Kestrel?"))
        try await repo.retract(conv.id, by: "Asha")
        #expect(try await repo.recent(caseID: f.caseA).contains { $0.id == conv.id } == false)
        let gone = try await repo.retracted(caseID: f.caseA)
        #expect(gone.count == 1 && gone.first?.retractedBy == "Asha" && gone.first?.retractedAt != nil)
        #expect(try await repo.turns(for: conv.id).count == 1, "the transcript is kept")
        try await repo.delete(conv.id)   // the old entry point retracts too; it never deletes
        #expect(try await CaseErasureTests.count(f.db, "SELECT COUNT(*) FROM conversations WHERE id = ?;", [.uuid(conv.id)]) == 1)
        let erased = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: false, reason: "Client request", legalBasis: nil, actor: "Tester")
        #expect(erased.report.refused == nil)
        #expect(try await CaseErasureTests.count(f.db, "SELECT COUNT(*) FROM conversation_turns WHERE conversation_id = ?;", [.uuid(conv.id)]) == 0)
        await f.state.shutdown()
    }

    // MARK: - ALC-20 enduring

    @Test("ALC-20: report PDFs are archival — fonts embedded, sRGB output intent, XMP metadata, not encrypted; PDF/A-2b is not claimed")
    func archivalPDF() throws {
        let data = try #require(CaseReportDocumentRenderer.pdf("# Case report\n\nKestrel was paid INR 50,000 on 3 Aug 2026."))
        let check = ArchivalPDF.check(data)
        #expect(check.fontsEmbedded && check.outputIntent && check.hasXMP && !check.encrypted, "\(check)")
        #expect(check.archival)
        let xmp = String(decoding: ArchivalPDF.xmp(title: "Case report", author: "Asha"), as: UTF8.self)
        #expect(xmp.contains("<dc:title>") && xmp.contains("xmp:CreateDate") && !xmp.contains("pdfaid"), "no PDF/A claim without a validator")
        #expect(ArchivalPDF.statement.contains("not verified"))
        let doc = ExportableDocument(title: "Work product", sections: [ExportSection(title: "One", paragraphs: ["Text."])],
                                     manifest: ExportManifest(exportedAt: Date(), appVersion: "test", schemaVersion: 1))
        #expect(ArchivalPDF.check(PDFReportWriter.render(doc)).archival)
    }

    @Test("ALC-20: the retention register has defaults, keeps every change with its reason, refuses a period for the audit chain, and a legal hold overrides the review")
    func retentionRegister() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let reg = RetentionRegister(database: f.db)
        let before = try await reg.entries()
        #expect(before.count == RetentionRegister.classes.count && before.allSatisfy(\.isDefault))
        #expect(before.first { $0.id == "access" }?.periodText == "7 years")
        await #expect(throws: RetentionRegister.RetentionError.self) { try await reg.set(classID: "access", keepDays: 30, by: "Asha", reason: " ") }
        await #expect(throws: RetentionRegister.RetentionError.self) { try await reg.set(classID: "auditChain", keepDays: 30, by: "Asha", reason: "x") }
        try await reg.set(classID: "access", keepDays: 30, by: "Asha", reason: "Policy 4.2", at: Date().addingTimeInterval(-5))
        try await reg.set(classID: "access", keepDays: 60, by: "Ben", reason: "Policy 4.3")
        let access = try #require(try await reg.entries().first { $0.id == "access" })
        #expect(access.keepDays == 60 && access.setBy == "Ben" && access.reason == "Policy 4.3")
        #expect(try await CaseErasureTests.count(f.db, "SELECT COUNT(*) FROM retention_rules WHERE table_class = 'access';", []) == 2, "the earlier setting is kept")
        await #expect(throws: (any Error).self) { try await f.db.exec("DELETE FROM retention_rules;", []) }
        // Two old access events: one in a case under a legal hold notice (kept by the hold), one not (due). Nothing is deleted.
        let old = Date().addingTimeInterval(-90 * 86_400)
        for c in [f.caseA, f.caseB] {
            try await f.db.exec("INSERT INTO case_access_events (id, case_id, actor, kind, occurred_at, recorded_tz) VALUES (?, ?, 'Asha', 'caseOpened', ?, 'UTC');",
                                [.uuid(UUID()), .uuid(c), .date(old)])
        }
        try await f.db.exec("""
            INSERT INTO case_hold_notices (id, case_id, custodian, notice_text, issued_at, issued_by) VALUES (?, ?, 'Records', 'Hold', ?, 'Asha');
            """, [.uuid(UUID()), .uuid(f.caseA), .date(Date())])
        let review = try #require(try await reg.review().first { $0.classID == "access" })
        #expect(review.due >= 1 && review.heldBack == 1, "\(review)")
        #expect(try await CaseErasureTests.count(f.db, "SELECT COUNT(*) FROM case_access_events WHERE occurred_at < ?;", [.date(old.addingTimeInterval(1))]) == 2)
        #expect(RetentionText.detail(access, review: review).contains("kept by a legal hold: 1"))
        await f.state.shutdown()
    }
}
