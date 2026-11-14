//
//  SmartMapS14Tests.swift
//  KalsmritikoshTests
//
//  Smart-map S14 (2026-11-12) — the local tasks left open after S13:
//  • QA-15: a file the app holds but could not read is admitted to a workspace (and so a case) as NOT READ with its
//    reason; it is never projected, never counted as read; a file with no custody record is still refused.
//  • SEC-10: CSV formula injection — case CSV cells a spreadsheet would run are written as text; amounts are untouched.
//  • PERF-08: a nearly full destination refuses an export explicitly, writes nothing and records the refusal.
//  • SRC-08: a cited place the viewer cannot go to (cell, image region, recording time) is a labelled state.
//  Throwaway ledgers only; no network; dates fixed in UTC.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Smart map S14 — omissions visible, CSV formulas, disk pressure, unsupported locators", .serialized)
struct SmartMapS14Tests {

    private let t0 = Date(timeIntervalSince1970: 1_762_905_600)   // 2025-11-12T00:00:00Z

    private struct Rig {
        let db: Database
        let files: FilesRepository
        let objects: KnowledgeObjectRepository
        let workspaces: WorkspaceRepository
        let claims: ClaimRepository
        let coordinator: WorkspaceSourceCoordinator
        let legacy: WorkspaceSourceCoordinator
    }

    private func rig() async throws -> Rig {
        let db = try Database(url: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("s14-\(UUID().uuidString).sqlite"))
        try await SchemaMigrations.migrate(db)
        let files = FilesRepository(database: db), objects = KnowledgeObjectRepository(database: db), workspaces = WorkspaceRepository(database: db)
        let gf = GenericFactRepository(database: db), asrt = AssertionsRepository(database: db), tcs = TemporalClaimRepository(database: db)
        let events = EventsRepository(database: db), claims = ClaimRepository(database: db), store = EvidenceStore(database: db)
        let membership = WorkspaceMembershipDeriver(database: db, workspaces: workspaces)
        let producer = ClaimProducer(genericFacts: gf, assertions: asrt, temporalClaims: tcs, events: events, claims: claims, evidence: store)
        let projection = ClaimProjectionBackfill(producer: producer, progress: ClaimProjectionProgressRepository(database: db), membership: membership,
                                                 genericFacts: gf, temporalClaims: tcs, assertions: asrt, events: events)
        return Rig(db: db, files: files, objects: objects, workspaces: workspaces, claims: claims,
                   coordinator: WorkspaceSourceCoordinator(files: files, objects: objects, workspaces: workspaces, membership: membership, projection: projection, database: db),
                   legacy: WorkspaceSourceCoordinator(files: files, objects: objects, workspaces: workspaces, membership: membership, projection: projection))
    }

    /// A file record; `custody` adds a current source version of the same bytes; `read` adds a knowledge object.
    private func seedFile(_ r: Rig, name: String, custody: Bool, read: Bool, aliasOf: UUID? = nil) async throws -> (file: UUID, version: UUID?) {
        let id = UUID(), hash = String(repeating: "ab", count: 30) + String(format: "%04x", Int.random(in: 0..<65_535))
        try await r.files.upsert(FileRecord(id: id, url: URL(fileURLWithPath: "/s14/\(name)"), sourceType: .pdf, ingestedAt: t0,
                                            contentHash: hash, aliasOf: aliasOf, availability: .available))
        var version: UUID?
        if custody {
            let v = UUID()
            try await r.db.exec("""
                INSERT INTO source_versions (id, logical_source_id, document_id, content_hash, valid_from, is_current, created_at, filename, original_url)
                VALUES (?,?,?,?,?,1,?,?,?);
                """, [.uuid(v), .uuid(UUID()), .uuid(UUID()), .text(hash), .real(0), .real(0), .text(name), .text("file:///s14/\(name)")])
            version = v
        }
        if read {
            try await r.db.exec("INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);",
                                [.uuid(UUID()), .uuid(id), .text("pdf"), .text("readable text"), .real(0), .real(0)])
        }
        return (id, version)
    }

