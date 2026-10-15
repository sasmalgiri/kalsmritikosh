//
//  BeatDevonthinkPlanTests.swift
//  KalsmritikoshTests
//
//  Final test phase for the beat-DEVONthink plan: each test checks one item's
//  "Done means" at the level that can be verified without owner hardware.
//

import Foundation
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
