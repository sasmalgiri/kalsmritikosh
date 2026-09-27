//
//  TopicConsolidatorTests.swift
//  KalsmritikoshTests
//
//  Owner rule (2026-09-19): topics must be FEW and evidence-backed. A subject
//  with too little context is not a real topic — it folds into its closest
//  substantive subject. These tests pin that behavior.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite struct TopicConsolidatorTests {

    private func fact(_ subject: String, _ field: String, _ value: String) -> GenericFact {
        GenericFact(
            subjectLabel: subject, field: field, value: value,
            assessment: EvidenceAssessment(basis: .directlyObserved, review: .unreviewed, origin: .sourceExtraction),
            confidence: 0.8, sourceBlockIDs: [UUID()])
    }

    private func subjectFacts(_ subject: String, _ pairs: [(String, String)]) -> TopicConsolidator.SubjectFacts {
        TopicConsolidator.SubjectFacts(subject: subject, facts: pairs.map { fact(subject, $0.0, $0.1) })
    }

    @Test("Thin subjects fold into the closest substantive subject — count shrinks")
    func thinFoldsIntoSubstantive() {
        // One rich subject about a patent, one thin fragment sharing its vocabulary.
        let rich = subjectFacts("Acme Patent Application", [
            ("applicant", "Acme Corporation"),
            ("application_number", "US-12345"),
            ("filing_date", "2023-04-01"),
            ("status", "granted"),
            ("examiner", "Jane Roe"),
        ])
        let thin = subjectFacts("Acme patent examiner note", [("note", "examiner queried Acme claim 3")])
        let unrelatedThin = subjectFacts("Weather log", [("temperature", "21C")])

        let out = TopicConsolidator.consolidate([rich, thin, unrelatedThin], minDistinctFacts: 4)

        // Only substantive subjects survive as topics.
        #expect(out.count == 1)
        #expect(out.first?.subject == "Acme Patent Application")
        // The thin fragment's fact was absorbed, not dropped.
        let values = out.first?.facts.map(\.value) ?? []
        #expect(values.contains("examiner queried Acme claim 3"))
        // And the unrelated thin fact is also preserved (folded into the only host).
        #expect(values.contains("21C"))
    }

    @Test("Multiple substantive subjects are all kept; thin routes to the closest by overlap")
    func routesToClosest() {
        let patent = subjectFacts("Patent Matter", [
            ("applicant", "Acme"), ("application_number", "US-1"),
            ("filing_date", "2023-01-01"), ("examiner", "Roe"),
        ])
        let lease = subjectFacts("Lease Agreement", [
            ("landlord", "Baker Estates"), ("tenant", "Acme"),
            ("rent", "5000"), ("term", "36 months"),
        ])
        // Shares vocabulary with the lease (landlord/rent), not the patent.
        let thinLease = subjectFacts("rent reminder", [("rent", "late rent notice to landlord Baker")])

        let out = TopicConsolidator.consolidate([patent, lease, thinLease], minDistinctFacts: 4)

        #expect(out.count == 2)
        let leaseTopic = out.first { $0.subject == "Lease Agreement" }
        #expect(leaseTopic?.facts.map(\.value).contains("late rent notice to landlord Baker") == true)
        let patentTopic = out.first { $0.subject == "Patent Matter" }
        #expect(patentTopic?.facts.map(\.value).contains("late rent notice to landlord Baker") == false)
    }

    @Test("All thin → the single largest becomes the sole topic and absorbs the rest")
    func allThinCollapseToOne() {
        let a = subjectFacts("A", [("x", "1"), ("y", "2")])
        let b = subjectFacts("B", [("z", "3")])
        let out = TopicConsolidator.consolidate([a, b], minDistinctFacts: 4)
        #expect(out.count == 1)
        #expect(out.first?.subject == "A")            // largest by distinct facts
        #expect(out.first?.facts.count == 3)          // absorbed B's fact
    }

    @Test("With several real topics, a thin subject sharing nothing with any of them is not dumped into the largest")
    func unrelatedThinDoesNotPolluteLargest() {
        let schedule = subjectFacts("Final shift schedule", [
            ("shift", "A"), ("shift", "B"), ("operator", "Ravi"), ("operator", "Mina"), ("line", "3"),
        ])
        let patent = subjectFacts("Patent Matter", [
            ("applicant", "Acme"), ("application_number", "US-1"),
            ("filing_date", "2023-01-01"), ("examiner", "Roe"),
        ])
        let unrelated = subjectFacts("Please call me back", [("contact", "8106524242")])
        let out = TopicConsolidator.consolidate([schedule, patent, unrelated], minDistinctFacts: 4)
        #expect(out.count == 2)
        #expect(out.allSatisfy { !$0.facts.map(\.value).contains("8106524242") },
                "no closest topic exists, so it joins none")
    }

    @Test("A single subject passes through untouched")
    func singlePassesThrough() {
        let a = subjectFacts("A", [("x", "1")])
        let out = TopicConsolidator.consolidate([a])
        #expect(out.count == 1)
        #expect(out.first?.subject == "A")
    }

    @Test("P1.13 — transport notices and file-kind stems are not subjects; real names with hashes still are")
    func nonSubjectLabels() {
        for label in ["Delivery Status Notification (Failure)", "Undeliverable: Fwd: resume (prasenjit maity)",
                      "Mail Delivery Subsystem", "image-bc523fd4", "img20200115_19590228-54927701",
                      "Picture-8776713c", "IMG_4471", "Scanned Document 12", "IMG-20231129-WA0004-55b8cdda", ""] {
            #expect(TopicConsolidator.isNonSubjectLabel(label), "\(label) is not a subject")
        }
        for label in ["Patent No. 555489 (Application 202331019665)", "Shirshendu Sasmal", "Resume QA - m-720c7304",
                      "GDPR_Report_sasmal", "HYBRID RELUCTANCE INDUCTION MOTOR", "Final shift schedule 1-44a2cf0d",
                      "Transaction Successful"] {
            #expect(!TopicConsolidator.isNonSubjectLabel(label), "\(label) is a real subject")
        }
    }

    @Test("P1.13 — a bounce notice with many facts is still folded or left out, never a standing topic")
    func bounceNeverStandsAlone() {
        let patent = subjectFacts("Patent No. 555489", [("patentnumber", "555489"), ("applicationnumber", "202331019665"),
                                                         ("status", "granted"), ("grantdate", "28 Nov 2024")])
        let person = subjectFacts("Shirshendu Sasmal", [("email", "a@b.c"), ("phone", "91234"), ("city", "Kolkata"), ("degree", "B.Tech")])
        let bounce = subjectFacts("Delivery Status Notification (Failure)",
                                  (1...8).map { ("recipient", "user\($0)@example.com") })
        let out = TopicConsolidator.consolidate([patent, person, bounce]).map(\.subject)
        #expect(!out.contains("Delivery Status Notification (Failure)"))
        #expect(out.contains("Patent No. 555489") && out.contains("Shirshendu Sasmal"))
    }

    @Test("P1.13 — labels differing only in case/spacing are one subject")
    func caseDuplicatesMerge() {
        let a = subjectFacts("HYBRID RELUCTANCE INDUCTION MOTOR", [("title", "motor"), ("inventor", "S. Sasmal")])
        let b = subjectFacts("Hybrid  Reluctance Induction Motor", [("field", "electrical"), ("status", "filed"), ("year", "2023")])
        let out = TopicConsolidator.consolidate([a, b])
        #expect(out.count == 1)
        #expect(out.first?.subject == "Hybrid  Reluctance Induction Motor", "the most-evidenced spelling leads")
        #expect(out.first?.facts.count == 5)
    }

    @Test("P1.19 — automated senders are recognised by the address; their subjects never stand as topics")
    func automatedMail() {
        for a in ["noreply@google.com", "no-reply@accounts.google.com", "alerts@bank.example", "calendar-notification@google.com",
                  "mailer-daemon@googlemail.com", "updates.jobs@portal.example"] {
            #expect(EmailParticipantRepository.isAutomatedAddress(a), "\(a)")
        }
        for a in ["gopinath@iiprd.com", "info@khuranaandkhurana.com", "accounts@khuranaandkhurana.com", "alertfield@x.com"] {
            #expect(!EmailParticipantRepository.isAutomatedAddress(a), "\(a)")
        }
        let chat = subjectFacts("shirshendu sasmal wants to chat", (1...6).map { ("f\($0)", "v\($0)") })
        let patent = subjectFacts("Patent No. 555489", [("patentnumber", "555489"), ("status", "granted"), ("grantdate", "28 Nov 2024"), ("applicant", "S. Sasmal")])
        let person = subjectFacts("Shirshendu Sasmal", [("email", "a@b.c"), ("phone", "1"), ("city", "Kolkata"), ("degree", "B.Tech")])
        let out = TopicConsolidator.consolidate([chat, patent, person], nonSubjects: ["Shirshendu Sasmal wants to chat"]).map(\.subject)
        #expect(!out.contains("shirshendu sasmal wants to chat"))
        #expect(out.contains("Patent No. 555489"))
    }

    @Test("P1.19 — one template with a varying slot is one series topic; closed matters and distinct matters are untouched")
    func templateSeriesFold() {
        let facts = (1...5).map { ("f\($0)", "v\($0)") }
        let alerts = ["Alert Generated for sara Koll", "Alert Generated for L489000002", "Re: Alert Generated for john smidth"]
            .map { subjectFacts($0, facts) }
        let pair = ["Final shift schedule A", "Final shift schedule B"].map { subjectFacts($0, facts) }
        let patents = ["Patent No. 555489 grant", "Patent No. 555489 hearing", "Patent No. 555489 fee"]
            .map { subjectFacts($0, facts) }
        let out = TopicConsolidator.consolidate(alerts + pair + patents, closed: Set(patents.map(\.subject)))
        let labels = out.map(\.subject)
        #expect(labels.contains("Alert Generated for …"))
        #expect(!labels.contains { $0.hasPrefix("Alert Generated for ") && !$0.hasSuffix("…") })
        #expect(out.first { $0.subject == "Alert Generated for …" }?.facts.count == 15, "every member's facts are kept")
        #expect(labels.contains("Final shift schedule A") && labels.contains("Final shift schedule B"), "two are not a series")
        #expect(patents.allSatisfy { labels.contains($0.subject) }, "closed matters never fold")
        #expect(TopicConsolidator.openingText(of: "CV : For Pharmaceutical JOB", words: 3) == "CV : For Pharmaceutical")
    }
}

@Suite("P1.4 — the owner's own name links nothing")
struct TopicUbiquitousTermTests {
    private func facts(_ subject: String, _ pairs: [(String, String)]) -> TopicConsolidator.SubjectFacts {
        TopicConsolidator.SubjectFacts(subject: subject, facts: pairs.map {
            GenericFact(subjectLabel: subject, field: $0.0, value: $0.1, status: .sourceAsserted,
                        confidence: 0.8, sourceBlockIDs: [UUID()])
        })
    }

    @Test("A thin mail sharing only the owner's name with a chat is not folded into it")
    func ubiquitousTermsDoNotFold() {
        let owner = ("from", "Shirshendu Sasmal")
        var input = (1...6).map { i in
            facts("Matter \(i)", [owner, ("topic\(i)a", "alpha\(i)"), ("topic\(i)b", "beta\(i)"), ("topic\(i)c", "gamma\(i)")])
        }
        input.append(facts("Hot", [owner]))
        let out = TopicConsolidator.consolidate(input)
        let total = out.reduce(0) { $0 + $1.facts.count }
        #expect(total == 24, "the photo mail's lone fact joined no matter (it stays in the ledger)")
    }
}
