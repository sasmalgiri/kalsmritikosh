//
//  EaseFixesBTests.swift
//  KalsmritikoshTests
//
//  Ease fixes B (AI-off assessment 2026-11-15, friction points 4 and 5): citations that read "document, p. 4" with the
//  identifiers only in an appendix; the case file report as PDF and Word, read back (PDFKit text; the .docx unzipped and
//  its document.xml parsed), refused at write when a name is protected after the draft, recorded with a manifest that
//  matches; the portable package without identifiers in its visible sections; one "New case…" (question as purpose);
//  "Add documents…" through the intake contracts (batch receipt, intake record, person's decision, unread file admitted
//  as not read); the persona job list; "Mark privileged…" through the register with a reason, kept, and re-checked at
//  release. Throwaway ledgers in temporary folders; expected values written by hand. AI off: no model, no network.
//

import Foundation
import PDFKit
import Testing
@testable import Kalsmritikosh

private enum EB {
    static let uuidPattern = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
    static func hasUUID(_ s: String) -> Bool { s.range(of: uuidPattern, options: .regularExpression) != nil }

    static func outputs(_ f: CaseFileTests.Fixture) throws -> (CaseOutputService, URL) {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("ef-b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let db = f.db
        let svc = CaseOutputService(database: f.db, caseFiles: f.svc, custody: { caseID in
            try await db.query("SELECT source_ref FROM investigation_case_sources WHERE case_id = ? AND in_scope = 1 AND source_kind = 'sourceVersion';", [.uuid(caseID)])
                .compactMap { $0.uuid(0) }.map { CustodyManifestEntry(sourceVersionID: $0, contentHash: nil, custodyEvents: []) }
        }, pendingDirectory: temp.appendingPathComponent("pending", isDirectory: true))
        return (svc, temp)
    }

    /// A case with two linked passages: invoice-a's block records page 4; invoice-b's block records no page.
    static func citedCase() async throws -> (rig: CaseMapRig, allegation: UUID) {
        let rig = try await CaseMapRig.make()
        let f = rig.f
        let json = String(decoding: try JSONEncoder().encode(SourceLocator(page: 4)), as: UTF8.self)
        try await f.db.exec("UPDATE evidence_blocks SET locator = ? WHERE id = ?;", [.text(json), .uuid(rig.a.blocks[0])])
        let a = try await f.file.addAllegation(caseID: f.caseID, text: "The supplier was paid twice", actor: "Ada")
        _ = try await f.svc.linkEvidence(caseID: f.caseID, allegationID: a, evidenceRef: rig.a.version.uuidString, label: "Invoice A", stance: .supports, note: nil,
                                         passage: StudioEvidenceRef(sourceVersionID: rig.a.version, objectID: rig.a.object, blockID: rig.a.blocks[0],
                                                                    quote: "The invoice total was 500 dollars."), actor: "Ada")
        _ = try await f.svc.linkEvidence(caseID: f.caseID, allegationID: a, evidenceRef: rig.b.version.uuidString, label: "Invoice B", stance: .contradicts, note: nil,
                                         passage: StudioEvidenceRef(sourceVersionID: rig.b.version, objectID: rig.b.object, blockID: rig.b.blocks[0],
                                                                    quote: "The invoice total was 650 dollars."), actor: "Ada")
        return (rig, a)
    }

    static let render: @Sendable (CaseFileSnapshot) -> String = { CaseFileDocuments.caseFileReport($0, by: "Ada") }
}

@Suite("Ease fixes B — court-ready reports and a simpler start", .serialized)
struct EaseFixesBTests {

    // MARK: - Citations

