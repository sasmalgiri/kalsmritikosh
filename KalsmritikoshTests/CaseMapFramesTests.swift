//
//  CaseMapFramesTests.swift
//  KalsmritikoshTests
//
//  Smart-map M1 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md: ARCH-03, GRAPH-01–03, REPORT-01–05/10,
//  ACTION-01/03/04/11, MAP-08, SEARCH-08; schema v176). Deterministic throwaway ledgers, AI off — nothing here calls a
//  model or the network:
//  • the M1 journey: report → source-linked point → question → action → result → deeper point, twice, and exact
//    return navigation through eight frames;
//  • no depth cap, cycle-safe traversal with a budget that continues rather than drops; parent cycles refused;
//  • one record in two branches: one edit seen in both, separate positions per frame;
//  • points survive a re-ingest of their source, flagged stale, not lost; an accepted point is never rewritten;
//  • reveal inside a collapsed group (map and list), Find matches in collapsed groups, reveal out of a frame;
//  • self-review labelled; v175 → v176 keeps every position as the root frame; erasure and backup of the new tables.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@MainActor
private func framesDefaults() -> UserDefaults {
    let name = "caseframes.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name) ?? .standard
    d.removePersistentDomain(forName: name)
    return d
}

/// A case with a seeded forensic report document and the report recorded from it.
struct CaseFramesRig {
    let f: CaseFileTests.Fixture
    let doc: (version: UUID, object: UUID, blocks: [UUID])
    let report: UUID

    static let reportText = "The seal on bag 7 was intact on arrival. The sample weighed 12 grams. The result is valid only if the chain of custody is complete."

    static func make() async throws -> CaseFramesRig {
        let f = try await CaseFileTests.fixture(title: "Sample tampering")
        let doc = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "lab-report-41.txt", text: reportText)
        let report = try await f.file.addReport(caseID: f.caseID, CaseReportDetails(
            title: "Laboratory report 41", sourceVersionID: doc.version, producer: "City Forensic Lab", author: "Dr Rao", examinedMaterial: "Bag 7",
            reportDateText: "14 March 2026", methods: "Visual inspection of the seal", limitations: "Examined from photographs only"), actor: "Ada")
        return CaseFramesRig(f: f, doc: doc, report: report)
    }

    func node(_ kind: CaseMapRecordKind, _ id: UUID) -> CaseMapNodeID { CaseMapNodeID(caseID: f.caseID, kind: kind, id: id) }
    func projection() async throws -> CaseMapProjection { try #require(await caseMapLoad(f).projection) }
    @MainActor func model(_ defaults: UserDefaults) -> CaseMapWorkspaceModel {
        CaseMapWorkspaceModel(caseID: f.caseID, workspace: CaseWorkspaceHolder(caseID: f.caseID, defaults: defaults))
    }
}

@MainActor
@Suite("Smart map M1 — recursive frames, report points and child actions", .serialized)
struct CaseMapFramesTests {

    @Test("M1 journey, AI off: report → source-linked point → question → action → result → deeper point (twice); exact return through eight frames")
    func journey() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f, c = f.caseID
        // The point: the exact words, verified in the report's own version and pinned to their passage with a span.
        let quote = "The seal on bag 7 was intact on arrival."
        let point = try await f.svc.addPoint(caseID: c, reportID: rig.report, kind: .finding, statement: "The seal was intact when the bag arrived",
                                             quote: quote, locatorNote: "p. 2, §3", actor: "Ada")
        try await f.file.addQualification(caseID: c, pointID: point, kind: .condition, text: "valid only if the chain of custody is complete",
                                          quote: "The result is valid only if the chain of custody is complete.", actor: "Ada")
        var ledger = try await f.file.reportLedger(caseID: c)
        let pt = try #require(ledger.point(point))
        #expect(pt.isVerified && pt.sourceVersionID == rig.doc.version && pt.blockID == rig.doc.blocks[0])
        #expect(pt.charStart == 0 && pt.charEnd == quote.count && pt.locatorNote == "p. 2, §3")
        #expect(ledger.report(rig.report)?.producer == "City Forensic Lab" && ledger.report(rig.report)?.limitations == "Examined from photographs only")

