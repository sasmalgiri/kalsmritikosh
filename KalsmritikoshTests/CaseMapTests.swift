//
//  CaseMapTests.swift
//  KalsmritikoshTests
//
//  Living case map M1–M4 (docs/IME_Living_Case_Map_Implementation_Plan_2026-11-06.md §13.1), deterministic
//  throwaway ledgers, no reader and no network:
//  M1 two-case isolation over a shared source; identity stable over row order and a re-ingested document;
//     a namesake is not merged; multiple citations survive; a note is never documentary; distinct states;
//     a failed part is "partial", never empty; a failed case read is "failed"; a case changing under the
//     read is "stale"; a late load is dropped.
//  M2 selection kept between map and list; state survives re-creating the model from the ledger and the
//     preference; the preference holds identifiers and geometry only; saved views in the ledger.
//  M3 new items never move existing or pinned positions; Arrange leaves pinned items and Undo restores;
//     counts reconcile with the full projection in every view; culling discloses its cap.
//  M4 investigator links are checked in the write (case, closed, membership); withdrawn, never edited.
//  v171 migration from v170 keeps earlier rows.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@MainActor
private func mapDefaults() -> UserDefaults {
    let name = "casemap.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name) ?? .standard
    d.removePersistentDomain(forName: name)
    return d
}

/// The map's sources over a fixture ledger: the real case services; custody from the case scope.
func caseMapSources(_ f: CaseFileTests.Fixture) -> CaseMapSources {
    let evidence = EvidenceStore(database: f.db)
    let analysis = InvestigationAnalysisService(cases: f.cases, resolver: CaseRetrievalScopeResolver(evidence: evidence), evidence: evidence,
                                                analysis: InvestigationAnalysisRepository(database: f.db))
    let desk = InvestigationContradictionGapService(cases: f.cases, resolver: CaseRetrievalScopeResolver(evidence: evidence), evidence: evidence,
                                                    contradictions: ContradictionsRepository(database: f.db), gaps: GapNodeRepository(database: f.db),
                                                    reviews: InvestigationDeskReviewRepository(database: f.db))
    var s = CaseMapSources.live(database: f.db, caseFiles: f.svc, custody: nil, analysis: analysis, desk: desk,
                                objects: KnowledgeObjectRepository(database: f.db))
    let db = f.db
    s.custody = { caseID in
        try await db.query("SELECT source_ref FROM investigation_case_sources WHERE case_id = ? AND in_scope = 1 AND source_kind = 'sourceVersion' ORDER BY source_ref;",
                           [.uuid(caseID)]).compactMap { $0.uuid(0) }.map { CustodyManifestEntry(sourceVersionID: $0, contentHash: nil, custodyEvents: []) }
    }
    return s
}

func caseMapLoad(_ f: CaseFileTests.Fixture, caseID: UUID? = nil, sources: CaseMapSources? = nil) async -> CaseMapLoad {
    await CaseMapService(sources: sources ?? caseMapSources(f)).load(caseID: caseID ?? f.caseID, generation: 1)
}

/// A case with two documents, a contradiction between them (rules), and the desk to review it.
struct CaseMapRig {
    let f: CaseFileTests.Fixture
    let a: (version: UUID, object: UUID, blocks: [UUID])
    let b: (version: UUID, object: UUID, blocks: [UUID])
    let desk: InvestigationContradictionGapService
    let contradictionID: UUID

    static func make() async throws -> CaseMapRig {
        let f = try await CaseFileTests.fixture(title: "Supplier payments")
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
        return CaseMapRig(f: f, a: a, b: b, desk: desk, contradictionID: finding.contradiction().id)
    }

    func node(_ kind: CaseMapRecordKind, _ id: UUID) -> CaseMapNodeID { CaseMapNodeID(caseID: f.caseID, kind: kind, id: id) }
    func logical(_ version: UUID) async throws -> UUID {
        try #require(try await f.db.query("SELECT logical_source_id FROM source_versions WHERE id = ?;", [.uuid(version)]).first?.uuid(0))
    }
}

// MARK: - M1 projection

@MainActor
@Suite("Case map M1 — projection", .serialized)
struct CaseMapProjectionTests {