    @Test("A place in words: page, sheet and cell, slide, time, line — and “page not recorded” when none is recorded")
    func placeWording() {
        #expect(CaseCitationText.place(SourceLocator(page: 4)) == "p. 4")
        #expect(CaseCitationText.place(SourceLocator(row: 4, column: "B", sheet: "Sales")) == "sheet Sales, cell B5")
        #expect(CaseCitationText.place(SourceLocator(cellRange: "B2:D5", sheet: "Sales")) == "sheet Sales, cells B2:D5")
        #expect(CaseCitationText.place(SourceLocator(slide: 3)) == "slide 3")
        #expect(CaseCitationText.place(SourceLocator(transcriptStart: 754, transcriptEnd: 770)) == "at 12:34–12:50")
        #expect(CaseCitationText.place(SourceLocator(line: 10)) == "line 10")
        #expect(CaseCitationText.place(SourceLocator(characterRange: 10..<40)) == "page not recorded", "a character range is not a page")
        #expect(CaseCitationText.place(nil) == "page not recorded")
        #expect(CaseCitationText.cite(name: "invoice.pdf", locator: SourceLocator(page: 4)) == "invoice.pdf, p. 4")
        #expect(CaseCitationText.cite(name: nil, locator: nil) == "\(CaseCitationText.unnamedDocument), page not recorded")
    }

    @Test("The case file report cites “document, p. 4” (or “page not recorded”); no identifier in the visible text; the identifiers are in the appendix")
    func reportCitationsHaveNameAndPage() async throws {
        let (rig, _) = try await EB.citedCase()
        let (out, temp) = try EB.outputs(rig.f)
        defer { try? FileManager.default.removeItem(at: temp) }
        let pkg = try await out.prepare(caseID: rig.f.caseID, kind: .caseFileReport, route: .file, actor: "Ada", render: EB.render)
        let body = CaseCitationText.visibleBody(pkg.text)
        #expect(body.contains("invoice-a.txt, p. 4"), "\(body)")
        #expect(body.contains("invoice-b.txt, page not recorded"), "no page was recorded for invoice B, and none is invented")
        #expect(!EB.hasUUID(body), "no identifier in the visible text: \(body)")
        #expect(pkg.text.contains(CaseCitationText.appendixHeading))
        #expect(pkg.text.contains("source version \(rig.a.version.uuidString)") && pkg.text.contains("passage \(rig.a.blocks[0].uuidString)"))
        #expect(body.contains("## What the app could read") && body.contains("## Unresolved questions and limitations"))
        // The output still reconciles: written as Markdown, read back, recorded with its manifest.
        let receipt = await out.write(pkg, to: temp.appendingPathComponent("report.md"))
        #expect(receipt.status == .written && receipt.recorded, "\(receipt.summary)")
    }

    // MARK: - PDF and Word

    @Test("PDF and Word: valid, readable back (PDFKit text; document.xml parsed), with names and pages, coverage and limits; no active content; manifest and read-back match; recorded")
    func pdfAndWordReadBack() async throws {
        let (rig, _) = try await EB.citedCase()
        let f = rig.f
        let (out, temp) = try EB.outputs(f)
        defer { try? FileManager.default.removeItem(at: temp) }

        let pdf = try await out.prepareReportDocument(caseID: f.caseID, format: .pdf, actor: "Ada", render: EB.render)
        #expect(pdf.manifest?.format == "pdf" && pdf.data.starts(with: Data("%PDF".utf8)))
        let pdfURL = temp.appendingPathComponent("report.pdf")
        let pdfReceipt = await out.writeRechecked(pdf, to: pdfURL)
        #expect(pdfReceipt.status == .written && pdfReceipt.recorded, "\(pdfReceipt.summary)")
        let pdfText = try #require(CaseReportDocumentRenderer.pdfText(try Data(contentsOf: pdfURL)))
        #expect(pdfText.contains("invoice-a.txt") && pdfText.contains("p. 4"), "\(pdfText.prefix(400))")
        #expect(pdfText.contains("What the app could read") && pdfText.contains("Unresolved questions and limitations"))
        #expect((PDFDocument(url: pdfURL)?.pageCount ?? 0) >= 1)
        #expect(CaseReportDocumentRenderer.activeContent(try Data(contentsOf: pdfURL), format: .pdf).isEmpty)

        let docx = try await out.prepareReportDocument(caseID: f.caseID, format: .docx, actor: "Ada", render: EB.render)
        let docxURL = temp.appendingPathComponent("report.docx")
        let docxReceipt = await out.writeRechecked(docx, to: docxURL)
        #expect(docxReceipt.status == .written && docxReceipt.recorded, "\(docxReceipt.summary)")
        let bytes = try Data(contentsOf: docxURL)
        let xml = try ZIPReader(data: bytes).read("word/document.xml")
        let parser = XMLParser(data: xml)
        #expect(parser.parse(), "document.xml is well-formed XML")
        let docText = try #require(CaseReportDocumentRenderer.docxText(bytes))
        #expect(docText.contains("invoice-a.txt, p. 4") && docText.contains("invoice-b.txt, page not recorded"))
        #expect(docText.contains("What the app could read") && docText.contains("Unresolved questions and limitations"))
        let docBody = docText.components(separatedBy: "Appendix — machine-readable references").first ?? docText
        #expect(!EB.hasUUID(docBody) && docText.contains("Appendix — machine-readable references"))
        #expect(CaseReportDocumentRenderer.activeContent(bytes, format: .docx).isEmpty)
        let types = String(decoding: try ZIPReader(data: bytes).read("[Content_Types].xml"), as: UTF8.self)
        #expect(types.contains("wordprocessingml.document.main+xml") && !types.lowercased().contains("macroenabled"))

        // The record holds the manifest of each format, and the written bytes are the recorded digest.
        let rows = try await f.db.query("SELECT file_name, file_sha256, manifest_json FROM case_document_outputs WHERE case_id = ? AND kind = 'caseFileReport' AND status = 'written';",
                                        [.uuid(f.caseID)])
        let formats = Set(rows.compactMap { $0.string(2).flatMap(CaseOutputManifest.decode)?.format })
        #expect(formats == ["pdf", "docx"])
        #expect(rows.contains { $0.string(0) == "report.docx" && $0.string(1) == StudioRecordRepository.sha256(bytes) })
        // A damaged Word file does not reconcile with its manifest.
        let m = try #require(docx.manifest)
        #expect(CaseOutputArtifactCheck.problem(Data("not a zip".utf8), manifest: m) != nil)
    }