        // Work from the point: a question and an action serving it, raised from the point.
        let question = try await f.svc.raiseQuestion(caseID: c, fromPoint: point, text: "Was the seal intact when the bag was collected?", actor: "Ada")
        let action = try await f.svc.createAction(caseID: c, .init(title: "Examine the seal photographs", purpose: "Whether the seal was intact at collection",
                                                                    deliverable: "A note on photos 1–6", responsible: "Ada", fromPoint: point,
                                                                    servesQuestions: [question]), actor: "Ada")
        try await f.svc.completeTask(caseID: c, taskID: action, actor: "Ada")
        try await f.file.submitAction(caseID: c, taskID: action, note: "Photos examined", actor: "Ada")
        // Solo: Ada reviews her own work — recorded as self-review, not refused, no second name invented.
        #expect(try await f.file.reviewAction(caseID: c, taskID: action, accept: true, note: nil, actor: "ada") == .selfReview)
        try await f.file.recordOutcome(caseID: c, taskID: action, outcome: .contradictionRemains, note: "Photo 3 differs", actor: "Ada")
        // The result, with its own deeper point, and a child action from it, with its own result and point.
        let result = try await f.svc.recordResult(caseID: c, taskID: action, title: "Seal photograph examination", methods: "Photos 1–6", actor: "Ada")
        let deeper = try await f.svc.addPoint(caseID: c, reportID: result, kind: .finding, statement: "Photo 3 shows a cut in the seal", quote: nil, actor: "Ada")
        let child = try await f.svc.createAction(caseID: c, .init(title: "Ask the courier about the cut", purpose: "When the cut happened",
                                                                   deliverable: "The courier's account", reviewer: "Ben", parentTaskID: action,
                                                                   fromPoint: deeper, servesQuestions: [question]), actor: "Ada")
        try await f.file.submitAction(caseID: c, taskID: child, note: nil, actor: "Ada")
        #expect(try await f.file.reviewAction(caseID: c, taskID: child, accept: true, note: nil, actor: "Ben") == .independent)
        let result2 = try await f.svc.recordResult(caseID: c, taskID: child, title: "Courier interview note", actor: "Ada")
        let deeper2 = try await f.svc.addPoint(caseID: c, reportID: result2, kind: .claim, statement: "The courier says the seal was cut at the depot", quote: nil, actor: "Ada")

        ledger = try await f.file.reportLedger(caseID: c)
        #expect(ledger.report(result)?.kind == .result && ledger.report(result)?.originTaskID == action && ledger.report(result)?.originPointID == point)
        #expect(ledger.report(result2)?.originPointID == deeper && ledger.contract(child)?.parentTaskID == action)
        #expect(ledger.contract(action)?.reviewKind == .selfReview && ledger.contract(action)?.outcome == .contradictionRemains)
        // Completed work leaves the question open: the outcome is separate, and the question keeps its own disposition.
        #expect(try await f.file.allegations(caseID: c).first { $0.id == question }?.disposition == .pending)

        // The projection: every hop is a typed link from the canonical records.
        let p = try await rig.projection()
        let n = (report: rig.node(.report, rig.report), point: rig.node(.reportPoint, point), question: rig.node(.allegation, question),
                 action: rig.node(.task, action), result: rig.node(.report, result), deeper: rig.node(.reportPoint, deeper),
                 child: rig.node(.task, child), result2: rig.node(.report, result2), deeper2: rig.node(.reportPoint, deeper2))
        func linked(_ a: CaseMapNodeID, _ type: CaseMapLinkType, _ b: CaseMapNodeID) -> Bool { p.links(of: a).contains { $0.from == a && $0.to == b && $0.type == type } }
        let logical = try #require(try await f.db.query("SELECT logical_source_id FROM source_versions WHERE id = ?;", [.uuid(rig.doc.version)]).first?.uuid(0))
        #expect(linked(n.report, .derivedFrom, rig.node(.document, logical)))
        #expect(linked(n.point, .derivedFrom, n.report) && linked(n.question, .derivedFrom, n.point) && linked(n.action, .derivedFrom, n.point))
        #expect(linked(n.action, .requestsEvidenceFor, n.question) && linked(n.result, .receivedInResponseTo, n.action) && linked(n.deeper, .derivedFrom, n.result))
        #expect(linked(n.child, .derivedFrom, n.action) && linked(n.child, .derivedFrom, n.deeper) && linked(n.result2, .receivedInResponseTo, n.child))
        #expect(linked(n.deeper2, .derivedFrom, n.result2) && linked(n.action, .derivedFrom, rig.node(.caseFile, c)))
        let pn = try #require(p.node(n.point))
        #expect(pn.qualifications.count == 1 && pn.wording?.contains("Qualified — Condition: valid only if the chain of custody is complete") == true)
        #expect(pn.title.hasSuffix("(qualified)") && pn.sources.first?.blockID == rig.doc.blocks[0] && pn.sources.first?.quote == quote)
        #expect(p.node(n.deeper)?.status.kind == .unsupported, "a point with no quoted words is not shown as verified")
        let an = try #require(p.node(n.action))
        #expect(an.wording?.contains("Expected result: A note on photos 1–6") == true && an.status.text.contains("Contradiction remains"))
        #expect(an.history.contains { $0.contains("Self-review (solo)") })
        #expect(p.node(n.child)?.history.contains { $0.contains("Independent review") } == true)

