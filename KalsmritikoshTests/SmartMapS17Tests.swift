//
//  SmartMapS17Tests.swift
//  KalsmritikoshTests
//
//  Smart-map slice S17 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md §25 PERF, milestone M6):
//  - PERF-01: named workloads (sizes, source bytes, pages, OCR images, depth, users, update rate) and the hardware /
//    build / load record, written with every measurement;
//  - PERF-02: stages timed apart — intake, parse/OCR, index, projection, RENDERING (the real CaseMapCanvas drawn by
//    SwiftUI's ImageRenderer and an NSHostingView laid out and displayed in an off-screen window, not the model
//    projection), navigation, change propagation;
//  - PERF-03: first use reads no branch's detail (no frame positions, no traversal) while every record is reachable;
//    a branch is read on demand, within a budget, with an explicit continuation;
//  - PERF-05: a large intake through the app's bounded lanes (LaneScheduler + BoundedFanOut) while navigation reads and
//    the main thread are timed;
//  - PERF-08: parser / archive temporary copies are refused before writing when the disk cannot hold them, with the
//    recovery choices; the custody record stays (nothing dropped);
//  - PERF-10: days of work added to an open case: no stored position moves, only the new records are placed and
//    stored, and the chronology is reused rather than rebuilt;
//  - PERF-11: every non-literal truncation point of the case map, case file and case search is listed with how it
//    discloses what it did not show (a source guard), and literal SQL row caps across the app are inventoried.
//  The full measurement runs only under the existing CASE_MAP_PERF switch (env or the git-ignored trigger file); the
//  ungated tests are small. Synthetic data only; no network, no model. Dates carry explicit time zones.
//

import AppKit
import Foundation
import os
import SwiftUI
import Testing
@testable import Kalsmritikosh

/// The same switch as CaseMapPerfHarnessTests: CASE_MAP_PERF=1, or the trigger file build/perf/RUN_CASE_MAP_PERF.
private let s17PerfEnabled: Bool = {
    if ProcessInfo.processInfo.environment["CASE_MAP_PERF"] == "1" { return true }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    return FileManager.default.fileExists(atPath: root.appendingPathComponent("build/perf/RUN_CASE_MAP_PERF").path)
}()

private let s17Root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

private func s17Scratch(_ tag: String) throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("s17-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func s17Count(_ db: Database, _ sql: String, _ b: [SQLValue] = []) async throws -> Int {
    Int(try await db.query(sql, b).first?.int(0) ?? -1)
}

@MainActor
private func s17Defaults() -> UserDefaults {
    let name = "casemap.s17.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name) ?? .standard
    d.removePersistentDomain(forName: name)
    return d
}

// MARK: - Intake corpus (PERF-01 / PERF-02 / PERF-05)

/// A generated archive: text-like files of several formats, multi-page text PDFs and images carrying text (OCR).
struct S17Corpus {
    var urls: [URL] = []
    var bytes = 0
    var pdfPages = 0
    var ocrImages = 0
    var byKind: [String: Int] = [:]

    static let utc = TimeZone(identifier: "UTC") ?? .current

    static func body(_ i: Int) -> String {
        "Payment approved for invoice INV-\(5000 + i) by the finance lead. Witness Ann Lee\(i % 50) confirmed the supplier was paid on "
            + "\(1 + i % 28) March 2026. Account 44\(i % 97) received INR \(1_000 + i).00. "
            + String(repeating: "The ledger entry for batch \(i) was reviewed and matched the bank statement line. ", count: 8)
    }

