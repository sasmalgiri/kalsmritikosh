//
//  CaseWorkspacePackageATests.swift
//  KalsmritikoshTests
//
//  Owner's implementation plan 2026-11-04 — package A scaffolding (schema v170), deterministic fixtures,
//  no reader and no network:
//  A1 (P0-C 3–4) a contradiction decided in the case screen keeps its decision over an unchanged rerun,
//     reopens with a visible note when one side's document is revised, records reasons and history, can be
//     deferred, and never touches either source; a confirmed item is carried without retyping.
//  A2 (P1-A) the case workspace (tab, selection, filter, search, last source) comes back when the model is
//     re-created from stored state; the overview counts what waits; every job stays reachable by search.
//  A3 (P1-B) three monthly statements requested, two plus a duplicate received → partly received with the
//     missing month listed; an unrelated file fulfils nothing; fulfilment only by a recorded decision;
//     a request made before v170 survives the migration.
//

import Foundation
import SwiftUI
import Testing
@testable import Kalsmritikosh

@MainActor
private func tempDefaults() -> UserDefaults {
    let name = "packageA.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name) ?? .standard
    d.removePersistentDomain(forName: name)
    return d
}

/// A new current version of the document behind `object`, included in the case (a revised source).
private func revise(_ db: Database, object: UUID, cases: InvestigationCaseRepository, caseID: UUID) async throws -> UUID {
    let fileID = try #require(try await db.query("SELECT file_id FROM knowledge_objects WHERE id = ?;", [.uuid(object)]).first?.uuid(0))
    try await db.exec("UPDATE source_versions SET is_current = 0 WHERE logical_source_id = ?;", [.uuid(fileID)])
    let version = UUID()
    let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    try await db.exec("""
        INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
            filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
        """, [.uuid(version), .uuid(fileID), .text(hex + hex), .real(200), .integer(1), .real(200),
              .text("revised.txt"), .text("txt"), .text("magicBytes"), .integer(1), .text("referenced"), .text("referenceRecorded"), .real(200)])
    let header = try await cases.fetch(caseID: caseID)?.caseHeader
    _ = try await cases.includeSource(caseID: caseID, expectedRevision: header?.revision ?? 1, sourceRef: version.uuidString,
                                      sourceKind: .sourceVersion, actor: "Ada", at: Date())
    return version
}

@MainActor
private struct ReviewRig {
    let f: CaseFileTests.Fixture
    let desk: InvestigationContradictionGapService
    let contradictions: ContradictionsRepository
    let a: (version: UUID, object: UUID, blocks: [UUID])
    let b: (version: UUID, object: UUID, blocks: [UUID])
    let finding: CaseContradictionFinder.Finding
    let qA = "The invoice total was 500 dollars.", qB = "The invoice total was 650 dollars."

    static func make() async throws -> ReviewRig {
        let f = try await CaseFileTests.fixture()
        let a = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "invoice-a.txt",
                                                          text: "The invoice total was 500 dollars. It was paid in March.")
        let b = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "invoice-b.txt",
                                                          text: "The invoice total was 650 dollars. It was paid in April.")
        let evidence = EvidenceStore(database: f.db)
        let contradictions = ContradictionsRepository(database: f.db)
        let desk = InvestigationContradictionGapService(cases: f.cases, resolver: CaseRetrievalScopeResolver(evidence: evidence), evidence: evidence,
                                                        contradictions: contradictions, gaps: GapNodeRepository(database: f.db),
                                                        reviews: InvestigationDeskReviewRepository(database: f.db))
        let finding = CaseContradictionFinder.Finding(kind: .amount, subject: "The invoice", attribute: "total",
                                                      quoteA: "The invoice total was 500 dollars.", quoteB: "The invoice total was 650 dollars.",
                                                      objectA: a.object, objectB: b.object, versionA: a.version, versionB: b.version,
                                                      valueA: "500 dollars", valueB: "650 dollars", provenance: .rules)
        await contradictions.insertMany([finding.contradiction()])
        return ReviewRig(f: f, desk: desk, contradictions: contradictions, a: a, b: b, finding: finding)
    }

    var id: UUID { finding.contradiction().id }
    /// The case check run again over the same documents: the same pair, the same stable id.
    func rerun() async { await contradictions.insertMany([finding.contradiction(at: Date().addingTimeInterval(60))]) }
    func item() async throws -> CaseContradictionReviewItem {
        try #require(try await desk.contradictionReviewItems(caseID: f.caseID).first { $0.id == id })
    }
}

// MARK: - A1 review in place

@MainActor
@Suite("Package A1 — contradiction review in place, durable decisions", .serialized)
struct ContradictionReviewInPlaceTests {