        // Exact return navigation through eight frames (no cap): each level's selection and viewport come back as left.
        let defaults = framesDefaults()
        let service = CaseMapService(sources: caseMapSources(f))
        let model = rig.model(defaults)
        await model.refresh(service)
        let rootPlacements = model.placements
        model.select(.node(n.question))
        let rootViewport = CaseMapViewport(scale: 0.7, originX: -11, originY: 22)
        model.setViewport(rootViewport)
        let path = [n.report, n.point, n.action, n.result, n.deeper, n.child, n.result2, n.deeper2]
        var left: [(CaseMapNodeID?, CaseMapViewport)] = []
        for (i, anchor) in path.enumerated() {
            await model.openFrame(anchor, service: service)
            #expect(model.frameStack.count == i + 1 && model.frame?.anchor == anchor)
            let frame = try #require(model.frame)
            #expect(model.result?.shown.first == anchor && Set(model.result?.shown ?? []) == Set([anchor] + frame.memberIDs))
            #expect(frame.memberIDs.allSatisfy { model.placements[$0] != nil } && model.placements[anchor] != nil)
            // Select a member of this frame and look at it from somewhere particular.
            let pick = frame.memberIDs.first
            if let pick { model.select(.node(pick)) }
            let vp = CaseMapViewport(scale: 1 + Double(i) / 10, originX: Double(i * 10), originY: Double(-i * 7))
            model.setViewport(vp)
            left.append((pick, vp))
        }
        #expect(model.frameStack.count == 8)
        #expect(model.breadcrumb.count >= 9 && model.frameTrail.count == 9)
        // The point's frame holds its report, its question, its action — the frames are a projection of the same records.
        let pointFrame = try #require(CaseMapFrames.frame(of: n.point, in: p))
        #expect(Set(pointFrame.memberIDs).isSuperset(of: [n.report, n.question, n.action]))
        // Back to level 3 (the action's frame): its selection and viewport exactly.
        await model.returnToFrame(depth: 3, service: service)
        #expect(model.frameStack.count == 3 && model.frame?.anchor == n.action)
        #expect(model.selection == left[2].0.map { .node($0) } && model.viewport() == left[2].1)
        // Then all the way out: the case map as it was left.
        await model.returnToFrame(depth: 0, service: service)
        #expect(model.frameStack.isEmpty && model.frame == nil)
        #expect(model.selection == .node(n.question) && model.viewport() == rootViewport && model.placements == rootPlacements)
        // AI off: nothing was sent anywhere.
        #expect(try await f.db.query("SELECT COUNT(*) FROM outbound_log;", []).first?.int(0) == 0)
    }

    @Test("No depth cap, cycle-safe: a twelve-deep chain of child actions is traversed whole; a budget returns a continuation, never drops; parent cycles are refused")
    func depthAndCycles() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f, c = f.caseID
        var chain: [UUID] = []
        for i in 0..<12 {
            chain.append(try await f.svc.createAction(caseID: c, .init(title: "Step \(i)", purpose: "Level \(i)", deliverable: "Note \(i)",
                                                                        parentTaskID: chain.last), actor: "Ada"))
        }
        // An investigative cycle (the deepest action back to the case) is allowed and does not loop a traversal.
        _ = try await CaseMapRepository(database: f.db).addLink(caseID: c, type: .dependsOn, from: rig.node(.task, chain[11]), to: rig.node(.caseFile, c),
                                                                 rationale: "closes the loop", actor: "Ada")
        let p = try await rig.projection()
        let start = rig.node(.task, chain[0])
        let whole = CaseMapFrames.traverse(from: start, in: p, budget: 10_000)
        #expect(whole.exhausted)
        for id in chain { #expect(whole.depth[rig.node(.task, id)] != nil, "every level reached") }
        #expect(Set(whole.depth.keys).count == whole.depth.count)
        // A small budget stops with a continuation; continuing from it reaches the rest — nothing is lost.
        let part = CaseMapFrames.traverse(from: start, in: p, budget: 3)
        #expect(!part.exhausted)
        var reached = Set(part.depth.keys)
        for n in part.continuation { reached.formUnion(CaseMapFrames.traverse(from: n, in: p, budget: 10_000).depth.keys) }
        #expect(reached.isSuperset(of: Set(whole.depth.keys)))
        // Twelve frames deep, then straight back.
        let model = rig.model(framesDefaults())
        let service = CaseMapService(sources: caseMapSources(f))
        await model.refresh(service)
        for id in chain { await model.openFrame(rig.node(.task, id), service: service) }
        #expect(model.frameStack.count == 12 && model.frame?.anchor == rig.node(.task, chain[11]))
        await model.returnToFrame(depth: 0, service: service)
        #expect(model.frameStack.isEmpty)
        // Ownership is acyclic: the root action cannot be put under its own descendant.
        await #expect(throws: CaseWorkError.parentCycle) {
            try await f.file.saveContract(caseID: c, taskID: chain[0], parentTaskID: chain[11], purpose: "p", deliverable: "d", responsible: nil, reviewer: nil, actor: "Ada")
        }
        #expect(try await f.file.reportLedger(caseID: c).contract(chain[0])?.parentTaskID == nil)
        // A frame pages its members; every member stays reachable.
        let frame = try #require(CaseMapFrames.frame(of: rig.node(.caseFile, c), in: p))
        let first = frame.page(offset: 0, limit: 1)
        #expect(first.members.count == 1 && first.remaining == frame.members.count - 1)
    }

    @Test("One record in two branches: an action serving two questions appears in both frames with its own position in each; one edit shows in both")
    func multipleAppearances() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f, c = f.caseID
        let q1 = try await f.file.addAllegation(caseID: c, text: "Was the seal intact at collection?", actor: "Ada")
        let q2 = try await f.file.addAllegation(caseID: c, text: "Did the courier open the bag?", actor: "Ada")
        let action = try await f.svc.createAction(caseID: c, .init(title: "Interview the courier", purpose: "Both questions", deliverable: "Statement",
                                                                    servesQuestions: [q1, q2]), actor: "Ada")
        let a = rig.node(.task, action)
        let service = CaseMapService(sources: caseMapSources(f))
        let model = rig.model(framesDefaults())
        await model.refresh(service)
        let rootPoint = try #require(model.placements[a]?.point)
        await model.openFrame(rig.node(.allegation, q1), service: service)
        #expect(model.frame?.contains(a) == true)
        await model.move(a, to: CaseMapPoint(x: 500, y: 500), repository: service.repository)
        await model.returnToFrame(depth: 0, service: service)
        await model.openFrame(rig.node(.allegation, q2), service: service)
        #expect(model.frame?.contains(a) == true)
        await model.move(a, to: CaseMapPoint(x: -300, y: 40), repository: service.repository)
        let repo = service.repository
        #expect(try await repo.layout(caseID: c, frame: CaseMapFrames.key(rig.node(.allegation, q1)))[a]?.point == CaseMapPoint(x: 500, y: 500))
        #expect(try await repo.layout(caseID: c, frame: CaseMapFrames.key(rig.node(.allegation, q2)))[a]?.point == CaseMapPoint(x: -300, y: 40))
        #expect(try await repo.layout(caseID: c)[a]?.point == rootPoint, "the case map's own position is untouched")
        // One canonical record: one task row, one contract; an edit shows wherever it appears.
        #expect(try await f.file.linkedTaskIDs(caseID: c).filter { $0 == action }.count == 1)
        try await f.file.recordOutcome(caseID: c, taskID: action, outcome: .answered, note: nil, actor: "Ada")
        await model.refresh(service)
        let p = try #require(model.projection)
        for q in [q1, q2] {
            let fr = try #require(CaseMapFrames.frame(of: rig.node(.allegation, q), in: p))
            #expect(fr.contains(a) && p.node(a)?.wording?.contains("Outcome: Question answered") == true)
        }
        #expect(model.frame?.anchor == rig.node(.allegation, q2) && model.placements[a]?.point == CaseMapPoint(x: -300, y: 40), "the open frame keeps its own position after a refresh")
    }

    @Test("Points survive a re-ingest of their source: kept with their locator and flagged stale; an accepted point is never rewritten")
    func reingestAndAcceptedPoints() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f, c = f.caseID
        let point = try await f.svc.addPoint(caseID: c, reportID: rig.report, kind: .finding, statement: "The sample weighed 12 grams",
                                             quote: "The sample weighed 12 grams.", actor: "Ada")
        try await f.file.reviewPoint(caseID: c, pointID: point, to: .accepted, actor: "Ada")
        await #expect(throws: CaseWorkError.acceptedPointLocked) {
            try await f.file.restatePoint(caseID: c, pointID: point, statement: "The sample weighed 13 grams", actor: "Ada")
        }
        await #expect(throws: (any Error).self) {
            try await f.db.exec("UPDATE case_report_points SET statement = 'rewritten' WHERE id = ?;", [.uuid(point)])
        }
        let before = try #require(try await f.file.reportLedger(caseID: c).point(point))
        #expect(try await rig.projection().node(rig.node(.reportPoint, point))?.status.kind == .recorded)

        // Re-ingest: a new current version of the report's document, included in the case.
        let logical = try #require(try await f.db.query("SELECT logical_source_id FROM source_versions WHERE id = ?;", [.uuid(rig.doc.version)]).first?.uuid(0))
        try await f.db.exec("UPDATE source_versions SET is_current = 0 WHERE logical_source_id = ?;", [.uuid(logical)])
        let v2 = UUID()
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try await f.db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at, filename, detected_type, detection_basis,
                size_bytes, custody_mode, preservation_status, intake_recorded_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(v2), .uuid(logical), .text(hex + hex), .real(300), .integer(1), .real(300), .text("lab-report-41 (re-read).txt"), .text("txt"),
                  .text("magicBytes"), .integer(1), .text("referenced"), .text("referenceRecorded"), .real(300)])
        let header = try await f.cases.fetch(caseID: c)?.caseHeader
        _ = try await f.cases.includeSource(caseID: c, expectedRevision: header?.revision ?? 1, sourceRef: v2.uuidString, sourceKind: .sourceVersion, actor: "Ada", at: Date())

        let after = try #require(try await f.file.reportLedger(caseID: c).point(point))
        #expect(after == before, "the point, its locator and its review are kept exactly")
        let p = try await rig.projection()
        let node = try #require(p.node(rig.node(.reportPoint, point)))
        #expect(node.status.kind == .stale && node.changedSourceWarning != nil && node.review == .accepted)
        #expect(node.sources.first?.sourceVersionID == rig.doc.version && node.sources.first?.blockID == before.blockID)
        #expect(p.node(rig.node(.report, rig.report))?.status.kind == .stale)
        // Recording deeper work never touches the accepted point.
        let action = try await f.svc.createAction(caseID: c, .init(title: "Re-weigh", purpose: "Check the weight", deliverable: "Weight", fromPoint: point), actor: "Ada")
        _ = try await f.svc.recordResult(caseID: c, taskID: action, title: "Re-weighing note", actor: "Ada")
        #expect(try await f.file.reportLedger(caseID: c).point(point) == before)
        // An amendment is a new report; the first one is kept.
        let amended = try await f.file.addReport(caseID: c, CaseReportDetails(title: "Laboratory report 41 (amended)", kind: .amendment,
                                                                             amendsReportID: rig.report, sourceVersionID: v2), actor: "Ada")
        let ledger = try await f.file.reportLedger(caseID: c)
        #expect(ledger.reports.count == 3 && ledger.report(rig.report)?.title == "Laboratory report 41" && ledger.report(amended)?.amendsReportID == rig.report)
        await #expect(throws: (any Error).self) {
            try await f.db.exec("UPDATE case_reports SET title = 'overwritten' WHERE id = ?;", [.uuid(rig.report)])
        }
    }

    @Test("Reveal: an item in a collapsed group is opened, selected and centred (map and list); Find matches in collapsed groups are offered; reveal leaves a frame that does not hold it")
    func revealInCollapsed() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f, c = f.caseID
        let point = try await f.svc.addPoint(caseID: c, reportID: rig.report, kind: .finding, statement: "The seal was intact",
                                             quote: "The seal on bag 7 was intact on arrival.", actor: "Ada")
        let pn = rig.node(.reportPoint, point)
        let service = CaseMapService(sources: caseMapSources(f))
        let model = rig.model(framesDefaults())
        await model.refresh(service)
        // The Overview starts with statements collapsed: the point is held back.
        #expect(model.view == .builtIn(.overview))
        #expect(!(model.result?.shown.contains(pn) ?? true))
        #expect(model.result?.collapsedGroups.contains { $0.members.contains(pn) } == true)
        // Find counts it as a match in a collapsed group.
        model.search = "seal intact"
        #expect(model.collapsedMatches.contains(pn))
        model.canvasSize = (800, 400)
        #expect(model.reveal(pn))
        #expect(model.result?.shown.contains(pn) == true && model.selection == .node(pn))
        let pt = try #require(model.displayPlacements[pn]?.point)
        let vp = model.viewport()
        #expect(abs((pt.x - vp.originX) * vp.scale - 400) < 0.5 && abs((pt.y - vp.originY) * vp.scale - 200) < 0.5, "centred")
        #expect(model.notice?.contains("opened the group") == true)
        // The list shows the same: switch to the list, collapse again, reveal from a hidden state too.
        model.listMode = true
        await model.toggleCollapse("group:statement", repository: service.repository, actor: "Ada")
        await model.hide(pn, repository: service.repository, actor: "Ada")
        #expect(!(model.result?.shown.contains(pn) ?? true))
        #expect(model.reveal(pn))
        #expect(model.result?.shown.contains(pn) == true && model.selection == .node(pn) && model.listMode)
        // From inside a frame that does not hold it, reveal returns to the case map first.
        let q = try await f.file.addAllegation(caseID: c, text: "Unrelated question", actor: "Ada")
        await model.refresh(service)
        await model.openFrame(rig.node(.allegation, q), service: service)
        #expect(model.frame?.contains(pn) == false)
        #expect(model.reveal(pn))
        #expect(model.frameStack.isEmpty && model.result?.shown.contains(pn) == true)
        // Something not in the case is reported, not faked.
        #expect(!model.reveal(rig.node(.reportPoint, UUID())))
    }

    @Test("v176 from a v175 ledger: every stored position is kept as the case's root frame; the new tables and guards exist")
    func migrationFromV175() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 175)
        let c = UUID(), a = UUID()
        try await db.exec("INSERT INTO case_map_layout (case_id, record_kind, record_id, x, y, pinned, updated_at) VALUES (?,?,?,?,?,?,?);",
                          [.uuid(c), .text("allegation"), .text(a.uuidString.lowercased()), .real(12), .real(-4), .integer(1), .real(1)])
        try await SchemaMigrations.migrate(db, through: 176)
        #expect(try await db.currentUserVersion() == 176)
        for t in ["case_reports", "case_report_points", "case_report_qualifications", "case_work_links", "case_action_contracts"] {
            #expect(try await MigrationFixtureBuilder.tableExists(db, t), "\(t) missing")
        }
        let id = CaseMapNodeID(caseID: c, kind: .allegation, id: a)
        let repo = CaseMapRepository(database: db)
        #expect(try await repo.layout(caseID: c) == [id: CaseMapPlacement(point: CaseMapPoint(x: 12, y: -4), pinned: true)])
        #expect(try await repo.layout(caseID: c, frame: "case:x").isEmpty)
        #expect(try await db.query("SELECT frame_key FROM case_map_layout;", []).first?.string(0) == "")
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
        #expect(try await MigrationFaultHarness.integrityOK(db))
        #expect(!SchemaMigrations.isIdempotent(try #require(SchemaMigrations.migrationSQL(for: 176))), "the layout rebuild is not re-run by the repair pass")
    }

    @Test("Self-review is labelled, independent review is labelled, and a result not submitted cannot be reviewed")
    func reviewKinds() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f, c = f.caseID
        let solo = try await f.svc.createAction(caseID: c, .init(title: "Solo", purpose: "p", deliverable: "d"), actor: "Ada")
        await #expect(throws: CaseWorkError.notSubmitted) { _ = try await f.file.reviewAction(caseID: c, taskID: solo, accept: true, note: nil, actor: "Ada") }
        try await f.file.submitAction(caseID: c, taskID: solo, note: nil, actor: "Ada")
        #expect(try await f.file.reviewAction(caseID: c, taskID: solo, accept: false, note: "more photos", actor: "Ada") == .selfReview)
        let k = try #require(try await f.file.reportLedger(caseID: c).contract(solo))
        #expect(k.review == .returned && k.reviewKind == .selfReview && k.reviewedBy == "Ada" && k.reviewKind?.label.contains("Self-review") == true)
        // A contract without purpose or deliverable is refused, and no untraceable task is left open.
        await #expect(throws: (any Error).self) { _ = try await f.svc.createAction(caseID: c, .init(title: "Vague", purpose: " ", deliverable: "d"), actor: "Ada") }
        #expect(try await f.svc.caseTasks(caseID: c).filter { $0.task.title == "Vague" }.isEmpty)
    }
}

