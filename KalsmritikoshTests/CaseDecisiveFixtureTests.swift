//
//  CaseDecisiveFixtureTests.swift
//  KalsmritikoshTests
//
//  Case plan 2026-11-16 (QA-19, §E) — the decisive engineering fixture: a failed pharmaceutical-quality batch first put
//  down to the supplier. Two "independent" lab confirmations copied from one raw run, a namesake instrument (HPLC-12 beside
//  HPLC-2), a plausible material explanation, a calibration record placed beyond the first 400 documents, and a raw
//  instrument log that is overwritten on a recorded date. A designed fixture, not a completed investigation. AI off.
//
//  1. The review starts from the failed result with no contradiction; all 16 methods are accounted for; the two
//     confirmations count as ONE origin until a person reviews them.
//  2. The expiring log outranks a cheaper check; a duplicate proposal from another method is one check.
//  3. Search reaches the calibration record past the old 400 limit, and the exact search keeps the namesake out.
//  4. A specialist request is followed by hand: prepared, handed over, confirmed; a partial answer leaves it open.
//  5. The brief says the case is inconclusive on the available evidence.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@MainActor
@Suite("Decisive fixture — the failed batch first blamed on the supplier", .serialized)
struct CaseDecisiveFixtureTests {

    @Test("The five steps of plan §E, AI off")
    func decisiveFixture() async throws {
        let f = try await CaseFileTests.fixture(title: "Why did batch 42 fail the assay?")
        let c = f.caseID
        let rawRun = "Run R-77 on HPLC-2, 3 March 2026: batch 42 assay 71 percent of label claim, below the 95 percent limit. Analyst: P. Rao."
        let labA = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: c, name: "lab-confirmation-A.txt",
                                                             text: "Confirmation A. " + rawRun + " The result is confirmed.")
        let labB = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: c, name: "lab-confirmation-B.txt",
                                                             text: "Confirmation B (QA copy). " + rawRun + " The result is confirmed.")
        _ = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: c, name: "hplc-12-service.txt",
                                                      text: "Service note for HPLC-12 (stability laboratory): lamp replaced in February 2026.")
        _ = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: c, name: "supplier-coa.txt",
                                                      text: "Supplier certificate of analysis for lot 9911: assay 99.2 percent.")
        // Filler so the calibration record sits beyond the first 400 documents of the case.
        for i in 0..<400 {
            _ = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: c, name: String(format: "batch-record-%03d.txt", i),
                                                          text: "Batch record page \(i): routine weighing entries.")
        }
        _ = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: c, name: "zz-calibration-hplc2.txt",
                                                      text: "Calibration record HPLC-2: last calibrated 2 January 2026; next due 2 February 2026 (overdue).")

        // 1. From the failed result, no contradiction: the review, and the two confirmations as one origin.
        let question = try await f.file.addAllegation(caseID: c, text: "Batch 42 failed the assay because of the supplier's material", actor: "Ada")
        for (v, label) in [(labA.version, "Confirmation A"), (labB.version, "Confirmation B")] {
            _ = try await f.svc.linkEvidence(caseID: c, allegationID: question, evidenceRef: v.uuidString, label: label, stance: .supports, note: nil,
                                             passage: StudioEvidenceRef(sourceVersionID: v, quote: "batch 42 assay 71 percent of label claim"), actor: "Ada")
        }
        let origins = try await f.file.supportOrigins(caseID: c, allegationID: question)
        #expect(origins.supportingRows == 2 && origins.origins == 1, "two copies of one raw run are one origin until reviewed: \(origins.line)")
        let snapshot = try #require(try await f.svc.snapshot(caseID: c, custody: [CustodyManifestEntry(sourceVersionID: labA.version, contentHash: nil, custodyEvents: [])]))
        let review = CaseMethodReview.assess(methods: CaseMethodReviewMethod.registered,
                                             input: .from(question: "Why did batch 42 fail?", snapshot: snapshot, coverage: nil, openContradictions: 0,
                                                          money: nil, hypotheses: [], requests: [], runs: [], now: Date()))
        #expect(review.accountsFor(CaseMethodReviewMethod.registered) && review.shortlist.contains { $0.methodID.hasSuffix(".fishbone") })

        // 2. The expiring log first; one check for two methods asking for the same certificate.
        let analysis = InvestigationAnalysisRepository(database: f.db)
        let due = Date().addingTimeInterval(3 * 86_400)
        _ = try await analysis.createRequest(caseID: c, details: EvidenceRequestDetails(description: "Raw instrument log HPLC-2, March 2026",
                                                                                        custodian: "QC laboratory", dueAt: due), actor: "Ada", at: Date())
        let requests = try await analysis.requestFiles(caseID: c)
        var candidates = CaseCheckShortlist.candidates(requests: requests, awaitingContradictions: [], openExplanations: [])
        candidates += [
            CaseCheckCandidate(id: "m:fishbone", title: "Calibration certificate", observation: "Calibration certificate for HPLC-2", target: "QC laboratory", origin: .method, effortHours: 0.5),
            CaseCheckCandidate(id: "m:five-whys", title: "Certificate", observation: "calibration certificate — HPLC-2", target: "QC Laboratory", origin: .method),
        ]
        let checks = CaseCheckShortlist.rank(candidates)
        #expect(checks.first?.title.contains("Raw instrument log") == true, "\(checks.map(\.title))")
        #expect(checks.count == 2 && checks[1].mergedFrom.count == 2, "one check for the two proposals: \(checks.map(\.mergedFrom))")

        // 3. Search past the old limit, and the namesake kept out by an exact search.
        let search = CaseSearchService(sources: .live(database: f.db))
        let options = CaseSearchOptions(timeZoneID: "UTC")
        let calibration = try #require(await search.run(caseID: c, text: "calibration overdue", options: options).run)
        #expect(calibration.hits.map(\.name).contains("zz-calibration-hplc2.txt"), "\(calibration.hits.map(\.name))")
        let exact = try #require(await search.run(caseID: c, text: "exact:\"HPLC-2\"", options: options).run)
        #expect(!exact.hits.map(\.name).contains("hplc-12-service.txt"), "the namesake instrument is not HPLC-2: \(exact.hits.map(\.name))")
        var run = CaseContradictionRun(); run.documents = 400; run.documentsInCase = 405
        #expect(run.continuation == 400, "the contradiction check offers to continue past the first 400")

        // 4. A specialist request by hand: prepared, handed over, confirmed; a partial answer leaves it open.
        let auto = CaseAutomationService(database: f.db, caseFiles: f.svc, aiPermitted: { _ in false })
        let file = try #require(requests.first)
        let effect = try await auto.prepareRequestDelivery(caseID: c, request: file, channel: "email", text: "Please preserve the raw log.", actor: "Ada")
        try await auto.markHandedOver(caseID: c, effectID: effect.id, providerRef: "mail 42", actor: "Ada")
        try await auto.reconcileExternalEffect(caseID: c, effectID: effect.id, sent: true, note: "The laboratory acknowledged", actor: "Ada")
        let partial = try await analysis.setRequestStatus(requestID: file.request.id, expectedRevision: file.request.revision, to: .partial,
                                                          note: "Days 1–15 received; 16–31 still to come", actor: "Ada", at: Date())
        #expect(partial.status.isOutstanding, "a partial answer leaves the request open")

        // 5. The brief, honestly inconclusive.
        let p = try #require(await caseMapLoad(f).projection)
        #expect(CaseMapBrief.compute(p).outcome.hasPrefix("Inconclusive on the available evidence."))
    }
}
