//
//  CaseMapHistoryTests.swift
//  KalsmritikoshTests
//
//  Living case map M6–M8 (docs/IME_Living_Case_Map_Implementation_Plan_2026-11-06.md §6.3, §6.4, §7, §9, §12,
//  §13.1). Deterministic throwaway ledgers built on the supplier-payment rig of CaseMapTests (two invoices,
//  a rule-found contradiction), synthetic only, no reader, no network.
//  M6 seen ≠ approved; removed detection ≠ resolved; a source revision flags dependent work and changes no
//     decision; a failed feed is a failure, never empty; refresh keeps view, selection and positions.
//  M7 before/after copies in the same write; no invented pre-baseline history; exact replay of recorded states;
//     the past view excludes evidence recorded later (event time ≠ recorded time); history is read-only; a
//     checkpoint is consistent under a concurrent write; readiness is not raised by node count; retained
//     versions that are gone are shown as unavailable, never replaced by the current one.
//  M8 case/person/full erasure and holds; a case erased during an async load; restore to a new ledger; export
//     recheck (privilege labelled before release blocks it); historical export labelling; no canvas bypass;
//     v173 migration from v172 and older, restart during migration, refusal of a newer ledger.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@MainActor
private func historyDefaults() -> UserDefaults {
    let name = "casemaphistory.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name) ?? .standard
    d.removePersistentDomain(forName: name)
    return d
}

private func analysisService(_ f: CaseFileTests.Fixture) -> InvestigationAnalysisService {
    let evidence = EvidenceStore(database: f.db)
    return InvestigationAnalysisService(cases: f.cases, resolver: CaseRetrievalScopeResolver(evidence: evidence), evidence: evidence,
                                        analysis: InvestigationAnalysisRepository(database: f.db))
}

/// A newer version of a case document, recorded now and admitted to the case.
private func revise(_ rig: CaseMapRig, _ version: UUID, at date: Date = Date()) async throws -> UUID {
    let db = rig.f.db
    let logical = try await rig.logical(version)
    try await db.exec("UPDATE source_versions SET is_current = 0 WHERE logical_source_id = ?;", [.uuid(logical)])
    let v2 = UUID()
    let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    try await db.exec("""
        INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at, filename, detected_type, detection_basis,
            size_bytes, custody_mode, preservation_status, intake_recorded_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
        """, [.uuid(v2), .uuid(logical), .text(hex + hex), .date(date), .integer(1), .date(date), .text("invoice-a.txt"), .text("txt"),
              .text("magicBytes"), .integer(1), .text("referenced"), .text("referenceRecorded"), .date(date)])
    let header = try await rig.f.cases.fetch(caseID: rig.f.caseID)?.caseHeader
    _ = try await rig.f.cases.includeSource(caseID: rig.f.caseID, expectedRevision: header?.revision ?? 1, sourceRef: v2.uuidString,
                                            sourceKind: .sourceVersion, actor: "Ada", at: date)
    return v2
}

private func count(_ db: Database, _ sql: String, _ binds: [SQLValue] = []) async throws -> Int {
    Int(try await db.query(sql, binds).first?.int(0) ?? -1)
}

private func liveProjection(_ f: CaseFileTests.Fixture) async throws -> CaseMapProjection {
    try #require(await caseMapLoad(f).projection)
}

// MARK: - M6 change feed

@MainActor
@Suite("Case map M6 — change feed and impact", .serialized)
struct CaseChangeFeedTests {