// MARK: - Erasure and backup of the v176 tables

extension CaseErasureTests {

    static func seedV176(_ db: Database, caseID: UUID, naming: String = "secret") async throws -> UUID {
        let report = UUID(), point = UUID(), task = UUID()
        try await db.exec("INSERT INTO case_reports (id, case_id, title, report_kind, recorded_by, recorded_at) VALUES (?,?,?,?,?,?);",
                          [.uuid(report), .uuid(caseID), .text("Report \(naming)"), .text("original"), .text("Tester"), .real(1)])
        try await db.exec("INSERT INTO case_report_points (id, case_id, report_id, point_kind, statement, recorded_by, recorded_at) VALUES (?,?,?,?,?,?,?);",
                          [.uuid(point), .uuid(caseID), .uuid(report), .text("finding"), .text("Point about \(naming)"), .text("Tester"), .real(1)])
        try await db.exec("INSERT INTO case_report_qualifications (id, case_id, point_id, qualification_kind, text, recorded_by, recorded_at) VALUES (?,?,?,?,?,?,?);",
                          [.uuid(UUID()), .uuid(caseID), .uuid(point), .text("condition"), .text("only if \(naming)"), .text("Tester"), .real(1)])
        // v190: the task is an action of this case (the work link and the contract are checked against it).
        try await db.exec("INSERT OR IGNORE INTO case_task_links (case_id, task_id, created_at) VALUES (?,?,1);", [.uuid(caseID), .uuid(task)])
        try await db.exec("INSERT INTO case_work_links (id, case_id, work_kind, work_id, target_kind, target_id, role, created_by, created_at) VALUES (?,?,?,?,?,?,?,?,?);",
                          [.uuid(UUID()), .uuid(caseID), .text("task"), .uuid(task), .text("point"), .uuid(point), .text("raisedFrom"), .text("Tester"), .real(1)])
        try await db.exec("INSERT INTO case_action_contracts (task_id, case_id, purpose, deliverable, created_by, created_at, updated_at) VALUES (?,?,?,?,?,?,?);",
                          [.uuid(task), .uuid(caseID), .text("purpose \(naming)"), .text("deliverable"), .text("Tester"), .real(1), .real(1)])
        try await db.exec("INSERT INTO case_map_layout (case_id, frame_key, record_kind, record_id, x, y, pinned, updated_at) VALUES (?,?,?,?,?,?,?,?);",
                          [.uuid(caseID), .text("report:\(report.uuidString.lowercased())"), .text("reportPoint"), .text(point.uuidString.lowercased()),
                           .real(1), .real(2), .integer(0), .real(1)])
        return point
    }

