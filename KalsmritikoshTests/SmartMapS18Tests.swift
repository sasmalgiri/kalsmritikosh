//
//  SmartMapS18Tests.swift
//  KalsmritikoshTests
//
//  Smart-map slice S18 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md §05 SRC, §24 SEC, §28 QA):
//  - SRC-01: a spreadsheet citation opens the cited version at its sheet / row / cell; a slide citation at its slide;
//  - SEC-06: the case-slice and issue-chronology saves are checked again AT WRITE;
//  - SEC-07: the sync side tables and this Mac's batches in the sync folder keep nothing an erasure removed; the full
//    erase empties every table (the old unescaped LIKE skipped names holding "fts");
//  - SEC-10: seeded fuzzing of the PDF, Office (ZIP), image and audio readers, bounded in time;
//  - QA-14: the test host's user-data folders are its own; tests never boot the owner's ledger; skipped or stale
//    result bundles are not fresh passes.
//  Synthetic data only; no network, no model. No calendar dates are computed (time-zone free).
//

import AppKit
import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import Testing
@testable import Kalsmritikosh

private struct S18Random {
    var state: UInt64
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state >> 11 }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
}

private func s18Scratch(_ tag: String) throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("s18-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func s18Count(_ db: Database, _ sql: String, _ b: [SQLValue] = []) async throws -> Int {
    Int(try await db.query(sql, b).first?.int(0) ?? -1)
}

/// A workbook with two sheets; "Payments" has a header and three rows (row index 0–3), the paid-twice cell is C3.
func s18Workbook() -> Data {
    var z = ZIPArchiveWriter()
    z.addFile(path: "xl/workbook.xml", text: """
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\
    <sheet name="Summary" sheetId="1" r:id="rId1"/><sheet name="Payments" sheetId="2" r:id="rId2"/></sheets></workbook>
    """)
    z.addFile(path: "xl/_rels/workbook.xml.rels", text: """
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>\
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/></Relationships>
    """)
    z.addFile(path: "xl/worksheets/sheet1.xml", text: """
    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\
    <row r="1"><c r="A1" t="inlineStr"><is><t>Total</t></is></c><c r="B1"><v>20000</v></c></row></sheetData></worksheet>
    """)
    z.addFile(path: "xl/worksheets/sheet2.xml", text: """
    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\
    <row r="1"><c r="A1" t="inlineStr"><is><t>Date</t></is></c><c r="B1" t="inlineStr"><is><t>Payee</t></is></c><c r="C1" t="inlineStr"><is><t>Amount</t></is></c></row>\
    <row r="2"><c r="A2" t="inlineStr"><is><t>5 March</t></is></c><c r="B2" t="inlineStr"><is><t>Dalmia Traders</t></is></c><c r="C2"><v>10000</v></c></row>\
    <row r="3"><c r="A3" t="inlineStr"><is><t>9 March</t></is></c><c r="B3" t="inlineStr"><is><t>Dalmia Traders</t></is></c><c r="C3" t="inlineStr"><is><t>10000 (second)</t></is></c></row>\
    <row r="4"><c r="A4" t="inlineStr"><is><t>12 March</t></is></c><c r="B4" t="inlineStr"><is><t>Office rent</t></is></c><c r="C4"><v>4000</v></c></row>\
    </sheetData></worksheet>
    """)
    return z.build()
}

/// A presentation of three slides; slide 2 has a title, a body line and speaker notes.
func s18Deck() -> Data {
    func slide(_ title: String, _ body: String) -> String {
        """
        <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><p:cSld><p:spTree>\
        <p:sp><p:nvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>\(title)</a:t></a:r></a:p></p:txBody></p:sp>\
        <p:sp><p:txBody><a:p><a:r><a:t>\(body)</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>
        """
    }
    var z = ZIPArchiveWriter()
    z.addFile(path: "ppt/slides/slide1.xml", text: slide("Overview", "Two payments in March"))
    z.addFile(path: "ppt/slides/slide2.xml", text: slide("The second transfer", "Approved by the treasurer on 9 March"))
    z.addFile(path: "ppt/slides/slide3.xml", text: slide("Next steps", "Ask the bank for both slips"))
    z.addFile(path: "ppt/notesSlides/notesSlide2.xml", text: """
    <p:notes xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><p:cSld><p:spTree>\
    <p:sp><p:txBody><a:p><a:r><a:t>Check the approval minute</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:notes>
    """)
    return z.build()
}