    @Test("Dismiss needs a reason; an unchanged rerun keeps it dismissed; revising one source reopens it with a note; history and sources stay")
    func dismissRerunRevise() async throws {
        let rig = try await ReviewRig.make()
        await #expect(throws: InvestigationDeskError.reasonRequired) {
            _ = try await rig.desk.reviewContradiction(caseID: rig.f.caseID, contradictionID: rig.id, decision: .dismissed, reason: nil,
                                                       note: nil, actor: "Ada", at: Date())
        }
        await #expect(throws: InvestigationDeskError.noteRequired) {
            _ = try await rig.desk.reviewContradiction(caseID: rig.f.caseID, contradictionID: rig.id, decision: .dismissed, reason: .other,
                                                       note: "  ", actor: "Ada", at: Date())
        }
        #expect(try await rig.item().status.latest == nil)   // refusals record nothing

        let record = try await rig.desk.reviewContradiction(caseID: rig.f.caseID, contradictionID: rig.id, decision: .dismissed,
                                                            reason: .differentEvent, note: "two separate invoices", actor: "Ada", at: Date())
        #expect(record.sourceVersions == [rig.a.object: rig.a.version, rig.b.object: rig.b.version])
        #expect(record.reason == .differentEvent && record.note == "two separate invoices")

        // Rerun over unchanged documents: still dismissed, not waiting for review, no second item.
        await rig.rerun()
        let after = try await rig.desk.contradictionReviewItems(caseID: rig.f.caseID)
        #expect(after.count == 1)
        #expect(after[0].status.current == .dismissed && !after[0].status.awaitingReview && !after[0].status.isReopened)
        #expect(try await rig.desk.contradictions(caseID: rig.f.caseID).first?.review?.decision == .dismissed)   // desk in step

        // Revise document A: the item reopens and names it; the earlier decision stays in the history.
        _ = try await revise(rig.f.db, object: rig.a.object, cases: rig.f.cases, caseID: rig.f.caseID)
        await rig.rerun()
        let reopened = try await rig.item()
        #expect(reopened.status.isReopened && reopened.status.current == nil && reopened.status.awaitingReview)
        #expect(reopened.status.changedObjects == [rig.a.object])
        #expect(reopened.status.label(names: [rig.a.object: "invoice-a.txt"]).hasPrefix("Reopened because invoice-a.txt changed since it was dismissed"))
        #expect(reopened.status.history.count == 1 && reopened.status.history[0].decision == .dismissed)

        // A dismissal deletes neither source nor the shared item, and leaves its global status alone.
        #expect(try await rig.f.db.query("SELECT COUNT(*) FROM knowledge_objects WHERE id IN (?, ?);",
                                         [.uuid(rig.a.object), .uuid(rig.b.object)]).first?.int(0) == 2)
        #expect(try await rig.f.db.query("SELECT COUNT(*) FROM source_versions WHERE id IN (?, ?);",
                                         [.uuid(rig.a.version), .uuid(rig.b.version)]).first?.int(0) == 2)
        #expect(try await rig.contradictions.findByIDs([rig.id]).first?.status == .open)
        // The history is append-only.
        await #expect(throws: (any Error).self) {
            try await rig.f.db.exec("UPDATE investigation_review_decisions SET decision = 'confirmed';", [])
        }
    }

    @Test("Defer keeps the item waiting with its reason; the desk holds no disposition; every decision is in the history")
    func deferKeepsItWaiting() async throws {
        let rig = try await ReviewRig.make()
        try await rig.desk.reviewContradiction(caseID: rig.f.caseID, contradictionID: rig.id, decision: .confirmed, reason: nil,
                                               note: nil, actor: "Ada", at: Date(timeIntervalSince1970: 1_000))
        try await rig.desk.reviewContradiction(caseID: rig.f.caseID, contradictionID: rig.id, decision: .deferred, reason: .insufficientContext,
                                               note: "ask the accountant", actor: "Ben", at: Date(timeIntervalSince1970: 2_000))
        let item = try await rig.item()
        #expect(item.status.current == .deferred && item.status.awaitingReview)
        #expect(item.status.history.map(\.decision) == [.confirmed, .deferred])
        #expect(item.status.history.map(\.actor) == ["Ada", "Ben"])
        #expect(item.status.latest?.reason == .insufficientContext && item.status.latest?.note == "ask the accountant")
        #expect(try await rig.desk.contradictions(caseID: rig.f.caseID).first?.review == nil)
    }

    @Test("A confirmed contradiction is carried to the chronology and the report with both passages, its versions and the decision's digest")
    func confirmedCarriedWithoutRetyping() async throws {
        let rig = try await ReviewRig.make()
        // Not confirmed: refused.
        await #expect(throws: ReviewedItemHandoffError.notConfirmed) {
            _ = try await JobResultHandoff.addReviewedToChronology(try await rig.item(), caseFiles: rig.f.svc, actor: "Ada")
        }
        let d = try await rig.desk.reviewContradiction(caseID: rig.f.caseID, contradictionID: rig.id, decision: .confirmed, reason: nil,
                                                       note: "both on the same invoice", actor: "Ada", at: Date())
        let item = try await rig.item()
        try await JobResultHandoff.addReviewedToChronology(item, caseFiles: rig.f.svc, actor: "Ada")
        try await JobResultHandoff.addReviewedToReport(item, caseFiles: rig.f.svc, actor: "Ada")
        let snap = try #require(try await rig.f.svc.snapshot(caseID: rig.f.caseID, custody: []))
        let entry = try #require(snap.journal.first { $0.kind == .chronology })
        let shown = JobResultHandoff.reviewText(item.contradiction)
        #expect(entry.text == shown && !shown.contains(CaseContradictionFinder.markerStem))
        #expect(entry.citations == [StudioEvidenceRef(sourceVersionID: rig.a.version, objectID: rig.a.object, quote: rig.qA),
                                    StudioEvidenceRef(sourceVersionID: rig.b.version, objectID: rig.b.object, quote: rig.qB)])
        #expect(entry.reviewState == "confirmed" && entry.originDigest == JobResultHandoff.reviewDigest(d))
        #expect(entry.origin == JobResultHandoff.reviewOrigin(itemKind: .contradiction, itemID: rig.id.uuidString, decisionID: d.id))
        let report = try #require(snap.reportItems.first)
        #expect(report.text == shown && report.citations == entry.citations && report.originDigest == entry.originDigest && report.included)
        // The same decision is not carried twice to the same place.
        await #expect(throws: CaseFileError.self) {
            _ = try await JobResultHandoff.addReviewedToChronology(item, caseFiles: rig.f.svc, actor: "Ada")
        }
        // Reopened by a revised document: not carried until reviewed again.
        _ = try await revise(rig.f.db, object: rig.b.object, cases: rig.f.cases, caseID: rig.f.caseID)
        await #expect(throws: ReviewedItemHandoffError.reopened) {
            _ = try await JobResultHandoff.addReviewedToReport(try await rig.item(), caseFiles: rig.f.svc, actor: "Ada")
        }
    }

    @Test("The case-screen review model: a reason gates Dismiss, a decision moves on, and filter, search and selection come back from stored state")
    func reviewModelState() async throws {
        let rig = try await ReviewRig.make()
        let defaults = tempDefaults()
        var model = CaseContradictionReviewModel(caseID: rig.f.caseID, workspace: CaseWorkspaceHolder(caseID: rig.f.caseID, defaults: defaults))
        await model.load(desk: rig.desk, objects: KnowledgeObjectRepository(database: rig.f.db))
        #expect(model.selectedID == rig.id && model.awaitingCount == 1)
        #expect(model.problem(for: .dismissed) == "Choose why you are dismissing it.")
        #expect(model.problem(for: .confirmed) == nil && model.problem(for: .deferred) == nil)
        #expect(await model.decide(.dismissed, desk: rig.desk, objects: nil, actor: "Ada") == nil)   // refused in the model, nothing written
        model.draftReason = .changedEstimate
        let rec = await model.decide(.dismissed, desk: rig.desk, objects: nil, actor: "Ada")
        #expect(rec?.reason == .changedEstimate && model.error == nil)
        #expect(model.visible.isEmpty && model.awaitingCount == 0)          // the "waiting" list no longer shows it
        model.filter = .all
        model.search = "invoice"
        #expect(model.visible.map(\.id) == [rig.id])
        model.search = "nothing-like-this"
        #expect(model.visible.isEmpty)
        model.search = "650"
        // "Relaunch": a new model from the same stored state.
        model = CaseContradictionReviewModel(caseID: rig.f.caseID, workspace: CaseWorkspaceHolder(caseID: rig.f.caseID, defaults: defaults))
        #expect(model.filter == .all && model.search == "650" && model.selectedID == rig.id)
        await model.load(desk: rig.desk, objects: nil)
        #expect(model.selected?.status.current == .dismissed)
    }
}