    @Test("A name protected after the draft was prepared is refused at write: nothing is written, the refusal is recorded")
    func protectedAfterDraftRefusedAtWrite() async throws {
        let (rig, a) = try await EB.citedCase()
        let f = rig.f
        try await f.file.recordResponse(allegationID: a, caseID: f.caseID, response: "Meera Iyer approved the second payment.", actor: "Ada")
        let (out, temp) = try EB.outputs(f)
        defer { try? FileManager.default.removeItem(at: temp) }
        let pkg = try await out.prepareReportDocument(caseID: f.caseID, format: .pdf, actor: "Ada", render: EB.render)
        #expect(pkg.text.contains("Meera Iyer"), "not protected when the draft was prepared")
        let vault = JobResultRow(title: "Source", detail: "", fields: ["protected": "yes", "identity": "Meera Iyer"])
        _ = try await JobResultRepository(database: f.db).save(caseID: f.caseID, jobID: "jrn.source-vault", family: .interviewsQuotes, state: .draft,
                                                                content: JobResultContent(rows: [vault]), actor: "Ada")
        let url = temp.appendingPathComponent("report.pdf")
        let receipt = await out.writeRechecked(pkg, to: url)
        #expect(receipt.status == .refused && receipt.detail?.contains("marked protected") == true, "\(receipt.summary)")
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try await out.outputs(caseID: f.caseID).contains { $0.kind == .caseFileReport && $0.status == .refused })
    }

    @Test("The portable package: places in words in its evidence; no identifier in its visible sections; the identifiers are in the appendix and the manifest; read back")
    func packageWithoutVisibleIDs() async throws {
        let (rig, _) = try await EB.citedCase()
        let f = rig.f
        let (out, temp) = try EB.outputs(f)
        defer { try? FileManager.default.removeItem(at: temp) }
        let map = CaseMapService(sources: caseMapSources(f))
        let pkg = try await out.preparePackage(caseID: f.caseID, selection: .wholeCase, actor: "Ada") { id in await map.load(caseID: id, generation: 1) }
        let read = CasePortablePackageReader.read(pkg.text)
        for section in ["status", "items", "relationships", "evidence", "findings", "open-work", "disclosures"] {
            #expect(!EB.hasUUID(read.sectionText[section] ?? ""), "\(section): \(read.sectionText[section] ?? "")")
        }
        #expect(read.sectionText["evidence"]?.contains("p. 4") == true, "\(read.sectionText["evidence"] ?? "")")
        #expect(read.sectionText["references"]?.contains(rig.a.version.uuidString.lowercased()) == true)
        #expect(read.manifest?.sourceVersions.contains(rig.a.version.uuidString) == true)
        let receipt = await out.write(pkg, to: temp.appendingPathComponent("package.html"))
        #expect(receipt.status == .written && receipt.recorded, "\(receipt.summary)")
    }

