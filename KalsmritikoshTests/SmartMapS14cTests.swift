//
//  SmartMapS14cTests.swift
//  KalsmritikoshTests
//
//  Smart-map slice S14 part 3 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md):
//  - SRC-01: a recording opens at the cited time, an image shows the cited (Vision 0–1) region, a PDF opens at the cited
//    page; sheets/cells/slides/database rows/pixel regions are still named as "not shown". A passage pins its version,
//    block and own words. The last direct openers (event detail, cross-document matrix, connection finder, places) go
//    through the pinned path; the provenance chain never opens an unknown version.
//  - PERF-08: a legal production is refused before the first file when it will not fit, and one that stops part-way
//    removes what it wrote (never a half production looking finished).
//  - SEC-10: a seeded fuzz campaign over the exchange parser and the statement import (whole or nothing — it found a
//    partial-write bug: a non-calendar day refused only at its own row), and the HTML clip preview neutralised so the
//    system's HTML reader cannot load, embed or run anything.
//  - PERF-04: the map's branch cache is kept with who read it; a different person never reads from it, and a revoked
//    person's next branch read is refused although the case's fence did not change.
//  Synthetic data only; no network. Dates are fixed instants (UTC).
//

import Foundation
import Testing
@testable import Kalsmritikosh

private let s14cRepoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

/// A small deterministic generator (the same corpus every run, on every Mac and on CI).
private struct S14cRandom {
    var state: UInt64
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state >> 11 }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
    mutating func pick<T>(_ a: [T]) -> T { a[int(a.count)] }
}