// MARK: - A2 the persistent case workspace

@MainActor
@Suite("Package A2 — persistent case workspace and overview")
struct CaseWorkspaceTests {

    @Test("Tab, selected request, last source and filters survive re-creating the case file model; another case keeps its own")
    func restoreAfterRelaunch() {
        let defaults = tempDefaults()
        let caseID = UUID(), other = UUID(), request = UUID(), object = UUID()
        var model = CaseFileModel(caseID: caseID, workspaceID: UUID(), defaults: defaults)
        #expect(model.tab == .overview)   // a new case lands on the overview
        model.tab = .evidence
        model.workspace.state.selectedRequestID = request
        let position = CaseSourcePosition(objectID: object, origin: .contradiction(id: UUID(), side: .b), revision: UUID())
        model.workspace.state.lastSource = position
        model.review.filter = .decided
        model = CaseFileModel(caseID: caseID, workspaceID: UUID(), defaults: defaults)
        #expect(model.tab == .evidence)
        #expect(model.workspace.state.selectedRequestID == request)
        #expect(model.workspace.state.lastSource == position)
        #expect(model.review.filter == .decided)
        let fresh = CaseFileModel(caseID: other, workspaceID: UUID(), defaults: defaults)
        #expect(fresh.tab == .overview && fresh.workspace.state.lastSource == nil)
    }

