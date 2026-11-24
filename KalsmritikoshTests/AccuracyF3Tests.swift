//
//  AccuracyF3Tests.swift
//  KalsmritikoshTests
//
//  Accuracy F3 (FAIR3 root cause, 2026-11-25): the second look gets a checklist — the AI picture records that name a person
//  or company of the question or the answer and that no shown claim cites; it must address each or say why not.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Accuracy F3 — the second look's subject checklist")
struct AccuracyF3Tests {
    static let d1 = UUID(), d2 = UUID()

    static func entity(_ name: String, aliases: [String] = []) -> CaseAIRecord {
        CaseAIRecord(kind: .entity, text: name, entityType: "person", quote: name, document: d1, supporting: aliases, origin: "picture")
    }

    static let records: [CaseAIRecord] = [
        entity("Dr Suresh Menon"),
        entity("Rajesh Iyer", aliases: ["Rajesh Ayyar"]),
        entity("Vitalair Medisystems"),
        entity("Anita Rao"),
        CaseAIRecord(kind: .conflict, text: "Menon declared no relative deals, but Rajesh Ayyar appears to be his brother-in-law",
                     quote: "I have no relative dealing with the hospital", document: d1,
                     quoteB: "my brother-in-law Rajesh Ayyar", documentB: d2, origin: "picture"),
        CaseAIRecord(kind: .event, text: "Vitalair Medisystems incorporated by Rajesh Iyer", dateText: "4 May 2025",
                     quote: "Vitalair Medisystems Pvt Ltd was incorporated on 4 May 2025", document: d2, origin: "picture"),
        CaseAIRecord(kind: .fact, text: "Anita Rao approved the canteen tender", quote: "Anita Rao approved the canteen tender", document: d2, origin: "picture"),
        CaseAIRecord(kind: .fact, text: "Menon signed the consent judgment on 13 February 2015", quote: "Consent judgment signed by Dr Suresh Menon", document: d2,
                     origin: "question"),
    ]

    @Test("F3: records about the question's and answer's names that no shown claim cites, conflicts first; cited and unrelated ones left out")
    func checklist() {
        let number = [Self.d1: 1, Self.d2: 2]
        let lines = CaseReader.subjectChecklist(question: "Who is behind Vitalair Medisystems, and is anyone named in more than one way?",
                                                answer: "Rajesh Iyer incorporated Vitalair; he is Menon's brother-in-law.",
                                                shownQuotes: ["Vitalair Medisystems Pvt Ltd was incorporated on 4 May 2025"],
                                                records: Self.records, number: number)
        #expect(lines.count == 1, "\(lines)")
        #expect(lines.first?.hasPrefix("- (conflict) Menon declared no relative deals") == true)
        #expect(lines.first?.hasSuffix("[Document 1] [Document 2]") == true)
        // Not cited: the event comes back; a record written while answering (origin question) is never on the list.
        let more = CaseReader.subjectChecklist(question: "Who is behind Vitalair Medisystems?", answer: "Rajesh Ayyar.", shownQuotes: [],
                                               records: Self.records, number: number)
        #expect(more.count == 2)
        #expect(more.last?.hasPrefix("- (event) 4 May 2025: Vitalair Medisystems incorporated") == true)
        #expect(!more.joined().contains("Anita Rao"), "a record about no name of the question or answer")
        #expect(!more.joined().contains("consent judgment"))
        // No named party: no list.
        #expect(CaseReader.subjectChecklist(question: "When was the fire?", answer: "On 3 May.", shownQuotes: [], records: Self.records, number: number).isEmpty)
    }

    @Test("F3: the second-look task carries the checklist and keeps the dropped-statements list; without both it is unchanged")
    func lookTask() {
        let dropped = [VerifiedAnswerComposer.DroppedClaim(text: "He got 72 months.", passage: 1, reason: "the number 72 not in the quote")]
        let s = CaseReader.secondLookSuffix("Q?", answer: "A.", dropped: dropped, checklist: ["- (conflict) X"])
        #expect(s.contains(CaseReader.checklistLead))
        #expect(s.contains("- (conflict) X"))
        #expect(s.contains(CaseReader.droppedLead))
        #expect(CaseReader.secondLookSuffix("Q?", answer: "A.") == CaseReader.secondLookSuffix("Q?", answer: "A.", dropped: [], checklist: []))
        #expect(!CaseReader.secondLookSuffix("Q?", answer: "A.").contains(CaseReader.checklistLead))
    }
}
