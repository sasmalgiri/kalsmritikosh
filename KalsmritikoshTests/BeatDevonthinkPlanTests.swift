//
//  BeatDevonthinkPlanTests.swift
//  KalsmritikoshTests
//
//  Final test phase for the beat-DEVONthink plan: each test checks one item's
//  "Done means" at the level that can be verified without owner hardware.
//

import Foundation
import AppKit
import CryptoKit
import Testing
@testable import Kalsmritikosh

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("bdt-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func migratedDB() async throws -> (Database, URL) {
    let dir = try tempDir()
    let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
    try await SchemaMigrations.migrate(db)
    return (db, dir)
}

// MARK: - W2-4 near-duplicates

@Suite("W2-4 near-duplicates")
struct NearDuplicateFinderTests {
    static let base = (1...60).map { "word\($0)" }.joined(separator: " ")

    @Test("A draft and its edited copy group together; an unrelated document does not")
    func groupsDraftsNotStrangers() {
        let a = UUID(), b = UUID(), c = UUID()
        let edited = Self.base.replacingOccurrences(of: "word60", with: "changed")
        let unrelated = (1...60).map { "other\($0)" }.joined(separator: " ")
        let groups = NearDuplicateFinder.find(documents: [(a, Self.base), (b, edited), (c, unrelated)])
        #expect(groups.count == 1)
        #expect(Set(groups[0].members) == [a, b])
        #expect(groups[0].weakestSimilarity >= 0.8)
    }

    @Test("Jaccard of identical shingle sets is 1, of disjoint sets 0")
    func jaccardBounds() {
        let s = NearDuplicateFinder.shingles(Self.base)
        #expect(NearDuplicateFinder.jaccard(s, s) == 1)
        #expect(NearDuplicateFinder.jaccard(s, NearDuplicateFinder.shingles("a b c d e f g h")) == 0)
    }
}

// MARK: - W2-5 legal production

@Suite("W2-5 legal production")
struct LegalProductionTests {
    @Test("Bates numbers are zero-padded and keep growing past their width")
    func batesFormat() {
        #expect(BatesNumbering.format(prefix: "ABC", number: 42, width: 6) == "ABC000042")
        #expect(BatesNumbering.format(prefix: "ABC", number: 1_234_567, width: 6) == "ABC1234567")
    }

    @Test("DAT uses þ quotes and ASCII 20 separators; OPT marks document breaks")
    func loadFileFormats() {
        let row = LoadFiles.DocumentRow(begBates: "P1", endBates: "P2", pageCount: 2, fileName: "a.txt", docID: "id",
                                        textPath: "TEXT/P1.txt", nativePath: "", withheld: false)
        let dat = LoadFiles.dat([row])
        #expect(dat.hasPrefix("\u{00FE}BEGBATES\u{00FE}\u{0014}\u{00FE}ENDBATES\u{00FE}"))
        #expect(dat.contains("\u{00FE}P1\u{00FE}\u{0014}\u{00FE}P2\u{00FE}"))
        let opt = LoadFiles.opt(pages: [("P1", "IMAGES/P1.pdf", true, 2), ("P2", "IMAGES/P2.pdf", false, 2)], volume: "V1")
        #expect(opt == "P1,V1,IMAGES/P1.pdf,Y,,,2\r\nP2,V1,IMAGES/P2.pdf,,,,\r\n")
    }

