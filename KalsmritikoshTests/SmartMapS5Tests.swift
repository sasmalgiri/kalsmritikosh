//
//  SmartMapS5Tests.swift
//  KalsmritikoshTests
//
//  Smart-map S5 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md: REASON and TIME of milestone M2; schema
//  v181). Throwaway ledgers; expected results written by hand from the fixture texts. AI off: nothing here calls a model
//  or the network. Contradiction DETECTION is not changed by S5 — REASON-11 only measures it.
//

import Foundation
import Testing
@testable import Kalsmritikosh

/// A new current version of the document behind `object`, with its own text blocks, included in the case.
private func reviseWithText(_ db: Database, object: UUID, cases: InvestigationCaseRepository, caseID: UUID, text: String, at t: Double) async throws -> UUID {
    let fileID = try #require(try await db.query("SELECT file_id FROM knowledge_objects WHERE id = ?;", [.uuid(object)]).first?.uuid(0))
    try await db.exec("UPDATE source_versions SET is_current = 0 WHERE logical_source_id = ?;", [.uuid(fileID)])
    let version = UUID(), doc = UUID()
    let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    try await db.exec("""
        INSERT INTO source_versions (id, logical_source_id, document_id, content_hash, valid_from, is_current, created_at,
            filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?);
        """, [.uuid(version), .uuid(fileID), .uuid(doc), .text(hex + hex), .real(t), .integer(1), .real(t),
              .text("revised.txt"), .text("txt"), .text("magicBytes"), .integer(1), .text("referenced"), .text("referenceRecorded"), .real(t)])
    try await db.exec("""
        INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text, extraction_method, extraction_confidence)
        VALUES (?,?,?,?,?,?,?,?,?);
        """, [.uuid(UUID()), .uuid(doc), .uuid(version), .integer(0), .text("paragraph"), .text(text), .text(text.lowercased()), .text("native"), .real(1.0)])
    let header = try await cases.fetch(caseID: caseID)?.caseHeader
    _ = try await cases.includeSource(caseID: caseID, expectedRevision: header?.revision ?? 1, sourceRef: version.uuidString,
                                      sourceKind: .sourceVersion, actor: "Ada", at: Date())
    return version
}

@MainActor
private struct ConflictRig {
    let f: CaseFileTests.Fixture
    let desk: InvestigationContradictionGapService
    let contradictions: ContradictionsRepository
    let a: (version: UUID, object: UUID, blocks: [UUID])
    let b: (version: UUID, object: UUID, blocks: [UUID])
    let finding: CaseContradictionFinder.Finding

    static func make() async throws -> ConflictRig {
        let f = try await CaseFileTests.fixture()
        let a = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "invoice-a.txt",
                                                          text: "The order was placed by the depot. The invoice total was 500 dollars. It was paid in March.")
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
        return ConflictRig(f: f, desk: desk, contradictions: contradictions, a: a, b: b, finding: finding)
    }
    var id: UUID { finding.contradiction().id }
    func item() async throws -> CaseContradictionReviewItem {
        try #require(try await desk.contradictionReviewItems(caseID: f.caseID).first { $0.id == id })
    }
}

// MARK: - REASON

@MainActor
@Suite("Smart map S5 — reasoning (REASON)", .serialized)
struct SmartMapS5ReasonTests {

