//
//  CaseMapPerfHarnessTests.swift
//  KalsmritikoshTests
//
//  Living case map M9 — the §13.3 measurement harness (docs/IME_Living_Case_Map_Implementation_Plan_2026-11-06.md).
//  The full run is OFF unless CASE_MAP_PERF=1 reaches the test process (xcodebuild forwards TEST_RUNNER_CASE_MAP_PERF=1)
//  or the git-ignored trigger file build/perf/RUN_CASE_MAP_PERF exists (a run from Xcode), so it never spends the normal
//  CI budget. The sandboxed host cannot write into the repository: the JSON and markdown are printed between
//  ===CASE_MAP_PERF_BEGIN <name>=== / ===CASE_MAP_PERF_END=== markers for scripts/case-map-perf-from-console.py. A small smoke run of the same code always runs, proving the harness.
//
//  It builds synthetic cases in a throwaway ledger through the real case services (documents are inserted in
//  the ledger's own tables; allegations, people, chronology entries and evidence-grid rows go through
//  CaseFileRepository / CaseFileService), then measures with the real CaseMapService, CaseMapWorkspaceModel,
//  CaseMapLayout, CaseMapViewFilter and CaseSearchService:
//    normal  — 500 documents, ~2,000 projected records, ~3,000 links;
//    stress  — 5,000 documents, ~50,000 projected records.
//  Measured: projection load cold (nothing placed yet) and warm; view switch and local filter p50/p95; selection;
//  incremental placement of 100 new records (existing positions must not move); initial layout and viewport
//  culling; case search over the normal case. Stress usability: grouping, culling and list paging, with every
//  record reachable. Hardware (sysctl), OS, build, fixture size, peak memory and raw timings are written as JSON
//  and markdown to CASE_MAP_PERF_OUT (a directory) when set, and printed between markers.
//
//  S13 (PERF, schema v188): the cases also carry the v176–v188 records — supplied reports with verified points, actions with
//  contracts and a deep parent chain, money accounts and records, frame memberships with one highly shared "hub" person,
//  a prior case with history references and an identifier overlap, and automation triggers — and the run times branch
//  (frame) open and return, the brief, the money ledger, change propagation, history, automation dispatch, the case
//  package export (with its read-back) and a backup + restore, separately. The machine's load average is recorded with
//  the numbers (a loaded Mac makes timings unreliable; the report says so).
//
//  The §13.3 targets are PROPOSED engineering targets; the harness records whether each was met and never fails
//  on a miss (it fails only on a correctness break: a moved position, an unreachable record, a failed load).
//  The fixture is generated text records (typed pdf/docx/eml/png by name and type, with long quotations); it
//  does not exercise parsing or OCR — the map reads the ledger after intake.
//

import Foundation
import Testing
@testable import Kalsmritikosh

/// The full run: CASE_MAP_PERF=1 in the test process (xcodebuild forwards TEST_RUNNER_CASE_MAP_PERF=1), or — for a run
/// from Xcode, which passes no variables — a trigger file build/perf/RUN_CASE_MAP_PERF in the (git-ignored) build folder.
private let perfEnabled: Bool = {
    if ProcessInfo.processInfo.environment["CASE_MAP_PERF"] == "1" { return true }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    return FileManager.default.fileExists(atPath: root.appendingPathComponent("build/perf/RUN_CASE_MAP_PERF").path)
}()

/// A seeded synthetic case.
struct CaseMapPerfCase {
    let f: CaseFileTests.Fixture
    let docs: [(version: UUID, object: UUID)]
    let allegations: [UUID]
    let seedSeconds: Double
    let textBytes: Int
    let spec: CaseMapPerfSpec
    /// S13 — the v176–v188 records seeded after the base case.
    var smart = CaseMapPerfSmart()
}

/// The v176–v188 records of a seeded case (S13).
struct CaseMapPerfSmart {
    var reports: [UUID] = []
    var points: [UUID] = []
    var actions: [UUID] = []
    var chain: [UUID] = []
    var moneyRecords: [UUID] = []
    var moneyAccounts: [UUID] = []
    var hub: UUID?
    var hubPlacements = 0
    var placements = 0
    var prior: UUID?
    var historySource: UUID?
    var references: [UUID] = []
    var stageSeconds: [String: Double] = [:]
}

struct CaseMapPerfSpec: Sendable {
    let label: String
    let documents: Int
    let allegations: Int
    let people: Int
    let journal: Int
    let grid: Int
    /// S13 — v176–v188 records: supplied reports × points each, actions (each serving a question), a parent chain of
    /// nested actions, money records (over two accounts), frame memberships (people placed in question frames; one hub
    /// person in every question's and every action's frame), history references to a prior case, automation triggers.
    var reports = 0
    var pointsPerReport = 0
    var actions = 0
    var chainDepth = 0
    var money = 0
    var frameMembers = 0
    var historyRefs = 0
    var triggers = 0
    /// Expected projected records of the base kinds: the case + allegations + documents + people + journal entries.
    var expectedRecords: Int { 1 + allegations + documents + people + journal }
    var expectedLinks: Int { journal + grid }

    static let smoke = CaseMapPerfSpec(label: "smoke", documents: 30, allegations: 4, people: 10, journal: 80, grid: 120,
                                       reports: 2, pointsPerReport: 3, actions: 5, chainDepth: 8, money: 10, frameMembers: 10, historyRefs: 2, triggers: 3)
    static let normal = CaseMapPerfSpec(label: "normal", documents: 500, allegations: 40, people: 160, journal: 1_300, grid: 1_700,
                                        reports: 20, pointsPerReport: 5, actions: 60, chainDepth: 40, money: 300, frameMembers: 300, historyRefs: 10, triggers: 30)
    static let stress = CaseMapPerfSpec(label: "stress", documents: 5_000, allegations: 50, people: 2_000, journal: 42_950, grid: 5_000,
                                        reports: 200, pointsPerReport: 5, actions: 400, chainDepth: 200, money: 3_000, frameMembers: 2_000, historyRefs: 20, triggers: 100)
}

enum CaseMapPerf {
    static let kinds = ["pdf", "docx", "eml", "png"]

    static func text(_ i: Int) -> String {
        let kind = kinds[i % kinds.count]
        let quote = String(repeating: "“The payment of invoice INV-\(1000 + i) for \(100 + i % 900).00 was approved by the finance lead on the stated date, and the supplier confirmed receipt.” ", count: 6)
        return "Document \(i) (\(kind)). Supplier account 44\(i % 97). Payment approved for invoice INV-\(1000 + i). Witness Ann Lee\(i % 50) said the payment was approved. " + quote
    }