    @Test("A production is continuous, writes every page, and withholds privileged documents with a slip sheet")
    func productionContinuousAndWithheld() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let long = String(repeating: "This is a long line of text for pagination. ", count: 400)
        let docs = [ProductionDocument(id: UUID(), fileName: "one.txt", text: long, nativeURL: nil, privileged: false),
                    ProductionDocument(id: UUID(), fileName: "secret.txt", text: "Attorney advice", nativeURL: nil, privileged: true),
                    ProductionDocument(id: UUID(), fileName: "three.txt", text: "Short", nativeURL: nil, privileged: false)]
        let r = try ProductionBuilder.build(docs, options: ProductionOptions(prefix: "T", startNumber: 10), into: dir)
        #expect(r.firstNumber == 10)
        #expect(r.lastNumber == 10 + r.pages - 1)
        #expect(r.pages > 3)
        #expect(r.withheld == 1)
        for n in 10...r.lastNumber {
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("IMAGES/\(BatesNumbering.format(prefix: "T", number: n)).pdf").path))
        }
        let privLog = try String(contentsOf: dir.appendingPathComponent("PRIVILEGE_LOG.csv"), encoding: .utf8)
        #expect(privLog.contains("secret.txt"))
        let text = try String(contentsOf: dir.appendingPathComponent("TEXT/\(r.firstBates).txt"), encoding: .utf8)
        #expect(text.contains("pagination"))
    }

    @Test("Bates numbers are never reused and holds are counted")
    func repositoryNumbersAndHolds() async throws {
        let (db, dir) = try await migratedDB(); defer { try? FileManager.default.removeItem(at: dir) }
        let repo = LegalProductionRepository(database: db)
        #expect(try await repo.nextNumber(prefix: "P") == 1)
        let r = ProductionResult(firstBates: "P0000001", lastBates: "P0000009", firstNumber: 1, lastNumber: 9,
                                 documents: 2, pages: 9, withheld: 0, redactions: 0, nativesSkipped: 0)
        try await repo.recordRun(prefix: "P", result: r)
        #expect(try await repo.nextNumber(prefix: "P") == 10)
        #expect(try await repo.nextNumber(prefix: "Q") == 1)
        let hold = try await repo.createHold(name: "Case A")
        try await repo.addToHold(hold, objects: [UUID(), UUID()])
        #expect(try await repo.holds().first?.items == 2)
        try await repo.release(hold)
        #expect(try await repo.holds().first?.releasedAt != nil)
    }
}

// MARK: - W2-1 annotations

@Suite("W2-1 highlights and notes")
struct AnnotationsTests {
    @Test("A highlight re-attaches after re-ingest by source file + quote, and removal is a stamp")
    func reattachAndRemove() async throws {
        let (db, dir) = try await migratedDB(); defer { try? FileManager.default.removeItem(at: dir) }
        let repo = AnnotationsRepository(database: db)
        let oldID = UUID(), newID = UUID()
        let id = try await repo.add(objectID: oldID, sourceURL: "file:///x.txt", quote: "the deadline is Friday",
                                    note: "checked", stance: .confirms)
        let moved = try await repo.forDocument(objectID: newID, sourceURL: "file:///x.txt", currentText: "So the deadline is Friday.")
        #expect(moved.map(\.id) == [id])
        #expect(moved.first?.stance.evidenceStatus == .humanConfirmed)
        let gone = try await repo.forDocument(objectID: newID, sourceURL: "file:///x.txt", currentText: "Different text now")
        #expect(gone.isEmpty)
        try await repo.remove(id)
        #expect(try await repo.all().isEmpty)
        let raw = try await db.query("SELECT removed_at FROM annotations WHERE id = ?;", [.uuid(id)])
        #expect(raw.first?.double(0) != nil)   // kept, stamped — not deleted
    }
}

// MARK: - W2-8 byte-range items

@Suite("W2-8 very large items")
struct LargeItemRangeTests {
    @Test("The kept range fits the budget, ends at a paragraph and never splits a character")
    func headFitsAndCutsClean() throws {
        let para = String(repeating: "é word ", count: 30)          // multi-byte characters
        let text = (0..<20).map { _ in para }.joined(separator: "\n\n")
        let budget = 1_000
        let head = try #require(LargeItemRange.head(of: text, maxBytes: budget))
        #expect(head.utf8.count <= budget)
        #expect(head.hasSuffix("\n\n") || head.hasSuffix("\n") || head.utf8.count > budget * 3 / 4)
        #expect(text.hasPrefix(head))
        #expect(LargeItemRange.head(of: "short", maxBytes: budget) == "short")
    }
}

// MARK: - N-9 notes apps

@Suite("N-9 notes formats")
struct NotesFormatTests {
    @Test("Obsidian wiki-links in every form")
    func wikiLinks() {
        let t = "See [[Plan]], [[Budget|money]], [[Notes#Heading]] and ![[diagram.png]]."
        #expect(NotesFormat.wikiLinks(t) == ["Plan", "Budget", "Notes", "diagram.png"])
    }

    @Test("Tags from YAML front matter and inline, without headings or numbers")
    func tags() {
        let t = "---\ntags: [alpha, \"beta\"]\n---\n# Heading\nText #gamma and #123 and issue#5 #delta/sub"
        #expect(NotesFormat.tags(t) == ["alpha", "beta", "gamma", "delta/sub"])
    }