    @Test("Two cases share one document: each map has its own node for it; case A's allegation, link and request never appear in case B")
    func twoCaseIsolation() async throws {
        let rig = try await CaseMapRig.make()
        let f = rig.f
        let other = try await f.cases.createCase(workspaceID: f.workspaceID, title: "Another matter", actor: "Ada", at: Date())
        let header = try await f.cases.fetch(caseID: other.id)?.caseHeader
        _ = try await f.cases.includeSource(caseID: other.id, expectedRevision: header?.revision ?? 1, sourceRef: rig.a.version.uuidString,
                                            sourceKind: .sourceVersion, actor: "Ada", at: Date())
        let allegation = try await f.file.addAllegation(caseID: f.caseID, text: "The supplier was paid twice", actor: "Ada")
        try await f.svc.linkEvidence(caseID: f.caseID, allegationID: allegation, evidenceRef: rig.a.version.uuidString, label: "invoice", stance: .supports,
                                     note: nil, passage: StudioEvidenceRef(sourceVersionID: rig.a.version, objectID: rig.a.object, quote: "The invoice total was 500 dollars."),
                                     actor: "Ada")
        let evidence = EvidenceStore(database: f.db)
        let analysis = InvestigationAnalysisService(cases: f.cases, resolver: CaseRetrievalScopeResolver(evidence: evidence), evidence: evidence,
                                                    analysis: InvestigationAnalysisRepository(database: f.db))
        _ = try await analysis.createEvidenceRequest(caseID: f.caseID, details: EvidenceRequestDetails(description: "Bank statements", allegationID: allegation), actor: "Ada", at: Date())

        let mapA = try #require(await caseMapLoad(f).projection)
        let mapB = try #require(await caseMapLoad(f, caseID: other.id).projection)
        let logicalA = try await rig.logical(rig.a.version)
        #expect(mapA.nodes.allSatisfy { $0.id.caseID == f.caseID } && mapA.links.allSatisfy { $0.caseID == f.caseID })
        #expect(mapB.nodes.allSatisfy { $0.id.caseID == other.id } && mapB.links.allSatisfy { $0.caseID == other.id })
        // The shared document is in both, as each case's own item.
        #expect(mapA.node(CaseMapNodeID(caseID: f.caseID, kind: .document, id: logicalA)) != nil)
        #expect(mapB.node(CaseMapNodeID(caseID: other.id, kind: .document, id: logicalA)) != nil)
        // Case A's work stays in case A.
        #expect(mapA.count(.question) == 2 && mapA.count(.action) == 1 && mapA.count(.contradiction) == 1)
        #expect(mapB.count(.question) == 1 && mapB.count(.action) == 0 && mapB.count(.contradiction) == 0)
        #expect(mapB.links.isEmpty)
        #expect(!mapB.nodes.contains { $0.id.recordID == allegation.uuidString.lowercased() })
        #expect(mapB.nodes.filter { $0.id.kind == .document }.count == 1, "only the shared document is in case B")
    }