    /// Seed a case: documents in the ledger's own tables (batched in a savepoint), each included in the case by its
    /// exact version through the case repository; then allegations, people, chronology entries (each citing a
    /// document) and evidence-grid rows (each linking an allegation to a document) through the case services.
    static func seed(_ spec: CaseMapPerfSpec) async throws -> CaseMapPerfCase {
        let t0 = Date()
        let f = try await CaseFileTests.fixture(title: "Perf \(spec.label): was the supplier paid twice?")
        let db = f.db
        var docs: [(version: UUID, object: UUID)] = []
        var bytes = 0
        let batch = 250
        var start = 0
        while start < spec.documents {
            let end = min(spec.documents, start + batch)
            var rows: [(file: UUID, ko: UUID, version: UUID, doc: UUID, block: UUID, name: String, kind: String, text: String, hash: String)] = []
            for i in start..<end {
                let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                let kind = kinds[i % kinds.count]
                let t = text(i)
                bytes += t.utf8.count
                rows.append((UUID(), UUID(), UUID(), UUID(), UUID(), "doc-\(i).\(kind)", kind, t, hex + hex))
            }
            let snapshot = rows
            try await db.withSavepoint("perf_docs") { db in
                for r in snapshot {
                    try db.exec("INSERT INTO files (id, url, source_type, availability, content_hash) VALUES (?,?,?,?,?);",
                                [.uuid(r.file), .text("file:///case-perf/\(r.name)"), .text(r.kind), .text("available"), .text(r.hash)])
                    try db.exec("INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);",
                                [.uuid(r.ko), .uuid(r.file), .text(r.kind == "eml" ? "email" : r.kind), .text(r.text), .real(0), .real(0)])
                    try db.exec("""
                        INSERT INTO source_versions (id, logical_source_id, document_id, content_hash, valid_from, is_current, created_at,
                            filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at, original_url)
                        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                        """, [.uuid(r.version), .uuid(r.file), .uuid(r.doc), .text(r.hash), .real(100), .integer(1), .real(100),
                              .text(r.name), .text(r.kind), .text("magicBytes"), .integer(Int64(r.text.utf8.count)), .text("referenced"),
                              .text("referenceRecorded"), .real(100), .text("file:///case-perf/\(r.name)")])
                    try db.exec("""
                        INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text, extraction_method, extraction_confidence)
                        VALUES (?,?,?,?,?,?,?,?,?);
                        """, [.uuid(r.block), .uuid(r.doc), .uuid(r.version), .integer(0), .text("paragraph"), .text(r.text), .text(r.text.lowercased()),
                              .text("native"), .real(1.0)])
                    try db.exec("INSERT INTO evidence_block_objects (evidence_block_id, knowledge_object_id, linked_at) VALUES (?,?,?);",
                                [.uuid(r.block), .uuid(r.ko), .real(0)])
                }
            }
            var revision = try await f.cases.fetch(caseID: f.caseID)?.caseHeader.revision ?? 1
            for r in rows {
                revision = try await f.cases.includeSource(caseID: f.caseID, expectedRevision: revision, sourceRef: r.version.uuidString,
                                                           sourceKind: .sourceVersion, actor: "Ada", at: Date()).revision
                docs.append((r.version, r.ko))
            }
            start = end
        }
        var allegations: [UUID] = []
        var people: [UUID] = []
        for a in 0..<spec.allegations {
            allegations.append(try await f.file.addAllegation(caseID: f.caseID, text: "Allegation \(a): the supplier was paid twice for batch \(a)", actor: "Ada"))
        }
        for p in 0..<spec.people {
            people.append(try await f.file.addPerson(caseID: f.caseID, name: "Person \(p)", role: p % 3 == 0 ? .witness : .subject, entityID: nil, contact: nil,
                                                     notes: nil, actor: "Ada"))
        }
        let day = 86_400.0
        for j in 0..<spec.journal {
            let d = docs[(j * 31) % docs.count]
            _ = try await f.file.addJournal(caseID: f.caseID, kind: .chronology, text: "Event \(j): payment step recorded for INV-\(1000 + j % spec.documents)",
                                            eventDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(j) * day / 10),
                                            evidenceRef: d.version.uuidString, quote: nil, actor: "Ada")
        }
        if !allegations.isEmpty {
            for g in 0..<spec.grid {
                let a = allegations[g % allegations.count]
                let d = docs[(g * 37 + g / allegations.count) % docs.count]
                _ = try await f.svc.linkEvidence(caseID: f.caseID, allegationID: a, evidenceRef: d.version.uuidString, label: nil,
                                                 stance: g % 5 == 0 ? .contradicts : .supports, note: nil, allowDuplicate: true, actor: "Ada")
            }
        }
        var c = CaseMapPerfCase(f: f, docs: docs, allegations: allegations, seedSeconds: 0, textBytes: bytes, spec: spec)
        c.smart.stageSeconds["base case (documents, questions, people, chronology, grid)"] = Date().timeIntervalSince(t0)
        c.smart = try await seedSmartMap(c, people: people, stages: c.smart.stageSeconds)
        return CaseMapPerfCase(f: f, docs: docs, allegations: allegations, seedSeconds: Date().timeIntervalSince(t0), textBytes: bytes, spec: spec, smart: c.smart)
    }

    /// S13 — the v176–v188 records, each family timed on its own (seeding cost is a measurement too: it is what a person's
    /// own recording costs at this size).
    static func seedSmartMap(_ c: CaseMapPerfCase, people: [UUID], stages: [String: Double]) async throws -> CaseMapPerfSmart {
        let spec = c.spec, f = c.f, caseID = f.caseID
        var s = CaseMapPerfSmart()
        s.stageSeconds = stages
        func node(_ k: CaseMapRecordKind, _ id: UUID) -> CaseMapNodeID { CaseMapNodeID(caseID: caseID, kind: k, id: id) }
        var t = Date()
        // Reports with points quoting their own document (verified against the version).
        for r in 0..<spec.reports {
            let d = c.docs[(r * 7) % c.docs.count]
            let i = (r * 7) % c.docs.count
            let report = try await f.file.addReport(caseID: caseID, CaseReportDetails(title: "Supplied report \(r)", sourceVersionID: d.version, producer: "Lab \(r % 5)",
                                                                                   author: "Examiner \(r % 9)", reportDateText: "\(1 + r % 28) March 2026"), actor: "Ada")
            s.reports.append(report)
            for k in 0..<spec.pointsPerReport {
                let quote = k == 0 ? "Payment approved for invoice INV-\(1000 + i)." : "Witness Ann Lee\(i % 50) said the payment was approved."
                s.points.append(try await f.svc.addPoint(caseID: caseID, reportID: report, kind: k % 2 == 0 ? .finding : .claim,
                                                         statement: "Point \(k) of report \(r)", quote: k < 2 ? quote : nil, actor: "Ada"))
            }
        }
        s.stageSeconds["reports and points (\(spec.reports) × \(spec.pointsPerReport))"] = Date().timeIntervalSince(t)
        t = Date()
        // Actions with contracts, each serving a question (and raised from a point when there are points).
        for a in 0..<spec.actions {
            let q = c.allegations[a % max(1, c.allegations.count)]
            s.actions.append(try await f.svc.createAction(caseID: caseID, .init(title: "Action \(a)", purpose: "Check batch \(a)", deliverable: "A note on batch \(a)",
                                                                              responsible: "Ada", fromPoint: s.points.isEmpty ? nil : s.points[a % s.points.count],
                                                                              servesQuestions: [q]), actor: "Ada"))
        }
        // A long branch: each action is the parent of the next.
        var parent: UUID? = nil
        for d in 0..<spec.chainDepth {
            let id = try await f.svc.createAction(caseID: caseID, .init(title: "Chain step \(d)", purpose: "Deeper step \(d)", deliverable: "Step \(d) result",
                                                                       responsible: "Ada", parentTaskID: parent), actor: "Ada")
            s.chain.append(id); parent = id
        }
        s.stageSeconds["actions (\(spec.actions)) and a parent chain (\(spec.chainDepth) deep)"] = Date().timeIntervalSince(t)
        t = Date()
        // Money: two accounts and payments/refunds between them, each sourced.
        let a1 = try await f.file.addMoneyAccount(caseID: caseID, identifier: "3391", institution: "Western Coast Bank", currency: "INR", actor: "Ada")
        let a2 = try await f.file.addMoneyAccount(caseID: caseID, identifier: "8804", institution: "Western Coast Bank", currency: "INR", actor: "Ada")
        s.moneyAccounts = [a1, a2]
        for m in 0..<spec.money {
            var input = CaseMoneyRecordInput(kind: m % 5 == 4 ? .refund : .payment, amountText: "INR \(1_000 + m)")
            input.date = String(format: "2026-03-%02d", 1 + m % 28); input.reference = "UTR KS-\(70_000 + m)"
            input.payerAccountID = m % 5 == 4 ? a2 : a1; input.payeeAccountID = m % 5 == 4 ? a1 : a2
            input.sourceVersionID = c.docs[(m * 11) % c.docs.count].version
            s.moneyRecords.append(try await f.file.recordMoney(caseID: caseID, input, actor: "Ada"))
        }
        s.stageSeconds["money records (\(spec.money))"] = Date().timeIntervalSince(t)
        t = Date()
        // Frames: people placed in question frames; one hub person in every question's and action's frame.
        if !people.isEmpty, !c.allegations.isEmpty {
            var placed = Set<String>()
            var i = 0
            while s.placements < spec.frameMembers && i < spec.frameMembers * 3 {
                let person = people[(i * 13) % people.count], q = c.allegations[i % c.allegations.count]
                i += 1
                guard placed.insert("\(q)|\(person)").inserted, person != people[0] else { continue }
                _ = try await f.file.placeInFrame(caseID: caseID, frame: node(.allegation, q), member: node(.person, person), purpose: nil, actor: "Ada")
                s.placements += 1
            }
            s.hub = people[0]
            for anchor in c.allegations.map({ node(.allegation, $0) }) + s.actions.map({ node(.task, $0) }) {
                _ = try await f.file.placeInFrame(caseID: caseID, frame: anchor, member: node(.person, people[0]), purpose: "shared", actor: "Ada")
                s.hubPlacements += 1
            }
        }
        s.stageSeconds["frame memberships (\(s.placements) + hub \(s.hubPlacements))"] = Date().timeIntervalSince(t)
        t = Date()
        // History: a prior case holding some of the same documents, an identifier overlap and references to its questions.
        let prior = try await f.cases.createCase(workspaceID: f.workspaceID, title: "Prior case \(spec.label)", actor: "Ada", at: Date()).id
        s.prior = prior
        var rev = try await f.cases.fetch(caseID: prior)?.caseHeader.revision ?? 1
        for d in c.docs.prefix(min(100, c.docs.count)) {
            rev = try await f.cases.includeSource(caseID: prior, expectedRevision: rev, sourceRef: d.version.uuidString, sourceKind: .sourceVersion, actor: "Ada", at: Date()).revision
        }
        _ = try await f.file.chooseOverlapIdentifier(caseID: caseID, kind: .accountNumber, value: "4412", actor: "Ada")
        let src = try await f.file.addHistorySource(caseID: caseID, kind: .case, originCaseID: prior, purpose: "Earlier matter", scope: .records, actor: "Ada")
        s.historySource = src
        for h in 0..<spec.historyRefs {
            let q = try await f.file.addAllegation(caseID: prior, text: "Prior question \(h)", actor: "Ada")
            s.references.append(try await f.file.addCrossReference(caseID: caseID, historySourceID: src, origin: CaseMapNodeID(caseID: prior, kind: .allegation, id: q),
                                                                   mode: .live, purpose: "Compare \(h)", actor: "Ada"))
        }
        s.stageSeconds["history (prior case, \(spec.historyRefs) references)"] = Date().timeIntervalSince(t)
        return s
    }

    // MARK: Timing

    static func ms(_ body: () throws -> Void) rethrows -> Double {
        let t = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
    }

    static func msAsync(_ body: () async throws -> Void) async rethrows -> Double {
        let t = DispatchTime.now().uptimeNanoseconds
        try await body()
        return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
    }

    static func percentile(_ xs: [Double], _ p: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let rank = Int((p * Double(s.count - 1)).rounded(.up))
        return s[min(max(rank, 0), s.count - 1)]
    }

    /// The 1-, 5- and 15-minute load averages (getloadavg).
    static func loadAverage() -> [Double] {
        var l = [Double](repeating: -1, count: 3)
        let n = getloadavg(&l, 3)
        return n == 3 ? l : []
    }

    static func peakRSSBytes() -> Int {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Int(usage.ru_maxrss)   // bytes on macOS
    }

    static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unavailable" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "unavailable" }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func sysctlInt(_ name: String) -> Int64 {
        var v: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return -1 }
        return v
    }

    static func buildSHA() -> String {
        if let sha = ProcessInfo.processInfo.environment["CASE_MAP_PERF_SHA"], !sha.isEmpty { return sha }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        guard let head = try? String(contentsOf: root.appendingPathComponent(".git/HEAD"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else { return "unknown" }
        if head.hasPrefix("ref: ") {
            let ref = String(head.dropFirst(5))
            return (try? String(contentsOf: root.appendingPathComponent(".git/" + ref), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "unknown (\(ref))"
        }
        return head
    }

    static func ledgerBytes(_ db: Database) async -> Int64 {
        let pages = (try? await db.query("PRAGMA page_count;").first?.int(0)) ?? 0
        let size = (try? await db.query("PRAGMA page_size;").first?.int(0)) ?? 0
        return Int64(pages) * Int64(size)
    }
}

/// One measured case.
struct CaseMapPerfResult: Codable {
    var label = ""
    var documents = 0
    var projectedRecords = 0
    var links = 0
    var collapsedGroupsOverview = 0
    var fixtureTextBytes = 0
    var ledgerBytes: Int64 = 0
    var seedSeconds = 0.0
    var loadColdMs = 0.0
    var loadWarmMs: [Double] = []
    /// A warm ledger read by a NEW service (nothing remembered from an earlier load: the map opened again).
    var loadFreshServiceMs: [Double] = []
    /// Where a fresh warm load spends its time, each read timed on its own.
    var warmStagesMs: [String: Double] = [:]
    /// Chronology entries the incremental refresh reused from the previous projection (not built again).
    var incrementalReusedEntries = 0
    var loadState = ""
    var initialLayoutMs: [Double] = []
    var viewSwitchMs: [Double] = []
    var localFilterMs: [Double] = []
    var selectionMs: [Double] = []
    var cullMs: [Double] = []
    var cullDrawn = 0
    var cullOverCap = 0
    var incrementalLoadMs = 0.0
    var incrementalPlaceNewMs = 0.0
    var incrementalNewRecords = 0
    var existingPositionsMoved = -1
    var searchMs: [String: Double] = [:]
    var searchDocuments: [String: Int] = [:]
    var listPagesToReachAll = 0
    var everyRecordReachable = false
    var peakRSSBytesAfter = 0
    var targets: [String: String] = [:]
    /// S3 — branch expand through the branch-scoped read path (fence only, the last read answers the branch).
    var branchExpandMs: [Double] = []
    var branchCachedAll = false
    /// S13 — v176–v188 records and their separate timings.
    var smartCounts: [String: Int] = [:]
    var seedStagesSeconds: [String: Double] = [:]
    var loadAverageAtStart: [Double] = []
    var loadAverageAtEnd: [Double] = []
    /// Branch action as the person does it: open a frame on the map model and return to the case map.
    var frameOpenMs: [Double] = []
    var frameReturnMs: [Double] = []
    /// Opening the long branch one level after another (the last level's open time is the deepest).
    var chainFrameOpenMs: [Double] = []
    var chainFramesOpened = 0
    var hubFrameCount = 0
    var hubNodeCount = 0
    var briefMs: [Double] = []
    var moneyLedgerMs: [Double] = []
    var moneyGrossTransactions = 0
    var changeTraceMs: [Double] = []
    var changeTraceDeepest = 0
    var overlapMs = 0.0
    var referenceResolveMs: [Double] = []
    var automationObserveMs: [Double] = []
    var automationDispatchMs = 0.0
    var automationDone = 0
    var automationHeld = 0
    var packagePrepareMs = 0.0
    var packageWriteMs = 0.0
    var packageBytes = 0
    var packageReadBackOK = false
    var backupMs = 0.0
    var restoreMs = 0.0
    var restoredCaseFound = false

    func p(_ xs: [Double], _ q: Double) -> Double { CaseMapPerf.percentile(xs, q) }
}

@MainActor
private func perfDefaults() -> UserDefaults {
    let name = "casemap.perf.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name) ?? .standard
    d.removePersistentDomain(forName: name)
    return d
}

@MainActor
@Suite("Case map M9 — performance harness (full run with CASE_MAP_PERF=1)", .serialized)
struct CaseMapPerfHarnessTests {

    /// Measure one case. Correctness checks are #expect; targets are recorded only.
    static func measure(_ spec: CaseMapPerfSpec, search: Bool) async throws -> CaseMapPerfResult {
        var r = CaseMapPerfResult()
        r.label = spec.label
        r.loadAverageAtStart = CaseMapPerf.loadAverage()
        let c = try await CaseMapPerf.seed(spec)
        let f = c.f
        r.documents = c.docs.count
        r.fixtureTextBytes = c.textBytes
        r.seedSeconds = c.seedSeconds
        r.ledgerBytes = await CaseMapPerf.ledgerBytes(f.db)
        let service = CaseMapService(sources: caseMapSources(f))

        // Cold: nothing placed yet (the first layout is computed and stored). Warm: stored positions, same ledger.
        var cold: CaseMapLoad?
        r.loadColdMs = await CaseMapPerf.msAsync { cold = await service.load(caseID: f.caseID, generation: 1) }
        let first = try #require(cold?.projection, "the \(spec.label) case did not load: \(String(describing: cold?.state))")
        r.loadState = String(describing: cold?.state ?? .complete)
        r.projectedRecords = first.nodes.count
        r.links = first.links.count
        func kindCount(_ k: CaseMapRecordKind) -> Int { first.nodes.filter { $0.id.kind == k }.count }
        let base = [CaseMapRecordKind.caseFile, .allegation, .document, .person, .journal].map(kindCount).reduce(0, +)
        #expect(base == spec.expectedRecords, "projected \(base) base records, expected \(spec.expectedRecords)")
        let sm = c.smart
        r.smartCounts = ["reports": kindCount(.report), "reportPoints": kindCount(.reportPoint), "tasks": kindCount(.task), "moneyRecords": kindCount(.moneyRecord),
                         "moneyAccounts": kindCount(.moneyAccount), "framePlacements": sm.placements + sm.hubPlacements, "historyReferences": sm.references.count,
                         "chainDepth": sm.chain.count]
        r.seedStagesSeconds = sm.stageSeconds
        #expect(kindCount(.report) == sm.reports.count && kindCount(.reportPoint) == sm.points.count, "reports \(kindCount(.report)), points \(kindCount(.reportPoint))")
        #expect(kindCount(.task) == sm.actions.count + sm.chain.count && kindCount(.moneyRecord) == sm.moneyRecords.count && kindCount(.moneyAccount) == sm.moneyAccounts.count,
                "tasks \(kindCount(.task)), money \(kindCount(.moneyRecord)) / \(kindCount(.moneyAccount))")
        #expect(first.links.count >= spec.expectedLinks, "links \(first.links.count), at least \(spec.expectedLinks)")
        for g in 2...6 {
            var warm: CaseMapLoad?
            r.loadWarmMs.append(await CaseMapPerf.msAsync { warm = await service.load(caseID: f.caseID, generation: UInt64(g)) })
            #expect(warm?.placements == cold?.placements, "a warm load moved a position")
        }
        for g in 7...9 {
            var fresh: CaseMapLoad?
            r.loadFreshServiceMs.append(await CaseMapPerf.msAsync { fresh = await CaseMapService(sources: caseMapSources(f)).load(caseID: f.caseID, generation: UInt64(g)) })
            #expect(fresh?.placements == cold?.placements, "a fresh load moved a position")
            #expect(fresh?.projection?.nodes == first.nodes && fresh?.projection?.links == first.links, "a fresh load read a different case")
        }
        r.warmStagesMs = try await Self.stages(f, caseMapSources(f))

        // S3 — branch expand on an unchanged case: the revision fence is read, the branch comes from the last read.
        var cachedAll = true
        let anchors = stride(from: 0, to: first.nodes.count, by: max(1, first.nodes.count / 20)).map { first.nodes[$0].id }
        for a in anchors {
            var read: CaseMapBranchRead?
            r.branchExpandMs.append(await CaseMapPerf.msAsync { read = await service.branch(caseID: f.caseID, anchor: a, budget: 2_000) })
            cachedAll = cachedAll && read?.source == .cached && read?.frame != nil
        }
        r.branchCachedAll = cachedAll
        #expect(cachedAll, "a branch of an unchanged case re-read the case")

        // Pure initial layout (what a cold load computes).
        for _ in 0..<3 { r.initialLayoutMs.append(CaseMapPerf.ms { _ = CaseMapLayout.initial(first) }) }

        // The workspace model, as the screen holds it.
        let model = CaseMapWorkspaceModel(caseID: f.caseID, workspace: CaseWorkspaceHolder(caseID: f.caseID, defaults: perfDefaults()))
        await model.refresh(service)
        let p = try #require(model.projection)
        let order: [CaseMapViewKind] = [.overview, .questions, .people, .chronology, .findings, .changes]
        for round in 0..<5 {
            for v in order {
                r.viewSwitchMs.append(CaseMapPerf.ms {
                    model.go(to: .builtIn(v))
                    _ = model.result
                })
            }
            _ = round
        }
        model.go(to: .builtIn(.overview))
        for word in ["invoice", "payment", "event 12", "person 7", "approved", "zzz-none", "inv-1004", "allegation 3"] {
            r.localFilterMs.append(CaseMapPerf.ms { model.search = word; _ = model.result })
        }
        model.search = ""
        r.localFilterMs.append(CaseMapPerf.ms { model.awaitingOnly = true; _ = model.result })
        model.awaitingOnly = false
        let sample = stride(from: 0, to: p.nodes.count, by: max(1, p.nodes.count / 25)).map { p.nodes[$0].id }
        for id in sample {
            r.selectionMs.append(CaseMapPerf.ms {
                model.select(.node(id))
                _ = p.links(of: id)
                _ = model.breadcrumb
            })
        }
        if let res = model.result { r.collapsedGroupsOverview = res.collapsedGroups.count }

        // Layout and culling for a 1440 × 900 viewport: at the stored default and fitted to everything shown.
        let all = CaseMapViewFilter.apply(p, view: .overview, filter: CaseMapFilter(collapsed: []))
        let fitAll = CaseMapLayout.bounds(of: all.shown.compactMap { model.placements[$0]?.point }).map { CaseMapLayout.fit($0, width: 1440, height: 900) } ?? CaseMapViewport()
        for vp in [CaseMapViewport(), fitAll, CaseMapViewport(scale: 1, originX: fitAll.originX, originY: fitAll.originY)] {
            for _ in 0..<5 {
                var cull: (drawn: [CaseMapNodeID], offScreen: Int, overCap: Int) = ([], 0, 0)
                r.cullMs.append(CaseMapPerf.ms {
                    cull = CaseMapLayout.cull(all.shown, positions: model.placements, in: vp.worldRect(width: 1440, height: 900), cap: CaseMapCanvas.drawCap)
                })
                #expect(cull.drawn.count <= CaseMapCanvas.drawCap)
                #expect(cull.drawn.count + cull.offScreen + cull.overCap == all.shown.count, "culling lost items")
                if vp == fitAll { r.cullDrawn = cull.drawn.count; r.cullOverCap = cull.overCap }
            }
        }

        // Reachability: every record through the list with nothing collapsed, page by page.
        let sections = CaseMapListPaging.sections(p, result: all)
        var reached = Set<CaseMapNodeID>()
        var pagesNeeded = 0
        for s in sections {
            let pages = CaseMapListPaging.pagesToReachAll(s.ids.count)
            pagesNeeded = max(pagesNeeded, pages)
            let page = CaseMapListPaging.visible(s.ids, pages: pages)
            #expect(page.remaining == 0)
            reached.formUnion(page.rows)
        }
        r.listPagesToReachAll = pagesNeeded
        // And in the default overview, what is collapsed is held by a group that opens.
        let def = try #require(model.result)
        let heldOrShown = Set(def.shown).union(def.collapsedGroups.flatMap(\.members))
        r.everyRecordReachable = reached == Set(p.nodes.map(\.id)) && def.counts.reconciles && heldOrShown.count + def.counts.filtered + def.counts.hidden == p.nodes.count
        #expect(r.everyRecordReachable, "not every record is reachable through the list and groups")

        // Incremental: 100 new records (chronology entries citing documents) while the map is open.
        let before = model.placements
        for j in 0..<100 {
            let d = c.docs[(j * 13 + 7) % c.docs.count]
            _ = try await f.file.addJournal(caseID: f.caseID, kind: .chronology, text: "Late event \(j) for INV-\(2000 + j)", eventDate: Date(),
                                            evidenceRef: d.version.uuidString, quote: nil, actor: "Ada")
        }
        r.incrementalLoadMs = await CaseMapPerf.msAsync { await model.refresh(service) }
        r.incrementalReusedEntries = await service.lastReusedEntries
        let grown = try #require(model.projection)
        // The incremental result is exactly what a load from scratch reads (same items, links, groups and counts).
        let scratch = try #require(await CaseMapService(sources: caseMapSources(f)).load(caseID: f.caseID, generation: 99).projection)
        #expect(grown.nodes == scratch.nodes && grown.links == scratch.links && grown.groups == scratch.groups, "the incremental refresh differs from a full read")
        r.incrementalNewRecords = grown.nodes.count - p.nodes.count
        r.existingPositionsMoved = before.filter { model.placements[$0.key]?.point != $0.value.point }.count
        #expect(r.incrementalNewRecords == 100)
        #expect(r.existingPositionsMoved == 0, "existing positions moved on an incremental update")
        var stored = before
        stored = stored.filter { grown.node($0.key) != nil }
        r.incrementalPlaceNewMs = CaseMapPerf.ms { _ = CaseMapLayout.placeNew(grown, existing: stored) }

        try await Self.measureSmartMap(&r, c, service: service, model: model)

        if search {
            let searchService = CaseSearchService(sources: CaseSearchSources.live(database: f.db))
            for q in ["invoice", "\"payment was approved\"", "approved NEAR/3 payment", "exact:\"INV-1007\"", "supplier AND NOT zzzqq"] {
                var docsFound = -1
                r.searchMs[q] = await CaseMapPerf.msAsync {
                    let outcome = await searchService.run(caseID: f.caseID, text: q)
                    docsFound = outcome.run?.documentCount ?? -1
                }
                r.searchDocuments[q] = docsFound
                #expect(docsFound >= 0, "search \(q) did not run")
            }
        }
        r.peakRSSBytesAfter = CaseMapPerf.peakRSSBytes()
        r.loadAverageAtEnd = CaseMapPerf.loadAverage()
        r.targets = targets(r, normal: spec.label != "stress")
        return r
    }

    /// S13 — the v176–v188 operations, each timed on its own over the seeded case.
    static func measureSmartMap(_ r: inout CaseMapPerfResult, _ c: CaseMapPerfCase, service: CaseMapService, model: CaseMapWorkspaceModel) async throws {
        let f = c.f, caseID = f.caseID, sm = c.smart
        func node(_ k: CaseMapRecordKind, _ id: UUID) -> CaseMapNodeID { CaseMapNodeID(caseID: caseID, kind: k, id: id) }
        await model.refresh(service)
        let p = try #require(model.projection)
        // Branch actions: open a frame (report, point, question, action) and return to the case map.
        let anchors = (sm.reports.prefix(5).map { node(.report, $0) } + sm.points.prefix(5).map { node(.reportPoint, $0) }
                       + c.allegations.prefix(5).map { node(.allegation, $0) } + sm.actions.prefix(5).map { node(.task, $0) })
        for a in anchors {
            r.frameOpenMs.append(await CaseMapPerf.msAsync { await model.openFrame(a, service: service) })
            #expect(model.frame?.anchor == a, "the frame of \(a) opened")
            r.frameReturnMs.append(await CaseMapPerf.msAsync { await model.returnToFrame(depth: 0, service: service) })
        }
        // The long branch, level after level (no depth ceiling), then back out.
        for step in sm.chain.prefix(60) {
            r.chainFrameOpenMs.append(await CaseMapPerf.msAsync { await model.openFrame(node(.task, step), service: service) })
        }
        r.chainFramesOpened = model.frameStack.count
        #expect(r.chainFramesOpened == min(60, sm.chain.count), "every level of the long branch opened")
        await model.returnToFrame(depth: 0, service: service)
        // The hub: one canonical person, many appearances.
        if let hub = sm.hub {
            let h = node(.person, hub)
            r.hubNodeCount = p.nodes.filter { $0.id == h }.count
            r.hubFrameCount = (c.allegations.map { node(.allegation, $0) } + sm.actions.map { node(.task, $0) })
                .filter { CaseMapFrames.frame(of: $0, in: p)?.contains(h) == true }.count
            #expect(r.hubNodeCount == 1 && r.hubFrameCount == sm.hubPlacements, "hub: \(r.hubNodeCount) node, in \(r.hubFrameCount) of \(sm.hubPlacements) frames")
        }
        // The brief, the money ledger, change propagation.
        for _ in 0..<3 { r.briefMs.append(CaseMapPerf.ms { _ = CaseMapBrief.compute(p) }) }
        for _ in 0..<3 {
            var gross = 0
            r.moneyLedgerMs.append(try await CaseMapPerf.msAsync {
                let l = try await f.file.moneyLedger(caseID: caseID)
                gross = l.outcomes().byCurrency["INR"]?.grossPaid.transactions ?? -1
            })
            r.moneyGrossTransactions = gross
        }
        #expect(r.moneyGrossTransactions == sm.moneyRecords.count - sm.moneyRecords.count / 5, "every payment counted once (\(r.moneyGrossTransactions))")
        if let root = sm.chain.first {
            for _ in 0..<3 {
                var deepest = 0
                r.changeTraceMs.append(CaseMapPerf.ms { deepest = CaseDependencyTraversal.trace(from: node(.task, root), in: p).deepest })
                r.changeTraceDeepest = deepest
            }
        }
        // History: the identifier overlap and the references.
        let history = CaseHistoryReviewService(database: f.db, file: f.file, map: service)
        r.overlapMs = try await CaseMapPerf.msAsync { _ = try await history.identifierOverlaps(caseID: caseID) }
        for ref in sm.references {
            var ok = false
            r.referenceResolveMs.append(try await CaseMapPerf.msAsync { ok = try await history.resolve(caseID: caseID, referenceID: ref).isAvailable })
            #expect(ok, "reference \(ref) resolves")
        }
        // Automation: triggers observed one by one, then one dispatch.
        let auto = CaseAutomationService(database: f.db, caseFiles: f.svc, recipes: CaseAutomationRecipe.builtIn, aiPermitted: { _ in false }, lease: 300)
        let recipe = CaseAutomationRecipe.changedEvidenceReview
        for i in 0..<c.spec.triggers {
            let d = c.docs[(i * 17) % c.docs.count]
            let trig = CaseAutomationTrigger(recipeID: recipe.id, causeAction: recipe.triggers[0], eventKey: "perf-\(i)", title: "Review \(i)", purpose: "Changed evidence",
                                             inputs: [.source(d.version), CaseExaminedInput(kind: "allegation", id: c.allegations[i % c.allegations.count].uuidString)],
                                             requestedBy: "Ada")
            r.automationObserveMs.append(try await CaseMapPerf.msAsync { _ = try await auto.observe(caseID: caseID, trig) })
        }
        var rep: CaseDispatchReport?
        r.automationDispatchMs = try await CaseMapPerf.msAsync { rep = try await auto.dispatch(caseID: caseID, actor: "Ada") }
        r.automationDone = rep?.done.count ?? -1
        r.automationHeld = rep?.held.count ?? -1
        // Export: the whole-case package through the output door, written and read back.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("perf-out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let db = f.db
        let outputs = CaseOutputService(database: f.db, caseFiles: f.svc, custody: { id in
            try await db.query("SELECT source_ref FROM investigation_case_sources WHERE case_id = ? AND in_scope = 1 AND source_kind = 'sourceVersion';", [.uuid(id)])
                .compactMap { $0.uuid(0) }.map { CustodyManifestEntry(sourceVersionID: $0, contentHash: nil, custodyEvents: []) }
        }, pendingDirectory: temp.appendingPathComponent("pending", isDirectory: true))
        var pkg: CaseOutputPackage?
        r.packagePrepareMs = try await CaseMapPerf.msAsync {
            pkg = try await outputs.preparePackage(caseID: caseID, selection: .wholeCase, actor: "Ada") { id in await service.load(caseID: id, generation: 500) }
        }
        let prepared = try #require(pkg)
        r.packageBytes = prepared.data.count
        let url = temp.appendingPathComponent("case.html")
        var receipt: CaseOutputReceipt?
        r.packageWriteMs = await CaseMapPerf.msAsync { receipt = await outputs.write(prepared, to: url) }
        let writtenBytes = try Data(contentsOf: url), pkgManifest = try #require(prepared.manifest)
        r.packageReadBackOK = receipt?.status == .written && CaseOutputArtifactCheck.problem(writtenBytes, manifest: pkgManifest) == nil
        #expect(r.packageReadBackOK, "the package is written and read back: \(receipt?.detail ?? "no receipt")")
        // Backup and restore of the ledger (no originals: the fixture's documents are references only).
        let snapDir = temp.appendingPathComponent("snap", isDirectory: true)
        try FileManager.default.createDirectory(at: snapDir, withIntermediateDirectories: true)
        let backup = temp.appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        r.backupMs = try await CaseMapPerf.msAsync {
            try await f.db.backupSnapshot(to: snapDir.appendingPathComponent("knowledge.sqlite"))
            _ = try BackupService().createCompleteBackup(databaseSnapshot: snapDir.appendingPathComponent("knowledge.sqlite"), originals: [], notIncluded: [],
                                                         destination: backup, schemaVersion: SchemaMigrations.latestVersion, nowEpoch: Date().timeIntervalSince1970)
        }
        let target = temp.appendingPathComponent("restored", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        r.restoreMs = try await CaseMapPerf.msAsync { _ = try await BackupService().restoreComplete(backupFolder: backup, into: target) }
        let restoredURL = target.appendingPathComponent("knowledge.sqlite")
        let restored = try Database(url: restoredURL, key: LedgerFileState.of(restoredURL) == .encrypted ? LedgerKeychain.load() : nil)
        r.restoredCaseFound = (try await restored.query("SELECT COUNT(*) FROM investigation_cases WHERE id = ?;", [.uuid(caseID)]).first?.int(0) ?? 0) == 1
        await restored.close()
        #expect(r.restoredCaseFound, "the restored ledger holds the case")
    }

    /// The §13.3 proposed targets, recorded (never asserted). The stress case has usability criteria, not timings.
    static func targets(_ r: CaseMapPerfResult, normal: Bool) -> [String: String] {
        func verdict(_ ok: Bool, _ measured: String) -> String { (ok ? "met" : "NOT MET") + " (" + measured + ")" }
        var t: [String: String] = [:]
        if normal {
            t["overview cold ≤ 3 s"] = verdict(r.loadColdMs <= 3_000, String(format: "%.0f ms", r.loadColdMs))
            let warm = r.p(r.loadWarmMs, 0.5)
            t["overview warm ≤ 1 s (p50 of 5)"] = verdict(warm <= 1_000, String(format: "%.0f ms", warm))
            t["view switch p95 ≤ 150 ms"] = verdict(r.p(r.viewSwitchMs, 0.95) <= 150, String(format: "%.1f ms", r.p(r.viewSwitchMs, 0.95)))
            t["local filter p95 ≤ 150 ms"] = verdict(r.p(r.localFilterMs, 0.95) <= 150, String(format: "%.1f ms", r.p(r.localFilterMs, 0.95)))
            t["selection p95 ≤ 150 ms"] = verdict(r.p(r.selectionMs, 0.95) <= 150, String(format: "%.1f ms", r.p(r.selectionMs, 0.95)))
            t["cached branch expand p95 ≤ 200 ms"] = verdict(r.p(r.branchExpandMs, 0.95) <= 200 && r.branchCachedAll, String(format: "%.1f ms", r.p(r.branchExpandMs, 0.95)))
            t["branch action (open a frame on the map model) p95 ≤ 200 ms"] = verdict(r.p(r.frameOpenMs, 0.95) <= 200, String(format: "%.1f ms", r.p(r.frameOpenMs, 0.95)))
            t["incremental 100 ≤ 2 s, positions kept"] = verdict(r.incrementalLoadMs <= 2_000 && r.existingPositionsMoved == 0,
                                                                  String(format: "%.0f ms, %d moved", r.incrementalLoadMs, r.existingPositionsMoved))
        } else {
            t["stress usable: culling ≤ \(CaseMapCanvas.drawCap) drawn"] = verdict(r.cullDrawn <= CaseMapCanvas.drawCap, "\(r.cullDrawn) drawn, \(r.cullOverCap) held back and disclosed")
            t["stress usable: every record reachable"] = verdict(r.everyRecordReachable, "list pages to reach all: \(r.listPagesToReachAll)")
            t["stress usable: grouping"] = verdict(r.collapsedGroupsOverview > 0, "\(r.collapsedGroupsOverview) collapsed groups in Overview")
            t["stress incremental: positions kept"] = verdict(r.existingPositionsMoved == 0, "\(r.existingPositionsMoved) moved")
            t["stress usable: deep branch opens level by level"] = verdict(r.chainFramesOpened == min(60, r.smartCounts["chainDepth"] ?? 0), "\(r.chainFramesOpened) levels opened")
            t["stress usable: hub is one record in all its frames"] = verdict(r.hubNodeCount == 1, "\(r.hubFrameCount) frames")
        }
        return t
    }

    static func environment(_ results: [CaseMapPerfResult]) -> [String: String] {
        [
            "hw.model": CaseMapPerf.sysctlString("hw.model"),
            "machdep.cpu.brand_string": CaseMapPerf.sysctlString("machdep.cpu.brand_string"),
            "hw.memsize": String(CaseMapPerf.sysctlInt("hw.memsize")),
            "hw.ncpu": String(CaseMapPerf.sysctlInt("hw.ncpu")),
            "hw.perflevel0.physicalcpu": String(CaseMapPerf.sysctlInt("hw.perflevel0.physicalcpu")),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "kern.osversion": CaseMapPerf.sysctlString("kern.osversion"),
            "build_sha": CaseMapPerf.buildSHA(),
            "configuration": { () -> String in
                #if DEBUG
                return "Debug (unoptimised test build)"
                #else
                return "Release"
                #endif
            }(),
            "schema": String(SchemaMigrations.latestVersion),
            "load_average_1_5_15_at_report": CaseMapPerf.loadAverage().map { String(format: "%.2f", $0) }.joined(separator: " "),
            "measured_at": ISO8601DateFormatter().string(from: Date())
        ]
    }

    static func markdown(_ env: [String: String], _ results: [CaseMapPerfResult]) -> String {
        var out = "# Case map performance measurement (plan §13.3)\n\n"
        out += "Generated by `KalsmritikoshTests/CaseMapPerfHarnessTests.swift` (CASE_MAP_PERF=1). Raw timings are in the JSON file of the same name. "
        out += "The §13.3 numbers are proposed engineering targets; a miss is recorded as NOT MET and not tuned away.\n\n"
        out += "## Environment\n\n| Key | Value |\n|---|---|\n"
        for k in env.keys.sorted() { out += "| \(k) | \(env[k] ?? "") |\n" }
        for r in results {
            out += "\n## \(r.label)\n\n"
            out += "Fixture: \(r.documents) documents, \(r.projectedRecords) projected records, \(r.links) links; \(r.fixtureTextBytes) bytes of document text; ledger \(r.ledgerBytes) bytes; seeded in \(String(format: "%.1f", r.seedSeconds)) s. Load state: \(r.loadState).\n\n"
            out += "| Measurement | p50 | p95 | n |\n|---|---|---|---|\n"
            func row(_ name: String, _ xs: [Double]) -> String { String(format: "| %@ | %.1f ms | %.1f ms | %d |\n", name, r.p(xs, 0.5), r.p(xs, 0.95), xs.count) }
            out += String(format: "| Projection load, cold (first layout computed and stored) | %.1f ms | — | 1 |\n", r.loadColdMs)
            out += row("Projection load, warm (same service: incremental journal read, unchanged entries reused)", r.loadWarmMs)
            out += row("Projection load, warm, new service (everything read and built again)", r.loadFreshServiceMs)
            out += row("Initial layout (pure)", r.initialLayoutMs)
            out += row("View switch (model + view result)", r.viewSwitchMs)
            out += row("Branch expand (cached, fence read)", r.branchExpandMs)
            out += row("Local filter (Find on this map / Waiting for me)", r.localFilterMs)
            out += row("Selection (select + links + breadcrumb)", r.selectionMs)
            out += row("Viewport culling 1440×900", r.cullMs)
            out += row("Branch action: open a frame on the map model (S13)", r.frameOpenMs)
            out += row("Branch action: return to the case map (S13)", r.frameReturnMs)
            out += row("Long branch: open each next level (S13)", r.chainFrameOpenMs)
            out += row("Brief of the whole case (pure, S13)", r.briefMs)
            out += row("Money ledger read + outcomes (S13)", r.moneyLedgerMs)
            out += row("Change propagation from the chain's root (pure, S13)", r.changeTraceMs)
            out += row("History reference resolve (S13)", r.referenceResolveMs)
            out += row("Automation: observe one trigger (S13)", r.automationObserveMs)
            out += String(format: "| History: identifier overlap across cases (S13) | %.1f ms | — | 1 |\n", r.overlapMs)
            out += String(format: "| Automation: one dispatch (%d done, %d held by budget) (S13) | %.1f ms | — | 1 |\n", r.automationDone, r.automationHeld, r.automationDispatchMs)
            out += String(format: "| Export: whole-case package prepared (%d bytes) (S13) | %.1f ms | — | 1 |\n", r.packageBytes, r.packagePrepareMs)
            out += String(format: "| Export: package written and read back (S13) | %.1f ms | — | 1 |\n", r.packageWriteMs)
            out += String(format: "| Backup: ledger snapshot + complete backup (S13) | %.1f ms | — | 1 |\n", r.backupMs)
            out += String(format: "| Restore: complete restore to a fresh folder (S13) | %.1f ms | — | 1 |\n", r.restoreMs)
            out += String(format: "| Incremental: 100 new records, reload | %.1f ms | — | 1 |\n", r.incrementalLoadMs)
            out += String(format: "| Incremental: placeNew only | %.1f ms | — | 1 |\n", r.incrementalPlaceNewMs)
            for (q, t) in r.searchMs.sorted(by: { $0.key < $1.key }) {
                out += String(format: "| Case search `%@` (%d documents) | %.1f ms | — | 1 |\n", q, r.searchDocuments[q] ?? -1, t)
            }
            if !r.warmStagesMs.isEmpty {
                out += "\nWhere a fresh warm load spends its time (each read timed on its own; the parts overlap the whole snapshot):\n\n| Stage | ms |\n|---|---|\n"
                for (k, v) in r.warmStagesMs.sorted(by: { $0.value > $1.value }) { out += String(format: "| %@ | %.1f |\n", k, v) }
                out += "\nIncremental refresh: \(r.incrementalReusedEntries) chronology entries reused from the previous projection.\n"
            }
            out += "\nCulling at fit-all: \(r.cullDrawn) drawn, \(r.cullOverCap) held back (disclosed on screen). Overview collapsed groups: \(r.collapsedGroupsOverview). "
            out += "List pages to reach every record: \(r.listPagesToReachAll). Every record reachable: \(r.everyRecordReachable). New records: \(r.incrementalNewRecords); existing positions moved: \(r.existingPositionsMoved). "
            out += "Peak resident memory of the test process after this case: \(r.peakRSSBytesAfter / 1_048_576) MiB.\n\n"
            out += "v176–v188 records: " + r.smartCounts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            out += ". Long branch: \(r.chainFramesOpened) levels opened; deepest change propagation \(r.changeTraceDeepest). Hub person: \(r.hubNodeCount) record in \(r.hubFrameCount) frames. "
            out += "Money: \(r.moneyGrossTransactions) payments counted once. Package read back: \(r.packageReadBackOK). Restored case found: \(r.restoredCaseFound).\n\n"
            out += "Load average (1/5/15 min) at the start of this case: " + r.loadAverageAtStart.map { String(format: "%.1f", $0) }.joined(separator: " / ")
            out += "; at the end: " + r.loadAverageAtEnd.map { String(format: "%.1f", $0) }.joined(separator: " / ") + " (hw.ncpu " + String(CaseMapPerf.sysctlInt("hw.ncpu")) + "). "
            out += ((r.loadAverageAtStart.first ?? 0) > Double(CaseMapPerf.sysctlInt("hw.ncpu")) || (r.loadAverageAtEnd.first ?? 0) > Double(CaseMapPerf.sysctlInt("hw.ncpu")))
                ? "**The Mac was loaded beyond its core count during this case: these timings are unreliable as capacity figures (they over-state the cost).**\n\n"
                : "The load stayed within the core count.\n\n"
            out += "Seeding, by family (seconds): " + r.seedStagesSeconds.sorted { $0.key < $1.key }.map { String(format: "%@ %.1f", $0.key, $0.value) }.joined(separator: "; ") + ".\n\n"
            out += "| Target | Result |\n|---|---|\n"
            for k in r.targets.keys.sorted() { out += "| \(k) | \(r.targets[k] ?? "") |\n" }
        }
        out += "\n## Limits\n\n- Timings are from the Debug test host in the XCTest process, not from a signed Release app with the window on screen; no frame times were profiled (pan/zoom/drag smoothness is not measured here).\n"
        out += "- The fixture is generated text records typed as PDF/DOCX/EML/PNG by name; intake, parsing and OCR are not part of these timings.\n"
        out += "- The view-switch, filter and selection timings cover the model and the shared view filter, not SwiftUI rendering.\n"
        return out
    }

    @Test("Harness smoke (always): seeds, loads, switches, filters, places 100 new records without moving any, culls and reaches every record")
    func smoke() async throws {
        let r = try await Self.measure(.smoke, search: true)
        #expect(r.projectedRecords >= CaseMapPerfSpec.smoke.expectedRecords && r.smartCounts["reportPoints"] == 6 && r.chainFramesOpened == 8)
        #expect(r.existingPositionsMoved == 0 && r.everyRecordReachable)
        #expect(!Self.markdown(Self.environment([r]), [r]).isEmpty)
    }

    /// One full case, reported on its own (so a stress run that stops cannot lose the normal case's numbers).
    static func fullRun(_ spec: CaseMapPerfSpec, search: Bool) async throws {
        let r = try await Self.measure(spec, search: search)
        let env = Self.environment([r])
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        struct Report: Codable { let environment: [String: String]; let results: [CaseMapPerfResult] }
        let json = String(decoding: try enc.encode(Report(environment: env, results: [r])), as: UTF8.self)
        let md = Self.markdown(env, [r])
        print("===CASE_MAP_PERF_BEGIN case-map-perf-\(spec.label).json===\n" + json + "\n===CASE_MAP_PERF_END===")
        print("===CASE_MAP_PERF_BEGIN case-map-perf-\(spec.label).md===\n" + md + "===CASE_MAP_PERF_END===")
        if let out = ProcessInfo.processInfo.environment["CASE_MAP_PERF_OUT"], !out.isEmpty {
            let dir = URL(fileURLWithPath: out, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try json.write(to: dir.appendingPathComponent("case-map-perf-\(spec.label).json"), atomically: true, encoding: .utf8)
            try md.write(to: dir.appendingPathComponent("case-map-perf-\(spec.label).md"), atomically: true, encoding: .utf8)
        }
    }

    /// Where a warm load spends its time: each read the service makes, timed on its own (same ledger, warm).
    static func stages(_ f: CaseFileTests.Fixture, _ sources: CaseMapSources) async throws -> [String: Double] {
        var t: [String: Double] = [:]
        let caseID = f.caseID
        t["fence"] = try await CaseMapPerf.msAsync { _ = try await sources.map.revisionFence(caseID: caseID) }
        var custody: [CustodyManifestEntry] = []
        t["custody"] = try await CaseMapPerf.msAsync { custody = try await sources.custody?(caseID) ?? [] }
        let c = custody
        t["snapshot as the map reads it (whole)"] = try await CaseMapPerf.msAsync { _ = try await sources.snapshot(caseID, c) }
        let file = f.file, svc = f.svc
        t["snapshot.header"] = try await CaseMapPerf.msAsync { _ = try await svc.caseHeader(caseID) }
        t["snapshot.grid"] = try await CaseMapPerf.msAsync { _ = try await file.allegationEvidence(caseID: caseID) }
        t["snapshot.journal (full read; the map reads new rows only)"] = try await CaseMapPerf.msAsync { _ = try await file.journal(caseID: caseID) }
        t["snapshot.reportItems"] = try await CaseMapPerf.msAsync { _ = try await file.reportItems(caseID: caseID) }
        t["snapshot.profile"] = try await CaseMapPerf.msAsync { _ = try await file.profile(caseID: caseID) }
        t["snapshot.allegations"] = try await CaseMapPerf.msAsync { _ = try await file.allegations(caseID: caseID) }
        t["snapshot.tasks"] = try await CaseMapPerf.msAsync { _ = try await svc.caseTasks(caseID: caseID) }
        t["snapshot.people"] = try await CaseMapPerf.msAsync { _ = try await file.people(caseID: caseID) }
        t["snapshot.actions (full read; the map no longer reads it)"] = try await CaseMapPerf.msAsync { _ = try await file.actions(caseID: caseID) }
        t["snapshot.attestations"] = try await CaseMapPerf.msAsync { _ = try await file.attestations(caseID: caseID) }
        t["snapshot.exhibits"] = try await CaseMapPerf.msAsync { _ = try await file.exhibits(caseID: caseID, includeWithdrawn: true) }
        let versions = Set(custody.map(\.sourceVersionID))
        var objects: [UUID: UUID] = [:]
        t["objectsByVersion"] = try await CaseMapPerf.msAsync { objects = try await sources.objectsByVersion(versions) }
        let o = objects
        var documents: [CaseMapDocument] = []
        t["documents"] = try await CaseMapPerf.msAsync { documents = try await sources.map.documents(versionIDs: versions, objectsByVersion: o) }
        var contradictions: [CaseContradictionReviewItem] = [], hypotheses: [CaseMapHypothesis] = [], requests: [EvidenceRequestFile] = []
        var links: [CaseMapInvestigatorLink] = []
        t["contradictions"] = try await CaseMapPerf.msAsync { contradictions = try await sources.contradictions?(caseID) ?? [] }
        t["hypotheses"] = try await CaseMapPerf.msAsync { hypotheses = try await sources.hypotheses?(caseID) ?? [] }
        t["requests"] = try await CaseMapPerf.msAsync { requests = try await sources.requests?(caseID) ?? [] }
        t["investigatorLinks"] = try await CaseMapPerf.msAsync { links = try await sources.map.links(caseID: caseID) }
        var stored: [CaseMapNodeID: CaseMapPlacement] = [:]
        t["layout read"] = try await CaseMapPerf.msAsync { stored = try await sources.map.layout(caseID: caseID) }
        t["views"] = try await CaseMapPerf.msAsync { _ = try await sources.map.views(caseID: caseID) }
        guard let snap = try await sources.snapshot(caseID, c) else { return t }
        let input = CaseMapInput(snapshot: snap, documents: documents, contradictions: contradictions, hypotheses: hypotheses,
                                 requests: requests, investigatorLinks: links)
        var projection: CaseMapProjection?
        t["project (pure)"] = CaseMapPerf.ms { projection = CaseMapProjector.project(input) }
        if let p = projection {
            t["placeNew, all stored (pure)"] = CaseMapPerf.ms { _ = CaseMapLayout.placeNew(p, existing: stored) }
        }
        return t
    }

    @Test("Full §13.3 measurement, normal case: 500 documents, ~2,000 records, ~3,000 links (CASE_MAP_PERF only)", .enabled(if: perfEnabled), .timeLimit(.minutes(30)))
    func fullMeasurementNormal() async throws { try await Self.fullRun(.normal, search: true) }

    @Test("Full §13.3 measurement, stress case: 5,000 documents, ~50,000 records (CASE_MAP_PERF only)", .enabled(if: perfEnabled), .timeLimit(.minutes(60)))
    func fullMeasurementStress() async throws { try await Self.fullRun(.stress, search: true) }
}
