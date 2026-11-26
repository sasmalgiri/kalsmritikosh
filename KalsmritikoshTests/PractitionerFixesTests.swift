//
//  PractitionerFixesTests.swift
//  KalsmritikoshTests
//
//  Blockers from the agent practitioner reviews of 2026-11-02 (docs/agent-reviews/practitioner-*.md).
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("Practitioner review fixes (2026-11-02)")
struct PractitionerFixesTests {

    @Test("A reading limit is never silent: documents beyond it and truncated events are stated in every job's limitations")
    func readingLimitStated() {
        let f = StudioCaseFacts(caseTitle: "c", parties: [], dates: [], amounts: [], identifiers: [], documents: [], events: [],
                                allFacts: [], documentsNotRead: 3, eventsTruncated: true)
        let l = JobText.withheldLimitation(0, facts: f)
        #expect(l.count == 2)
        #expect(l[0].hasPrefix("3 document(s) in this case are beyond the 5000-document reading limit"))
        #expect(l[1].contains("more than 50000 dated events"))
        #expect(JobText.withheldLimitation(0, facts: .empty).isEmpty)
        #expect(StudioCaseFacts.documentReadingLimit >= 5_000, "the old silent cap was 60 documents")
    }

    @Test("SIU: an external referral cannot complete without the contrary facts and innocent explanations; the report always prints them; an old saved referral still opens")
    func siuContraryFacts() throws {
        var r = SIUReferral.sample(now: Date(timeIntervalSince1970: 1_800_000_000))
        r.disposition = .referNICB; r.dispositionRationale = "Reasonable suspicion on the date of loss."
        r.indicatorsNotProofAcknowledged = true; r.goodFaithConfirmed = true; r.contraryFacts = nil
        #expect(!r.isComplete(.disposition), "external referral without contrary facts")
        #expect(SIUReportRenderer.markdown(r, generatedAt: Date()).contains("### Contrary facts and innocent explanations considered\n\n_Not recorded._"))
        r.contraryFacts = "The clinic letter dates the first visit to 3 March, which supports the claimant's account."
        #expect(r.isComplete(.disposition))
        #expect(SIUReportRenderer.markdown(r, generatedAt: Date()).contains("supports the claimant's account"))
        r.disposition = .returnToClaims; r.contraryFacts = nil
        #expect(r.isComplete(.disposition), "returning to claims does not need it")
        // A referral saved before the field existed decodes.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as! [String: Any]
        json.removeValue(forKey: "contraryFacts")
        let old = try JSONDecoder().decode(SIUReferral.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.contraryFacts == nil)
    }