    @Test("REASON-01: a speaker only from an explicit attribution; firsthand / reported / not stated; when it applies; nearby names are never speakers")
    func attribution() async throws {
        let said = CaseAttributionReader.read("Ravi Kumar said that the van left the depot at nine on 3 March.")
        #expect(said.speaker == "Ravi Kumar" && said.basis == .speechVerb && said.mode == .notStated && said.appliesText == "on 3 March")
        let reported = CaseAttributionReader.read("Ravi Kumar said that Meena Shah told him the van left early.")
        #expect(reported.speaker == "Ravi Kumar" && reported.mode == .reported && reported.reportedFrom == "Meena Shah")
        let firsthand = CaseAttributionReader.read("According to Asha Rao, she saw the driver sign the log.")
        #expect(firsthand.speaker == "Asha Rao" && firsthand.basis == .accordingTo && firsthand.mode == .firsthand)
        // Names near the words are not speakers.
        for s in ["Ravi Kumar was at the depot when the van left at nine.", "The memo was sent to Ravi Kumar, who said nothing.",
                  "Meena Shah. The van left at nine."] {
            let r = CaseAttributionReader.read(s)
            #expect(r.speaker == nil && r.mode == .unattributed && r.basis == CaseAttributionBasis.none, "\(s)")
        }
        let f = try await CaseFileTests.fixture()
        let doc = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "statement.txt",
                                                            text: "Ravi Kumar was at the depot. Ravi Kumar said that the van left at nine on 3 March. The gate was open.")
        let ids = try await f.file.readAttributions(caseID: f.caseID, sourceVersionID: doc.version, actor: "Ada")
        #expect(ids.count == 1, "only the attributed sentence is recorded")
        #expect(try await f.file.readAttributions(caseID: f.caseID, sourceVersionID: doc.version, actor: "Ada").isEmpty, "reading again adds nothing")
        let list = try await f.file.attributions(caseID: f.caseID)
        #expect(list.count == 1 && list[0].speaker == "Ravi Kumar" && list[0].byRule && list[0].sourceVersionID == doc.version)
        #expect(list[0].line.contains("read by rule, not reviewed"))
        // A speaker needs a basis; the investigator's own attribution needs its reason.
        var bare = CaseAttributionReader.read("The van left at nine.")
        bare.speaker = "Ravi Kumar"; bare.mode = .notStated
        await #expect(throws: CaseReasoningError.speakerNeedsBasis) { _ = try await f.file.recordAttribution(caseID: f.caseID, bare, actor: "Ada") }
        bare.basis = .investigator
        await #expect(throws: CaseReasoningError.investigatorBasisNeedsReason) { _ = try await f.file.recordAttribution(caseID: f.caseID, bare, actor: "Ada") }
        bare.basisDetail = "He signed the statement page"
        let manual = try await f.file.recordAttribution(caseID: f.caseID, bare, sourceVersionID: doc.version, actor: "Ada")
        // The ledger refuses a speaker without a basis even when written directly.
        await #expect(throws: (any Error).self) {
            try await f.db.exec("INSERT INTO case_assertion_attributions (id, case_id, quote, claim, speaker, mode, basis, origin, recorded_by, recorded_at) VALUES (?,?,?,?,?,?,?,?,?,?);",
                                [.uuid(UUID()), .uuid(f.caseID), .text("q"), .text("q"), .text("Ravi"), .text("notStated"), .text("none"), .text("investigator"), .text("Ada"), .real(1)])
        }
        try await f.file.withdrawAttribution(caseID: f.caseID, id: manual, reason: "Wrong page", actor: "Ada")
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_assertion_attributions SET speaker = 'x' WHERE id = ?;", [.uuid(manual)]) }
    }

    @Test("REASON-02 / REASON-09 / REASON-10: qualifies, mentions and unassessed rows are not support; completed child work does not decide; the decision keeps its inputs, alternatives and contrary material")
    func relationsAndDecisionInputs() async throws {
        let f = try await CaseFileTests.fixture()
        let c = f.caseID
        let a = try await f.file.addAllegation(caseID: c, text: "The supplier was paid twice", actor: "Ada")
        let bank = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: c, name: "bank-statement.txt",
                                                             text: "Transfer to Dalmia Traders on 5 March 2026 for ₹10,000. A second transfer of ₹10,000 followed on 9 March 2026.")
        let memo = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: c, name: "memo.txt",
                                                             text: "The second transfer was reversed by the bank on 10 March 2026.")
        let row = try await f.svc.linkEvidence(caseID: c, allegationID: a, evidenceRef: bank.version.uuidString, label: "Bank statement", stance: .supports, note: nil,
                                               passage: StudioEvidenceRef(sourceVersionID: bank.version, quote: "A second transfer of ₹10,000 followed on 9 March 2026."), actor: "Ada")
        #expect(row.verification.support.isDocumentary)
        let lim = try await f.svc.linkEvidence(caseID: c, allegationID: a, evidenceRef: memo.version.uuidString, label: "Reversal memo", stance: .neutral, note: nil,
                                               passage: StudioEvidenceRef(sourceVersionID: memo.version, quote: "The second transfer was reversed by the bank on 10 March 2026."), actor: "Ada")
        // A neutral row from before v181 had no relation: it reads as "relevance not assessed", never as support.
        #expect(CaseEvidenceRelation.of(stance: .neutral, stored: nil) == .unassessed)
        #expect(try await f.file.allegationEvidence(caseID: c).first { $0.id == lim.id }?.relation == .unassessed)
        try await f.file.recordResponse(allegationID: a, caseID: c, response: "The second one bounced", actor: "Ada")
        // Only a verified supporting row is support: the same verified row as qualifies / mentions / unassessed refuses the finding.
        for rel in [CaseEvidenceRelation.qualifies, .mentions, .unassessed] {
            try await f.file.setEvidenceRelation(caseID: c, linkID: row.id, relation: rel, actor: "Ada")
            await #expect(throws: CaseFileError.self, "\(rel)") {
                try await f.svc.decide(allegationID: a, caseID: c, disposition: .substantiated, rationale: "Two debits", actor: "Ada")
            }
        }
        try await f.file.setEvidenceRelation(caseID: c, linkID: row.id, relation: .supports, actor: "Ada")
        try await f.file.setEvidenceRelation(caseID: c, linkID: lim.id, relation: .qualifies, actor: "Ada")
        #expect(try await f.file.contraryMaterial(caseID: c, allegationID: a).map(\.id) == [lim.id])
        #expect(try await CaseRecordRevisions.revisions(f.db, caseID: c, kind: "allegationEvidence").count >= 5, "every relation change keeps its before/after copy")
        // REASON-09: completing every child action does not decide the question.
        for t in ["Get the bank's confirmation", "Interview the accountant"] {
            let task = try await f.svc.createAction(caseID: c, .init(title: t, purpose: "Settle the second payment", deliverable: "A written answer", servesQuestions: [a]), actor: "Ada")
            try await f.svc.completeTask(caseID: c, taskID: task, actor: "Ada")
        }
        #expect(try await f.file.allegations(caseID: c).first { $0.id == a }?.disposition == .pending)
        #expect(try await f.file.decisionInputs(caseID: c, allegationID: a).isEmpty)
        // REASON-10: the decision is frozen with its inputs and the alternatives on record.
        let analysis = InvestigationAnalysisRepository(database: f.db)
        _ = try await analysis.captureHypothesis(caseID: c, statement: "The second transfer was a duplicate the bank reversed", actor: "Ada", at: Date())
        try await f.svc.decide(allegationID: a, caseID: c, disposition: .inconclusive, rationale: "The reversal is not explained by the bank yet", actor: "Ada")
        let inputs = try #require(try await f.file.decisionInputs(caseID: c, allegationID: a).first)
        #expect(inputs.disposition == "inconclusive" && inputs.rows.count == 2 && inputs.contrary.map(\.id) == [lim.id.uuidString.lowercased()])
        #expect(inputs.alternatives.count == 1 && inputs.alternatives[0].statement.contains("duplicate"))
        #expect(inputs.rows.contains { $0.relation == "supports" && $0.verification == "verified" })
        let text = inputs.lines.joined(separator: "\n")
        #expect(text.contains("Alternative explanations on record (1)") && text.contains("Reversal memo") && text.contains("Input digest"))
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_decision_inputs SET rationale = 'x';", []) }
        // Alternatives are presented in recorded order, without counts or a vote.
        let alts = try await f.file.alternatives(caseID: c)
        #expect(alts.explanations.count == 1 && alts.notice.contains("does not count, rank or vote"))
    }

    @Test("REASON-03 / REASON-04: both passages with their surrounding words, values and versions; cautions for denials, definitions, other dates and currencies — never deciding")
    func comparison() async throws {
        let rig = try await ConflictRig.make()
        let cmp = try await rig.desk.comparison(caseID: rig.f.caseID, contradictionID: rig.id)
        #expect(cmp.a.foundInVersion && cmp.b.foundInVersion)
        #expect(cmp.a.before?.contains("placed by the depot") == true && cmp.a.after?.contains("paid in March") == true)
        #expect(cmp.a.values.contains("500 dollars") && cmp.b.values.contains("650 dollars"))
        #expect(cmp.a.versionLabel.contains("the current version") && cmp.a.sourceVersionID == rig.a.version)
        #expect(cmp.subject.hasPrefix("The invoice"))
        #expect(cmp.lines.contains { $0.contains("[The invoice total was 500 dollars.]") })
        // Cautions are about the pair as quoted.
        #expect(CaseDifferenceCheck.cautions("The supplier was not paid in March.", "The supplier was paid ₹5,000 in March.").contains(.negation))
        #expect(CaseDifferenceCheck.cautions("Gross revenue was 10 lakh.", "Net revenue was 8 lakh.").contains(.definition))
        let money = CaseDifferenceCheck.cautions("Paid USD 500 on 3 March 2024.", "Paid ₹500 on 9 March 2024.", kind: .amount)
        #expect(money.contains(.otherCurrency) && money.contains(.otherTime))
        #expect(CaseDifferenceCheck.cautions("Ravi said the van was late.", "The van was on time.").contains(.quotedSpeaker))
        #expect(CaseDifferenceCheck.cautions("The corrected invoice total is 650 dollars.", "The invoice total was 500 dollars.").contains(.correction))
        #expect(CaseDifferenceCheck.cautions("The invoice total was 500 dollars.", "The invoice total was 650 dollars.", kind: .amount).isEmpty)
        // Reading the comparison changed nothing.
        #expect(try await rig.item().status.latest == nil)
    }

    @Test("REASON-06 / REASON-12: explained and unresolved need their reason; an item no longer detected keeps its decision; a new version reopens only when the decided words changed")
    func statesAndMateriality() async throws {
        let rig = try await ConflictRig.make()
        let c = rig.f.caseID
        #expect(try await rig.item().status.state == .proposed)
        await #expect(throws: InvestigationDeskError.noteRequired) {
            _ = try await rig.desk.reviewContradiction(caseID: c, contradictionID: rig.id, decision: .explained, reason: nil, note: nil, actor: "Ada", at: Date())
        }
        try await rig.desk.reviewContradiction(caseID: c, contradictionID: rig.id, decision: .unresolved, reason: nil, note: "Neither invoice is the final one",
                                               actor: "Ada", at: Date(timeIntervalSince1970: 1_000))
        var st = try await rig.item().status
        #expect(st.state == .unresolved && st.state.isOpen && !st.awaitingReview)
        try await rig.desk.reviewContradiction(caseID: c, contradictionID: rig.id, decision: .explained, reason: nil, note: "Two invoices: an estimate and the final bill",
                                               actor: "Ben", at: Date(timeIntervalSince1970: 2_000))
        st = try await rig.item().status
        #expect(st.state == .explained && !st.state.isOpen && st.history.map(\.decision) == [.unresolved, .explained])
        #expect(st.latest?.passages[rig.a.object] == "The invoice total was 500 dollars.")
        // A new version of A that still holds the decided words: the decision stands, and says why.
        _ = try await reviseWithText(rig.f.db, object: rig.a.object, cases: rig.f.cases, caseID: c,
                                     text: "Order note. The invoice total was 500 dollars. It was paid in March by cheque.", at: 300)
        st = try await rig.item().status
        #expect(!st.isReopened && st.current == .explained && st.unchangedPassageObjects == [rig.a.object])
        #expect(st.label(names: [rig.a.object: "invoice-a.txt"]).contains("passage this was decided on is unchanged"))
        // A version where the words changed reopens it.
        _ = try await reviseWithText(rig.f.db, object: rig.a.object, cases: rig.f.cases, caseID: c, text: "The invoice total was 550 dollars.", at: 400)
        st = try await rig.item().status
        #expect(st.isReopened && st.state == .reopened && st.changedObjects == [rig.a.object])
        // The check no longer produces the item: it stays listed with its last decision.
        try await rig.f.db.exec("DELETE FROM contradictions WHERE id = ?;", [.uuid(rig.id)])
        let gone = try await rig.desk.noLongerDetected(caseID: c)
        #expect(gone.count == 1 && gone[0].itemID == rig.id.uuidString && gone[0].history.last?.decision == .explained)
        #expect(gone[0].line.contains("not treated as resolved") && gone[0].state == .noLongerDetected)
    }

    @Test("REASON-07: a follow-up action carries the exact question, the result needed and both accounts; its outcome can be inconclusive and is recorded once")
    func followUp() async throws {
        let rig = try await ConflictRig.make()
        let c = rig.f.caseID
        let contradiction = rig.finding.contradiction()
        let task = try await rig.f.svc.createConflictFollowUp(caseID: c, contradiction: contradiction, versionA: rig.a.version, versionB: rig.b.version,
                                                              question: "Which invoice total did the supplier finally bill?",
                                                              neededResult: "The supplier's ledger entry for the order", actor: "Ada")
        let fu = try #require(try await rig.f.file.conflictFollowUps(caseID: c).first)
        #expect(fu.taskID == task && fu.contradictionID == rig.id && fu.sideA.quote == rig.finding.quoteA && fu.sideB.quote == rig.finding.quoteB)
        #expect(fu.sideA.version == rig.a.version && fu.outcome == .pending)
        let contract = try #require(try await rig.f.file.reportLedger(caseID: c).contract(task))
        #expect(contract.purpose == "Which invoice total did the supplier finally bill?" && contract.deliverable == "The supplier's ledger entry for the order")
        await #expect(throws: CaseReasoningError.outcomeNeedsNote) { try await rig.f.file.recordFollowUpOutcome(caseID: c, taskID: task, outcome: .inconclusive, note: " ", actor: "Ada") }
        try await rig.f.file.recordFollowUpOutcome(caseID: c, taskID: task, outcome: .inconclusive, note: "The ledger shows both amounts", actor: "Ada")
        await #expect(throws: CaseReasoningError.followUpDecided) { try await rig.f.file.recordFollowUpOutcome(caseID: c, taskID: task, outcome: .accountAConfirmed, note: "x", actor: "Ada") }
        #expect(try await rig.f.file.conflictFollowUps(caseID: c).first?.outcome == .inconclusive)
        #expect(try await rig.item().status.latest == nil, "raising work decides nothing about the contradiction")
    }

    @Test("REASON-05: copies and derivative reports are one origin until reviewed independent; ten copies are not ten confirmations")
    func dependence() async throws {
        let base = "The warehouse ledger shows that bag 7 was received sealed at the evidence room on the morning of 3 March and signed by the duty officer."
        let ten = (0..<10).map { (row: UUID(), source: UUID(), text: base + ($0 == 0 ? "" : " Copy \($0).")) }
        let one = CaseSupportOrigins.compute(rows: ten, reviews: [])
        #expect(one.origins == 1 && one.documents == 10 && one.joinedUnreviewed.count == 45)
        #expect(one.line.contains("not whether any of them is true"))
        let f = try await CaseFileTests.fixture()
        let c = f.caseID
        let a = try await f.file.addAllegation(caseID: c, text: "Bag 7 was tampered with", actor: "Ada")
        let r1 = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: c, name: "report-1.txt", text: base)
        let r2 = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: c, name: "report-2.txt", text: base)
        let r3 = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: c, name: "lab.txt", text: "The laboratory found the seal on bag 7 broken and re-glued with a different adhesive.")
        for (doc, q) in [(r1, base), (r2, base), (r3, "The laboratory found the seal on bag 7 broken and re-glued with a different adhesive.")] {
            let l = try await f.svc.linkEvidence(caseID: c, allegationID: a, evidenceRef: doc.version.uuidString, label: nil, stance: .supports, note: nil,
                                                 passage: StudioEvidenceRef(sourceVersionID: doc.version, quote: q), actor: "Ada")
            #expect(l.verification.support.isDocumentary)
        }
        var o = try await f.file.supportOrigins(caseID: c, allegationID: a)
        #expect(o.supportingRows == 3 && o.documents == 3 && o.origins == 2 && o.joinedUnreviewed.count == 1)
        let pair = try #require(o.joinedUnreviewed.first)
        #expect(pair.basis.contains("copied text"))
        try await f.file.reviewDependence(caseID: c, sourceA: pair.a, sourceB: pair.b, judgment: .independent, detectedBasis: pair.basis,
                                          rationale: "Two officers wrote these independently on the same form", actor: "Ada")
        o = try await f.file.supportOrigins(caseID: c, allegationID: a)
        #expect(o.origins == 3 && o.reviewedIndependent == 1 && o.joinedUnreviewed.isEmpty)
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_source_dependence_reviews SET judgment = 'dependent';", []) }
    }

    @Test("REASON-08: an unassessed cell cannot make a hypothesis 'leading'; ties, coverage and contrary evidence are kept")
    func achNotSettled() {
        var a = ACHAnalysis(title: "x", now: Date(timeIntervalSince1970: 0))
        let h1 = ACHHypothesis(text: "H1"), h2 = ACHHypothesis(text: "H2")
        a.hypotheses = [h1, h2]
        let e1 = ACHEvidence(text: "Debit on 3 March"), e2 = ACHEvidence(text: "Courier log")
        a.evidence = [e1, e2]
        a.ratings[ACHAnalysis.key(e1.id, h1.id)] = .consistent
        a.ratings[ACHAnalysis.key(e1.id, h2.id)] = .veryInconsistent
        a.ratings[ACHAnalysis.key(e2.id, h2.id)] = .consistent     // e2 × h1 unrated
        guard case .notSettled(let hs, let unrated) = a.preference else { Issue.record("expected notSettled, got \(a.preference)"); return }
        #expect(hs.map(\.id) == [h1.id, h2.id] && unrated == 1 && a.leastInconsistent == nil)
        #expect(a.preferenceStatement.contains("no preference is established yet"))
        a.ratings[ACHAnalysis.key(e2.id, h1.id)] = .inconsistent
        #expect(a.leastInconsistent?.id == h1.id, "fully rated: h1 1 point against 2 — the rating, not a gap, decides it")
        a.ratings[ACHAnalysis.key(e2.id, h1.id)] = .consistent
        #expect(a.leastInconsistent?.id == h1.id)
        #expect(a.contraryEvidence(h2).map(\.id) == [e1.id])
        #expect(a.preferenceStatement.contains("not a probability or a finding"))
    }

    @Test("REASON-11: detection scored against a hand-written key, reported apart from human disposition")
    func scoring() {
        func doc(_ t: String) -> CaseContradictionFinder.Document { CaseContradictionFinder.Document(objectID: UUID(), sourceVersionID: UUID(), text: t, fileName: nil) }
        let fixtures: [(name: String, expectedConflict: Bool, documents: [CaseContradictionFinder.Document])] = [
            ("equivalent amounts (₹50,000 / Rs. 50000)", false, [doc("Ravi Kumar paid Dalmia Traders ₹50,000 on 3 March 2024."), doc("Ravi Kumar paid Dalmia Traders Rs. 50000 on 3 March 2024.")]),
            ("two true payments in one document", false, [doc("Ravi Kumar paid Dalmia Traders ₹50,000 on 3 March 2024. Ravi Kumar paid Dalmia Traders ₹20,000 on 9 March 2024.")]),
            ("date ambiguity (03/04/2024 vs 3 April 2024)", false, [doc("The meeting was held on 03/04/2024."), doc("The meeting was held on 3 April 2024.")]),
            ("duplicated report", false, [doc("Ravi Kumar paid Dalmia Traders ₹50,000 on 3 March 2024."), doc("Ravi Kumar paid Dalmia Traders ₹50,000 on 3 March 2024.")]),
            ("denial", true, [doc("Ravi Kumar paid Dalmia Traders ₹50,000 on 3 March 2024."), doc("Ravi Kumar denied that he paid Dalmia Traders anything in March 2024.")]),
            ("source amendment", false, [doc("Ravi Kumar paid Dalmia Traders ₹50,000 on 3 March 2024."), doc("Correction: Ravi Kumar paid Dalmia Traders ₹45,000 on 3 March 2024, not ₹50,000.")]),
            ("different amounts", true, [doc("Ravi Kumar paid Dalmia Traders ₹50,000 on 3 March 2024."), doc("Ravi Kumar paid Dalmia Traders ₹80,000 on 3 March 2024.")]),
        ]
        let score = CaseConflictScore.score(fixtures, dispositions: [.confirmed, .explained, .explained, .proposed])
        #expect(score.cases.count == 7)
        #expect(score.truePositives + score.missed == 2 && score.falsePositives + score.trueNegatives == 5)
        #expect(score.dispositions[.explained] == 2 && score.dispositions[.confirmed] == 1)
        let text = score.lines.joined(separator: "\n")
        #expect(text.contains("Detection (the check against a hand-written key)") && text.contains("Human disposition (counted separately, not scored)"))
        print("S5 REASON-11 measured:\n" + text)
    }

    @Test("REASON-12: a rejected or deferred proposal of any kind is not offered again unchanged; a changed one is, with the change named")
    func proposals() async throws {
        let f = try await CaseFileTests.fixture()
        let c = f.caseID
        let v0 = try await f.file.proposalVerdict(caseID: c, kind: .fact, key: "fact:payment:1", content: "Ravi paid ₹50,000 on 3 March")
        #expect(v0.offer && v0.reason == "Not decided before.")
        await #expect(throws: (any Error).self) {
            _ = try await f.file.recordProposalDecision(caseID: c, kind: .fact, key: "fact:payment:1", content: "Ravi paid ₹50,000 on 3 March", decision: .rejected, reason: " ", actor: "Ada")
        }
        try await f.file.recordProposalDecision(caseID: c, kind: .fact, key: "fact:payment:1", content: "Ravi paid ₹50,000 on 3 March", decision: .rejected, reason: "Duplicate of the bank row", actor: "Ada")
        let same = try await f.file.proposalVerdict(caseID: c, kind: .fact, key: "fact:payment:1", content: "Ravi paid ₹50,000 on 3 March")
        #expect(!same.offer && same.reason.contains("not offered again"))
        let changed = try await f.file.proposalVerdict(caseID: c, kind: .fact, key: "fact:payment:1", content: "Ravi paid ₹55,000 on 3 March")
        #expect(changed.offer && changed.reason.contains("changed since it was rejected") && changed.reason.contains("₹55,000"))
        try await f.file.recordProposalDecision(caseID: c, kind: .gap, key: "gap:march", content: "No statement for March", decision: .deferred, reason: "Asked the bank", actor: "Ada")
        #expect(try await !f.file.proposalVerdict(caseID: c, kind: .gap, key: "gap:march", content: "No statement for March").offer)
        #expect(try await f.file.proposalVerdict(caseID: c, kind: .link, key: "gap:march", content: "No statement for March").offer, "kinds are kept apart")
    }
}