    static let v176Tables = ["case_reports", "case_report_points", "case_report_qualifications", "case_work_links", "case_action_contracts", "case_map_layout"]

    static func v176Rows(_ db: Database, _ caseID: UUID) async throws -> Int {
        var n = 0
        for t in v176Tables { n += try await count(db, "SELECT COUNT(*) FROM \(t) WHERE case_id = ?;", [.uuid(caseID)]) }
        return n
    }

    @Test("v176: a case erase removes the case's reports, points, qualifications, work links, contracts and frame positions (a hold refuses it); another case's stay")
    func caseEraseCoversReports() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        _ = try await Self.seedV176(f.db, caseID: f.caseA)
        _ = try await Self.seedV176(f.db, caseID: f.caseB)
        let seeded = try await Self.v176Rows(f.db, f.caseA)
        #expect(seeded >= 6)
        let hold = UUID()
        try await f.db.exec("INSERT INTO legal_holds (id, name, created_at) VALUES (?,?,?);", [.uuid(hold), .text("Hold"), .date(Date())])
        try await f.db.exec("INSERT INTO legal_hold_items (hold_id, object_id, created_at) VALUES (?,?,?);", [.uuid(hold), .text(f.caseA.uuidString), .date(Date())])
        let refused = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: false, reason: "Client request", legalBasis: nil, actor: "Tester")
        #expect(refused.report.refused?.contains("legal hold") == true)
        #expect(try await Self.v176Rows(f.db, f.caseA) == seeded)
        try await f.db.exec("UPDATE legal_holds SET released_at = ? WHERE id = ?;", [.date(Date()), .uuid(hold)])
        let out = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: false, reason: "Client request", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil, "\(out.report.refused ?? "")")
        #expect(try await Self.v176Rows(f.db, f.caseA) == 0)
        #expect(try await Self.v176Rows(f.db, f.caseB) >= 6)
    }

    @Test("v176: a person erase removes frame positions anchored on their case-person rows and lists report points naming them; a full erase empties the tables")
    func personAndFullEraseCoverReports() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let row = try #require(try await f.db.query("SELECT id, value FROM entities WHERE kind = 'person' AND value LIKE '%Roberts%' LIMIT 1;", []).first)
        let entity = try #require(row.string(0).flatMap(UUID.init(uuidString:)))
        let name = row.string(1) ?? "Roberts"
        let person = UUID()
        try await f.db.exec("INSERT INTO case_people (id, case_id, name, role, entity_id, created_at) VALUES (?,?,?,?,?,?);",
                            [.uuid(person), .uuid(f.caseA), .text(name), .text("witness"), .uuid(entity), .real(1)])
        _ = try await Self.seedV176(f.db, caseID: f.caseA, naming: name)
        try await f.db.exec("INSERT INTO case_map_layout (case_id, frame_key, record_kind, record_id, x, y, pinned, updated_at) VALUES (?,?,?,?,?,?,?,?);",
                            [.uuid(f.caseA), .text("person:\(person.uuidString.lowercased())"), .text("case"), .text(f.caseA.uuidString.lowercased()),
                             .real(1), .real(2), .integer(0), .real(1)])
        let out = try await f.state.erasePerson(entity, reason: "Subject request", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil)
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM case_map_layout WHERE frame_key LIKE 'person:%';", []) == 0)
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM case_map_layout WHERE frame_key LIKE 'report:%';", []) == 1, "other frames stay")
        #expect((out.report.stillNamedIn["report points"] ?? 0) >= 1 && (out.report.stillNamedIn["report qualifications"] ?? 0) >= 1)
        _ = await f.state.deleteAllData()
        for t in Self.v176Tables { #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM \(t);", []) == 0, "\(t) not emptied") }
    }
}