    @MainActor
    static func write(into dir: URL, textLike: Int, pdfs: Int, pagesPerPDF: Int, images: Int) throws -> S17Corpus {
        var c = S17Corpus()
        func add(_ name: String, _ data: Data, kind: String) throws {
            let url = dir.appendingPathComponent(name)
            try data.write(to: url)
            c.urls.append(url); c.bytes += data.count; c.byKind[kind, default: 0] += 1
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = utc
        df.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        for i in 0..<textLike {
            let t = body(i)
            switch i % 5 {
            case 0: try add("note-\(i).txt", Data(t.utf8), kind: "txt")
            case 1:
                let date = df.string(from: Date(timeIntervalSince1970: 1_740_000_000 + Double(i) * 3_600))
                let mail = "From: Finance <finance\(i % 7)@supplier.example>\nTo: Audit <audit@case.example>\nSubject: Batch \(i) payment\nDate: \(date)\n\n\(t)\n"
                try add("mail-\(i).eml", Data(mail.utf8), kind: "eml")
            case 2: try add("memo-\(i).md", Data("# Memo \(i)\n\n\(t)\n".utf8), kind: "md")
            case 3: try add("page-\(i).html", Data("<html><body><h1>Batch \(i)</h1><p>\(t)</p></body></html>".utf8), kind: "html")
            default: try add("ledger-\(i).csv", Data("date,reference,amount\n2026-03-\(String(format: "%02d", 1 + i % 28)),INV-\(5000 + i),\(1_000 + i).00\n".utf8), kind: "csv")
            }
        }
        for i in 0..<pdfs {
            let pages = (0..<pagesPerPDF).map { "Statement \(i), page \($0 + 1). " + body(i * 10 + $0) }
            try add("statement-\(i).pdf", pdf(pages), kind: "pdf")
            c.pdfPages += pagesPerPDF
        }
        for i in 0..<images {
            guard let png = image("Receipt \(i): INV-\(5000 + i) paid INR \(1_000 + i).00 on \(1 + i % 28) March 2026") else { continue }
            try add("scan-\(i).png", png, kind: "png")
            c.ocrImages += 1
        }
        return c
    }

    /// A text PDF drawn with Core Graphics (one page per string).
    static func pdf(_ pages: [String]) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        for text in pages {
            ctx.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            (text as NSString).draw(in: CGRect(x: 54, y: 54, width: 504, height: 684), withAttributes: [.font: NSFont.systemFont(ofSize: 12)])
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    /// A PNG of black text on white (what OCR reads).
    static func image(_ text: String) -> Data? {
        let w = 1200, h = 220
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        (text as NSString).draw(at: CGPoint(x: 30, y: 90), withAttributes: [.font: NSFont.systemFont(ofSize: 34), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}

/// Per-file intake times collected from the bounded fan-out.
actor S17IntakeLog {
    var fileMs: [Double] = []
    var byKindMs: [String: [Double]] = [:]
    var failures = 0
    var finished = false
    func add(_ ms: Double, ok: Bool, kind: String = "") { fileMs.append(ms); byKindMs[kind, default: []].append(ms); if !ok { failures += 1 } }
    func finish() { finished = true }
}

/// How late the main actor wakes from a short sleep: the time it was kept from running (a hang shows as a long gap).
@MainActor
final class S17MainLag {
    var samples: [Double] = []
    private var running = true
    private var task: Task<Void, Never>?
    func start() {
        task = Task { @MainActor [weak self] in
            while self?.running == true {
                let t = DispatchTime.now().uptimeNanoseconds
                try? await Task.sleep(nanoseconds: 5_000_000)
                let late = Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6 - 5
                self?.samples.append(max(0, late))
            }
        }
    }
    func stop() async { running = false; await task?.value }
}

enum S17 {
    /// An ingest pipeline over `db` (the app's real coordinator; custody by reference, no vectors, no model).
    @MainActor
    static func coordinator(_ db: Database, dir: URL, metrics: PipelineMetrics?) throws -> IngestCoordinator {
        let vault = EvidenceVault(root: dir.appendingPathComponent("vault", isDirectory: true))
        return IngestCoordinator(
            universalRegistry: try UniversalParserRegistryBuilder.standard(ocr: VisionOCR()),
            entityExtractor: NLEntityExtractor(), entityLinker: EntityLinker(), eventExtractor: RuleEventExtractor(),
            files: FilesRepository(database: db), objects: KnowledgeObjectRepository(database: db), chunks: ChunksRepository(database: db),
            pipelineMetrics: metrics, evidenceStore: EvidenceStore(database: db), ingestAttempts: IngestAttemptsRepository(database: db),
            sourceRelations: SourceRelationsRepository(database: db),
            intakeCoordinator: UniversalSourceIntakeCoordinator(repository: CanonicalSourceIntakeRepository(database: db, vault: vault)),
            custodyModeOverride: .referenced)
    }

    /// The app's own bounds: lane capacities from this Mac, and the watcher's in-flight limit.
    static func lanes() -> (scheduler: LaneScheduler, inFlight: Int, cpu: Int) {
        let caps = LaneScheduler.defaultCapacities(processorCount: ProcessInfo.processInfo.activeProcessorCount,
                                                   availableRAMBytes: Int64(ProcessInfo.processInfo.physicalMemory))
        return (LaneScheduler(capacities: caps), BoundedFanOut.watcherLimit(capacities: caps), caps[.cpu] ?? 1)
    }

    /// Start the intake in the background: bounded fan-out, each file inside a lane, as the folder watcher runs it.
    static func startIntake(_ urls: [URL], coordinator: IngestCoordinator, log: S17IntakeLog) -> Task<Void, Never> {
        let l = lanes()
        let scheduler = l.scheduler
        return Task.detached(priority: .utility) {
            await BoundedFanOut.forEach(urls, maxInFlight: l.inFlight) { url in
                let lane: ResourceLane = url.pathExtension == "png" ? .neuralEngine : .cpu
                await scheduler.withLane(lane) {
                    let t = DispatchTime.now().uptimeNanoseconds
                    var ok = true
                    do { _ = try await coordinator.ingest(fileAt: url) } catch {
                        KalsmritikoshLog.ingestion.error("S17 intake failed: \(error.localizedDescription, privacy: .public)")
                        ok = false
                    }
                    await log.add(Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6, ok: ok, kind: url.pathExtension)
                }
            }
            await log.finish()
        }
    }

    // MARK: Rendering (PERF-02)

    struct Render: Codable {
        var ms = 0.0
        var inkedPixels = 0
        var width = 0
        var height = 0
    }

    /// The real case-map canvas drawn to pixels by SwiftUI (ImageRenderer runs the view's body, its layout and the
    /// Canvas drawing of every drawn item and link) — not the model projection.
    @MainActor
    static func render(_ model: CaseMapWorkspaceModel, width: Int = 1440, height: Int = 900) -> Render? {
        guard let p = model.projection, let result = model.result else { return nil }
        let view = CaseMapCanvas(map: model, projection: p, result: result, repository: nil, actor: "Ada")
            .frame(width: CGFloat(width), height: CGFloat(height))
        var image: CGImage?
        let ms = CaseMapPerf.ms {
            let r = ImageRenderer(content: view)
            r.scale = 1
            image = r.cgImage
        }
        guard let image else { return nil }
        return Render(ms: ms, inkedPixels: inked(image), width: image.width, height: image.height)
    }

    /// The AppKit path: the canvas in an NSHostingView inside an off-screen window (never ordered front), laid out and
    /// displayed into a bitmap. Returns layout and display times.
    @MainActor
    static func host(_ model: CaseMapWorkspaceModel, width: Int = 1440, height: Int = 900) -> (layoutMs: Double, displayMs: Double)? {
        guard let p = model.projection, let result = model.result else { return nil }
        let host = NSHostingView(rootView: CaseMapCanvas(map: model, projection: p, result: result, repository: nil, actor: "Ada"))
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = frame
        let layout = CaseMapPerf.ms { host.layoutSubtreeIfNeeded() }
        var display = 0.0
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            display = CaseMapPerf.ms { host.cacheDisplay(in: host.bounds, to: rep) }
        }
        window.contentView = nil
        window.close()
        return (layout, display)
    }

    /// Pixels with any ink (sampled every 2nd pixel each way).
    static func inked(_ image: CGImage) -> Int {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let base = ctx.data else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = base.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var n = 0
        for y in stride(from: 0, to: h, by: 2) {
            for x in stride(from: 0, to: w, by: 2) where px[(y * w + x) * 4 + 3] > 0 { n += 1 }
        }
        return n
    }

    // MARK: Growth (PERF-10)

    struct Day: Codable {
        var day = 0
        var added = 0
        var refreshMs = 0.0
        var freshLoadMs = 0.0
        var reusedEntries = 0
        var newPlacementsStored = 0
        var newRecords = 0
        var positionsMoved = -1
        var renderMs = 0.0
        var peakRSSMiB = 0
    }

    /// One day of work on an open case: chronology entries, people, a question, evidence links, actions and money records.
    static func addDay(_ c: CaseMapPerfCase, day: Int, journal: Int, people: Int, grid: Int, actions: Int, money: Int) async throws -> Int {
        let f = c.f
        var added = 0
        for j in 0..<journal {
            let d = c.docs[(day * 97 + j * 13) % c.docs.count]
            _ = try await f.file.addJournal(caseID: f.caseID, kind: .chronology, text: "Day \(day) event \(j)", eventDate: Date(timeIntervalSince1970: 1_760_000_000 + Double(day * 86_400 + j)),
                                            evidenceRef: d.version.uuidString, quote: nil, actor: "Ada")
            added += 1
        }
        for p in 0..<people {
            _ = try await f.file.addPerson(caseID: f.caseID, name: "Day \(day) person \(p)", role: .witness, entityID: nil, contact: nil, notes: nil, actor: "Ada")
            added += 1
        }
        let q = try await f.file.addAllegation(caseID: f.caseID, text: "Day \(day): was batch \(day) paid twice?", actor: "Ada")
        added += 1
        for g in 0..<grid {
            let d = c.docs[(day * 31 + g * 7) % c.docs.count]
            _ = try await f.svc.linkEvidence(caseID: f.caseID, allegationID: q, evidenceRef: d.version.uuidString, label: nil, stance: .supports, note: nil,
                                             allowDuplicate: true, actor: "Ada")
        }
        for a in 0..<actions {
            _ = try await f.svc.createAction(caseID: f.caseID, .init(title: "Day \(day) action \(a)", purpose: "Check", deliverable: "A note", responsible: "Ada",
                                                                     servesQuestions: [q]), actor: "Ada")
            added += 1
        }
        if money > 0 {
            let acct = try await f.file.addMoneyAccount(caseID: f.caseID, identifier: "D\(day)", institution: "Western Coast Bank", currency: "INR", actor: "Ada")
            added += 1
            for m in 0..<money {
                var input = CaseMoneyRecordInput(kind: .payment, amountText: "INR \(2_000 + m)")
                input.date = String(format: "2026-04-%02d", 1 + (day + m) % 28); input.reference = "UTR D\(day)-\(m)"
                input.payerAccountID = acct
                input.sourceVersionID = c.docs[(day + m) % c.docs.count].version
                _ = try await f.file.recordMoney(caseID: f.caseID, input, actor: "Ada")
                added += 1
            }
        }
        return added
    }

    static func rootLayoutRows(_ db: Database, _ caseID: UUID) async throws -> Int {
        try await s17Count(db, "SELECT COUNT(*) FROM case_map_layout WHERE case_id = ? AND frame_key = '';", [.uuid(caseID)])
    }

    /// Grow an open case day by day; each day is refreshed incrementally, compared with a fresh full read and drawn.
    @MainActor
    static func grow(_ c: CaseMapPerfCase, model: CaseMapWorkspaceModel, service: CaseMapService, days: Int,
                     journal: Int, people: Int, grid: Int, actions: Int, money: Int) async throws -> [Day] {
        var out: [Day] = []
        for day in 1...days {
            let before = model.placements
            let nodesBefore = model.projection?.nodes.count ?? 0
            let rowsBefore = try await rootLayoutRows(c.f.db, c.f.caseID)
            var d = Day()
            d.day = day
            d.added = try await addDay(c, day: day, journal: journal, people: people, grid: grid, actions: actions, money: money)
            d.refreshMs = await CaseMapPerf.msAsync { await model.refresh(service) }
            d.reusedEntries = await service.lastReusedEntries
            let rowsAfter = try await rootLayoutRows(c.f.db, c.f.caseID)
            d.newPlacementsStored = rowsAfter - rowsBefore
            d.newRecords = (model.projection?.nodes.count ?? 0) - nodesBefore
            d.positionsMoved = before.filter { model.placements[$0.key]?.point != $0.value.point }.count
            let sources = caseMapSources(c.f)
            d.freshLoadMs = await CaseMapPerf.msAsync { _ = await CaseMapService(sources: sources).load(caseID: c.f.caseID, generation: UInt64(10_000 + day)) }
            d.renderMs = render(model)?.ms ?? -1
            d.peakRSSMiB = CaseMapPerf.peakRSSBytes() / 1_048_576
            out.append(d)
        }
        return out
    }
}

// MARK: - PERF-11: the truncation inventory

/// Every non-literal `.prefix(...)` cap in the case map / case file / case search, with what discloses the rest.
/// A new cap must be added here with its disclosure, or the guard fails.
let s17TruncationInventory: [String: String] = [
    "Kalsmritikosh/Investigate/CaseFile/CaseChangeFeed.swift|prefix(Self.displayCap)": "CaseChangeFeedLoad.omitted counts the changes not shown",
    "Kalsmritikosh/Investigate/CaseFile/CaseDeconfliction.swift|prefix(cap)": "CaseDeconflictionReport.totalOverlapping and capped",
    "Kalsmritikosh/Investigate/CaseFile/CaseMapLayout.swift|prefix(cap)": "cull returns offScreen and overCap; the canvas discloses items held back",
    "Kalsmritikosh/Investigate/CaseFile/CaseReasoning.swift|prefix(contextLength)": "context words around a quote (display of a sentence, not a result set)",
    "Kalsmritikosh/Investigate/CaseFile/CaseRecordSearch.swift|prefix(max)": "snippets per hit; CaseRecordSearchHit.occurrences counts every match",
    "Kalsmritikosh/Investigate/CaseFile/CaseSourceDependence.swift|prefix(occurrenceLimit)": "CaseMapSourceDependence.occurrenceTotal counts every citing record",
    "Kalsmritikosh/Retrieval/CaseSearchService.swift|prefix(options.maxDocuments)": "documents beyond the cap are listed as notReached with stoppedEarly; the run continues by resume",
    "Kalsmritikosh/UI/CaseMapAccessibility.swift|prefix(n)": "CaseMapListPaging.visible returns remaining; the list offers Show more",
    "Kalsmritikosh/UI/CaseMapWorkspaceModel.swift|prefix(depth)": "returning to a level of the frame breadcrumb (navigation, not a result set)"
]

/// Literal SQL row caps of 100 rows or more across the app (`LIMIT n`), as found by S17. Outside the case map these were
/// inventoried, not changed; a new one fails the guard until it is listed with how it behaves.
let s17SQLLimitInventory: [String: String] = [
    "Kalsmritikosh/UI/RelationshipGraphView.swift|LIMIT 400": "entity graph view: strongest 400 pairs (outside the case map; not audited for disclosure)",
    "Kalsmritikosh/UI/EmailAuthenticityView.swift|LIMIT 500": "newest 500 messages (outside the case map; not audited for disclosure)",
    "Kalsmritikosh/App/AppState.swift|LIMIT 3000": "background batch (re-run on the next pass)",
    "Kalsmritikosh/App/AppState+LivingDossier.swift|LIMIT 200": "dossier sample (outside the case map; not audited for disclosure)",
    "Kalsmritikosh/App/AppState+PostIngest.swift|LIMIT 5000": "background batch (re-run on the next pass)",
    "Kalsmritikosh/Storage/Repositories/ExtractionProvenanceRepository.swift|LIMIT 20000": "provenance passages of one version (outside the case map; not audited for disclosure)",
    "Kalsmritikosh/Storage/Repositories/EntitiesRepository.swift|LIMIT 500": "entity listing (outside the case map; not audited for disclosure)",
    "Kalsmritikosh/Storage/Repositories/EventsRepository.swift|LIMIT 200": "events of one document (outside the case map; not audited for disclosure)",
    "Kalsmritikosh/Storage/Repositories/GenericFactRepository.swift|LIMIT 500": "fact lookup (outside the case map; not audited for disclosure)",
    "Kalsmritikosh/Knowledge/Organise/DocumentSimilarity.swift|LIMIT 200": "chunks sampled for similarity (a sample by design)",
    "Kalsmritikosh/Knowledge/Watchlist/BatchScreening.swift|LIMIT 2000": "screening batch (outside the case map; not audited for disclosure)",
    "Kalsmritikosh/Knowledge/Watchlist/BatchScreening.swift|LIMIT 20000": "screening batch (outside the case map; not audited for disclosure)",
    "Kalsmritikosh/Knowledge/Watchlist/BatchScreening.swift|LIMIT 400": "screening passages (outside the case map; not audited for disclosure)",
    "Kalsmritikosh/Knowledge/Topics/CommunitySummarizer.swift|LIMIT 500": "summary sample (a sample by design)",
    "Kalsmritikosh/Sync/AppState+Sync.swift|LIMIT 200": "newest 200 open sync conflicts (outside the case map; not audited for disclosure)"
]

private func s17SwiftFiles(_ dirs: [String]) -> [String] {
    var out: [String] = []
    for d in dirs {
        let url = s17Root.appendingPathComponent(d)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
        if !isDir.boolValue { out.append(d); continue }
        let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for i in items where i.pathExtension == "swift" {
            out.append(d + "/" + String(i.path.dropFirst(url.path.count + 1)))
        }
    }
    return out.sorted()
}

private func s17Matches(_ pattern: String, in text: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
}

// MARK: - The suite

@MainActor
@Suite("Smart map S17 — PERF: stages, rendering, incremental loading, intake, pressure, growth, capacity", .serialized)
struct SmartMapS17Tests {

    // PERF-03 — first use reads no branch detail; branches on demand, budgeted, with a continuation; all reachable.
    @Test("PERF-03: the first load reads no frame's positions and computes no branch; one opened frame reads only its own; every record stays reachable")
    func firstUseLoadsNoBranchDetail() async throws {
        let c = try await CaseMapPerf.seed(.smoke)
        let f = c.f
        let service = CaseMapService(sources: caseMapSources(f))
        let load = await service.load(caseID: f.caseID, generation: 1)
        let p = try #require(load.projection)
        #expect(try await s17Count(f.db, "SELECT COUNT(*) FROM case_map_layout WHERE case_id = ? AND frame_key <> '';", [.uuid(f.caseID)]) == 0,
                "the first load stored a branch's positions")
        #expect(await service.lastBranchRead == nil, "the first load read a branch")
        // One branch on demand: the frame's own positions only.
        let anchor = CaseMapNodeID(caseID: f.caseID, kind: .allegation, id: c.allegations[0])
        let opened = try #require(await service.openFrame(caseID: f.caseID, anchor: anchor, in: p))
        #expect(!opened.frame.members.isEmpty)
        #expect(try await s17Count(f.db, "SELECT COUNT(DISTINCT frame_key) FROM case_map_layout WHERE case_id = ? AND frame_key <> '';", [.uuid(f.caseID)]) == 1)
        // A branch read on an unchanged case answers from the last read (the fence only) and is budgeted.
        let small = await service.branch(caseID: f.caseID, anchor: anchor, budget: 2)
        #expect(small.source == .cached && small.frame != nil)
        let t = try #require(small.traversal)
        #expect(!t.exhausted, "a 2-record budget over a linked question must leave a continuation")
        #expect(t.depth.count >= t.continuation.count)
        let all = try #require(await service.branch(caseID: f.caseID, anchor: anchor, budget: p.nodes.count + 1).traversal)
        #expect(all.exhausted)
        #expect(Set(t.depth.keys).isSubset(of: Set(all.depth.keys)), "the budgeted read must be a prefix of the whole branch")
        // Every record is reachable through the list, page by page.
        let model = CaseMapWorkspaceModel(caseID: f.caseID, workspace: CaseWorkspaceHolder(caseID: f.caseID, defaults: s17Defaults()))
        await model.refresh(service)
        let projection = try #require(model.projection)
        let shown = CaseMapViewFilter.apply(projection, view: .overview, filter: CaseMapFilter(collapsed: []))
        var reached = Set<CaseMapNodeID>()
        for s in CaseMapListPaging.sections(projection, result: shown) {
            let page = CaseMapListPaging.visible(s.ids, pages: CaseMapListPaging.pagesToReachAll(s.ids.count))
            #expect(page.remaining == 0)
            reached.formUnion(page.rows)
        }
        #expect(reached == Set(projection.nodes.map(\.id)), "not every record is reachable")
    }

    // PERF-02 — the canvas is drawn by SwiftUI and laid out in AppKit, timed apart from the projection.
    @Test("PERF-02: the real case-map canvas is rendered to pixels (ImageRenderer) and laid out + displayed in an NSHostingView; times are recorded apart from the projection")
    func canvasRendersToPixels() async throws {
        let c = try await CaseMapPerf.seed(.smoke)
        let service = CaseMapService(sources: caseMapSources(c.f))
        let model = CaseMapWorkspaceModel(caseID: c.f.caseID, workspace: CaseWorkspaceHolder(caseID: c.f.caseID, defaults: s17Defaults()))
        var projectionMs = 0.0
        projectionMs = await CaseMapPerf.msAsync { await model.refresh(service) }
        let r = try #require(S17.render(model))
        #expect(r.width == 1440 && r.height == 900)
        #expect(r.inkedPixels > 0, "the canvas drew nothing")
        let h = try #require(S17.host(model))
        #expect(h.layoutMs >= 0 && h.displayMs >= 0)
        print("S17 smoke: projection \(projectionMs) ms, render \(r.ms) ms (\(r.inkedPixels) inked), host layout \(h.layoutMs) ms, display \(h.displayMs) ms")
    }

    // PERF-05 — a bounded intake does not stop navigation reads or the main thread.
    @Test("PERF-05: files ingested through the app's bounded lanes while branch reads and the main thread keep answering")
    func navigationAnswersDuringIntake() async throws {
        let c = try await CaseMapPerf.seed(.smoke)
        let f = c.f
        let dir = try s17Scratch("intake")
        defer { try? FileManager.default.removeItem(at: dir) }
        let corpus = try S17Corpus.write(into: dir, textLike: 12, pdfs: 0, pagesPerPDF: 0, images: 0)
        let coordinator = try S17.coordinator(f.db, dir: dir, metrics: nil)
        let service = CaseMapService(sources: caseMapSources(f))
        _ = await service.load(caseID: f.caseID, generation: 1)
        let versionsBefore = try await s17Count(f.db, "SELECT COUNT(*) FROM source_versions;")
        let anchor = CaseMapNodeID(caseID: f.caseID, kind: .allegation, id: c.allegations[0])
        let lag = S17MainLag()
        lag.start()
        let log = S17IntakeLog()
        let intake = S17.startIntake(corpus.urls, coordinator: coordinator, log: log)
        var reads = 0, answered = 0
        while !(await log.finished) {
            let b = await service.branch(caseID: f.caseID, anchor: anchor)
            reads += 1
            if b.frame != nil { answered += 1 }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await intake.value
        await lag.stop()
        #expect(await log.failures == 0)
        #expect(try await s17Count(f.db, "SELECT COUNT(*) FROM source_versions;") == versionsBefore + corpus.urls.count, "every file must be taken in")
        #expect(reads > 0 && answered == reads, "a navigation read went unanswered during intake (\(answered) of \(reads))")
        #expect(!lag.samples.isEmpty, "the main thread never ran during intake")
        // The case itself is unchanged by an archive intake (the files are not in its scope): the map still reads it.
        #expect(await service.branch(caseID: f.caseID, anchor: anchor).source == .cached)
    }

    /// Found by S17: the app target isolates undeclared types to the main actor, so every structural parser and loader
    /// ran its parse ON THE MAIN THREAD (a 120-page PDF held it for ~375 ms). The parse/ingest requirements and their
    /// conformers are now nonisolated; this test ingests a long PDF through the real pipeline and checks the main thread
    /// was free for most of it.
    @Test("PERF-05: a long PDF ingested through the real pipeline does not hold the main thread (parsers run off the main actor)")
    func parseRunsOffTheMainThread() async throws {
        let dir = try s17Scratch("offmain")
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        let coordinator = try S17.coordinator(db, dir: dir, metrics: nil)
        let url = dir.appendingPathComponent("long.pdf")
        try S17Corpus.pdf((0..<120).map { "Page \($0). " + S17Corpus.body($0) + S17Corpus.body($0 + 1) }).write(to: url)
        let lag = S17MainLag()
        lag.start()
        let t = DispatchTime.now().uptimeNanoseconds
        let repeats = FileManager.default.fileExists(atPath: s17Root.appendingPathComponent("build/perf/S17_REPEAT").path) ? 8 : 1
        for k in 0..<repeats {
            let u = k == 0 ? url : dir.appendingPathComponent("long-\(k).pdf")
            if k > 0 { try S17Corpus.pdf((0..<120).map { "Copy \(k) page \($0). " + S17Corpus.body($0 + k) }).write(to: u) }
            _ = try await Task.detached { try await coordinator.ingest(fileAt: u) }.value
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
        await lag.stop()
        let worst = lag.samples.max() ?? 0
        print("S17 off-main: pdf ingest \(ms) ms, main lag max \(worst) ms over \(lag.samples.count) samples; over 50 ms: \(lag.samples.enumerated().filter { $0.element > 50 }.map { "#\($0.offset)=\(Int($0.element))" })")
        #expect(lag.samples.count > 5, "the main thread ran only \(lag.samples.count) times during a \(ms) ms ingest")
        #expect(worst < ms * 0.5, "the main thread was held for \(worst) ms of a \(ms) ms ingest")
    }

    // PERF-08 — temporary copies refused before writing; custody stays; recovery choices are given.
    @Test("PERF-08: a parser's temporary copy is refused when the disk cannot hold it; the custody record stays and the reason names the recovery choices")
    func parserScratchRefusedUnderDiskPressure() async throws {
        let dir = try s17Scratch("scratch")
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let coordinator = try S17.coordinator(db, dir: dir, metrics: nil)
        let url = dir.appendingPathComponent("contract.docx")
        // A well-formed document (the loader reads it); the structural reader then needs its temporary copy.
        let xml = "<?xml version=\"1.0\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>"
            + "<w:p><w:r><w:t>The supplier was paid twice for invoice INV-7001.</w:t></w:r></w:p></w:body></w:document>"
        try S17Zip.stored([("[Content_Types].xml", Data("<?xml version=\"1.0\"?><Types/>".utf8)), ("word/document.xml", Data(xml.utf8))]).write(to: url)
        let original = try Data(contentsOf: url)
        var thrown: Error?
        do {
            _ = try await DiskSpaceCheck.$scratchCapacityOverride.withValue(1_024) { try await coordinator.ingest(fileAt: url) }
        } catch { thrown = error }
        _ = thrown
        #expect(try await s17Count(db, "SELECT COUNT(*) FROM source_versions;") == 1, "the custody record must stay")
        let details = try await db.query("SELECT coalesce(detail, '') FROM ingest_file_attempts;").compactMap { $0.string(0) }.joined(separator: " | ")
        #expect(details.contains("disk space"), "the attempt must say why: \(details)")
        #expect(try Data(contentsOf: url) == original, "the original must be untouched")
        // The refusal itself: what it needs, what is free, the safe choices.
        #expect(throws: DiskSpaceCheck.ScratchRefusal.self) {
            try DiskSpaceCheck.$scratchCapacityOverride.withValue(10) { try DiskSpaceCheck.requireScratch(5_000_000, for: "a file being read") }
        }
        let refusal = DiskSpaceCheck.ScratchRefusal(purpose: "a file being read", needed: 70_000_000, available: 10)
        let text = refusal.errorDescription ?? ""
        #expect(text.contains("Nothing was written") && text.contains("process the item again") && text.contains("Leave it unprocessed"))
        #expect(DiskSpaceCheck.ScratchRefusal.recoveryChoices.count == 3)
        // With room, the same check lets the copy through.
        try DiskSpaceCheck.$scratchCapacityOverride.withValue(Int64(1) << 40) { try DiskSpaceCheck.requireScratch(5_000_000, for: "a file being read") }
    }

    @Test("PERF-08: an archive is refused before its first member is written when its contents will not fit in the temporary folder")
    func archiveExpansionRefusedUpFront() async throws {
        let dir = try s17Scratch("zip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = dir.appendingPathComponent("bundle.zip")
        try S17Zip.stored([("a.txt", Data(repeating: 0x41, count: 2_000)), ("b.txt", Data(repeating: 0x42, count: 3_000))]).write(to: zip)
        let tmp = FileManager.default.temporaryDirectory
        func zipDirs() -> Set<String> {
            Set(((try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []).filter { $0.hasPrefix("kalsmritikosh-zip-") })
        }
        let before = zipDirs()
        #expect(throws: DiskSpaceCheck.ScratchRefusal.self) {
            try DiskSpaceCheck.$scratchCapacityOverride.withValue(1_000) { _ = try ArchiveLoader.expandZIP(at: zip) }
        }
        #expect(zipDirs() == before, "a refused expansion created a folder")
        // With room it expands both members (the archive is well formed).
        let ok = try DiskSpaceCheck.$scratchCapacityOverride.withValue(Int64(1) << 40) { try ArchiveLoader.expandZIP(at: zip) }
        defer { try? FileManager.default.removeItem(at: ok.root) }
        #expect(ok.files.count == 2)
    }

    // PERF-10 — days of work: nothing moves, only the new records are placed, the chronology is reused.
    @Test("PERF-10: three days of work on an open case — no stored position moves, only new records are placed and stored, and unchanged chronology is reused")
    func dailyGrowthIsIncremental() async throws {
        let c = try await CaseMapPerf.seed(.smoke)
        let service = CaseMapService(sources: caseMapSources(c.f))
        let model = CaseMapWorkspaceModel(caseID: c.f.caseID, workspace: CaseWorkspaceHolder(caseID: c.f.caseID, defaults: s17Defaults()))
        await model.refresh(service)
        let days = try await S17.grow(c, model: model, service: service, days: 3, journal: 8, people: 2, grid: 4, actions: 1, money: 2)
        for d in days {
            #expect(d.positionsMoved == 0, "day \(d.day) moved \(d.positionsMoved) positions")
            #expect(d.newRecords == d.added, "day \(d.day): \(d.newRecords) new records, \(d.added) added")
            #expect(d.newPlacementsStored == d.newRecords, "day \(d.day) stored \(d.newPlacementsStored) positions for \(d.newRecords) new records")
            #expect(d.reusedEntries >= CaseMapPerfSpec.smoke.journal, "day \(d.day) rebuilt the chronology (\(d.reusedEntries) reused)")
        }
    }

    // PERF-11 — truncation points are explicit; the inventory is complete.
    @Test("PERF-11: every non-literal cap in the case map, case file and case search is inventoried with its disclosure, and the 20,000-passage report caps are gone")
    func truncationPointsAreInventoried() throws {
        var found = Set<String>()
        for path in s17SwiftFiles(["Kalsmritikosh/Investigate/CaseFile", "Kalsmritikosh/Retrieval/CaseSearchService.swift"]) + s17SwiftFiles(["Kalsmritikosh/UI"]).filter({ $0.contains("/CaseMap") }) {
            let text = try String(contentsOf: s17Root.appendingPathComponent(path), encoding: .utf8)
            for m in s17Matches(#"\.prefix\([A-Za-z_][A-Za-z0-9_.]*\)"#, in: text) { found.insert(path + "|" + String(m.dropFirst())) }
        }
        let unlisted = found.subtracting(s17TruncationInventory.keys).sorted()
        #expect(unlisted.isEmpty, "caps without a recorded disclosure: \(unlisted)")
        var limits = Set<String>()
        for path in s17SwiftFiles(["Kalsmritikosh"]) {
            let text = try String(contentsOf: s17Root.appendingPathComponent(path), encoding: .utf8)
            for m in s17Matches(#"LIMIT [0-9]{3,}"#, in: text) { limits.insert(path + "|" + m) }
        }
        let newLimits = limits.subtracting(s17SQLLimitInventory.keys).sorted()
        #expect(newLimits.isEmpty, "row caps not in the inventory: \(newLimits)")
        for p in ["Kalsmritikosh/Investigate/CaseFile/CaseReports.swift", "Kalsmritikosh/Investigate/CaseFile/CaseReportStructure.swift"] {
            #expect(!limits.contains(p + "|LIMIT 20000"), "\(p) still stops at 20,000 passages")
        }
        // The disclosed caps behave as recorded.
        let ids = (0..<1_234).map { $0 }
        let page = CaseMapListPaging.visible(ids, pages: 1)
        #expect(page.rows.count + page.remaining == ids.count && page.remaining > 0)
    }

    @Test("PERF-11: a report's rule reader reads every passage of a long report (more than the old 20,000-passage cap)")
    func longReportReadInFull() async throws {
        let f = try await CaseFileTests.fixture(title: "S17 long report")
        let version = UUID(), doc = UUID(), file = UUID()
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try await f.db.exec("INSERT INTO files (id, url, source_type, availability, content_hash) VALUES (?,?,?,?,?);",
                            [.uuid(file), .text("file:///s17/long.txt"), .text("txt"), .text("available"), .text(hex + hex)])
        try await f.db.exec("""
            INSERT INTO source_versions (id, logical_source_id, document_id, content_hash, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(version), .uuid(file), .uuid(doc), .text(hex + hex), .real(100), .integer(1), .real(100),
                  .text("long.txt"), .text("txt"), .text("magicBytes"), .integer(1), .text("referenced"), .text("referenceRecorded"), .real(100)])
        let n = 20_050
        try await f.db.withSavepoint("s17_blocks") { db in
            for i in 0..<n {
                try db.exec("""
                    INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text, extraction_method, extraction_confidence)
                    VALUES (?,?,?,?,?,?,?,?,?);
                    """, [.uuid(UUID()), .uuid(doc), .uuid(version), .integer(Int64(i)), .text("paragraph"), .text("Passage \(i)."), .text("passage \(i)."),
                          .text("native"), .real(1.0)])
            }
        }
        let passages = try await f.file.reportPassages(sourceVersionID: version)
        #expect(passages.count == n, "read \(passages.count) of \(n) passages")
        #expect(passages.last?.text == "Passage \(n - 1).")
    }

    // MARK: The full measurement (CASE_MAP_PERF only)

    @Test("S17 full measurement, normal case + a 200-file intake with PDFs and OCR (CASE_MAP_PERF only)", .enabled(if: s17PerfEnabled), .timeLimit(.minutes(40)))
    func fullS17Normal() async throws { try await Self.full(.normal, textLike: 150, pdfs: 30, pagesPerPDF: 4, images: 20, days: 5) }

    @Test("S17 full measurement, stress case + a 1,000-file intake (CASE_MAP_PERF only)", .enabled(if: s17PerfEnabled && ProcessInfo.processInfo.environment["CASE_MAP_PERF_STRESS"] == "1"),
          .timeLimit(.minutes(60)))
    func fullS17Stress() async throws { try await Self.full(.stress, textLike: 800, pdfs: 100, pagesPerPDF: 4, images: 100, days: 5) }

    struct FullResult: Codable {
        var workload: [String: String] = [:]
        var environment: [String: String] = [:]
        var loadAtStart: [Double] = []
        var loadAtEnd: [Double] = []
        var stagesMs: [String: Double] = [:]
        var intakeFiles = 0
        var intakeFailures = 0
        var intakeWallMs = 0.0
        var intakeFileMs: [Double] = []
        var intakeStageSeconds: [String: Double] = [:]
        var intakeStageCounts: [String: Int] = [:]
        var laneCapacityCPU = 0
        var fanOutInFlight = 0
        var branchReadIdleMs: [Double] = []
        var branchReadDuringIntakeMs: [Double] = []
        var mapReloadIdleMs: [Double] = []
        var mapReloadDuringIntakeMs: [Double] = []
        /// The main thread's lateness while the intake ran: n, p50, p95, p99, max, and how many wake-ups were over 16 / 100 ms.
        var mainLagDuringIntake: [String: Double] = [:]
        /// Every wake-up more than 50 ms late, in order.
        var mainLagSpikesMs: [Double] = []
        /// Per-file intake time by file kind: n, p50, p95, max.
        var intakeByKindMs: [String: [String: Double]] = [:]
        var renderColdMs = 0.0
        var renderWarmMs: [Double] = []
        var renderInkedPixels = 0
        var renderByViewMs: [String: Double] = [:]
        var hostLayoutMs: [Double] = []
        var hostDisplayMs: [Double] = []
        var navigationToPixelsMs: [Double] = []
        var changeToPixelsMs: [Double] = []
        var growth: [S17.Day] = []
        var targets: [String: String] = [:]
    }

    static func full(_ spec: CaseMapPerfSpec, textLike: Int, pdfs: Int, pagesPerPDF: Int, images: Int, days: Int) async throws {
        var r = FullResult()
        r.loadAtStart = CaseMapPerf.loadAverage()
        let c = try await CaseMapPerf.seed(spec)
        let f = c.f
        let dir = try s17Scratch("full-\(spec.label)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let corpus = try S17Corpus.write(into: dir, textLike: textLike, pdfs: pdfs, pagesPerPDF: pagesPerPDF, images: images)
        let service = CaseMapService(sources: caseMapSources(f))
        let model = CaseMapWorkspaceModel(caseID: f.caseID, workspace: CaseWorkspaceHolder(caseID: f.caseID, defaults: s17Defaults()))
        r.stagesMs["projection: first load (cold, positions placed and stored)"] = await CaseMapPerf.msAsync { await model.refresh(service) }
        r.stagesMs["projection: warm reload"] = await CaseMapPerf.msAsync { await model.refresh(service) }
        let p = try #require(model.projection)
        // Rendering: the canvas drawn to pixels, cold then warm, and per built-in view; the AppKit host path.
        let cold = try #require(S17.render(model))
        r.renderColdMs = cold.ms
        r.renderInkedPixels = cold.inkedPixels
        #expect(cold.inkedPixels > 0, "the canvas drew nothing")
        for _ in 0..<10 { r.renderWarmMs.append(S17.render(model)?.ms ?? -1) }
        for v in [CaseMapViewKind.overview, .questions, .people, .chronology, .findings, .changes] {
            model.go(to: .builtIn(v))
            r.renderByViewMs[v.rawValue] = S17.render(model)?.ms ?? -1
        }
        model.go(to: .builtIn(.overview))
        for _ in 0..<5 {
            if let h = S17.host(model) { r.hostLayoutMs.append(h.layoutMs); r.hostDisplayMs.append(h.displayMs) }
        }
        // Navigation to pixels: select an item, switch view, draw.
        let sample = stride(from: 0, to: p.nodes.count, by: max(1, p.nodes.count / 20)).map { p.nodes[$0].id }
        let views: [CaseMapViewKind] = [.questions, .people, .chronology, .overview]
        for (i, id) in sample.enumerated() {
            r.navigationToPixelsMs.append(CaseMapPerf.ms {
                model.select(.node(id))
                model.go(to: .builtIn(views[i % views.count]))
                _ = S17.render(model)
            })
        }
        model.go(to: .builtIn(.overview))
        // Change propagation to pixels: one new chronology entry, refreshed and drawn.
        for j in 0..<5 {
            let d = c.docs[(j * 17) % c.docs.count]
            _ = try await f.file.addJournal(caseID: f.caseID, kind: .chronology, text: "Propagation \(j)", eventDate: Date(timeIntervalSince1970: 1_765_000_000 + Double(j)),
                                            evidenceRef: d.version.uuidString, quote: nil, actor: "Ada")
            r.changeToPixelsMs.append(await CaseMapPerf.msAsync {
                await model.refresh(service)
                _ = S17.render(model)
            })
        }
        // Navigation reads idle, then during a large intake through the app's bounded lanes.
        let anchors = c.allegations.prefix(5).map { CaseMapNodeID(caseID: f.caseID, kind: .allegation, id: $0) }
        let sources = caseMapSources(f)
        for a in anchors { r.branchReadIdleMs.append(await CaseMapPerf.msAsync { _ = await service.branch(caseID: f.caseID, anchor: a) }) }
        for g in 0..<3 { r.mapReloadIdleMs.append(await CaseMapPerf.msAsync { _ = await CaseMapService(sources: sources).load(caseID: f.caseID, generation: UInt64(200 + g)) }) }
        let metrics = PipelineMetrics()
        let coordinator = try S17.coordinator(f.db, dir: dir, metrics: metrics)
        let l = S17.lanes()
        r.laneCapacityCPU = l.cpu
        r.fanOutInFlight = l.inFlight
        let lag = S17MainLag()
        lag.start()
        let log = S17IntakeLog()
        let t0 = DispatchTime.now().uptimeNanoseconds
        let intake = S17.startIntake(corpus.urls, coordinator: coordinator, log: log)
        var i = 0
        while !(await log.finished) {
            let a = anchors[i % anchors.count]
            r.branchReadDuringIntakeMs.append(await CaseMapPerf.msAsync { _ = await service.branch(caseID: f.caseID, anchor: a) })
            if i % 10 == 0 {
                r.mapReloadDuringIntakeMs.append(await CaseMapPerf.msAsync { _ = await CaseMapService(sources: sources).load(caseID: f.caseID, generation: UInt64(300 + i)) })
            }
            i += 1
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        await intake.value
        r.intakeWallMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        await lag.stop()
        let lagS = lag.samples
        r.mainLagDuringIntake = ["n": Double(lagS.count), "p50": CaseMapPerf.percentile(lagS, 0.5), "p95": CaseMapPerf.percentile(lagS, 0.95),
                                 "p99": CaseMapPerf.percentile(lagS, 0.99), "max": lagS.max() ?? 0,
                                 "over16ms": Double(lagS.filter { $0 > 16 }.count), "over100ms": Double(lagS.filter { $0 > 100 }.count)]
        r.mainLagSpikesMs = lagS.filter { $0 > 50 }
        for (k, v) in await log.byKindMs {
            r.intakeByKindMs[k] = ["n": Double(v.count), "p50": CaseMapPerf.percentile(v, 0.5), "p95": CaseMapPerf.percentile(v, 0.95), "max": v.max() ?? 0]
        }
        r.intakeFiles = corpus.urls.count
        r.intakeFailures = await log.failures
        r.intakeFileMs = await log.fileMs
        for (k, v) in await metrics.durationsSnapshot() { r.intakeStageSeconds[k.rawValue] = v }
        for (k, v) in await metrics.snapshot() { r.intakeStageCounts[k.rawValue] = v }
        #expect(r.intakeFailures == 0, "\(r.intakeFailures) files failed intake")
        // Growth: days of work on the open case.
        r.growth = try await S17.grow(c, model: model, service: service, days: days, journal: 40, people: 4, grid: 12, actions: 3, money: 10)
        for d in r.growth { #expect(d.positionsMoved == 0 && d.newPlacementsStored == d.newRecords, "day \(d.day): moved \(d.positionsMoved), stored \(d.newPlacementsStored)/\(d.newRecords)") }
        r.loadAtEnd = CaseMapPerf.loadAverage()
        r.environment = CaseMapPerfHarnessTests.environment([])
        r.environment["os.processInfo.activeProcessorCount"] = String(ProcessInfo.processInfo.activeProcessorCount)
        r.environment["hw.perflevel1.physicalcpu"] = String(CaseMapPerf.sysctlInt("hw.perflevel1.physicalcpu"))
        let depth = c.smart.chain.count
        r.workload = [
            "name": "\(spec.label) (S17)", "documents in the case": String(c.docs.count), "projected records": String(p.nodes.count), "links": String(p.links.count),
            "case text bytes": String(c.textBytes), "longest branch depth": String(depth), "hub person frames": String(c.smart.hubPlacements),
            "intake files": String(corpus.urls.count), "intake bytes": String(corpus.bytes), "intake PDF pages": String(corpus.pdfPages),
            "intake OCR images": String(corpus.ocrImages), "intake by kind": corpus.byKind.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "),
            "users": "1 (local; no shared service exists)",
            "update rate (growth series)": "\(days) days × ~\(r.growth.first?.added ?? 0) records/day, refreshed after each day"
        ]
        func pq(_ xs: [Double], _ q: Double) -> Double { CaseMapPerf.percentile(xs, q) }
        func verdict(_ ok: Bool, _ s: String) -> String { (ok ? "met" : "NOT MET") + " (" + s + ")" }
        r.targets["overview warm ≤ 1 s"] = verdict((r.stagesMs["projection: warm reload"] ?? .infinity) <= 1_000, String(format: "%.0f ms", r.stagesMs["projection: warm reload"] ?? -1))
        r.targets["canvas render warm p95 ≤ 200 ms (drawn by SwiftUI, off screen)"] = verdict(pq(r.renderWarmMs, 0.95) <= 200, String(format: "%.1f ms", pq(r.renderWarmMs, 0.95)))
        r.targets["navigation to pixels p95 ≤ 200 ms"] = verdict(pq(r.navigationToPixelsMs, 0.95) <= 200, String(format: "%.1f ms", pq(r.navigationToPixelsMs, 0.95)))
        r.targets["branch read during intake p95 ≤ 200 ms"] = verdict(pq(r.branchReadDuringIntakeMs, 0.95) <= 200, String(format: "%.1f ms", pq(r.branchReadDuringIntakeMs, 0.95)))
        r.targets["main thread lag during intake max ≤ 250 ms (no hang)"] = verdict((r.mainLagDuringIntake["max"] ?? 0) <= 250, String(format: "%.1f ms", r.mainLagDuringIntake["max"] ?? 0))
        r.targets["growth: no position moved"] = verdict(r.growth.allSatisfy { $0.positionsMoved == 0 }, "\(r.growth.map(\.positionsMoved))")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = String(decoding: try enc.encode(r), as: UTF8.self)
        print("===CASE_MAP_PERF_BEGIN s17-\(spec.label).json===\n" + json + "\n===CASE_MAP_PERF_END===")
        if let out = ProcessInfo.processInfo.environment["CASE_MAP_PERF_OUT"], !out.isEmpty {
            let d = URL(fileURLWithPath: out, isDirectory: true)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try json.write(to: d.appendingPathComponent("s17-\(spec.label).json"), atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - A stored (uncompressed) ZIP for the archive test

enum S17Zip {
    static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }

    static func stored(_ entries: [(String, Data)]) -> Data {
        var out = Data()
        var central = Data()
        for (name, body) in entries {
            let offset = UInt32(out.count)
            let crc = crc32(body), size = UInt32(body.count), n = Array(name.utf8)
            var local: [UInt8] = le32(0x0403_4B50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
            local += le32(crc) + le32(size) + le32(size) + le16(n.count) + le16(0)
            out.append(contentsOf: local); out.append(contentsOf: n); out.append(body)
            var cd: [UInt8] = le32(0x0201_4B50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
            cd += le32(crc) + le32(size) + le32(size) + le16(n.count) + le16(0) + le16(0) + le16(0) + le16(0)
            cd += le32(0) + le32(offset)
            central.append(contentsOf: cd); central.append(contentsOf: n)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        var end: [UInt8] = le32(0x0605_4B50) + le16(0) + le16(0) + le16(entries.count) + le16(entries.count)
        end += le32(UInt32(central.count)) + le32(cdOffset) + le16(0)
        out.append(contentsOf: end)
        return out
    }
}
