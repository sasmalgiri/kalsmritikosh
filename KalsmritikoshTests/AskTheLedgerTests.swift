//
//  AskTheLedgerTests.swift
//  Kalsmritikosh Tests
//
//  A3 — the Ask-the-Ledger lane's laws, proven pure in CI: the plan cannot
//  name a nonexistent field; the sweep keeps only cited, grounded
//  sentences; an adversarial span never fills; the plan derivation is
//  k-run stable.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("A3 — Ask-the-Ledger (plan validation + the sweep)")
struct AskTheLedgerTests {

    @Test("The plan cannot name a nonexistent field; derivation is k-run stable")
    func planLaws() {
        let anchors = [Entity(kind: .identifierAnchor, value: "patentnumber|555489",
                              normalizedValue: "patentnumber|555489", sourceObjectID: UUID(), confidence: .high)]
        // A fabricated field dies at the validating init.
        let bogus = QuestionPlan(shape: .unresolved, subjectMention: nil, field: "shoeSize")
        #expect(bogus.field == nil, "an unknown field can never reach a lookup")
        // A real field normalizes and survives.
        let real = QuestionPlan(shape: .unresolved, subjectMention: nil, field: "applicant")
        #expect(real.field == "applicant")
        // k-run stability: same question + anchors → identical plans.
        let p1 = QuestionPlan.derive(question: "who is the owner of this patent?", anchors: anchors)
        let p2 = QuestionPlan.derive(question: "who is the owner of this patent?", anchors: anchors)
        #expect(p1 == p2)
        #expect(p1.field == "applicant")
        #expect(p1.subjectMention == "555489")
    }

    @Test("The sweep: cited+grounded survives; uncited, foreign-digit, and new-noun sentences die")
    func sweepLaws() {
        let results = [
            ToolResult(id: "T1", text: "28 November 2024 — Patent granted", objectIDs: [UUID()]),
            ToolResult(id: "F1", text: "applicant: shirshendu sasmal", objectIDs: [UUID()]),
        ]
        let q = "when was the patent granted and who applied"
        let candidate = """
        The patent was granted on 28 November 2024 [T1]. The applicant is \
        shirshendu sasmal [F1]. It was worth 50000 rupees [T1]. Khurana \
        handled everything [F1]. This sentence has no citation at all.
        """
        let kept = ToolGroundedComposer.sweep(candidate: candidate, question: q, results: results)
        #expect(kept.count == 2, "got: \(kept.map(\.text))")
        #expect(kept[0].text.contains("28 November 2024") && kept[0].citedID == "T1")
        #expect(kept[1].text.lowercased().contains("shirshendu") && kept[1].citedID == "F1")
        // The foreign digit (50000), the new noun (Khurana), and the uncited
        // sentence are all dead.
        #expect(!kept.contains { $0.text.contains("50000") })
        #expect(!kept.contains { $0.text.contains("Khurana") })
    }

    @Test("Tools are deterministic and id-bearing; an unknown field returns nothing")
    func toolLaws() async {
        let src = UUID()
        let granted = Event(kind: .contractSigned, date: Date(timeIntervalSince1970: 1_732_752_000),
                            title: "Patent granted", entityIDs: [], sourceObjectID: src, datePrecision: .day)
        let tools = LedgerTools(
            events: { _ in [granted] },
            facts: { field in
                field == "applicant"
                    ? [GenericFact(subjectLabel: "s", field: "applicant", value: "shirshendu sasmal",
                                   status: .sourceAsserted, confidence: 0.8, sourceBlockIDs: [],
                                   producerVersion: 4, rawMatch: nil, sourceCount: 1)]
                    : []
            },
            chunksForQuestion: { _ in [] })
        let history = await tools.historyOf(question: "when was the patent granted")
        #expect(history.first?.id == "T1")
        #expect(history.first?.text.contains("28 November 2024") == true)
        #expect(history.first?.objectIDs == [src])
        let lookup = await tools.lookupField("applicant")
        #expect(lookup.first?.text == "applicant: shirshendu sasmal")
        #expect(await tools.lookupField("shoeSize").isEmpty, "unknown fields return nothing")
        let count = await tools.countEvents(question: "how many grants were there")
        #expect(count.first?.text == "count: 1")
    }
}
