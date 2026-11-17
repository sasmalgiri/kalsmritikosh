//
//  CasePartialRowsTests.swift
//  KalsmritikoshTests
//
//  Reachability recheck 2026-11-17 — the partly reachable rows finished from the map: a result version naming what was
//  examined, bound to it (ACTION-08 / ACTION-13 / CHANGE-11); an evidence request from a point, bound to the point
//  (CHANGE-11); a brief proposed from the case's records beside the accepted one (CHANGE-04); a statement checked on
//  screen (MONEY-07); the matching rule's latest assessment of a pair (PEOPLE-07). AI off, no network.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@MainActor
@Suite("Partly reachable rows, finished from the map", .serialized)
struct CasePartialRowsTests {

    @Test("A result version names the examined document and is bound to it and to the action; the review pins that version")
    func boundResult() async throws {
        let f = try await CaseFileTests.fixture(title: "Was the seal intact?")
        let c = f.caseID
        let doc = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: c, name: "seal-photos.txt", text: "Photo 3 shows the seal on bag 7 intact.")
        let task = try await f.svc.createAction(caseID: c, .init(title: "Examine the seal photographs", purpose: "Was the seal intact?", deliverable: "A note"), actor: "Ada")
        let p = try #require(await caseMapLoad(f).projection)
        let w = try await f.svc.recordBoundResult(caseID: c, taskID: task, kind: .record, outcome: .inconclusive, summary: "Photo 3 is too dark to tell",
                                                  inputs: [.source(doc.version, "seal-photos.txt")], reportTitle: nil, projection: p, actor: "Ada")
        #expect(w.bindingProblem == nil, "\(w.bindingProblem ?? "")")
        #expect(w.value.outcome == .inconclusive && w.value.revision == 1)
        let bound = try await f.file.derivationBindings(caseID: c).filter { $0.derivedKind == .actionResult && $0.derivedID == w.value.id.uuidString.lowercased() }
        let keys = Set(bound.flatMap(\.inputs).map(\.key))
        #expect(keys.contains(CaseMapNodeID(caseID: c, kind: .task, id: task).key), "\(keys)")
        #expect(keys.contains { $0.hasPrefix("document:") }, "\(keys)")
        // Nothing examined: refused unless it is "no result".
        await #expect(throws: (any Error).self) {
            _ = try await f.svc.recordBoundResult(caseID: c, taskID: task, kind: .record, outcome: .successful, summary: "x", inputs: [], reportTitle: nil, projection: p, actor: "Ada")
        }
        // The input keys keep only what is on the map.
        let keysOnly = CaseFileService.resultInputKeys(caseID: c, taskID: task, inputs: [.source(UUID(), "not in the case")], projection: p)
        #expect(keysOnly == [CaseMapNodeID(caseID: c, kind: .task, id: task).key])
    }

    @Test("An evidence request raised from a point is bound to the point")
    func boundRequest() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f, c = f.caseID
        let pt = try await f.svc.addPoint(caseID: c, reportID: rig.report, kind: .finding, statement: "The sample weighed 12 grams",
                                          quote: "The sample weighed 12 grams.", actor: "Ada")
        let evidence = EvidenceStore(database: f.db)
        let analysis = InvestigationAnalysisService(cases: f.cases, resolver: CaseRetrievalScopeResolver(evidence: evidence), evidence: evidence,
                                                    analysis: InvestigationAnalysisRepository(database: f.db))
        let p = try #require(await caseMapLoad(f).projection)
        let w = try await f.svc.requestEvidenceBound(caseID: c, fromPoint: pt, details: EvidenceRequestDetails(description: "Balance calibration log"),
                                                     purpose: "Check the weighing", analysis: analysis, projection: p, actor: "Ada")
        #expect(w.bindingProblem == nil, "\(w.bindingProblem ?? "")")
        let bound = try await f.file.derivationBindings(caseID: c).filter { $0.derivedKind == .request }
        #expect(bound.contains { b in b.inputs.contains { $0.key == CaseMapNodeID(caseID: c, kind: .reportPoint, id: pt).key } })
    }

    @Test("A brief proposed from the case's records is a generated, unaccepted version beside the accepted one")
    func generatedBriefProposal() async throws {
        let f = try await CaseFileTests.fixture(title: "Was Kestrel paid twice?")
        let c = f.caseID
        _ = try await f.file.addAllegation(caseID: c, text: "Kestrel Supplies was paid twice for INV-104", actor: "Ada")
        let anchor = CaseMapNodeID(caseID: c, kind: .caseFile, id: c)
        let v1 = try await f.file.writeBrief(caseID: c, anchor: anchor, text: CaseBriefText(position: "Two debits are recorded."), expectedVersion: 0, actor: "Ada")
        try await f.file.acceptBrief(caseID: c, id: v1, actor: "Ada")
        let p = try #require(await caseMapLoad(f).projection)
        let text = CaseMapBrief.compute(p).generatedText
        #expect(text.position?.hasPrefix("Inconclusive on the available evidence.") == true, "\(text.position ?? "")")
        #expect(!text.isEmpty)
        let fence = try await f.file.resultFence(caseID: c, anchor: anchor, policy: CaseMapBrief.drafterName, requestedBy: "Ada")
        #expect(try await f.file.applyGeneratedBrief(fence, text: text, generatedBy: CaseMapBrief.drafterName, policyNow: CaseMapBrief.drafterName).isApplied)
        let view = CaseBriefRefreshView.resolve(try await f.file.briefLedger(caseID: c), anchor: anchor)
        #expect(view.accepted?.id == v1 && view.proposal?.origin == .generated && view.proposal?.isAccepted == false)
    }

    @Test("A statement with no balances is partial on screen, never reconciled; the gap between statements is named")
    func statementCheck() async throws {
        let f = try await CaseFileTests.fixture(title: "Statements")
        let acct = try await f.file.addMoneyAccount(caseID: f.caseID, identifier: "3391", actor: "Ada")
        let st = try await f.file.addMoneyStatement(caseID: f.caseID, accountID: acct, periodStart: "2026-04-01", periodEnd: "2026-04-30",
                                                    opening: nil, closing: nil, currency: "INR", actor: "Ada")
        _ = try await f.file.importStatementRows(caseID: f.caseID, statementID: st, text: "Date,Description,Reference,Debit,Credit\n2026-04-02,Payment to Ravi,NEFT,\"1,000.00\",\n", actor: "Ada")
        _ = try await f.file.addMoneyStatement(caseID: f.caseID, accountID: acct, periodStart: "2026-06-01", periodEnd: "2026-06-30",
                                               opening: "INR 0", closing: "INR 0", currency: "INR", actor: "Ada")
        let l = try await f.file.moneyLedger(caseID: f.caseID)
        let checks = l.distinctStatements.map(l.check)
        #expect(checks.count == 2)
        #expect(checks.first?.state == .partial && checks.first?.label.hasPrefix("Not reconciled — partial") == true, "\(checks.first?.label ?? "")")
        #expect(!l.missingPeriods().isEmpty, "May has no statement")
        await f.db.close()
    }

    @Test("The latest assessment of a pair is found whichever way round the pair is named")
    func latestAssessment() {
        let a = UUID(), b = UUID(), other = UUID()
        func m(_ x: UUID, _ y: UUID, _ t: TimeInterval, _ v: CasePersonMatchAssessment.Verdict) -> CasePersonMatchAssessment {
            CasePersonMatchAssessment(id: UUID(), personA: x, personB: y, ruleVersion: 1, verdict: v, reasons: [], assessedBy: "Ada", assessedAt: Date(timeIntervalSince1970: t))
        }
        let all = [m(a, b, 10, .weakCandidate), m(b, a, 20, .keepSeparate), m(a, other, 30, .strongCandidate)]
        #expect(CasePersonMatchBlock.latest(all, a, b)?.verdict == .keepSeparate)
        #expect(CasePersonMatchBlock.latest(all, b, other) == nil)
    }

    @Test("A binding key keeps its kind as written and lowercases only the id (two-word kinds were refused)")
    func inputKeyNormalised() {
        #expect(CaseFileRepository.normalisedInputKey("reportPoint:ABC-1") == "reportPoint:abc-1")
        #expect(CaseFileRepository.normalisedInputKey("brief:XY") == "brief:xy")
        #expect(CaseFileRepository.normalisedInputKey("noColon") == "noColon")
    }

    @Test("MAP-13: switching the presentation is a step; Back returns to the presentation and selection it was taken in")
    func backRestoresPresentation() {
        let c = UUID()
        let d = UserDefaults(suiteName: "partial-\(UUID().uuidString)") ?? .standard
        let model = CaseMapWorkspaceModel(caseID: c, workspace: CaseWorkspaceHolder(caseID: c, defaults: d))
        let a = CaseMapNodeID(caseID: c, kind: .allegation, id: UUID()), b = CaseMapNodeID(caseID: c, kind: .document, id: UUID())
        #expect(model.presentation == .map)
        model.select(.node(a))
        model.showAs(.list)
        model.select(.node(b))
        model.goBack()
        #expect(model.selection == .node(a) && model.presentation == .list)
        model.goBack()
        #expect(model.selection == .node(a) && model.presentation == .map)
        model.goForward()
        #expect(model.presentation == .list)
        model.showAs(.list)   // the same presentation is not a step
        model.goBack()
        #expect(model.presentation == .map)
    }

    @Test("BRIEF-10: the changes since a reader's version, part by part; unchanged parts say so")
    func briefDiff() {
        let parts = CaseBriefDiff.between(CaseBriefText(purpose: "Was Kestrel paid twice?", position: "Two debits."),
                                          CaseBriefText(purpose: "Was Kestrel paid twice?", position: "Two debits.\nOne refund.", nextWork: "Match the refund"))
        #expect(parts.first { $0.title == "Purpose" }?.unchanged == true)
        #expect(parts.first { $0.title == "Current position" }?.added == ["One refund."])
        #expect(parts.first { $0.title == "Next work" }?.added == ["Match the refund"])
    }

    @Test("SEARCH-14: an earlier page's document sharing a full name is carried and its pair with the page is found once; a shared surname alone carries nothing")
    func crossPageCarry() {
        typealias D = CaseContradictionFinder.Document
        let page = [D(objectID: UUID(), text: "Brian Kelly, 50, of Boca Raton, pleaded guilty on June 2, 2013, to conspiracy.")]
        let same = D(objectID: UUID(), text: "Brian Kelly, 50, of Boca Raton, pleaded guilty on May 2, 2013, to conspiracy.")
        let surnameOnly = D(objectID: UUID(), text: "Kelly was not in court that day.")
        let other = D(objectID: UUID(), text: "Anita Rao signed invoice INV-104 on 3 March 2026.")
        let carried = CaseContradictionCarry.carried(page: page, earlier: [other, surnameOnly, same])
        #expect(carried.map(\.objectID) == [same.objectID], "\(carried.map(\.text))")
        let cross = CaseContradictionCarry.crossFindings(page: page, carried: carried)
        #expect(cross.contains { $0.kind == .date } && cross.allSatisfy { Set([$0.objectA, $0.objectB]) == Set([page[0].objectID, same.objectID]) }, "\(cross.map(\.description))")
        // A reference is a subject too.
        let refPage = [D(objectID: UUID(), text: "Payment against INV-104 was approved.")]
        #expect(CaseContradictionCarry.carried(page: refPage, earlier: [other]).count == 1)
        #expect(CaseContradictionCarry.carried(page: page, earlier: [same], limit: 0).isEmpty)
    }

    @Test("SEARCH-13: with a question the check reads matching documents first, then the rest by id — stable, no gaps or repeats")
    func questionOrder() async throws {
        let a = UUID(), b = UUID(), c = UUID()
        let byID = [a, b, c].sorted { $0.uuidString < $1.uuidString }
        let order = AppState.caseContradictionOrder(byID: byID, ranked: [byID[2], byID[2]])
        #expect(order == [byID[2], byID[0], byID[1]])
        #expect(AppState.caseContradictionOrder(byID: byID, ranked: []) == byID)
        let f = try await CaseFileTests.fixture(title: "Batch 42")
        let cal = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "calibration.txt",
                                                            text: "Calibration record HPLC-2: next calibration overdue since February.")
        let other = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "weighing.txt", text: "Routine weighing entries.")
        let objects = KnowledgeObjectRepository(database: f.db)
        let ordered = try await AppState.caseContradictionOrder(objects: objects, ids: [cal.object, other.object], question: "Was the instrument calibration overdue?")
        #expect(ordered == [cal.object, other.object], "\(ordered)")
        #expect(try await AppState.caseContradictionOrder(objects: objects, ids: [cal.object, other.object], question: nil).count == 2)
        var run = CaseContradictionRun(); run.documents = 2; run.orderedBy = "Was the instrument calibration overdue?"
        #expect(CaseContradictionReviewModel.rulesRunText(run).contains("read in the order of the case question"))
    }

    @Test("The new controls are named in the help")
    func help() {
        for c in ["Start from a template", "Propose a version from the case's records", "Check with the matching rules", "Look for this identifier"] {
            #expect(CaseMapControlHelp.entry(c) != nil, "\(c)")
        }
        #expect(CaseActionTemplate.all.count == 8)
    }
}