/// One simulated device for the sync tests (its own ledger, notes and intake; the shared folder store).
private struct S18Device {
    let dir: URL
    let db: Database
    let engine: SyncEngine
    static func make(_ name: String, store: SyncStore, key: Curve25519.Signing.PrivateKey = Curve25519.Signing.PrivateKey()) async throws -> S18Device {
        let dir = try ParityFixture.tempFolder("s18-dev-\(name)")
        let db = try await ParityFixture.database(in: dir)
        let intake = dir.appendingPathComponent("Intake", isDirectory: true)
        try FileManager.default.createDirectory(at: intake, withIntermediateDirectories: true)
        let engine = SyncEngine(database: db, store: store, deviceID: "device-\(name)", deviceName: name, signingKey: key,
                                notes: NotesStore(base: dir), intakeFolder: intake,
                                saveIntake: { data, fileName, _ in
                                    let target = intake.appendingPathComponent("\(UUID().uuidString)-\(fileName)")
                                    try data.write(to: target)
                                    return CaptureIntake.Saved(file: target, sha256: SyncCrypto.sha256Hex(data))
                                })
        return S18Device(dir: dir, db: db, engine: engine)
    }
}

@Suite("Smart map S18 — locators, write-time checks, erasure reach, fuzzing, test isolation", .serialized)
struct SmartMapS18Tests {

    // MARK: SRC-01 — spreadsheet and slide locators

