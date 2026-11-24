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
}