    @Test("Seen is not approval: marking the feed as seen moves only the seen position — no review, decision, request status or case log entry changes; later changes are new again")
    func seenIsNotApproval() async throws {
        let rig = try await CaseMapRig.make()
        let f = rig.f
        let allegation = try await f.file.addAllegation(caseID: f.caseID, text: "The supplier was paid twice", actor: "Ada")
        _ = try await f.svc.linkEvidence(caseID: f.caseID, allegationID: allegation, evidenceRef: rig.a.version.uuidString, label: "invoice A", stance: .supports, note: nil,
                                         passage: StudioEvidenceRef(sourceVersionID: rig.a.version, objectID: rig.a.object, quote: "The invoice total was 500 dollars."), actor: "Ada")
        let request = try await analysisService(f).createEvidenceRequest(caseID: f.caseID, details: EvidenceRequestDetails(description: "Bank statements", allegationID: allegation),
                                                                         actor: "Ada", at: Date())
        let feeds = CaseChangeFeedService(database: f.db)
        let p = try await liveProjection(f)
        let load = await feeds.load(caseID: f.caseID, projection: p)
        #expect(load.state == .loaded)
        let alNode = CaseMapNodeID(caseID: f.caseID, kind: .allegation, id: allegation)
        #expect(load.changes.contains { $0.kind == .questionRevised && $0.record == alNode && $0.basis.isRecorded })
        #expect(load.changes.contains { $0.kind == .linkAdded && $0.record == alNode })
        #expect(load.changes.contains { $0.kind == .documentAdmitted })
        let actionsBefore = try await count(f.db, "SELECT COUNT(*) FROM case_actions WHERE case_id = ?;", [.uuid(f.caseID)])
        let revisionsBefore = try await count(f.db, "SELECT COUNT(*) FROM case_record_revisions WHERE case_id = ?;", [.uuid(f.caseID)])

        try await feeds.markSeen(load, actor: "Ada")

        // Nothing was reviewed, accepted or decided.
        let after = try await liveProjection(f)
        #expect(after.node(rig.node(.contradiction, rig.contradictionID))?.review == .unreviewed)
        #expect(try await f.file.allegations(caseID: f.caseID).first?.disposition == .pending)
        #expect(try await InvestigationAnalysisRepository(database: f.db).request(id: request.id)?.status == .open)
        #expect(try await count(f.db, "SELECT COUNT(*) FROM investigation_review_decisions WHERE case_id = ?;", [.uuid(f.caseID)]) == 0)
        #expect(try await count(f.db, "SELECT COUNT(*) FROM case_actions WHERE case_id = ?;", [.uuid(f.caseID)]) == actionsBefore)
        #expect(try await count(f.db, "SELECT COUNT(*) FROM case_record_revisions WHERE case_id = ?;", [.uuid(f.caseID)]) == revisionsBefore)
        let seen = try #require(try await feeds.seenPosition(caseID: f.caseID))
        #expect(seen.seenBy == "Ada" && seen.state.detections == [rig.contradictionID.uuidString.lowercased()])
        // The preference holds none of it; the state holds identifiers only.
        let raw = try #require(try await f.db.query("SELECT state_json FROM case_change_seen WHERE case_id = ?;", [.uuid(f.caseID)]).first?.string(0))
        // Identifiers are random UUIDs and can contain "500" by chance: check the words outside them.
        let words = raw.replacingOccurrences(of: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
                                             with: "<id>", options: .regularExpression)
        for word in ["invoice", "500", "Supplier", "paid"] { #expect(!words.contains(word), "\(word) in the seen state") }

        let quiet = await feeds.load(caseID: f.caseID, projection: after, now: Date().addingTimeInterval(1))
        #expect(quiet.newChanges.isEmpty, "\(quiet.newChanges.map(\.summary))")
        // A later change is new.
        try await Task.sleep(nanoseconds: 5_000_000)
        try await f.file.decide(allegationID: allegation, caseID: f.caseID, disposition: .unsubstantiated, rationale: "Only one payment cleared", actor: "Ada")
        let later = await feeds.load(caseID: f.caseID, projection: try await liveProjection(f), now: Date().addingTimeInterval(2))
        let decided = try #require(later.newChanges.first { $0.kind == .questionRevised })
        #expect(decided.record == alNode && decided.summary.contains("pending → unsubstantiated"))
    }

    @Test("A detection that disappears is “no longer detected”, never resolved: no decision is recorded and the feed says it is not a resolution")
    func removedDetectionIsNotResolved() async throws {
        let rig = try await CaseMapRig.make()
        let f = rig.f
        let feeds = CaseChangeFeedService(database: f.db)
        try await feeds.markSeen(await feeds.load(caseID: f.caseID, projection: try await liveProjection(f)), actor: "Ada")
        try await f.db.exec("DELETE FROM contradictions WHERE id IN (?, ?);", [.text(rig.contradictionID.uuidString), .text(rig.contradictionID.uuidString.lowercased())])
        let p = try await liveProjection(f)
        #expect(p.node(rig.node(.contradiction, rig.contradictionID)) == nil)
        let load = await feeds.load(caseID: f.caseID, projection: p, now: Date().addingTimeInterval(1))
        let gone = try #require(load.newChanges.first { $0.kind == .noLongerDetected })
        #expect(gone.record == rig.node(.contradiction, rig.contradictionID))
        #expect(gone.summary.contains("not a resolution") && !gone.basis.isRecorded)
        #expect(CaseChangeKind.noLongerDetected.label.contains("not resolved"))
        #expect(!load.changes.contains { $0.kind == .reviewDecided })
        #expect(try await count(f.db, "SELECT COUNT(*) FROM investigation_review_decisions;") == 0)
    }

    @Test("A revised source flags what rests on it — the allegation that cites it directly, items linked to that as may need review — and changes no decision; the map's Changes view shows them; positions, view and selection survive the refresh")
    func sourceRevisionFlagsDependents() async throws {
        let rig = try await CaseMapRig.make()
        let f = rig.f
        let allegation = try await f.file.addAllegation(caseID: f.caseID, text: "Paid twice", actor: "Ada")
        _ = try await f.svc.linkEvidence(caseID: f.caseID, allegationID: allegation, evidenceRef: rig.a.version.uuidString, label: "invoice A", stance: .supports, note: nil,
                                         passage: StudioEvidenceRef(sourceVersionID: rig.a.version, objectID: rig.a.object, quote: "The invoice total was 500 dollars."), actor: "Ada")
        try await f.file.decide(allegationID: allegation, caseID: f.caseID, disposition: .unsubstantiated, rationale: "One payment only", actor: "Ada")
        _ = try await rig.desk.reviewContradiction(caseID: f.caseID, contradictionID: rig.contradictionID, decision: .dismissed, reason: .differentEvent,
                                                   note: nil, actor: "Ada", at: Date())
        let service = CaseMapService(sources: caseMapSources(f))
        let feeds = CaseChangeFeedService(database: f.db)
        let model = CaseMapWorkspaceModel(caseID: f.caseID, workspace: CaseWorkspaceHolder(caseID: f.caseID, defaults: historyDefaults()))
        await model.refresh(service)
        await model.refreshFeed(feeds)
        await model.markSeen(feeds, actor: "Ada")
        let alNode = rig.node(.allegation, allegation)
        model.go(to: .builtIn(.questions))
        model.select(.node(alNode))
        await model.move(alNode, to: CaseMapPoint(x: 777, y: 333), repository: service.repository)
        let before = model.placements

        try await Task.sleep(nanoseconds: 5_000_000)
        _ = try await revise(rig, rig.a.version)
        await model.refresh(service)
        await model.refreshFeed(feeds)
        let feed = try #require(model.feed)
        let logicalA = try await rig.logical(rig.a.version)
        let docA = CaseMapNodeID(caseID: f.caseID, kind: .document, id: logicalA)
        let revised = try #require(feed.newChanges.first { $0.kind == .documentRevised })
        #expect(revised.record == docA && revised.summary.contains("in this case's scope") && !revised.basis.isRecorded)
        #expect(feed.newChanges.contains { $0.kind == .reviewReopened && $0.record == rig.node(.contradiction, rig.contradictionID) })
        let p = try #require(model.liveProjection)
        let impact = CaseChangeImpactAnalysis.impact(of: docA, in: p)
        #expect(impact.direct.contains { $0.node == alNode && $0.dependency.contains("supports") })
        #expect(impact.direct.contains { $0.node == rig.node(.contradiction, rig.contradictionID) })
        // Decisions are as they were.
        #expect(try await f.file.allegations(caseID: f.caseID).first { $0.id == allegation }?.disposition == .unsubstantiated)
        #expect(try await count(f.db, "SELECT COUNT(*) FROM investigation_review_decisions WHERE case_id = ?;", [.uuid(f.caseID)]) == 1)
        // The Changes view shows what rests on the changed document.
        #expect(model.changedRecords.contains(alNode))
        #expect(CaseMapViewFilter.apply(p, view: .changes, filter: CaseMapFilter(), changed: model.changedRecords).shown.contains(alNode))
        // Refresh kept the view, selection and positions.
        #expect(model.view == .builtIn(.questions) && model.selection == .node(alNode))
        for (id, pl) in before { #expect(model.placements[id]?.point == pl.point, "\(id) moved") }
    }

    @Test("A failed feed is a failure, never “nothing changed”; a part that fails is named; a failed feed cannot be marked seen; without a map the model fails visibly")
    func failedFeedIsNotEmpty() async throws {
        let rig = try await CaseMapRig.make()
        let f = rig.f
        let feeds = CaseChangeFeedService(database: f.db)
        let p = try await liveProjection(f)
        await feeds.setFaults(.init(seenUnreadable: true))
        let failed = await feeds.load(caseID: f.caseID, projection: p)
        if case .failed(let why) = failed.state { #expect(why.contains("not “nothing changed”")) } else { Issue.record("expected failed, got \(failed.state)") }
        #expect(failed.changes.isEmpty)
        await #expect(throws: CaseChangeFeedError.feedNotLoaded) { try await feeds.markSeen(failed, actor: "Ada") }
        await feeds.setFaults(.init(parts: [.requests, .links]))
        let partial = await feeds.load(caseID: f.caseID, projection: p)
        #expect(partial.state == .partial([.links, .requests]) && partial.failedParts == [.links, .requests])
        await feeds.setFaults(.init())
        // A case that is gone fails.
        let other = await feeds.load(caseID: UUID(), projection: p)
        if case .failed = other.state {} else { Issue.record("a different case's projection must fail") }
        // The model with no map read yet.
        let model = CaseMapWorkspaceModel(caseID: f.caseID, workspace: CaseWorkspaceHolder(caseID: f.caseID, defaults: historyDefaults()))
        await model.refreshFeed(feeds)
        if case .failed? = model.feed?.state {} else { Issue.record("expected a visible failure") }
    }
}

// MARK: - M7 history and readiness

@MainActor
@Suite("Case map M7 — history, checkpoints and readiness", .serialized)
struct CaseHistoryTests {

    @Test("Overwrite-only updates keep their before and after in the same write: the profile, a decision, a report selection; the copies cannot be edited or deleted")
    func beforeAfterKept() async throws {
        let f = try await CaseFileTests.fixture()
        var p = try await f.file.profile(caseID: f.caseID)
        p.intake = CaseIntake(channel: .hotline, allegationSummary: "Paid twice")
        try await f.file.saveProfile(p, actor: "Ada")
        p.intake = CaseIntake(channel: .hotline, allegationSummary: "Paid twice, March and April")
        try await f.file.saveProfile(p, actor: "Ben")
        let profile = try await CaseRecordRevisions.revisions(f.db, caseID: f.caseID, kind: "profile")
        #expect(profile.count == 2)
        let last = try #require(profile.last)
        #expect(last.value("allegation_summary").before == "Paid twice" && last.value("allegation_summary").after == "Paid twice, March and April")
        #expect(last.actor == "Ben" && last.change == "profileSaved" && last.changedFields.contains("allegation_summary"))
        // The copy belongs to the case log row written in the same savepoint.
        let action = try #require(last.actionID)
        #expect(try await count(f.db, "SELECT COUNT(*) FROM case_actions WHERE id = ? AND action = 'profileSaved';", [.uuid(action)]) == 1)
        let a = try await f.file.addAllegation(caseID: f.caseID, text: "A1", actor: "Ada")
        try await f.file.decide(allegationID: a, caseID: f.caseID, disposition: .inconclusive, rationale: "Not enough", actor: "Ada")
        let dec = try #require(try await CaseRecordRevisions.revisions(f.db, caseID: f.caseID, kind: "allegation", recordID: a).last)
        #expect(dec.value("disposition").before == "pending" && dec.value("disposition").after == "inconclusive")
        let item = try await f.file.addReportItem(caseID: f.caseID, allegationID: a, text: "Finding", quote: nil, evidenceRef: nil, origin: nil, actor: "Ada")
        try await f.file.setReportItem(caseID: f.caseID, id: item, included: false, reason: "Out of scope", actor: "Ada")
        let sel = try #require(try await CaseRecordRevisions.revisions(f.db, caseID: f.caseID, kind: "reportItem", recordID: item).last)
        #expect(sel.value("included").before == "1" && sel.value("included").after == "0")
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_record_revisions SET actor = 'x';", []) }
        await #expect(throws: (any Error).self) { try await f.db.exec("DELETE FROM case_record_revisions;", []) }
        // A refused write keeps no copy (the savepoint rolled back).
        let n = try await count(f.db, "SELECT COUNT(*) FROM case_record_revisions;")
        await #expect(throws: (any Error).self) {
            try await f.file.decide(allegationID: a, caseID: f.caseID, disposition: .substantiated, rationale: "notes only", actor: "Ada")
        }
        #expect(try await count(f.db, "SELECT COUNT(*) FROM case_record_revisions;") == n)
    }

    @Test("No invented history: before the baseline nothing was recorded and nothing is reconstructed; after it, only recorded states exist")
    func noInventedHistory() async throws {
        let rig = try await CaseMapRig.make()
        let f = rig.f
        let history = CaseHistoryService(database: f.db, map: CaseMapService(sources: caseMapSources(f)))
        let base = try await history.baseline(caseID: f.caseID)
        #expect(base.label.hasPrefix("Full map state not recorded before"))
        #expect(try await history.checkpoints(caseID: f.caseID).isEmpty)
        #expect(try await history.knownAt(caseID: f.caseID, base.effective.addingTimeInterval(-86_400)) == .notRecorded(baseline: base.effective))
        #expect(try await history.knownAt(caseID: f.caseID, Date().addingTimeInterval(5)) == .noRecordedStateYet(baseline: base.effective))
    }

    @Test("The multi-day case (plan §12): exact replay of each recorded state; the past view excludes evidence recorded later even when its event is earlier; comparison names what was added, changed and needs review; the daily record is written once a day")
    func multiDayReplay() async throws {
        let rig = try await CaseMapRig.make()
        let f = rig.f
        let service = CaseMapService(sources: caseMapSources(f))
        let history = CaseHistoryService(database: f.db, map: service)
        let day1 = Date()
        // Day 1: the question and two documents.
        let a = try await f.file.addAllegation(caseID: f.caseID, text: "Was this supplier paid twice, and were the payments authorised?", actor: "Ada")
        let live1 = try #require(await service.load(caseID: f.caseID, generation: 1))
        let cp1 = try await history.record(caseID: f.caseID, kind: .milestone, name: "Day 1", actor: "Ada", at: day1)
        // Day 2: a chronology entry recorded now about an event a month earlier; a supporting link.
        let eventDate = day1.addingTimeInterval(-30 * 86_400)
        let entry = try await f.file.addJournal(caseID: f.caseID, kind: .chronology, text: "First payment made", eventDate: eventDate,
                                                evidenceRef: rig.a.version.uuidString, quote: "It was paid in March.", actor: "Ada", at: day1.addingTimeInterval(86_400))
        _ = try await f.svc.linkEvidence(caseID: f.caseID, allegationID: a, evidenceRef: rig.b.version.uuidString, label: "invoice B", stance: .supports, note: nil,
                                         passage: StudioEvidenceRef(sourceVersionID: rig.b.version, objectID: rig.b.object, quote: "The invoice total was 650 dollars."), actor: "Ada")
        let cp2 = try await history.record(caseID: f.caseID, kind: .manual, actor: "Ada", at: day1.addingTimeInterval(86_400))

        // Exact replay: the recorded state is the map as it was read.
        let v1 = try await history.open(id: cp1.id, caseID: f.caseID)
        #expect(v1.payload == CaseCheckpointPayload.make(try #require(live1.projection), placements: live1.placements))
        #expect(v1.projection.nodes.map(\.id) == live1.projection?.nodes.map(\.id))
        #expect(v1.projection.nodes.map(\.revision) == live1.projection?.nodes.map(\.revision))
        #expect(v1.unavailableVersions.isEmpty && v1.manifest.nodeCount == v1.payload.nodes.count && v1.manifest.scopeFingerprint == cp1.scopeFingerprint)
        // Past view: Day 1 does not hold the entry recorded on Day 2, although its event is a month before Day 1.
        let jNode = CaseMapNodeID(caseID: f.caseID, kind: .journal, id: entry)
        #expect(v1.projection.node(jNode) == nil)
        let v2 = try await history.open(id: cp2.id, caseID: f.caseID)
        let j = try #require(v2.projection.node(jNode))
        #expect(j.eventDate.map { abs($0.timeIntervalSince(eventDate)) < 1 } == true)
        #expect(j.recordedAt.map { $0 > day1 } == true, "recorded time stays apart from event time")
        if case .recorded(let s, let exact) = try await history.knownAt(caseID: f.caseID, day1.addingTimeInterval(3600)) {
            #expect(s.id == cp1.id && !exact)
        } else { Issue.record("expected the Day 1 state") }
        if case .recorded(let s, let exact) = try await history.knownAt(caseID: f.caseID, cp2.recordedAt) { #expect(s.id == cp2.id && exact) }
        // Comparison by identity and revision.
        let cmp = CaseHistoryComparison.compare(v1.payload, v2.payload)
        #expect(cmp.entries.contains { $0.id == "node:\(jNode.key)" && $0.change == .added })
        #expect(cmp.count(.added) >= 1 && cmp.entries.filter { $0.isLink && $0.change == .added }.count >= 1)
        // Day 3: a revised document — the dismissed contradiction needs review in the comparison with now.
        _ = try await rig.desk.reviewContradiction(caseID: f.caseID, contradictionID: rig.contradictionID, decision: .dismissed, reason: .differentEvent,
                                                   note: nil, actor: "Ada", at: Date())
        _ = try await revise(rig, rig.a.version)
        let now = try #require(await service.load(caseID: f.caseID, generation: 9).projection)
        let cmpNow = CaseHistoryComparison.compare(v2.payload, CaseCheckpointPayload.make(now, placements: [:]))
        #expect(cmpNow.entries.contains { $0.id == "node:\(rig.node(.contradiction, rig.contradictionID).key)" && $0.change == .needsReview })
        // The daily record: once a day when the case changed; not again the same day; never when unchanged.
        let auto1 = await history.recordAutomaticIfChanged(caseID: f.caseID, actor: "Ada", at: day1.addingTimeInterval(2 * 86_400))
        #expect(auto1?.kind == .automatic)
        #expect(await history.recordAutomaticIfChanged(caseID: f.caseID, actor: "Ada", at: day1.addingTimeInterval(2 * 86_400 + 60)) == nil)
        #expect(await history.recordAutomaticIfChanged(caseID: f.caseID, actor: "Ada", at: day1.addingTimeInterval(4 * 86_400)) == nil, "unchanged: nothing new to record")
        // Recorded states are never edited.
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_checkpoints SET name = 'edited';", []) }
        await #expect(throws: (any Error).self) { try await f.db.exec("DELETE FROM case_checkpoints;", []) }
    }

    @Test("History is read-only: positions, pins, arrange, hide, saved views and undo are refused while a recorded state is shown; Return to current brings back the live case")
    func historyIsReadOnly() async throws {
        let rig = try await CaseMapRig.make()
        let f = rig.f
        let service = CaseMapService(sources: caseMapSources(f))
        let history = CaseHistoryService(database: f.db, map: service)
        let cp = try await history.record(caseID: f.caseID, kind: .manual, actor: "Ada")
        let model = CaseMapWorkspaceModel(caseID: f.caseID, workspace: CaseWorkspaceHolder(caseID: f.caseID, defaults: historyDefaults()))
        await model.refresh(service)
        let stored = try await service.repository.layout(caseID: f.caseID)
        model.openHistory(try await history.open(id: cp.id, caseID: f.caseID))
        #expect(model.isHistorical && model.loadState == .complete)
        let c = rig.node(.contradiction, rig.contradictionID)
        await model.move(c, to: CaseMapPoint(x: 9999, y: 9999), repository: service.repository)
        await model.togglePin(c, repository: service.repository)
        #expect(await model.arrange(.view, repository: service.repository) == 0)
        await model.hide(c, repository: service.repository, actor: "Ada")
        #expect(await model.saveCurrentView(named: "From the past", repository: service.repository, actor: "Ada") == nil)
        await model.resetView(repository: service.repository, service: service)
        #expect(model.notice?.contains("read-only") == true)
        #expect(try await service.repository.layout(caseID: f.caseID) == stored)
        #expect(try await service.repository.views(caseID: f.caseID).isEmpty)
        #expect(model.memory.hidden?.values.flatMap { $0 }.contains(c) != true)
        model.returnToCurrent()
        #expect(!model.isHistorical && model.projection?.caseID == f.caseID)
    }

    @Test("A checkpoint is consistent under a concurrent write: a change between the read and the write is never mixed in — it reads again; a case that keeps changing is refused")
    func checkpointUnderConcurrentWrite() async throws {
        let rig = try await CaseMapRig.make()
        let f = rig.f
        let service = CaseMapService(sources: caseMapSources(f))
        let history = CaseHistoryService(database: f.db, map: service)
        let file = f.file, caseID = f.caseID
        await history.setHooks(.init(beforeCommit: { attempt in
            if attempt == 1 { _ = try? await file.addAllegation(caseID: caseID, text: "Written meanwhile", actor: "Ben") }
        }))
        let cp = try await history.record(caseID: caseID, kind: .manual, actor: "Ada")
        let view = try await history.open(id: cp.id, caseID: caseID)
        #expect(view.payload.nodes.contains { $0.wording == "Written meanwhile" }, "the recorded state is the one after the change, never a mix")
        let fresh = try #require(await service.load(caseID: caseID, generation: 5).projection)
        #expect(view.payload.nodes.map(\.key) == CaseCheckpointPayload.make(fresh, placements: [:]).nodes.map(\.key))
        let fenceNow = try await service.repository.revisionFence(caseID: caseID)
        #expect(cp.fence == fenceNow)
        await history.setHooks(.init(beforeCommit: { _ in _ = try? await file.addAllegation(caseID: caseID, text: "Again", actor: "Ben") }))
        await #expect(throws: CaseHistoryError.keptChanging) { _ = try await history.record(caseID: caseID, kind: .manual, actor: "Ada") }
        #expect(try await history.checkpoints(caseID: caseID).count == 1)
    }

    @Test("Readiness is explicit states with no percentage: fifty more documents and notes raise nothing; contrary evidence recorded after a decision moves the question back to needs review")
    func readinessNotRaisedByNodeCount() async throws {
        let rig = try await CaseMapRig.make()
        let f = rig.f
        let a = try await f.file.addAllegation(caseID: f.caseID, text: "Paid twice", actor: "Ada")
        _ = try await f.svc.linkEvidence(caseID: f.caseID, allegationID: a, evidenceRef: rig.a.version.uuidString, label: "invoice A", stance: .supports, note: nil,
                                         passage: StudioEvidenceRef(sourceVersionID: rig.a.version, objectID: rig.a.object, quote: "The invoice total was 500 dollars."), actor: "Ada")
        try await f.file.decide(allegationID: a, caseID: f.caseID, disposition: .unsubstantiated, rationale: "One payment", actor: "Ada", at: Date().addingTimeInterval(-120))
        func readiness() async throws -> CaseReadiness {
            let p = try await liveProjection(f)
            let s = try #require(try await f.svc.snapshot(caseID: f.caseID, custody: []))
            return CaseReadiness.compute(projection: p, snapshot: s, requests: [], coverage: nil)
        }
        let r1 = try await readiness()
        let nodesBefore = try await liveProjection(f).nodes.count
        #expect(r1.area("questions")?.count("answered") == 1 && r1.area("questions")?.count("needsReview") == 0)
        for i in 0..<25 {
            _ = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "extra-\(i).txt", text: "Unrelated memo number \(i).")
            _ = try await f.file.addJournal(caseID: f.caseID, kind: .note, text: "Thought \(i)", eventDate: nil, evidenceRef: nil, actor: "Ada")
        }
        let r2 = try await readiness()
        let nodesAfter = try await liveProjection(f).nodes.count
        #expect(nodesAfter >= nodesBefore + 50, "\(nodesBefore) → \(nodesAfter)")
        #expect(r2.area("questions") == r1.area("questions"))
        #expect(r2.openItems == r1.openItems, "more items do not change open work")
        #expect(r2.area("evidence")?.count("read") ?? 0 > r1.area("evidence")?.count("read") ?? 0)
        // Contrary evidence after the decision lowers it.
        _ = try await f.svc.linkEvidence(caseID: f.caseID, allegationID: a, evidenceRef: rig.b.version.uuidString, label: "invoice B", stance: .contradicts, note: nil,
                                         passage: StudioEvidenceRef(sourceVersionID: rig.b.version, objectID: rig.b.object, quote: "The invoice total was 650 dollars."), actor: "Ada")
        let r3 = try await readiness()
        #expect(r3.area("questions")?.count("answered") == 0 && r3.area("questions")?.count("needsReview") == 1)
        #expect(r3.openItems == r2.openItems + 1)
        #expect(r3.attention.contains { $0.contains("needs review") })
        // No percentage anywhere.
        #expect(!r3.attention.joined().contains("%") && !r3.areas.flatMap(\.lines).map(\.label).joined().contains("%"))
    }

    @Test("A retained version that is gone is shown as unavailable — its words are not shown and the current version is never substituted")
    func unavailableRetainedVersion() async throws {
        let rig = try await CaseMapRig.make()
        let f = rig.f
        let history = CaseHistoryService(database: f.db, map: CaseMapService(sources: caseMapSources(f)))
        let cp = try await history.record(caseID: f.caseID, kind: .manual, actor: "Ada")
        try await f.db.exec("PRAGMA foreign_keys=OFF;")
        try await f.db.exec("DELETE FROM evidence_block_objects WHERE evidence_block_id IN (SELECT id FROM evidence_blocks WHERE source_version_id = ?);", [.uuid(rig.b.version)])
        try await f.db.exec("DELETE FROM evidence_blocks WHERE source_version_id = ?;", [.uuid(rig.b.version)])
        try await f.db.exec("DELETE FROM source_versions WHERE id = ?;", [.uuid(rig.b.version)])
        try await f.db.exec("PRAGMA foreign_keys=ON;")
        let view = try await history.open(id: cp.id, caseID: f.caseID)
        #expect(view.unavailableVersions == [rig.b.version])
        let c = try #require(view.projection.node(rig.node(.contradiction, rig.contradictionID)))
        #expect(c.wording?.contains("650") != true && c.wording?.contains("no longer available") == true)
        let gone = c.sources.filter { $0.sourceVersionID == rig.b.version }
        #expect(!gone.isEmpty && gone.allSatisfy { $0.quote == nil && $0.objectID == nil && $0.documentName == "Retained version no longer available" })
        #expect(!view.projection.nodes.flatMap(\.sources).contains { $0.sourceVersionID == rig.b.version && $0.quote != nil })
    }
}

// MARK: - M8 privacy, export and recovery

@MainActor
@Suite("Case map M8 — erasure, races, restore, export and migration", .serialized)
struct CaseMapRecoveryTests {

    private func seedHistory(_ rig: CaseMapRig) async throws -> CaseHistoryService {
        let f = rig.f
        let history = CaseHistoryService(database: f.db, map: CaseMapService(sources: caseMapSources(f)))
        _ = try await history.record(caseID: f.caseID, kind: .milestone, name: "Before interviews", actor: "Ada")
        let feeds = CaseChangeFeedService(database: f.db)
        try await feeds.markSeen(await feeds.load(caseID: f.caseID, projection: try await liveProjection(f)), actor: "Ada")
        var p = try await f.file.profile(caseID: f.caseID)
        p.intake = CaseIntake(channel: .hotline, allegationSummary: "Paid twice")
        try await f.file.saveProfile(p, actor: "Ada")
        return history
    }

    private func newTables(_ db: Database, _ caseID: UUID) async throws -> [String: Int] {
        var out: [String: Int] = [:]
        for t in ["case_checkpoints", "case_record_revisions", "case_change_seen"] {
            out[t] = try await count(db, "SELECT COUNT(*) FROM \(t) WHERE case_id = ?;", [.uuid(caseID)])
        }
        return out
    }

    @Test("Case erasure removes the case's recorded states, before/after copies and seen position; a legal hold refuses and keeps them; another case's stay")
    func caseErasure() async throws {
        let rig = try await CaseMapRig.make()
        let f = rig.f
        _ = try await seedHistory(rig)
        let other = try await f.cases.createCase(workspaceID: f.workspaceID, title: "Other", actor: "Ada", at: Date())
        var op = try await f.file.profile(caseID: other.id); op.intake = CaseIntake(channel: .hotline, allegationSummary: "x")
        try await f.file.saveProfile(op, actor: "Ada")
        #expect(try await newTables(f.db, f.caseID).values.allSatisfy { $0 > 0 })
        let hold = UUID()
        try await f.db.exec("INSERT INTO legal_holds (id, name, created_at) VALUES (?,?,?);", [.uuid(hold), .text("Hold"), .date(Date())])
        try await f.db.exec("INSERT INTO legal_hold_items (hold_id, object_id, created_at) VALUES (?,?,?);", [.uuid(hold), .text(f.caseID.uuidString), .date(Date())])
        let eraser = CaseEraser(database: f.db)
        let refused = try await eraser.erase(caseID: f.caseID, sourceVersionIDs: [rig.a.version, rig.b.version], eraseExclusiveSources: false,
                                             reason: "Client request", legalBasis: nil, actor: "Tester")
        #expect(refused.refused?.contains("legal hold") == true)
        #expect(try await newTables(f.db, f.caseID).values.allSatisfy { $0 > 0 })
        try await f.db.exec("UPDATE legal_holds SET released_at = ? WHERE id = ?;", [.date(Date()), .uuid(hold)])
        let out = try await eraser.erase(caseID: f.caseID, sourceVersionIDs: [rig.a.version, rig.b.version], eraseExclusiveSources: false,
                                         reason: "Client request", legalBasis: nil, actor: "Tester")
        #expect(out.refused == nil, "\(out.refused ?? "")")
        #expect(try await newTables(f.db, f.caseID).values.allSatisfy { $0 == 0 })
        #expect(try await count(f.db, "SELECT COUNT(*) FROM case_record_revisions WHERE case_id = ?;", [.uuid(other.id)]) == 1)
        #expect(try await count(f.db, "SELECT COUNT(*) FROM ledger_case_erase;") == 0)
    }

    @Test("Person erasure clears every recorded state that names the person (a stub stays, marked erased) and removes the before/after copies of their case-person row")
    func personErasure() async throws {
        let rig = try await CaseMapRig.make()
        let f = rig.f
        let entity = UUID()
        try await f.db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?,?,?,?,?);",
                            [.uuid(entity), .text("person"), .text("Ann Lee"), .text("ann lee"), .uuid(rig.a.object)])
        let person = try await f.file.addPerson(caseID: f.caseID, name: "Ann Lee", role: .witness, entityID: entity, contact: nil, notes: nil, actor: "Ada")
        let people = try await f.file.people(caseID: f.caseID)
        var row = try #require(people.first { $0.id == person }); row.notes = "Approved the payment"
        try await f.file.updatePerson(row, actor: "Ada")
        let history = try await seedHistory(rig)
        #expect(try await count(f.db, "SELECT COUNT(*) FROM case_record_revisions WHERE record_kind = 'person';") == 1)
        let report = try await CaseEraser(database: f.db).erasePerson(entityID: entity, reason: "Subject request", legalBasis: nil, actor: "Tester")
        #expect(report.refused == nil, "\(report.refused ?? "")")
        #expect(try await count(f.db, "SELECT COUNT(*) FROM case_record_revisions WHERE record_kind = 'person';") == 0)
        #expect(try await count(f.db, "SELECT COUNT(*) FROM case_checkpoints WHERE instr(lower(payload_json), 'ann lee') > 0;") == 0)
        let list = try await history.checkpoints(caseID: f.caseID)
        #expect(list.count == 1 && list[0].erasedAt != nil)
        await #expect(throws: CaseHistoryError.self) { _ = try await history.open(id: list[0].id, caseID: f.caseID) }
        #expect(try await count(f.db, "SELECT COUNT(*) FROM ledger_person_erase;") == 0)
        await #expect(throws: (any Error).self) { try await f.db.exec("DELETE FROM case_record_revisions;", []) }
    }