    @Test("Notion ids are stripped and file links decoded")
    func notion() {
        #expect(NotesFormat.notionTitle("Plan 0f3a9c1b2d3e4f5a6b7c8d9e0f1a2b3c") == "Plan")
        #expect(NotesFormat.markdownFileLinks("[x](My%20Page%200f3a9c1b2d3e4f5a6b7c8d9e0f1a2b3c.md) [web](https://a.md)")
                == ["My Page 0f3a9c1b2d3e4f5a6b7c8d9e0f1a2b3c"])
        #expect(NotesFormat.key("My Page 0f3a9c1b2d3e4f5a6b7c8d9e0f1a2b3c") == "my page")
    }
}

// MARK: - W4-2 file types

@Suite("W4-2 Keynote, Messages, browser history")
struct ExtraParserPrimitiveTests {
    @Test("Snappy literals and overlapping copies decompress exactly")
    func snappy() throws {
        // "abcabcabc": varint 9, literal "abc" (tag (3-1)<<2), copy len 6 offset 3 (tag ((6-4)<<2)|1, offset byte 3).
        let block: [UInt8] = [9, 2 << 2] + Array("abc".utf8) + [((6 - 4) << 2) | 1, 3]
        #expect(String(decoding: try Snappy.decompress(block), as: UTF8.self) == "abcabcabc")
        #expect(throws: (any Error).self) { try Snappy.decompress([5, 0]) }
    }

    @Test("Text a person wrote is kept; style names are not")
    func isText() {
        #expect(IWAReader.isText("Quarterly results improved"))
        #expect(IWAReader.isText("Done."))
        #expect(!IWAReader.isText("HelveticaNeue"))
        #expect(!IWAReader.isText("12"))
    }

    @Test("attributedBody text is read without unarchiving any class")
    func typedStream() {
        var bytes: [UInt8] = [0x04, 0x0B] + Array("streamtyped".utf8) + [0x81, 0xE8, 0x03, 0x84, 0x01]
        bytes += Array("NSAttributedString".utf8) + [0x00, 0x84, 0x84] + Array("NSString".utf8)
        bytes += [0x01, 0x94, 0x84, 0x01, 0x2B]
        let msg = Array("See you at 5".utf8)
        bytes += [UInt8(msg.count)] + msg
        #expect(TypedStreamText.firstString(Data(bytes)) == "See you at 5")
        #expect(TypedStreamText.firstString(Data("not an archive at all".utf8)) == nil)
    }

    @Test("Chrome/WebKit microseconds since 1601 convert to the right instant")
    func webkitTime() {
        let d = SQLiteAdapterSupport.webkitDate(13_000_000_000_000_000)
        #expect(d == Date(timeIntervalSince1970: 1_355_526_400))
        #expect(SQLiteAdapterSupport.webkitDate(0) == nil)
    }
}

// MARK: - W4-4 team review

@Suite("W4-4 team review")
struct TeamCaseTests {
    @Test("Signed logs verify; a changed byte and a removed entry are reported at the exact entry")
    func verifyAndTamper() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let c = try TeamCase.create(at: dir, name: "Case")
        let key = Curve25519.Signing.PrivateKey()
        let me = try c.join(displayName: "Ann", key: key)
        _ = try c.append([("code", "h1", "a.pdf", "responsive"), ("code", "h2", "b.pdf", "privileged"),
                          ("code", "h3", "c.pdf", "hot")], member: me, key: key)
        #expect(c.verify() == [.ok(member: "Ann", entries: 3)])
        #expect(c.currentCodes()["h2"]?.value == "privileged")

        let log = dir.appendingPathComponent("log/\(me).jsonl")
        let original = try String(contentsOf: log, encoding: .utf8)
        try original.replacingOccurrences(of: "privileged", with: "responsive").write(to: log, atomically: true, encoding: .utf8)
        #expect(c.verify() == [.badSignature(member: "Ann", seq: 2)])

        var lines = original.split(separator: "\n").map(String.init)
        lines.remove(at: 1)
        try (lines.joined(separator: "\n") + "\n").write(to: log, atomically: true, encoding: .utf8)
        #expect(c.verify() == [.brokenChain(member: "Ann", seq: 3)])
    }

    @Test("A lease held by another member blocks; your own lease renews")
    func leases() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let c = try TeamCase.create(at: dir, name: "Case")
        #expect(try c.lease("h1", member: "a"))
        #expect(try !c.lease("h1", member: "b"))
        #expect(try c.lease("h1", member: "a"))
    }
}

// MARK: - W2-6 export

@Suite("W2-6 export formats")
struct LedgerExportTests {
    let table = LedgerExportTable(title: "T", columns: ["Name", "Note"],
                                  rows: [["Acme, Inc.", "said \"yes\"\nthen left"], ["B|C", "plain"]],
                                  sources: ["a.eml", "b.eml"], passages: ["p1", "p2"])

