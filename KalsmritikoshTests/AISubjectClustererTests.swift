//
//  AISubjectClustererTests.swift
//  KalsmritikoshTests
//
//  M2 — AI subject clustering: the model proposes groups, the deterministic guard
//  decides. Same-subject copies merge only when they share evidence terms; a
//  distinct subject the model wrongly grouped is NOT merged.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite struct AISubjectClustererTests {

    private func fact(_ subject: String, _ field: String, _ value: String) -> GenericFact {
        GenericFact(
            subjectLabel: subject, field: field, value: value,
            assessment: EvidenceAssessment(basis: .directlyObserved, review: .unreviewed, origin: .sourceExtraction),
            confidence: 0.8, sourceBlockIDs: [UUID()])
    }
    private func sf(_ subject: String, _ pairs: [(String, String)]) -> TopicConsolidator.SubjectFacts {
        TopicConsolidator.SubjectFacts(subject: subject, facts: pairs.map { fact(subject, $0.0, $0.1) })
    }

    @Test("Parser reads comma-number lines into 0-based, in-range, deduped groups")
    func parse() {
        let g = AISubjectClusterer.parseGroups("1, 3, 5\n2\n4, 4\nGroup 6: 1", count: 5)
        #expect(g[0] == [0, 2, 4])
        #expect(g[1] == [1])
        #expect(g[2] == [3])          // 4,4 → deduped to one
        #expect(g[3] == [0])          // "6" out of range dropped; "1" kept
    }

    @Test("Same-subject copies that share evidence terms MERGE into the largest")
    func mergesSharedSubject() async {
        // Three résumé copies (share role/employer terms) + one unrelated weather doc.
        let a = sf("RESUME_2", [("role","Senior Manager"),("employer","Pharma Ltd"),("date","2004")])
        let b = sf("RESUME copy", [("role","Senior Manager"),("employer","Pharma Ltd")])
        let c = sf("Resume final", [("role","Senior Manager"),("employer","Pharma Ltd"),("date","2004"),("phone","x")])
        let w = sf("Weather log", [("temperature","21C")])
        // Stub model groups the 3 resumes (1,2,3) and leaves weather (4) alone.
        let clusterer = AISubjectClusterer(reason: { _ in "1, 2, 3\n4" })
        let canon = await clusterer.canonicalize([a, b, c, w], minSharedTerms: 2)
        // Largest (c, 4 facts) is canonical; a + b fold into it; weather stands alone.
        #expect(canon["Resume final"] == "Resume final")
        #expect(canon["RESUME_2"] == "Resume final")
        #expect(canon["RESUME copy"] == "Resume final")
        #expect(canon["Weather log"] == "Weather log")
    }

    @Test("A wrongly-grouped distinct subject is NOT merged (guard rejects)")
    func guardRejectsUnsharedMerge() async {
        let patent = sf("Patent A", [("applicant","Acme"),("number","US-1"),("status","granted")])
        let lease  = sf("Lease B", [("landlord","Baker"),("tenant","Cain"),("rent","5000")])
        // Model hallucinates that 1 and 2 are the same subject.
        let clusterer = AISubjectClusterer(reason: { _ in "1, 2" })
        let canon = await clusterer.canonicalize([patent, lease], minSharedTerms: 3)
        // No shared evidence terms → guard refuses the merge; both stay themselves.
        #expect(canon["Patent A"] == "Patent A")
        #expect(canon["Lease B"] == "Lease B")
    }

    @Test("No model (nil) → identity mapping, nothing merges")
    func noModelIdentity() async {
        let a = sf("A", [("x","1")]); let b = sf("B", [("y","2")])
        let clusterer = AISubjectClusterer(reason: { _ in nil })
        let canon = await clusterer.canonicalize([a, b])
        #expect(canon["A"] == "A" && canon["B"] == "B")
    }
}