    @Test("Identity is case + record kind + record id: the same records in reverse order give the same nodes and links; a re-ingested document keeps its identity with a new revision")
    func identityStable() async throws {
        let rig = try await CaseMapRig.make()
        let f = rig.f
        let allegation = try await f.file.addAllegation(caseID: f.caseID, text: "Paid twice", actor: "Ada")
        try await f.svc.linkEvidence(caseID: f.caseID, allegationID: allegation, evidenceRef: rig.b.version.uuidString, label: "b", stance: .contradicts,
                                     note: nil, passage: StudioEvidenceRef(sourceVersionID: rig.b.version, objectID: rig.b.object, quote: "The invoice total was 650 dollars."), actor: "Ada")
        _ = try await f.file.addPerson(caseID: f.caseID, name: "Ann Lee", role: .witness, entityID: nil, contact: nil, notes: nil, actor: "Ada")
        let sources = caseMapSources(f)
        let first = try #require(await caseMapLoad(f, sources: sources).projection)

        // The same records read back in another order.
        let s = try #require(try await f.svc.snapshot(caseID: f.caseID, custody: [rig.b.version, rig.a.version].map { CustodyManifestEntry(sourceVersionID: $0, contentHash: nil, custodyEvents: []) }))
        let reversed = CaseFileSnapshot(caseHeader: s.caseHeader, profile: s.profile, allegations: s.allegations.reversed(), grid: s.grid.reversed(), tasks: s.tasks,
                                        journal: s.journal.reversed(), people: s.people.reversed(), contacts: s.contacts, interviews: s.interviews, credibility: s.credibility,
                                        exhibits: s.exhibits, holds: s.holds, redactions: s.redactions, batches: s.batches, conflicts: s.conflicts, actions: s.actions,
                                        custody: s.custody.reversed(), addenda: s.addenda, reportItems: s.reportItems.reversed())
        let docs = try await sources.map.documents(versionIDs: [rig.a.version, rig.b.version], objectsByVersion: [rig.a.version: rig.a.object, rig.b.version: rig.b.object])
        let items = try await rig.desk.contradictionReviewItems(caseID: f.caseID)
        let again = CaseMapProjector.project(CaseMapInput(snapshot: reversed, documents: docs.reversed(), contradictions: items.reversed()))
        #expect(again.nodes.map(\.id) == first.nodes.map(\.id))
        #expect(again.links.map(\.id) == first.links.map(\.id))

        // Re-ingest: a new current version of document A, included in the case.
        let logicalA = try await rig.logical(rig.a.version)
        let docA = rig.node(.document, logicalA)
        let before = try #require(first.node(docA))
        try await f.db.exec("UPDATE source_versions SET is_current = 0 WHERE logical_source_id = ?;", [.uuid(logicalA)])
        let v2 = UUID()
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try await f.db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at, filename, detected_type, detection_basis,
                size_bytes, custody_mode, preservation_status, intake_recorded_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(v2), .uuid(logicalA), .text(hex + hex), .real(300), .integer(1), .real(300), .text("invoice-a (re-read).txt"), .text("txt"),
                  .text("magicBytes"), .integer(1), .text("referenced"), .text("referenceRecorded"), .real(300)])
        let header = try await f.cases.fetch(caseID: f.caseID)?.caseHeader
        _ = try await f.cases.includeSource(caseID: f.caseID, expectedRevision: header?.revision ?? 1, sourceRef: v2.uuidString, sourceKind: .sourceVersion, actor: "Ada", at: Date())
        let after = try #require(await caseMapLoad(f, sources: sources).projection)
        let reread = try #require(after.node(docA))
        #expect(reread.id == before.id && reread.revision == v2.uuidString.lowercased() && before.revision == rig.a.version.uuidString.lowercased())
        #expect(after.nodes.filter { $0.id.kind == .document }.count == 2, "two documents, not three")
        #expect(reread.sources.count == 2, "both versions are listed")
    }

    @Test("A namesake is not merged: two people with one name stay two items, offered as possibly the same person, pending review; different linked people get no such link")
    func namesake() async throws {
        let f = try await CaseFileTests.fixture()
        let p1 = try await f.file.addPerson(caseID: f.caseID, name: "Ann Lee", role: .witness, entityID: nil, contact: nil, notes: nil, actor: "Ada")
        let p2 = try await f.file.addPerson(caseID: f.caseID, name: "ann  lee", role: .subject, entityID: nil, contact: nil, notes: nil, actor: "Ada")
        let p3 = try await f.file.addPerson(caseID: f.caseID, name: "Raj Rao", role: .witness, entityID: UUID(), contact: nil, notes: nil, actor: "Ada")
        let p4 = try await f.file.addPerson(caseID: f.caseID, name: "Raj Rao", role: .custodian, entityID: UUID(), contact: nil, notes: nil, actor: "Ada")
        let p = try #require(await caseMapLoad(f).projection)
        #expect(p.count(.person) == 4)
        let same = p.links.filter { $0.type == .possibleSamePerson }
        #expect(same.count == 1)
        let link = try #require(same.first)
        #expect(Set([link.from, link.to]) == Set([p1, p2].map { CaseMapNodeID(caseID: f.caseID, kind: .person, id: $0) }))
        #expect(link.review == .pendingReview && link.status.kind == .unassessed && !link.directed)
        if case .rule = link.assertedBy {} else { Issue.record("a same-name pairing is a rule's proposal, not a person's decision") }
        #expect(!same.contains { [p3, p4].map { CaseMapNodeID(caseID: f.caseID, kind: .person, id: $0) }.contains($0.from) })
    }

    @Test("Multiple citations survive: a confirmed contradiction carried to the report keeps both passages as two sources and two links")
    func multipleCitations() async throws {
        let rig = try await CaseMapRig.make()
        _ = try await rig.desk.reviewContradiction(caseID: rig.f.caseID, contradictionID: rig.contradictionID, decision: .confirmed, reason: nil,
                                                   note: nil, actor: "Ada", at: Date())
        let item = try #require(try await rig.desk.contradictionReviewItems(caseID: rig.f.caseID).first)
        let reportID = try await JobResultHandoff.addReviewedToReport(item, caseFiles: rig.f.svc, actor: "Ada")
        let p = try #require(await caseMapLoad(rig.f).projection)
        let finding = try #require(p.node(rig.node(.reportItem, reportID)))
        #expect(finding.sources.count == 2)
        #expect(Set(finding.sources.compactMap(\.quote)) == ["The invoice total was 500 dollars.", "The invoice total was 650 dollars."])
        #expect(finding.sources.allSatisfy { $0.positionAvailable })
        let derived = p.links(of: finding.id).filter { $0.type == .derivedFrom }
        #expect(derived.count == 2)
        #expect(Set(derived.map(\.to)) == Set([try await rig.logical(rig.a.version), try await rig.logical(rig.b.version)].map { rig.node(.document, $0) }))
        // The contradiction itself carries both sides, each with its version.
        let c = try #require(p.node(rig.node(.contradiction, rig.contradictionID)))
        #expect(c.sources.compactMap(\.sourceVersionID) == [rig.a.version, rig.b.version] && c.review == .confirmed)
    }

    @Test("A note is never documentary: a note-only grid row is a note item with an unsupported link; a journal note is a note; a bare document reference shows Position unavailable")
    func noteOnlyIsNotDocumentary() async throws {
        let f = try await CaseFileTests.fixture()
        let allegation = try await f.file.addAllegation(caseID: f.caseID, text: "Approval was never given", actor: "Ada")
        try await f.svc.linkEvidence(caseID: f.caseID, allegationID: allegation, evidenceRef: "note:I remember the approval email", label: "my recollection",
                                     stance: .supports, note: nil, actor: "Ada")
        _ = try await f.file.addJournal(caseID: f.caseID, kind: .note, text: "Call the auditor", eventDate: nil, evidenceRef: nil, actor: "Ada")
        let p = try #require(await caseMapLoad(f).projection)
        let notes = p.nodes.filter { $0.kind == .note }
        #expect(notes.count == 2)
        #expect(notes.allSatisfy { !$0.isDocumentary && $0.status.kind == .unsupported })
        let link = try #require(p.links.first { $0.to == CaseMapNodeID(caseID: f.caseID, kind: .allegation, id: allegation) })
        #expect(link.type == .supports && link.status.kind == .unsupported && link.status.text.contains("not documentary"))
        #expect(!p.nodes.contains { $0.kind == .note && $0.status.kind == .recorded })
        let bare = CaseMapSourceRef(sourceVersionID: UUID(), objectID: UUID(), documentName: "x.pdf", quote: nil)
        #expect(!bare.positionAvailable && bare.locatorText.contains("Position unavailable"))
    }

    @Test("States are distinct: verified, unassessed (legacy), restricted (in the case, not readable), unavailable (not in the case), failed (unreadable), stale (superseded)")
    func distinctStates() async throws {
        let rig = try await CaseMapRig.make()
        let f = rig.f
        let a = try await f.file.addAllegation(caseID: f.caseID, text: "Q", actor: "Ada")
        let s = try #require(try await f.svc.snapshot(caseID: f.caseID, custody: []))
        func row(_ ref: String, _ stored: String?, _ detail: String?, origin: String? = nil) -> AllegationEvidence {
            AllegationEvidence(id: UUID(), allegationID: a, evidenceRef: ref, label: nil, stance: .supports, note: nil, addedBy: "Ada", createdAt: Date(),
                               quote: "q", objectID: nil, origin: origin, verification: stored, verificationDetail: detail)
        }
        let outside = UUID()
        let origin = JobResultHandoff.origin(jobID: "inv.linkage", resultID: UUID(), row: 0)
        let grid = [row(rig.a.version.uuidString, "verified", nil),
                    row(rig.a.version.uuidString, nil, nil),
                    row(rig.b.version.uuidString, "unverified", "the cited source is not in this case or is not accessible under the current policy"),
                    row(outside.uuidString, "unverified", "the cited source is not in this case or is not accessible under the current policy"),
                    row(rig.b.version.uuidString, "unverified", "the case's sources could not be read"),
                    row(rig.a.version.uuidString, "verified", nil, origin: origin)]
        let snap = CaseFileSnapshot(caseHeader: s.caseHeader, profile: s.profile, allegations: s.allegations, grid: grid, tasks: [], journal: [], people: [],
                                    contacts: [], interviews: [], credibility: [], exhibits: [], holds: [], redactions: [], batches: [], conflicts: [],
                                    actions: [], custody: [], supersededOrigins: [origin])
        let docs = [CaseMapDocument(sourceVersionID: rig.a.version, logicalSourceID: UUID(), name: "a", objectID: rig.a.object, isCurrent: true),
                    CaseMapDocument(sourceVersionID: rig.b.version, logicalSourceID: UUID(), name: "b", objectID: rig.b.object, isCurrent: true)]
        let p = CaseMapProjector.project(CaseMapInput(snapshot: snap, documents: docs))
        let kinds = grid.map { g in p.links.first { $0.origins.first?.recordID == g.id.uuidString.lowercased() }?.status.kind }
        #expect(kinds == [.recorded, .unassessed, .restricted, .unavailable, .failed, .stale])
        #expect(Set(kinds.compactMap { $0 }).count == 6)
    }

    @Test("Failed ≠ empty: a part that fails is 'partial' and named; a case that cannot be read is 'failed' with no projection; an empty case is 'empty'")
    func failedIsNotEmpty() async throws {
        let f = try await CaseFileTests.fixture()
        var sources = caseMapSources(f)
        let empty = await caseMapLoad(f, sources: sources)
        #expect(empty.state == .empty && empty.projection != nil)
        struct Boom: Error {}
        sources.contradictions = { _ in throw Boom() }
        let partial = await caseMapLoad(f, sources: sources)
        #expect(partial.state == .partial([.contradictions]))
        #expect(partial.projection.map { CaseMapViewFilter.apply($0, view: .overview, filter: CaseMapFilter()).counts.notLoaded } == [.contradictions])
        sources.snapshot = { _, _ in throw Boom() }
        let failed = await caseMapLoad(f, sources: sources)
        if case .failed = failed.state {} else { Issue.record("expected failed, got \(failed.state)") }
        #expect(failed.projection == nil)
        let gone = await caseMapLoad(f, caseID: UUID())
        if case .failed(let why) = gone.state { #expect(why.contains("not in the ledger")) } else { Issue.record("an unknown case is not empty") }
    }

    @Test("A case that changes while it is read twice is 'stale'; a reopened contradiction is stale with the changed document named")
    func staleRevision() async throws {
        let rig = try await CaseMapRig.make()
        var sources = caseMapSources(rig.f)
        let db = rig.f.db, caseID = rig.f.caseID
        let real = sources.contradictions
        let file = rig.f.file
        sources.contradictions = { id in
            // Someone records something in the case during every read.
            try await file.logAction(caseID: caseID, action: "note", detail: nil, actor: "Ben")
            return try await real?(id) ?? []
        }
        let load = await caseMapLoad(rig.f, sources: sources)
        if case .stale = load.state {} else { Issue.record("expected stale, got \(load.state)") }
        #expect(load.projection != nil)

        _ = try await rig.desk.reviewContradiction(caseID: caseID, contradictionID: rig.contradictionID, decision: .dismissed, reason: .differentEvent,
                                                   note: nil, actor: "Ada", at: Date())
        // Revise document A: the decision reopens.
        let logicalA = try await rig.logical(rig.a.version)
        try await db.exec("UPDATE source_versions SET is_current = 0 WHERE logical_source_id = ?;", [.uuid(logicalA)])
        let v2 = UUID()
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at, filename, detected_type, detection_basis,
                size_bytes, custody_mode, preservation_status, intake_recorded_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(v2), .uuid(logicalA), .text(hex + hex), .real(300), .integer(1), .real(300), .text("invoice-a.txt"), .text("txt"),
                  .text("magicBytes"), .integer(1), .text("referenced"), .text("referenceRecorded"), .real(300)])
        let header = try await rig.f.cases.fetch(caseID: caseID)?.caseHeader
        _ = try await rig.f.cases.includeSource(caseID: caseID, expectedRevision: header?.revision ?? 1, sourceRef: v2.uuidString, sourceKind: .sourceVersion, actor: "Ada", at: Date())
        let p = try #require(await caseMapLoad(rig.f).projection)
        let c = try #require(p.node(rig.node(.contradiction, rig.contradictionID)))
        #expect(c.status.kind == .stale && c.review == .reopened && c.history.count == 1)
        #expect(CaseMapViewFilter.apply(p, view: .changes, filter: CaseMapFilter()).shown.contains(c.id))
    }

    @Test("A late load is dropped: an older generation, another case, or after the case is closed out")
    func lateLoadDropped() async throws {
        let f = try await CaseFileTests.fixture()
        let model = CaseMapWorkspaceModel(caseID: f.caseID, workspace: CaseWorkspaceHolder(caseID: f.caseID, defaults: mapDefaults()))
        let service = CaseMapService(sources: caseMapSources(f))
        let g1 = model.beginLoad()
        let g2 = model.beginLoad()
        #expect(!model.apply(await service.load(caseID: f.caseID, generation: g1)))
        #expect(model.projection == nil)
        #expect(!model.apply(await service.load(caseID: UUID(), generation: g2)))
        #expect(model.apply(await service.load(caseID: f.caseID, generation: g2)))
        let g3 = model.beginLoad()
        model.closeOut()
        #expect(!model.apply(await service.load(caseID: f.caseID, generation: g3)) && model.projection == nil)
    }
}