    @Test("Full erasure empties the new tables")
    func fullErasure() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        try await f.db.exec("""
            INSERT INTO case_checkpoints (id, case_id, kind, name, fence, scope_fingerprint, content_digest, manifest_json, payload_json, format_version, recorded_by, recorded_at)
            VALUES (?,?,'manual',NULL,'f','s','d','{}','{}',1,'Tester',1);
            """, [.uuid(UUID()), .uuid(f.caseA)])
        try await f.db.exec("INSERT INTO case_record_revisions (id, case_id, record_kind, record_id, change, after_json, actor, recorded_at) VALUES (?,?,?,?,?,?,?,?);",
                            [.uuid(UUID()), .uuid(f.caseA), .text("profile"), .text("x"), .text("profileSaved"), .text("{}"), .text("Tester"), .real(1)])
        try await f.db.exec("INSERT INTO case_change_seen (case_id, seen_through, state_json, seen_by, seen_at) VALUES (?,1,'{}','Tester',1);", [.uuid(f.caseA)])
        _ = await f.state.deleteAllData()
        for t in ["case_checkpoints", "case_record_revisions", "case_change_seen", "case_history_install", "ledger_person_erase"] {
            #expect(try await count(f.db, "SELECT COUNT(*) FROM \(t);") == 0, "\(t) not emptied")
        }
        // After a full erase, history starts again from a new baseline.
        #expect(try await CaseHistoryService.installBaseline(f.db) > Date().addingTimeInterval(-60))
    }

    @Test("A case erased during an async load: the late checkpoint, seen position and map positions are not written; the model drops the late feed and shows nothing of the case")
    func eraseDuringLoad() async throws {
        let rig = try await CaseMapRig.make()
        let f = rig.f
        let service = CaseMapService(sources: caseMapSources(f))
        let history = CaseHistoryService(database: f.db, map: service)
        let feeds = CaseChangeFeedService(database: f.db)
        let model = CaseMapWorkspaceModel(caseID: f.caseID, workspace: CaseWorkspaceHolder(caseID: f.caseID, defaults: historyDefaults()))
        await model.refresh(service)
        let p = try #require(model.liveProjection)
        let early = await feeds.load(caseID: f.caseID, projection: p)
        let db = f.db, caseID = f.caseID, versions: Set<UUID> = [rig.a.version, rig.b.version]
        await history.setHooks(.init(beforeCommit: { _ in
            _ = try? await CaseEraser(database: db).erase(caseID: caseID, sourceVersionIDs: versions, eraseExclusiveSources: false,
                                                         reason: "Erased meanwhile", legalBasis: nil, actor: "Tester")
        }))
        await #expect(throws: CaseHistoryError.caseNotFound) { _ = try await history.record(caseID: caseID, kind: .manual, actor: "Ada") }
        #expect(try await count(db, "SELECT COUNT(*) FROM case_checkpoints;") == 0)
        await #expect(throws: CaseChangeFeedError.caseNotFound) { try await feeds.markSeen(early, actor: "Ada") }
        #expect(try await count(db, "SELECT COUNT(*) FROM case_change_seen;") == 0)
        await #expect(throws: CaseMapError.caseNotFound) {
            try await service.repository.savePlacements(caseID: caseID, [rig.node(.contradiction, rig.contradictionID): CaseMapPlacement(point: CaseMapPoint(x: 1, y: 1))])
        }
        let late = model.beginFeedLoad()
        model.closeOut()
        #expect(!model.applyFeed(CaseChangeFeedLoad.failed(caseID, late, "late")))
        #expect(model.projection == nil && model.feed == nil && model.history == nil && model.result == nil, "nothing of the erased case is shown; the inspector has nothing to show")
        if case .failed = (await feeds.load(caseID: caseID, projection: p)).state {} else { Issue.record("a feed of an erased case must fail") }
    }

    @Test("Restore to a new ledger keeps the recorded states (digest intact), the before/after copies, the seen position and the saved views' identity")
    func restoreToNewLedger() async throws {
        let rig = try await CaseMapRig.make()
        let f = rig.f
        let history = try await seedHistory(rig)
        let viewID = try await CaseMapRepository(database: f.db).saveView(caseID: f.caseID, name: "Payments", base: .questions, filter: CaseMapFilter(), actor: "Ada")
        let cp = try #require(try await history.checkpoints(caseID: f.caseID).first)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("m8restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for d in ["snap", "backup", "newmac"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true) }
        let snap = root.appendingPathComponent("snap/knowledge.sqlite")
        try await f.db.backupSnapshot(to: snap)
        _ = try BackupService().createCompleteBackup(databaseSnapshot: snap, originals: [], notIncluded: [], destination: root.appendingPathComponent("backup"),
                                                     schemaVersion: SchemaMigrations.latestVersion, nowEpoch: 1)
        _ = try await BackupService().restoreComplete(backupFolder: root.appendingPathComponent("backup"), into: root.appendingPathComponent("newmac"), ledgerKey: nil)
        let restored = try Database(url: root.appendingPathComponent("newmac/knowledge.sqlite"))
        let back = CaseHistoryService(database: restored, map: CaseMapService(sources: CaseMapSources(custody: nil, snapshot: { _, _ in nil },
                                                                                                         objectsByVersion: { _ in [:] }, contradictions: nil,
                                                                                                         hypotheses: nil, requests: nil, map: CaseMapRepository(database: restored))))
        let view = try await back.open(id: cp.id, caseID: f.caseID)
        #expect(view.summary.contentDigest == cp.contentDigest && view.summary.name == "Before interviews")
        #expect(try await CaseRecordRevisions.revisions(restored, caseID: f.caseID, kind: "profile").count == 1)
        #expect(try await CaseChangeFeedService(database: restored).seenPosition(caseID: f.caseID)?.seenBy == "Ada")
        #expect(try await CaseMapRepository(database: restored).views(caseID: f.caseID).map(\.id) == [viewID])
        await restored.close()
    }

    private func outputs(_ f: CaseFileTests.Fixture) throws -> (CaseOutputService, URL) {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("m8out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let db = f.db
        let svc = CaseOutputService(database: f.db, caseFiles: f.svc, custody: { caseID in
            try await db.query("SELECT source_ref FROM investigation_case_sources WHERE case_id = ? AND in_scope = 1 AND source_kind = 'sourceVersion';", [.uuid(caseID)])
                .compactMap { $0.uuid(0) }.map { CustodyManifestEntry(sourceVersionID: $0, contentHash: nil, custodyEvents: []) }
        }, pendingDirectory: temp.appendingPathComponent("pending", isDirectory: true))
        return (svc, temp)
    }

    private func request(_ p: CaseMapProjection, _ placements: [CaseMapNodeID: CaseMapPlacement], state: CaseMapExportRequest.State) -> CaseMapExportRequest {
        let r = CaseMapViewFilter.apply(p, view: .overview, filter: CaseMapFilter(collapsed: []))
        return CaseMapExportRequest(projection: p, placements: placements, shown: r.shown, links: r.links, selection: nil, viewTitle: "Overview",
                                    state: state, scopeFingerprint: "fp")
    }

    @Test("Map export goes through the output door: PDF with the relationship table, frozen and recorded; a source labelled privileged before release refuses it and writes nothing; copy carries the table, protected")
    func exportRecheck() async throws {
        let rig = try await CaseMapRig.make()
        let f = rig.f
        let a = try await f.file.addAllegation(caseID: f.caseID, text: "Paid twice", actor: "Ada")
        _ = try await f.svc.linkEvidence(caseID: f.caseID, allegationID: a, evidenceRef: rig.a.version.uuidString, label: "invoice A", stance: .supports, note: nil,
                                         passage: StudioEvidenceRef(sourceVersionID: rig.a.version, objectID: rig.a.object, quote: "The invoice total was 500 dollars."), actor: "Ada")
        let (out, temp) = try outputs(f)
        defer { try? FileManager.default.removeItem(at: temp) }
        let load = await caseMapLoad(f)
        let req = request(try #require(load.projection), load.placements, state: .current(Date()))
        let pkg = try await out.prepareMap(req, format: .pdf, route: .file, actor: "Ada")
        #expect(pkg.kind == .caseMap && pkg.data.starts(with: Data("%PDF".utf8)))
        #expect(pkg.text.contains("row,from,relationship,to,why this link exists") && pkg.text.contains("supports") && pkg.text.contains("Legal holds now: none"))
        #expect(pkg.citations.contains { $0.sourceVersionID == rig.a.version })
        let url = temp.appendingPathComponent("map.pdf")
        let ok = await out.write(pkg, to: url)
        #expect(ok.status == .written && ok.recorded)
        // Prepared, then the source is labelled privileged before the release: refused, nothing written.
        let again = try await out.prepareMap(req, format: .pdf, route: .file, actor: "Ada")
        _ = try await SensitiveScopeRepository(database: f.db).assign(
            target: SensitiveScopeTarget(kind: .sourceVersion, id: rig.a.version), sensitivity: .confidential,
            authority: .userConfirmed(actorID: "Ada", confirmationID: UUID(), privileged: true), reason: "legal advice")
        let blocked = temp.appendingPathComponent("blocked.pdf")
        let refused = await out.write(again, to: blocked)
        #expect(refused.status == .refused && !FileManager.default.fileExists(atPath: blocked.path))
        var copied: String?
        let copy = await out.release(again) { text in copied = text; return true }
        #expect(copy.status == .refused && copied == nil)
        await #expect(throws: CaseOutputError.sourcesWithdrawn(1)) { _ = try await out.prepareMap(req, format: .csv, route: .clipboard, actor: "Ada") }
        #expect(try await out.outputs(caseID: f.caseID).contains { $0.kind == .caseMap && $0.status == .refused })
    }

    @Test("A historical export names the recorded state it depicts and applies today's restrictions (holds stated as they are now; protected names scrubbed)")
    func historicalExportLabelled() async throws {
        let rig = try await CaseMapRig.make()
        let f = rig.f
        _ = try await f.file.addPerson(caseID: f.caseID, name: "Meera Iyer", role: .witness, entityID: nil, contact: nil, notes: nil, actor: "Ada")
        let history = CaseHistoryService(database: f.db, map: CaseMapService(sources: caseMapSources(f)))
        let cp = try await history.record(caseID: f.caseID, kind: .milestone, name: "Day 2", actor: "Ada")
        // Today: a protected identity and a hold notice that did not exist when the state was recorded.
        let vault = JobResultRow(title: "Source", detail: "", fields: ["protected": "yes", "identity": "Meera Iyer"])
        _ = try await JobResultRepository(database: f.db).save(caseID: f.caseID, jobID: "jrn.source-vault", family: .interviewsQuotes, state: .draft,
                                                               content: JobResultContent(rows: [vault]), actor: "Ada")
        try await f.file.issueHold(caseID: f.caseID, custodian: "Finance", personID: nil, noticeText: "Preserve", reminderDue: nil, actor: "Ada")
        let view = try await history.open(id: cp.id, caseID: f.caseID)
        let (out, temp) = try outputs(f)
        defer { try? FileManager.default.removeItem(at: temp) }
        let pkg = try await out.prepareMap(request(view.projection, view.placements, state: .recorded(view.summary)), format: .csv, route: .file, actor: "Ada")
        #expect(pkg.text.contains("Recorded state: “Day 2”") && pkg.text.contains("This is not the case as it is now"))
        #expect(pkg.text.contains("1 unreleased hold notice(s)"))
        #expect(!pkg.text.contains("Meera Iyer") && pkg.text.contains("[PROTECTED SOURCE]"))
        let png = try await out.prepareMap(request(view.projection, view.placements, state: .recorded(view.summary)), format: .png, route: .file, actor: "Ada")
        #expect(png.data.starts(with: Data([0x89, 0x50, 0x4E, 0x47])))
    }

    @Test("No canvas bypass: no map screen renders itself to an image, the clipboard, a printer or a file except the export routes, and every route takes a package the output service prepared")
    func noCanvasBypass() throws {
        let ui = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Kalsmritikosh/UI")
        let files = try FileManager.default.contentsOfDirectory(atPath: ui.path).filter { $0.hasPrefix("CaseMap") && $0.hasSuffix(".swift") }
        #expect(files.count >= 6, "\(files)")
        let forbidden = ["ImageRenderer", "NSPasteboard", "NSPrintOperation", "AppPrinting", "fileExporter", "dataWithPDF", "cacheDisplay",
                         "bitmapImageRepForCachingDisplay", "NSSavePanel", ".write(to:", "CGImageDestination", "ShareLink", "NSSharingService"]
        for name in files where name != "CaseMapExportRoutes.swift" {
            let text = try String(contentsOf: ui.appendingPathComponent(name), encoding: .utf8)
            for token in forbidden { #expect(!text.contains(token), "\(name) uses \(token) outside the export routes") }
        }
        let routes = try String(contentsOf: ui.appendingPathComponent("CaseMapExportRoutes.swift"), encoding: .utf8)
        #expect(routes.contains("outputs.prepareMap(") && routes.contains("outputs.release(pkg)") && routes.contains("outputs.write(pkg, to: url)"))
        #expect(!routes.contains("ImageRenderer") && !routes.contains("cacheDisplay") && !routes.contains("dataWithPDF"))
        // Every NSPasteboard / printer use sits inside a release of a prepared package.
        for line in routes.split(separator: "\n") where line.contains("NSPasteboard.general.setString") || line.contains("AppPrinting.run") {
            #expect(line.contains("text") , "\(line)")
        }
        #expect(routes.components(separatedBy: "await outputs.release(pkg)").count - 1 == 2)
    }

    @Test("v173 from a v172 ledger (and an older one): earlier map and search rows are kept, the baseline is set, the guards exist; a fault during v173 rolls back and a restart migrates; a newer ledger is refused")
    func migrationV173() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 172)
        let ws = UUID(), c = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);", [.uuid(ws), .text("W"), .real(1), .real(1)])
        try await db.exec("INSERT INTO investigation_cases (id, workspace_id, title, status, revision, actor, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?);",
                          [.uuid(c), .uuid(ws), .text("C"), .text("open"), .integer(1), .text("u"), .real(1), .real(1)])
        let view = try await CaseMapRepository(database: db).saveView(caseID: c, name: "Kept", base: .overview, filter: CaseMapFilter(), actor: "Ada")
        #expect(!(try await MigrationFixtureBuilder.tableExists(db, "case_checkpoints")))
        // A fault after v173's SQL, before its stamp: everything rolls back.
        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.migrate(db, through: 173, fault: MigrationFaultHarness.hook(throwingAt: .afterSQLBeforeVersionStamp(version: 173)))
        }
        #expect(try await db.currentUserVersion() == 172)
        let cpTable = try await MigrationFixtureBuilder.tableExists(db, "case_checkpoints")
        let installTable = try await MigrationFixtureBuilder.tableExists(db, "case_history_install")
        #expect(!cpTable && !installTable)
        // The restart migrates.
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
        for t in ["case_history_install", "case_record_revisions", "case_change_seen", "case_checkpoints", "ledger_person_erase"] {
            #expect(try await MigrationFixtureBuilder.tableExists(db, t), "\(t) missing")
        }
        #expect(try await count(db, "SELECT COUNT(*) FROM case_history_install;") == 1)
        #expect(try await CaseMapRepository(database: db).views(caseID: c).map(\.id) == [view])
        #expect(try await MigrationFaultHarness.integrityOK(db))
        // An older ledger goes all the way.
        let old = try await MigrationFixtureBuilder.database(atVersion: 160)
        try await SchemaMigrations.migrate(old)
        #expect(try await old.currentUserVersion() == SchemaMigrations.latestVersion)
        #expect(try await MigrationFixtureBuilder.tableExists(old, "case_checkpoints"))
        // A ledger from a newer build is refused and left as it was.
        try await db.setUserVersion(SchemaMigrations.latestVersion + 1)
        await #expect(throws: (any Error).self) { try await SchemaMigrations.migrate(db) }
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion + 1)
        #expect(try await count(db, "SELECT COUNT(*) FROM case_map_views;") == 1)
    }
}