private func s14cScratch(_ tag: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("s14c-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite("Smart map S14 part 3 — locators, openers, production space, fuzzing, HTML preview, branch cache", .serialized)
struct SmartMapS14cTests {

    // MARK: SRC-01 — typed locators

    @Test("A recording opens at the cited time, an image shows a Vision-normalised region, a PDF opens at the page; what the viewer cannot reach is still named")
    func locatorPlaces() {
        let timed = SourceLocator(transcriptStart: 75.4, transcriptEnd: 92)
        #expect(CitedSourceResolver.showablePlace(timed, fileExtension: "M4A") == .recordingTime(start: 75.4, end: 92))
        #expect(CitedSourceResolver.unsupportedLocatorNote(timed, fileExtension: "m4a") == nil, "the time is shown, so it is not 'not shown'")
        // The same locator on a file the viewer cannot play still says so (and so does the passage fallback, no extension).
        #expect(CitedSourceResolver.showablePlace(timed, fileExtension: "txt") == nil)
        #expect(CitedSourceResolver.unsupportedLocatorNote(timed, fileExtension: "txt")?.contains("the recording at 1:15–1:32") == true)
        #expect(CitedSourceResolver.unsupportedLocatorNote(timed)?.contains("1:15") == true)
        // An end before the start is dropped, never inverted.
        #expect(CitedSourceResolver.showablePlace(SourceLocator(transcriptStart: 10, transcriptEnd: 5), fileExtension: "mp3") == .recordingTime(start: 10, end: nil))

        let region = SourceLocator(boundingBox: [0.1, 0.2, 0.3, 0.05])
        #expect(CitedSourceResolver.showablePlace(region, fileExtension: "png") == .imageRegion(x: 0.1, y: 0.2, width: 0.3, height: 0.05))
        #expect(CitedSourceResolver.unsupportedLocatorNote(region, fileExtension: "jpeg") == nil)
        // A box in pixel units (or malformed) is not guessed at: named as not shown.
        for bad in [[120.0, 40, 300, 20], [0.9, 0.9, 0.5, 0.5], [0.1, 0.1, 0, 0.1], [0.1, 0.2]] {
            let l = SourceLocator(boundingBox: bad)
            #expect(CitedSourceResolver.showablePlace(l, fileExtension: "png") == nil, "\(bad)")
            #expect(CitedSourceResolver.unsupportedLocatorNote(l, fileExtension: "png")?.contains("a region of the image") == true, "\(bad)")
        }
        #expect(CitedSourceResolver.showablePlace(SourceLocator(page: 4), fileExtension: "pdf") == .page(4))
        // S18: a spreadsheet the viewer reads opens at the cell and a presentation at the slide; other formats still name it.
        let cell = SourceLocator(row: 7, column: "C", sheet: "Ledger")
        #expect(CitedSourceResolver.showablePlace(cell, fileExtension: "xlsx") == .sheetCell(sheet: "Ledger", row: 7, column: "C", cellRange: nil))
        #expect(CitedSourceResolver.unsupportedLocatorNote(cell, fileExtension: "xlsx") == nil)
        let note = CitedSourceResolver.unsupportedLocatorNote(cell, fileExtension: "numbers") ?? ""
        #expect(note.contains("sheet “Ledger”") && note.contains("cell C8"), "\(note)")
        #expect(CitedSourceResolver.unsupportedLocatorNote(SourceLocator(slide: 3), fileExtension: "pptx") == nil)
        #expect(CitedSourceResolver.unsupportedLocatorNote(SourceLocator(slide: 3), fileExtension: "key")?.contains("slide 3") == true)
        #expect(CitedSourceResolver.unsupportedLocatorNote(SourceLocator(page: 2, line: 4), fileExtension: "pdf") == nil)
    }

    @Test("A stored passage pins the version and evidence block it was read from, with its own words; a gone passage pins nothing")
    func passagePin() async throws {
        let f = try await CaseFileTests.fixture()
        let doc = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "minutes.txt",
                                                            text: "The board approved the loan on 3 March. The treasurer abstained.")
        // The passage as the reader stores it: a chunk of the object carrying its version and first evidence block.
        let chunk = UUID(), block = try #require(doc.blocks.first)
        try await f.db.exec("""
            INSERT INTO chunks (id, object_id, ordinal, text, char_start, char_end, created_at, source_version_id, evidence_block_id)
            VALUES (?,?,?,?,?,?,?,?,?);
            """, [.uuid(chunk), .uuid(doc.object), .integer(900), .text("  The board approved the loan on 3 March.  "), .integer(0), .integer(40),
                  .real(1_790_000_000), .uuid(doc.version), .uuid(block)])
        let pin = try await CitedSourceResolver.chunkPin(chunkID: chunk, database: f.db)
        #expect(pin.sourceVersionID == doc.version)
        #expect(pin.quote == "The board approved the loan on 3 March.", "trimmed, the passage's own words")
        #expect(pin.blockID == block)
        let gone = try await CitedSourceResolver.chunkPin(chunkID: UUID(), database: f.db)
        #expect(gone == CitedSourceResolver.PassagePin(sourceVersionID: nil, blockID: nil, quote: nil))
    }

    @Test("The last direct openers (event detail, cross-document matrix, connection finder, places) open through the pinned path; viewers receive the cited place")
    func lastOpenersArePinned() throws {
        func text(_ file: String) throws -> String { try String(contentsOf: s14cRepoRoot.appendingPathComponent(file), encoding: .utf8) }
        for file in ["Kalsmritikosh/UI/EventDetailSheet.swift", "Kalsmritikosh/UI/CrossDocumentMatrixView.swift",
                     "Kalsmritikosh/UI/ConnectionFinderView.swift", "Kalsmritikosh/UI/PlacesView.swift"] {
            let t = try text(file)
            #expect(!t.contains("fetchSourceURL("), "\(file) still reads the object's current file")
            #expect(!t.contains("activateFileViewerSelecting("), "\(file) still reveals the current file instead of the cited version")
            #expect(!t.contains("SourceViewer(url:"), "\(file) shows a file without the pinned check")
            #expect(t.contains("CitedSourceOpening.resolve"), "\(file) does not use the pinned path")
        }
        // The event detail opens the passage's own version and block (not the event's paraphrase).
        #expect(try text("Kalsmritikosh/UI/EventDetailSheet.swift").contains("CitedSourceResolver.chunkPin"))
        // Both viewer entry points hand the cited place to the viewer.
        #expect(try text("Kalsmritikosh/UI/CitationChips.swift").contains("place: target.place"))
        #expect(try text("Kalsmritikosh/UI/Shared/CitedSourceOpening.swift").contains("place: target.place"))
        // The provenance chain opens only a known version's exact original.
        #expect(try text("Kalsmritikosh/UI/Shared/SourceProvenanceChainView.swift").contains("guard givenVersionID ?? resolvedVersionID != nil"))
    }

    // MARK: PERF-08 — legal production folders

    private func productionDocs(_ dir: URL) throws -> [ProductionDocument] {
        let native = dir.appendingPathComponent("native.txt")
        try Data("Native bytes".utf8).write(to: native)
        return [ProductionDocument(id: UUID(), fileName: "memo.txt", text: String(repeating: "The memo says the payment was approved. ", count: 40),
                                   nativeURL: native, privileged: false),
                ProductionDocument(id: UUID(), fileName: "advice.txt", text: "Legal advice.", nativeURL: nil, privileged: true)]
    }

    @Test("A production that will not fit is refused before the first file (no folder, no Bates numbers); with room it is written")
    func productionRefusedWhenItWillNotFit() throws {
        let dir = try s14cScratch("prod")
        defer { try? FileManager.default.removeItem(at: dir) }
        let docs = try productionDocs(dir)
        let folder = dir.appendingPathComponent("ABC_0000001", isDirectory: true)
        #expect(ProductionBuilder.estimatedBytes(docs, options: ProductionOptions(prefix: "ABC", startNumber: 1)) > 0)
        do {
            _ = try ProductionBuilder.build(docs, options: ProductionOptions(prefix: "ABC", startNumber: 1), into: folder, availableCapacity: { _ in 1_000 })
            Issue.record("a production that does not fit was written")
        } catch let e as ProductionError {
            guard case .notEnoughSpace = e else { Issue.record("wrong error \(e)"); return }
            #expect(e.errorDescription?.contains("Nothing was written") == true)
        }
        #expect(!FileManager.default.fileExists(atPath: folder.path), "nothing is created when refused")
        let result = try ProductionBuilder.build(docs, options: ProductionOptions(prefix: "ABC", startNumber: 1), into: folder,
                                                 availableCapacity: { _ in 50 * 1_073_741_824 })
        #expect(result.documents == 2 && result.withheld == 1)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("DATA/production.dat").path))
    }

    @Test("A production that stops part-way removes every file and folder it created and says so; the person's own files stay")
    func productionStoppedPartWayLeavesNothingHalfWritten() throws {
        let dir = try s14cScratch("prod-stop")
        defer { try? FileManager.default.removeItem(at: dir) }
        let docs = try productionDocs(dir)
        let folder = dir.appendingPathComponent("chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mine = folder.appendingPathComponent("keep-me.txt")
        try Data("mine".utf8).write(to: mine)
        // The last write (the load file) cannot happen: something already stands at its path.
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("DATA/production.dat", isDirectory: true), withIntermediateDirectories: true)
        do {
            _ = try ProductionBuilder.build(docs, options: ProductionOptions(prefix: "XYZ", startNumber: 1), into: folder, availableCapacity: { _ in nil })
            Issue.record("the production reported success")
        } catch let e as ProductionError {
            guard case .incomplete = e else { Issue.record("wrong error \(e)"); return }
            #expect(e.errorDescription?.contains("partly written files were removed") == true)
        }
        for sub in ["IMAGES", "TEXT", "NATIVES"] {
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(sub).path), "\(sub) left behind")
        }
        #expect(FileManager.default.fileExists(atPath: mine.path), "the person's own file is untouched")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("DATA/production.dat").path), "what stood there before stays")
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("PRIVILEGE_LOG.csv").path))
    }

    // MARK: SEC-10 — fuzzing and the HTML preview

    @Test("A statement with a non-calendar day is refused whole (it used to save the rows before it)")
    func statementWithImpossibleDayRefusedWhole() async throws {
        let f = try await CaseFileTests.fixture()
        let acct = try await f.file.addMoneyAccount(caseID: f.caseID, identifier: "ACC-9", actor: "Ada")
        let st = try await f.file.addMoneyStatement(caseID: f.caseID, accountID: acct, periodStart: "2026-01-01", periodEnd: "2026-01-31",
                                                    opening: nil, closing: nil, currency: "EUR", actor: "Ada")
        await #expect(throws: CaseMoneyError.self) {
            _ = try await f.file.importStatementRows(caseID: f.caseID, statementID: st,
                                                     text: "Date,Description,Debit,Credit\n2026-01-05,Payment,100,\n2026-01-06,Refund,,20\n2026-13-01,Fee,5,", actor: "Ada")
        }
        #expect(try await f.file.moneyLedger(caseID: f.caseID).records.isEmpty, "nothing of a refused statement was written")
    }

    @Test("Seeded fuzzing: 400 mutated exchange files never crash the parser (refused with a named reason or read); 60 mutated statements import whole or not at all")
    func fuzzParsersWholeOrNothing() async throws {
        var rng = S14cRandom(state: 0x5EC10_F022)
        let valid = """
        {"format":"ime-case-exchange","version":1,"sourceSystem":"field","records":[
          {"id":"e1","kind":"event","text":"Met the supplier","date":"2026-03-04","sources":[]},
          {"id":"p1","kind":"person","text":"Mira Sen","role":"witness","sources":[]}],"relationships":[]}
        """
        let bytes = Array(valid.utf8)
        let inserts: [[UInt8]] = [Array("\u{0}".utf8), Array("\"".utf8), Array("{".utf8), Array("]".utf8), Array("\\u0000".utf8),
                                  Array("../../etc/passwd".utf8), Array("=cmd|' /C calc'!A0".utf8), Array("<script>".utf8),
                                  [0xFF, 0xFE], [0xC3], Array(String(repeating: "[", count: 200).utf8), Array("9".utf8)]
        var read = 0, refused = 0
        for _ in 0..<400 {
            var m = bytes
            for _ in 0..<(1 + rng.int(4)) {
                switch rng.int(3) {
                case 0: if !m.isEmpty { m.remove(at: rng.int(m.count)) }
                case 1: m.insert(contentsOf: rng.pick(inserts), at: rng.int(m.count + 1))
                default: if !m.isEmpty { m[rng.int(m.count)] = UInt8(truncatingIfNeeded: rng.next()) }
                }
            }
            do { _ = try CaseExchange.parse(Data(m)); read += 1 }
            catch is CaseInteropError { refused += 1 }
            catch { Issue.record("unexpected error kind \(type(of: error)): \(error)") }
        }
        #expect(read + refused == 400 && refused > 0)

        // Statements: whole or nothing, every time.
        let f = try await CaseFileTests.fixture()
        let acct = try await f.file.addMoneyAccount(caseID: f.caseID, identifier: "ACC-F", actor: "Ada")
        let st = try await f.file.addMoneyStatement(caseID: f.caseID, accountID: acct, periodStart: "2026-01-01", periodEnd: "2026-12-31",
                                                    opening: nil, closing: nil, currency: "EUR", actor: "Ada")
        let days = ["2026-01-05", "2026-02-28", "2026-13-01", "2026-00-10", "05/01/2026", "", "2026-1-5"]
        let amounts = ["100", "1,000.00", "", "abc", "-5", "=1+1", "0.01", "1e309", "  "]
        var imported = 0, refusedStatements = 0
        for _ in 0..<60 {
            var lines = ["Date,Description,Debit,Credit"]
            for i in 0..<(1 + rng.int(5)) {
                let debitSide = rng.int(2) == 0
                let amount = rng.pick(amounts)
                var line = "\(rng.pick(days)),Item \(i)\(rng.int(6) == 0 ? ",extra" : ""),\(debitSide ? amount : ""),\(debitSide ? "" : amount)"
                if rng.int(10) == 0 { line = String(line.prefix(rng.int(line.count + 1))) }
                lines.append(line)
            }
            let text = lines.joined(separator: "\n")
            let before = try await f.file.moneyLedger(caseID: f.caseID).records.count
            do {
                let ids = try await f.file.importStatementRows(caseID: f.caseID, statementID: st, text: text, actor: "Ada")
                let after = try await f.file.moneyLedger(caseID: f.caseID).records.count
                #expect(after - before == ids.count && ids.count == CaseMoneyStatementParser.rows(text).count, "partly imported: \(text)")
                imported += 1
            } catch {
                let after = try await f.file.moneyLedger(caseID: f.caseID).records.count
                #expect(after == before, "a refused statement left \(after - before) rows: \(text)")
                refusedStatements += 1
            }
        }
        #expect(imported > 0 && refusedStatements > 0, "the corpus exercises both outcomes (\(imported) imported, \(refusedStatements) refused)")
    }

    @Test("The HTML clip preview cannot load, embed, redirect or run anything; ordinary links and text survive (fixed corpus + seeded fuzz)")
    @MainActor
    func htmlPreviewNeutralised() {
        let hostile = [
            #"<img src="http://evil.example/p.png" onerror="steal()">"#, #"<IMG SRC=x onerror=alert(1)>"#,
            #"<object data="http://evil.example/x.swf"></object>"#, #"<embed src="http://evil.example/e">"#,
            #"<meta http-equiv="refresh" content="0;url=http://evil.example">"#, #"<base href="http://evil.example/">"#,
            #"<link rel="stylesheet" href="http://evil.example/s.css">"#, #"<table background="http://evil.example/b.png"><tr><td>x</td></tr></table>"#,
            #"<p style="background:url(http://evil.example/t.png)">styled</p>"#, #"<a href="javascript:alert(1)">click</a>"#,
            #"<a href=" JaVaScRiPt:alert(1)">spaced</a>"#, #"<a href='data:text/html,<script>x</script>'>data</a>"#,
            #"<a href=file:///etc/passwd>file</a>"#, #"<video poster="http://evil.example/v.png"></video>"#,
            #"<input type="image" src="http://evil.example/i.png">"#, #"<im<img>g src="http://evil.example/split.png">"#,
            #"<svg><image href="http://evil.example/s.png"/></svg>"#, #"<iframe src="http://evil.example"></iframe>"#,
            #"<div onmouseover="x()">hover</div>"#, #"<!-- <img src="http://evil.example/c.png"> -->"#, #"<form action="http://evil.example"><button>Go</button></form>"#,
        ]
        func leaks(_ s: String) -> [String] {
            let lower = s.lowercased()
            var found: [String] = []
            for tag in ["<img", "<object", "<embed", "<meta", "<base", "<link", "<iframe", "<video", "<audio", "<input", "<svg", "<frame", "<script", "<style"]
            where lower.contains(tag) { found.append(tag) }
            for attr in [" src=", " src =", "background=", "poster=", "onerror", "onmouseover", "style=", "javascript:", "data:text", "file:///", "action="]
            where lower.contains(attr) { found.append(attr) }
            if lower.range(of: #"href\s*=\s*["']?\s*(?!https?:|mailto:|#)"#, options: .regularExpression) != nil { found.append("unsafe href") }
            return found
        }
        for h in hostile {
            let out = HTMLMarkdown.readablePart(of: "<html><body><p>Before</p>\(h)<p>After</p></body></html>")
            #expect(leaks(out).isEmpty, "\(h) → \(out) leaks \(leaks(out))")
            #expect(out.contains("Before") && out.contains("After"), "the readable text is kept")
        }
        // Ordinary content survives: an https link keeps its address, prose that looks like an attribute stays.
        let ok = HTMLMarkdown.readablePart(of: ##"<body><p>The data = 5 and src = 7.</p><a href="https://example.org/report">report</a> <a href="#n2">note</a></body>"##)
        #expect(ok.contains("The data = 5 and src = 7.") && ok.contains(#"href="https://example.org/report""#) && ok.contains(##"href="#n2""##), "\(ok)")
        // Seeded fuzz: random concatenations of hostile fragments, tags split and nested.
        var rng = S14cRandom(state: 0xC11F)
        let pieces = hostile + ["<p>", "</p>", "<", ">", "\"", "'", " ", "<a ", "href=", "src=", "<i", "mg ", "text", "<b>", "</b>"]
        for _ in 0..<300 {
            let html = (0..<(2 + rng.int(8))).map { _ in rng.pick(pieces) }.joined()
            let out = HTMLMarkdown.neutralised(html)
            let tagLeaks = leaks(out).filter { $0.hasPrefix("<") || $0 == "javascript:" || $0 == "onerror" || $0 == "background=" || $0 == "poster=" }
            #expect(tagLeaks.isEmpty, "\(html) → \(out) leaks \(tagLeaks)")
        }
        // The portable package's escaper: no markup survives it, whatever the text.
        for _ in 0..<300 {
            let s = (0..<(1 + rng.int(6))).map { _ in rng.pick(pieces + ["&", "\u{0}", "\u{7}", "</style>", "]]>", "\u{202E}"]) }.joined()
            let e = CasePortablePackage.escape(s)
            #expect(!e.contains("<") && !e.contains(">") && !e.contains("\"") && !e.contains("'"), "\(s) → \(e)")
        }
    }

    // MARK: PERF-04 — branch cache by identity and permission

    @Test("The branch cache is kept with who read it: another person rereads; a revoked person's next branch read is refused though the fence is unchanged")
    func branchCacheRespectsPrincipal() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f, c = f.caseID
        let grant = try await f.file.grantAccess(caseID: c, to: "Ben", role: .investigator, reason: "Works the case", actor: "Ada")
        let service = CaseMapService(sources: caseMapSources(f))
        let report = rig.node(.report, rig.report)

        // The owner reads; a second owner branch read of the unchanged case comes from the cache.
        _ = await service.load(caseID: c, generation: 1)
        #expect(await service.branch(caseID: c, anchor: report).source == .cached)

        // Ben: never answered from the owner's read; his read is re-checked each time.
        let ben = await CaseAccessContext.$principal.withValue(.local("Ben")) { await service.branch(caseID: c, anchor: report) }
        #expect(ben.source == .reread && ben.frame?.anchor == report, "\(String(describing: ben.problem))")
        let benAgain = await CaseAccessContext.$principal.withValue(.local("Ben")) { await service.branch(caseID: c, anchor: report) }
        #expect(benAgain.source == .reread)

        // The owner, after Ben's read, does not read Ben's copy either.
        #expect(await service.branch(caseID: c, anchor: report).source == .reread)

        // Revoked: the case's fence is unchanged by the revocation's effect on Ben's next read — it is refused.
        try await f.file.revokeAccess(caseID: c, grantID: grant, reason: "Moved to another team", actor: "Ada")
        let revoked = await CaseAccessContext.$principal.withValue(.local("Ben")) { await service.branch(caseID: c, anchor: report) }
        #expect(revoked.frame == nil && revoked.problem != nil, "a revoked person read a branch from memory")
        // The owner still reads.
        #expect(await service.branch(caseID: c, anchor: report).frame?.anchor == report)
    }
}