extension CompleteBackupTests {

    @Test("v176: reports, points, qualifications, work links, contracts and per-frame positions travel in a complete backup and come back on restore")
    func reportsRoundTrip() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f, c = f.caseID
        let point = try await f.svc.addPoint(caseID: c, reportID: rig.report, kind: .finding, statement: "Seal intact", quote: "The seal on bag 7 was intact on arrival.", actor: "Ada")
        try await f.file.addQualification(caseID: c, pointID: point, kind: .limitation, text: "photos only", quote: nil, actor: "Ada")
        let action = try await f.svc.createAction(caseID: c, .init(title: "Check", purpose: "p", deliverable: "d", fromPoint: point), actor: "Ada")
        let frameKey = CaseMapFrames.key(CaseMapNodeID(caseID: c, kind: .reportPoint, id: point))
        let actionNode = CaseMapNodeID(caseID: c, kind: .task, id: action)
        try await CaseMapRepository(database: f.db).savePlacements(caseID: c, frame: frameKey, [actionNode: CaseMapPlacement(point: CaseMapPoint(x: 9, y: 8), pinned: true)])
        let before = try await f.file.reportLedger(caseID: c)

        let snap = try scratch("v176snap").appendingPathComponent("knowledge.sqlite")
        try await f.db.backupSnapshot(to: snap)
        let backup = try scratch("v176backup")
        _ = try BackupService().createCompleteBackup(databaseSnapshot: snap, originals: [], notIncluded: [], destination: backup,
                                                     schemaVersion: SchemaMigrations.latestVersion, nowEpoch: 1)
        let newMac = try scratch("v176new")
        _ = try await BackupService().restoreComplete(backupFolder: backup, into: newMac, ledgerKey: nil)
        let restored = try Database(url: newMac.appendingPathComponent("knowledge.sqlite"))
        #expect(try await CaseFileRepository(database: restored).reportLedger(caseID: c) == before)
        #expect(try await CaseMapRepository(database: restored).layout(caseID: c, frame: frameKey) == [actionNode: CaseMapPlacement(point: CaseMapPoint(x: 9, y: 8), pinned: true)])
        await restored.close()
    }
}
