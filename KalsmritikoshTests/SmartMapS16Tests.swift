//
//  SmartMapS16Tests.swift
//  KalsmritikoshTests
//
//  Smart-map slice S16 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md §24 SEC, §02 ARCH):
//  - ARCH-05: the job hand-over and the case package carry typed references with an explicit availability
//    (no source recorded, outside the case's scope, position not recorded);
//  - ARCH-09: an AI effect and a carried job row are re-checked INSIDE the write that applies them;
//  - SEC-03: the storage / key inventory matches the code; temporary plaintext leftovers are swept; a ledger move never
//    carries opened plaintext copies;
//  - SEC-06: protection added on the document's file, record or review coding after an output was prepared stops it;
//  - SEC-07: a dataset made from the case goes with it; the explicit count-back; the table filter no longer skips names
//    holding "fts";
//  - SEC-10: seeded fuzzing of the structural parsers and of file names;
//  - SEC-11: diagnostics never keep message text, paths or credentials; no file name reaches the log as public text.
//  Synthetic data only; no network, no model. Dates carry explicit time zones.
//

import CryptoKit
import Foundation
import Testing
@testable import Kalsmritikosh

private struct S16Random {
    var state: UInt64
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state >> 11 }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
    mutating func pick<T>(_ a: [T]) -> T { a[int(a.count)] }
}

private func s16Scratch(_ tag: String) throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("s16-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func s16Count(_ db: Database, _ sql: String, _ b: [SQLValue] = []) async throws -> Int {
    Int(try await db.query(sql, b).first?.int(0) ?? -1)
}

/// A new current version of the document behind `object`, included in the case.
private func s16Revise(_ db: Database, object: UUID, cases: InvestigationCaseRepository, caseID: UUID) async throws {
    let fileID = try #require(try await db.query("SELECT file_id FROM knowledge_objects WHERE id = ?;", [.uuid(object)]).first?.uuid(0))
    try await db.exec("UPDATE source_versions SET is_current = 0 WHERE logical_source_id = ?;", [.uuid(fileID)])
    let version = UUID(), doc = UUID(), t = Date().timeIntervalSince1970
    let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    try await db.exec("""
        INSERT INTO source_versions (id, logical_source_id, document_id, content_hash, valid_from, is_current, created_at,
            filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?);
        """, [.uuid(version), .uuid(fileID), .uuid(doc), .text(hex + hex), .real(t), .integer(1), .real(t),
              .text("revised.txt"), .text("txt"), .text("magicBytes"), .integer(1), .text("referenced"), .text("referenceRecorded"), .real(t)])
    let header = try await cases.fetch(caseID: caseID)?.caseHeader
    _ = try await cases.includeSource(caseID: caseID, expectedRevision: header?.revision ?? 1, sourceRef: version.uuidString,
                                      sourceKind: .sourceVersion, actor: "Ada", at: Date())
}

private func s16Exclude(_ f: CaseFileTests.Fixture, version: UUID) async throws {
    let header = try #require(try await f.cases.fetch(caseID: f.caseID)).caseHeader
    _ = try await f.cases.excludeSource(caseID: f.caseID, expectedRevision: header.revision, sourceRef: version.uuidString,
                                       sourceKind: .sourceVersion, note: "out of period", actor: "Ada", at: Date())
}

@Suite("Smart map S16 — security and typed references (M3 SEC)", .serialized)
struct SmartMapS16Tests {

    static let kolkata = TimeZone(identifier: "Asia/Kolkata") ?? .gmt

    // MARK: ARCH-05 / ARCH-09 — the job hand-over

