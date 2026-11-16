//
//  AIConflictConsolidationTests.swift
//  KalsmritikoshTests
//
//  Owner request 2026-11-16 — ONE AI conflict path. The older two-sided AI contradiction pass is removed and every caller
//  is on the AI conflict scaffolding (ConflictKind, AIConflictContract, InvestigationContradictionGapService+AIConflicts,
//  CaseConflictDetailsRepository, CaseAIConflictViews). Pinned here: the old path is gone (a source audit); older stored
//  contradictions still load with their decisions and their ids; a confirmed conflict with three sides reaches the
//  report, the case package and the PDF and Word exports with every side's quote and citation (and the integrity checks
//  still pass); "Find contradictions" with AI off runs the rules only and sends nothing. Scripted fake readers only: no
//  model, no network.
//

import CryptoKit
import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("One AI conflict path — the old two-sided pass removed, reports carry every side", .serialized)
struct AIConflictConsolidationTests {
    typealias S = AIConflictScaffoldingTests
    typealias F = CaseContradictionFinder

    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    /// Every Swift file under a folder of the repo, with its text.
    static func swiftFiles(_ folder: String) throws -> [(path: String, text: String)] {
        let base = root.appendingPathComponent(folder, isDirectory: true)
        guard let walk = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
        var out: [(String, String)] = []
        for case let url as URL in walk where url.pathExtension == "swift" {
            out.append((url.path.replacingOccurrences(of: root.path + "/", with: ""), try String(contentsOf: url, encoding: .utf8)))
        }
        return out
    }

    // MARK: - 1. The old path is gone

    @Test("Source audit: no reference to the removed two-sided pass — its reply format, parser, verifier, prompt, purpose or run fields")
    func oldPathGone() throws {
        let app = try Self.swiftFiles("Kalsmritikosh")
        let tests = try Self.swiftFiles("KalsmritikoshTests").filter { !$0.path.hasSuffix("AIConflictConsolidationTests.swift") }
        #expect(app.count > 100 && tests.count > 100, "the audit read the sources")
        let removed = [#""pairs""#, "value_a", "value_b", "CaseContradictionFinder.verify(", "CaseContradictionFinder.prompt(",
                       "CaseContradictionFinder.wholeCaseTask", "CaseContradictionFinder.wholeCaseReplyTokens", "CaseContradictionFinder.Verification",
                       "CaseContradictionFinder.sameAsRule", "case.analysis.contradictions", "aiAgreedWithRules", "passagePathReason"]
        for (path, text) in app + tests {
            for word in removed { #expect(!text.contains(word), "\(path) still refers to \(word)") }
        }
        // The finder keeps the rules and the shared helpers, and no AI pair code.
        let finder = try #require(app.first { $0.path.hasSuffix("Knowledge/Ledger/CaseContradictionFinder.swift") }).text
        for gone in ["struct Pair", "struct Reply", "func verify(reply", "public static func prompt(", "func wholeCaseTask("] {
            #expect(!finder.contains(gone), "CaseContradictionFinder still has \(gone)")
        }
        for kept in ["func ruleFindings(", "func moneyRecordFindings(", "func batches(", "func wholeCaseBatch(", "static func explained(", "static func verbatim("] {
            #expect(finder.contains(kept), "a shared helper the AI look uses is gone: \(kept)")
        }
        // The desk's "Find contradictions" runs the rules only; the one AI entry is "Look for conflicts with AI…".
        let desk = try #require(app.first { $0.path.hasSuffix("Investigator/InvestigationContradictionGapService.swift") }).text
        #expect(!desk.contains("reader.read(") && !desk.contains("readForAnalysis("), "findContradictions sends nothing")
        let section = try #require(app.first { $0.path.hasSuffix("UI/CaseContradictionsSection.swift") }).text
        #expect(section.components(separatedBy: "Label(\"Look for conflicts with AI…\"").count == 2, "one AI entry")
        #expect(section.contains("let showAI = await model.findContradictions(") && section.contains("if showAI { showingAILook = true }"),
                "“Find contradictions” leads to the same AI sheet")
    }

    // MARK: - 2. Older stored contradictions