    @Test("The overview counts what waits — contradictions, result rows, open requests and missing items — names the question and limits, and points at a next step")
    func overviewCounts() async throws {
        let rig = try await ReviewRig.make()
        var p = try await rig.f.file.profile(caseID: rig.f.caseID)
        p.intake.allegationSummary = "Was the supplier paid twice?"
        try await rig.f.file.saveProfile(p, actor: "Ada")
        let analysis = InvestigationAnalysisService(cases: rig.f.cases, resolver: CaseRetrievalScopeResolver(evidence: EvidenceStore(database: rig.f.db)),
                                                    evidence: EvidenceStore(database: rig.f.db), analysis: InvestigationAnalysisRepository(database: rig.f.db))
        _ = try await analysis.createEvidenceRequest(caseID: rig.f.caseID, details: EvidenceRequestDetails(
            description: "Supplier ledger", custodian: "Accounts", dueAt: Date(timeIntervalSince1970: 10),
            items: [.init(label: "Ledger 2025"), .init(label: "Ledger 2026")]), actor: "Ada", at: Date())
        let custody = [CustodyManifestEntry(sourceVersionID: rig.a.version, contentHash: nil, custodyEvents: []),
                       CustodyManifestEntry(sourceVersionID: rig.b.version, contentHash: nil, custodyEvents: [])]
        let snap = try #require(try await rig.f.svc.snapshot(caseID: rig.f.caseID, custody: custody))
        let g = CaseGlance.compute(snap, contradictions: try await rig.desk.contradictionReviewItems(caseID: rig.f.caseID),
                                   requests: try await analysis.requestFiles(caseID: rig.f.caseID), resultRowsUndecided: 3,
                                   aiPermittedDocuments: 1, unresolvedReferences: 0, custodyReadFailed: false)
        #expect(g.question == "Was the supplier paid twice?")
        #expect(g.contradictionsAwaiting == 1 && g.resultRowsUndecided == 3 && g.awaitingReview == 4)
        #expect(g.openRequests == 1 && g.overdueRequests == 1 && g.missingItems == 2)
        #expect(g.limitations.contains { $0.contains("allowed to read 1 of the 2 documents") })
        // A finding of the case's own check (rules) is listed: the overview does not say the documents were never compared.
        #expect(!g.limitations.contains { $0.contains("not been compared for contradictions") || $0.contains("archive scan") })
        // The next step is the case's most pressing one (triage for a new case); the request and the review
        // queue are among the steps, each pointing at the tab where it is done.
        let items = try await rig.desk.contradictionReviewItems(caseID: rig.f.caseID)
        let steps = CaseNextSteps.compute(snap, evidenceRequests: try await analysis.requestFiles(caseID: rig.f.caseID),
                                          contradictionsAwaiting: items.count, contradictionsReopened: 0)
        #expect(g.nextStep == steps.first && g.nextStep != nil)
        #expect(steps.contains { $0.id.hasPrefix("request-overdue-") && $0.place == .evidence && $0.text.contains("2 item(s) still missing") })
        #expect(steps.contains { $0.id == "contradictions-awaiting" && $0.place == .overview })
        // Callers that pass no requests or counts get the steps they always had.
        #expect(CaseNextSteps.compute(snap).allSatisfy { !$0.id.hasPrefix("request-") && !$0.id.hasPrefix("contradictions-") })
    }

    @Test("Walk 2026-11-06: the reading limit about contradictions accounts for what is listed — none, archive-scan only, or the case check's own")
    func contradictionLimitMatchesWhatIsListed() async throws {
        let rig = try await ReviewRig.make()
        let custody = [CustodyManifestEntry(sourceVersionID: rig.a.version, contentHash: nil, custodyEvents: [])]
        let snap = try #require(try await rig.f.svc.snapshot(caseID: rig.f.caseID, custody: custody))
        let open = CaseItemReviewStatus(history: [], changedObjects: [])
        let scan = CaseContradictionReviewItem(contradiction: Contradiction(description: "Conflicting dates for \"Delivery delayed\"",
                                                                           claimA: "delayed on 3 May", claimB: "delayed on 9 May"),
                                               status: open, currentVersions: [:])
        func limit(_ items: [CaseContradictionReviewItem]) -> String? {
            CaseGlance.compute(snap, contradictions: items, requests: [], resultRowsUndecided: 0, aiPermittedDocuments: nil,
                               unresolvedReferences: 0, custodyReadFailed: false)
                .limitations.first { $0.contains("contradiction") }
        }
        #expect(limit([])?.contains("have not been compared for contradictions yet") == true)
        let scanOnly = try #require(limit([scan, scan]))
        #expect(scanOnly.contains("The archive scan compared these documents and found 2 contradiction(s)"))
        #expect(scanOnly.contains("this case's own comparison (“Find contradictions”") && !scanOnly.contains("have not been compared"))
        #expect(limit([scan, try await rig.item()]) == nil, "the case check's finding is listed: it ran")
        // No documents in the case: nothing to compare, no line.
        let empty = try #require(try await rig.f.svc.snapshot(caseID: rig.f.caseID, custody: []))
        #expect(CaseGlance.contradictionCheckLimit(empty, contradictions: []) == nil)
    }