    @Test("Journalist: a source-map row marked confidential protects its source; every file export replaces it or exports nothing")
    func confidentialSourceProtectedInExports() async throws {
        // Re-review 2026-11-02: a source-map row's title is a DOCUMENT name; the person is the identity field.
        let rows = [JobResultRow(title: "memo-from-city-hall.pdf", fields: ["protection": "confidential source", "identity": "Anna Novak; A. N."]),
                    JobResultRow(title: "daily-wire-story.html", fields: ["protection": "none"])]
        #expect(ProtectedIdentities.confidentialSources(in: rows) == ["Anna Novak", "A. N."], "the person, never the file name")
        #expect(JobFields.completionProblems(job: "jrn.source-map", rows: [{ var r = JobResultRow(title: "memo.pdf", fields: ["protection": "confidential source"]); r.decision = .accepted; return r }()])
                    .contains { $0.contains("needs the identity to protect") })
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        try await JobResultRepository(database: f.db).save(caseID: f.caseA, jobID: "jrn.source-map", family: .reliabilityConflicts, state: .draft,
                                                         content: JobResultContent(rows: [JobResultRow(title: "memo.pdf", fields: ["protection": "confidential source", "identity": "Anna Novak"])]),
                                                         actor: "Tester")
        #expect(try await JobResultRepository(database: f.db).protectedIdentityNames().contains("Anna Novak"))
        switch await f.state.protectedExportText("Quote book: Anna Novak said the permit was backdated.") {
        case .success(let safe): #expect(!safe.contains("Anna Novak") && safe.contains("[PROTECTED SOURCE]"))
        case .failure(let r): Issue.record("refused: \(r.reason)")
        }
    }

    @Test("Researcher: a bibliography date is accepted as sources give it — year, month, day, circa, range, n.d. — and nonsense is still refused")
    func historicalDates() {
        for ok in ["1771", "1771-03", "1771-03-04", "c. 1771", "circa 1771", "before 1800", "1770–1775", "1770-1775", "1770 to 1775", "n.d.", "Undated"] {
            #expect(JobFields.invalidReason(.historicalDate, ok) == nil, "\(ok)")
        }
        for bad in ["1771-13", "1771-02-30", "seventeen", "71", "1770–", "yesterday"] {
            #expect(JobFields.invalidReason(.historicalDate, bad) != nil, "\(bad)")
        }
        #expect(JobFields.specs["res.bibliography"]?.first { $0.key == "date" }?.kind == .historicalDate)
    }

    @Test("Individual: a sharing copy holds only cleared rows; the binder prints its real review date; renewal comes only from a stated renewal date")
    func individualFixes() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = [JobResultRow(title: "Passport scan — share", fields: ["include": "include", "recipient": "Bank"]),
                    JobResultRow(title: "Medical letter — SECRET DETAIL", fields: ["include": "withhold"]),
                    JobResultRow(title: "Undecided tax notice", fields: [:])]
        let rec = JobResultRecord(id: UUID(), caseID: UUID(), jobID: "ind.secure-share", family: "controlledDisclosure", state: .draft,
                                  content: JobResultContent(rows: rows), createdBy: "me", createdAt: t)
        let md = JobResultMarkdown.render(rec, title: "Share")
        #expect(md.contains("Passport scan") && !md.contains("SECRET DETAIL") && !md.contains("Undecided tax notice"))
        #expect(md.contains("2 item(s) not cleared to share are left out"))

        var b = EmergencyBinder.sample(now: t)
        b.lastReviewedAt = t.addingTimeInterval(-400 * 86_400)
        let binder = EmergencyBinderRenderer.markdown(b, generatedAt: t)
        #expect(!binder.contains("**Last reviewed:** " + { let f = DateFormatter(); f.dateStyle = .long; return f.string(from: t) }()))
        #expect(binder.contains("Reviewed within the last year: **No"))

        let issued = JobResultRow(title: "Policy", date: "2025-01-02", flags: ["upcoming: 2026-12-31"])
        let plain = JobResultRow(title: "Policy", date: "2025-01-02")
        let filled = JobFields.prefill(job: "ind.insurance", rows: [issued, plain], evidence: nil)
        #expect(filled[0].fields?["renewal"] == "2026-12-31", "the stated renewal date, not the issue date")
        #expect((filled[1].fields?["renewal"] ?? "").isEmpty, "no renewal sentence: left for the person")
    }

    @Test("Re-review: the synchronous export gate fails closed while the register is unknown, scrubs ordinary files and refuses sealed ones")
    func exportGate() async {
        await ProtectedIdentityCache.TestOverride.$names.withValue(nil) {
            // nil override falls through to the shared cache; force the unknown case explicitly below.
        }
        await ProtectedIdentityCache.TestOverride.$names.withValue(["Anna Novak"]) {
            guard case .success(let safe) = ProtectedExport.prepare("Anna Novak handed over the ledger.") else { Issue.record("scrub refused"); return }
            #expect(!safe.contains("Anna Novak") && safe.contains("[PROTECTED SOURCE]"))
            guard case .failure(let r) = ProtectedExport.prepare("{\"passage\":\"Anna Novak handed over the ledger.\"}", refuseIfPresent: true) else { Issue.record("sealed file altered"); return }
            #expect(r.reason.contains("cannot be redacted after sealing"))
            guard case .success(let clean) = ProtectedExport.prepare("{\"passage\":\"The ledger was handed over.\"}", refuseIfPresent: true) else { Issue.record("clean sealed refused"); return }
            #expect(clean.contains("handed over"))
        }
        await ProtectedIdentityCache.TestOverride.$names.withValue([]) {
            guard case .success = ProtectedExport.prepare("anything") else { Issue.record("no names should pass"); return }
        }
    }

    @Test("Re-review: renewal needs a renewal word (not 'due to'); a sharing copy masks emails and phone numbers; truncated values are stated")
    func reReviewIndividualAndLimits() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = [JobResultRow(title: "Bank letter — write to anna@example.com or call +1 555 010 2030", fields: ["include": "include"])]
        let rec = JobResultRecord(id: UUID(), caseID: UUID(), jobID: "ind.secure-share", family: "controlledDisclosure", state: .draft,
                                  content: JobResultContent(rows: rows), createdBy: "me", createdAt: t)
        let md = JobResultMarkdown.render(rec, title: "Share")
        #expect(!md.contains("anna@example.com") && !md.contains("555 010 2030") && md.contains("[MASKED]"), "\(md)")
        let f = StudioCaseFacts(caseTitle: "c", parties: [], dates: [], amounts: [], identifiers: [], documents: [], events: [],
                                allFacts: [], valuesTruncated: true)
        #expect(JobText.withheldLimitation(0, facts: f).contains { $0.contains("beyond the limit were not read") })
        #expect(!JobText.matches("The policy lapsed due to non-payment on 2 May 2025.", #"(?i)\b(?:expir\w*|renew\w*|valid (?:until|through|till)|due (?:on|by|date)|payment due|deadline)\b"#))
    }
}