    // MARK: - Add documents into the case

    @Test("“Add documents…”: one step through the intake contracts — batch receipt, workspace, intake record and the person's decision; an unreadable held file joins as not read; an unheld one is named")
    func addDocumentsIntoCase() async throws {
        let f = try await CaseFileTests.fixture(title: "Kestrel payments")
        let files = FilesRepository(database: f.db), objects = KnowledgeObjectRepository(database: f.db)
        let gf = GenericFactRepository(database: f.db), asrt = AssertionsRepository(database: f.db), tcs = TemporalClaimRepository(database: f.db)
        let events = EventsRepository(database: f.db), claims = ClaimRepository(database: f.db), store = EvidenceStore(database: f.db)
        let membership = WorkspaceMembershipDeriver(database: f.db, workspaces: f.workspaces)
        let producer = ClaimProducer(genericFacts: gf, assertions: asrt, temporalClaims: tcs, events: events, claims: claims, evidence: store)
        let projection = ClaimProjectionBackfill(producer: producer, progress: ClaimProjectionProgressRepository(database: f.db), membership: membership,
                                                 genericFacts: gf, temporalClaims: tcs, assertions: asrt, events: events)
        let coordinator = WorkspaceSourceCoordinator(files: files, objects: objects, workspaces: f.workspaces, membership: membership, projection: projection, database: f.db)
        let intake = InvestigationWorkspaceIntake(cases: f.cases, workspaces: f.workspaces, coverage: CaseCoverageRepository(database: f.db))
        let adder = CaseDocumentAdder(database: f.db, cases: f.cases, intake: intake, coordinator: coordinator, runs: IngestRunRepository(database: f.db))
        let db = f.db
        struct Unreadable: LocalizedError { var errorDescription: String? { "the scan holds no text" } }
        struct Refused: LocalizedError { var errorDescription: String? { "the file could not be opened" } }
        @Sendable func seed(_ url: URL, read: Bool) async throws -> (UUID, UUID) {
            let file = UUID(), version = UUID()
            let hash = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased().prefix(64)
            try await db.exec("INSERT INTO files (id, url, source_type, availability, content_hash, ingested_at) VALUES (?,?,?,?,?,?);",
                              [.uuid(file), .text(url.absoluteString), .text("pdf"), .text("available"), .text(String(hash)), .real(100)])
            if read {
                try await db.exec("INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);",
                                  [.uuid(UUID()), .uuid(file), .text("pdf"), .text("Paid Kestrel INR 50,000."), .real(0), .real(0)])
            }
            try await db.exec("""
                INSERT INTO source_versions (id, logical_source_id, document_id, content_hash, valid_from, is_current, created_at, filename, original_url)
                VALUES (?,?,?,?,?,1,?,?,?);
                """, [.uuid(version), .uuid(file), .uuid(UUID()), .text(String(hash)), .real(0), .real(0), .text(url.lastPathComponent), .text(url.absoluteString)])
            return (file, version)
        }
        let good = URL(fileURLWithPath: "/ef-b/statement.pdf"), scan = URL(fileURLWithPath: "/ef-b/scan.pdf"), never = URL(fileURLWithPath: "/ef-b/never.pdf")
        let receipt = try await adder.add(caseID: f.caseID, urls: [good, scan, never], actor: "Ada", at: Date()) { url in
            if url == good { let (fid, v) = try await seed(url, read: true); return (fid, v, .newLogicalSource) }
            if url == scan { _ = try await seed(url, read: false); throw Unreadable() }
            throw Refused()
        }
        #expect(receipt.added == ["statement.pdf"], "\(receipt)")
        #expect(receipt.notRead.map(\.name) == ["scan.pdf"] && receipt.notRead.first?.reason.isEmpty == false)
        #expect(receipt.notTakenIn.map(\.name) == ["never.pdf"] && receipt.notTakenIn.first?.reason == "the file could not be opened")
        #expect(receipt.included == 2 && receipt.summary.hasPrefix("2 document(s) added to the case"))
        // The case's scope holds both held files; each has an intake record decided by the person, channel "file picker".
        let inScope = try await f.db.query("SELECT COUNT(*) FROM investigation_case_sources WHERE case_id = ? AND in_scope = 1;", [.uuid(f.caseID)]).first?.int(0)
        #expect(inScope == 2)
        let items = try await f.db.query("SELECT channel, decision, decided_via, entered_by, ingest_run_id, label FROM case_intake_items WHERE case_id = ?;", [.uuid(f.caseID)])
        #expect(items.count == 2 && items.allSatisfy { $0.string(1) == "included" && $0.string(2) == "person" && $0.string(3) == "Ada" })
        let read = try #require(items.first { $0.string(5) == "statement.pdf" })
        #expect(read.string(0) == "fileImport" && read.string(4)?.uppercased() == receipt.runID?.uuidString.uppercased(), "the read file names its batch and channel")
        // The unread file never "arrived" as a received document, so its channel is recorded as not known — never invented.
        #expect(items.first { $0.string(5) == "scan.pdf" }?.string(0) == "workspace")
        // The batch receipt accounts for every file once.
        let run = try #require(receipt.runID)
        let batch = try #require(try await IntakeReceiptRepository(database: f.db).receipt(run: run))
        #expect(batch.selected == 3 && batch.received == 1 && batch.failed == 2 && batch.reconciles)
        // The library and the workspace still hold them.
        #expect(try await f.workspaces.sourceIDs(in: f.workspaceID).count == 2)
    }