    @Test("LB3: the workspace preference holds identifiers only; the passage is re-read from the ledger; a state from an earlier build loses its quote and name")
    func workspacePreferenceHoldsNoDocumentText() async throws {
        let rig = try await ReviewRig.make()
        let defaults = tempDefaults()
        let item = try await rig.item()
        var state = CaseWorkspaceState()
        state.lastSource = CaseSourcePosition(objectID: rig.b.object, origin: .contradiction(id: rig.id, side: .b), revision: rig.b.version)
        CaseWorkspaceStore.save(state, caseID: rig.f.caseID, defaults: defaults)
        let raw = String(decoding: try #require(defaults.data(forKey: CaseWorkspaceStore.key(rig.f.caseID))), as: UTF8.self)
        #expect(!raw.contains("650") && !raw.contains("invoice") && !raw.contains("quote") && !raw.contains("label"), "\(raw)")
        // The passage comes back from the ledger's contradiction, at the version it was opened at.
        let back = try #require(CaseWorkspaceStore.load(caseID: rig.f.caseID, defaults: defaults).lastSource)
        #expect(back.passage(contradictions: [item], entries: [], objectForVersion: [:]) == rig.qB)
        // A newer version of the document: it opens without a highlight; a vanished item gives nothing.
        let moved = CaseSourcePosition(objectID: rig.b.object, origin: .contradiction(id: rig.id, side: .b), revision: UUID())
        #expect(moved.passage(contradictions: [item], entries: [], objectForVersion: [:]) == nil)
        #expect(back.passage(contradictions: [], entries: [], objectForVersion: [:]) == nil)
        // A case entry's quote is read from the entry.
        let entryID = UUID()
        let entry = CaseJournalEntry(id: entryID, caseID: rig.f.caseID, kind: .chronology, eventDate: nil, text: "t", evidenceRef: nil,
                                     author: "Ada", createdAt: Date(), quote: "paid twice",
                                     citations: [StudioEvidenceRef(sourceVersionID: rig.a.version, objectID: rig.a.object, quote: "paid twice")])
        let fromEntry = CaseSourcePosition(objectID: rig.a.object, origin: .caseEntry(id: entryID), revision: rig.a.version)
        #expect(fromEntry.passage(contradictions: [], entries: [entry], objectForVersion: [:]) == "paid twice")
        // A state written by the earlier build (quote and file name in the preference) is rewritten without them.
        let legacyCase = UUID()
        let legacy = #"{"contradictionFilter":"all","contradictionSearch":"","lastSource":{"objectID":"\#(rig.a.object.uuidString)","quote":"The invoice total was 500 dollars.","label":"invoice-a.txt"}}"#
        defaults.set(Data(legacy.utf8), forKey: CaseWorkspaceStore.key(legacyCase))
        let loaded = CaseWorkspaceStore.load(caseID: legacyCase, defaults: defaults)
        #expect(loaded.lastSource?.objectID == rig.a.object && loaded.contradictionFilter == .all)
        let rewritten = String(decoding: try #require(defaults.data(forKey: CaseWorkspaceStore.key(legacyCase))), as: UTF8.self)
        #expect(!rewritten.contains("500 dollars") && !rewritten.contains("invoice-a.txt"), "\(rewritten)")
    }

    @Test("Walk 2026-11-06: the review keys act while a note is being typed — the menu's keys go through the model, keep the note and say a missing reason")
    func reviewKeysWithNoteTyped() async throws {
        let rig = try await ReviewRig.make()
        let model = CaseContradictionReviewModel(caseID: rig.f.caseID, workspace: CaseWorkspaceHolder(caseID: rig.f.caseID, defaults: tempDefaults()))
        await model.load(desk: rig.desk, objects: nil)
        // The keys: ⌥⌘ with ↓ ↑ Y N L, each a distinct menu item; the section's help text names the same keys.
        #expect(CaseReviewKey.modifiers == [.command, .option])
        #expect(CaseReviewKey.allCases.map(\.key.character) == [KeyEquivalent.downArrow.character, KeyEquivalent.upArrow.character, "y", "n", "l"])
        #expect(CaseReviewKey.allCases.compactMap(\.decision) == [.confirmed, .dismissed, .deferred])
        #expect(Set(CaseReviewKey.allCases.map(\.title)).count == CaseReviewKey.allCases.count)
        // A note typed, focus still in the field: Dismiss (⌥⌘N) without a reason is refused and said; nothing recorded.
        model.draftNote = "Waiting for the signed amendment original"
        await model.perform(.dismiss, desk: rig.desk, objects: nil, actor: "Ada")
        #expect(model.error == "Choose why you are dismissing it.")
        #expect(try await rig.item().status.latest == nil)
        #expect(model.draftNote == "Waiting for the signed amendment original", "the note typed so far is kept")
        // Defer (⌥⌘L) records the decision with the note typed.
        await model.perform(.deferIt, desk: rig.desk, objects: nil, actor: "Ada")
        let latest = try #require(try await rig.item().status.latest)
        #expect(latest.decision == .deferred && latest.note == "Waiting for the signed amendment original")
        #expect(model.error == nil && model.draftNote.isEmpty)
        // ⌥⌘↓ / ⌥⌘↑ move through the listed items (one listed here: the selection stays on it).
        await model.perform(.next, desk: rig.desk, objects: nil, actor: "Ada")
        #expect(model.selectedID == rig.id)
        await model.perform(.previous, desk: rig.desk, objects: nil, actor: "Ada")
        #expect(model.selectedID == rig.id)
    }

    @Test("Undecided result rows count only in results still under review")
    func undecidedRows() {
        func record(_ state: JobResultState, _ decisions: [JobRowDecision?]) -> JobResultRecord {
            let rows = decisions.map { d -> JobResultRow in var r = JobResultRow(title: "r", detail: nil, date: nil, refs: []); r.decision = d; return r }
            return JobResultRecord(id: UUID(), caseID: UUID(), jobID: "j", family: "chronologyLinkage", state: state,
                                   content: JobResultContent(rows: rows), createdBy: "Ada", createdAt: Date())
        }
        #expect(CaseGlance.undecidedRows([record(.draft, [nil, .accepted, nil]), record(.completed, [nil]), record(.blocked, [nil])]) == 3)
    }

    @Test("Every persona job is reachable through “Find a job”; an unrelated query finds none")
    func everyJobReachable() {
        let all = PersonaJobCatalogComposer.allJobs
        #expect(!all.isEmpty)
        for job in all { #expect(PersonaJobsModel.jobMatches(job, query: job.title), "\(job.title)") }
        #expect(all.filter { PersonaJobsModel.jobMatches($0, query: "zzqx-nothing") }.isEmpty)
        #expect(all.allSatisfy { PersonaJobsModel.jobMatches($0, query: "  ") })
    }
}

// MARK: - A3 evidence requests that can be followed through

@MainActor
@Suite("Package A3 — evidence requests followed through", .serialized)
struct EvidenceRequestFollowThroughTests {

    private static var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC") ?? .gmt; return c }
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date { Self.utc.date(from: DateComponents(year: y, month: m, day: d, hour: 12)) ?? Date() }

    private func service(_ f: CaseFileTests.Fixture) -> InvestigationAnalysisService {
        let evidence = EvidenceStore(database: f.db)
        return InvestigationAnalysisService(cases: f.cases, resolver: CaseRetrievalScopeResolver(evidence: evidence), evidence: evidence,
                                            analysis: InvestigationAnalysisRepository(database: f.db))
    }

    @Test("Three monthly statements: two plus a duplicate received → partly received, March missing; an unrelated file fulfils nothing; fulfilment only by decision")
    func threeMonthlyStatements() async throws {
        let f = try await CaseFileTests.fixture()
        let svc = service(f)
        let items = EvidenceRequestItemSpec.monthly("Bank statement", from: day(2026, 1, 1), to: day(2026, 3, 31), calendar: Self.utc)
        #expect(items.map(\.label) == ["Bank statement — January 2026", "Bank statement — February 2026", "Bank statement — March 2026"])
        let request = try await svc.createEvidenceRequest(caseID: f.caseID, details: EvidenceRequestDetails(
            description: "Bank statement", question: "Was the supplier paid twice?", custodian: "First Bank",
            periodStart: items.first?.periodStart, periodEnd: items.last?.periodEnd, dueAt: day(2026, 12, 1), items: items),
            actor: "Ada", at: day(2026, 11, 1))
        #expect(request.status == .open && request.custodian == "First Bank" && request.question == "Was the supplier paid twice?")

        let jan = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "statement-2026-01.txt", text: "January statement. Balance 100.")
        let feb = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "statement-2026-02.txt", text: "February statement. Balance 90.")
        let dup = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "copy of january.txt", text: "January statement. Balance 100.")
        let janHash = try #require(try await f.db.query("SELECT content_hash FROM source_versions WHERE id = ?;", [.uuid(jan.version)]).first?.string(0))
        try await f.db.exec("UPDATE source_versions SET content_hash = ? WHERE id = ?;", [.text(janHash), .uuid(dup.version)])   // the same bytes, imported twice
        let minutes = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "board-minutes.txt", text: "The board met. Nothing about the bank.")

