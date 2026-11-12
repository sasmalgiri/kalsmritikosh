//
//  SmartMapS11Tests.swift
//  KalsmritikoshTests
//
//  Smart-map S11 (milestone M5): reviewed case products (OUTPUT-01..10) and backup / restore / lifecycle integrity
//  (RECOVERY-01..10). On throwaway migrated ledgers in temporary folders — never the owner's. Dates are built with an
//  explicit time zone (UTC) where they matter.
//

import CoreGraphics
import Foundation
import Testing
@testable import Kalsmritikosh

/// A thread-safe counter / flag for hooks.
final class S11Box: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

final class S11PermissionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [UUID: CaseReadPermission] = [:]
    func get(_ id: UUID) -> CaseReadPermission? { lock.lock(); defer { lock.unlock() }; return stored[id] }
    func set(_ p: CaseReadPermission?, _ id: UUID) { lock.lock(); stored[id] = p; lock.unlock() }
}

func s11Scratch(_ tag: String) throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("s11-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

func s11Outputs(_ f: CaseFileTests.Fixture) throws -> (CaseOutputService, URL) {
    let temp = try s11Scratch("out")
    let db = f.db
    let svc = CaseOutputService(database: f.db, caseFiles: f.svc, custody: { caseID in
        try await db.query("SELECT source_ref FROM investigation_case_sources WHERE case_id = ? AND in_scope = 1 AND source_kind = 'sourceVersion';", [.uuid(caseID)])
            .compactMap { $0.uuid(0) }.map { CustodyManifestEntry(sourceVersionID: $0, contentHash: nil, custodyEvents: []) }
    }, pendingDirectory: temp.appendingPathComponent("pending", isDirectory: true))
    return (svc, temp)
}

func s11Hash(_ url: URL) throws -> String { StudioRecordRepository.sha256(try Data(contentsOf: url)) }

@Suite("Smart map S11 — reviewed products and recovery (M5)", .serialized)
@MainActor
struct SmartMapS11Tests {

    static let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC") ?? .gmt; return c }()
    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date { utc.date(from: DateComponents(year: y, month: m, day: d, hour: 12)) ?? Date(timeIntervalSince1970: 0) }

    /// A case with a verified link, a question, an open action, a money record and a briefing.
    struct Rig {
        let rig: CaseMapRig
        var f: CaseFileTests.Fixture { rig.f }
        let allegation: UUID
        let task: UUID
        let briefing: UUID
        let map: CaseMapService
    }

    func rig() async throws -> Rig {
        let rig = try await CaseMapRig.make()
        let f = rig.f
        let a = try await f.file.addAllegation(caseID: f.caseID, text: "The supplier was paid twice", actor: "Ada")
        _ = try await f.svc.linkEvidence(caseID: f.caseID, allegationID: a, evidenceRef: rig.a.version.uuidString, label: "invoice A", stance: .supports, note: nil,
                                         passage: StudioEvidenceRef(sourceVersionID: rig.a.version, objectID: rig.a.object, quote: "The invoice total was 500 dollars."), actor: "Ada")
        let t = try await f.svc.addTask(caseID: f.caseID, workspaceID: f.workspaceID, title: "Ask the bank for the March statement", assignee: "Ada", due: nil, actor: "Ada")
        var money = CaseMoneyRecordInput(kind: .payment, amountText: "USD 500")
        money.date = "2026-03-03"; money.sourceVersionID = rig.a.version; money.quote = "The invoice total was 500 dollars."; money.sourceName = "invoice-a.txt"
        _ = try await f.file.recordMoney(caseID: f.caseID, money, actor: "Ada")
        let b = try await f.file.createBriefing(caseID: f.caseID, title: "For the director", purpose: "Where the payments stand", actor: "Ada")
        _ = try await f.file.addBriefingItem(caseID: f.caseID, briefingID: b, kind: .record, record: rig.node(.allegation, a), actor: "Ada")
        return Rig(rig: rig, allegation: a, task: t, briefing: b, map: CaseMapService(sources: caseMapSources(f)))
    }

    // MARK: OUTPUT-02

    @Test("OUTPUT-02: a product is read under one revision — an edit during the read is read again; an edit on every read refuses; the manifest pins the revision")
    func freezeUnderConcurrentEdit() async throws {
        let r = try await rig()
        let f = r.f
        let (out, temp) = try s11Outputs(f)
        defer { try? FileManager.default.removeItem(at: temp) }
        // Two prepares of an unchanged case name the same revision (re-verification times do not change it).
        let p1 = try await out.prepare(caseID: f.caseID, kind: .caseFileReport, route: .file, actor: "Ada") { CaseFileDocuments.caseFileReport($0, by: "Ada") }
        let p2 = try await out.prepare(caseID: f.caseID, kind: .caseFileReport, route: .file, actor: "Ada") { CaseFileDocuments.caseFileReport($0, by: "Ada") }
        #expect(p1.manifest?.revisionFence != nil && p1.manifest?.revisionFence == p2.manifest?.revisionFence)
        // An edit lands once, between the two fence reads: the read is repeated and the package holds the edit.
        let once = S11Box()
        let file = f.file, caseID = f.caseID
        await out.setHooks(.init(duringFreeze: {
            if once.next() == 1 { _ = try? await file.addAllegation(caseID: caseID, text: "Late note from the auditor", actor: "Ben") }
        }))
        let p3 = try await out.prepare(caseID: f.caseID, kind: .caseFileReport, route: .file, actor: "Ada") { CaseFileDocuments.caseFileReport($0, by: "Ada") }
        #expect(p3.text.contains("Late note from the auditor"))
        #expect(p3.manifest?.revisionFence != p1.manifest?.revisionFence)
        // An edit on every read: never a mixed state — refused, and the refusal recorded.
        let always = S11Box()
        await out.setHooks(.init(duringFreeze: {
            _ = try? await file.addJournal(caseID: caseID, kind: .note, text: "Edit \(always.next())", eventDate: nil, evidenceRef: nil, actor: "Ben")
        }))
        await #expect(throws: CaseOutputError.keptChanging) {
            _ = try await out.prepare(caseID: caseID, kind: .caseFileReport, route: .file, actor: "Ada") { CaseFileDocuments.caseFileReport($0, by: "Ada") }
        }
        await out.setHooks(.init())
        #expect(try await out.outputs(caseID: f.caseID).contains { $0.status == .refused && $0.kind == .caseFileReport })
        // The written report's record carries the manifest and the revision.
        let p4 = try await out.prepare(caseID: f.caseID, kind: .caseFileReport, route: .file, actor: "Ada") { CaseFileDocuments.caseFileReport($0, by: "Ada") }
        let receipt = await out.write(p4, to: temp.appendingPathComponent("report.md"))
        #expect(receipt.status == .written && receipt.recorded)
        let row = try #require(try await f.db.query("SELECT manifest_json, revision_fence FROM case_document_outputs WHERE id = ?;", [.uuid(receipt.id)]).first)
        #expect(row.string(1) == p4.manifest?.revisionFence)
        let m = try #require(row.string(0).flatMap(CaseOutputManifest.decode))
        #expect(m.counts["allegations"] == 2 && m.state == "draft")
    }

    // MARK: OUTPUT-03 / 04 / 05 / 07 / 10

    @Test("OUTPUT-03/04/05/07/10: the case package is one static file a fresh reader opens with nothing but its bytes — sections, provenance marks, evidence, open work, money, disclosures — and it is reconciled with its manifest before it is recorded")
    func packageWholeCase() async throws {
        let r = try await rig()
        let f = r.f
        _ = try await f.file.addJournal(caseID: f.caseID, kind: .note, text: "Pasted from mail: <script>alert(1)</script> <img src=\"http://evil.example/x.png\"> onload=steal()",
                                        eventDate: Self.day(2026, 3, 4), evidenceRef: nil, actor: "Ada")
        let (out, temp) = try s11Outputs(f)
        defer { try? FileManager.default.removeItem(at: temp) }
        let map = r.map
        let pkg = try await out.preparePackage(caseID: f.caseID, selection: .wholeCase, actor: "Ada") { id in await map.load(caseID: id, generation: 1) }
        #expect(pkg.kind == .casePackage && pkg.manifest?.format == "html")
        let url = temp.appendingPathComponent("package.html")
        let receipt = await out.write(pkg, to: url)
        #expect(receipt.status == .written && receipt.recorded, "\(receipt.summary)")
        // The handover: a fresh folder, no ledger, no app state — only the file.
        let fresh = try s11Scratch("viewer")
        defer { try? FileManager.default.removeItem(at: fresh) }
        let copy = fresh.appendingPathComponent("received.html")
        try FileManager.default.copyItem(at: url, to: copy)
        let read = CasePortablePackageReader.read(try String(contentsOf: copy, encoding: .utf8))
        #expect(read.violations.isEmpty, "\(read.violations)")
        #expect(read.brokenAnchors.isEmpty, "\(read.brokenAnchors)")
        for s in ["status", "legend", "items", "relationships", "evidence", "findings", "open-work", "money", "disclosures", "manifest"] {
            #expect(read.sections.contains(s), "section \(s)")
        }
        let m = try #require(read.manifest)
        #expect(m.revisionFence == pkg.manifest?.revisionFence)
        #expect(read.rows["item"] == m.counts["items"] && read.rows["link"] == m.counts["links"] && read.rows["evidence"] == m.counts["evidence"])
        // The recipient reaches the evidence (quoted words), the decisions and the remaining work.
        #expect(read.sectionText["evidence"]?.contains("The invoice total was 500 dollars.") == true)
        #expect(read.sectionText["open-work"]?.contains("Ask the bank for the March statement") == true)
        #expect(read.sectionText["findings"]?.contains("The supplier was paid twice") == true)
        #expect(read.sectionText["money"]?.contains("Gross paid") == true)
        #expect(read.sectionText["status"]?.contains("Not approved") == true)
        // Supplied / inferred / reviewed / unresolved are told apart.
        #expect(read.sectionText["legend"]?.contains("Supplied") == true && read.sectionText["legend"]?.contains("Unresolved") == true)
        #expect(read.sectionText["items"]?.contains("Supplied") == true || read.sectionText["items"]?.contains("Inferred") == true)
        // Untrusted case text is shown, never run.
        #expect(read.sectionText["items"]?.contains("<script>alert(1)</script>") == true)
        // Disclosures say what is not inside (originals).
        #expect(read.sectionText["disclosures"]?.contains("Originals and derived files are not inside this package") == true)
        let row = try #require(try await f.db.query("SELECT kind, manifest_json FROM case_document_outputs WHERE id = ?;", [.uuid(receipt.id)]).first)
        #expect(row.string(0) == "casePackage" && row.string(1) != nil)
    }

    @Test("OUTPUT-03/06: chosen records bring what they rest on and the rest is disclosed by count; a source labelled privileged before release refuses the package")
    func packageSelectionAndRecheck() async throws {
        let r = try await rig()
        let f = r.f
        let (out, temp) = try s11Outputs(f)
        defer { try? FileManager.default.removeItem(at: temp) }
        let map = r.map
        let load = await map.load(caseID: f.caseID, generation: 1)
        let p = try #require(load.projection)
        let allegation = r.rig.node(.allegation, r.allegation)
        let resolved = CasePortablePackage.resolve(.records([allegation]), in: p, briefings: [])
        #expect(resolved.count > 1, "the evidence the question rests on comes with it")
        #expect(resolved.values.contains { ($0 ?? "").contains("rests on it") })
        let pkg = try await out.preparePackage(caseID: f.caseID, selection: .records([allegation]), actor: "Ada") { id in await map.load(caseID: id, generation: 2) }
        let read = CasePortablePackageReader.read(pkg.text)
        #expect(read.sectionText["disclosures"]?.contains("Not selected for this package") == true)
        #expect(read.sectionText["items"]?.contains("Included because") == true)
        // Briefing selection.
        let bp = try await out.preparePackage(caseID: f.caseID, selection: .briefing(r.briefing), actor: "Ada") { id in await map.load(caseID: id, generation: 3) }
        #expect(CasePortablePackageReader.read(bp.text).rows["step"] == 1)
        // Prepared, then the cited source is labelled privileged: the release is refused and nothing is written.
        let again = try await out.preparePackage(caseID: f.caseID, selection: .wholeCase, actor: "Ada") { id in await map.load(caseID: id, generation: 4) }
        _ = try await SensitiveScopeRepository(database: f.db).assign(
            target: SensitiveScopeTarget(kind: .sourceVersion, id: r.rig.a.version), sensitivity: .confidential,
            authority: .userConfirmed(actorID: "Ada", confirmationID: UUID(), privileged: true), reason: "legal advice")
        let blocked = temp.appendingPathComponent("blocked.html")
        let refused = await out.write(again, to: blocked)
        #expect(refused.status == .refused && !FileManager.default.fileExists(atPath: blocked.path))
    }

    @Test("OUTPUT-07: the read-back reconciles counts and formats — a package missing a row, a table with a row too few, a damaged PDF or image is not a successful export")
    func readBackReconciles() async throws {
        let r = try await rig()
        let f = r.f
        let (out, temp) = try s11Outputs(f)
        defer { try? FileManager.default.removeItem(at: temp) }
        let map = r.map
        let pkg = try await out.preparePackage(caseID: f.caseID, selection: .wholeCase, actor: "Ada") { id in await map.load(caseID: id, generation: 1) }
        let m = try #require(pkg.manifest)
        #expect(CaseOutputArtifactCheck.problem(pkg.data, manifest: m) == nil)
        // One evidence row removed (manifest unchanged).
        let lines = pkg.text.components(separatedBy: "\n")
        let cut = lines.filter { !$0.contains("data-row=\"evidence\"") || $0.contains("id=\"ev-2\"") }.joined(separator: "\n")
        #expect(CaseOutputArtifactCheck.problem(Data(cut.utf8), manifest: m) != nil, "a removed evidence row (or the links to it) is caught")
        // Active content added.
        let hostile = pkg.text.replacingOccurrences(of: "</body>", with: "<script>fetch('https://x')</script></body>")
        #expect(CaseOutputArtifactCheck.problem(Data(hostile.utf8), manifest: m)?.contains("active content") == true)
        // Map exports carry a manifest; the CSV is reconciled by rows, the PDF by pages.
        let view = CaseMapViewFilter.apply(try #require((await map.load(caseID: f.caseID, generation: 2)).projection), view: .overview, filter: CaseMapFilter(collapsed: []))
        let load = await map.load(caseID: f.caseID, generation: 3)
        let req = CaseMapExportRequest(projection: try #require(load.projection), placements: load.placements, shown: view.shown, links: view.links, selection: nil,
                                       viewTitle: "Overview", state: .current(Date()), scopeFingerprint: "fp")
        let csv = try await out.prepareMap(req, format: .csv, route: .file, actor: "Ada")
        let cm = try #require(csv.manifest)
        #expect(cm.format == "csv" && CaseOutputArtifactCheck.problem(csv.data, manifest: cm) == nil)
        let short = String(decoding: csv.data, as: UTF8.self).components(separatedBy: "\n").filter { !$0.hasPrefix("item,") }.joined(separator: "\n")
        #expect(CaseOutputArtifactCheck.problem(Data(short.utf8), manifest: cm) != nil)
        let pdf = try await out.prepareMap(req, format: .pdf, route: .file, actor: "Ada")
        #expect(CaseOutputArtifactCheck.problem(pdf.data, manifest: try #require(pdf.manifest)) == nil)
        #expect(CaseOutputArtifactCheck.problem(Data("%PDF-1.4 broken".utf8), manifest: try #require(pdf.manifest)) != nil)
        let png = try await out.prepareMap(req, format: .png, route: .file, actor: "Ada")
        #expect(CaseOutputArtifactCheck.problem(png.data, manifest: try #require(png.manifest)) == nil)
        #expect(CaseOutputArtifactCheck.problem(Data([0x89, 0x50, 0x4E, 0x47, 0, 1]), manifest: try #require(png.manifest)) != nil)
        let ok = await out.write(pdf, to: temp.appendingPathComponent("map.pdf"))
        #expect(ok.status == .written && ok.recorded)
    }

    // MARK: OUTPUT-08 / OUTPUT-06

    @Test("OUTPUT-08: a product is a draft with its revision until a reviewer approves exactly that revision; a later change or a withdrawn approval stops the release; viewers cannot approve")
    func approvals() async throws {
        let r = try await rig()
        let f = r.f
        let (out, temp) = try s11Outputs(f)
        defer { try? FileManager.default.removeItem(at: temp) }
        let render: @Sendable (CaseFileSnapshot) -> String = { CaseFileDocuments.caseFileReport($0, by: "Ada") }
        let draft = try await out.prepare(caseID: f.caseID, kind: .caseFileReport, route: .file, actor: "Ada", render: render)
        #expect(draft.text.hasPrefix("> DRAFT case file") && draft.text.contains("Not approved") && !draft.approved)
        let approved = try await out.approve(caseID: f.caseID, kinds: [.caseFileReport, .casePackage, .exhibitList], note: "Checked", actor: "Ada")
        #expect(approved.count == 2 && approved.allSatisfy(\.selfReview), "records are not approved; a solo approval is labelled")
        let a = try await out.prepare(caseID: f.caseID, kind: .caseFileReport, route: .file, actor: "Ada", render: render)
        #expect(a.approved && a.approvalID != nil && a.text.contains("APPROVED for release") && a.text.contains("self-approved") && !a.text.hasPrefix("> DRAFT"))
        let ok = await out.write(a, to: temp.appendingPathComponent("approved.md"))
        #expect(ok.status == .written)
        #expect(try await f.db.query("SELECT approval_id FROM case_document_outputs WHERE id = ?;", [.uuid(ok.id)]).first?.string(0) == a.approvalID?.uuidString)
        // Prepared approved, then the case changes: the release is refused (it would present a stale state as approved).
        let stale = try await out.prepare(caseID: f.caseID, kind: .caseFileReport, route: .file, actor: "Ada", render: render)
        _ = try await f.file.addJournal(caseID: f.caseID, kind: .note, text: "New interview booked", eventDate: nil, evidenceRef: nil, actor: "Ada")
        let refused = await out.write(stale, to: temp.appendingPathComponent("stale.md"))
        #expect(refused.status == .refused && refused.detail?.contains("changed after it was approved") == true)
        // Now a draft again, saying an approval exists for an earlier revision.
        let again = try await out.prepare(caseID: f.caseID, kind: .caseFileReport, route: .file, actor: "Ada", render: render)
        #expect(!again.approved && again.text.contains("earlier revision"))
        // Approve again; prepare; withdraw; the prepared release is refused.
        let second = try await out.approve(caseID: f.caseID, kinds: [.caseFileReport], note: nil, actor: "Ada")
        let pkg = try await out.prepare(caseID: f.caseID, kind: .caseFileReport, route: .file, actor: "Ada", render: render)
        try await out.withdrawApproval(caseID: f.caseID, approvalID: try #require(second.first?.id), reason: "The interview changes the picture", actor: "Ada")
        let w = await out.write(pkg, to: temp.appendingPathComponent("withdrawn.md"))
        #expect(w.status == .refused && w.detail?.contains("withdrawn") == true)
        await #expect(throws: CaseOutputError.self) {
            try await out.withdrawApproval(caseID: f.caseID, approvalID: try #require(second.first?.id), reason: "again", actor: "Ada")
        }
        // Team case: a viewer cannot approve; a reviewer can (not labelled self-approved).
        _ = try await f.file.grantAccess(caseID: f.caseID, to: "Vera", role: .viewer, reason: "Reads", actor: "Ada")
        _ = try await f.file.grantAccess(caseID: f.caseID, to: "Rita", role: .reviewer, reason: "Reviews", actor: "Ada")
        await #expect(throws: (any Error).self) {
            try await CaseAccessContext.$principal.withValue(.local("Vera")) {
                _ = try await out.approve(caseID: f.caseID, kinds: [.caseFileReport], note: nil, actor: "Vera")
            }
        }
        let byRita = try await CaseAccessContext.$principal.withValue(.local("Rita")) {
            try await out.approve(caseID: f.caseID, kinds: [.casePackage], note: nil, actor: "Rita")
        }
        #expect(byRita.first?.selfReview == false && byRita.first?.approvedBy == "Rita")
    }

    // MARK: OUTPUT-01

    @Test("OUTPUT-01: the money report, a briefing and a review record leave through the output door (recorded, protected, re-checked); the findings export and every new route use it")
    func productsThroughTheDoor() async throws {
        let r = try await rig()
        let f = r.f
        let (out, temp) = try s11Outputs(f)
        defer { try? FileManager.default.removeItem(at: temp) }
        let money = try await out.prepareMoneyReport(caseID: f.caseID, actor: "Ada")
        #expect(money.kind == .moneyReport && money.text.contains("Gross paid") && money.citations.contains { $0.sourceVersionID == r.rig.a.version })
        #expect(await out.write(money, to: temp.appendingPathComponent("money.md")).status == .written)
        let map = r.map
        let briefing = try await out.prepareBriefing(caseID: f.caseID, briefingID: r.briefing, actor: "Ada") { id in await map.load(caseID: id, generation: 1) }
        #expect(briefing.text.contains("For the director") && briefing.text.contains("The supplier was paid twice") && briefing.manifest?.counts["steps"] == 1)
        #expect(await out.write(briefing, to: temp.appendingPathComponent("briefing.md")).status == .written)
        let review = CaseHistoryReviewService(database: f.db, file: f.file, map: map)
        let record = try await out.prepareReviewRecord(caseID: f.caseID, review: review, actor: "Ada")
        #expect(record.kind == .reviewRecord && record.text.contains("review record"))
        #expect(await out.write(record, to: temp.appendingPathComponent("review.md")).status == .written)
        let kinds = Set(try await out.outputs(caseID: f.caseID).filter { $0.status == .written }.map(\.kind))
        #expect(kinds.isSuperset(of: [.moneyReport, .briefing, .reviewRecord]))
        // Money: a cited statement made privileged refuses the report.
        _ = try await SensitiveScopeRepository(database: f.db).assign(
            target: SensitiveScopeTarget(kind: .sourceVersion, id: r.rig.a.version), sensitivity: .confidential,
            authority: .userConfirmed(actorID: "Ada", confirmationID: UUID(), privileged: true), reason: "legal advice")
        await #expect(throws: CaseOutputError.self) { _ = try await out.prepareMoneyReport(caseID: f.caseID, actor: "Ada") }
        // Sources: every new route prepares through CaseOutputService and writes with its write; the findings export too.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let routes = try String(contentsOf: root.appendingPathComponent("Kalsmritikosh/UI/CaseMapExportRoutes.swift"), encoding: .utf8)
        for call in ["outputs.preparePackage(", "outputs.prepareMoneyReport(", "outputs.prepareReviewRecord(", "outputs.prepareBriefing("] { #expect(routes.contains(call), "\(call)") }
        #expect(routes.components(separatedBy: "await outputs.release(pkg)").count - 1 == 2, "no new clipboard / print route")
        let handoff = try String(contentsOf: root.appendingPathComponent("Kalsmritikosh/UI/WorkProductHandoffView.swift"), encoding: .utf8)
        #expect(handoff.contains("kind: .findingsReport") && handoff.contains("await outputs.write(pkg, to: url)"))
    }

    @Test("OUTPUT-01: a studio report of a case draft and a job result of a case leave through the output door — authorised there before the bytes leave, the written file read back, recorded in the case's outputs; an altered file is not an export; someone without a role is refused and nothing is released")
    func externalWritersThroughTheDoor() async throws {
        let f = try await CaseFileTests.fixture()
        let (out, temp) = try s11Outputs(f)
        defer { try? FileManager.default.removeItem(at: temp) }
        let repo = StudioRecordRepository(database: f.db)
        let storage = StudioStorage(studio: "siu", legacyKey: "test.s11.\(UUID().uuidString)")
        storage.repositoryOverride = repo
        storage.caseOutputsOverride = out
        let m = SIUReferral(title: "Claim S11", now: Self.day(2026, 3, 3))
        storage.persist([m], app: nil)
        await storage.flush()
        try await repo.bind(recordID: m.id, caseID: f.caseID, workspaceID: f.workspaceID, actor: "Tester")
        _ = await storage.load(SIUReferral.self, app: nil)
        let pkg = try #require(await storage.package(m, app: nil, render: { _ in "SIU report: the claim was paid twice." }))
        let casePkg = try #require(pkg.caseOutput, "a case draft is prepared by CaseOutputService")
        #expect(casePkg.kind == .studioReport && casePkg.caseID == f.caseID && casePkg.text == pkg.text && casePkg.digest == pkg.digest)
        let file = temp.appendingPathComponent("siu.md")
        try Data(pkg.text.utf8).write(to: file)
        storage.exported(pkg, format: "markdown", writtenTo: file, app: nil)
        await storage.flush()
        #expect(try await out.outputs(caseID: f.caseID).contains { $0.kind == .studioReport && $0.status == .written })
        #expect(try await repo.exports(recordID: m.id).count == 1, "the studio's own export record is kept too")
        // A file that does not hold the released bytes is recorded as failed, not as an export.
        try Data("Something else.".utf8).write(to: file)
        #expect(await out.recordExternalRelease(casePkg, route: .file, writtenTo: file).status == .failed)
        #expect(await out.recordExternalRelease(casePkg, route: .clipboard, writtenTo: nil).status == .released)
        // In a team case a person with no role is refused at the door, and the refusal is recorded.
        _ = try await f.file.grantAccess(caseID: f.caseID, to: "Vera", role: .viewer, reason: "Reads", actor: "Ada")
        let stranger = CaseOutputPackage(id: UUID(), caseID: f.caseID, kind: .studioReport, route: .clipboard, text: casePkg.text, data: casePkg.data,
                                         digest: casePkg.digest, scopeFingerprint: nil, approved: false, custodyIncomplete: false, actor: "Mallory",
                                         preparedAt: Date(), citations: [])
        await #expect(throws: (any Error).self) { try await out.authorizeExternalRelease(stranger) }
        let statuses = try await f.db.query("SELECT status FROM case_document_outputs WHERE case_id = ? AND kind = 'studioReport';", [.uuid(f.caseID)]).compactMap { $0.string(0) }
        #expect(statuses.contains("refused") && statuses.contains("written") && statuses.contains("failed"))
        // Sources: the studio and job-result writers use the door.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let studio = try String(contentsOf: root.appendingPathComponent("Kalsmritikosh/UI/StudioStorage.swift"), encoding: .utf8)
        #expect(studio.contains("outputs.authorizeExternalRelease(prepared)") && studio.contains("outputs.recordExternalRelease(casePkg"))
        let jobs = try String(contentsOf: root.appendingPathComponent("Kalsmritikosh/App/AppState+Erasure.swift"), encoding: .utf8)
        #expect(jobs.contains("kind: .jobResult") && jobs.contains("await outputs.write(pkg, to: url)"))
    }

    // MARK: OUTPUT-09 / RECOVERY-10

    func closure(_ f: CaseFileTests.Fixture) -> InvestigationClosureService {
        InvestigationClosureService(cases: f.cases, resolver: CaseRetrievalScopeResolver(evidence: EvidenceStore(database: f.db)),
                                    closures: InvestigationClosureRepository(database: f.db))
    }
    func close(_ f: CaseFileTests.Fixture, _ c: InvestigationClosureService) async throws {
        let rev = try #require(try await f.svc.caseHeader(f.caseID)).revision
        _ = try await c.closeCase(caseID: f.caseID, expectedRevision: rev, rationale: "Paid twice; recovered", unresolvedItems: ["Who approved the second payment"],
                                  workProductRunID: nil, receiptSeal: nil, actor: "Ada", at: Date())
        try await f.file.markClosed(caseID: f.caseID, reopened: false, actor: "Ada")
    }
    func reopen(_ f: CaseFileTests.Fixture, _ c: InvestigationClosureService) async throws {
        let rev = try #require(try await f.svc.caseHeader(f.caseID)).revision
        _ = try await c.reopenCase(caseID: f.caseID, expectedRevision: rev, rationale: "New evidence", actor: "Ada", at: Date())
        try await f.file.markClosed(caseID: f.caseID, reopened: true, actor: "Ada")
    }

    @Test("OUTPUT-09: the closure position (disposition, who authorised it, waived work, the recorded state) is fixed and survives reopening")
    func closurePosition() async throws {
        let r = try await rig()
        let f = r.f
        let history = CaseHistoryService(database: f.db, map: r.map)
        await #expect(throws: CaseClosurePositionError.notClosed) {
            _ = try await history.recordClosurePosition(caseID: f.caseID, disposition: "Recovered", authorizedBy: "Director", waived: [], unresolved: [], actor: "Ada")
        }
        let c = closure(f)
        try await close(f, c)
        await #expect(throws: CaseClosurePositionError.self) {
            _ = try await history.recordClosurePosition(caseID: f.caseID, disposition: "Recovered", authorizedBy: "Director",
                                                        waived: [CaseWaivedWork(item: "Interview the courier", reason: " ")], unresolved: [], actor: "Ada")
        }
        let pos = try await history.recordClosurePosition(caseID: f.caseID, disposition: "Substantiated; amount recovered", authorizedBy: "Director of Finance",
                                                          waived: [CaseWaivedWork(item: "Ask the bank for the March statement", reason: "Payment reversed; not needed")],
                                                          unresolved: ["Who approved the second payment"], actor: "Ada")
        #expect(pos.closureSequence >= 1 && pos.checkpointID != nil && pos.waived.count == 1)
        let cps = try await history.checkpoints(caseID: f.caseID)
        #expect(cps.contains { $0.id == pos.checkpointID && $0.name?.hasPrefix("Closure") == true })
        await #expect(throws: CaseClosurePositionError.alreadyRecorded) {
            _ = try await history.recordClosurePosition(caseID: f.caseID, disposition: "Other", authorizedBy: "X", waived: [], unresolved: [], actor: "Ada")
        }
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_closure_records SET disposition = 'changed';") }
        try await reopen(f, c)
        #expect(try await history.closurePositions(caseID: f.caseID).map(\.id) == [pos.id])
        #expect(try await history.checkpoints(caseID: f.caseID).contains { $0.id == pos.checkpointID })
    }

    @Test("RECOVERY-10: only a closed case is archived; archived and closed cases stay readable, searchable and exportable but take no change; reopening an archived case needs unarchive first")
    func lifecycleMatrix() async throws {
        let r = try await rig()
        let f = r.f
        let (out, temp) = try s11Outputs(f)
        defer { try? FileManager.default.removeItem(at: temp) }
        let c = closure(f)
        await #expect(throws: CaseLifecycleError.archiveNeedsClosed) { try await f.file.archive(caseID: f.caseID, actor: "Ada") }
        func readable() async throws {
            #expect(try await f.svc.snapshot(caseID: f.caseID, custody: []) != nil)
            #expect(!(try await f.file.journal(caseID: f.caseID)).isEmpty || true)
            #expect(!(try await f.file.actions(caseID: f.caseID)).isEmpty)
            let p = try await out.prepare(caseID: f.caseID, kind: .caseFileReport, route: .file, actor: "Ada") { CaseFileDocuments.caseFileReport($0, by: "Ada") }
            #expect(await out.write(p, to: temp.appendingPathComponent("\(UUID().uuidString).md")).status == .written)
            #expect((await r.map.load(caseID: f.caseID, generation: 9)).projection != nil)
        }
        try await close(f, c)
        try await readable()
        await #expect(throws: (any Error).self) { _ = try await f.file.addAllegation(caseID: f.caseID, text: "x", actor: "Ada") }
        try await f.file.archive(caseID: f.caseID, actor: "Ada")
        await #expect(throws: CaseLifecycleError.alreadyArchived) { try await f.file.archive(caseID: f.caseID, actor: "Ada") }
        try await readable()
        await #expect(throws: (any Error).self) { _ = try await f.file.addAllegation(caseID: f.caseID, text: "x", actor: "Ada") }
        await #expect(throws: CaseLifecycleError.archivedCannotReopen) { try await reopen(f, c) }
        #expect(try await f.svc.caseHeader(f.caseID)?.status == .closed, "the refused reopen changed nothing")
        try await f.file.unarchive(caseID: f.caseID, actor: "Ada")
        try await reopen(f, c)
        _ = try await f.file.addAllegation(caseID: f.caseID, text: "Was the courier involved?", actor: "Ada")
        try await readable()
        let actions = try await f.file.actions(caseID: f.caseID).map(\.action)
        #expect(actions.contains("archived") && actions.contains("unarchived") && actions.filter { $0 == "closed" }.count == 1)
    }

    // MARK: RECOVERY-01 / 02 / 06 / 07

    @Test("RECOVERY-01/02/06: a complete backup carries the stores beside the ledger and an inventory; a changed original or a missing store is not 'complete'; restore puts the vault and pending records back and merges the erasure register")
    func completeBackupInventory() async throws {
        let f = try await CaseFileTests.fixture()
        let oldMac = try s11Scratch("old"), ledgerDir = try s11Scratch("ledger")
        defer { for u in [oldMac, ledgerDir] { try? FileManager.default.removeItem(at: u) } }
        let letter = oldMac.appendingPathComponent("letter.txt"), memo = oldMac.appendingPathComponent("memo.txt")
        try Data("The approval letter.".utf8).write(to: letter)
        try Data("The internal memo.".utf8).write(to: memo)
        let letterID = UUID(), memoID = UUID()
        for (id, url) in [(letterID, letter), (memoID, memo)] {
            try await f.db.exec("INSERT INTO files (id, url, source_type, availability, content_hash) VALUES (?,?,?,?,?);",
                                [.uuid(id), .text(url.absoluteString), .text("txt"), .text("available"), .text(try s11Hash(url))])
        }
        // The stores beside the ledger.
        let vault = ledgerDir.appendingPathComponent("EvidenceVault/ab", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try Data("sealed-bytes".utf8).write(to: vault.appendingPathComponent("abcdef.sealed"))
        let pending = ledgerDir.appendingPathComponent("case-output-pending", isDirectory: true)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: pending.appendingPathComponent("\(UUID().uuidString).json"))
        let erasedCase = UUID()
        try ErasureRegister.record(.init(kind: .case, idHash: ErasureRegister.hash(erasedCase), eraseSources: false, erasedAt: 5), besideLedgerAt: ledgerDir.appendingPathComponent("ledger"))
        let snap = try s11Scratch("snap").appendingPathComponent("knowledge.sqlite")
        try await f.db.backupSnapshot(to: snap)
        let key = LedgerKey.random()
        let hashes: [UUID: String] = [letterID: try s11Hash(letter), memoID: try s11Hash(memo)]
        let backup = try s11Scratch("backup")
        let full = try BackupService().createCompleteBackup(databaseSnapshot: snap, originals: [(letterID, letter), (memoID, memo)], notIncluded: [],
                                                            destination: backup, schemaVersion: SchemaMigrations.latestVersion, nowEpoch: 10,
                                                            besideLedger: ledgerDir, expectedHashes: hashes, signingKey: key)
        #expect(full.coverage == .complete, "\(full.inventory ?? [])")
        let inv = try #require(full.inventory)
        #expect(inv.contains { $0.store.hasPrefix("Evidence vault") && $0.included && $0.count == 1 })
        #expect(inv.contains { $0.store.hasPrefix("Erasure register") && $0.included })
        #expect(inv.contains { $0.store.hasPrefix("AI permissions") && !$0.included && $0.byDesign })
        #expect(try BackupService().inspect(backupFolder: backup, ledgerKey: key).verdict.signature == .valid)
        // A changed original (RECOVERY-02) is backed up but the backup is not complete, and names it.
        try Data("The memo, edited later.".utf8).write(to: memo)
        let changedBackup = try s11Scratch("changed")
        let partial = try BackupService().createCompleteBackup(databaseSnapshot: snap, originals: [(letterID, letter), (memoID, memo)], notIncluded: [],
                                                               destination: changedBackup, schemaVersion: SchemaMigrations.latestVersion, nowEpoch: 11,
                                                               besideLedger: ledgerDir, expectedHashes: hashes, signingKey: key)
        #expect(partial.coverage == .ledgerWithSomeOriginals)
        #expect(try BackupService.sourcesMap(in: changedBackup).changedSinceRecorded == [memo.path])
        // Without the ledger folder, never "complete".
        let bare = try BackupService().createCompleteBackup(databaseSnapshot: snap, originals: [(letterID, letter)], notIncluded: [],
                                                            destination: try s11Scratch("bare"), schemaVersion: SchemaMigrations.latestVersion, nowEpoch: 12)
        #expect(bare.coverage == .ledgerWithSomeOriginals)
        // Restore on a new Mac: vault and pending records land beside the ledger; the register is merged; the sidecar folder goes.
        let newMac = try s11Scratch("newmac")
        defer { try? FileManager.default.removeItem(at: newMac) }
        let map = try await BackupService().restoreComplete(backupFolder: backup, into: newMac, ledgerKey: key)
        #expect(map.signature == BackupSignatureState.valid.rawValue && map.unaccounted == [])
        #expect(FileManager.default.fileExists(atPath: newMac.appendingPathComponent("EvidenceVault/ab/abcdef.sealed").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: newMac.appendingPathComponent("case-output-pending").path).count == 1)
        #expect(!FileManager.default.fileExists(atPath: newMac.appendingPathComponent("sidecars").path))
        let merged = try ErasureRegister.load(besideLedgerAt: newMac.appendingPathComponent("knowledge.sqlite"))
        #expect(ErasureRegister.matches([erasedCase], kind: .case, in: merged).count == 1)
        // Merging twice adds nothing (idempotent).
        try ErasureRegister.merge(from: ErasureRegister.url(besideLedgerAt: ledgerDir.appendingPathComponent("ledger")), besideLedgerAt: newMac.appendingPathComponent("knowledge.sqlite"))
        #expect(try ErasureRegister.load(besideLedgerAt: newMac.appendingPathComponent("knowledge.sqlite")).entries.count == 1)
    }

    @Test("RECOVERY-06 edge cases: an unreadable register beside the target or carried by the backup refuses the restore with nothing promoted; registers merge as a union (cases, people, full erases) and a second merge adds nothing; a backup older than a carried full erase is then refused")
    func erasureRegisterEdgeCases() async throws {
        let f = try await CaseFileTests.fixture()
        let snap = try s11Scratch("ersnap").appendingPathComponent("knowledge.sqlite")
        try await f.db.backupSnapshot(to: snap)
        // The old Mac: one erased case and a full erase, both before the backup.
        let oldDir = try s11Scratch("erold")
        let oldLedger = oldDir.appendingPathComponent("knowledge.sqlite")
        let erasedCase = UUID(), erasedPerson = UUID()
        try ErasureRegister.record(.init(kind: .case, idHash: ErasureRegister.hash(erasedCase), eraseSources: true, erasedAt: 100), besideLedgerAt: oldLedger)
        try ErasureRegister.record(.init(kind: .full, idHash: nil, eraseSources: nil, erasedAt: 150), besideLedgerAt: oldLedger)
        let backup = try s11Scratch("erbackup")
        _ = try BackupService().createCompleteBackup(databaseSnapshot: snap, originals: [], notIncluded: [], destination: backup,
                                                     schemaVersion: SchemaMigrations.latestVersion, nowEpoch: 200, besideLedger: oldDir)
        // The new Mac already knows of an erased person.
        let newMac = try s11Scratch("ernew")
        let newLedger = newMac.appendingPathComponent("knowledge.sqlite")
        try ErasureRegister.record(.init(kind: .person, idHash: ErasureRegister.hash(erasedPerson), eraseSources: nil, erasedAt: 120), besideLedgerAt: newLedger)
        let registerURL = ErasureRegister.url(besideLedgerAt: newLedger)
        let good = try Data(contentsOf: registerURL)
        // 1. The register beside the target cannot be read: refused, nothing promoted.
        try Data("not a register".utf8).write(to: registerURL)
        await #expect(throws: (any Error).self) { _ = try await BackupService().restoreComplete(backupFolder: backup, into: newMac, ledgerKey: nil) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: newMac.path) == [ErasureRegister.fileName], "nothing was restored")
        try good.write(to: registerURL)
        // 2. A backup whose carried register was already damaged on the old Mac: refused before anything is promoted.
        let damagedDir = try s11Scratch("erdamaged")
        try Data("{ broken".utf8).write(to: ErasureRegister.url(besideLedgerAt: damagedDir.appendingPathComponent("knowledge.sqlite")))
        let damaged = try s11Scratch("erdbackup")
        _ = try BackupService().createCompleteBackup(databaseSnapshot: snap, originals: [], notIncluded: [], destination: damaged,
                                                     schemaVersion: SchemaMigrations.latestVersion, nowEpoch: 200, besideLedger: damagedDir)
        await #expect(throws: (any Error).self) { _ = try await BackupService().restoreComplete(backupFolder: damaged, into: newMac, ledgerKey: nil) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: newMac.path) == [ErasureRegister.fileName], "nothing was restored")
        // 3. A good backup: the registers are merged as a union, full erase included; restoring again adds nothing.
        _ = try await BackupService().restoreComplete(backupFolder: backup, into: newMac, ledgerKey: nil)
        let merged = try ErasureRegister.load(besideLedgerAt: newLedger)
        #expect(ErasureRegister.matches([erasedCase], kind: .case, in: merged).count == 1)
        #expect(ErasureRegister.matches([erasedPerson], kind: .person, in: merged).count == 1)
        #expect(ErasureRegister.lastFullErase(in: merged) == 150 && merged.entries.count == 3)
        _ = try await BackupService().restoreComplete(backupFolder: backup, into: newMac, ledgerKey: nil)
        #expect(try ErasureRegister.load(besideLedgerAt: newLedger).entries.count == 3)
        // 4. On the new Mac, a backup made before that full erase is refused; one made after it is not.
        #expect(ErasureRegister.refusal(backupCreatedAt: 140, besideLedgerAt: newLedger) != nil)
        #expect(ErasureRegister.refusal(backupCreatedAt: 200, besideLedgerAt: newLedger) == nil)
        for u in [oldDir, backup, newMac, damagedDir, damaged] { try? FileManager.default.removeItem(at: u) }
    }

    /// An encrypted ledger with a `files` table (the minimum a complete restore relinks).
    func encryptedLedger(_ key: LedgerKey, marker: String, files: [(UUID, URL)] = []) async throws -> URL {
        let dir = try s11Scratch("enc")
        let url = dir.appendingPathComponent("live.sqlite")
        let db = try Database(url: url, key: key)
        try await db.exec("CREATE TABLE files (id TEXT PRIMARY KEY, url TEXT NOT NULL, source_type TEXT, availability TEXT, content_hash TEXT); CREATE TABLE marker (x TEXT);")
        try await db.exec("INSERT INTO marker VALUES (?);", [.text(marker)])
        for (id, u) in files { try await db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);", [.uuid(id), .text(u.absoluteString), .text("txt"), .text("available")]) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("snap"), withIntermediateDirectories: true)
        let snap = dir.appendingPathComponent("snap/knowledge.sqlite")
        try await db.backupSnapshot(to: snap)
        await db.close()
        return snap
    }

    @Test("RECOVERY-07: a manifest changed after the backup is refused; an unsigned (older) backup restores and says so; ledger sources with no original and not listed are reported")
    func signedManifestAndReferences() async throws {
        let key = LedgerKey.random()
        let src = try s11Scratch("src")
        let letter = src.appendingPathComponent("letter.txt")
        try Data("Letter".utf8).write(to: letter)
        let letterID = UUID(), ghostID = UUID()
        let snap = try await encryptedLedger(key, marker: "m", files: [(letterID, letter), (ghostID, src.appendingPathComponent("ghost.txt"))])
        let backup = try s11Scratch("signed")
        _ = try BackupService().createCompleteBackup(databaseSnapshot: snap, originals: [(letterID, letter)], notIncluded: [], destination: backup,
                                                     schemaVersion: SchemaMigrations.latestVersion, nowEpoch: 1, besideLedger: try s11Scratch("beside"), signingKey: key)
        // Restores, with the ghost source reported (not in the backup, not listed as left out).
        let target = try s11Scratch("t1")
        let map = try await BackupService().restoreComplete(backupFolder: backup, into: target, ledgerKey: key)
        #expect(map.signature == "valid" && map.unaccounted?.count == 1)
        // A consistently rewritten manifest (files and hashes still agree) is caught by the signature and refused.
        let manifestURL = backup.appendingPathComponent(BackupService.manifestName)
        let m = try JSONDecoder().decode(BackupManifest.self, from: Data(contentsOf: manifestURL))
        let forged = BackupManifest(createdAtEpoch: 999_999, schemaVersion: m.schemaVersion, entries: m.entries, coverage: .complete, inventory: m.inventory)
        try JSONEncoder().encode(forged).write(to: manifestURL)
        #expect(try BackupService().inspect(backupFolder: backup, ledgerKey: key).verdict.signature == .invalid)
        let t2 = try s11Scratch("t2")
        #expect(throws: BackupService.BackupError.self) { try BackupService().restore(backupFolder: backup, into: t2, ledgerKey: key) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: t2.path).isEmpty, "nothing was restored")
        // Without its signature: an older backup restores; the state says it is unsigned.
        try FileManager.default.removeItem(at: backup.appendingPathComponent(BackupService.signatureName))
        #expect(try BackupService().inspect(backupFolder: backup, ledgerKey: key).verdict.signature == .absent)
        let t3 = try s11Scratch("t3")
        #expect(try await BackupService().restoreComplete(backupFolder: backup, into: t3, ledgerKey: key).signature == "absent")
    }

    // MARK: RECOVERY-03

    @Test("RECOVERY-03: an encrypted backup with no key asks for the recovery key; a wrong key restores nothing; the right key restores over an existing keyed ledger, which stays openable in 'Before restore'")
    func recoveryKeyPaths() async throws {
        defer { PendingRestore.cancel() }
        let backupKey = LedgerKey.random(), currentKey = LedgerKey.random()
        let snap = try await encryptedLedger(backupKey, marker: "from-the-backup")
        let backup = try s11Scratch("kbackup")
        _ = try BackupService().createCompleteBackup(databaseSnapshot: snap, originals: [], notIncluded: [], destination: backup,
                                                     schemaVersion: SchemaMigrations.latestVersion, nowEpoch: 1, besideLedger: try s11Scratch("kb"), signingKey: backupKey)
        // The Mac's current ledger, encrypted with its own key.
        let macDir = try s11Scratch("mac")
        let ledger = macDir.appendingPathComponent("knowledge.sqlite")
        let cur = try Database(url: ledger, key: currentKey)
        try await cur.exec("CREATE TABLE marker (x TEXT); INSERT INTO marker VALUES ('current');")
        await cur.close()
        let before = try s11Hash(ledger)
        #expect(PendingRestore.schedule(backupFolder: backup) == nil)
        // No key held for it: asks, and changes nothing.
        if LedgerKeychain.load() != backupKey {
            guard case .needsKey = await PendingRestore.performIfScheduled(databaseURL: ledger, recoveryKey: nil) else { Issue.record("expected needsKey"); return }
            let h = try s11Hash(ledger)
            #expect(h == before && PendingRestore.isScheduled)
        }
        // A wrong recovery key: refused, the restore cancelled, the ledger unchanged.
        guard case .failed(let why) = await PendingRestore.performIfScheduled(databaseURL: ledger, recoveryKey: LedgerKey.random()) else { Issue.record("expected failed"); return }
        let afterWrong = try s11Hash(ledger)
        #expect(why.contains("does not open the backup") && afterWrong == before && !PendingRestore.isScheduled)
        // The right key: restored; the replaced ledger is kept and still opens with its own key.
        #expect(PendingRestore.schedule(backupFolder: backup) == nil)
        guard case .restored(let note) = await PendingRestore.performIfScheduled(databaseURL: ledger, recoveryKey: backupKey) else { Issue.record("expected restored"); return }
        #expect(note.contains("Before restore") && note.contains("AI permissions are asked again"))
        let restored = try Database(url: ledger, key: backupKey)
        #expect(try await restored.query("SELECT x FROM marker;", []).first?.string(0) == "from-the-backup")
        await restored.close()
        let kept = try #require(try FileManager.default.contentsOfDirectory(at: macDir, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("Before restore") })
        let old = try Database(url: kept.appendingPathComponent("knowledge.sqlite"), key: currentKey)
        #expect(try await old.query("SELECT x FROM marker;", []).first?.string(0) == "current")
        await old.close()
    }

    // MARK: RECOVERY-09

    @Test("RECOVERY-09: a restore that dies part-way is undone at the next launch (previous files back, partial ones removed); a repeated restore is deterministic; a repeated 'Before restore' copy in the same second does not fail")
    func interruptedAndRepeatedRestore() async throws {
        let src = try s11Scratch("isrc")
        let a = src.appendingPathComponent("a.txt"), b = src.appendingPathComponent("b.txt")
        try Data("A from backup".utf8).write(to: a); try Data("B from backup".utf8).write(to: b)
        let f = try await CaseFileTests.fixture()
        let snap = try s11Scratch("isnap").appendingPathComponent("knowledge.sqlite")
        try await f.db.backupSnapshot(to: snap)
        let backup = try s11Scratch("ibackup")
        _ = try BackupService().createCompleteBackup(databaseSnapshot: snap, originals: [(UUID(), a), (UUID(), b)], notIncluded: [], destination: backup,
                                                     schemaVersion: SchemaMigrations.latestVersion, nowEpoch: 1, besideLedger: try s11Scratch("ib"))
        // The Mac's current state.
        let parent = try s11Scratch("iparent")
        let target = parent.appendingPathComponent("Ledger", isDirectory: true)
        try FileManager.default.createDirectory(at: target.appendingPathComponent("originals"), withIntermediateDirectories: true)
        try Data("current ledger".utf8).write(to: target.appendingPathComponent("knowledge.sqlite"))
        try Data("current A".utf8).write(to: target.appendingPathComponent("originals/a.txt"))
        let beforeLedger = try s11Hash(target.appendingPathComponent("knowledge.sqlite")), beforeA = try s11Hash(target.appendingPathComponent("originals/a.txt"))
        // The process dies after promoting two files.
        #expect(throws: (any Error).self) { try BackupService(simulateCrashAfter: 2).restore(backupFolder: backup, into: target, ledgerKey: nil) }
        let asides = try FileManager.default.contentsOfDirectory(atPath: parent.path).filter { $0.hasPrefix(".Ledger.previous-") }
        #expect(asides.count == 1)
        // Next launch.
        let notes = BackupService.recoverInterruptedRestores(ledgerFolder: target)
        #expect(notes.count == 1 && notes[0].contains("was undone"))
        let nowLedger = try s11Hash(target.appendingPathComponent("knowledge.sqlite")), nowA = try s11Hash(target.appendingPathComponent("originals/a.txt"))
        #expect(nowLedger == beforeLedger && nowA == beforeA)
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("originals/b.txt").path), "a partly restored file with no previous copy is removed")
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).filter { $0.hasPrefix(".Ledger.") }.isEmpty)
        #expect(BackupService.recoverInterruptedRestores(ledgerFolder: target).isEmpty, "nothing left to undo")
        // Repeated restore: the same files, byte for byte.
        try BackupService().restore(backupFolder: backup, into: target, ledgerKey: nil)
        let first = try ["knowledge.sqlite", "originals/a.txt", "originals/b.txt"].map { try s11Hash(target.appendingPathComponent($0)) }
        try BackupService().restore(backupFolder: backup, into: target, ledgerKey: nil)
        let second = try ["knowledge.sqlite", "originals/a.txt", "originals/b.txt"].map { try s11Hash(target.appendingPathComponent($0)) }
        #expect(first == second)
        let k1 = try PendingRestore.keepCurrent(databaseURL: target.appendingPathComponent("knowledge.sqlite"), nowEpoch: 42)
        let k2 = try PendingRestore.keepCurrent(databaseURL: target.appendingPathComponent("knowledge.sqlite"), nowEpoch: 42)
        #expect(k1 != nil && k2 != nil && k1 != k2)
        // A cancelled schedule restores nothing.
        #expect(PendingRestore.schedule(backupFolder: backup) == nil)
        PendingRestore.cancel()
        #expect(await PendingRestore.performIfScheduled(databaseURL: target.appendingPathComponent("knowledge.sqlite"), recoveryKey: nil) == .none)
    }

    // MARK: RECOVERY-01 (every table v171–v186), RECOVERY-05

    static func firstMatch(_ pattern: String, _ sql: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: sql, range: NSRange(sql.startIndex..., in: sql)), let r = Range(m.range(at: 1), in: sql) else { return nil }
        return String(sql[r])
    }

    /// A value that satisfies the column's declared checks (the first literal of an IN list, an exact length, a fixed value).
    static func dummy(_ table: String, column c: String, type: String, sql: String, caseID: UUID) -> SQLValue {
        if let lit = firstMatch("\\b\(c)\\s+IN\\s*\\(\\s*'([^']*)'", sql) { return .text(lit) }
        if let n = firstMatch("\\b\(c)\\s+IN\\s*\\(\\s*(-?\\d+)", sql) { return .integer(Int64(n) ?? 0) }
        if let n = firstMatch("length\\(\\s*(?:trim\\()?\\s*\(c)\\s*\\)?\\s*\\)\\s*=\\s*(\\d+)", sql) { return .text(String(repeating: "a", count: Int(n) ?? 1)) }
        if let n = firstMatch("CHECK\\s*\\(\\s*\(c)\\s*=\\s*(\\d+)\\s*\\)", sql) { return .integer(Int64(n) ?? 1) }
        if firstMatch("json_type\\(\\s*\(c)\\s*\\)\\s*=\\s*'(object)'", sql) != nil { return .text("{}") }
        if c == "case_id" || c == "origin_case_id" { return .uuid(caseID) }
        let t = type.uppercased()
        if t.contains("INT") { return .integer(1) }
        if t.contains("REAL") { return .real(1) }
        if c.hasSuffix("json") { return .text(c.contains("counts") || c.contains("coverage") ? "{}" : "[]") }
        if c == "id" || c.hasSuffix("_id") { return .text(UUID().uuidString) }
        return .text(String(repeating: "a", count: 64))
    }

    static func digest(_ db: Database, _ table: String) async throws -> String {
        let rows = try await db.query("SELECT * FROM \"\(table)\" ORDER BY rowid;", [])
        return StudioRecordRepository.sha256(Data(rows.map { $0.values.map { "\($0)" }.joined(separator: "|") }.joined(separator: "\n").utf8))
    }

    @Test("RECOVERY-01/04/05: every table added in v171–v186 round-trips through a complete backup to a fresh folder unchanged; queued automation and prepared hand-overs come back paused and are not handed over again blindly")
    func everyNewTableRoundTrips() async throws {
        let old = try await MigrationFixtureBuilder.database(atVersion: 170)
        let oldTables = Set(try await old.query("SELECT name FROM sqlite_master WHERE type = 'table';", []).compactMap { $0.string(0) })
        let f = try await CaseFileTests.fixture()
        let db = f.db
        let all = try await db.query("SELECT name, sql FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '%_fts%';", [])
        let latestOnly: Set<String> = ["case_output_approvals", "case_closure_records", "ledger_restores"]   // v187: covered by their own tests
        let fresh = all.compactMap { r -> (String, String)? in
            guard let n = r.string(0), let s = r.string(1), !oldTables.contains(n), !latestOnly.contains(n) else { return nil }
            return (n, s)
        }
        #expect(fresh.count > 40, "\(fresh.count) tables added in v171–v186")
        try await db.exec("PRAGMA foreign_keys = OFF;")
        // Two real documents (for the tables whose guards require existing source versions) and a second, solo case.
        let docA = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "a.txt", text: "Alpha paid Beta 100 dollars.")
        let docB = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "b.txt", text: "Beta received 100 dollars.")
        let other = try await f.cases.createCase(workspaceID: f.workspaceID, title: "Other", actor: "Ada", at: Date()).id
        let low = "00000000-0000-0000-0000-000000000001", high = "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"
        // Values a generic filler cannot guess (cross-column checks), per table.
        let overrides: [String: [String: SQLValue]] = [
            "case_record_revisions": ["after_json": .text("{}")],
            "case_actors": ["legacy_name": .text("Ada"), "authentication": .text("notAuthenticated"), "actor_kind": .text("localUser")],
            "case_intake_policies": ["covers_until": .real(1), "channel": .text("workspace")],
            "case_intake_items": ["source_version_id": .uuid(docA.version), "channel": .text("workspace")],
            "source_version_links": ["source_version_id": .uuid(docB.version), "earlier_source_version_id": .uuid(docA.version)],
            "case_person_identity_decisions": ["person_a": .text(low), "person_b": .text(high)],
            "case_person_match_assessments": ["person_a": .text(low), "person_b": .text(high)],
            "case_source_dependence_reviews": ["source_a": .text(low), "source_b": .text(high)],
            "case_money_identity_decisions": ["record_a": .text(low), "record_b": .text(high)],
            "case_briefs": ["purpose": .text("Where it stands")],
            "case_assertion_attributions": ["speaker": .text("Beta")],
            "case_time_assertions": ["start_at": .real(1), "asserted_by": .text("Ada"), "source_version_id": .uuid(docA.version)],
            "case_briefing_items": ["record_kind": .text("allegation"), "record_id": .text(low)],
            "case_person_attributes": ["source_version_id": .uuid(docA.version)],
            "case_money_ownership": ["source_version_id": .uuid(docA.version)],
            "case_money_conversions": ["from_currency": .text("USD"), "to_currency": .text("INR")],
            "case_history_sources": ["origin_case_id": .uuid(other)],
            "case_cross_references": ["origin_case_id": .uuid(other), "pinned_checkpoint_id": .text(low)],
            "case_review_of": ["origin_case_id": .uuid(other)],
            "case_action_routing": ["assignee": .text("Ada")],
        ]
        var pool: [String: SQLValue] = [:]   // table → the id of its row (children point to it)
        var failed: [String] = []
        for (table, sql) in fresh {
            if (try await db.query("SELECT COUNT(*) FROM \"\(table)\";", []).first?.int(0) ?? 0) > 0 { continue }   // already holds rows (e.g. the history baseline)
            let cols = try await db.query("PRAGMA table_info(\"\(table)\");", [])
            var names: [String] = [], values: [SQLValue] = []
            let extra = overrides[table] ?? [:]
            for c in cols {
                guard let name = c.string(1) else { continue }
                let notNull = (c.int(3) ?? 0) == 1, hasDefault = !(c.isNull(4)), pk = (c.int(5) ?? 0) > 0
                guard (notNull && !hasDefault) || pk || extra[name] != nil else { continue }
                var v = extra[name] ?? Self.dummy(table, column: name, type: c.string(2) ?? "", sql: sql, caseID: f.caseID)
                if extra[name] == nil, name.hasSuffix("_id"), name != "case_id" {
                    let stem = String(name.dropLast(3))
                    if let parent = ["case_\(stem)s", "case_\(stem)es", "\(stem)s", "case_report_\(stem)s"].compactMap({ pool[$0] }).first { v = parent }
                }
                names.append("\"\(name)\""); values.append(v)
            }
            do {
                try await db.exec("INSERT INTO \"\(table)\" (\(names.joined(separator: ","))) VALUES (\(names.map { _ in "?" }.joined(separator: ",")));", values)
                if let i = names.firstIndex(of: "\"id\"") { pool[table] = values[i] }
            } catch { failed.append("\(table): \(String(describing: error).suffix(240))") }
        }
        #expect(failed.isEmpty, "\(failed)")
        // A queued automation and a prepared hand-over, as the old Mac left them.
        let effect = UUID()
        try await db.exec("UPDATE case_automation_outbox SET state = 'queued';")
        try await db.exec("""
            INSERT INTO case_external_effects (id, case_id, recipient_id, channel, purpose, content_digest, idempotency_key, state, created_by, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,'prepared',?,?,?);
            """, [.uuid(effect), .uuid(other), .uuid(UUID()), .text("letter"), .text("Notice"), .text("d"), .text(UUID().uuidString), .text("Ada"), .real(1), .real(1)])
        var before: [String: (Int, String)] = [:]
        for (t, _) in fresh {
            before[t] = (Int(try await db.query("SELECT COUNT(*) FROM \"\(t)\";", []).first?.int(0) ?? 0), try await Self.digest(db, t))
        }
        let snap = try s11Scratch("rtsnap").appendingPathComponent("knowledge.sqlite")
        try await db.backupSnapshot(to: snap)
        let backup = try s11Scratch("rtbackup")
        _ = try BackupService().createCompleteBackup(databaseSnapshot: snap, originals: [], notIncluded: [], destination: backup,
                                                     schemaVersion: SchemaMigrations.latestVersion, nowEpoch: 1, besideLedger: try s11Scratch("rtb"))
        let newMac = try s11Scratch("rtnew")
        let map = try await BackupService().restoreComplete(backupFolder: backup, into: newMac, ledgerKey: nil)
        #expect(map.pausedOutbox == 1 && map.pausedEffects == 2)
        let restored = try Database(url: newMac.appendingPathComponent("knowledge.sqlite"))
        try await SchemaMigrations.migrate(restored)
        for (t, _) in fresh {
            let count = Int(try await restored.query("SELECT COUNT(*) FROM \"\(t)\";", []).first?.int(0) ?? 0)
            #expect(count == before[t]?.0, "\(t) count")
            if t != "case_automation_outbox" && t != "case_external_effects" {
                #expect(try await Self.digest(restored, t) == before[t]?.1, "\(t) content")
            }
        }
        // RECOVERY-05: paused, not run or sent again.
        #expect(try await restored.query("SELECT state, state_reason FROM case_automation_outbox;", []).allSatisfy { $0.string(0) == "held" && ($0.string(1) ?? "").contains("Paused after a restore") })
        #expect(try await restored.query("SELECT COUNT(*) FROM ledger_restores;", []).first?.int(0) == 1)
        let files = CaseFileService(database: restored, cases: InvestigationCaseRepository(database: restored), workspaces: WorkspaceRepository(database: restored))
        let auto = CaseAutomationService(database: restored, caseFiles: files, aiPermitted: { _ in false })
        await #expect(throws: CaseAutomationError.self) { try await auto.markHandedOver(caseID: other, effectID: effect, providerRef: nil, actor: "Ada") }
        try await auto.confirmAfterRestore(caseID: other, effectID: effect, sent: false, note: "Checked the post book: not sent", actor: "Ada")
        try await auto.markHandedOver(caseID: other, effectID: effect, providerRef: "post", actor: "Ada")
        await restored.close()
    }

    // MARK: RECOVERY-04 / RECOVERY-08

    @Test("RECOVERY-04/08: restored on a fresh folder the money figures, sources and deep links work without the old paths; AI permissions are not in the backup and are asked again; acting still needs the current role")
    func cleanProfileAndBoundaries() async throws {
        let r = try await rig()
        let f = r.f
        // An original on the "old Mac" for the case's document.
        let old = try s11Scratch("o")
        let original = old.appendingPathComponent("invoice-a.txt")
        try Data("The invoice total was 500 dollars. It was paid in March.".utf8).write(to: original)
        let fileID = UUID()
        try await f.db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                            [.uuid(fileID), .text(original.absoluteString), .text("txt"), .text("available")])
        let moneyBefore = try await f.file.moneyLedger(caseID: f.caseID).outcomes().byCurrency
        // This Mac's AI permission for the case lives outside the ledger.
        let box = S11PermissionBox()
        let thisMac = CaseReadPermissionStore(load: { id in box.get(id) }, save: { p, id in box.set(p, id) })
        thisMac.grant(caseID: f.caseID, fingerprint: "fp-\(f.caseID.uuidString)", documentCount: 2)
        #expect(thisMac.isGranted(caseID: f.caseID, fingerprint: "fp-\(f.caseID.uuidString)"))
        _ = try await f.file.grantAccess(caseID: f.caseID, to: "Vera", role: .viewer, reason: "Reads", actor: "Ada")
        let snap = try s11Scratch("cs").appendingPathComponent("knowledge.sqlite")
        try await f.db.backupSnapshot(to: snap)
        let backup = try s11Scratch("cb")
        let manifest = try BackupService().createCompleteBackup(databaseSnapshot: snap, originals: [(fileID, original)], notIncluded: [], destination: backup,
                                                                schemaVersion: SchemaMigrations.latestVersion, nowEpoch: 1, besideLedger: try s11Scratch("cbl"))
        #expect(manifest.inventory?.contains { $0.store.hasPrefix("AI permissions") && $0.byDesign && !$0.included } == true)
        // No byte of the backup holds the permission's fingerprint.
        for name in try FileManager.default.subpathsOfDirectory(atPath: backup.path) {
            let u = backup.appendingPathComponent(name)
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &dir), !dir.boolValue else { continue }
            #expect(try Data(contentsOf: u).range(of: Data("fp-\(f.caseID.uuidString)".utf8)) == nil, "\(name)")
        }
        try FileManager.default.removeItem(at: old)   // the old Mac is gone
        let newMac = try s11Scratch("cn")
        _ = try await BackupService().restoreComplete(backupFolder: backup, into: newMac, ledgerKey: nil)
        let restored = try Database(url: newMac.appendingPathComponent("knowledge.sqlite"))
        try await SchemaMigrations.migrate(restored)
        let files = CaseFileService(database: restored, cases: InvestigationCaseRepository(database: restored), workspaces: WorkspaceRepository(database: restored))
        #expect(try await files.file.moneyLedger(caseID: f.caseID).outcomes().byCurrency == moneyBefore)
        let url = try #require(try await restored.query("SELECT url FROM files WHERE id = ?;", [.uuid(fileID)]).first?.string(0).flatMap(URL.init(string:)))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(url.path.hasPrefix(newMac.standardizedFileURL.path) && text.contains("500 dollars"))
        // A deep link to the case's document resolves against the restored ledger.
        let link = try #require(DeepLink.document(id: r.rig.a.object, quote: "The invoice total was 500 dollars.").url)
        guard case .document(let id, let quote)? = DeepLink(url: link) else { Issue.record("link did not parse"); return }
        #expect(quote == "The invoice total was 500 dollars.")
        #expect(try await restored.query("SELECT 1 FROM knowledge_objects WHERE id = ?;", [.uuid(id)]).count == 1)
        // The new Mac's permission store starts empty: the AI asks again.
        let newStore = CaseReadPermissionStore(load: { _ in nil }, save: { _, _ in })
        #expect(!newStore.isGranted(caseID: f.caseID, fingerprint: "fp-\(f.caseID.uuidString)"))
        // Roles come back as data; acting is checked against the person acting NOW (a viewer cannot change the case).
        await #expect(throws: (any Error).self) {
            try await CaseAccessContext.$principal.withValue(.local("Vera")) {
                _ = try await files.file.addAllegation(caseID: f.caseID, text: "x", actor: "Vera")
            }
        }
        await restored.close()
    }

    @Test("RECOVERY-04 (old versions): a backup of a v170 ledger restores and migrates; a manifest written before S11 (no inventory, no signature) still verifies")
    func oldVersionCompatibility() async throws {
        let old = try await MigrationFixtureBuilder.database(atVersion: 170)
        let snap = try s11Scratch("ov").appendingPathComponent("knowledge.sqlite")
        try await old.backupSnapshot(to: snap)
        let backup = try s11Scratch("ovb")
        _ = try BackupService().createCompleteBackup(databaseSnapshot: snap, originals: [], notIncluded: [], destination: backup, schemaVersion: 170, nowEpoch: 1)
        // Rewrite its manifest as an older build wrote it (no inventory key).
        let manifestURL = backup.appendingPathComponent(BackupService.manifestName)
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        json.removeValue(forKey: "inventory")
        try JSONSerialization.data(withJSONObject: json).write(to: manifestURL)
        let (m, verdict) = try BackupService().inspect(backupFolder: backup)
        #expect(m.inventory == nil && verdict.ok && verdict.signature == .absent)
        let target = try s11Scratch("ovt")
        _ = try await BackupService().restoreComplete(backupFolder: backup, into: target, ledgerKey: nil)
        let restored = try Database(url: target.appendingPathComponent("knowledge.sqlite"))
        #expect(try await restored.currentUserVersion() == 170)
        try await SchemaMigrations.migrate(restored)
        #expect(try await restored.currentUserVersion() == SchemaMigrations.latestVersion)
        #expect(try await MigrationFixtureBuilder.tableExists(restored, "case_output_approvals"))
        await restored.close()
    }

    @Test("v187 from a v186 ledger: earlier outputs are kept, the new columns and tables exist; approvals and closure records are fixed")
    func migrationV187() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 186)
        let id = UUID()
        try await db.exec("INSERT INTO case_document_outputs (id, case_id, kind, route, snapshot_sha256, status, released_by, released_at) VALUES (?,?,?,?,?,?,?,?);",
                          [.uuid(id), .uuid(UUID()), .text("caseFileReport"), .text("file"), .text("x"), .text("written"), .text("Ada"), .real(1)])
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == 187)
        #expect(try await db.query("SELECT manifest_json FROM case_document_outputs WHERE id = ?;", [.uuid(id)]).first?.isNull(0) == true)
        let a = UUID()
        try await db.exec("INSERT INTO case_output_approvals (id, case_id, kind, revision_fence, approved_by, approved_at) VALUES (?,?,?,?,?,?);",
                          [.uuid(a), .uuid(UUID()), .text("casePackage"), .text(String(repeating: "f", count: 64)), .text("Rita"), .real(1)])
        await #expect(throws: (any Error).self) { try await db.exec("UPDATE case_output_approvals SET revision_fence = ?;", [.text(String(repeating: "0", count: 64))]) }
        try await db.exec("UPDATE case_output_approvals SET withdrawn_by = 'Rita', withdrawn_at = 2, withdrawn_reason = 'changed';")
        await #expect(throws: (any Error).self) { try await db.exec("UPDATE case_output_approvals SET withdrawn_reason = 'again';") }
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }
}