    @Test("SRC-01: a cell citation in a workbook opens the cited version at its sheet, row and cell; a CSV row and an ODS sheet too; a slide citation opens that slide; a place missing from the file is said")
    func sheetCellAndSlidePlaces() async throws {
        let f = try await CitedSourceResolverTests.fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        // The workbook on disk IS the cited version (its hash): the resolver opens it, and the place is the cell.
        let book = f.dir.appendingPathComponent("payments.xlsx")
        let bytes = s18Workbook()
        try bytes.write(to: book)
        let v = try await CitedSourceResolverTests.version(f, logical: UUID(), bytes: bytes, current: true, url: book)
        #expect(try await CitedSourceResolver.resolve(sourceVersionID: v, objectID: nil, database: f.db, ledgerURL: f.ledger) == .open(book, note: nil))
        // The locator as the XLSX reader records it (row 0-based) plus the cell's column, as a citation stores it.
        let cell = SourceLocator(row: 2, column: "C", sheet: "Payments")
        let place = try #require(CitedSourceResolver.showablePlace(cell, fileExtension: book.pathExtension))
        #expect(place == .sheetCell(sheet: "Payments", row: 2, column: "C", cellRange: nil))
        #expect(CitedSourceResolver.unsupportedLocatorNote(cell, fileExtension: "xlsx") == nil, "the place is shown, so it is not 'not shown'")
        guard case .sheet(let sheet) = await CitedPlaceReader.read(url: book, place: place) else { Issue.record("not opened at the sheet"); return }
        #expect(sheet.sheet == "Payments" && sheet.sheetNames == ["Summary", "Payments"])
        #expect(sheet.selectedRow == 2 && sheet.selectedColumn == 2 && sheet.selectedValue == "10000 (second)", "\(String(describing: sheet.selectedValue))")
        #expect(sheet.totalRows == 4 && sheet.rows.contains { $0.index == 2 && $0.cells[1] == "Dalmia Traders" })
        // An A1 range opens at its first cell; a row-only citation selects the row.
        guard case .sheet(let ranged) = await CitedPlaceReader.read(url: book, place: .sheetCell(sheet: "Payments", row: nil, column: nil, cellRange: "$B$4:C4")) else {
            Issue.record("range not opened"); return
        }
        #expect(ranged.selectedRow == 3 && ranged.selectedColumn == 1 && ranged.selectedValue == "Office rent")
        guard case .sheet(let rowOnly) = await CitedPlaceReader.read(url: book, place: .sheetCell(sheet: "Payments", row: 1, column: nil, cellRange: nil)) else {
            Issue.record("row not opened"); return
        }
        #expect(rowOnly.selectedRow == 1 && rowOnly.selectedColumn == nil && rowOnly.selectedValue == nil)
        // A sheet or row this version does not have is said — never another place.
        guard case .missing(let noSheet) = await CitedPlaceReader.read(url: book, place: .sheetCell(sheet: "Ledger", row: 1, column: nil, cellRange: nil)) else {
            Issue.record("a missing sheet was replaced"); return
        }
        #expect(noSheet.contains("“Ledger”") && noSheet.contains("not in this version"))
        guard case .missing(let noRow) = await CitedPlaceReader.read(url: book, place: .sheetCell(sheet: "Payments", row: 40, column: "A", cellRange: nil)) else {
            Issue.record("a missing row was replaced"); return
        }
        #expect(noRow.contains("row 41"))
        // The file changed on disk since it was cited: the resolver refuses it, so no sheet of the wrong bytes is shown.
        var changed = bytes; changed.append(0x00)
        try changed.write(to: book)
        #expect(try await CitedSourceResolver.resolve(sourceVersionID: v, objectID: nil, database: f.db, ledgerURL: f.ledger) == .unavailable(.changedOnDisk))

        // A superseded version opens its KEPT copy (the vault, named with its extension) at the cited cell.
        let logical = UUID()
        let vault = EvidenceVault(root: f.dir.appendingPathComponent("EvidenceVault", isDirectory: true))
        let address = try await vault.store(bytes)
        let old = UUID()
        try await f.db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, original_url, created_at, filename, custody_mode,
                                         preservation_status, vault_address)
            VALUES (?,?,?,?,0,?,?,?,'managed','managedCopyStored',?);
            """, [.uuid(old), .uuid(logical), .text(CitedSourceResolverTests.hash(bytes)), .real(1), .text(book.absoluteString), .real(1), .text("payments.xlsx"),
                  .text(address)])
        guard case .open(let kept, let note) = try await CitedSourceResolver.resolve(sourceVersionID: old, objectID: nil, database: f.db, ledgerURL: f.ledger, vault: vault) else {
            Issue.record("the kept copy did not open"); return
        }
        #expect(note == CitedSourceResolver.newerVersionNote && kept.pathExtension == "xlsx")
        guard case .sheet(let fromKept) = await CitedPlaceReader.read(url: kept, place: place) else { Issue.record("kept copy not read"); return }
        #expect(fromKept.selectedValue == "10000 (second)")

        // A CSV row (the CSV reader names its one sheet after the file) and an ODS sheet.
        let csv = f.dir.appendingPathComponent("ledger.csv")
        try Data("Date,Payee,Amount\n5 March,Dalmia,10000\n9 March,Dalmia,10000\n".utf8).write(to: csv)
        let csvPlace = try #require(CitedSourceResolver.showablePlace(SourceLocator(row: 2, sheet: "ledger"), fileExtension: "csv"))
        guard case .sheet(let csvSheet) = await CitedPlaceReader.read(url: csv, place: csvPlace) else { Issue.record("csv not opened"); return }
        #expect(csvSheet.selectedRow == 2 && csvSheet.rows.first { $0.index == 2 }?.cells.first == "9 March")
        var ods = ZIPArchiveWriter()
        ods.addFile(path: "content.xml", text: """
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" \
        xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"><office:body><office:spreadsheet><table:table table:name="Cash">\
        <table:table-row><table:table-cell><text:p>Opening</text:p></table:table-cell><table:table-cell><text:p>500</text:p></table:table-cell></table:table-row>\
        <table:table-row><table:table-cell><text:p>Closing</text:p></table:table-cell><table:table-cell><text:p>120</text:p></table:table-cell></table:table-row>\
        </table:table></office:spreadsheet></office:body></office:document-content>
        """)
        let odsURL = f.dir.appendingPathComponent("cash.ods")
        try ods.build().write(to: odsURL)
        guard case .sheet(let odsSheet) = await CitedPlaceReader.read(url: odsURL, place: .sheetCell(sheet: "Cash", row: 1, column: "B", cellRange: nil)) else {
            Issue.record("ods not opened"); return
        }
        #expect(odsSheet.selectedValue == "120")

        // A slide: the cited slide (1-based) with its title, body and notes; a slide the deck lacks is said.
        let deckURL = f.dir.appendingPathComponent("briefing.pptx")
        try s18Deck().write(to: deckURL)
        let slidePlace = try #require(CitedSourceResolver.showablePlace(SourceLocator(slide: 2, shape: "shape2"), fileExtension: "pptx"))
        #expect(slidePlace == .slide(2))
        guard case .slide(let s) = await CitedPlaceReader.read(url: deckURL, place: slidePlace) else { Issue.record("slide not opened"); return }
        #expect(s.number == 2 && s.count == 3 && s.title == "The second transfer" && s.body == ["Approved by the treasurer on 9 March"] && s.notes == "Check the approval minute")
        guard case .missing(let noSlide) = await CitedPlaceReader.read(url: deckURL, place: .slide(9)) else { Issue.record("missing slide replaced"); return }
        #expect(noSlide.contains("slide 9") && noSlide.contains("it has 3"))
        // Formats the viewer does not read still name the place (a Keynote slide, a Numbers cell, a database row).
        #expect(CitedSourceResolver.showablePlace(SourceLocator(slide: 2), fileExtension: "key") == nil)
        #expect(CitedSourceResolver.unsupportedLocatorNote(SourceLocator(databaseRowKey: "7"), fileExtension: "sqlite")?.contains("database row 7") == true)
        // The caption names the cell in A1 form (row 0-based in the locator → spreadsheet row 3).
        #expect(CitedPlaceReader.cellReference("C3") == (row: 2, column: 2) && CitedPlaceReader.cellReference("AA10") == (row: 9, column: 26))
    }

    // MARK: SEC-06 — a second check at write

    @Test("SEC-06: a source protected while the save window is open stops the issue chronology (replaced) and the signed case slice (refused); an unreadable register writes nothing")
    func secondCheckAtWrite() async throws {
        let dir = try s18Scratch("save")
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = "## Chronology\n- 3 March: Meera Iyer told the auditor about the second transfer.\n"
        // Checked before the panel with no protected names; Meera is protected while the panel is open.
        let chronology = dir.appendingPathComponent("chronology.md")
        let written = await ProtectedExport.writeRechecked(text, to: chronology, refuseIfPresent: false, names: { ["Meera Iyer"] })
        guard case .success(let out) = written else { Issue.record("not written: \(written)"); return }
        let onDisk = try String(contentsOf: chronology, encoding: .utf8)
        #expect(onDisk == out && !onDisk.contains("Meera Iyer") && onDisk.contains("second transfer"), "\(onDisk)")
        // A signed slice cannot be altered: refused, and no file appears.
        let slice = dir.appendingPathComponent("slice.json")
        let refused = await ProtectedExport.writeRechecked("{\"passages\":[\"Meera Iyer told the auditor\"]}", to: slice, refuseIfPresent: true, names: { ["Meera Iyer"] })
        guard case .failure(let why) = refused else { Issue.record("a sealed file with a protected name was written"); return }
        #expect(why.reason.contains("marked protected while the save window was open") && !FileManager.default.fileExists(atPath: slice.path))
        // The register cannot be read at write: nothing is written (fail closed).
        struct Unreadable: Error {}
        let unread = dir.appendingPathComponent("unread.md")
        let failed = await ProtectedExport.writeRechecked(text, to: unread, refuseIfPresent: false, names: { throw Unreadable() })
        guard case .failure(let r) = failed else { Issue.record("written without a readable register"); return }
        #expect(r.reason.contains("could not be read") && !FileManager.default.fileExists(atPath: unread.path))
        // No protected names: written as is.
        let plain = dir.appendingPathComponent("plain.md")
        #expect(await ProtectedExport.writeRechecked(text, to: plain, refuseIfPresent: true, names: { [] }) == .success(text))
        // Both save panels write through the re-check (source check: no direct write of the prepared text remains).
        let root = SmartMapS9Tests.repoRoot
        for file in ["Kalsmritikosh/UI/IssueChronologyView.swift", "Kalsmritikosh/UI/CaseSliceView.swift"] {
            let src = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            #expect(src.contains("ProtectedExport.writeRechecked") && src.contains("protectedNamesNow()"), "\(file)")
            #expect(!src.contains(".write(to: url, options: .atomic)"), "\(file) still writes without the second check")
        }
    }

    // MARK: SEC-07 — sync side tables, this Mac's batches, the full erase

    @Test("SEC-07: a person erasure clears every synced value, conflict and waiting change naming them; a removed row keeps its clock but no value")
    func syncSideTablesScrubbed() async throws {
        let f = try await CaseFileTests.fixture()
        let db = f.db
        let entity = UUID()
        let object = try await CaseFileTestSources.seedPassage(db, cases: f.cases, caseID: f.caseID, name: "note.txt", text: "Meera Iyer was called.").object
        try await db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence, attributes_json, quality_tier) VALUES (?, 'person', 'Meera Iyer', 'meera iyer', ?, 0.9, '{}', 'T2');",
                          [.uuid(entity), .uuid(object)])
        try await db.exec("INSERT INTO sync_field_clocks (tbl, row_key, field, lamport, device, synced_value) VALUES ('annotations', 'a1', 'note', 3, 'me', '\"t:Ask Meera Iyer again\"');", [])
        try await db.exec("INSERT INTO sync_field_clocks (tbl, row_key, field, lamport, device, synced_value) VALUES ('annotations', 'a2', 'note', 3, 'me', '\"t:Unrelated\"');", [])
        try await db.exec("INSERT INTO sync_field_clocks (tbl, row_key, field, lamport, device, synced_value) VALUES ('pdf_marks', 'gone-row', 'contents', 4, 'me', '\"t:Struck from the ledger\"');", [])
        try await db.exec("INSERT INTO sync_conflicts (id, tbl, row_key, field, kept_value, other_value, other_device, detected_at) VALUES ('c1', 'annotations', 'a1', 'note', 'Meera Iyer', 'M. Iyer', 'other', 1);", [])
        try await db.exec("INSERT INTO sync_conflicts (id, tbl, row_key, field, kept_value, other_value, other_device, detected_at) VALUES ('c2', 'annotations', 'a2', 'note', 'x', 'y', 'other', 1);", [])
        try await db.exec("INSERT INTO sync_pending (id, op_json, reason, first_seen) VALUES ('p1', '{\"fields\":{\"note\":\"meera iyer called\"}}', 'document not here', 1);", [])
        try await db.exec("INSERT INTO sync_pending (id, op_json, reason, first_seen) VALUES ('p2', '{\"fields\":{\"note\":\"rent\"}}', 'document not here', 1);", [])
        // A row an earlier erasure removed (its tombstone): its clock stays, its value goes.
        try await db.exec("INSERT INTO erasure_tombstones (generation, tbl, row_key, recorded_at) VALUES (1, 'pdf_marks', 'gone-row', 1);", [])
        let report = try await CaseEraser(database: db).erasePerson(entityID: entity, reason: "Subject request", legalBasis: nil, actor: "Ada")
        #expect(report.refused == nil, "\(report.refused ?? "")")
        #expect((report.rowsErased["sync side tables"] ?? 0) >= 4, "\(report.rowsErased)")
        #expect(try await s18Count(db, "SELECT COUNT(*) FROM sync_field_clocks WHERE row_key = 'a1' AND synced_value IS NULL;") == 1)
        #expect(try await s18Count(db, "SELECT COUNT(*) FROM sync_field_clocks WHERE row_key = 'a2' AND synced_value IS NOT NULL;") == 1, "unrelated values stay")
        #expect(try await s18Count(db, "SELECT COUNT(*) FROM sync_field_clocks WHERE row_key = 'gone-row' AND synced_value IS NULL AND lamport = 4;") == 1,
                "the erased row keeps its clock (an older copy still loses) and no value")
        let conflictsLeft = try await s18Count(db, "SELECT COUNT(*) FROM sync_conflicts;")
        let c2Left = try await s18Count(db, "SELECT COUNT(*) FROM sync_conflicts WHERE id = 'c2';")
        #expect(conflictsLeft == 1 && c2Left == 1)
        let pendingLeft = try await s18Count(db, "SELECT COUNT(*) FROM sync_pending;")
        let p2Left = try await s18Count(db, "SELECT COUNT(*) FROM sync_pending WHERE id = 'p2';")
        #expect(pendingLeft == 1 && p2Left == 1)
        // Nothing left names the person in any sync side table.
        let left = try await db.query("SELECT coalesce(synced_value,'') FROM sync_field_clocks UNION ALL SELECT coalesce(kept_value,'') || coalesce(other_value,'') FROM sync_conflicts UNION ALL SELECT op_json FROM sync_pending;", [])
        #expect(!left.contains { CaseEraser.names($0.string(0), ["Meera Iyer"]) })
    }

    @Test("SEC-07: a row an erasure removed leaves this Mac's batches in the sync folder (re-sealed, re-signed); a device that had not read them never receives it")
    func ownBatchesRedacted() async throws {
        let root = try ParityFixture.tempFolder("s18-sync")
        let store = try SyncStore.create(at: root, passphrase: "pass", rounds: 1_000)
        let a = try await S18Device.make("A", store: store)
        defer { for u in [root, a.dir] { try? FileManager.default.removeItem(at: u) } }
        let text = "Lease between Ada and Bo.\n\nRent is monthly."
        let doc = try await ParityFixture.document(a.db, name: "lease.txt", text: text, fileHash: "filehash-s18").id
        let notes = AnnotationsRepository(database: a.db)
        let keep = try await notes.add(objectID: doc, sourceURL: nil, quote: "Rent is monthly", note: "due 1st")
        let gone = try await notes.add(objectID: doc, sourceURL: nil, quote: "Lease between Ada and Bo", note: "Informant: Meera Iyer")
        let sent = try await a.engine.sync()
        #expect(sent.batchesWritten == 1)
        func ownOps() throws -> [SyncOp] {
            try store.batchNumbers(of: "device-A").flatMap { try store.readBatch(device: "device-A", seq: $0).ops }
        }
        #expect(try ownOps().contains { $0.table == "annotations" && $0.key.lowercased() == gone.uuidString.lowercased() })
        // The annotation is removed by an erasure (its tombstone is written by the v185 triggers while a generation runs).
        let erasure = UUID()
        try await a.db.withSavepoint("s18_erase") { db in
            _ = try ErasureGenerations.begin(db, kind: "person", scopeHash: ErasureGenerations.scopeHash(erasure), erasureID: erasure, at: Date())
            try db.exec("DELETE FROM annotations WHERE id = ?;", [.uuid(gone)])
            _ = try CaseEraser.scrubSyncSideTables(db, tables: Set(try CaseEraser.userTables(db)), terms: ["Meera Iyer"])
            try ErasureGenerations.finish(db, erasureID: erasure)
        }
        #expect(try await s18Count(a.db, "SELECT COUNT(*) FROM erasure_tombstones WHERE tbl = 'annotations';") == 1)
        let next = try await a.engine.sync()
        #expect(next.batchesRedacted == 1, "\(next)")
        let ops = try ownOps()
        #expect(!ops.contains { $0.table == "annotations" && $0.fields.values.contains { $0.display.contains("Meera") } }, "the erased row's text left the folder")
        #expect(ops.contains { $0.table == "annotations" && $0.fields.values.contains { $0.display == "due 1st" } }, "other rows stay")
        _ = keep
        // Idempotent: nothing new to redact.
        #expect(try await a.engine.sync().batchesRedacted == 0)
        // A device joining now reads the redacted batch: it never receives the erased note.
        let c = try await S18Device.make("C", store: store)
        defer { try? FileManager.default.removeItem(at: c.dir) }
        _ = try await ParityFixture.document(c.db, name: "lease.txt", text: text, fileHash: "filehash-s18")
        _ = try await c.engine.sync()
        #expect(try await s18Count(c.db, "SELECT COUNT(*) FROM annotations WHERE note LIKE '%Meera%';") == 0)
        #expect(try await s18Count(c.db, "SELECT COUNT(*) FROM annotations WHERE note = 'due 1st';") == 1)
    }

    @Test("SEC-07: the full erase empties tables whose names hold 'fts' after their first letter (the old unescaped LIKE skipped them) and still leaves the search indexes to their own triggers; it clears Spotlight and stops a sync that would refill it")
    func fullEraseReach() async throws {
        let f = try await CaseFileTests.fixture()
        try await f.db.exec("CREATE TABLE IF NOT EXISTS s18_giftshop_drafts (id TEXT PRIMARY KEY, note TEXT);")
        let tables = try await f.db.query(AppState.fullEraseTablesSQL, []).compactMap { $0.string(0) }
        #expect(tables.contains("s18_giftshop_drafts"), "a name holding 'fts' is erased")
        #expect(tables.contains("case_drafts") || tables.contains { $0.contains("drafts") })
        #expect(!tables.contains { $0.hasSuffix("_fts") || $0.contains("_fts_") }, "the full-text index tables are not deleted from directly")
        let old = try await f.db.query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '%_fts%';", []).compactMap { $0.string(0) }
        #expect(!old.contains("s18_giftshop_drafts"), "the bug: the old filter skipped it")
        // The full erase removes this app's Spotlight items and stops folder sync (source check: the test host never
        // touches the system index or the owner's sync settings).
        let src = try String(contentsOf: SmartMapS9Tests.repoRoot.appendingPathComponent("Kalsmritikosh/App/AppState.swift"), encoding: .utf8)
        let body = try #require(src.range(of: "public func deleteAllData()").map { String(src[$0.lowerBound...].prefix(9000)) })
        #expect(body.contains("await refreshSpotlightAfterErasure()") && body.contains("stopSyncing()") && body.contains("Self.fullEraseTablesSQL"))
    }

    // MARK: SEC-10 — binary parsers

    @Test("SEC-10: seeded fuzzing of the PDF, Office/ODF (ZIP), image and audio readers — every mutated input is read or refused within the time bound, without amplification")
    func fuzzBinaryReaders() async throws {
        struct OCRStub: OCREngine {
            nonisolated var engineID: String { "s18-stub" }
            func recognizePrinted(at url: URL) async -> [String] { ["recognised line"] }
            func recognizeHandwritten(at url: URL) async -> [String] { [] }
            func recognizeTable(at url: URL) async -> [[String]] { [] }
        }
        struct NoSpeech: AudioTranscribing {
            nonisolated var engineID: String { "s18-no-speech" }
            func transcribe(audioAt url: URL) async throws -> String { "" }
        }
        // Seeds: a one-page text PDF, a PNG, a DOCX, the workbook, the deck, an ODT, a WAV header.
        let pdf = NSMutableData()
        if let consumer = CGDataConsumer(data: pdf as CFMutableData) {
            var box = CGRect(x: 0, y: 0, width: 200, height: 100)
            if let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) {
                ctx.beginPDFPage(nil)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Paid twice on 9 March"))
                ctx.textPosition = CGPoint(x: 10, y: 50)
                CTLineDraw(line, ctx)
                ctx.endPDFPage(); ctx.closePDF()
            }
        }
        let image = NSImage(size: NSSize(width: 24, height: 12))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 24, height: 12).fill(); image.unlockFocus()
        let png = image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) } ?? Data()
        var docx = ZIPArchiveWriter()
        docx.addFile(path: "word/document.xml", text: "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p><w:r><w:t>Paid twice.</w:t></w:r></w:p></w:body></w:document>")
        var odt = ZIPArchiveWriter()
        odt.addFile(path: "content.xml", text: "<office:document-content xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\"><office:body><office:text><text:p>Paid twice.</text:p></office:text></office:body></office:document-content>")
        var wav = Data("RIFF".utf8); wav.append(contentsOf: [36, 0, 0, 0]); wav.append(Data("WAVEfmt ".utf8))
        wav.append(contentsOf: [16, 0, 0, 0, 1, 0, 1, 0, 0x40, 0x1F, 0, 0, 0x80, 0x3E, 0, 0, 2, 0, 16, 0]); wav.append(Data("data".utf8)); wav.append(contentsOf: [0, 0, 0, 0])
        let registry = StructuralParserRegistry.standard(ocr: OCRStub())
        let seeds: [(SourceType, Data, Int)] = [(.pdf, pdf as Data, 12), (.png, png, 12), (.docx, docx.build(), 16), (.xlsx, s18Workbook(), 16),
                                                (.pptx, s18Deck(), 16), (.odt, odt.build(), 12)]
        var rng = S18Random(state: 0x5EC_1018)
        var read = 0, refused = 0, slowest: Duration = .zero
        let clock = ContinuousClock()
        let started = clock.now
        func mutate(_ base: Data) -> Data {
            var bytes = [UInt8](base)
            for _ in 0..<(1 + rng.int(8)) {
                switch rng.int(4) {
                case 0 where !bytes.isEmpty: bytes[rng.int(bytes.count)] = UInt8(truncatingIfNeeded: rng.next())
                case 1 where bytes.count > 8: bytes.removeSubrange(rng.int(bytes.count / 2 + 1)..<bytes.count)
                case 2 where !bytes.isEmpty: let s = rng.int(bytes.count); bytes.insert(contentsOf: bytes[s..<min(bytes.count, s + 64)], at: rng.int(bytes.count + 1))
                default: bytes.insert(UInt8(truncatingIfNeeded: rng.next()), at: rng.int(bytes.count + 1))
                }
            }
            return Data(bytes)
        }
        for (type, seed, n) in seeds {
            let parser = try #require(registry.parser(for: type), "\(type.rawValue)")
            for _ in 0..<n {
                let data = mutate(seed)
                let t0 = clock.now
                do {
                    let doc = try await parser.parse(data: data, filename: "fuzz.\(type.rawValue)", type: type, logicalSourceID: UUID(), sourceVersionID: UUID())
                    read += 1
                    let total = doc.blocks.reduce(0) { $0 + $1.rawText.utf8.count }
                    #expect(total <= data.count * 20 + 8192, "\(type.rawValue): \(data.count) bytes became \(total) characters")
                } catch { refused += 1 }
                let took = clock.now - t0
                if took > slowest { slowest = took }
                #expect(took < .seconds(2), "\(type.rawValue) took \(took)")
            }
        }
        // Audio: mutated headers through the audio reader (a stub transcriber; no speech recognition).
        let dir = try s18Scratch("audio")
        defer { try? FileManager.default.removeItem(at: dir) }
        let loader = AudioLoader(transcriber: NoSpeech())
        for i in 0..<8 {
            let url = dir.appendingPathComponent("fuzz-\(i).wav")
            try mutate(wav).write(to: url)
            let t0 = clock.now
            do { _ = try await loader.ingest(fileAt: url, type: .wav); read += 1 } catch { refused += 1 }
            #expect(clock.now - t0 < .seconds(2))
        }
        #expect(read + refused == seeds.reduce(0) { $0 + $1.2 } + 8)
        #expect(clock.now - started < .seconds(5), "the whole fuzz run is bounded: \(clock.now - started), slowest \(slowest)")
    }

    // MARK: QA-14 — test isolation and honest result checks

    @Test("QA-14: the test host's notes, intake, diagnostics, receipts, transcriptions and diagnostic reports live in its own folder; no test boots the owner's ledger; every App Support user is reviewed")
    func testHostStoresAreItsOwn() throws {
        #expect(TestHost.isActive)
        let tmp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        for url in [NotesStore.standard?.base, CaptureIntake.folder, DiagnosticsStore.folder, try? ScanRescue.folder()].compactMap({ $0 }) {
            #expect(url.standardizedFileURL.path.hasPrefix(tmp), "\(url.path) is not the test host's own folder")
        }
        #expect(TestHost.applicationSupport() == TestHost.scratchSupport)
        #expect(try TestHost.documentsDirectory(create: false).standardizedFileURL.path.hasPrefix(tmp), "diagnostic reports stay in the test host's folder")
        // Every boot in the tests names a throwaway ledger (nil would open the owner's under Application Support).
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var offenders: [String] = []
        for file in try FileManager.default.contentsOfDirectory(at: testsDir, includingPropertiesForKeys: nil)
        where file.pathExtension == "swift" && file.lastPathComponent != "SmartMapS18Tests.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (i, line) in text.components(separatedBy: "\n").enumerated() where line.contains(".boot(") && line.contains("await") {
                // AcceptanceCaseGUIFixture.boot opens only its own ledger in the temporary folder (and, since GUI walk D1,
                // nothing at all when a ledger is already open) — never the owner's.
                let fixtureBoot = line.contains("AcceptanceCaseGUIFixture.boot(")
                if !fixtureBoot && !line.contains("databaseURL:") && !line.contains("Tests.boot(") && !line.contains("Self.boot(") && !line.contains(".boot(at:") {
                    offenders.append("\(file.lastPathComponent):\(i + 1)")
                }
            }
            if text.contains("DatabaseStack.defaultDatabaseURL") { offenders.append("\(file.lastPathComponent): defaultDatabaseURL") }
        }
        #expect(offenders.isEmpty, "\(offenders)")
        // Every product file that resolves Application Support is either redirected in the test host or reviewed here.
        let reviewed: [String: String] = [
            "Storage/Database/DatabaseStack.swift": "the ledger: tests always pass databaseURL (checked above)",
            "App/SampleArchiveMode.swift": "the sample ledger, app-owned demo data",
            "App/DemoArchive.swift": "bundled demo documents copied for the sample",
            "App/AcceptanceCaseFixture.swift": "bundled acceptance documents for the sample",
            "App/ScaleRunRecorder.swift": "a Settings button only; no test starts it",
            "EvalKit/NarrativeEvalReportStore.swift": "developer evaluation reports",
            "Routing/ModelDownloader.swift": "model files",
            "Routing/Providers/CloudEndpointRegistry.swift": "endpoint list", "Routing/Providers/GGUFRegistry.swift": "model registry",
            "Routing/Providers/MLXDiscovery.swift": "model discovery",
            // Documents users (developer evaluation harnesses, run on purpose against a chosen ledger, gated in tests).
            "EvalKit/Gate1Baseline.swift": "developer baseline (takes its own databaseURL)", "EvalKit/RealDataProbe.swift": "developer probe (owner's archive, gated)",
            "EvalKit/ReleaseReadiness.swift": "developer release report",
        ]
        let root = SmartMapS9Tests.repoRoot.appendingPathComponent("Kalsmritikosh")
        var unreviewed: [String] = []
        if let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in en where url.pathExtension == "swift" {
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                guard text.contains("applicationSupportDirectory") || text.contains("documentDirectory") else { continue }
                let rel = String(url.path.dropFirst(root.path.count + 1))
                if reviewed[rel] == nil && !text.contains("TestHost.") { unreviewed.append(rel) }
            }
        }
        #expect(unreviewed.isEmpty, "Application Support used without a test-host redirect or a review: \(unreviewed)")
    }

    @Test("QA-14: the result-bundle checks count only executed tests (skipped ones are not passes), refuse a bundle older than the checked commit, and ignore suites whose tests were all skipped")
    func resultBundleChecksAreHonest() throws {
        let root = SmartMapS9Tests.repoRoot
        let whole = try String(contentsOf: root.appendingPathComponent("ci/verify-xcresult-tests.sh"), encoding: .utf8)
        #expect(whole.contains("executed = passed + failed + expected") && whole.contains("if executed < minimum"))
        #expect(whole.contains("stale result bundle") && whole.contains("git log -1 --format=%ct") && whole.contains("XCRESULT_ALLOW_STALE"))
        let group = try String(contentsOf: root.appendingPathComponent("ci/verify-xcresult-group.sh"), encoding: .utf8)
        #expect(group.contains("o.get(\"result\") != \"Skipped\"") && group.contains("- int(summary.get(\"skippedTests\", 0))"))
    }
}
