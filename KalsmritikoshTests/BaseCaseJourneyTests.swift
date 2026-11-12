//
//  BaseCaseJourneyTests.swift
//  KalsmritikoshTests
//
//  M9/M10 — the base-case journey (Core and Add-On Scope 2026-11-06 §2/§10; Living Case Map plan §12, §13.1):
//  A  one ordered, service-level journey through the real AppState with every optional pack off and Online
//     disabled: intake of a PDF, a Word file, an email and a scanned image (plus one unreadable file), a case,
//     an exact case search with its receipt, opening the source, a note, a chronology entry, links, contrary
//     evidence, a reviewed contradiction, a partly answered evidence request, a reviewed finding under the
//     existing approval policy and a cited report released through the one output door and read back from disk.
//  B  the parts of the plan's §12 multi-day case that CaseMapHistoryTests.multiDayReplay does not cover:
//     Day 3 (a January–March request with a duplicate, March outstanding, no automatic fulfilment) as the map
//     shows it, Day 4 (a debit and a later return kept apart with their currency, account and dates; a namesake
//     kept distinct; no "loss" wording) and Day 6 (a reasoned finding, reviewed items in the report, the report
//     and the map export keeping citations and contrary evidence).
//  C  subscription and pack boundaries: on a case built before the lapse, the map, search, change feed, history,
//     map export, backup, help and case erasure keep working while lapsed (and with every optional pack off);
//     opening a case and carrying a search hit into the report are refused, proving the override is in force.
//  Synthetic files only; no network, no AI reader (contradictions come from the rules path).
//

import AppKit
import Foundation
import PDFKit
import Testing
@testable import Kalsmritikosh

private let journeyRepoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

// MARK: - Shared helpers (file-private)

