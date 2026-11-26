//
//  AccuracyG5Tests.swift
//  KalsmritikoshTests
//
//  Accuracy G5 (FAIR4 design gap, 2026-11-25): when the AI compares two figures, the app says — with exact arithmetic on
//  the precision each is stated to — whether they differ only by rounding; the question task tells the AI to treat such
//  differences as consistent unless a document says otherwise. FAIR4 real4-4x q3 ("approximately $2 million" vs the court's
//  $1,985,754) and real4-autoland q6 (167 knots vs "about 170 knots") were framed as disagreements.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Accuracy G5 — differences within rounding at the stated precision")
struct AccuracyG5Tests {
    @Test("G5: the stated precision of a figure")
    func precision() throws {
        let a = try #require(CaseAgent.statedFigure("about 170 knots"))
        #expect(a.value == 170 && a.unit == 10)
        let b = try #require(CaseAgent.statedFigure("$1.6 million"))
        #expect(b.value == 1_600_000 && b.unit == 100_000)
        let c = try #require(CaseAgent.statedFigure("approximately $2 million"))
        #expect(c.value == 2_000_000 && c.unit == 1_000_000)
        let d = try #require(CaseAgent.statedFigure("$1,985,754"))
        #expect(d.value == 1_985_754 && d.unit == 1)
        #expect(CaseAgent.statedFigure("167 knots")?.unit == 1)
        #expect(CaseAgent.statedFigure("500 m")?.value == 500, "a spaced m is a unit of length, not million")
    }

    @Test("G5: FAIR4 4x q3 and autoland q6 differ only by rounding; real differences do not")
    func fair4() {
        let fourX = CaseAgent.compareFigures("approximately $2 million", "$1,985,754")
        #expect(fourX.contains("these differ only by rounding at the stated precision"), "\(fourX)")
        #expect(fourX.contains("differ by 14,246"), "\(fourX)")
        let autoland = CaseAgent.compareFigures("167 knots", "about 170 knots")
        #expect(autoland.contains("these differ only by rounding at the stated precision") && autoland.contains("covers 165 to 175"), "\(autoland)")
        #expect(CaseAgent.compareFigures("71 knots", "about 70 knots").contains("only by rounding"))
        #expect(CaseAgent.compareFigures("$1.6 million", "$1,575,000").contains("only by rounding"))
        // Real differences: newark $730,000 alleged vs $956,948 admitted; two exact figures; a hedge that does not reach.
        #expect(CaseAgent.compareFigures("$730,000", "$956,948").contains("more than rounding"))
        #expect(CaseAgent.compareFigures("167 knots", "170 knots").contains("more than rounding"))
        #expect(CaseAgent.compareFigures("about 170 knots", "180 knots").contains("more than rounding"))
        #expect(CaseAgent.compareFigures("EUR 500", "USD 500").contains("different currencies"))
        #expect(CaseAgent.compareFigures("$5,000", "$5,000.00").contains("the same figure"))
    }

    @Test("G5: the compare tool and the sum tool say so; the question task carries the instruction")
    func toolsAndTask() async {
        let tools = CaseAgentTools(documents: [CaseReader.Document(objectID: UUID(), text: "approximately $2 million; $1,985,754")])
        let compare = await tools.run([CaseAgent.Call(tool: "compare", fields: ["a": .string("approximately $2 million"), "b": .string("$1,985,754")])])
        #expect(compare.contains("only by rounding"), "\(compare)")
        let sum = await tools.run([CaseAgent.Call(tool: "sum", fields: ["items": .array([.string("$1.6 million")]), "minus": .array([.string("$1,575,000")])])])
        #expect(sum.contains("these differ only by rounding at the stated precision"), "\(sum)")
        #expect(CaseReader.questionSuffix("Q?").contains("differ only within rounding at their stated precision"))
        #expect(CaseAgent.guide(write: false).contains("\"tool\": \"compare\""))
    }

    @Test("G5: any style — durations, lakh/crore, comma-decimal, Arabic-Indic digits; bounds are not rounding")
    func anyStyle() {
        #expect(CaseAgent.compareFigures("nearly 3 years", "2 years 11 months").contains("only by rounding"))
        #expect(CaseAgent.compareFigures("3 years", "2 years 11 months").contains("only by rounding"), "3 years is stated to the nearest year")
        #expect(CaseAgent.compareFigures("2 years 6 months", "2 years 11 months").contains("more than rounding"))
        #expect(CaseAgent.compareFigures("about 30 days", "4 months").contains("different units"))
        #expect(CaseAgent.compareFigures("₹1.6 crore", "₹1,57,50,000").contains("only by rounding"))
        #expect(CaseAgent.compareFigures("₹1.6 crore", "₹1,25,00,000").contains("more than rounding"))
        #expect(CaseAgent.compareFigures("€1,6 Mio.", "€1.575.000").contains("only by rounding"))
        #expect(CaseAgent.compareFigures("CHF 1'600'000", "CHF 1'575'000").contains("more than rounding"))
        #expect(CaseAgent.compareFigures("about \u{0667}\u{0660} knots", "71 knots").contains("only by rounding"))
        #expect(CaseAgent.compareFigures("170-odd knots", "167 knots").contains("only by rounding"))
        #expect(CaseAgent.compareFigures("more than 170 knots", "167 knots").contains("outside the bound"), "a bound is not a hedge")
        #expect(CaseAgent.compareFigures("over $2 million", "$1,985,754").contains("is a bound") && CaseAgent.compareFigures("over $2 million", "$1,985,754").contains("outside the bound"))
        #expect(CaseAgent.compareFigures("about £2 million", "$1,985,754").contains("different currencies"))
        #expect(CaseAgent.compareFigures("about 12%", "12.4%").contains("only by rounding"))
        #expect(CaseAgent.compareFigures("about 12%", "13.4%").contains("more than rounding"))
    }

    @Test("G5: a conflict's two quotes get the note only when two figures differ within rounding; dates and years are not figures")
    func conflicts() {
        #expect(CaseAgent.roundingNote(between: "On 3 March 2026 the aircraft was at about 170 knots", and: "the recorder shows 167 knots") != nil)
        #expect(CaseAgent.roundingNote(between: "paid $730,000 on 2 May 2025", and: "admitted $956,948 on 2 May 2025") == nil)
        #expect(CaseAgent.roundingNote(between: "signed in 2025", and: "signed in 2026") == nil)
        #expect(CaseAgent.roundingNote(between: "dated 13/03/2026", and: "dated 14/03/2026") == nil)
    }
}