// MARK: - TIME

@MainActor
@Suite("Smart map S5 — time (TIME)", .serialized)
struct SmartMapS5TimeTests {
    static let ist = TimeZone(identifier: "Asia/Kolkata") ?? .current
    static func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        var c = Calendar(identifier: .gregorian); c.timeZone = ist
        return c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min)) ?? Date()
    }

    @Test("TIME-01 / TIME-03: typed times stay apart by kind; competing source times stay as they are while an interpretation records its choice")
    func typedAndCompeting() async throws {
        let f = try await CaseFileTests.fixture()
        let c = f.caseID
        let doc = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: c, name: "log.txt", text: "Bag 7 arrived on 3 March 2024.")
        let j = try await f.file.addJournal(caseID: c, kind: .chronology, text: "Bag 7 arrives at the evidence room", eventDate: Self.day(2024, 3, 3),
                                            evidenceRef: nil, datePrecision: .day, actor: "Ada")
        let rid = j.uuidString
        let a1 = try await f.file.recordTime(caseID: c, recordKind: "journal", recordID: rid, kind: .occurrence,
                                             value: CaseTimeValue(start: Self.day(2024, 3, 3), precision: .day, timeZoneID: "Asia/Kolkata", originalText: "3 March"),
                                             assertor: .source, sourceVersionID: doc.version, locator: "line 1", actor: "Ada")
        let a2 = try await f.file.recordTime(caseID: c, recordKind: "journal", recordID: rid, kind: .occurrence,
                                             value: CaseTimeValue(start: Self.day(2024, 3, 4), precision: .day, originalText: "the 4th"),
                                             assertor: .source, assertedBy: "Courier Ravi", actor: "Ada")
        _ = try await f.file.recordTime(caseID: c, recordKind: "journal", recordID: rid, kind: .collection,
                                        value: CaseTimeValue(start: Self.day(2024, 3, 2, 18, 30), precision: .minute, timeZoneID: "Asia/Kolkata"),
                                        assertor: .investigator, actor: "Ada")
        var times = try await f.file.times(caseID: c, recordKind: "journal", recordID: rid)
        #expect(times.assertions(.occurrence).count == 3, "two source times + the entry's own date (derived)")
        #expect(times.assertions(.collection).count == 1 && times.assertions(.receipt).isEmpty)
        #expect(times.assertions.contains { $0.derived && $0.kind == .occurrence && $0.assertor == .investigator })
        #expect(times.competing == [.occurrence])
        // Validation of values.
        await #expect(throws: CaseTimeError.unknownMustHaveNoValue) {
            _ = try await f.file.recordTime(caseID: c, recordKind: "journal", recordID: rid, kind: .signing,
                                            value: CaseTimeValue(start: Date(), precision: .unknown, qualifier: .unknown), assertor: .investigator, actor: "Ada")
        }
        await #expect(throws: CaseTimeError.sourceNeedsReference) {
            _ = try await f.file.recordTime(caseID: c, recordKind: "journal", recordID: rid, kind: .signing,
                                            value: CaseTimeValue(start: Date(), precision: .day), assertor: .source, actor: "Ada")
        }
        await #expect(throws: CaseTimeError.relativeNeedsWording) {
            _ = try await f.file.recordTime(caseID: c, recordKind: "journal", recordID: rid, kind: .signing,
                                            value: CaseTimeValue(start: nil, precision: .unknown, qualifier: .relative), assertor: .investigator, actor: "Ada")
        }
        _ = try await f.file.recordTime(caseID: c, recordKind: "journal", recordID: rid, kind: .signing,
                                        value: CaseTimeValue(start: nil, precision: .unknown, qualifier: .relative, relativeText: "two days after the meeting"),
                                        assertor: .investigator, actor: "Ada")
        // Interpretation: a decision, not an overwrite.
        await #expect(throws: CaseTimeError.nothingConsidered) {
            _ = try await f.file.interpretTime(caseID: c, recordKind: "journal", recordID: rid, kind: .occurrence, choosing: a1, value: nil, considered: [], rationale: "log", actor: "Ada")
        }
        _ = try await f.file.interpretTime(caseID: c, recordKind: "journal", recordID: rid, kind: .occurrence, choosing: a1, value: nil, considered: [a1, a2],
                                           rationale: "The log is contemporaneous", actor: "Ada")
        times = try await f.file.times(caseID: c, recordKind: "journal", recordID: rid)
        #expect(times.competing.isEmpty && times.interpretation(.occurrence)?.chosenAssertionID == a1)
        #expect(times.assertions(.occurrence).filter { !$0.derived }.map(\.id) == [a1, a2], "both source times are kept as they were")
        _ = try await f.file.interpretTime(caseID: c, recordKind: "journal", recordID: rid, kind: .occurrence, choosing: a2, value: nil, considered: [a1, a2],
                                           rationale: "The courier's receipt is signed", actor: "Ben")
        times = try await f.file.times(caseID: c, recordKind: "journal", recordID: rid)
        #expect(times.interpretations.count == 2 && times.interpretations.filter(\.isActive).map(\.chosenAssertionID) == [a2])
        // An interpretation cannot adopt another record's assertion.
        await #expect(throws: CaseTimeError.assertionNotForRecord) {
            _ = try await f.file.interpretTime(caseID: c, recordKind: "journal", recordID: UUID().uuidString, kind: .occurrence, choosing: a1, value: nil,
                                               considered: [a1], rationale: "x", actor: "Ada")
        }
        // The app's own import time of a document is a separate kind.
        let imp = try await f.file.times(caseID: c, recordKind: "document", recordID: doc.version.uuidString)
        #expect(imp.assertions(.import).count == 1 && imp.assertions(.occurrence).isEmpty)
    }

    @Test("TIME-02: ranges, approximate and bounded dates and time zones are stored and shown at their own precision in the journal, the map and the report")
    func precisionEverywhere() async throws {
        let f = try await CaseFileTests.fixture()
        let c = f.caseID
        _ = try await f.file.addJournal(caseID: c, kind: .chronology, text: "Seal broken", eventDate: Self.day(2024, 3, 3), evidenceRef: nil,
                                        datePrecision: .day, dateEnd: Self.day(2024, 3, 5), timeZoneID: "Asia/Kolkata", actor: "Ada")
        _ = try await f.file.addJournal(caseID: c, kind: .chronology, text: "Courier hired", eventDate: Self.day(2024, 2, 1), evidenceRef: nil,
                                        datePrecision: .month, dateText: "early in the year", dateQualifier: .approximate, actor: "Ada")
        _ = try await f.file.addJournal(caseID: c, kind: .chronology, text: "Call to the depot", eventDate: Self.day(2024, 3, 3, 9, 30), evidenceRef: nil,
                                        datePrecision: .minute, timeZoneID: "Asia/Kolkata", actor: "Ada")
        await #expect(throws: CaseTimeError.endBeforeStart) {
            _ = try await f.file.addJournal(caseID: c, kind: .chronology, text: "x", eventDate: Self.day(2024, 3, 5), evidenceRef: nil, dateEnd: Self.day(2024, 3, 3), actor: "Ada")
        }
        let j = try await f.file.journal(caseID: c, kind: .chronology)
        let seal = try #require(j.first { $0.text == "Seal broken" })
        #expect(seal.dateQualifier == .between && seal.dateTimeZone == "Asia/Kolkata")
        #expect(seal.dateLabel == "between 3 Mar 2024 and 5 Mar 2024", "a day range never gets a time")
        let hired = try #require(j.first { $0.text == "Courier hired" })
        #expect(hired.timeValue?.label(assuming: Self.ist) == "approximately February 2024 — “early in the year”")
        #expect(try #require(j.first { $0.text == "Call to the depot" }).dateLabel == "3 Mar 2024 09:30 Asia/Kolkata")
        // The map carries the same.
        let p = try #require(await CaseMapService(sources: caseMapSources(f)).load(caseID: c, generation: 1).projection)
        #expect(p.nodes.first { $0.wording == "Seal broken" }?.dateLabel == "between 3 Mar 2024 and 5 Mar 2024")
        // The report prints it at its precision, with what the order does not establish.
        let snap = try #require(try await f.svc.snapshot(caseID: c, custody: []))
        let report = CaseFileDocuments.caseFileReport(snap, by: "Ada")
        #expect(report.contains("between 3 Mar 2024 and 5 Mar 2024: Seal broken"))
        #expect(report.contains("approximately February 2024"))
        #expect(report.contains("Order cannot be determined from the recorded dates between"))
        #expect(report.contains("not evidence of the sequence"))
    }

    @Test("TIME-05: overlapping or same-day entries are marked undetermined; unknown and relative ones are not placed; the zone assumption is stated")
    func chronologyOrder() {
        let tz = Self.ist
        let items = [
            CaseChronologyItem(id: "a", title: "Call A", time: CaseTimeValue(start: Self.day(2024, 3, 3, 9, 0), precision: .minute, timeZoneID: "Asia/Kolkata")),
            CaseChronologyItem(id: "b", title: "Meeting", time: CaseTimeValue(start: Self.day(2024, 3, 3), precision: .day)),
            CaseChronologyItem(id: "c", title: "Payment", time: CaseTimeValue(start: Self.day(2024, 3, 5), precision: .day)),
            CaseChronologyItem(id: "d", title: "Rumour", time: .unknown),
            CaseChronologyItem(id: "e", title: "Follow-up", time: CaseTimeValue(start: nil, precision: .unknown, qualifier: .relative, relativeText: "after the meeting")),
            CaseChronologyItem(id: "f", title: "Before hearing", time: CaseTimeValue(start: Self.day(2024, 3, 10), precision: .day, qualifier: .notAfter)),
        ]
        let arr = CaseChronologyOrder.arrange(items, assuming: tz)
        #expect(arr.unplaced.map(\.id).sorted() == ["d", "e"])
        let groupOf: (String) -> Int? = { id in arr.groups.firstIndex { $0.contains { $0.id == id } } }
        #expect(groupOf("a") == groupOf("b"), "a time on the 3rd and the day of the 3rd cannot be ordered")
        #expect(groupOf("f") == groupOf("a"), "“not after 10 March” overlaps everything before it")
        #expect(arr.timeZoneNote.contains("Asia/Kolkata"))
        #expect(arr.notes.contains { $0.contains("not evidence of the sequence") })
        let separate = CaseChronologyOrder.arrange([items[1], items[2]], assuming: tz)
        #expect(separate.groups.count == 2 && separate.undetermined.isEmpty)
    }

    @Test("TIME-04: a record's timeline holds its event times and work history (assignments, saved views); the case timeline is their union by the same ids; view history does not move the map fence")
    func timelines() async throws {
        let f = try await CaseFileTests.fixture()
        let c = f.caseID
        let j = try await f.file.addJournal(caseID: c, kind: .chronology, text: "Bag 7 arrives", eventDate: Self.day(2024, 3, 3), evidenceRef: nil, datePrecision: .day, actor: "Ada")
        _ = try await f.file.recordTime(caseID: c, recordKind: "journal", recordID: j.uuidString, kind: .receipt,
                                        value: CaseTimeValue(start: Self.day(2024, 3, 4), precision: .day), assertor: .investigator, actor: "Ada")
        let task = try await f.svc.createAction(caseID: c, .init(title: "Check the seal", purpose: "Seal", deliverable: "Photo"), actor: "Ada")
        try await f.file.reassignTask(caseID: c, taskID: task, to: "Ben", reason: "Ada is away", actor: "Ada")
        try await f.file.reassignTask(caseID: c, taskID: task, to: "Chitra", reason: nil, actor: "Ben")
        let taskLine = try await f.file.timeline(caseID: c, recordKind: "task", recordID: task.uuidString)
        #expect(taskLine.filter { $0.text.hasPrefix("taskAssigned") }.count == 2 && taskLine.allSatisfy { $0.lane == .work && $0.eventTime == nil })
        let assigned = try await f.file.times(caseID: c, recordKind: "task", recordID: task.uuidString).assertions(.assignment)
        #expect(assigned.count == 2 && assigned.map(\.assertedBy) == ["Ada", "Ben"])
        let revs = try await CaseRecordRevisions.revisions(f.db, caseID: c, kind: "task")
        #expect(revs.last?.value("owner").before == "Ben" && revs.last?.value("owner").after == "Chitra")
        let journalLine = try await f.file.timeline(caseID: c, recordKind: "journal", recordID: j.uuidString)
        #expect(journalLine.contains { $0.lane == .event && $0.eventTime?.precision == .day && $0.recordedAt > Self.day(2024, 3, 4) })
        // Saved views: history kept, map fence unchanged.
        let repo = CaseMapRepository(database: f.db)
        let fence = try await repo.revisionFence(caseID: c)
        let v = try await repo.saveView(caseID: c, name: "Witnesses", base: .people, filter: CaseMapFilter(), actor: "Ada")
        _ = try await repo.saveView(caseID: c, id: v, name: "Witnesses (all)", base: .people, filter: CaseMapFilter(), actor: "Ben")
        try await repo.deleteView(caseID: c, id: v, actor: "Ben")
        #expect(try await repo.revisionFence(caseID: c) == fence)
        let viewRevs = try await CaseRecordRevisions.revisions(f.db, caseID: c, kind: "mapView")
        #expect(viewRevs.map(\.change) == ["mapViewSaved", "mapViewChanged", "mapViewRemoved"] && viewRevs.last?.after == nil)
        // The case timeline is the union of the records' timelines — the same entries.
        let all = Set(try await f.file.caseTimeline(caseID: c).map(\.id))
        #expect(Set(taskLine.map(\.id)).isSubset(of: all) && Set(journalLine.map(\.id)).isSubset(of: all))
        let viewLine = try await f.file.timeline(caseID: c, recordKind: "mapView", recordID: v.uuidString)
        #expect(viewLine.count == 3 && Set(viewLine.map(\.id)).isSubset(of: all))
    }

    @Test("TIME-06 / TIME-08: attribution parts are kept apart and sealed; this device's sequence orders actions; a clock running backwards is marked, never trusted")
    func attributionAndOrder() async throws {
        let f = try await CaseFileTests.fixture()
        let c = f.caseID
        let t0 = Date(timeIntervalSince1970: 2_000_000_000)
        _ = try await f.file.addAllegation(caseID: c, text: "First", actor: "Ada", at: t0)
        try await CaseActionContext.$current.withValue(CaseActionContext(performedBy: "Field officer Rao", softwareActor: "intake rule v1", trigger: "report imported")) {
            _ = try await f.file.addAllegation(caseID: c, text: "Second", actor: "Ada", at: t0.addingTimeInterval(-3_600))   // the clock went back
        }
        let acts = try await f.file.actions(caseID: c)
        let second = try #require(acts.last)
        #expect(second.actor == "Ada" && second.performedBy == "Field officer Rao" && second.softwareActor == "intake rule v1" && second.trigger == "report imported")
        #expect(second.sessionAccount == NSUserName() && second.attributionLine.contains("not an identity check"))
        let device = try await f.file.recordingDeviceID()
        #expect(device != nil && acts.allSatisfy { $0.deviceID == device })
        let seqs = acts.compactMap(\.deviceSeq)
        #expect(seqs == seqs.sorted() && Set(seqs).count == seqs.count)
        let ordered = CaseAuditOrdering.arrange(acts, device: device)
        #expect(ordered.last?.action.id == second.id && ordered.last?.clockOutOfOrder == true)
        #expect(CaseAuditOrdering.statement.contains("not verified"))
        // Renaming a profile later does not rewrite the recorded name; an action from before sequencing is marked.
        #expect(try await f.file.actions(caseID: c).map(\.actor) == acts.map(\.actor))
        var legacy = acts[0]; legacy.deviceID = nil; legacy.deviceSeq = nil
        #expect(CaseAuditOrdering.arrange([legacy], device: device).first?.outsideDeviceOrder == true)
        // The new parts are sealed.
        try await f.db.exec("INSERT OR IGNORE INTO case_action_seal_boundaries (id, sealed_from_at, legacy_action_count, created_at) VALUES ('t', 0, 0, 0);", [])
        let events = try await f.file.auditChainEvents()
        let ev = try #require(events.first { $0.eventID == second.id })
        #expect(ev.canonicalPayload.contains("performedBy=Field officer Rao") && ev.canonicalPayload.contains("deviceSeq="))
    }

    @Test("TIME-07: map links, review decisions and outputs are sealed; a changed output breaks the chain; the result names its trust limits")
    func auditCoverage() async throws {
        let rig = try await ConflictRig.make()
        let f = rig.f, c = f.caseID
        try await rig.desk.reviewContradiction(caseID: c, contradictionID: rig.id, decision: .confirmed, reason: nil, note: nil, actor: "Ada", at: Date())
        let a = try await f.file.addAllegation(caseID: c, text: "Q", actor: "Ada")
        let p = try await f.file.addPerson(caseID: c, name: "Ravi", role: .witness, entityID: nil, contact: nil, notes: nil, actor: "Ada")
        _ = try await CaseMapRepository(database: f.db).addLink(caseID: c, type: .qualifies,
                                                               from: CaseMapNodeID(caseID: c, kind: .person, recordID: p.uuidString.lowercased()),
                                                               to: CaseMapNodeID(caseID: c, kind: .allegation, recordID: a.uuidString.lowercased()),
                                                               rationale: "His account limits it", actor: "Ada")
        let out = UUID()
        try await f.db.exec("INSERT INTO case_document_outputs (id, case_id, kind, route, snapshot_sha256, status, released_by, released_at) VALUES (?,?,?,?,?,?,?,?);",
                            [.uuid(out), .uuid(c), .text("caseReport"), .text("file"), .text(String(repeating: "a", count: 64)), .text("written"), .text("Ada"), .real(5)])
        let db = f.db
        let chain = AuditChainService(database: db, secret: Data(repeating: 7, count: 32), eventProvider: { try await CaseAuditSources.events(db) })
        let sealed = try await chain.seal()
        #expect(sealed == 3)
        let ok = try await chain.verify()
        #expect(ok.isIntact && ok.statusLine.contains("No change detected in 3 sealed events") && ok.statusLine.contains("not tamper-proof"))
        #expect(ok.statusLine.contains("Keychain") && !ok.statusLine.contains("none altered"))
        try await db.exec("UPDATE case_document_outputs SET status = 'released' WHERE id = ?;", [.uuid(out)])
        let broken = try await chain.verify()
        #expect(!broken.isIntact && broken.statusLine.hasPrefix("BROKEN"))
    }

    @Test("TIME-10: a recorded state opened today withholds sources no longer in the case; history detail is shown with today's protected names removed")
    func historyAccess() async throws {
        let f = try await CaseFileTests.fixture()
        let c = f.caseID
        let a = try await f.file.addAllegation(caseID: c, text: "Bag 7 was tampered with", actor: "Ada")
        let doc = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: c, name: "lab.txt", text: "The seal on bag 7 was broken.")
        _ = try await f.svc.linkEvidence(caseID: c, allegationID: a, evidenceRef: doc.version.uuidString, label: "Lab", stance: .supports, note: nil,
                                         passage: StudioEvidenceRef(sourceVersionID: doc.version, quote: "The seal on bag 7 was broken."), actor: "Ada")
        let history = CaseHistoryService(database: f.db, map: CaseMapService(sources: caseMapSources(f)))
        let cp = try await history.record(caseID: c, kind: .manual, actor: "Ada")
        #expect(try await history.open(id: cp.id, caseID: c).restrictedVersions.isEmpty)
        let header = try #require(try await f.cases.fetch(caseID: c)?.caseHeader)
        _ = try await f.cases.excludeSource(caseID: c, expectedRevision: header.revision, sourceRef: doc.version.uuidString, sourceKind: .sourceVersion,
                                            note: "Privileged", actor: "Ada", at: Date())
        let view = try await history.open(id: cp.id, caseID: c)
        #expect(view.restrictedVersions == [doc.version] && view.accessNote?.contains("withheld") == true)
        #expect(CaseHistoryAccess.visibleDetail("Interviewed Meena Shah about the seal", protectedNames: ["Meena Shah"])?.contains("Meena Shah") == false)
        #expect(CaseHistoryAccess.visibleDetail("No names", protectedNames: []) == "No names")
    }

    @Test("v180 → v181: rebuilt tables keep their rows and guards, wider CHECKs admit the new values, new tables are registered")
    func migration() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 180)
        let c = UUID(), l = UUID(), d = UUID()
        try await db.exec("INSERT INTO case_map_links (id, case_id, link_type, from_kind, from_id, to_kind, to_id, rationale, created_by, created_at, certainty) VALUES (?,?,?,?,?,?,?,?,?,?,?);",
                          [.uuid(l), .uuid(c), .text("supports"), .text("case"), .text("a"), .text("allegation"), .text("b"), .text("r"), .text("Ada"), .real(1), .text("possible")])
        try await db.exec("INSERT INTO investigation_review_decisions (id, case_id, item_kind, item_id, decision, actor, decided_at) VALUES (?,?,?,?,?,?,?);",
                          [.uuid(d), .uuid(c), .text("contradiction"), .text("x"), .text("confirmed"), .text("Ada"), .real(1)])
        try await db.exec("INSERT INTO audit_chain (seq, source, event_id, occurred_at, payload_hash, prev_hash, entry_hash, sealed_at) VALUES (1,'caseAction',?,1,'p','g','e',1);", [.uuid(UUID())])
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
        #expect(try await db.query("SELECT certainty FROM case_map_links WHERE id = ?;", [.uuid(l)]).first?.string(0) == "possible")
        #expect(try await db.query("SELECT decision FROM investigation_review_decisions WHERE id = ?;", [.uuid(d)]).first?.string(0) == "confirmed")
        #expect(try await db.query("SELECT entry_hash FROM audit_chain WHERE seq = 1;").first?.string(0) == "e")
        await #expect(throws: (any Error).self) { try await db.exec("UPDATE case_map_links SET rationale = 'x' WHERE id = ?;", [.uuid(l)]) }
        await #expect(throws: (any Error).self) { try await db.exec("UPDATE investigation_review_decisions SET decision = 'dismissed';", []) }
        try await db.exec("INSERT INTO case_map_links (id, case_id, link_type, from_kind, from_id, to_kind, to_id, rationale, created_by, created_at) VALUES (?,?,?,?,?,?,?,?,?,?);",
                          [.uuid(UUID()), .uuid(c), .text("qualifies"), .text("case"), .text("a"), .text("allegation"), .text("b"), .text("r"), .text("Ada"), .real(1)])
        await #expect(throws: (any Error).self, "an explanation needs its note") {
            try await db.exec("INSERT INTO investigation_review_decisions (id, case_id, item_kind, item_id, decision, actor, decided_at) VALUES (?,?,?,?,?,?,?);",
                              [.uuid(UUID()), .uuid(c), .text("contradiction"), .text("x"), .text("explained"), .text("Ada"), .real(2)])
        }
        try await db.exec("INSERT INTO audit_chain (seq, source, event_id, occurred_at, payload_hash, prev_hash, entry_hash, sealed_at) VALUES (2,'mapLink',?,1,'p','e','f',1);", [.uuid(UUID())])
        for t in ["case_assertion_attributions", "case_source_dependence_reviews", "case_conflict_followups", "case_decision_inputs", "case_proposal_decisions",
                  "case_time_assertions", "case_time_interpretations"] {
            #expect(try await MigrationFixtureBuilder.tableExists(db, t), "\(t) missing")
            #expect(CaseDataInventory.entry(t)?.lifecycle == .caseID, "\(t) not registered")
        }
        #expect(try await MigrationFaultHarness.integrityOK(db))
        #expect(try await db.withSavepoint("inv") { d in try CaseDataInventory.unregistered(d) }.isEmpty)
    }
}