/// Every module that is not core (or merged into core) switched OFF for `body`; the stored values are put back.
/// The same rule as ScopeCoreTests.withOptionalPacksOff.
@MainActor
private func journeyPacksOff(_ body: () async throws -> Void) async rethrows {
    let store = AppDefaults.store
    let packs = ProductModule.allCases.filter { $0.disposition != .core && $0.disposition != .merge }
    let saved = packs.map { store.object(forKey: ProductModuleFlags.storageKey($0)) }
    for m in packs { store.set(false, forKey: ProductModuleFlags.storageKey(m)) }
    defer {
        for (m, v) in zip(packs, saved) {
            if let v { store.set(v, forKey: ProductModuleFlags.storageKey(m)) } else { store.removeObject(forKey: ProductModuleFlags.storageKey(m)) }
        }
    }
    for m in packs { #expect(!ProductModuleFlags.isEnabled(m), "\(m.rawValue) is still on") }
    try await body()
}

/// Online disabled for `body`: the connectivity choice is Private (put back afterwards); the Online answers
/// module is off and no cloud path is allowed.
@MainActor
private func journeyOnlineOff(_ body: () async throws -> Void) async rethrows {
    let key = "kalsmritikosh.connectivity.mode"   // ConnectivityMode's stored choice
    let saved = UserDefaults.standard.object(forKey: key)
    defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
    ConnectivityMode.set(.privateMode)
    #expect(ConnectivityMode.stored == .privateMode && ConnectivityMode.current == .privateMode)
    #expect(!ProductModuleFlags.isEnabled(.onlineAnswers))
    #expect(!OnlineSettings.cloudAllowed, "Online must be disabled for the base journey")
    try await body()
}

/// The core import queue (W1-9) runs imports in the background; the journey reads its files in order, the
/// module's documented "off" behaviour, so the receipt and the failures exist when ingestFiles returns.
@MainActor
private func journeyImportQueueOff(_ body: () async throws -> Void) async rethrows {
    let key = ProductModuleFlags.storageKey(.importQueue)
    let saved = AppDefaults.store.object(forKey: key)
    defer { if let saved { AppDefaults.store.set(saved, forKey: key) } else { AppDefaults.store.removeObject(forKey: key) } }
    AppDefaults.store.set(false, forKey: key)
    try await body()
}

private func journeyAnalysis(_ f: CaseFileTests.Fixture) -> InvestigationAnalysisService {
    let evidence = EvidenceStore(database: f.db)
    return InvestigationAnalysisService(cases: f.cases, resolver: CaseRetrievalScopeResolver(evidence: evidence), evidence: evidence,
                                        analysis: InvestigationAnalysisRepository(database: f.db))
}

private func journeyDesk(_ f: CaseFileTests.Fixture) -> InvestigationContradictionGapService {
    let evidence = EvidenceStore(database: f.db)
    return InvestigationContradictionGapService(cases: f.cases, resolver: CaseRetrievalScopeResolver(evidence: evidence), evidence: evidence,
                                                contradictions: ContradictionsRepository(database: f.db), gaps: GapNodeRepository(database: f.db),
                                                reviews: InvestigationDeskReviewRepository(database: f.db))
}

/// The one output door, with custody from the case scope (as CaseMapHistoryTests does).
private func journeyOutputs(_ f: CaseFileTests.Fixture) throws -> (CaseOutputService, URL) {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("basejourney-out-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    let db = f.db
    let svc = CaseOutputService(database: f.db, caseFiles: f.svc, custody: { caseID in
        try await db.query("SELECT source_ref FROM investigation_case_sources WHERE case_id = ? AND in_scope = 1 AND source_kind = 'sourceVersion';", [.uuid(caseID)])
            .compactMap { $0.uuid(0) }.map { CustodyManifestEntry(sourceVersionID: $0, contentHash: nil, custodyEvents: []) }
    }, pendingDirectory: temp.appendingPathComponent("pending", isDirectory: true))
    return (svc, temp)
}

private func journeyMapRequest(_ p: CaseMapProjection, _ placements: [CaseMapNodeID: CaseMapPlacement]) -> CaseMapExportRequest {
    let r = CaseMapViewFilter.apply(p, view: .overview, filter: CaseMapFilter(collapsed: []))
    return CaseMapExportRequest(projection: p, placements: placements, shown: r.shown, links: r.links, selection: nil, viewTitle: "Overview",
                                state: .current(Date()), scopeFingerprint: "fp")
}

private func journeyUTC() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC") ?? .current
    return c
}

private func journeyDay(_ y: Int, _ m: Int, _ d: Int) -> Date {
    journeyUTC().date(from: DateComponents(year: y, month: m, day: d, hour: 12)) ?? Date()
}

/// A stored evidence reference as the report prints it (the case file keeps what the caller wrote).
private func journeyMentions(_ text: String, _ id: UUID) -> Bool {
    text.contains(id.uuidString) || text.contains(id.uuidString.lowercased())
}

// MARK: - Synthetic intake files

private enum JourneyFiles {
    /// A one-page PDF with a text layer, one line per entry.
    @MainActor
    static func pdf(_ lines: [String]) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        ctx.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSAttributedString(string: lines.joined(separator: "\n"), attributes: [.font: NSFont.systemFont(ofSize: 12)])
            .draw(in: CGRect(x: 54, y: 54, width: 504, height: 684))
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage(); ctx.closePDF()
        return data as Data
    }

    /// A Word file written by the app's own DOCX writer (a complete OOXML package).
    static func docx(title: String, paragraphs: [String]) throws -> Data {
        let doc = ExportableDocument(
            title: title,
            sections: [ExportSection(title: "Memo", paragraphs: paragraphs)],
            manifest: ExportManifest(exportedAt: Date(timeIntervalSince1970: 1_772_000_000), appVersion: "test", schemaVersion: 1,
                                     workspaceTitle: "Facilities", sourceVersionIDs: [], sourceHashes: [],
                                     selectedFindingCount: 0, knownLimitations: []))
        return try WorkProductExportService().data(for: doc, format: .docx)
    }

    /// A "scanned" page: large black type on white, as a PNG with no text layer.
    @MainActor
    static func scan(_ text: String) throws -> Data {
        let size = NSSize(width: 1800, height: 300)
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        (text as NSString).draw(at: NSPoint(x: 40, y: 100),
                                withAttributes: [.font: NSFont.systemFont(ofSize: 96, weight: .bold), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    /// A file that claims to be a PDF but is not one.
    static func damagedPDF() -> Data {
        var d = Data("%PDF-1.7\n".utf8)
        d.append(Data((0..<4096).map { UInt8(truncatingIfNeeded: ($0 &* 37) ^ 0x5A) }))
        return d
    }
}

// MARK: - A. The base-case journey

@MainActor
@Suite("Base-case journey (scope §2/§10)", .serialized)
struct BaseCaseJourneyTests {

    @Test("With every optional pack off and Online disabled: intake (PDF, Word, email, scan, one unreadable), a case, exact case search with its receipt, open the source, a note, a chronology entry, links, contrary evidence, a reviewed contradiction, a partly answered request, a reviewed finding and a cited report read back from disk",
          .timeLimit(.minutes(8)))
    func baseCaseJourney() async throws {
        try await journeyPacksOff {
            try await journeyOnlineOff {
                try await journeyImportQueueOff {
                    let (state, dir) = try await RealArchivePipelineTests.bootState(label: "basejourney")
                    guard case .ready = state.phase else {
                        Issue.record("AppState did not boot — the base-case journey was NOT verified")
                        await RealArchivePipelineTests.teardown(state, dir); return
                    }
                    do {
                        try await journey(state, dir)
                    } catch {
                        await RealArchivePipelineTests.teardown(state, dir)
                        throw error
                    }
                    await RealArchivePipelineTests.teardown(state, dir)
                }
            }
        }
    }

    private func journey(_ state: AppState, _ dir: URL) async throws {
        let db = try #require(state.database)
        let objects = try #require(state.objects)

        // ── 1. Intake ───────────────────────────────────────────────────────────────────────────────
        let docs = dir.appendingPathComponent("intake", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let pdfURL = docs.appendingPathComponent("invoice-INV-2041.pdf")
        try JourneyFiles.pdf(["Invoice INV-2041 from Dalmia Traders.",
                              "Annual generator service, Block C.",
                              "Total due 12,500 rupees.",
                              "Approval status: not approved at the time of payment."]).write(to: pdfURL)
        let docxURL = docs.appendingPathComponent("approval-memo.docx")
        try JourneyFiles.docx(title: "Approval memo",
                              paragraphs: ["Vikram Rao approved payment of invoice INV-2041 on 4 March 2026.",
                                           "The memo was filed with Facilities."]).write(to: docxURL)
        let emlSource = journeyRepoRoot.appendingPathComponent("Kalsmritikosh/Resources/Fixtures/AcceptanceSupplierPayment/email-invoice-resend-1.eml")
        let emlURL = docs.appendingPathComponent("email-invoice-resend-1.eml")
        try FileManager.default.copyItem(at: emlSource, to: emlURL)
        let damagedURL = docs.appendingPathComponent("damaged-statement.pdf")
        try JourneyFiles.damagedPDF().write(to: damagedURL)
        // The scan is read by text recognition. On a machine where Vision does not answer (the hosted CI runner), it
        // would stall the suite, so it is not taken in and the step is shown as NOT verified — never pretended.
        let ocrWorks = TextRecognitionProbe.works
        let scanURL = docs.appendingPathComponent("witness-scan.png")
        var intake = [pdfURL, docxURL, emlURL, damagedURL]
        if ocrWorks {
            try JourneyFiles.scan("SECOND PAYMENT NOT APPROVED").write(to: scanURL)
            intake.append(scanURL)
        } else {
            withKnownIssue("Text recognition does not answer on this machine: the scanned image was not read and the scan step is NOT verified here") {
                Issue.record("scan step not run (TextRecognitionProbe.works == false)")
            }
        }
        await state.ingestFiles(intake)

        // The unreadable file is listed under Needs attention with a reason; the readable ones are not.
        let attempts = try #require(state.ingestAttempts)
        let failures = await attempts.recentFailures(limit: 50)
        let damagedFailure = failures.first { $0.url.hasSuffix("damaged-statement.pdf") }
        #expect(damagedFailure != nil, "the unreadable file is not listed as failed: \(failures.map(\.url))")
        let damagedReason: String = damagedFailure.flatMap { $0.detail } ?? ""
        #expect(!damagedReason.trimmingCharacters(in: .whitespaces).isEmpty, "a failure carries its reason")
        for name in ["invoice-INV-2041.pdf", "approval-memo.docx", "email-invoice-resend-1.eml"] + (ocrWorks ? ["witness-scan.png"] : []) {
            let failed = failures.filter { $0.url.hasSuffix(name) }.map { $0.detail ?? "" }
            #expect(failed.isEmpty, "\(name) failed: \(failed)")
        }

        // ── 2. A case over a workspace holding the intake ────────────────────────────────────────────
        var fileIDs: [String: UUID] = [:]
        for row in try await db.query("SELECT id, url FROM files;") {
            guard let id = row.uuid(0), let raw = row.string(1) else { continue }
            let name = URL(string: raw)?.lastPathComponent ?? URL(fileURLWithPath: raw).lastPathComponent
            fileIDs[name.removingPercentEncoding ?? name] = fileIDs[name.removingPercentEncoding ?? name] ?? id
        }
        let readableNames = ["invoice-INV-2041.pdf", "approval-memo.docx", "email-invoice-resend-1.eml"] + (ocrWorks ? ["witness-scan.png"] : [])
        let readableIDs = try readableNames.map { try #require(fileIDs[$0], "\($0) has no file record") }
        let workspaces = try #require(state.workspaces)
        let ws = Workspace(title: "Supplier payments")
        try await workspaces.upsert(ws)
        // S14 (QA-15): the coordinator admits the unreadable file too, as not read with its reason, so the case can account
        // for it (it is never projected or counted as read).
        if let damagedID = fileIDs["damaged-statement.pdf"] {
            let added = try await #require(state.workspaceSourceCoordinator).addSources(Set(readableIDs).union([damagedID]), to: ws.id, at: Date())
            #expect(added.notRead[damagedID]?.isEmpty == false, "the unreadable file is admitted as not read: \(added.notRead)")
            #expect(readableIDs.allSatisfy { added.added.contains($0) && added.notRead[$0] == nil })
        } else {
            try await #require(state.workspaceSourceCoordinator).addSources(Set(readableIDs), to: ws.id, at: Date())
            Issue.record("the unreadable file left no file record — a case cannot list it as not read")
        }
        let cases = try #require(state.investigationCases)
        let svc = try #require(state.caseFiles)
        let created = try await cases.createCase(workspaceID: ws.id, title: "Was INV-2041 paid twice?", actor: "Ada", at: Date())
        let (_, included) = try await #require(state.investigationWorkspaceIntake).includeWorkspaceSources(caseID: created.id, actor: "Ada", at: Date())
        #expect(included >= readableNames.count, "included \(included)")
        let f = CaseFileTests.Fixture(db: db, cases: cases, workspaces: workspaces, svc: svc, workspaceID: ws.id, caseID: created.id)
        let record = try #require(try await cases.fetch(caseID: f.caseID))
        let inScope = Set(record.sources.filter(\.inScope).compactMap { UUID(uuidString: $0.sourceRef) })
        let labels = try await CaseCoverageRepository(database: db).labels(for: Array(inScope))
        let versionByName = Dictionary(labels.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        var objectByVersion: [UUID: UUID] = [:]
        for (object, versions) in try await objects.sourceVersionsByObject(inSourceVersionIDs: inScope) {
            for v in versions where objectByVersion[v] == nil { objectByVersion[v] = object }
        }
        func doc(_ name: String) throws -> (version: UUID, object: UUID) {
            let v = try #require(versionByName[name], "\(name) is not in the case scope: \(versionByName.keys.sorted())")
            return (v, try #require(objectByVersion[v], "\(name) has no readable text in the case"))
        }
        let pdf = try doc("invoice-INV-2041.pdf"), memo = try doc("approval-memo.docx"), email = try doc("email-invoice-resend-1.eml")

        // ── 3. Exact case search, with its receipt ───────────────────────────────────────────────────
        let search = CaseSearchService(sources: CaseSearchSources.live(database: db))
        let options = CaseSearchOptions(timeZoneID: "UTC")
        let phrase = try #require(await search.run(caseID: f.caseID, text: "\"approved payment of invoice\"", options: options).run)
        #expect(phrase.hits.map(\.name) == ["approval-memo.docx"], "\(phrase.hits.map(\.name))")
        #expect(phrase.documentCount == 1 && phrase.occurrenceCount == 1)
        let notSearched = phrase.receipt.items.filter { $0.category != .partlySearched && $0.category != .excluded }
        #expect(notSearched.contains { $0.name == "damaged-statement.pdf" },
                "the receipt must list the unreadable file as not searched: \(phrase.receipt.lines)")
        #expect(!phrase.isComplete && phrase.countsLine.contains("incomplete"))
        let exact = try #require(await search.run(caseID: f.caseID, text: "exact:\"INV-2041\"", options: options).run)
        #expect(exact.documentCount == 3, "INV-2041 is in the invoice, the memo and the email: \(exact.hits.map(\.name))")
        #expect(Set(exact.hits.map(\.objectID)) == [pdf.object, memo.object, email.object])
        if ocrWorks {
            let scanned = try #require(await search.run(caseID: f.caseID, text: "\"second payment not approved\"", options: options).run)
            #expect(scanned.hits.map(\.name) == ["witness-scan.png"], "the scan's recognised text is searchable: \(scanned.hits.map(\.name))")
        }

        // ── 4. Open the source from the hit (as the panel's "Open source" does) ───────────────────────
        let hit = try #require(phrase.hits.first)
        let witness = try #require(hit.witnesses.first)
        #expect(witness.matchedText.lowercased() == "approved payment of invoice")
        #expect(hit.versionIDs.contains(memo.version))
        let opened = try #require(try await objects.fetchSourceURL(id: hit.objectID))
        #expect(opened.lastPathComponent == "approval-memo.docx" && FileManager.default.fileExists(atPath: opened.path))
        let content = try #require(try await objects.fetchContent(id: hit.objectID))
        #expect(content.contains("Vikram Rao approved payment of invoice INV-2041"))

        // ── 5. A note ────────────────────────────────────────────────────────────────────────────────
        let note = try await f.file.addJournal(caseID: f.caseID, kind: .note, text: "Ask Facilities who filed the memo.", eventDate: nil,
                                               evidenceRef: nil, actor: "Ada")

        // ── 6. A chronology entry from the hit, with its evidence and quote ──────────────────────────
        let chron = try await PassageChronology.add(caseID: f.caseID, objectID: hit.objectID, sourceVersionID: hit.versionIDs.first,
                                                    quote: "Vikram Rao approved payment of invoice INV-2041 on 4 March 2026",
                                                    text: "Payment of INV-2041 approved", eventDate: journeyDay(2026, 3, 4),
                                                    caseFiles: svc, actor: "Ada")
        #expect(chron.support.isDocumentary, "the chronology quote verifies against the memo: \(chron.support.label)")
        #expect(chron.sourceVersionID == memo.version)

        // ── 7. Links: a supporting passage, and an investigator's link on the map ──────────────────────
        let a1 = try await f.file.addAllegation(caseID: f.caseID, text: "INV-2041 was approved before it was paid", actor: "Ada")
        let a2 = try await f.file.addAllegation(caseID: f.caseID, text: "INV-2041 was paid a second time", actor: "Ada")
        let supports = try await svc.linkEvidence(caseID: f.caseID, allegationID: a1, evidenceRef: memo.version.uuidString, label: "Approval memo", stance: .supports,
                                                  note: nil, passage: StudioEvidenceRef(sourceVersionID: memo.version, objectID: memo.object,
                                                                                        quote: "Vikram Rao approved payment of invoice INV-2041 on 4 March 2026"),
                                                  actor: "Ada")
        #expect(supports.verification.support.isDocumentary, "\(supports.verification.support.label)")

        // ── 8. Contrary evidence ─────────────────────────────────────────────────────────────────────
        let contrary = try await svc.linkEvidence(caseID: f.caseID, allegationID: a1, evidenceRef: pdf.version.uuidString, label: "Invoice", stance: .contradicts,
                                                  note: "The invoice says it was not approved when paid", passage: StudioEvidenceRef(
                                                    sourceVersionID: pdf.version, objectID: pdf.object, quote: "Approval status: not approved at the time of payment"),
                                                  actor: "Ada")
        #expect(contrary.verification.support.isDocumentary, "\(contrary.verification.support.label)")

        // ── 9. A contradiction reviewed (a rules-path detection over the two passages) ────────────────
        let finding = CaseContradictionFinder.Finding(kind: .amount, subject: "Invoice INV-2041", attribute: "amount due",
                                                      quoteA: "Total due 12,500 rupees.", quoteB: "Amount due ₹10,000",
                                                      objectA: pdf.object, objectB: email.object, versionA: pdf.version, versionB: email.version,
                                                      valueA: "12,500 rupees", valueB: "₹10,000", provenance: .rules)
        await ContradictionsRepository(database: db).insertMany([finding.contradiction()])
        let contradictionID = finding.contradiction().id
        let desk = journeyDesk(f)
        _ = try await desk.reviewContradiction(caseID: f.caseID, contradictionID: contradictionID, decision: .confirmed, reason: nil,
                                               note: "The resend quotes a different amount", actor: "Ada", at: Date())
        let reviewed = try #require(try await desk.contradictionReviewItems(caseID: f.caseID).first { $0.id == contradictionID })

        // ── 10. An evidence request, partly answered: it stays open ──────────────────────────────────
        let analysis = journeyAnalysis(f)
        let months = EvidenceRequestItemSpec.monthly("Bank statement", from: journeyDay(2026, 1, 1), to: journeyDay(2026, 3, 31), calendar: journeyUTC())
        let request = try await analysis.createEvidenceRequest(caseID: f.caseID, details: EvidenceRequestDetails(
            description: "Bank statements", allegationID: a2, custodian: "First Bank", items: months), actor: "Ada", at: Date())
        var requestFile = try #require(try await analysis.requestFiles(caseID: f.caseID).first { $0.id == request.id })
        try await analysis.linkReceivedSource(requestID: request.id, itemID: requestFile.items.first?.id, sourceVersionID: email.version,
                                              knowledgeObjectID: email.object, actor: "Ada", at: Date())
        requestFile = try #require(try await analysis.requestFiles(caseID: f.caseID).first { $0.id == request.id })
        #expect(requestFile.progress.state == .partlyReceived && requestFile.progress.received.count == 1 && requestFile.progress.outstanding.count == 2)
        #expect(requestFile.request.status == .open, "an arrival never fulfils a request")

        // The investigator's own link on the map: the second-payment question depends on the request.
        let mapRepo = CaseMapRepository(database: db)
        let linkID = try await mapRepo.addLink(caseID: f.caseID, type: .dependsOn,
                                               from: CaseMapNodeID(caseID: f.caseID, kind: .allegation, id: a2),
                                               to: CaseMapNodeID(caseID: f.caseID, kind: .request, id: request.id),
                                               rationale: "Only the bank statements can show a second payment", actor: "Ada")

        // ── 11. A reviewed finding under the existing approval policy ─────────────────────────────────
        await #expect(throws: CaseFileError.self) {   // an adverse finding needs the response put to the respondent
            try await svc.decide(allegationID: a1, caseID: f.caseID, disposition: .substantiated, rationale: "The memo records the approval", actor: "Ada")
        }
        try await f.file.recordResponse(allegationID: a1, caseID: f.caseID, response: "Vikram Rao says he approved it on 4 March.", actor: "Ada")
        try await svc.decide(allegationID: a1, caseID: f.caseID, disposition: .substantiated, rationale: "The memo records the approval", actor: "Ada")
        #expect(try await f.file.allegations(caseID: f.caseID).first { $0.id == a1 }?.disposition == .substantiated)
        let reportItem = try await JobResultHandoff.addReviewedToReport(reviewed, allegationID: a1, caseFiles: svc, actor: "Ada")

        // The map shows the journey: documents, the note, both questions, the links, the confirmed contradiction.
        let load = await caseMapLoad(f)
        let p = try #require(load.projection, "the map did not load: \(load.state)")
        #expect(p.node(CaseMapNodeID(caseID: f.caseID, kind: .journal, id: note))?.isDocumentary == false)
        #expect(p.node(CaseMapNodeID(caseID: f.caseID, kind: .contradiction, id: contradictionID))?.review == .confirmed)
        #expect(p.node(CaseMapNodeID(caseID: f.caseID, kind: .reportItem, id: reportItem)) != nil)
        let a1Node = CaseMapNodeID(caseID: f.caseID, kind: .allegation, id: a1)
        #expect(p.links(of: a1Node).contains { $0.type == .supports } && p.links(of: a1Node).contains { $0.type == .challenges })
        let drawn = try #require(p.links.first { $0.origins.first?.recordID == linkID.uuidString.lowercased() })
        #expect(drawn.type == .dependsOn && drawn.basis == "Only the bank statements can show a second payment")

        // ── 12. A cited report through the one output door, read back from disk ──────────────────────
        let (out, temp) = try journeyOutputs(f)
        defer { try? FileManager.default.removeItem(at: temp) }
        let coverage = try await CaseCoverageReadout.load(database: db, workspaceID: ws.id, scope: inScope)
        let requests = try await analysis.requestFiles(caseID: f.caseID)
        let pkg = try await out.prepare(caseID: f.caseID, kind: .caseFileReport, route: .file, actor: "Ada") {
            CaseFileDocuments.caseFileReport($0, coverage: coverage, requests: requests, by: "Ada")
        }
        let reportURL = temp.appendingPathComponent("Case file.md")
        let receipt = await out.write(pkg, to: reportURL)
        #expect(receipt.status == .written && receipt.recorded, "\(receipt.summary)")
        let bytes = try Data(contentsOf: reportURL)
        #expect(StudioRecordRepository.sha256(bytes) == pkg.digest, "the bytes on disk are the released bytes")
        let report = String(decoding: bytes, as: UTF8.self)
        #expect(report.hasPrefix("> DRAFT case file"))
        // Citations: the documents, the quotes and the source versions.
        #expect(report.contains("Vikram Rao approved payment of invoice INV-2041 on 4 March 2026"))
        #expect(journeyMentions(report, memo.version) && journeyMentions(report, pdf.version))
        #expect(report.contains("(verified passage)"))
        #expect(report.contains("Payment of INV-2041 approved"), "the chronology entry")
        #expect(pkg.citations.contains { $0.sourceVersionID == memo.version } && pkg.citations.contains { $0.sourceVersionID == pdf.version })
        // Contrary evidence and the reviewed contradiction.
        #expect(report.contains(GridStance.contradicts.label + ":") && report.contains("Approval status: not approved at the time of payment"))
        #expect(report.contains(JobResultHandoff.reviewText(reviewed.contradiction)), "the reviewed contradiction is in the report, not retyped")
        // Found by this journey (2026-11-07) and fixed: a contradiction CONFIRMED on review and carried is a reviewed result.
        #expect(report.contains("## Reviewed results included in this report"))
        // What is unresolved: the open question, the request still missing two months, the unreadable file.
        #expect(report.contains("## Unresolved questions and limitations"))
        #expect(report.contains("INV-2041 was paid a second time — unresolved"))
        #expect(report.contains("## Evidence requests") && report.contains("1 of 3 received"))
        #expect(report.contains("damaged-statement.pdf"), "the coverage section names the unreadable file")
        #expect(!report.contains("Ask Facilities who filed the memo"), "a working note is not a finding")

        // The map leaves through the same door as a PDF with its relationship table.
        let mapPkg = try await out.prepareMap(journeyMapRequest(p, load.placements), format: .pdf, route: .file, actor: "Ada")
        #expect(mapPkg.text.contains("depends on") && mapPkg.text.contains("Only the bank statements can show a second payment"))
        let mapURL = temp.appendingPathComponent("Case map.pdf")
        let mapReceipt = await out.write(mapPkg, to: mapURL)
        #expect(mapReceipt.status == .written && mapReceipt.recorded)
        #expect((PDFDocument(url: mapURL)?.pageCount ?? 0) > 0, "the delivered map PDF opens")
    }
}

// MARK: - B. Plan §12, the parts multiDayReplay does not cover

@MainActor
@Suite("Base-case journey — §12 multi-day acceptance", .serialized)
struct BaseCaseMultiDayTests {

    @Test("§12 Days 3, 4 and 6: a January–March request with a duplicate shows March outstanding and is not fulfilled; a debit and a later return stay apart with currency, account and dates, and a namesake stays distinct; a reasoned finding and reviewed items reach the report and the map export with their citations and the contrary evidence")
    func daysThreeFourSix() async throws {
        let rig = try await CaseMapRig.make()
        let f = rig.f
        let analysis = journeyAnalysis(f)
        // Day 1 (covered elsewhere): the question.
        let question = try await f.file.addAllegation(caseID: f.caseID, text: "Was this supplier paid twice, and were the payments authorised?", actor: "Ada")
        let open = try await f.file.addAllegation(caseID: f.caseID, text: "Who authorised the second payment?", actor: "Ada")

        // ── Day 3: request January–March; January and February arrive, plus an exact duplicate of January ──
        let months = EvidenceRequestItemSpec.monthly("Bank statement", from: journeyDay(2026, 1, 1), to: journeyDay(2026, 3, 31), calendar: journeyUTC())
        let request = try await analysis.createEvidenceRequest(caseID: f.caseID, details: EvidenceRequestDetails(
            description: "Bank statements", allegationID: question, custodian: "First Bank", items: months), actor: "Ada", at: journeyDay(2026, 4, 1))
        let jan = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "statement-2026-01.txt", text: "January statement. Balance 100.")
        let feb = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "statement-2026-02.txt", text: "February statement. Balance 90.")
        let dup = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "copy of january.txt", text: "January statement. Balance 100.")
        let janHash = try #require(try await f.db.query("SELECT content_hash FROM source_versions WHERE id = ?;", [.uuid(jan.version)]).first?.string(0))
        try await f.db.exec("UPDATE source_versions SET content_hash = ? WHERE id = ?;", [.text(janHash), .uuid(dup.version)])   // the same bytes twice
        var file = try #require(try await analysis.requestFiles(caseID: f.caseID).first { $0.id == request.id })
        try await analysis.linkReceivedSource(requestID: request.id, itemID: file.items[0].id, sourceVersionID: jan.version, knowledgeObjectID: jan.object, actor: "Ada", at: journeyDay(2026, 4, 2))
        try await analysis.linkReceivedSource(requestID: request.id, itemID: file.items[1].id, sourceVersionID: feb.version, knowledgeObjectID: feb.object, actor: "Ada", at: journeyDay(2026, 4, 3))
        let copy = try await analysis.linkReceivedSource(requestID: request.id, itemID: file.items[0].id, sourceVersionID: dup.version, knowledgeObjectID: dup.object,
                                                         actor: "Ada", at: journeyDay(2026, 4, 4))
        #expect(copy.duplicateOf != nil && !copy.counts, "the duplicate keeps its provenance and is not counted")
        file = try #require(try await analysis.requestFiles(caseID: f.caseID).first { $0.id == request.id })
        #expect(file.items.count == 3 && file.progress.received.count == 2 && file.progress.duplicates == 1)
        #expect(file.progress.outstanding.map(\.label) == ["Bank statement — March 2026"])
        #expect(file.request.status == .open, "no automatic fulfilment")

        // The map shows it: the request with its outstanding month, both arrivals, the duplicate marked not counted.
        var p = try #require(await caseMapLoad(f).projection)
        let reqNode = try #require(p.node(rig.node(.request, request.id)))
        #expect(reqNode.status.text.contains("2 of 3 received") && reqNode.status.text.contains("still missing: Bank statement — March 2026"))
        #expect(reqNode.status.text.contains("1 duplicate copy not counted") && reqNode.review == .pendingReview)
        let arrivals = p.links.filter { $0.type == .receivedInResponseTo && $0.to == reqNode.id }
        #expect(arrivals.count == 3)
        #expect(arrivals.filter { $0.status.text.contains("not counted") }.count == 1)
        #expect(arrivals.allSatisfy { $0.basis.contains("An arrival does not fulfil the request") })
        #expect(p.links.contains { $0.type == .requestsEvidenceFor && $0.from == reqNode.id && $0.to == rig.node(.allegation, question) })

        // ── Day 4: a second debit and a later return; a namesake in an unrelated document ────────────
        let debit = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "debit-advice.txt",
                                                              text: "Debit of ₹10,000 to Dalmia Traders from account ending 4471 on 5 March 2026.")
        let refund = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "return-advice.txt",
                                                               text: "Return of ₹10,000 from Dalmia Traders to account ending 4471 on 9 March 2026.")
        let debitEntry = try await f.file.addJournal(caseID: f.caseID, kind: .chronology, text: "Second debit of ₹10,000 (account ending 4471)",
                                                     eventDate: journeyDay(2026, 3, 5), evidenceRef: debit.version.uuidString,
                                                     quote: "Debit of ₹10,000 to Dalmia Traders from account ending 4471 on 5 March 2026.", actor: "Ada")
        let returnEntry = try await f.file.addJournal(caseID: f.caseID, kind: .chronology, text: "Return of ₹10,000 (account ending 4471)",
                                                      eventDate: journeyDay(2026, 3, 9), evidenceRef: refund.version.uuidString,
                                                      quote: "Return of ₹10,000 from Dalmia Traders to account ending 4471 on 9 March 2026.", actor: "Ada")
        let unrelated = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "staff-picnic.txt",
                                                                  text: "Ann Lee organised the staff picnic in May.")
        let entity = UUID()
        try await f.db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?,?,?,?,?);",
                            [.uuid(entity), .text("person"), .text("Ann Lee"), .text("ann lee"), .uuid(unrelated.object)])
        let witness = try await f.file.addPerson(caseID: f.caseID, name: "Ann Lee", role: .witness, entityID: nil, contact: nil, notes: "Accounts clerk", actor: "Ada")
        let namesake = try await f.file.addPerson(caseID: f.caseID, name: "Ann Lee", role: .other, entityID: entity, contact: nil, notes: "Named in the picnic memo", actor: "Ada")
        p = try #require(await caseMapLoad(f).projection)
        let d = try #require(p.node(CaseMapNodeID(caseID: f.caseID, kind: .journal, id: debitEntry)))
        let r = try #require(p.node(CaseMapNodeID(caseID: f.caseID, kind: .journal, id: returnEntry)))
        #expect(d.id != r.id, "the debit and the return are two entries")
        for (node, day) in [(d, 5), (r, 9)] {
            #expect(node.eventDate.map { journeyUTC().component(.day, from: $0) } == day)
            let words = [node.title, node.wording ?? ""].joined(separator: " ") + node.sources.compactMap(\.quote).joined(separator: " ")
            #expect(words.contains("₹10,000") && words.contains("4471"), "currency and account context kept: \(words)")
        }
        // The namesake is never merged into the witness.
        #expect(p.node(rig.node(.person, witness)) != nil && p.node(rig.node(.person, namesake)) != nil)
        #expect(p.nodes.filter { $0.kind == .person && $0.title == "Ann Lee" }.count == 2)
        #expect(p.links.filter { $0.type == .possibleSamePerson }.allSatisfy { $0.review == .pendingReview }, "a same-name pairing is only ever proposed")
        // A gross outflow is not presented as a proven loss.
        let snapshot = try #require(try await f.svc.snapshot(caseID: f.caseID, custody: []))
        let readiness = CaseReadiness.compute(projection: p, snapshot: snapshot, requests: try await analysis.requestFiles(caseID: f.caseID), coverage: nil)
        let wording = (readiness.attention + p.nodes.map(\.status.text) + p.links.map(\.status.text)).joined(separator: " ").lowercased()
        #expect(!wording.contains("loss") && !wording.contains("fraud"), "no loss or fraud conclusion is drawn")

        // ── Day 6: a reasoned finding under the approval policy; reviewed items selected for the report ─
        _ = try await f.svc.linkEvidence(caseID: f.caseID, allegationID: question, evidenceRef: rig.a.version.uuidString, label: "Invoice A", stance: .supports, note: nil,
                                         passage: StudioEvidenceRef(sourceVersionID: rig.a.version, objectID: rig.a.object, quote: "The invoice total was 500 dollars."), actor: "Ada")
        _ = try await f.svc.linkEvidence(caseID: f.caseID, allegationID: question, evidenceRef: rig.b.version.uuidString, label: "Invoice B", stance: .contradicts,
                                         note: "A different total", passage: StudioEvidenceRef(sourceVersionID: rig.b.version, objectID: rig.b.object,
                                                                                                quote: "The invoice total was 650 dollars."), actor: "Ada")
        await #expect(throws: CaseFileError.self) {
            try await f.svc.decide(allegationID: question, caseID: f.caseID, disposition: .substantiated, rationale: "Two debits cleared", actor: "Ada")
        }
        try await f.file.recordResponse(allegationID: question, caseID: f.caseID, response: "Finance says the second debit was a mistake.", actor: "Ada")
        try await f.svc.decide(allegationID: question, caseID: f.caseID, disposition: .substantiated, rationale: "Two debits cleared; one was returned", actor: "Ada")
        _ = try await rig.desk.reviewContradiction(caseID: f.caseID, contradictionID: rig.contradictionID, decision: .confirmed, reason: nil,
                                                   note: "Two different totals for one invoice", actor: "Ada", at: Date())
        let item = try #require(try await rig.desk.contradictionReviewItems(caseID: f.caseID).first { $0.id == rig.contradictionID })
        let reportID = try await JobResultHandoff.addReviewedToReport(item, allegationID: question, caseFiles: f.svc, actor: "Ada")
        p = try #require(await caseMapLoad(f).projection)
        #expect(p.node(rig.node(.allegation, question))?.review == .confirmed)
        #expect(p.node(rig.node(.reportItem, reportID))?.sources.count == 2, "both passages travel with the reviewed item")

        let (out, temp) = try journeyOutputs(f)
        defer { try? FileManager.default.removeItem(at: temp) }
        let requests = try await analysis.requestFiles(caseID: f.caseID)
        let pkg = try await out.prepare(caseID: f.caseID, kind: .caseFileReport, route: .file, actor: "Ada") {
            CaseFileDocuments.caseFileReport($0, requests: requests, by: "Ada")
        }
        let url = temp.appendingPathComponent("Day 6.md")
        #expect(await out.write(pkg, to: url).status == .written)
        let report = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(report.contains("The invoice total was 500 dollars.") && journeyMentions(report, rig.a.version))
        #expect(report.contains(GridStance.contradicts.label + ":") && report.contains("The invoice total was 650 dollars.") && journeyMentions(report, rig.b.version))
        #expect(report.contains("Two debits cleared; one was returned"), "the reasoned finding, as recorded")
        #expect(report.contains(JobResultHandoff.reviewText(item.contradiction)), "the reviewed item, not retyped")
        #expect(report.contains("Second debit of ₹10,000 (account ending 4471)") && report.contains("Return of ₹10,000 (account ending 4471)"))
        #expect(report.contains("2 of 3 received") && report.contains("still missing: Bank statement — March 2026"))
        #expect(report.contains("Who authorised the second payment? — unresolved"), "\(open)")
        // The map export keeps the contrary link with its source.
        let load = await caseMapLoad(f)
        let csv = try await out.prepareMap(journeyMapRequest(try #require(load.projection), load.placements), format: .csv, route: .file, actor: "Ada")
        #expect(csv.text.contains("row,from,relationship,to,why this link exists") && csv.text.contains(CaseMapLinkType.challenges.label))
        #expect(csv.citations.contains { $0.sourceVersionID == rig.b.version })
    }
}