    @Test("CSV quotes commas, quotes and newlines")
    func csv() {
        let csv = LedgerExportRenderer.csv(table)
        #expect(csv.hasPrefix("Name,Note\r\n\"Acme, Inc.\",\"said \"\"yes\"\"\nthen left\"\r\n"))
    }

    @Test("JSON round-trips every row")
    func jsonRoundTrip() throws {
        let obj = try JSONSerialization.jsonObject(with: LedgerExportRenderer.json(table)) as? [String: Any]
        let rows = obj?["rows"] as? [[String: String]]
        #expect(rows?.count == 2)
        #expect(rows?[0]["Note"] == "said \"yes\"\nthen left")
    }

    @Test("Markdown escapes pipes; receipts carry one entry per row")
    func markdownAndReceipt() {
        #expect(LedgerExportRenderer.markdown(table).contains("| B\\|C | plain |"))
        let drafts = LedgerExportRenderer.receiptDrafts(table)
        #expect(drafts.map(\.source) == ["a.eml", "b.eml"])
        #expect(VerifiableReceipt.verify(VerifiableReceipt.seal(title: "x", drafts: drafts)))
    }
}

// MARK: - Module matrix, presets, tools menu

@Suite("Module presets and tools menu")
struct ModulePresetTests {
    @Test("Role presets switch on the role's tools and never a preview module")
    func presets() {
        let legal = ModulePreset.modules(forPersona: "legal")
        #expect(legal.contains(.legalProduction))
        #expect(legal.contains(.corroborationMeter))
        for id in ["legal", "investigation", "journalism", "research", "devonthink", "general"] {
            #expect(ModulePreset.modules(forPersona: id).allSatisfy { !$0.spec.preview && $0.spec.implemented })
        }
        #expect(ProductModule.teamReview.spec.preview)
        #expect(ProductModule.locationMap.spec.preview)
    }

    @Test("Every tool sits in exactly one Tools hub")
    @MainActor func hubsCoverTools() {
        let placed = ToolHub.allCases.flatMap(\.tools)
        #expect(placed.count == ToolSheet.allCases.count)
        #expect(Set(placed) == Set(ToolSheet.allCases))
    }
}

// MARK: - W0-1 scale run

@Suite("W0-1 scale-run summary")
struct ScaleRunSummaryTests {
    func samples(_ mib: [Double]) -> [ScaleSample] {
        mib.enumerated().map { i, m in
            ScaleSample(at: Date(timeIntervalSince1970: Double(i) * 600), footprint: UInt64(m * 1_048_576), documents: i * 100)
        }
    }

    @Test("A flat second half reads as flat; steady growth does not")
    func flatVersusGrowing() {
        #expect(ScaleRunSummary.text(samples([300, 400, 400, 401, 400, 400]), hardware: "x").contains("— flat"))
        #expect(ScaleRunSummary.text(samples([300, 400, 500, 600, 700, 800]), hardware: "x").contains("NOT flat"))
        #expect(ScaleRunSummary.text(samples([300]), hardware: "x").hasPrefix("Not enough samples"))
    }
}

// MARK: - N-7 similar images

@Suite("N-7 image grouping")
struct ImageGroupingTests {
    @Test("Union–find joins every pair under the threshold, transitively")
    func transitiveGroups() {
        let d: [Double] = [0, 0.1, 0.9, 0.95]
        let groups = ImageIntelligence.group(count: 4, threshold: 0.3) { i, j in abs(d[i] - d[j]) }
        #expect(Set(groups.map { Set($0) }) == [Set([0, 1]), Set([2, 3])])
    }
}

// MARK: - W4-2 7z and PowerPoint 97–2003

@Suite("W4-2 7z archives and legacy PowerPoint")
struct SevenZipAndPPTTests {
    private func fixture(_ name: String) throws -> Data {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Archives", isDirectory: true)
        return try Data(contentsOf: dir.appendingPathComponent(name))
    }