    @Test("ARCH-05/09: a carried row keeps typed references (outside scope and no source said so); a newer run or a source leaving the case while the carry is in flight refuses the write and leaves nothing")
    func jobCarryTypedAndRechecked() async throws {
        let f = try await CaseFileTests.fixture()
        let src = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "minutes.txt",
                                                            text: "The board approved the payment on 3 March 2026. The treasurer disagreed.")
        let other = try await f.cases.createCase(workspaceID: f.workspaceID, title: "Another matter", actor: "Ada", at: Date())
        let outside = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: other.id, name: "elsewhere.txt", text: "Unrelated words.")
        let results = JobResultRepository(database: f.db)
        var row = JobResultRow(title: "Approval date", detail: nil, date: "2026-03-03",
                               refs: [StudioEvidenceRef(sourceVersionID: src.version, objectID: src.object, blockID: src.blocks[0], quote: "The board approved the payment on 3 March 2026."),
                                      StudioEvidenceRef(sourceVersionID: outside.version, objectID: outside.object, quote: "Unrelated words."),
                                      StudioEvidenceRef(sourceVersionID: nil, objectID: nil, quote: "as told by phone")])
        row.decision = JobRowDecision.accepted
        let id = try await results.save(caseID: f.caseID, jobID: "inv.chronology", family: .chronologyLinkage, state: .draft,
                                        content: JobResultContent(rows: [row]), actor: "Ada")
        let saved = try #require(try await results.record(id: id))

        // 1. Typed references: available, outside this case's scope, and no source recorded — each said so.
        let carried = try await JobResultHandoff.carriedTyped(saved, row: 0, results: results, caseFiles: f.svc)
        let states = carried.references.map(\.availability)
        #expect(states == [.available, .outsideScope, .notRecorded], "\(states)")
        #expect(carried.references.allSatisfy { $0.holder == carried.origin })
        #expect(carried.references[1].fields.contains(CaseTypedReference.Availability.outsideScope.label))
        // A row citing nothing still carries one explicit "no source recorded" reference.
        let bare = try await JobResultHandoff.typed(CarriedRow(row: JobResultRow(title: "x", detail: nil, date: nil, refs: []), index: 0,
                                                               reviewState: .accepted, digest: "d", origin: "job:a:b:row:0"),
                                                    caseID: f.caseID, caseFiles: f.svc)
        #expect(bare.references.map(\.availability) == [.notRecorded])

        // 2. Carried as is → written.
        let journalBefore = try await s16Count(f.db, "SELECT COUNT(*) FROM case_journal WHERE case_id = ?;", [.uuid(f.caseID)])
        _ = try await JobResultHandoff.applying(carried, record: saved) {
            try await f.file.addJournal(caseID: f.caseID, kind: .chronology, text: "carried", eventDate: nil, evidenceRef: nil, actor: "Ada")
        }
        #expect(try await s16Count(f.db, "SELECT COUNT(*) FROM case_journal WHERE case_id = ?;", [.uuid(f.caseID)]) == journalBefore + 1)

        // 3. The cited source leaves the case while the carry is in flight: refused inside the write, nothing written.
        try await s16Exclude(f, version: src.version)
        await #expect(throws: CaseApplyRecheck.Refused.self) {
            _ = try await JobResultHandoff.applying(carried, record: saved) {
                try await f.file.addJournal(caseID: f.caseID, kind: .chronology, text: "late carry", eventDate: nil, evidenceRef: nil, actor: "Ada")
            }
        }
        #expect(try await s16Count(f.db, "SELECT COUNT(*) FROM case_journal WHERE case_id = ? AND text = 'late carry';", [.uuid(f.caseID)]) == 0)

        // 4. A newer run of the same job saved while a carry of the older one is in flight: refused.
        let f2 = try await CaseFileTests.fixture()
        let src2 = try await CaseFileTestSources.seedPassage(f2.db, cases: f2.cases, caseID: f2.caseID, name: "m.txt", text: "Paid on 4 March 2026.")
        let results2 = JobResultRepository(database: f2.db)
        var r2 = JobResultRow(title: "Paid", detail: nil, date: "2026-03-04", refs: [StudioEvidenceRef(sourceVersionID: src2.version, objectID: src2.object, quote: "Paid on 4 March 2026.")])
        r2.decision = JobRowDecision.accepted
        let first = try #require(try await results2.record(id: try await results2.save(caseID: f2.caseID, jobID: "inv.chronology", family: .chronologyLinkage,
                                                                                         state: .draft, content: JobResultContent(rows: [r2]), actor: "Ada")))
        let inFlight = try await JobResultHandoff.carriedTyped(first, row: 0, results: results2, caseFiles: f2.svc)
        _ = try await results2.save(caseID: f2.caseID, jobID: "inv.chronology", family: .chronologyLinkage, state: .draft,
                                    content: JobResultContent(rows: [r2, r2]), actor: "Ada")
        await #expect(throws: CaseApplyRecheck.Refused.self) {
            _ = try await JobResultHandoff.applying(inFlight, record: first) {
                try await f2.file.addAllegation(caseID: f2.caseID, text: "From the older run", actor: "Ada")
            }
        }
        #expect(try await s16Count(f2.db, "SELECT COUNT(*) FROM case_allegations WHERE case_id = ?;", [.uuid(f2.caseID)]) == 0)
    }

    // MARK: ARCH-09 — AI effects

    @Test("ARCH-09: an AI effect whose input was replaced, or whose policy changed, is refused inside the write — case-file writes and map links alike; a compensating write runs unchecked")
    func aiEffectRecheckedInsideWrite() async throws {
        let f = try await CaseFileTests.fixture()
        let doc = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "ledger.txt", text: "A transfer of 10,000 on 5 March 2026.")
        let q = try await f.file.addAllegation(caseID: f.caseID, text: "Was it paid twice?", actor: "Ada")
        let q2 = try await f.file.addAllegation(caseID: f.caseID, text: "Who approved it?", actor: "Ada")
        // Current inputs: applied.
        try await CaseApplyRecheck.$current.withValue(CaseApplyRecheck.inputsCurrent([doc.version])) {
            _ = try await f.file.addAllegation(caseID: f.caseID, text: "Applied while current", actor: "Ada")
        }
        let policy = try await f.db.withSavepoint("s16pv") { db in try CaseAutomationPolicyStore.current(db, caseID: f.caseID).version }
        // The document gets a newer version while the effect is in flight.
        try await s16Revise(f.db, object: doc.object, cases: f.cases, caseID: f.caseID)
        let before = try await s16Count(f.db, "SELECT COUNT(*) FROM case_allegations WHERE case_id = ?;", [.uuid(f.caseID)])
        let linksBefore = try await s16Count(f.db, "SELECT COUNT(*) FROM case_map_links WHERE case_id = ?;", [.uuid(f.caseID)])
        let check = CaseApplyRecheck.all([CaseApplyRecheck.inputsCurrent([doc.version]), CaseApplyRecheck.policyUnchanged(policy)])
        await #expect(throws: CaseApplyRecheck.Refused.self) {
            try await CaseApplyRecheck.$current.withValue(check) {
                _ = try await f.file.addAllegation(caseID: f.caseID, text: "Applied after the change", actor: "Ada")
            }
        }
        await #expect(throws: CaseApplyRecheck.Refused.self) {
            try await CaseApplyRecheck.$current.withValue(check) {
                _ = try await CaseMapRepository(database: f.db).addLink(caseID: f.caseID, type: .dependsOn,
                                                                        from: CaseMapNodeID(caseID: f.caseID, kind: .allegation, recordID: q.uuidString),
                                                                        to: CaseMapNodeID(caseID: f.caseID, kind: .allegation, recordID: q2.uuidString),
                                                                        rationale: "AI proposal", actor: "Ada")
            }
        }
        #expect(try await s16Count(f.db, "SELECT COUNT(*) FROM case_allegations WHERE case_id = ?;", [.uuid(f.caseID)]) == before)
        #expect(try await s16Count(f.db, "SELECT COUNT(*) FROM case_map_links WHERE case_id = ?;", [.uuid(f.caseID)]) == linksBefore)
        // A changed policy version alone refuses too.
        await #expect(throws: CaseApplyRecheck.Refused.self) {
            try await CaseApplyRecheck.$current.withValue(CaseApplyRecheck.policyUnchanged(policy + 1)) {
                _ = try await f.file.addAllegation(caseID: f.caseID, text: "Under another policy", actor: "Ada")
            }
        }
        // The compensating write (cancelling a half-made action) is not refused by the check that failed.
        try await CaseApplyRecheck.$current.withValue(check) {
            try await CaseApplyRecheck.unbound {
                _ = try await f.file.addAllegation(caseID: f.caseID, text: "Compensation", actor: "Ada")
            }
        }
        #expect(try await s16Count(f.db, "SELECT COUNT(*) FROM case_allegations WHERE case_id = ?;", [.uuid(f.caseID)]) == before + 1)
    }

    // MARK: ARCH-05 — the case package

    @Test("ARCH-05: the case package writes one typed reference per shown source with its availability now, and each evidence row says whether it is available")
    @MainActor func packageTypedReferences() async throws {
        let rig = try await CaseMapRig.make()
        let f = rig.f
        let a = try await f.file.addAllegation(caseID: f.caseID, text: "The supplier was paid twice", actor: "Ada")
        _ = try await f.svc.linkEvidence(caseID: f.caseID, allegationID: a, evidenceRef: rig.a.version.uuidString, label: "invoice A", stance: .supports, note: nil,
                                         passage: StudioEvidenceRef(sourceVersionID: rig.a.version, objectID: rig.a.object, quote: "The invoice total was 500 dollars."), actor: "Ada")
        let (out, temp) = try s11Outputs(f)
        defer { try? FileManager.default.removeItem(at: temp) }
        let map = CaseMapService(sources: caseMapSources(f))
        let pkg = try await out.preparePackage(caseID: f.caseID, selection: .wholeCase, actor: "Ada") { id in await map.load(caseID: id, generation: 1) }
        let read = CasePortablePackageReader.read(pkg.text)
        #expect(read.violations.isEmpty, "\(read.violations)")
        #expect(read.sections.contains("references"))
        let m = try #require(read.manifest)
        let refs = try #require(m.counts["references"])
        #expect(refs > 0 && read.rows["reference"] == refs, "\(refs) references, \(read.rows["reference"] ?? -1) rows")
        let refText = read.sectionText["references"] ?? ""
        #expect(refText.contains(rig.a.version.uuidString.lowercased()), "the exact version is written")
        #expect(refText.contains("available"))
        #expect(read.sectionText["evidence"]?.contains("Available now") == true)
        // The written file reconciles with its manifest (the reference rows are counted).
        let url = temp.appendingPathComponent("package.html")
        let receipt = await out.write(pkg, to: url)
        #expect(receipt.status == .written && receipt.recorded, "\(receipt.summary)")
    }

    // MARK: SEC-06

    @Test("SEC-06: an output prepared before the document was marked privileged on its FILE, on one of its RECORDS, or coded privileged in review is refused at release; a citation naming only the record is checked too")
    @MainActor func protectionChangeAfterPrepareStopsRelease() async throws {
        for route in ["file", "record", "review", "objectOnly"] {
            let f = try await CaseFileTests.fixture()
            let doc = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "advice.txt", text: "Counsel advised settling the claim.")
            let (out, temp) = try s11Outputs(f)
            defer { try? FileManager.default.removeItem(at: temp) }
            let cite = route == "objectOnly" ? StudioEvidenceRef(sourceVersionID: nil, objectID: doc.object, quote: "Counsel advised")
                                             : StudioEvidenceRef(sourceVersionID: doc.version, objectID: doc.object, quote: "Counsel advised")
            let pkg = try await out.prepareText(caseID: f.caseID, kind: .achReport, route: .print, actor: "Ada", citations: [cite], text: "ACH: settlement advice")
            let fileID = try #require(try await f.db.query("SELECT file_id FROM knowledge_objects WHERE id = ?;", [.uuid(doc.object)]).first?.uuid(0))
            let scopes = SensitiveScopeRepository(database: f.db)
            switch route {
            case "file", "objectOnly":
                _ = try await scopes.assign(target: SensitiveScopeTarget(kind: .file, id: fileID), sensitivity: .confidential,
                                            authority: .userConfirmed(actorID: "Ada", confirmationID: UUID(), privileged: true), reason: "legal advice")
            case "record":
                _ = try await scopes.assign(target: SensitiveScopeTarget(kind: .knowledgeObject, id: doc.object), sensitivity: .confidential,
                                            authority: .userConfirmed(actorID: "Ada", confirmationID: UUID(), privileged: true), reason: "legal advice")
            default:
                try await f.db.exec("INSERT INTO review_codes (id, object_id, code, reviewer, coded_at) VALUES (?,?, 'privileged', 'Ada', ?);",
                                    [.uuid(UUID()), .uuid(doc.object), .real(Date().timeIntervalSince1970)])
            }
            let released = await out.release(pkg) { _ in true }
            #expect(released.status == .refused, "\(route): \(released.status) \(released.detail ?? "")")
            #expect(released.detail?.contains("no longer cleared") == true, "\(route): \(released.detail ?? "")")
        }
    }

    // MARK: SEC-07

    @Test("SEC-07: a Data Lab dataset made from the case and every row of it go with the case; a table whose name holds 'fts' is no longer skipped; the count-back covers them; the inventory names them")
    func erasureReachesOriginTablesAndCountsBack() async throws {
        let f = try await CaseFileTests.fixture()
        let c = f.caseID
        let ds = UUID(), field = UUID(), t = Date().timeIntervalSince1970
        try await f.db.exec("INSERT INTO workbench_datasets (id, workspace_id, title, mode, revision, created_at, updated_at, origin_case_id) VALUES (?,?,?,'advanced',1,?,?,?);",
                            [.uuid(ds), .uuid(f.workspaceID), .text("Supplier payments — money trail"), .real(t), .real(t), .uuid(c)])
        try await f.db.exec("INSERT INTO workbench_fields (id, dataset_id, name, value_shape, ordinal, created_at) VALUES (?,?,'amount','text',0,?);",
                            [.uuid(field), .uuid(ds), .real(t)])
        // A dataset of no case stays.
        let keep = UUID()
        try await f.db.exec("INSERT INTO workbench_datasets (id, workspace_id, title, mode, revision, created_at, updated_at) VALUES (?,?,'Library data','advanced',1,?,?);",
                            [.uuid(keep), .uuid(f.workspaceID), .real(t), .real(t)])
        // A store whose name holds "fts" after its first letter (the old unescaped LIKE skipped it).
        try await f.db.exec("CREATE TABLE IF NOT EXISTS s16_giftshop_notes (id TEXT PRIMARY KEY, case_id TEXT NOT NULL, note TEXT);")
        try await f.db.exec("INSERT INTO s16_giftshop_notes (id, case_id, note) VALUES (?,?, 'case text');", [.uuid(UUID()), .uuid(c)])
        let tables = try await f.db.withSavepoint("s16t") { db in try CaseEraser.userTables(db) }
        #expect(tables.contains("s16_giftshop_notes") && !tables.contains { $0.hasSuffix("_fts") })
        // The inventory registers the dataset and its children; nothing case-shaped is unregistered except the test table.
        let missing = try await f.db.withSavepoint("s16inv") { db in try CaseDataInventory.unregistered(db) }
        #expect(missing == ["s16_giftshop_notes"], "\(missing)")
        #expect(CaseDataInventory.entry("workbench_datasets")?.lifecycle == .originCase(column: "origin_case_id"))

        let report = try await CaseEraser(database: f.db).erase(caseID: c, sourceVersionIDs: [], eraseExclusiveSources: false,
                                                                reason: "Retention ended", legalBasis: nil, actor: "Ada")
        #expect(report.refused == nil, "\(report.refused ?? "")")
        #expect(report.rowsErased["workbench_datasets"] == 1 && report.rowsErased["s16_giftshop_notes"] == 1, "\(report.rowsErased)")
        #expect(try await s16Count(f.db, "SELECT COUNT(*) FROM workbench_datasets WHERE id = ?;", [.uuid(ds)]) == 0)
        #expect(try await s16Count(f.db, "SELECT COUNT(*) FROM workbench_fields WHERE dataset_id = ?;", [.uuid(ds)]) == 0, "children cascade")
        #expect(try await s16Count(f.db, "SELECT COUNT(*) FROM workbench_datasets WHERE id = ?;", [.uuid(keep)]) == 1)
        #expect(try await s16Count(f.db, "SELECT COUNT(*) FROM s16_giftshop_notes;") == 0)

        // Legal holds still refuse atomically (the hold check runs inside the same savepoint as the deletes).
        let f2 = try await CaseFileTests.fixture()
        let ds2 = UUID()
        try await f2.db.exec("INSERT INTO workbench_datasets (id, workspace_id, title, mode, revision, created_at, updated_at, origin_case_id) VALUES (?,?,'held','advanced',1,?,?,?);",
                             [.uuid(ds2), .uuid(f2.workspaceID), .real(t), .real(t), .uuid(f2.caseID)])
        try await f2.db.exec("INSERT INTO case_hold_notices (id, case_id, custodian, notice_text, issued_by, issued_at) VALUES (?,?, 'Bo', 'Keep everything', 'Ada', ?);",
                             [.uuid(UUID()), .uuid(f2.caseID), .real(t)])
        let held = try await CaseEraser(database: f2.db).erase(caseID: f2.caseID, sourceVersionIDs: [], eraseExclusiveSources: false,
                                                               reason: "Retention ended", legalBasis: nil, actor: "Ada")
        #expect(held.refused != nil)
        #expect(try await s16Count(f2.db, "SELECT COUNT(*) FROM workbench_datasets WHERE id = ?;", [.uuid(ds2)]) == 1, "nothing erased under a hold")
    }

    // MARK: SEC-03

    @Test("SEC-03: the storage inventory names every store with an anchor that exists, lists every swept temporary prefix, and the vault seals by default")
    func storageInventory() async throws {
        let root = SmartMapS9Tests.repoRoot
        let doc = try String(contentsOf: root.appendingPathComponent("docs/STORAGE_KEY_INVENTORY.md"), encoding: .utf8)
        let row = try NSRegularExpression(pattern: #"^\| (ST-\d+) \|[^|]*\| ([^|]+?) :: ([^|]+?) \|"#, options: [.anchorsMatchLines])
        let ns = doc as NSString
        var rows = 0, broken: [String] = []
        for m in row.matches(in: doc, range: NSRange(location: 0, length: ns.length)) {
            rows += 1
            let path = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            let symbol = ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespaces)
            let text = (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
            if !text.contains(symbol) { broken.append("\(ns.substring(with: m.range(at: 1))): \(path) :: \(symbol)") }
        }
        #expect(rows >= 20, "\(rows) stores")
        #expect(broken.isEmpty, "\(broken)")
        for p in TemporaryPlaintextSweep.prefixes { #expect(doc.contains("`\(p)"), "temporary prefix \(p) inventoried") }
        for key in ["hnsw-cache", EvidenceVault.sealPurpose, "backup-manifest"] { #expect(doc.contains(key), "derived key \(key)") }
        // The declared model in the threat model and data-flow inventory no longer says vault copies are unencrypted.
        let threat = try String(contentsOf: root.appendingPathComponent("docs/THREAT_MODEL.md"), encoding: .utf8)
        let flow = try String(contentsOf: root.appendingPathComponent("docs/DATA_FLOW_INVENTORY.md"), encoding: .utf8)
        #expect(!threat.contains("NOT app-encrypted") && threat.contains("Vault copies of originals are sealed"))
        #expect(!flow.contains("**Not encrypted** by the app") && flow.contains("**Sealed**"))
        // The vault seals what it stores when the ledger has a key (CitedSourceOpeningTests covers the default and the opener).
        let vroot = try s16Scratch("vault")
        defer { try? FileManager.default.removeItem(at: vroot) }
        let vault = EvidenceVault(root: vroot.appendingPathComponent("EvidenceVault", isDirectory: true), sealKey: SymmetricKey(size: .bits256))
        let plain = Data("Counsel advised settling the claim with Meera Iyer.".utf8)
        let address = try await vault.store(plain)
        #expect(await vault.isSealed(address))
        var onDisk = Data()
        if let en = FileManager.default.enumerator(at: vroot.appendingPathComponent("EvidenceVault"), includingPropertiesForKeys: nil) {
            for case let u as URL in en where !u.hasDirectoryPath { onDisk.append((try? Data(contentsOf: u)) ?? Data()) }
        }
        #expect(!onDisk.isEmpty && onDisk.range(of: Data("Meera Iyer".utf8)) == nil, "no plaintext in the vault")
        // An opened plaintext copy is never carried by a ledger move.
        #expect(LedgerRelocation.isOpenedPlaintext("EvidenceVault-open/abc/file.pdf") && !LedgerRelocation.isOpenedPlaintext("EvidenceVault/ab/abc.sealed"))
    }

    @Test("SEC-03: the launch sweep removes the app's own temporary plaintext older than an hour, and nothing younger or not its own")
    func temporarySweep() throws {
        let dir = try s16Scratch("sweep")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        func make(_ name: String, age: TimeInterval) throws {
            let u = dir.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: u, withIntermediateDirectories: true)
            let file = u.appendingPathComponent("copy.pdf")
            try Data("plaintext".utf8).write(to: file)
            try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: u.path)
        }
        try make("original-old", age: 7200)
        try make("kalsmritikosh-devonthink", age: 7200)
        try make("original-young", age: 60)
        try make("someone-elses-folder", age: 7200)
        let removed = TemporaryPlaintextSweep.run(in: dir)
        #expect(removed == 2)
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("original-old").path))
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("kalsmritikosh-devonthink").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("original-young").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("someone-elses-folder").path))
    }

    // MARK: SEC-10

    @Test("SEC-10: seeded fuzzing of the structural parsers — every mutated input is read or refused, quickly, without amplifying its size")
    func fuzzStructuralParsers() async throws {
        let parsers: [(any StructuralParser, SourceType, String)] = [
            (CSVStructuralParser(), .csv, "a,b,c\r\n\"1\",\"two, too\",3\r\n=HYPERLINK(\"http://x\"),@SUM(A1),-1\r\n"),
            (EmailStructuralParser(), .eml, "From: Ada <ada@example.com>\r\nTo: Bo <bo@example.com>\r\nSubject: =?utf-8?B?SGVsbG8=?=\r\nDate: Tue, 3 Mar 2026 10:00:00 +0530\r\nContent-Type: multipart/mixed; boundary=\"b1\"\r\n\r\n--b1\r\nContent-Type: text/plain\r\n\r\nPaid twice.\r\n--b1\r\nContent-Type: application/octet-stream; name=\"../../x.sh\"\r\nContent-Transfer-Encoding: base64\r\n\r\nIyEvYmluL3NoCg==\r\n--b1--\r\n"),
            (MBOXStructuralParser(), .mbox, "From ada@example.com Tue Mar  3 10:00:00 2026\nFrom: ada@example.com\nSubject: one\n\nbody one\n>From the start\n\nFrom bo@example.com Wed Mar  4 10:00:00 2026\nFrom: bo@example.com\nSubject: two\n\nbody two\n"),
            (RTFStructuralParser(), .rtf, "{\\rtf1\\ansi{\\fonttbl\\f0 Helvetica;}\\f0 Invoice {\\b 401} paid\\par{\\field{\\*\\fldinst HYPERLINK \"file:///etc/passwd\"}{\\fldrslt x}}}"),
            (StructuredTextStructuralParser(), .json, "{\"payments\":[{\"amount\":10000,\"date\":\"2026-03-05\"},{\"amount\":10000,\"note\":\"\\u0000\"}]}"),
            (StructuredTextStructuralParser(), .xml, "<?xml version=\"1.0\"?><!DOCTYPE r [<!ENTITY a \"aaaaaaaaaa\"><!ENTITY b \"&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;\"><!ENTITY c \"&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;\"><!ENTITY ext SYSTEM \"file:///etc/passwd\">]><r><p>&c;</p><q>&ext;</q></r>"),
            (StructuredTextStructuralParser(), .html, "<html><body onload=\"x()\"><script>fetch('http://e.example')</script><p>Paid <b>twice</b></p><iframe src=\"http://e.example\"></iframe></body></html>"),
            (PlistStructuralParser(), .plist, "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>a</key><array><string>x</string><integer>99999999999999999999</integer></array></dict></plist>"),
        ]
        let hostile = ["\u{0}", "\u{202E}", "\r\n\r\n", "\"", "\\", "{", "}", "<", ">", "&#x0;", "=?utf-8?Q?=00?=", "From ", "--b1", "=cmd|' /C calc'!A0",
                       "../", "%00", String(repeating: "(", count: 64), "\u{FEFF}", "\u{FFFF}", "\\rtf1", "<!ENTITY", "&c;"]
        var rng = S16Random(state: 0x5EC_1016)
        var read = 0, refused = 0, slowest: Duration = .zero
        for (parser, type, seed) in parsers {
            let base = Array(seed.utf8)
            for _ in 0..<60 {
                var bytes = base
                for _ in 0..<(1 + rng.int(6)) {
                    switch rng.int(5) {
                    case 0 where !bytes.isEmpty: bytes[rng.int(bytes.count)] = UInt8(truncatingIfNeeded: rng.next())
                    case 1: bytes.insert(contentsOf: Array(rng.pick(hostile).utf8), at: rng.int(bytes.count + 1))
                    case 2 where bytes.count > 4: bytes.removeSubrange(rng.int(bytes.count / 2)..<bytes.count)
                    case 3 where !bytes.isEmpty: let s = rng.int(bytes.count); bytes.insert(contentsOf: bytes[s..<min(bytes.count, s + 40)], at: rng.int(bytes.count + 1))
                    default: bytes.append(UInt8(truncatingIfNeeded: rng.next()))
                    }
                }
                let data = Data(bytes)
                let clock = ContinuousClock()
                let start = clock.now
                do {
                    let doc = try await parser.parse(data: data, filename: "../\u{202E}fuzz\u{0}.\(type.rawValue)", type: type,
                                                     logicalSourceID: UUID(), sourceVersionID: UUID())
                    read += 1
                    let total = doc.blocks.reduce(0) { $0 + $1.rawText.utf8.count }
                    #expect(total <= data.count * 20 + 4096, "\(type.rawValue): \(data.count) bytes became \(total) characters of text")
                    #expect(doc.blocks.count <= data.count + 16, "\(type.rawValue): \(doc.blocks.count) blocks from \(data.count) bytes")
                    #expect(!doc.blocks.contains { $0.rawText.contains("root:") }, "\(type.rawValue): an external entity was resolved")
                } catch {
                    refused += 1
                }
                let took = clock.now - start
                if took > slowest { slowest = took }
                #expect(took < .seconds(5), "\(type.rawValue) took \(took)")
            }
        }
        #expect(read + refused == parsers.count * 60)
        #expect(read > 0, "\(read) read, \(refused) refused, slowest \(slowest)")
    }

    @Test("SEC-10: hostile file names become one safe component wherever the app names a file from case text")
    func fuzzFileNames() {
        var rng = S16Random(state: 0xF11E)
        let parts = ["..", ".", "/", "\\", "\u{0}", "\u{202E}", "\u{2066}", "\n", "\t", ":", "*", "?", "%2e%2e", "~", " ", "CON", "a", "é", "📄", String(repeating: "x", count: 300)]
        let bidi: Set<UInt32> = [0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069, 0x200E, 0x200F, 0x061C]
        for _ in 0..<500 {
            var name = ""
            for _ in 0..<(1 + rng.int(8)) { name += rng.pick(parts) }
            for safe in [SafeFilename.sanitize(name, fallback: "Answer"), OnlineToolDocuments.safeName(name)] {
                #expect(!safe.isEmpty && !safe.contains("/") && !safe.contains("\\") && !safe.hasPrefix("."), "\(name.debugDescription) → \(safe.debugDescription)")
                #expect(!safe.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || bidi.contains($0.value) }, "\(safe.debugDescription)")
                #expect(safe.utf8.count <= SafeFilename.maxBytes, "\(safe.utf8.count) bytes")
                #expect(safe != ".." && safe != ".")
            }
        }
    }

    // MARK: SEC-11

    @Test("SEC-11: a saved diagnostic keeps no exception message, home-folder path or credential; an older raw file is cleaned before it can be sent; a payload that cannot be read is not kept")
    func diagnosticsCarryNoContent() throws {
        let key = "sk-ant-api03-" + String(repeating: "Ab9_", count: 12)
        let raw = """
        {"crashDiagnostics":[{"diagnosticMetaData":{"exceptionType":1,"signal":6,"appVersion":"1.0",
          "exceptionReason":{"composedMessage":"*** -[NSString substringToIndex:]: Range out of bounds in 'Invoice for Meera Iyer.pdf'",
                             "formatString":"%@ in %@","arguments":["Meera Iyer","Invoice for Meera Iyer.pdf"],"className":"NSRangeException","exceptionName":"NSRangeException"},
          "terminationReason":"Namespace SIGNAL, Code 6 at /Users/ada/Documents/Cases/Meera/statement.pdf token \(key)"},
          "callStackTree":{"callStacks":[{"threadAttributed":true,"callStackRootFrames":[{"binaryName":"Kalsmritikosh","offsetIntoBinaryTextSegment":1234,
             "binaryUUID":"0D5F-1","address":4294967296}]}]}}]}
        """
        let clean = String(decoding: DiagnosticsSanitizer.sanitize(Data(raw.utf8)), as: UTF8.self)
        for leak in ["Meera", "Invoice", "/Users/ada", "Documents/Cases", key, "substringToIndex"] {
            #expect(!clean.contains(leak), "\(leak) survived: \(clean)")
        }
        for kept in ["NSRangeException", "Kalsmritikosh", "offsetIntoBinaryTextSegment", "\"signal\":6", "/Users/[path removed]"] {
            #expect(clean.contains(kept), "\(kept) kept for diagnosis: \(clean)")
        }
        #expect(DiagnosticsSanitizer.isSanitized(Data(clean.utf8)))
        #expect(!String(decoding: DiagnosticsSanitizer.sanitize(Data("not json \(key)".utf8)), as: UTF8.self).contains(key))

        // Saving through the store cleans; a file an older build wrote as delivered is cleaned before it is listed.
        let dir = try s16Scratch("diag")
        defer { try? FileManager.default.removeItem(at: dir) }
        let saved = try #require(DiagnosticsStore.save(Data(raw.utf8), kind: "crash", date: Date(), in: dir))
        #expect(!(try String(contentsOf: saved, encoding: .utf8)).contains("Meera"))
        let old = dir.appendingPathComponent("20260101-000000-000-crash-old.json")
        try Data(raw.utf8).write(to: old)
        DiagnosticsStore.sanitizeExisting(in: dir)
        #expect(!(try String(contentsOf: old, encoding: .utf8)).contains("Meera"))
        #expect(DiagnosticsStore.files(in: dir).count == 2)
    }

    @Test("SEC-11: no log statement in the app writes a file's name as public text")
    func noPublicFileNamesInLogs() throws {
        let interp = try NSRegularExpression(pattern: #"\\\(([^()]*(?:\([^()]*\))*[^()]*),\s*privacy:\s*\.public\)"#)
        let nameLike = try NSRegularExpression(pattern: #"(lastPathComponent|rule\.name|jobTitle|\.filename\b|fileName\b)"#)
        // Developer tools that log their own report paths, never a person's file.
        let exempt = ["EvalKit", "Fixture", "Gate1Baseline"]
        var scanned = 0, offenders: [String] = []
        for dir in ["Kalsmritikosh", "KalsmritikoshShare", "SyncCore"] {
            guard let en = FileManager.default.enumerator(at: SmartMapS9Tests.repoRoot.appendingPathComponent(dir), includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in en where url.pathExtension == "swift" {
                if exempt.contains(where: { url.path.contains($0) }) { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                scanned += 1
                for line in text.components(separatedBy: "\n") where line.contains("Log.") && line.contains(".public") {
                    let ns = line as NSString
                    for m in interp.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                        let expr = ns.substring(with: m.range(at: 1))
                        if nameLike.firstMatch(in: expr, range: NSRange(location: 0, length: (expr as NSString).length)) != nil {
                            offenders.append("\(url.lastPathComponent): \(expr.prefix(80))")
                        }
                    }
                }
            }
        }
        #expect(scanned > 500)
        #expect(offenders.isEmpty, "\(offenders)")
    }
}