// MARK: - C. Subscription and pack boundaries

@MainActor
@Suite("Subscription and pack boundaries — map, search and history", .serialized)
struct BaseCaseLapsedBoundaryTests {

    @Test("Lapsed (expired): on a case built before, the map loads, search runs, the change feed and history read and a recorded state opens, the map export releases, a backup verifies, help is there and case erasure works; opening a case and carrying a hit into the report are refused")
    func lapsedKeepsMapSearchHistory() async throws {
        try await lapsedChecks()
    }

    @Test("The same while lapsed with every optional pack off")
    func lapsedWithPacksOff() async throws {
        try await journeyPacksOff {
            try await lapsedChecks()
        }
    }

    private func lapsedChecks() async throws {
        // Built before the lapse: two invoices, a rule-found contradiction, a question with a supporting passage,
        // a recorded state.
        let rig = try await CaseMapRig.make()
        let f = rig.f
        let a = try await f.file.addAllegation(caseID: f.caseID, text: "Paid twice", actor: "Ada")
        _ = try await f.svc.linkEvidence(caseID: f.caseID, allegationID: a, evidenceRef: rig.a.version.uuidString, label: "invoice A", stance: .supports, note: nil,
                                         passage: StudioEvidenceRef(sourceVersionID: rig.a.version, objectID: rig.a.object, quote: "The invoice total was 500 dollars."),
                                         actor: "Ada")
        let history = CaseHistoryService(database: f.db, map: CaseMapService(sources: caseMapSources(f)))
        let checkpoint = try await history.record(caseID: f.caseID, kind: .milestone, name: "Before the lapse", actor: "Ada")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("basejourney-lapsed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await PaidUse.TestOverride.$entitlement.withValue(.lapsed(reason: .expired)) {
            try await PaidUse.TestOverride.$sample.withValue(false) {
                // The override is in force: paid edits are refused.
                #expect(PaidUse.refusal("edit the case file") != nil)
                await #expect(throws: PaidUse.Refused.self) {
                    _ = try await f.cases.createCase(workspaceID: f.workspaceID, title: "New while lapsed", actor: "Ada", at: Date())
                }

                // The map loads, with the case's items.
                let load = await caseMapLoad(f)
                let p = try #require(load.projection, "the map did not load while lapsed: \(load.state)")
                #expect(p.node(rig.node(.contradiction, rig.contradictionID)) != nil && p.node(rig.node(.allegation, a)) != nil)

                // Search runs over the case; carrying a hit into the report is a paid edit and is refused.
                let search = CaseSearchService(sources: CaseSearchSources.live(database: f.db))
                let run = try #require(await search.run(caseID: f.caseID, text: "invoice", options: CaseSearchOptions(timeZoneID: "UTC")).run)
                #expect(run.hits.map(\.name) == ["invoice-a.txt", "invoice-b.txt"])
                let hit = try #require(run.hits.first)
                await #expect(throws: PaidUse.Refused.self) {
                    try await PassageReportSelection.add(caseID: f.caseID, objectID: hit.objectID, sourceVersionID: hit.versionIDs.first,
                                                         quote: hit.witnesses.first?.matchedText ?? "invoice", text: "x", caseFiles: f.svc, actor: "Ada")
                }

                // The change feed and the recorded history read; the recorded state opens.
                let feed = await CaseChangeFeedService(database: f.db).load(caseID: f.caseID, projection: p)
                #expect(feed.state == .loaded && !feed.changes.isEmpty)
                #expect(try await history.checkpoints(caseID: f.caseID).map(\.id) == [checkpoint.id])
                let view = try await history.open(id: checkpoint.id, caseID: f.caseID)
                #expect(view.summary.name == "Before the lapse" && !view.projection.nodes.isEmpty)

                // A map export still leaves through the output door.
                let (out, temp) = try journeyOutputs(f)
                defer { try? FileManager.default.removeItem(at: temp) }
                let pkg = try await out.prepareMap(journeyMapRequest(p, load.placements), format: .pdf, route: .file, actor: "Ada")
                let written = await out.write(pkg, to: temp.appendingPathComponent("map.pdf"))
                #expect(written.status == .written && written.recorded, "\(written.summary)")

                // A verified backup.
                let snapshot = root.appendingPathComponent("knowledge.sqlite")
                try await f.db.backupSnapshot(to: snapshot)
                let backup = root.appendingPathComponent("backup", isDirectory: true)
                _ = try BackupService().createBackup(databaseURL: snapshot, originalURLs: [], destination: backup,
                                                     schemaVersion: SchemaMigrations.latestVersion, nowEpoch: 1_700_000_000)
                #expect(try BackupService().inspect(backupFolder: backup).verdict.ok)

                // Help for the map, search and history.
                for id in ["task-case-map", "task-case-search", "task-case-history", "task-case-changes", "task-case-map-export"] {
                    #expect(HelpRegistry.topic(id) != nil, "help topic \(id) is missing")
                }

                // Privacy control: the case can be erased.
                let erased = try await CaseEraser(database: f.db).erase(caseID: f.caseID, sourceVersionIDs: [rig.a.version, rig.b.version],
                                                                        eraseExclusiveSources: false, reason: "Client request", legalBasis: nil, actor: "Tester")
                #expect(erased.refused == nil, "\(erased.refused ?? "")")
                #expect(try await f.svc.caseHeader(f.caseID) == nil)
                #expect(try await history.checkpoints(caseID: f.caseID).isEmpty)
            }
        }
    }
}