    private func expected() throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: fixture("expected.json"))
    }

    @Test("A 7-Zip-layout archive (LZMA2 data, LZMA-encoded header) lists and extracts every member exactly",
          arguments: ["sample-lzma2-encoded.7z", "sample-lzma-plain.7z"])
    func readsArchive(_ name: String) throws {
        let reader = try SevenZipReader(data: fixture(name), maxFolderBytes: 64 << 20)
        #expect(reader.entries.map(\.name) == ["docs", "docs/a.txt", "b.txt", "empty.txt"])
        #expect(reader.entries[0].isDirectory)
        #expect(!reader.entries[3].isDirectory && reader.entries[3].size == 0)
        let want = try expected()
        for e in reader.entries where !e.isDirectory {
            let bytes = try reader.extract(e)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            #expect(digest == want[e.name], "\(name): \(e.name)")
        }
    }

    @Test("A folder larger than the cap is refused, not decoded")
    func capRefused() throws {
        let data = try fixture("sample-lzma-plain.7z")       // plain header: the cap applies at extraction
        let reader = try SevenZipReader(data: data, maxFolderBytes: 100)
        #expect(throws: SevenZipError.tooLarge) { try reader.extract(reader.entries[1]) }
        // With an encoded header the header itself is a capped folder: refused while opening.
        #expect(throws: (any Error).self) { try SevenZipReader(data: try fixture("sample-lzma2-encoded.7z"), maxFolderBytes: 100) }
    }

    @Test("Not a 7z file is reported as such")
    func notSevenZip() {
        #expect(throws: SevenZipError.notSevenZip) { try SevenZipReader(data: Data("PK\u{3}\u{4}xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx".utf8), maxFolderBytes: 1 << 20) }
    }

    /// One PowerPoint record: 8-byte header (version/instance, type, length) + body.
    private func rec(_ verInst: UInt16, _ type: UInt16, _ body: [UInt8]) -> [UInt8] {
        var h: [UInt8] = [UInt8(verInst & 0xFF), UInt8(verInst >> 8), UInt8(type & 0xFF), UInt8(type >> 8)]
        let n = UInt32(body.count)
        h += [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8(n >> 24)]
        return h + body
    }

    @Test("PowerPoint text atoms come out per slide with titles, body and notes")
    func pptTextRuns() {
        func u32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
        let utf16 = Array("Quarterly review".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        let slideList = rec(0x000F, 0x0FF0,
            rec(0, 0x03F3, Array(repeating: 0, count: 20)) + rec(0, 0x0F9F, u32(0)) + rec(0, 0x0FA0, utf16)
          + rec(0, 0x0F9F, u32(1)) + rec(0, 0x0FA8, Array("Revenue grew\rCosts fell".utf8))
          + rec(0, 0x0FA8, Array("Revenue grew\rCosts fell".utf8))                     // duplicate kept once
          + rec(0, 0x03F3, Array(repeating: 0, count: 20)) + rec(0, 0x0F9F, u32(2)) + rec(0, 0x0FA8, Array("Speaker note".utf8)))
        let runs = PPTStructuralParser.textRuns(rec(0x000F, 0x03E8, slideList))
        #expect(runs == [.init(slide: 1, kind: 0, text: "Quarterly review"),
                         .init(slide: 1, kind: 1, text: "Revenue grew\nCosts fell"),
                         .init(slide: 2, kind: 2, text: "Speaker note")])
    }
}

@Suite("O-2 network helper")
struct NetworkHelperTests {
    @Test func helperIsEmbedded() {
        // The test host is the built app: the helper must be bundled under Contents/Extensions.
        #expect(ConnectivityMode.onlineAvailableInThisBuild)
    }

    @Test func refusesNonAllowlistedAndNonHTTPSDestinations() async {
        for url in ["https://example.com/v1/messages", "http://api.anthropic.com/v1/messages", "https://api.anthropic.com.evil.test/x"] {
            let req = OutboundHTTPRequest(url: url, headers: [:], body: Data())
            await #expect(throws: NetworkHelperError.self) { _ = try await NetworkHelperClient.send(req) }
        }
    }
}