    @Test("Older stored contradictions still load and show with their decisions and their ids: an old AI-reading row, a rules row and an archive-scan row")
    func olderRowsKeepDecisions() async throws {
        let r = try await S.rig(aiOn: false) { _, _, _ in Issue.record("the AI must not be called"); return "{}" }
        let pune = r.doc(S.pune), chennai = r.doc(S.chennai)
        // A row the removed two-sided pass stored (its description, its marker, its id).
        let qa = "Ravi Kumar said he met the supplier on 4 March 2026 at the Pune office."
        let qb = "The visitor log shows Ravi Kumar was in Chennai on 4 March 2026."
        let oldID = F.stableID(kind: .account, a: (pune.object, qa), b: (chennai.object, qb))
        // The id formula of older builds, written out: unchanged.
        let sides = ["\(pune.object.uuidString)|\(F.normalized(qa))", "\(chennai.object.uuidString)|\(F.normalized(qb))"].sorted()
        var bytes = Array(SHA256.hash(data: Data("casecheck|account|\(sides[0])|\(sides[1])".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50; bytes[8] = (bytes[8] & 0x3F) | 0x80
        #expect(oldID == UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                                     bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])))
        let oldAI = Contradiction(id: oldID, kind: .testimony,
                                  description: "Account — Ravi Kumar: Pune vs Chennai. " + F.Provenance.aiRead.marker,
                                  claimA: qa, claimB: qb, evidenceA: pune.object, evidenceB: chennai.object, severity: .medium, detectedAt: S.t0)
        // An archive-scan row (stable identity of the rescan).
        let scan = Contradiction.stableIdentities([Contradiction(kind: .date, description: "Conflicting dates for the purchase order",
                                                                 claimA: "He signed the purchase order the same day.", claimB: "the purchase order was signed on 6 March 2026",
                                                                 evidenceA: pune.object, evidenceB: chennai.object, severity: .low, detectedAt: S.t0)])
        let scanRow = try #require(scan.first)
        #expect(Contradiction.stableIdentities([scanRow]).first?.id == scanRow.id, "a rescan gives it the same id")
        let repo = ContradictionsRepository(database: r.f.db)
        await repo.insertMany([oldAI, scanRow])
        // Decisions recorded against them (as an older build did).
        let at = Date(timeIntervalSince1970: 1_794_100_000)
        _ = try await r.desk.reviewContradiction(caseID: r.caseID, contradictionID: oldID, decision: .confirmed, reason: nil, note: "the log is reliable", actor: "Ada", at: at)
        _ = try await r.desk.reviewContradiction(caseID: r.caseID, contradictionID: scanRow.id, decision: .dismissed, reason: .differentEvent, note: "two orders", actor: "Ben", at: at)
        // The rules run now; the older rows are untouched and keep their decisions.
        _ = try await r.desk.findContradictions(caseID: r.caseID, at: S.t0)
        let items = try await r.desk.contradictionReviewItems(caseID: r.caseID)
        let old = try #require(items.first { $0.id == oldID })
        #expect(old.status.current == .confirmed && old.contradiction.claimA == qa && old.extraSides.isEmpty)
        #expect(InvestigationContradictionGapService.foundBy(old.contradiction, detail: nil) == .ai)
        #expect(ConflictKind.of(old.contradiction) == .documentVsTestimony)
        let dismissed = try #require(items.first { $0.id == scanRow.id })
        #expect(dismissed.status.current == .dismissed && InvestigationContradictionGapService.foundBy(dismissed.contradiction, detail: nil) == nil)
        #expect(try await r.desk.conflictDetails(caseID: r.caseID).isEmpty, "no detail rows invented for older data")
        // The confirmed older row still reaches the report with both sources.
        try await JobResultHandoff.addReviewedToReport(old, caseFiles: r.f.svc, actor: "Ada")
        let report = try #require(try await r.f.file.reportItems(caseID: r.caseID).first)
        #expect(report.citations.count == 2 && Set(report.citations.compactMap(\.quote)) == [qa, qb])
    }

    // MARK: - 3. Three sides into the report, package and exports

    static func outputs(_ f: CaseFileTests.Fixture) throws -> (CaseOutputService, URL) {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("aicc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let db = f.db
        let svc = CaseOutputService(database: f.db, caseFiles: f.svc, custody: { caseID in
            try await db.query("SELECT source_ref FROM investigation_case_sources WHERE case_id = ? AND in_scope = 1 AND source_kind = 'sourceVersion';", [.uuid(caseID)])
                .compactMap { $0.uuid(0) }.map { CustodyManifestEntry(sourceVersionID: $0, contentHash: nil, custodyEvents: []) }
        }, pendingDirectory: temp.appendingPathComponent("pending", isDirectory: true))
        return (svc, temp)
    }

    static func flat(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    @Test("A confirmed three-sided conflict: every side's version is decided on, and every side's quote and citation reach the report, the case package, the PDF and the Word file; the integrity checks pass")
    func threeSidesEverywhere() async throws {
        let quotes = ["met the supplier on 4 March 2026 at the Pune office", "Ravi Kumar was in Chennai on 4 March 2026",
                      "the meeting with the supplier took place in Mumbai on 4 March 2026"]
        let r = try await S.rig { send, _, _ in
            S.json([["kind": "place_location", "description": "Three places for one meeting on 4 March 2026.",
                     "sides": [S.side(S.number("Pune office", in: send), quotes[0], value: "Pune"),
                               S.side(S.number("visitor log", in: send), quotes[1], value: "Chennai"),
                               S.side(S.number("Meera Shah", in: send), quotes[2], value: "Mumbai")]]])
        }
        let run = try await S.run(r)
        #expect(run.outcome == .done && run.aiFindings == 1, "\(run.message) \(run.dropped)")
        let item = try #require(try await r.desk.contradictionReviewItems(caseID: r.caseID).first { $0.extraSides.count == 1 })
        #expect(item.allSides.map(\.quote) == quotes)
        let mumbai = r.doc(S.mumbai)
        #expect(item.currentVersions[mumbai.object] == .some(mumbai.version), "the third side's document is followed for changes")
        let decision = try await r.desk.reviewContradiction(caseID: r.caseID, contradictionID: item.id, decision: .confirmed, reason: nil,
                                                            note: "three accounts", actor: "Ada", at: Date(timeIntervalSince1970: 1_794_100_000))
        #expect(decision.sourceVersions.count == 3 && decision.sourceVersions[mumbai.object] == mumbai.version)
        #expect(decision.passages[mumbai.object] == quotes[2])
        let confirmed = try #require(try await r.desk.contradictionReviewItems(caseID: r.caseID).first { $0.id == item.id })
        #expect(confirmed.status.current == .confirmed && !confirmed.status.isReopened)

        // The report item: three citations, each pinned to its side's version.
        try await JobResultHandoff.addReviewedToReport(confirmed, caseFiles: r.f.svc, actor: "Ada")
        let reportItem = try #require(try await r.f.file.reportItems(caseID: r.caseID).first)
        #expect(reportItem.citations.count == 3, "every side, not the first two")
        #expect(reportItem.citations.map(\.quote) == quotes)
        #expect(Set(reportItem.citations.compactMap(\.sourceVersionID)) == Set([S.pune, S.chennai, S.mumbai].map { r.doc($0).version }))
        #expect(!reportItem.text.contains(F.markerStem))

        // The case file report (Markdown): every side's quote and "document, place"; written and read back with its manifest.
        let (out, temp) = try Self.outputs(r.f)
        defer { try? FileManager.default.removeItem(at: temp) }
        let render: @Sendable (CaseFileSnapshot) -> String = { CaseFileDocuments.caseFileReport($0, by: "Ada") }
        let md = try await out.prepare(caseID: r.caseID, kind: .caseFileReport, route: .file, actor: "Ada", render: render)
        let body = CaseCitationText.visibleBody(md.text)
        for q in quotes { #expect(body.contains(q), "the report quotes: \(q)") }
        for name in [S.pune, S.chennai, S.mumbai] { #expect(body.contains(name + ", "), "the report cites \(name) with its place: \(body)") }
        let mdReceipt = await out.write(md, to: temp.appendingPathComponent("report.md"))
        #expect(mdReceipt.status == .written && mdReceipt.recorded, "\(mdReceipt.summary)")

        // PDF and Word: every side, read back; written, recorded and reconciled with their manifests.
        let pdf = try await out.prepareReportDocument(caseID: r.caseID, format: .pdf, actor: "Ada", render: render)
        let pdfURL = temp.appendingPathComponent("report.pdf")
        let pdfReceipt = await out.writeRechecked(pdf, to: pdfURL)
        #expect(pdfReceipt.status == .written && pdfReceipt.recorded, "\(pdfReceipt.summary)")
        let pdfText = Self.flat(try #require(CaseReportDocumentRenderer.pdfText(try Data(contentsOf: pdfURL))))
        for q in quotes { #expect(pdfText.contains(Self.flat(q)), "the PDF quotes: \(q)") }
        for name in [S.pune, S.chennai, S.mumbai] { #expect(pdfText.contains(name), "the PDF cites \(name)") }
        let docx = try await out.prepareReportDocument(caseID: r.caseID, format: .docx, actor: "Ada", render: render)
        let docxURL = temp.appendingPathComponent("report.docx")
        let docxReceipt = await out.writeRechecked(docx, to: docxURL)
        #expect(docxReceipt.status == .written && docxReceipt.recorded, "\(docxReceipt.summary)")
        let bytes = try Data(contentsOf: docxURL)
        let docText = try #require(CaseReportDocumentRenderer.docxText(bytes))
        for q in quotes { #expect(docText.contains(q), "the Word file quotes: \(q)") }
        for name in [S.pune, S.chennai, S.mumbai] { #expect(docText.contains(name + ", "), "the Word file cites \(name)") }
        let manifest = try #require(docx.manifest)
        #expect(CaseOutputArtifactCheck.problem(bytes, manifest: manifest) == nil, "the Word file reconciles with its manifest")

        // The case package (from the case map, with the desk that reads the conflict details): every side.
        let evidence = EvidenceStore(database: r.f.db)
        let analysis = InvestigationAnalysisService(cases: r.f.cases, resolver: CaseRetrievalScopeResolver(evidence: evidence), evidence: evidence,
                                                    analysis: InvestigationAnalysisRepository(database: r.f.db))
        var sources = CaseMapSources.live(database: r.f.db, caseFiles: r.f.svc, custody: nil, analysis: analysis, desk: r.desk,
                                          objects: KnowledgeObjectRepository(database: r.f.db))
        sources.custody = caseMapSources(r.f).custody
        let map = CaseMapService(sources: sources)
        let loaded = await map.load(caseID: r.caseID, generation: 1)
        let node = try #require(loaded.projection?.nodes.first { $0.kind == .contradiction && ($0.wording ?? "").contains(quotes[2]) })
        let wording = node.wording ?? ""
        #expect(node.sources.count == 3 && wording.hasPrefix("A: ") && wording.contains("\nC: "), "\(wording)")
        let pkg = try await out.preparePackage(caseID: r.caseID, selection: .wholeCase, actor: "Ada") { id in await map.load(caseID: id, generation: 2) }
        let read = CasePortablePackageReader.read(pkg.text)
        let packageText = read.sectionText.values.joined(separator: "\n")
        for q in quotes { #expect(packageText.contains(q), "the package quotes: \(q)") }
        let pkgReceipt = await out.write(pkg, to: temp.appendingPathComponent("package.html"))
        #expect(pkgReceipt.status == .written && pkgReceipt.recorded, "\(pkgReceipt.summary)")
    }

    // MARK: - 4. "Find contradictions"

    @Test("“Find contradictions” with AI off: the rules run, nothing is sent, and the screen says AI is off; with AI on it opens the AI sheet and still sends nothing until “Run the look”")
    @MainActor
    func findContradictionsButton() async throws {
        let texts = [("a-release1.txt", CaseContradictionFinderTests.release1), ("b-release4.txt", CaseContradictionFinderTests.release4)]
        let off = try await S.rig(texts: texts, privileged: [], aiOn: false) { _, _, _ in Issue.record("the AI must not be called"); return "{}" }
        let defaults = try #require(UserDefaults(suiteName: "aicc-\(UUID().uuidString)"))
        let model = CaseContradictionReviewModel(caseID: off.caseID, workspace: CaseWorkspaceHolder(caseID: off.caseID, defaults: defaults))
        let showAI = await model.findContradictions(desk: off.desk, objects: KnowledgeObjectRepository(database: off.f.db))
        #expect(!showAI, "no AI sheet with AI off")
        #expect(model.lastRun?.contains("found by the rules") == true && model.lastRun?.contains("AI is off — nothing was sent") == true, "\(model.lastRun ?? "")")
        #expect(off.log.sends.isEmpty && off.log.passages.isEmpty && off.log.consents == 0, "nothing sent")
        #expect(!model.items.isEmpty, "the rules' findings are listed")
        #expect(model.aiPreview?.aiOff == true && model.aiPreview?.coverageLine.hasPrefix("AI is off; rules checked: ") == true)

        let on = try await S.rig(texts: texts, privileged: []) { _, _, _ in S.json([]) }
        let onModel = CaseContradictionReviewModel(caseID: on.caseID, workspace: CaseWorkspaceHolder(caseID: on.caseID, defaults: defaults))
        let opens = await onModel.findContradictions(desk: on.desk, objects: KnowledgeObjectRepository(database: on.f.db))
        #expect(opens && onModel.aiPreview?.aiAvailable == true && onModel.aiPreview?.estimate != nil, "the same sheet with the estimate")
        #expect(on.log.sends.isEmpty && on.log.passages.isEmpty && on.log.consents == 0, "nothing is sent before “Run the look”")
        await onModel.runAILook(desk: on.desk, objects: KnowledgeObjectRepository(database: on.f.db))
        #expect(on.log.sends.count == 1 && onModel.aiRunText?.contains("found by the rules") == true, "\(onModel.aiRunText ?? "")")
    }
}