// MARK: - M2 workspace and M3 layout

@MainActor
@Suite("Case map M2/M3 — workspace, layout and counts", .serialized)
struct CaseMapWorkspaceTests {

    @Test("Selection is shared by the map and the list; Back restores the previous view and selection; Previous/Next stop at the ends")
    func selectionAcrossMapAndList() async throws {
        let rig = try await CaseMapRig.make()
        let model = CaseMapWorkspaceModel(caseID: rig.f.caseID, workspace: CaseWorkspaceHolder(caseID: rig.f.caseID, defaults: mapDefaults()))
        await model.refresh(CaseMapService(sources: caseMapSources(rig.f)))
        let c = rig.node(.contradiction, rig.contradictionID)
        model.select(.node(c))
        model.listMode = true
        #expect(model.selection == .node(c))
        model.listMode = false
        #expect(model.selection == .node(c))
        model.go(to: .builtIn(.people))
        model.select(nil)
        #expect(model.selection == nil && model.view == .builtIn(.people))
        model.goBack()
        #expect(model.selection == .node(c) && model.view == .builtIn(.people))
        model.goBack()
        #expect(model.view == .builtIn(.overview) && model.selection == .node(c))
        model.goBack()
        #expect(model.view == .builtIn(.overview) && model.selection == nil && !model.canGoBack)
        model.step(-1)
        #expect(model.view == .builtIn(.overview))
        for _ in 0..<10 { model.step(1) }
        #expect(model.view == .builtIn(.changes))
        #expect(model.breadcrumb.first == "Changes")
    }