@Suite("W3-1 DEVONthink package (simulated .dtBase2)")
struct DevonthinkPackageTests {
    /// Builds a package shaped like DEVONthink's: stored files under Files.noindex/<type>/<bucket>/,
    /// database metadata at the package root, a hidden file, and Finder tags on two files.
    private func makePackage() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("dt-\(UUID().uuidString)", isDirectory: true)
        let pkg = base.appendingPathComponent("Research.dtBase2", isDirectory: true)
        let fm = FileManager.default
        for meta in ["DEVONthink-1.dtMeta", "DEVONthink-2.dtMeta", "Properties.plist"] {
            try fm.createDirectory(at: pkg, withIntermediateDirectories: true)
            try Data("meta".utf8).write(to: pkg.appendingPathComponent(meta))
        }
        let stored: [(String, String, [String])] = [
            ("pdf/3", "Grant letter.pdf", ["patent", "2024"]),
            ("md/a", "Meeting notes.md", ["meeting"]),
            ("html/0", "Clipped page.html", []),
            ("txt/f", "plain.txt", []),
        ]
        for (dir, name, tags) in stored {
            let d = pkg.appendingPathComponent("Files.noindex/\(dir)", isDirectory: true)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            let u = d.appendingPathComponent(name)
            try Data("content of \(name)".utf8).write(to: u)
            if !tags.isEmpty { try (u as NSURL).setResourceValue(tags, forKey: .tagNamesKey) }
        }
        try Data().write(to: pkg.appendingPathComponent("Files.noindex/pdf/.DS_Store"))
        return pkg
    }

    @Test func opensOnlyStoredFilesNotMetadataOrHidden() throws {
        let pkg = try makePackage()
        defer { try? FileManager.default.removeItem(at: pkg.deletingLastPathComponent()) }
        let p = try #require(DevonthinkPackage.open(pkg))
        #expect(Set(p.files.map(\.lastPathComponent)) == ["Grant letter.pdf", "Meeting notes.md", "Clipped page.html", "plain.txt"])
    }

    @Test func rejectsNonPackages() throws {
        let pkg = try makePackage()
        defer { try? FileManager.default.removeItem(at: pkg.deletingLastPathComponent()) }
        #expect(DevonthinkPackage.open(pkg.deletingLastPathComponent()) == nil)          // wrong extension
        let noFiles = pkg.deletingLastPathComponent().appendingPathComponent("Empty.dtBase2", isDirectory: true)
        try FileManager.default.createDirectory(at: noFiles, withIntermediateDirectories: true)
        #expect(DevonthinkPackage.open(noFiles) == nil)                                  // no Files.noindex
    }

    @Test func readsFinderTags() throws {
        let pkg = try makePackage()
        defer { try? FileManager.default.removeItem(at: pkg.deletingLastPathComponent()) }
        let p = try #require(DevonthinkPackage.open(pkg))
        let byName = Dictionary(uniqueKeysWithValues: p.files.map { ($0.lastPathComponent, Set(DevonthinkPackage.finderTags($0))) })
        #expect(byName["Grant letter.pdf"] == ["patent", "2024"])
        #expect(byName["Meeting notes.md"] == ["meeting"])
        #expect(byName["plain.txt"] == [])
    }

    @Test func accountingNamesWhatIsNotYetRead() throws {
        let pkg = try makePackage()
        defer { try? FileManager.default.removeItem(at: pkg.deletingLastPathComponent()) }
        let p = try #require(DevonthinkPackage.open(pkg))
        let read = Set(p.files.filter { $0.pathExtension != "txt" && $0.pathExtension != "html" }.map { $0.standardizedFileURL.path })
        let a = p.accounting(ledgerPaths: read.union(["/elsewhere/other.pdf"]))
        #expect(a == .init(total: 4, inLedger: 2, missing: ["Clipped page.html", "plain.txt"]))
        #expect(a.summary.hasPrefix("2 of 4 stored documents are in the ledger. Not yet read (2): Clipped page.html, plain.txt"))
        let all = p.accounting(ledgerPaths: Set(p.files.map { $0.standardizedFileURL.path }))
        #expect(all.summary == "All 4 stored documents are in the ledger.")
    }
}

@Suite("W3-6 Share inbox and Services capture")
struct ShareCaptureTests {
    /// Writes one item exactly as KalsmritikoshShare does: <stamp>-<uuid>/<name> + item.json.
    private func shareItem(_ inbox: URL, name: String, data: Data, recordedSHA: String? = nil) throws -> URL {
        let dir = inbox.appendingPathComponent("2026-10-15T10-00-00Z-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(name))
        let meta = ["sharedAt": "2026-10-15T10:00:00Z", "origin": "Share menu: Safari", "name": name, "kind": "file",
                    "sha256": recordedSHA ?? CaptureIntake.sha256(data), "bytes": String(data.count)]
        try JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent(ShareInbox.itemFile))
        return dir
    }