    // MARK: - New case, persona jobs, Mark privileged

    @Test("The persona job list leaves out other professions' work (CAPA, Data Lab…) and names it; “Show all jobs” lists everything")
    @MainActor
    func personaJobList() async throws {
        let inv = InvestigatorPersonaPackage.applicationID
        let listed = PersonaJobCatalogComposer.listedJobs(forPersona: inv).map(\.title)
        for hidden in ["CAPA register", "DataLab", "Causal analysis", "Effectiveness review"] { #expect(!listed.contains(hidden), "\(hidden)") }
        #expect(listed.contains("Case report & export") && listed.contains("Chain of custody"))
        #expect(PersonaJobCatalogComposer.listedJobs(forPersona: ResearcherPersonaPackage.applicationID).count == PersonaJobCatalogComposer.jobs(forPersona: ResearcherPersonaPackage.applicationID).count)

        let h = try await PersonaAcceptanceHarness.make(seed: "efb")
        let model = PersonaJobsModel(service: h.service, catalog: try PersonaJobCatalogComposer.composeProduction(), workspaces: h.workspaces)
        await model.load()
        await model.select(persona: inv)
        #expect(!model.runnableJobs.contains { $0.title == "CAPA register" || $0.title == "DataLab" })
        #expect(Set(model.hiddenJobs.map(\.job.title)) == ["DataLab", "Causal analysis", "CAPA register", "Effectiveness review"])
        model.showAllJobs = true
        #expect(model.runnableJobs.contains { $0.title == "CAPA register" } && model.hiddenJobs.isEmpty)
        #expect(model.runnableJobs.count == model.jobs.filter { $0.kind != .caseIntake }.count)
    }

    @Test("“New case…” from Professional Jobs: the question typed is the case's purpose")
    @MainActor
    func newCaseQuestionIsPurpose() async throws {
        let h = try await PersonaAcceptanceHarness.make(seed: "efb-q")
        try await h.workspaces.upsert(Workspace(id: UUID(), title: "General", template: .general))
        let model = PersonaJobsModel(service: h.service, catalog: try PersonaJobCatalogComposer.composeProduction(), workspaces: h.workspaces)
        await model.load()
        await model.select(persona: InvestigatorPersonaPackage.applicationID)
        let q = "Was Kestrel paid twice in March?"
        model.matterTitle = FirstCaseEntry.title(question: q, typed: "")
        model.matterQuestion = q
        await model.startMatter(actor: "Ada", at: Date())
        let caseID = try #require(model.activeCaseID)
        let purpose = try await h.db.query("SELECT purpose FROM investigation_cases WHERE id = ?;", [.uuid(caseID)]).first?.string(0)
        #expect(purpose == q && model.activeMatterTitle == "Was Kestrel paid twice in March")
    }

    @Test("“Mark privileged…”: a reason is required; the mark is kept in the register with its history; a report citing the document is then refused at release (SEC-06)")
    func markPrivileged() async throws {
        let (rig, _) = try await EB.citedCase()
        let f = rig.f
        let (out, temp) = try EB.outputs(f)
        defer { try? FileManager.default.removeItem(at: temp) }
        let svc = SensitiveScopeMutationService(repository: SensitiveScopeRepository(database: f.db))
        await #expect(throws: MarkPrivilegedError.reasonRequired) { try await svc.markPrivileged(sourceVersionID: rig.a.version, reason: "  ", actor: "Ada", at: Date()) }
        // Prepared before the mark.
        let pkg = try await out.prepareReportDocument(caseID: f.caseID, format: .docx, actor: "Ada", render: EB.render)
        let mark = try await svc.markPrivileged(sourceVersionID: rig.a.version, reason: "Legal advice from counsel", actor: "Ada", at: Date())
        #expect(mark.privileged && mark.reason == "Legal advice from counsel")
        let history = try await f.db.query("SELECT action FROM sensitive_scope_reviews WHERE assignment_id = ?;", [.uuid(mark.id)])
        #expect(history.map { $0.string(0) } == ["assigned"], "the mark keeps its history")
        let privileged = try await f.db.withSavepoint("efb_priv") { db in try CaseProtectionNow.versionPrivileged(db, rig.a.version) }
        #expect(privileged)
        let url = temp.appendingPathComponent("report.docx")
        let receipt = await out.writeRechecked(pkg, to: url)
        #expect(receipt.status == .refused && !FileManager.default.fileExists(atPath: url.path), "\(receipt.summary)")
        await #expect(throws: CaseOutputError.self) { _ = try await out.prepareReportDocument(caseID: f.caseID, format: .pdf, actor: "Ada", render: EB.render) }
    }

    @Test("Source audit: one “New case…” (Cases, File menu, first screen, Professional Jobs); no “Start matter” or “Start from a question” left in the interface; every new control has help")
    func oneNewCaseEntry() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func src(_ p: String) throws -> String { try String(contentsOf: root.appendingPathComponent(p), encoding: .utf8) }
        let cases = try src("Kalsmritikosh/UI/CasesView.swift"), jobs = try src("Kalsmritikosh/UI/PersonaJobsView.swift")
        let app = try src("Kalsmritikosh/KalsmritikoshApp.swift"), onboarding = try src("Kalsmritikosh/UI/OnboardingView.swift")
        #expect(cases.contains("Label(\"New case…\"") && jobs.contains("Label(\"New case…\"") && app.contains("Button(\"New case…\")") && onboarding.contains("Label(\"New case…\""))
        #expect(jobs.contains("NewCaseSheet(profession:") && cases.contains("The question (optional)"))
        guard let en = FileManager.default.enumerator(at: root.appendingPathComponent("Kalsmritikosh/UI"), includingPropertiesForKeys: nil) else { Issue.record("no UI"); return }
        for case let url as URL in en where url.pathExtension == "swift" {
            let s = try String(contentsOf: url, encoding: .utf8)
            #expect(!s.contains("\"Start matter\"") && !s.contains("“Start matter”") && !s.contains("\"Start from a question"), "\(url.lastPathComponent)")
        }
        for control in ["New case…", "Add documents…", "Mark privileged…", "Report as PDF or Word…", "Case file report as PDF…", "Case file report as Word…", "Show all jobs"] {
            #expect(!CaseMapControlHelp.text(control).isEmpty, "\(control) has no help entry")
        }
        let onboardingText = onboarding.lowercased()
        #expect(!onboardingText.contains("sources tab") && !onboardingText.contains("explore tab") && !onboardingText.contains("map preview"))
    }
}