    private func workspace(_ r: Rig) async throws -> UUID {
        let id = UUID()
        try await r.workspaces.upsert(Workspace(id: id, title: "S14", template: .general))
        return id
    }

    // MARK: QA-15

    @Test("QA-15: a held but unread file is offered and admitted as not read, with its reason; never projected; a file with no custody record, or an alias, is still refused; without the ledger handle the old rule holds")
    func notReadAdmission() async throws {
        let r = try await rig()
        let ws = try await workspace(r)
        let readable = try await seedFile(r, name: "statement.pdf", custody: true, read: true)
        let scan = try await seedFile(r, name: "scan-unreadable.pdf", custody: true, read: false)
        let refused = try await seedFile(r, name: "never-held.pdf", custody: false, read: false)
        let alias = try await seedFile(r, name: "scan-copy.pdf", custody: false, read: false, aliasOf: scan.file)

        let offered = try await r.coordinator.candidates(for: ws)
        #expect(Set(offered.map(\.fileID)) == [readable.file, scan.file], "only held, canonical files are offered: \(offered.map(\.filename))")
        #expect(offered.first { $0.fileID == readable.file }?.readState == .read)
        let scanOffer = try #require(offered.first { $0.fileID == scan.file })
        #expect(scanOffer.readState.isRead == false && scanOffer.readState.label?.hasPrefix("Not read — ") == true, "\(String(describing: scanOffer.readState.label))")

        let claimsBefore = try await r.claims.count()
        let added = try await r.coordinator.addSources([readable.file, scan.file, refused.file, alias.file], to: ws, at: t0)
        #expect(Set(added.added) == [readable.file, scan.file], "the unheld file and the alias are not admitted")
        #expect(added.notRead.keys.sorted { $0.uuidString < $1.uuidString } == [scan.file] && added.notRead[scan.file] == UnreadSourceReason.noRecord,
                "the scan is admitted as not read with the reason its record gives: \(added.notRead)")
        #expect(Set(try await r.workspaces.sourceIDs(in: ws)) == [readable.file, scan.file])
        #expect(try await r.claims.count() == claimsBefore, "nothing is projected from the unread file")
        let current = try await r.coordinator.currentSources(in: ws)
        #expect(current.first { $0.fileID == scan.file }?.readState.isRead == false && current.first { $0.fileID == readable.file }?.readState.isRead == true,
                "the workspace's source list keeps saying which one was not read")

        // Nothing eligible: still an explicit error, never a silent success.
        let ws2 = try await workspace(r)
        await #expect(throws: WorkspaceSourceError.noEligibleSources) { try await r.coordinator.addSources([refused.file, alias.file], to: ws2, at: t0) }
        // A rig without the ledger handle keeps the pre-S14 rule (read files only).
        await #expect(throws: WorkspaceSourceError.noEligibleSources) { try await r.legacy.addSources([scan.file], to: ws2, at: t0) }
        #expect(try await r.legacy.candidates(for: ws2).map(\.fileID) == [readable.file])
    }

    @Test("QA-15: the not-read reason comes from the reading record in the intake list's words; the map's document loader carries it for a version with no readable document only")
    func notReadReasonWording() async throws {
        let r = try await rig()
        let scan = try await seedFile(r, name: "scan.pdf", custody: true, read: false)
        let readable = try await seedFile(r, name: "memo.pdf", custody: true, read: true)
        let v = try #require(scan.version), rv = try #require(readable.version)
        #expect(UnreadSourceReason.text(snapshot: nil) == UnreadSourceReason.noRecord)
        let reasons = await UnreadSourceReason.reasons(for: [v], database: r.db)
        #expect(reasons[v] == UnreadSourceReason.noRecord, "no readiness record: said, not invented")
        let docs = try await CaseMapRepository(database: r.db).documents(versionIDs: [v, rv], objectsByVersion: [rv: UUID()])
        #expect(docs.first { $0.sourceVersionID == v }?.notReadReason == UnreadSourceReason.noRecord)
        #expect(docs.first { $0.sourceVersionID == rv }?.notReadReason == nil)
    }

    // MARK: SEC-10

    @Test("SEC-10: CSV formula injection — =, +, -, @, tab, CR and full-width look-alikes are written as text; plain (negative) amounts and ordinary text are untouched; the map CSV and the case-file CSVs apply it")
    func csvFormulaInjection() {
        for hostile in ["=HYPERLINK(\"https://evil.example\",\"open\")", "+1+cmd|' /C calc'!A0", "-2+3", "@SUM(A1:A9)", "\tx", "\rx", "  =1+1", "＝1+1", "－1+1"] {
            let cell = CSVFormulaGuard.neutralised(hostile)
            #expect(cell == "'" + hostile, "\(hostile) → \(cell)")
            #expect(CSVFormulaGuard.isFormulaLike(hostile))
        }
        for plain in ["-50,000.00", "+3.5", "-7", "100,000", "Invoice INV-104", "Meera Shah", "", "—", "a=b"] {
            #expect(CSVFormulaGuard.neutralised(plain) == plain, "\(plain)")
        }
        #expect(CaseMapExportRenderer.csvField("=cmd()") == "'=cmd()")
        #expect(CaseMapExportRenderer.csvField("=A1,B1") == "\"'=A1,B1\"", "quoted and neutralised")
        let csv = CaseFileDocuments.csv([["Description"], ["@evil"], ["-120.50"]])
        #expect(csv == "\"Description\"\n\"'@evil\"\n\"-120.50\"\n", "\(csv)")
    }

    // MARK: PERF-08

    @Test("PERF-08: the shortfall rule (file twice plus a margin); a destination without room refuses the export before writing, records the refusal, and the next export with room is written")
    func diskPressureRefusesExplicitly() async throws {
        #expect(DiskSpaceCheck.shortfall(writing: 10, available: 10_000, margin: 100) == nil)
        #expect(DiskSpaceCheck.shortfall(writing: 1_000, available: 1_500, margin: 100) == 2_100)
        #expect(DiskSpaceCheck.shortfall(writing: -5, available: 50, margin: 100) == 100, "a negative size counts as zero")
        #expect(DiskSpaceCheck.availableCapacity(at: FileManager.default.temporaryDirectory.appendingPathComponent("not-yet-\(UUID().uuidString).md")) ?? 0 > 0,
                "the volume reports its free space for a file not written yet")

        let f = try await CaseFileTests.fixture(title: "Disk pressure")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("s14-out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let outputs = CaseOutputService(database: f.db, caseFiles: f.svc, custody: { _ in [] }, pendingDirectory: temp.appendingPathComponent("pending", isDirectory: true))
        _ = try await f.file.addAllegation(caseID: f.caseID, text: "Was the rota changed afterwards?", actor: "Ada")
        await outputs.setHooks(.init(availableCapacity: { _ in 1_000 }))
        let pkg = try await outputs.prepare(caseID: f.caseID, kind: .caseFileReport, route: .file, actor: "Ada") { CaseFileDocuments.caseFileReport($0, by: "Ada") }
        let url = temp.appendingPathComponent("Case file.md")
        let refused = await outputs.write(pkg, to: url)
        #expect(refused.status == .failed && refused.detail?.contains("Nothing was written") == true && refused.detail?.contains("free") == true, "\(refused.detail ?? "")")
        #expect(!FileManager.default.fileExists(atPath: url.path), "nothing was written")
        #expect(try await outputs.outputs(caseID: f.caseID).contains { $0.status == .failed }, "the refusal is recorded, not silent")
        await outputs.setHooks(.init(availableCapacity: { _ in 10 * 1_073_741_824 }))
        let written = await outputs.write(pkg, to: url)
        #expect(written.status == .written && FileManager.default.fileExists(atPath: url.path), "\(written.detail ?? "")")
    }

    // MARK: SRC-08

    @Test("SRC-08: an unsupported locator is a labelled state (cell, cell range, image region, recording time, slide, database row); a page or text range is not; the locator is read from the cited block")
    func unsupportedLocatorLabelled() async throws {
        let cell = try #require(CitedSourceResolver.unsupportedLocatorNote(SourceLocator(row: 4, column: "B", sheet: "Payments")))
        #expect(cell.contains("sheet “Payments”") && cell.contains("cell B5") && cell.hasPrefix("Cited place not shown"))
        #expect(CitedSourceResolver.unsupportedLocatorNote(SourceLocator(cellRange: "B2:D5"))?.contains("cells B2:D5") == true)
        #expect(CitedSourceResolver.unsupportedLocatorNote(SourceLocator(boundingBox: [1, 2, 3, 4]))?.contains("a region of the image") == true)
        var av = SourceLocator(); av.transcriptStart = 3_725; av.transcriptEnd = 3_790
        #expect(CitedSourceResolver.unsupportedLocatorNote(av)?.contains("the recording at 1:02:05–1:03:10") == true)
        #expect(CitedSourceResolver.unsupportedLocatorNote(SourceLocator(slide: 7))?.contains("slide 7") == true)
        #expect(CitedSourceResolver.unsupportedLocatorNote(SourceLocator(characterRange: 10..<40, page: 3)) == nil, "a PDF page and a text range are shown")
        #expect(CitedSourceResolver.unsupportedLocatorNote(SourceLocator(page: 2, boundingBox: [1, 2, 3, 4])) == nil, "a region on a PDF page opens at its page")
        #expect(CitedSourceResolver.unsupportedLocatorNote(SourceLocator()) == nil)

        let r = try await rig()
        let block = UUID()
        let json = String(decoding: try JSONEncoder().encode(SourceLocator(row: 9, column: "C", sheet: "Ledger")), as: UTF8.self)
        try await r.db.exec("""
            INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text, locator, extraction_method, extraction_confidence)
            VALUES (?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(block), .uuid(UUID()), .uuid(UUID()), .integer(0), .text("tableCell"), .text("50,000"), .text("50,000"), .text(json), .text("native"), .real(1)])
        let read = try #require(try await CitedSourceResolver.locator(blockID: block, database: r.db))
        #expect(CitedSourceResolver.unsupportedLocatorNote(read)?.contains("cell C10") == true, "rows are 0-based in the locator (S18 fix)")
        #expect(try await CitedSourceResolver.locator(blockID: UUID(), database: r.db) == nil, "a gone block has no locator")
    }
    // MARK: QA-03

    @Test("QA-03: a non-financial workplace case — the complainant's and the respondent's accounts both kept on the map and in the brief, the respondent's response opportunity listed as next work, a protected witness scrubbed from the export, a held rota that could not be read named as missing material; no money record, money section or loss wording appears")
    func workplaceCaseWithoutMoney() async throws {
        let f = try await CaseFileTests.fixture(title: "Complaint about the night shift")
        let t = try #require(CaseTemplate.template(id: "workplace"))
        try await f.svc.applyTemplate(t, caseID: f.caseID, workspaceID: f.workspaceID, actor: "Ada")
        let complaint = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "complaint.txt",
                                                                  text: "Sam Okafor shouted at me on 3 March in the staff room. Meera Iyer was there.")
        let reply = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "respondent-reply.txt",
                                                              text: "I did not shout at anyone on 3 March. I was not on shift that evening.")
        // Missing material: the rota is held in the case but no text could be read from it.
        let rotaRef = try await CaseFileTestSources.inScope(f.db, cases: f.cases, caseID: f.caseID).first ?? ""
        let rota = try #require(UUID(uuidString: rotaRef))
        let q = try await f.file.addAllegation(caseID: f.caseID, text: "Sam Okafor shouted at staff on 3 March", actor: "Ada")
        let qn = CaseMapNodeID(caseID: f.caseID, kind: .allegation, id: q)
        var p = try #require(await caseMapLoad(f).projection)
        let complaintDoc = try #require(p.nodes.first { $0.id.kind == .document && $0.sources.contains { $0.sourceVersionID == complaint.version } }).id
        let replyDoc = try #require(p.nodes.first { $0.id.kind == .document && $0.sources.contains { $0.sourceVersionID == reply.version } }).id
        let map = CaseMapRepository(database: f.db)
        _ = try await map.addLink(caseID: f.caseID, type: .supports, from: complaintDoc, to: qn, rationale: "The complainant's account", actor: "Ada")
        _ = try await map.addLink(caseID: f.caseID, type: .challenges, from: replyDoc, to: qn, rationale: "The respondent's account: not on shift", actor: "Ada")
        p = try #require(await caseMapLoad(f).projection)
        #expect(p.links(of: qn).contains { $0.type == .supports && $0.from == complaintDoc } && p.links(of: qn).contains { $0.type == .challenges && $0.from == replyDoc },
                "both accounts are kept, neither averaged away")
        let brief = CaseMapBrief.compute(p, changed: [])
        #expect(brief.section("alternatives")?.entries.contains { $0.node == replyDoc } == true, "the respondent's account is listed as contrary material")
        #expect(brief.section("position")?.entries.isEmpty == true, "no position is taken")
        #expect(brief.section("next")?.entries.contains { $0.text.contains("respondent") && $0.text.contains("put fairly") } == true,
                "the respondent's response opportunity is open work: \(brief.section("next")?.entries.map(\.text) ?? [])")
        // Missing material: named on the map and in the brief.
        let rotaNode = try #require(p.nodes.first { $0.id.kind == .document && $0.sources.contains { $0.sourceVersionID == rota } })
        #expect(rotaNode.status.kind == .failed && rotaNode.status.text.contains("not read"), "\(rotaNode.status)")
        #expect(brief.scope.contains { $0.contains("could not be read") && $0.contains(rotaNode.title) }, "\(brief.scope)")
        // Money assumptions do not control the case: no money record, no money wording.
        #expect(!p.nodes.contains { [.moneyAccount, .moneyRecord, .moneyTransaction, .accountRelation].contains($0.id.kind) })
        #expect(try await f.file.moneyLedger(caseID: f.caseID).records.isEmpty)
        let briefText = (brief.scope + brief.allEntries.map { $0.text + " " + $0.why } + brief.evidentialStates.map(\.label)).joined(separator: " ").lowercased()
        #expect(!briefText.contains("loss") && !briefText.contains("money") && !briefText.contains("transaction"), "\(briefText)")
        // Confidentiality: the protected witness is scrubbed from the case file export.
        _ = try await JobResultRepository(database: f.db).save(caseID: f.caseID, jobID: "jrn.source-vault", family: .interviewsQuotes, state: .draft,
                                                               content: JobResultContent(rows: [JobResultRow(title: "Source", detail: "", fields: ["protected": "yes", "identity": "Meera Iyer"])]),
                                                               actor: "Ada")
        _ = try await f.svc.linkEvidence(caseID: f.caseID, allegationID: q, evidenceRef: complaint.version.uuidString, label: "Complaint", stance: .supports,
                                         note: "Meera Iyer asked not to be named", passage: StudioEvidenceRef(sourceVersionID: complaint.version, quote: "Sam Okafor shouted at me on 3 March in the staff room"),
                                         actor: "Ada")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("s14-hr-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let outputs = CaseOutputService(database: f.db, caseFiles: f.svc, custody: { _ in [] }, pendingDirectory: temp.appendingPathComponent("pending", isDirectory: true))
        let pkg = try await outputs.prepare(caseID: f.caseID, kind: .caseFileReport, route: .file, actor: "Ada") { CaseFileDocuments.caseFileReport($0, by: "Ada") }
        #expect(!pkg.text.contains("Meera Iyer") && pkg.text.contains("[PROTECTED SOURCE] asked not to be named"), "the protected witness is scrubbed from the export")
        #expect(!pkg.text.lowercased().contains("loss"))
    }
}