    private func tempInbox() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("inbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test func verifiedItemsMoveWithCustodyAndTamperedOnesStay() throws {
        let inbox = try tempInbox()
        defer { try? FileManager.default.removeItem(at: inbox) }
        let good = try shareItem(inbox, name: "Grant letter.pdf", data: Data("pdf bytes".utf8))
        let tampered = try shareItem(inbox, name: "notes.txt", data: Data("changed".utf8), recordedSHA: CaptureIntake.sha256(Data("original".utf8)))
        let noRecord = inbox.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: noRecord, withIntermediateDirectories: true)
        let staging = inbox.appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: true)   // half-written
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        var saves: [(String, String)] = []
        let r = ShareInbox.drain(inbox) { data, name, origin in
            saves.append((name, origin))
            return CaptureIntake.Saved(file: inbox.appendingPathComponent(name), sha256: CaptureIntake.sha256(data))
        }
        #expect(r.moved == 1)
        #expect(saves.map(\.0) == ["Grant letter.pdf"])
        #expect(saves[0].1.contains("Share menu: Safari") && saves[0].1.contains("shared 2026-10-15T10:00:00Z"))
        #expect(!FileManager.default.fileExists(atPath: good.path))          // handed over
        #expect(FileManager.default.fileExists(atPath: tampered.path))       // kept, not imported
        #expect(FileManager.default.fileExists(atPath: noRecord.path))
        #expect(FileManager.default.fileExists(atPath: staging.path))        // never touched
        #expect(r.refused.count == 2)
        #expect(r.refused.contains { $0.contains("do not match") })
    }

    @Test func inboxCopyStaysWhenTheIntakeCopyDoesNotVerify() throws {
        let inbox = try tempInbox()
        defer { try? FileManager.default.removeItem(at: inbox) }
        let item = try shareItem(inbox, name: "a.txt", data: Data("a".utf8))
        let r = ShareInbox.drain(inbox) { _, name, _ in CaptureIntake.Saved(file: inbox.appendingPathComponent(name), sha256: "bad") }
        #expect(r.moved == 0)
        #expect(FileManager.default.fileExists(atPath: item.path))
    }

    @Test func servicesPasteboardPrefersFilesThenRichestText() throws {
        let pb = NSPasteboard(name: NSPasteboard.Name("kals-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("plain words", forType: .string)
        pb.setData(Data("<p>rich <b>words</b></p>".utf8), forType: .html)
        let textItems = CapturePasteboard.items(from: pb)
        #expect(textItems.count == 1)
        #expect(textItems[0].name.hasSuffix(".html"))
        #expect(textItems[0].data == Data("<p>rich <b>words</b></p>".utf8))

        pb.clearContents()
        let file = URL(fileURLWithPath: "/tmp/does-not-matter.pdf")
        pb.writeObjects([file as NSURL])
        let fileItems = CapturePasteboard.items(from: pb) { _ in Data("file bytes".utf8) }
        #expect(fileItems == [.init(data: Data("file bytes".utf8), name: "does-not-matter.pdf", origin: "Services menu: /tmp/does-not-matter.pdf")])

        pb.clearContents()
        pb.setString("   \n", forType: .string)
        #expect(CapturePasteboard.items(from: pb).isEmpty)
    }
}

@Suite("W4-6 backup names never collide with control files")
struct BackupReservedNameTests {
    @Test func originalsNamedLikeControlFilesOrDifferingByCaseStayDistinct() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("bkres-\(UUID().uuidString)", isDirectory: true)
        let src = base.appendingPathComponent("src", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        var originals: [URL] = []
        for (i, name) in ["manifest.json", "signature.json", "Letter.txt"].enumerated() {
            let d = src.appendingPathComponent("d\(i)", isDirectory: true)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            let u = d.appendingPathComponent(name)
            try Data("original \(name)".utf8).write(to: u)
            originals.append(u)
        }
        let lower = src.appendingPathComponent("d9", isDirectory: true)
        try fm.createDirectory(at: lower, withIntermediateDirectories: true)
        try Data("lowercase twin".utf8).write(to: lower.appendingPathComponent("letter.txt"))
        originals.append(lower.appendingPathComponent("letter.txt"))
        let db = src.appendingPathComponent("ledger.sqlite")
        try Data("SQLite format 3\0".utf8).write(to: db)

        let dest = base.appendingPathComponent("backup", isDirectory: true)
        let m = try BackupService().createBackup(databaseURL: db, originalURLs: originals, destination: dest,
                                                 schemaVersion: 1, nowEpoch: 0)
        let paths = m.entries.map(\.relativePath)
        #expect(Set(paths.map { $0.lowercased() }).count == paths.count)
        #expect(!paths.contains { BackupService.reservedNames.contains($0.lowercased()) })
        // The manifest on disk is the manifest, not the original that shares its name.
        let onDisk = try JSONDecoder().decode(BackupManifest.self, from: Data(contentsOf: dest.appendingPathComponent(BackupService.manifestName)))
        #expect(onDisk == m)
        let verdict = try BackupService().inspect(backupFolder: dest).verdict
        #expect(verdict.corrupt.isEmpty && verdict.missing.isEmpty)
    }
}

/// W4-6 — the iPhone/iPad viewer's own reader (KalsmritikoshViewer/SnapshotVerifier.swift and
/// SnapshotLedger.swift, compiled into this test target too) against a snapshot the Mac app
/// really exports: real ingest, real export, real signature.
@Suite("W4-6 viewer reads a real signed snapshot", .serialized)
struct CompanionViewerRoundTripTests {
    static let passphrase = "correct horse battery"
    @MainActor
    private func exportSnapshot() async throws -> (snapshot: URL, cleanup: () async -> Void) {
        let (state, dir) = try await RealArchivePipelineTests.bootState(label: "viewer")
        let docs = dir.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let note = docs.appendingPathComponent("Patent grant notice.txt")
        try Data("""
            Patent grant notice.
            The patent office granted patent 11,223,344 to Ecosanskriti Innovation on 4 March 2024.
            The examiner was Dr. Meera Iyer. Renewal fees fall due every year in March.
            """.utf8).write(to: note)
        await state.ingestFiles([note])
        let out = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        _ = try await state.exportCompanionSnapshot(to: out, includeOriginals: true, passphrase: Self.passphrase)
        let snap = try #require(try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "kalsnapshot" })
        return (snap, { await RealArchivePipelineTests.teardown(state, dir) })
    }

    @Test(.timeLimit(.minutes(5)))
    func viewerVerifiesBrowsesSearchesAndOpensTheOriginal() async throws {
        let (snap, cleanup) = try await exportSnapshot()
        let (verdict, entries) = SnapshotVerifier.verify(snap)
        #expect(verdict.isVerified, "\(verdict.message)")
        // W2-7 — the snapshot's ledger is encrypted with the export passphrase, not the Mac's key.
        let db = try #require(entries.first { $0.kind == "database" })
        #expect(LedgerFileState.of(snap.appendingPathComponent(db.relativePath)) == .encrypted)
        #expect(throws: SnapshotLedger.OpenError.wrongPassphrase) {
            _ = try SnapshotLedger(folder: snap, entries: entries, passphrase: "not the passphrase")
        }
        let ledger = try SnapshotLedger(folder: snap, entries: entries, passphrase: Self.passphrase)
        let docs = ledger.documents()
        let doc = try #require(docs.first { $0.title == "Patent grant notice.txt" }, "documents: \(docs.map(\.title))")
        #expect(!ledger.passages(of: doc.id).isEmpty)
        let hits = ledger.search("examiner Iyer")
        #expect(hits.contains { $0.documentID == doc.id && $0.text.contains("Meera Iyer") })
        // The citation opens its source: the snapshot's own copy of the original, byte for byte.
        let original = try #require(ledger.originalURL(fileID: doc.fileID))
        #expect(try Data(contentsOf: original) == Data(contentsOf: snap.deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/Patent grant notice.txt")))
        await cleanup()
    }

    @Test(.timeLimit(.minutes(5)))
    func oneChangedByteOrAMissingSignatureIsRefused() async throws {
        let (snap, cleanup) = try await exportSnapshot()
        let (_, entries) = SnapshotVerifier.verify(snap)
        let original = try #require(entries.first { $0.kind == "originalSource" && $0.relativePath.hasSuffix(".txt") })
        let url = snap.appendingPathComponent(original.relativePath)
        var bytes = try Data(contentsOf: url)
        bytes[0] ^= 0x01
        try bytes.write(to: url)
        if case .damaged = SnapshotVerifier.verify(snap).0 {} else { Issue.record("a changed original byte was not detected") }

        var manifest = try Data(contentsOf: snap.appendingPathComponent(SnapshotVerifier.manifestName))
        manifest[manifest.count / 2] ^= 0x01
        try manifest.write(to: snap.appendingPathComponent(SnapshotVerifier.manifestName))
        #expect(SnapshotVerifier.verify(snap).0 == .badSignature)

        try FileManager.default.removeItem(at: snap.appendingPathComponent(SnapshotVerifier.signatureName))
        #expect(SnapshotVerifier.verify(snap).0 == .unsigned)
        await cleanup()
    }

    @Test func ftsQueryQuotesEveryWord() {
        #expect(SnapshotLedger.ftsQuery(#"patent "grant" OR"#) == #""patent" """grant""" "OR""#)
        #expect(SnapshotLedger.ftsQuery("   ").isEmpty)
    }
}