    @Test("State survives re-creating the model: positions, pins and saved views from the ledger; view, selection and viewport from the preference, which holds no document text")
    func survivesRecreation() async throws {
        let rig = try await CaseMapRig.make()
        let defaults = mapDefaults()
        let service = CaseMapService(sources: caseMapSources(rig.f))
        var model = CaseMapWorkspaceModel(caseID: rig.f.caseID, workspace: CaseWorkspaceHolder(caseID: rig.f.caseID, defaults: defaults))
        await model.refresh(service)
        let c = rig.node(.contradiction, rig.contradictionID)
        await model.move(c, to: CaseMapPoint(x: 1234, y: -567), repository: service.repository)
        await model.togglePin(c, repository: service.repository)
        model.search = "invoice"
        let saved = try #require(await model.saveCurrentView(named: "Payment authorisation", repository: service.repository, actor: "Ada"))
        model.select(.node(c))
        model.setViewport(CaseMapViewport(scale: 0.5, originX: 10, originY: 20))
        model.listMode = true

        model = CaseMapWorkspaceModel(caseID: rig.f.caseID, workspace: CaseWorkspaceHolder(caseID: rig.f.caseID, defaults: defaults))
        await model.refresh(service)
        #expect(model.placements[c] == CaseMapPlacement(point: CaseMapPoint(x: 1234, y: -567), pinned: true))
        #expect(model.view == .saved(saved) && model.savedView?.name == "Payment authorisation" && model.savedView?.filter.search == "invoice")
        #expect(model.selection == .node(c) && model.listMode)
        #expect(model.viewport() == CaseMapViewport(scale: 0.5, originX: 10, originY: 20))
        // The preference: identifiers and geometry only.
        let raw = String(decoding: try #require(defaults.data(forKey: CaseWorkspaceStore.key(rig.f.caseID))), as: UTF8.self)
        for word in ["invoice", "Payment", "500", "dollars", "Supplier"] { #expect(!raw.contains(word), "“\(word)” in the preference: \(raw)") }
        // The view's name and words are in the ledger.
        #expect(try await rig.f.db.query("SELECT COUNT(*) FROM case_map_views WHERE case_id = ? AND name = 'Payment authorisation';", [.uuid(rig.f.caseID)]).first?.int(0) == 1)
    }

    @Test("Growth: new items never move existing or pinned positions; they land near what they link to or beside the map; Arrange leaves pinned items and Undo restores")
    func stableGrowth() async throws {
        let rig = try await CaseMapRig.make()
        let f = rig.f
        let service = CaseMapService(sources: caseMapSources(f))
        let model = CaseMapWorkspaceModel(caseID: f.caseID, workspace: CaseWorkspaceHolder(caseID: f.caseID, defaults: mapDefaults()))
        await model.refresh(service)
        let first = model.placements
        let c = rig.node(.contradiction, rig.contradictionID)
        await model.togglePin(c, repository: service.repository)
        // New material: an allegation with a link to document B, a person, a note.
        let allegation = try await f.file.addAllegation(caseID: f.caseID, text: "Paid twice", actor: "Ada")
        try await f.svc.linkEvidence(caseID: f.caseID, allegationID: allegation, evidenceRef: rig.b.version.uuidString, label: "b", stance: .supports, note: nil,
                                     passage: StudioEvidenceRef(sourceVersionID: rig.b.version, objectID: rig.b.object, quote: "The invoice total was 650 dollars."), actor: "Ada")
        _ = try await f.file.addPerson(caseID: f.caseID, name: "Ann Lee", role: .witness, entityID: nil, contact: nil, notes: nil, actor: "Ada")
        await model.refresh(service)
        for (id, p) in first { #expect(model.placements[id]?.point == p.point, "\(id) moved on refresh") }
        #expect(model.placements[c]?.pinned == true)
        let p = try #require(model.projection)
        #expect(p.nodes.allSatisfy { model.placements[$0.id] != nil }, "every item has a position")
        let points = p.nodes.compactMap { model.placements[$0.id]?.point }
        #expect(Set(points).count == points.count, "no two items share a position")
        // A pure check of the same rule with a larger insert.
        let stored = model.placements
        let grown = CaseMapLayout.placeNew(p, existing: stored)
        #expect(grown == stored)

        // Arrange everything: the pinned item stays; Undo puts every moved item back.
        let before = model.placements
        let moved = await model.arrange(.view, repository: service.repository)
        #expect(model.placements[c] == before[c])
        if moved > 0 { #expect(model.placements != before) }
        await model.undo(repository: service.repository)
        #expect(model.placements == before)
        #expect(try await service.repository.layout(caseID: f.caseID) == before)
    }

    @Test("Counts reconcile with the full projection in every view, with filters, hidden items and collapsed groups; links join shown items only")
    func countsReconcile() async throws {
        let rig = try await CaseMapRig.make()
        let f = rig.f
        let allegation = try await f.file.addAllegation(caseID: f.caseID, text: "Paid twice", actor: "Ada")
        try await f.svc.linkEvidence(caseID: f.caseID, allegationID: allegation, evidenceRef: "note:a thought", label: nil, stance: .neutral, note: nil, actor: "Ada")
        _ = try await f.file.addPerson(caseID: f.caseID, name: "Ann Lee", role: .witness, entityID: nil, contact: nil, notes: nil, actor: "Ada")
        _ = try await f.file.addJournal(caseID: f.caseID, kind: .chronology, text: "Invoice paid", eventDate: Date(), evidenceRef: rig.a.version.uuidString,
                                        quote: "It was paid in March.", actor: "Ada")
        let p = try #require(await caseMapLoad(f).projection)
        let someone = try #require(p.nodes.first { $0.kind == .person }?.id)
        let filters = [CaseMapFilter(), CaseMapFilter(awaitingOnly: true), CaseMapFilter(search: "invoice"), CaseMapFilter(hidden: [someone]),
                       CaseMapFilter(collapsed: []), CaseMapFilter(kinds: [.evidence], collapsed: ["group:evidence"])]
        for view in CaseMapViewKind.allCases {
            for filter in filters {
                let r = CaseMapViewFilter.apply(p, view: view, filter: filter)
                #expect(r.counts.reconciles && r.counts.total == p.nodes.count, "\(view) \(filter)")
                let shown = Set(r.shown)
                #expect(r.collapsedGroups.flatMap(\.members).allSatisfy { !shown.contains($0) })
                #expect(r.counts.collapsed == r.collapsedGroups.reduce(0) { $0 + $1.members.count })
                #expect(r.links.compactMap { p.link($0) }.allSatisfy { shown.contains($0.from) && shown.contains($0.to) })
            }
        }
        // Everything is reachable: with nothing filtered or collapsed, the overview shows the whole case.
        #expect(CaseMapViewFilter.apply(p, view: .overview, filter: CaseMapFilter(collapsed: [])).shown.count == p.nodes.count)
        // Rendering is bounded and says by how much.
        let placements = CaseMapLayout.placeNew(p, existing: [:])
        let all = CaseMapRect(minX: -1e6, minY: -1e6, maxX: 1e6, maxY: 1e6)
        let cull = CaseMapLayout.cull(p.nodes.map(\.id), positions: placements, in: all, cap: 2)
        #expect(cull.drawn.count == 2 && cull.overCap == p.nodes.count - 2 && cull.offScreen == 0)
    }

    @Test("The preview switch is off unless turned on; a case can return to its sections")
    func previewSwitch() {
        let d = mapDefaults()
        #expect(!CaseMapPreview.isEnabled(d))
        let model = CaseFileModel(caseID: UUID(), workspaceID: UUID(), defaults: d)
        #expect(!model.showsMap(previewOn: CaseMapPreview.isEnabled(d)))
        CaseMapPreview.set(true, d)
        #expect(model.showsMap(previewOn: CaseMapPreview.isEnabled(d)))
        var m = CaseMapWorkspaceMemory(); m.showsSections = true
        model.workspace.state.map = m
        #expect(!model.showsMap(previewOn: true))
    }
}

// MARK: - M4 investigator links and v171

@MainActor
@Suite("Case map M4 — links and the v171 tables", .serialized)
struct CaseMapLinkTests {

    @Test("A link is checked in the write: both ends in this case, the case open, a reason; withdrawn with a reason, never edited")
    func linksChecked() async throws {
        let f = try await CaseFileTests.fixture()
        let repo = CaseMapRepository(database: f.db)
        let a1 = try await f.file.addAllegation(caseID: f.caseID, text: "A1", actor: "Ada")
        let person = try await f.file.addPerson(caseID: f.caseID, name: "Ann Lee", role: .witness, entityID: nil, contact: nil, notes: nil, actor: "Ada")
        let other = try await f.cases.createCase(workspaceID: f.workspaceID, title: "Other", actor: "Ada", at: Date())
        let foreign = try await f.file.addAllegation(caseID: other.id, text: "B1", actor: "Ada")
        let from = CaseMapNodeID(caseID: f.caseID, kind: .person, id: person), to = CaseMapNodeID(caseID: f.caseID, kind: .allegation, id: a1)
        await #expect(throws: CaseMapError.blank("The reason for the link")) {
            _ = try await repo.addLink(caseID: f.caseID, type: .dependsOn, from: from, to: to, rationale: " ", actor: "Ada")
        }
        await #expect(throws: CaseMapError.notInCase("allegation")) {
            _ = try await repo.addLink(caseID: f.caseID, type: .dependsOn, from: from, to: CaseMapNodeID(caseID: f.caseID, kind: .allegation, id: foreign), rationale: "x", actor: "Ada")
        }
        await #expect(throws: CaseMapError.notInCase("item")) {
            _ = try await repo.addLink(caseID: f.caseID, type: .dependsOn, from: from, to: CaseMapNodeID(caseID: other.id, kind: .allegation, id: foreign), rationale: "x", actor: "Ada")
        }
        await #expect(throws: CaseMapError.notLinkable("contradiction")) {
            _ = try await repo.addLink(caseID: f.caseID, type: .dependsOn, from: from, to: CaseMapNodeID(caseID: f.caseID, kind: .contradiction, id: UUID()), rationale: "x", actor: "Ada")
        }
        let id = try await repo.addLink(caseID: f.caseID, type: .attributedTo, from: from, to: to, rationale: "She made the complaint", actor: "Ada")
        var p = try #require(await caseMapLoad(f).projection)
        let drawn = try #require(p.links.first { $0.origins.first?.recordID == id.uuidString.lowercased() })
        #expect(drawn.basis == "She made the complaint" && drawn.from == from && drawn.to == to)
        if case .investigator(let who) = drawn.assertedBy { #expect(who == "Ada") } else { Issue.record("asserted by the investigator") }
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_map_links SET rationale = 'changed';", []) }
        try await repo.withdrawLink(caseID: f.caseID, id: id, reason: "wrong person", actor: "Ada")
        await #expect(throws: CaseMapError.alreadyWithdrawn) { try await repo.withdrawLink(caseID: f.caseID, id: id, reason: "again", actor: "Ada") }
        p = try #require(await caseMapLoad(f).projection)
        #expect(!p.links.contains { $0.origins.first?.recordID == id.uuidString.lowercased() } && p.withdrawnLinks == 1)
        #expect(try await repo.links(caseID: f.caseID).first?.withdrawnReason == "wrong person")
        // A closed case refuses new links.
        try await f.db.exec("UPDATE investigation_cases SET status = 'closed' WHERE id = ?;", [.uuid(f.caseID)])
        await #expect(throws: CaseMapError.caseClosed) {
            _ = try await repo.addLink(caseID: f.caseID, type: .dependsOn, from: from, to: to, rationale: "x", actor: "Ada")
        }
        // No position is stored for a case that is not in the ledger (late work after an erase).
        await #expect(throws: CaseMapError.caseNotFound) {
            try await repo.savePlacements(caseID: UUID(), [CaseMapNodeID(caseID: UUID(), kind: .person, id: UUID()): CaseMapPlacement(point: CaseMapPoint(x: 0, y: 0))])
        }
    }

    @Test("v171 from a v170 ledger: earlier rows are kept, the three map tables and the edit guard exist, latest is a safe no-op")
    func migrationFromV170() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 170)
        let ws = UUID(), c = UUID(), r = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);", [.uuid(ws), .text("W"), .real(1), .real(1)])
        try await db.exec("""
            INSERT INTO investigation_cases (id, workspace_id, title, status, revision, actor, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?);
            """, [.uuid(c), .uuid(ws), .text("C"), .text("open"), .integer(1), .text("u"), .real(1), .real(1)])
        try await db.exec("""
            INSERT INTO investigation_evidence_requests (id, case_id, description, status, revision, actor, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?);
            """, [.uuid(r), .uuid(c), .text("Phone records"), .text("partial"), .integer(2), .text("Ada"), .real(10), .real(20)])
        #expect(!(try await MigrationFixtureBuilder.tableExists(db, "case_map_views")))
        try await SchemaMigrations.migrate(db, through: 171)
        #expect(try await db.currentUserVersion() == 171)
        for t in ["case_map_views", "case_map_layout", "case_map_links"] { #expect(try await MigrationFixtureBuilder.tableExists(db, t), "\(t) missing") }
        let old = try #require(try await InvestigationAnalysisRepository(database: db).requests(caseID: c).first)
        #expect(old.id == r && old.status == .partial && old.revision == 2)
        let repo = CaseMapRepository(database: db)
        let id = try await repo.addLink(caseID: c, type: .dependsOn, from: CaseMapNodeID(caseID: c, kind: .caseFile, id: c),
                                        to: CaseMapNodeID(caseID: c, kind: .request, id: r), rationale: "asked for it", actor: "Ada")
        await #expect(throws: (any Error).self) { try await db.exec("UPDATE case_map_links SET to_id = 'x' WHERE id = ?;", [.uuid(id)]) }
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
        #expect(try await MigrationFaultHarness.integrityOK(db))
        #expect(SchemaMigrations.isIdempotent(try #require(SchemaMigrations.migrationSQL(for: 171))), "v171 can be re-run by the repair pass")
    }
}