        // Suggestions: each statement for its own month; the unrelated minutes for nothing.
        var file = try #require(try await svc.requestFiles(caseID: f.caseID).first)
        let candidates = [EvidenceRequestCandidate(sourceVersionID: jan.version, knowledgeObjectID: jan.object, name: "statement-2026-01.txt"),
                          EvidenceRequestCandidate(sourceVersionID: feb.version, knowledgeObjectID: feb.object, name: "statement-2026-02.txt"),
                          EvidenceRequestCandidate(sourceVersionID: minutes.version, knowledgeObjectID: minutes.object, name: "board-minutes.txt",
                                                   documentDate: day(2025, 6, 1))]
        let suggestions = EvidenceRequestMatcher.suggestions(for: file, candidates: candidates, calendar: Self.utc)
        #expect(suggestions.map(\.candidate.sourceVersionID) == [jan.version, feb.version])
        #expect(suggestions.map(\.itemID) == [file.items[0].id, file.items[1].id])

        try await svc.linkReceivedSource(requestID: request.id, itemID: file.items[0].id, sourceVersionID: jan.version, knowledgeObjectID: jan.object,
                                         origin: .suggestion, actor: "Ada", at: day(2026, 11, 2))
        try await svc.linkReceivedSource(requestID: request.id, itemID: file.items[1].id, sourceVersionID: feb.version, knowledgeObjectID: feb.object,
                                         actor: "Ada", at: day(2026, 11, 3))
        let copy = try await svc.linkReceivedSource(requestID: request.id, itemID: file.items[0].id, sourceVersionID: dup.version, knowledgeObjectID: dup.object,
                                                    actor: "Ada", at: day(2026, 11, 4))
        #expect(copy.duplicateOf != nil && !copy.counts)
        // The unrelated file, linked by hand to no item, fulfils nothing.
        try await svc.linkReceivedSource(requestID: request.id, itemID: nil, sourceVersionID: minutes.version, knowledgeObjectID: minutes.object,
                                         actor: "Ada", at: day(2026, 11, 5))
        await #expect(throws: InvestigationHypothesisError.alreadyReceived(sourceVersionID: jan.version)) {
            _ = try await svc.linkReceivedSource(requestID: request.id, itemID: nil, sourceVersionID: jan.version, knowledgeObjectID: nil, actor: "Ada", at: Date())
        }
        let outside = try await CaseFileTestSources.seed(f.db)   // in the archive, not in the case
        await #expect(throws: InvestigationHypothesisError.evidenceOutOfScope(sourceVersionID: outside)) {
            _ = try await svc.linkReceivedSource(requestID: request.id, itemID: nil, sourceVersionID: outside, knowledgeObjectID: nil, actor: "Ada", at: Date())
        }

        file = try #require(try await svc.requestFiles(caseID: f.caseID).first)
        let progress = file.progress
        #expect(progress.state == .partlyReceived)
        #expect(progress.outstanding.map(\.label) == ["Bank statement — March 2026"])
        #expect(progress.received.count == 2 && progress.duplicates == 1 && progress.unassigned == 1)
        #expect(progress.summary.contains("2 of 3 received") && progress.summary.contains("still missing: Bank statement — March 2026"))
        #expect(file.request.status == .open)   // arrivals change no status
        #expect(file.events.map(\.kind) == [.created, .received, .received, .duplicateReceived, .received])

        // Fulfilment is a decision; with March missing it needs the reason.
        await #expect(throws: InvestigationHypothesisError.requestItemsOutstanding(["Bank statement — March 2026"])) {
            _ = try await svc.fulfillRequest(requestID: request.id, expectedRevision: file.request.revision, actor: "Ada", at: Date())
        }
        await #expect(throws: InvestigationHypothesisError.decisionNoteRequired(.refused)) {
            _ = try await svc.decideRequest(requestID: request.id, expectedRevision: file.request.revision, status: .refused, note: nil, actor: "Ada", at: Date())
        }
        try await svc.recordRequestEvent(requestID: request.id, kind: .requested, detail: "emailed the bank", actor: "Ada", at: day(2026, 11, 6))
        let partial = try await svc.decideRequest(requestID: request.id, expectedRevision: file.request.revision, status: .partial,
                                                  note: "bank sent two of three", actor: "Ada", at: day(2026, 11, 7))
        #expect(partial.status == .partial)
        file = try #require(try await svc.requestFiles(caseID: f.caseID).first)
        #expect(file.progress.outstanding.map(\.label) == ["Bank statement — March 2026"])   // the missing month is kept
        #expect(file.events.last?.kind == .statusDecided && file.events.last?.statusAfter == .partial && file.events.last?.detail == "bank sent two of three")
        #expect(EvidenceRequestMatcher.suggestions(for: file, candidates: candidates, calendar: Self.utc).isEmpty)   // linked ones are not suggested again

        // The draft asks for what is still missing and names what arrived; nothing is sent.
        let draft = EvidenceRequestDraft.text(file, caseTitle: "Supplier payments", about: file.request.question, requester: "Ada")
        #expect(draft.contains("To: First Bank") && draft.contains("1. Bank statement — March 2026") && !draft.contains("1. Bank statement — January 2026"))
        #expect(draft.contains("Already received, with thanks: Bank statement — January 2026; Bank statement — February 2026."))

        // A wrong link is withdrawn with a reason and stays in the record; fulfilment with a stated reason is accepted.
        let minutesReceipt = try #require(file.receipts.first { $0.sourceVersionID == minutes.version })
        try await svc.withdrawReceivedSource(receiptID: minutesReceipt.id, reason: "not a bank record", actor: "Ada", at: Date())
        let done = try await svc.decideRequest(requestID: request.id, expectedRevision: partial.revision, status: .fulfilled,
                                               note: "March account closed — no statement exists", actor: "Ada", at: Date())
        #expect(done.status == .fulfilled)
        file = try #require(try await svc.requestFiles(caseID: f.caseID).first)
        #expect(file.receipts.count == 4 && file.receipts.first { $0.id == minutesReceipt.id }?.withdrawnReason == "not a bank record")
        await #expect(throws: (any Error).self) {
            try await f.db.exec("DELETE FROM investigation_evidence_request_events;", [])   // history is append-only
        }
    }

    @Test("New material arriving after a decided allegation names it for revisiting and changes nothing")
    func revisitNotice() {
        let caseID = UUID(), allegation = UUID()
        let decided = CaseAllegation(id: allegation, caseID: caseID, sequence: 2, text: "Supplier paid twice", disposition: .substantiated,
                                     rationale: "two transfers", decidedBy: "Ada", decidedAt: Date(timeIntervalSince1970: 100), createdAt: Date(timeIntervalSince1970: 0))
        let request = EvidenceRequest(id: UUID(), caseID: caseID, hypothesisID: nil, description: "Statements", status: .confirmed, revision: 2,
                                      actor: "Ada", createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0), allegationID: allegation)
        let receipt = EvidenceRequestReceipt(id: UUID(), requestID: request.id, itemID: nil, sourceVersionID: UUID(), knowledgeObjectID: nil, contentHash: nil,
                                             duplicateOf: nil, origin: .manual, note: nil, linkedBy: "Ada", linkedAt: Date(timeIntervalSince1970: 200),
                                             withdrawnBy: nil, withdrawnAt: nil, withdrawnReason: nil)
        let file = EvidenceRequestFile(request: request, items: [], receipts: [receipt], events: [])
        let notices = EvidenceRequestRevisit.notices(file, allegations: [decided], hypotheses: [])
        #expect(notices == ["A2 was decided (Substantiated) before this material arrived. It may need revisiting; the finding has not been changed."])
        #expect(decided.disposition == .substantiated)
        #expect(EvidenceRequestRevisit.notices(EvidenceRequestFile(request: request, items: [], receipts: [], events: []), allegations: [decided], hypotheses: []).isEmpty)
    }

    @Test("A request made before v170 survives the migration unchanged; the new states are accepted only after it")
    func migrationKeepsOldRequests() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 169)
        let ws = UUID(), c = UUID(), r = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);", [.uuid(ws), .text("W"), .real(1), .real(1)])
        try await db.exec("""
            INSERT INTO investigation_cases (id, workspace_id, title, status, revision, actor, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?);
            """, [.uuid(c), .uuid(ws), .text("C"), .text("open"), .integer(1), .text("u"), .real(1), .real(1)])
        try await db.exec("""
            INSERT INTO investigation_evidence_requests (id, case_id, hypothesis_id, description, status, revision, actor, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?);
            """, [.uuid(r), .uuid(c), .null, .text("Phone records for May"), .text("confirmed"), .integer(3), .text("Ada"), .real(10), .real(20)])
        await #expect(throws: (any Error).self) {
            try await db.exec("UPDATE investigation_evidence_requests SET status = 'partial' WHERE id = ?;", [.uuid(r)])
        }
        try await SchemaMigrations.migrate(db, through: 170)
        #expect(try await db.currentUserVersion() == 170)
        let repo = InvestigationAnalysisRepository(database: db)
        let old = try #require(try await repo.requests(caseID: c).first)
        #expect(old.id == r && old.description == "Phone records for May" && old.status == .confirmed && old.revision == 3 && old.actor == "Ada")
        #expect(old.createdAt == Date(timeIntervalSince1970: 10) && old.updatedAt == Date(timeIntervalSince1970: 20))
        #expect(old.custodian == nil && old.dueAt == nil && old.allegationID == nil)
        let file = try #require(try await repo.requestFiles(caseID: c).first)
        #expect(file.items.isEmpty && file.events.isEmpty && file.progress.state == .noItemsListed)
        try await db.exec("UPDATE investigation_evidence_requests SET status = 'partial' WHERE id = ?;", [.uuid(r)])
        await #expect(throws: (any Error).self) {
            try await db.exec("UPDATE investigation_evidence_requests SET status = 'bogus' WHERE id = ?;", [.uuid(r)])
        }
        for t in ["investigation_review_decisions", "investigation_evidence_request_items", "investigation_evidence_request_receipts", "investigation_evidence_request_events"] {
            #expect(try await MigrationFixtureBuilder.tableExists(db, t), "\(t) missing")
        }
        try await SchemaMigrations.migrate(db)   // to latest: a safe no-op over v170
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }
}
